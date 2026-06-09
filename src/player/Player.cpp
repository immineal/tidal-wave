#include "Player.h"
#include <QDebug>
#include <QUrl>
#include <QTimer>
#include <QNetworkReply>
#include <algorithm>
#include <numeric>
#include <QRandomGenerator>

Player::Player(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client)
{
    // Defer audio device init until after the event loop starts to avoid
    // a PipeWire pw_thread_loop_lock deadlock under -O3 optimisation.
    QTimer::singleShot(0, this, &Player::initAudio);
}

void Player::initAudio() {
    m_player   = new QMediaPlayer(this);
    m_audioOut = new QAudioOutput(this);
    m_player->setAudioOutput(m_audioOut);
    m_audioOut->setVolume(m_pendingVolume);
    m_audioOut->setMuted(m_pendingMuted);

    connect(m_player, &QMediaPlayer::mediaStatusChanged,
            this, &Player::onMediaStatusChanged);
    connect(m_player, &QMediaPlayer::playbackStateChanged,
            this, &Player::onPlaybackStateChanged);
    connect(m_player, &QMediaPlayer::errorOccurred,
            this, &Player::onErrorOccurred);
    connect(m_player, &QMediaPlayer::positionChanged, this, [this](qint64 pos) {
        qint64 dur = m_player->duration();
        if (dur > 10000 && pos > 0 && (dur - pos) <= 10000)
            preloadNext();
        emit positionChanged(pos);
    });
    connect(m_player, &QMediaPlayer::durationChanged,
            this, &Player::durationChanged);
}

Player::~Player() {
    cancelPreload();
    delete m_mpdTempFile;
}

bool   Player::playing()  const { return m_player  && m_player->playbackState() == QMediaPlayer::PlayingState; }
qint64 Player::position() const { return m_player  ? m_player->position() : 0; }
qint64 Player::duration() const { return m_player  ? m_player->duration() : 0; }
double Player::volume()   const { return m_audioOut ? m_audioOut->volume() : m_pendingVolume; }
bool   Player::muted()    const { return m_audioOut ? m_audioOut->isMuted() : m_pendingMuted; }

QVariantMap Player::currentTrackMap() const {
    if (m_index < 0 || m_index >= m_queue.count()) return {};
    return m_queue[m_index];
}

void Player::setLoading(bool l) {
    if (m_loading == l) return;
    m_loading = l;
    emit loadingChanged(l);
}

// ─── QML-callable ──────────────────────────────────

void Player::playTracks(const QVariantList &tracks, int startIndex) {
    if (tracks.isEmpty()) return;
    cancelPreload();
    m_queue.clear();
    for (const auto &v : tracks)
        m_queue.append(v.toMap());
    m_index = qBound(0, startIndex, m_queue.count() - 1);
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
    loadAndPlay(m_index);
}

void Player::appendQueue(const QVariantList &tracks) {
    int insertAt = (m_index >= 0) ? m_index + 1 : m_queue.count();
    for (int i = 0; i < tracks.count(); i++) {
        QVariantMap t = tracks[i].toMap();
        t["_userQueued"] = true;
        m_queue.insert(insertAt + i, t);
    }
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
}

void Player::jumpToQueue(int index) {
    if (index < 0 || index >= m_queue.count()) return;
    cancelPreload();
    m_index = index;
    emit queueChanged();
    loadAndPlay(m_index);
}

void Player::clearQueue() {
    cancelPreload();
    if (m_player) m_player->stop();
    m_queue.clear();
    m_shuffleOrder.clear();
    m_index = -1;
    m_currentTrack = Track{};
    setLoading(false);
    emit currentTrackChanged();
    emit queueChanged();
}

void Player::removeFromQueue(int index) {
    if (index < 0 || index >= m_queue.count()) return;
    m_queue.removeAt(index);
    if (index < m_index) {
        m_index--;
    } else if (index == m_index) {
        if (m_queue.isEmpty()) {
            if (m_player) m_player->stop();
            m_index = -1;
            m_currentTrack = Track{};
            setLoading(false);
            emit currentTrackChanged();
        } else {
            m_index = qMin(m_index, m_queue.count() - 1);
            loadAndPlay(m_index);
        }
    }
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
}

void Player::moveQueueItem(int from, int to) {
    if (from < 0 || from >= m_queue.count() ||
        to   < 0 || to   >= m_queue.count() || from == to) return;
    m_queue.move(from, to);
    if      (m_index == from)                          m_index = to;
    else if (from < m_index && to >= m_index)          m_index--;
    else if (from > m_index && to <= m_index)          m_index++;
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
}

QVariantMap Player::queueTrackAt(int index) const {
    if (index < 0 || index >= m_queue.count()) return {};
    return m_queue[index];
}

QVariantList Player::queueTracks() const {
    QVariantList out;
    for (const auto &m : m_queue)
        out.append(m);
    return out;
}

QVariantList Player::recentlyPlayed() const {
    QVariantList out;
    for (const auto &m : m_recentlyPlayed)
        out.append(m);
    return out;
}

void Player::playPause() {
    if (!m_player) return;
    if (m_player->playbackState() == QMediaPlayer::PlayingState)
        m_player->pause();
    else
        m_player->play();
}

void Player::next() {
    if (!m_player) return;
    int n = nextIndex();
    if (n < 0) { m_player->stop(); return; }
    m_index = n;
    emit queueChanged();
    loadAndPlay(m_index);
}

void Player::previous() {
    if (!m_player) return;
    if (m_player->position() > 3000) {
        m_player->setPosition(0);
        return;
    }
    int p = previousIndex();
    if (p < 0) { m_player->setPosition(0); return; }
    m_index = p;
    emit queueChanged();
    loadAndPlay(m_index);
}

void Player::seek(qint64 ms) { if (m_player) m_player->setPosition(ms); }

void Player::setVolume(double v) {
    m_pendingVolume = qBound(0.0, v, 1.0);
    if (m_audioOut) m_audioOut->setVolume(m_pendingVolume);
    emit volumeChanged(m_pendingVolume);
}

void Player::setMuted(bool m) {
    m_pendingMuted = m;
    if (m_audioOut) m_audioOut->setMuted(m);
    emit mutedChanged(m);
}

void Player::setShuffle(bool s) {
    m_shuffle = s;
    if (s) buildShuffleOrder();
    emit shuffleChanged(s);
}

void Player::setRepeatMode(int m) {
    m_repeatMode = m;
    emit repeatModeChanged(m);
}

// ─── Internals ─────────────────────────────────────

int Player::nextIndex() const {
    if (m_repeatMode == 2) return m_index;   // repeat one
    if (m_shuffle) {
        int si = m_shuffleOrder.indexOf(m_index);
        if (si < m_shuffleOrder.count() - 1) return m_shuffleOrder[si + 1];
        if (m_repeatMode == 1) return m_shuffleOrder[0];
        return -1;
    }
    if (m_index < m_queue.count() - 1) return m_index + 1;
    if (m_repeatMode == 1) return 0;
    return -1;
}

int Player::previousIndex() const {
    if (m_shuffle) {
        int si = m_shuffleOrder.indexOf(m_index);
        if (si > 0) return m_shuffleOrder[si - 1];
        return -1;
    }
    if (m_index > 0) return m_index - 1;
    return -1;
}

void Player::buildShuffleOrder() {
    m_shuffleOrder.resize(m_queue.count());
    std::iota(m_shuffleOrder.begin(), m_shuffleOrder.end(), 0);
    for (int i = m_shuffleOrder.count() - 1; i > 0; --i) {
        int j = QRandomGenerator::global()->bounded(i + 1);
        std::swap(m_shuffleOrder[i], m_shuffleOrder[j]);
    }
    if (m_index >= 0) {
        int pos = m_shuffleOrder.indexOf(m_index);
        if (pos > 0) std::swap(m_shuffleOrder[0], m_shuffleOrder[pos]);
    }
}

Track Player::trackFromMap(const QVariantMap &m) const {
    Track t;
    t.id       = m["id"].toLongLong();
    t.title    = m["title"].toString();
    t.duration = m["duration"].toInt();
    t.album.title = m["albumTitle"].toString();
    t.album.id    = m["albumId"].toLongLong();
    t.album.cover = m["albumCover"].toString();
    // Parse artists string back to artist struct (simplified)
    Artist a;
    a.name = m["artists"].toString();
    a.id   = m["artistId"].toLongLong();
    t.artists.append(a);
    return t;
}

void Player::loadAndPlay(int index) {
    if (!m_player || index < 0 || index >= m_queue.count()) return;

    setLoading(true);
    m_player->stop();
    m_player->setSource(QUrl());

    if (m_activeDownload) {
        auto *dl = m_activeDownload;
        m_activeDownload = nullptr;
        dl->abort();
        dl->deleteLater();
    }

    if (m_mpdTempFile) {
        m_mpdTempFile->remove();
        delete m_mpdTempFile;
        m_mpdTempFile = nullptr;
    }

    m_streamedQuality.clear();
    m_currentTrack = trackFromMap(m_queue[index]);
    emit currentTrackChanged();

    // Track recently played (max 20 unique entries)
    QVariantMap trackMap = m_queue[index];
    qlonglong trackId = trackMap.value("id").toLongLong();
    for (int i = m_recentlyPlayed.count() - 1; i >= 0; --i) {
        if (m_recentlyPlayed.at(i).value("id").toLongLong() == trackId)
            m_recentlyPlayed.removeAt(i);
    }
    m_recentlyPlayed.prepend(trackMap);
    if (m_recentlyPlayed.count() > 20)
        m_recentlyPlayed = m_recentlyPlayed.mid(0, 20);
    emit recentlyPlayedChanged();

    // Use preloaded file if it's ready for this exact index
    if (m_preloadIndex == index && m_preloadReady && m_preloadTempFile) {
        m_mpdTempFile     = m_preloadTempFile;
        m_preloadTempFile = nullptr;
        m_streamedQuality = m_preloadQuality;
        m_preloadIndex    = -1;
        m_preloadReady    = false;
        m_preloadQuality  = {};
        emit currentTrackChanged();
        setLoading(false);
        m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
        m_player->play();
        return;
    }

    // Preload is for a different track or still in progress — discard it
    cancelPreload();

    qlonglong loadingTrackId = m_currentTrack.id;
    m_client->fetchStreamManifest(loadingTrackId,
        [this, loadingTrackId](StreamManifest manifest, QString err) {
            if (m_currentTrack.id != loadingTrackId) {
                return;
            }
            if (!err.isEmpty()) {
                setLoading(false);
                emit error("Stream error: " + err);
                return;
            }
            m_streamedQuality = manifest.codec;
            emit currentTrackChanged();

            if (manifest.type == StreamManifest::BTS) {
                m_activeDownload = m_client->fetchRaw(QUrl(manifest.url), [this, loadingTrackId](QByteArray data, QString err) {
                    m_activeDownload = nullptr;
                    if (m_currentTrack.id != loadingTrackId) {
                        return;
                    }
                    if (!err.isEmpty() || data.isEmpty()) {
                        setLoading(false);
                        emit error("Failed to download audio stream: " + err);
                        return;
                    }
                    m_mpdTempFile = new QTemporaryFile(
                        QStringLiteral("/tmp/tidal-wave-XXXXXX.mp4"));
                    m_mpdTempFile->setAutoRemove(false);
                    if (m_mpdTempFile->open()) {
                        m_mpdTempFile->write(data);
                        m_mpdTempFile->flush();
                        m_mpdTempFile->close();
                        m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
                        m_player->play();
                    } else {
                        setLoading(false);
                        emit error("Failed to write temporary audio file");
                    }
                });
            } else {
                m_mpdTempFile = new QTemporaryFile(
                    QStringLiteral("/tmp/tidal-wave-XXXXXX.mpd"));
                m_mpdTempFile->setAutoRemove(false);
                if (m_mpdTempFile->open()) {
                    m_mpdTempFile->write(manifest.url.toUtf8());
                    m_mpdTempFile->flush();
                    m_mpdTempFile->close();
                    m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
                    m_player->play();
                } else {
                    setLoading(false);
                    emit error("Failed to write MPD temp file");
                    return;
                }
            }
        });
}

void Player::onMediaStatusChanged(QMediaPlayer::MediaStatus status) {
    switch (status) {
    case QMediaPlayer::LoadingMedia:
    case QMediaPlayer::BufferingMedia:
        setLoading(true); break;
    case QMediaPlayer::BufferedMedia:
    case QMediaPlayer::LoadedMedia:
        setLoading(false); break;
    case QMediaPlayer::EndOfMedia:
        setLoading(false);
        next();
        break;
    case QMediaPlayer::InvalidMedia:
        setLoading(false);
        emit error("Invalid media");
        break;
    default: break;
    }
}

void Player::onPlaybackStateChanged(QMediaPlayer::PlaybackState state) {
    emit playingChanged(state == QMediaPlayer::PlayingState);
}

void Player::onErrorOccurred(QMediaPlayer::Error, const QString &msg) {
    setLoading(false);
    qWarning() << "Player error:" << msg;
    emit error(msg);
}

void Player::cancelPreload() {
    if (m_preloadDownload) {
        auto *dl = m_preloadDownload;
        m_preloadDownload = nullptr;
        dl->abort();
        dl->deleteLater();
    }
    if (m_preloadTempFile) {
        m_preloadTempFile->remove();
        delete m_preloadTempFile;
        m_preloadTempFile = nullptr;
    }
    m_preloadIndex   = -1;
    m_preloadReady   = false;
    m_preloadQuality = {};
}

void Player::preloadNext() {
    int next = nextIndex();
    if (next < 0 || next == m_preloadIndex) return;

    cancelPreload();
    m_preloadIndex = next;

    qlonglong trackId = m_queue[next].value("id").toLongLong();

    m_client->fetchStreamManifest(trackId, [this, next](StreamManifest manifest, QString err) {
        if (m_preloadIndex != next || !err.isEmpty()) return;

        m_preloadQuality = manifest.codec;

        if (manifest.type == StreamManifest::BTS) {
            m_preloadDownload = m_client->fetchRaw(QUrl(manifest.url), [this, next](QByteArray data, QString dlErr) {
                m_preloadDownload = nullptr;
                if (m_preloadIndex != next || !dlErr.isEmpty() || data.isEmpty()) return;
                auto *f = new QTemporaryFile(QStringLiteral("/tmp/tidal-wave-XXXXXX.mp4"));
                f->setAutoRemove(false);
                if (f->open()) {
                    f->write(data); f->flush(); f->close();
                    m_preloadTempFile = f;
                    m_preloadReady    = true;
                } else {
                    delete f;
                }
            });
        } else {
            auto *f = new QTemporaryFile(QStringLiteral("/tmp/tidal-wave-XXXXXX.mpd"));
            f->setAutoRemove(false);
            if (f->open()) {
                f->write(manifest.url.toUtf8()); f->flush(); f->close();
                m_preloadTempFile = f;
                m_preloadReady    = true;
            } else {
                delete f;
                m_preloadIndex = -1;
            }
        }
    });
}

QString Player::audioQuality() const {
    if (m_streamedQuality.isEmpty()) {
        return QString();
    }

    AudioQuality pref = m_client->audioQuality();

    AudioQuality maxQuality = AudioQuality::Lossless;
    if (m_streamedQuality == QStringLiteral("LOW")) maxQuality = AudioQuality::Low96k;
    else if (m_streamedQuality == QStringLiteral("HIGH")) maxQuality = AudioQuality::Low320k;
    else if (m_streamedQuality == QStringLiteral("LOSSLESS")) maxQuality = AudioQuality::Lossless;
    else if (m_streamedQuality == QStringLiteral("HI_RES_LOSSLESS")) maxQuality = AudioQuality::HiResLossless;

    AudioQuality actual = pref;
    if (static_cast<int>(maxQuality) < static_cast<int>(pref)) {
        actual = maxQuality;
    }

    switch (actual) {
        case AudioQuality::Low96k:        return QStringLiteral("LOW");
        case AudioQuality::Low320k:       return QStringLiteral("HIGH");
        case AudioQuality::Lossless:      return QStringLiteral("LOSSLESS");
        case AudioQuality::HiResLossless: return QStringLiteral("HI_RES_LOSSLESS");
    }
    return QStringLiteral("LOSSLESS");
}

