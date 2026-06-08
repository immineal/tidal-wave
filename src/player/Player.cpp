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
    connect(m_player, &QMediaPlayer::positionChanged,
            this, &Player::positionChanged);
    connect(m_player, &QMediaPlayer::durationChanged,
            this, &Player::durationChanged);
}

Player::~Player() { delete m_mpdTempFile; }

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
    m_queue.clear();
    for (const auto &v : tracks)
        m_queue.append(v.toMap());
    m_index = qBound(0, startIndex, m_queue.count() - 1);
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
    loadAndPlay(m_index);
}

void Player::appendQueue(const QVariantList &tracks) {
    for (const auto &v : tracks) m_queue.append(v.toMap());
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
}

void Player::jumpToQueue(int index) {
    if (index < 0 || index >= m_queue.count()) return;
    m_index = index;
    emit queueChanged();
    loadAndPlay(m_index);
}

QVariantMap Player::queueTrackAt(int index) const {
    if (index < 0 || index >= m_queue.count()) return {};
    return m_queue[index];
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

    m_currentTrack = trackFromMap(m_queue[index]);
    emit currentTrackChanged();

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
