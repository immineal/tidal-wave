#include "Player.h"
#include <QDebug>
#include <QUrl>
#include <QTimer>
#include <QNetworkReply>
#include <QSettings>
#include <QDir>
#include <QMediaDevices>
#include <QSet>
#include "cast/CastSession.h"
#include "ui/Prefs.h"
#include <algorithm>
#include <numeric>
#include <QRandomGenerator>

Player::Player(TidalClient *client, QObject *parent)
    : QObject(parent), m_client(client)
{
    connect(m_client, &TidalClient::userIdChanged, this, &Player::handleUserIdChanged);
    if (m_client->userId() > 0) {
        handleUserIdChanged(m_client->userId());
    }

    // Defer audio device init until after the event loop starts to avoid
    // a PipeWire pw_thread_loop_lock deadlock under -O3 optimisation.
    QTimer::singleShot(0, this, &Player::initAudio);
}

void Player::initAudio() {
    m_player   = new QMediaPlayer(this);
    // Bind the resolved device explicitly rather than taking QAudioOutput's
    // default: a default-constructed output latches onto whatever the default
    // was at construction and never notices a later change.
    m_audioOut = new QAudioOutput(resolveAudioDevice(), this);
    m_player->setAudioOutput(m_audioOut);
    m_audioOut->setVolume(m_pendingVolume);
    m_audioOut->setMuted(m_pendingMuted);

    // Hot-plug, removal and system-default changes all arrive here. It needs
    // an instance: audioOutputsChanged is not a static signal. Created inside
    // initAudio() so it stays behind the same deferral as the rest.
    m_devices = new QMediaDevices(this);
    connect(m_devices, &QMediaDevices::audioOutputsChanged,
            this, &Player::onAudioOutputsChanged);

    connect(m_player, &QMediaPlayer::mediaStatusChanged,
            this, &Player::onMediaStatusChanged);
    connect(m_player, &QMediaPlayer::playbackStateChanged,
            this, &Player::onPlaybackStateChanged);
    connect(m_player, &QMediaPlayer::errorOccurred,
            this, &Player::onErrorOccurred);
    connect(m_player, &QMediaPlayer::positionChanged, this, [this](qint64 pos) {
        if (m_rebinding) return;   // a swap's transient positions are not seeks
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
    // Detach and drop the output here rather than leaving it to QObject's
    // child cleanup: an output destroyed after its player calls back into an
    // object that is already gone.
    if (m_player) m_player->setAudioOutput(nullptr);
    delete m_audioOut;
    m_audioOut = nullptr;
}

// ─── Audio output routing ──────────────────────────────────
//
// The device can change under us in three ways: the user picks one in
// Settings, the system default moves (PipeWire and PulseAudio both do this
// when headphones appear), or the device we are on is unplugged. All three
// end up in applyAudioDevice() -> rebindAudioOutput(), and all three have to
// be inaudible beyond the gap the hardware itself imposes.
//
// Backend note: the device list and its change signal come from Qt's
// multimedia backend. PipeWire and PulseAudio report add/remove promptly; a
// plain ALSA backend has a static list and may never emit the change signal,
// so there a hot-plugged device only shows up the next time the list is read.
// The fallback path below does not depend on that signal.

void Player::setPrefs(Prefs *prefs) {
    if (m_prefs == prefs) return;
    if (m_prefs) disconnect(m_prefs, &Prefs::audioDeviceChanged, this, nullptr);
    m_prefs = prefs;
    if (m_prefs) {
        connect(m_prefs, &Prefs::audioDeviceChanged, this, [this] { applyAudioDevice(); });
    }
    applyAudioDevice();
}

QAudioDevice Player::resolveAudioDevice() const {
    const QString wanted = m_prefs ? m_prefs->audioDevice() : QString();
    if (!wanted.isEmpty()) {
        const QList<QAudioDevice> outs = QMediaDevices::audioOutputs();
        for (const QAudioDevice &d : outs) {
            if (QString::fromUtf8(d.id()) == wanted) return d;
        }
        // Chosen device is gone (unplugged, renamed, or a settings file from
        // another machine). Falling back to the default beats going silent.
    }
    return QMediaDevices::defaultAudioOutput();
}

QVariantList Player::availableAudioDevices() const {
    QVariantList out;
    QVariantMap sentinel;
    sentinel[QStringLiteral("id")]        = QString();
    sentinel[QStringLiteral("label")]     = tr("System default");
    sentinel[QStringLiteral("isDefault")] = false;
    out.append(sentinel);

    const QString defaultId = QString::fromUtf8(QMediaDevices::defaultAudioOutput().id());
    QSet<QString> seen;
    const QList<QAudioDevice> devices = QMediaDevices::audioOutputs();
    for (const QAudioDevice &d : devices) {
        const QString id = QString::fromUtf8(d.id());
        // An empty id would collide with the sentinel; a repeat would give the
        // picker two rows that select the same thing.
        if (id.isEmpty() || seen.contains(id)) continue;
        seen.insert(id);
        QVariantMap m;
        m[QStringLiteral("id")]    = id;
        m[QStringLiteral("label")] = d.description();   // from the OS, never translated
        m[QStringLiteral("isDefault")] = (id == defaultId);
        out.append(m);
    }
    return out;
}

QString Player::activeAudioDeviceId() const {
    if (!m_audioOut) return QString();
    return QString::fromUtf8(m_audioOut->device().id());
}

void Player::refreshAudioDevice() {
    applyAudioDevice();
}

void Player::onAudioOutputsChanged() {
    // Fires for any add or remove, most of which do not concern us.
    // applyAudioDevice() rebinds only if the device we should be on changed,
    // which covers both "the default moved" and "our device disappeared".
    applyAudioDevice();
}

void Player::applyAudioDevice() {
    if (!m_player || !m_audioOut) return;   // initAudio() resolves it on the way up
    const QAudioDevice target = resolveAudioDevice();
    if (m_audioOut->device() == target) return;
    rebindAudioOutput(target);
}

Player::AudioState Player::captureAudioState() const {
    AudioState s;
    // Deliberately the local player's state, not playing()/position(), which
    // report the cast device while casting. The local side is what the swap
    // disturbs, and the local side is what has to come back.
    s.position = m_player ? m_player->position() : 0;
    s.playing  = m_player && m_player->playbackState() == QMediaPlayer::PlayingState;
    s.volume   = m_audioOut ? m_audioOut->volume()  : m_pendingVolume;
    s.muted    = m_audioOut ? m_audioOut->isMuted() : m_pendingMuted;
    return s;
}

void Player::restoreAudioState(const AudioState &state) {
    if (m_audioOut) {
        m_audioOut->setVolume(state.volume);
        // The live value, not m_pendingMuted: while casting the local output is
        // force-muted and must stay that way across a swap.
        m_audioOut->setMuted(state.muted);
    }
    if (!m_player) return;
    // A swap can drop the backend back to the start of the track. Seek back
    // rather than letting it restart, and never re-set the source: that would
    // re-fetch the stream and look like a track change.
    if (state.position > 0 && m_player->position() != state.position && m_player->isSeekable())
        m_player->setPosition(state.position);
    const bool playing = m_player->playbackState() == QMediaPlayer::PlayingState;
    if (state.playing && !playing)      m_player->play();
    else if (!state.playing && playing) m_player->pause();
}

void Player::rebindAudioOutput(const QAudioDevice &device) {
    if (!m_player) return;

    const AudioState state = captureAudioState();
    m_rebinding = true;

    auto *fresh = new QAudioOutput(device, this);
    fresh->setVolume(state.volume);
    fresh->setMuted(state.muted);

    // Order matters. An output that is destroyed while the player still knows
    // about it calls back and unbinds whatever output is attached at that
    // moment - which, if the new one were attached first, would leave playback
    // with no sink at all. So: detach, destroy the old one outright (not
    // deleteLater, which would fire that callback later), then attach.
    QAudioOutput *old = m_audioOut;
    m_audioOut = fresh;
    if (old) {
        m_player->setAudioOutput(nullptr);
        delete old;
    }
    m_player->setAudioOutput(fresh);

    restoreAudioState(state);
    m_rebinding = false;

    // If the swap could not be made invisible after all, tell the UI the truth
    // instead of leaving it showing a state the player is no longer in.
    if (!casting()) {
        const bool playing = m_player->playbackState() == QMediaPlayer::PlayingState;
        if (playing != state.playing) emit playingChanged(playing);
        if (m_player->position() != state.position) emit positionChanged(m_player->position());
    }
}

bool   Player::playing()  const { return casting() ? m_castPlaying  : (m_player && m_player->playbackState() == QMediaPlayer::PlayingState); }
qint64 Player::position() const { return casting() ? m_castPosition : (m_player ? m_player->position() : 0); }
qint64 Player::duration() const { return casting() ? m_castDuration : (m_player ? m_player->duration() : 0); }
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
    // Clear a stale "playing from" if this play didn't set its own source.
    if (!m_pendingSource && !m_sourceType.isEmpty()) {
        m_sourceType.clear();
        m_sourceId.clear();
        m_sourceName.clear();
        emit sourceChanged();
    }
    m_pendingSource = false;
    cancelPreload();
    m_queue.clear();
    for (const auto &v : tracks)
        m_queue.append(v.toMap());
    m_index = qBound(0, startIndex, m_queue.count() - 1);
    if (m_shuffle) buildShuffleOrder();
    emit queueChanged();
    loadAndPlay(m_index);
}

void Player::setPlaybackSource(const QString &type, const QString &id, const QString &name) {
    m_pendingSource = true;   // consumed by the playTracks() that follows
    if (m_sourceType == type && m_sourceId == id && m_sourceName == name) return;
    m_sourceType = type;
    m_sourceId   = id;
    m_sourceName = name;
    emit sourceChanged();
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

QVariantList Player::upcomingTracks(int max) const {
    QVariantList out;
    if (m_queue.isEmpty() || m_index < 0) return out;
    if (m_shuffle) {
        // Walk the shuffle permutation forward from the current track.
        int si = m_shuffleOrder.indexOf(m_index);
        for (int i = si + 1; i >= 0 && i < m_shuffleOrder.count(); ++i) {
            out.append(m_queue[m_shuffleOrder[i]]);
            if (max >= 0 && out.count() >= max) break;
        }
    } else {
        for (int i = m_index + 1; i < m_queue.count(); ++i) {
            out.append(m_queue[i]);
            if (max >= 0 && out.count() >= max) break;
        }
    }
    return out;
}

QVariantList Player::playbackOrderTracks() const {
    if (!m_shuffle) return queueTracks();
    QVariantList out;
    for (int idx : m_shuffleOrder) {
        if (idx < 0 || idx >= m_queue.count()) continue;
        QVariantMap m = m_queue[idx];
        m[QStringLiteral("_queueIndex")] = idx;
        out.append(m);
    }
    return out;
}

QVariantList Player::recentlyPlayed() const {
    QVariantList out;
    for (const auto &m : m_recentlyPlayed)
        out.append(m);
    return out;
}

void Player::playPause() {
#ifdef Q_OS_LINUX
    if (casting()) {
        if (m_castPlaying) m_castSession->pause();
        else               m_castSession->play();
        return;
    }
#endif
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
    if (position() > 3000) { seek(0); return; }
    int p = previousIndex();
    if (p < 0) { seek(0); return; }
    m_index = p;
    emit queueChanged();
    loadAndPlay(m_index);
}

void Player::seek(qint64 ms) {
#ifdef Q_OS_LINUX
    if (casting()) {
        if (m_castSession) m_castSession->seek(ms / 1000.0);
        m_castPosition = ms;              // optimistic; device status corrects it
        emit positionChanged(ms);
        return;
    }
#endif
    if (m_player) m_player->setPosition(ms);
}

void Player::setVolume(double v) {
    m_pendingVolume = qBound(0.0, v, 1.0);
#ifdef Q_OS_LINUX
    if (casting() && m_castSession) m_castSession->setVolume(m_pendingVolume);
#endif
    if (m_audioOut) m_audioOut->setVolume(m_pendingVolume);
    emit volumeChanged(m_pendingVolume);
}

void Player::setMuted(bool m) {
    m_pendingMuted = m;
    // While casting the local output is force-muted; don't override that here
    // (the preference is re-applied on endCast). Mute still updates the UI state.
    if (m_audioOut && !casting()) m_audioOut->setMuted(m);
    emit mutedChanged(m);
}

void Player::setShuffle(bool s) {
    m_shuffle = s;
    if (s) buildShuffleOrder();
    emit shuffleChanged(s);
    // The upcoming-tracks order depends on shuffle, so refresh every queue view.
    emit queueChanged();
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

    // Save recently played to settings
    qint64 uid = m_client->userId();
    if (uid > 0) {
        QVariantList saveList;
        for (const auto &m : m_recentlyPlayed) {
            saveList.append(m);
        }
        QSettings settings;
        settings.setValue(QStringLiteral("user_%1/playback/recentlyPlayed").arg(uid), saveList);
    }

    // If casting, don't play locally — hand the (already-updated) current track
    // off to the cast device; CastManager re-prepares and LOADs it.
    if (casting()) {
        setLoading(false);
        emit castTrackChanged();
        return;
    }

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
                emit error(tr("Could not load this track for playback. %1").arg(err));
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
                        emit error(err.isEmpty()
                            ? tr("Could not download the audio for this track. No data came back.")
                            : tr("Could not download the audio for this track. %1").arg(err));
                        return;
                    }
                    m_mpdTempFile = new QTemporaryFile(
                        QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mp4"));
                    m_mpdTempFile->setAutoRemove(false);
                    if (m_mpdTempFile->open()) {
                        m_mpdTempFile->write(data);
                        m_mpdTempFile->flush();
                        m_mpdTempFile->close();
                        // Casting may have started while this fetch was in flight;
                        // if so, hand off to the device instead of playing locally.
                        if (casting()) { setLoading(false); emit castTrackChanged(); return; }
                        m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
                        m_player->play();
                    } else {
                        setLoading(false);
                        emit error(tr("Could not save the audio to a temporary file. "
                                      "Check that there is free disk space."));
                    }
                });
            } else {
                m_mpdTempFile = new QTemporaryFile(
                    QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mpd"));
                m_mpdTempFile->setAutoRemove(false);
                if (m_mpdTempFile->open()) {
                    m_mpdTempFile->write(manifest.url.toUtf8());
                    m_mpdTempFile->flush();
                    m_mpdTempFile->close();
                    // Casting may have started while this fetch was in flight;
                    // if so, hand off to the device instead of playing locally.
                    if (casting()) { setLoading(false); emit castTrackChanged(); return; }
                    m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
                    m_player->play();
                } else {
                    setLoading(false);
                    emit error(tr("Could not save the playback details to a temporary file. "
                                  "Check that there is free disk space."));
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
        emit error(tr("This track could not be played. The audio format may not be supported."));
        break;
    default: break;
    }
}

void Player::onPlaybackStateChanged(QMediaPlayer::PlaybackState state) {
    if (m_rebinding) return;   // rebindAudioOutput() reports the settled state
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
                auto *f = new QTemporaryFile(QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mp4"));
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
            auto *f = new QTemporaryFile(QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mpd"));
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

QString Player::qualityLabel(const QString &code) const {
    // Tidal-consistent tier names (matches the labels Tidal's own apps show),
    // replacing the older "HI-FI"/"MASTER" branding.
    if (code == QStringLiteral("HI_RES_LOSSLESS")) return tr("Max");
    if (code == QStringLiteral("LOSSLESS"))        return tr("Lossless");
    if (code == QStringLiteral("HIGH"))            return tr("High");
    if (code == QStringLiteral("LOW"))             return tr("Low");
    return code;
}

void Player::beginCast(CastSession *session) {
    m_castSession = session;
    // Silence local output; playback continues on the device. Muting the output
    // (not just pausing) is a hard guard: any in-flight stream fetch that resolves
    // after this point must not leak audio to the local speakers alongside the cast.
    if (m_player) m_player->pause();
    if (m_audioOut) m_audioOut->setMuted(true);
    cancelPreload();
    m_castPosition = 0;
    m_castDuration = duration();   // seed from current until the device reports
    m_castPlaying  = true;
    emit playingChanged(true);
}

void Player::endCast() {
    if (!m_castSession) return;
    m_castSession = nullptr;
    m_castPosition = 0;
    m_castPlaying  = false;
    // Restore the user's local mute preference (beginCast force-muted the output).
    if (m_audioOut) m_audioOut->setMuted(m_pendingMuted);
    // Resume playback locally from the top of the current track.
    if (m_index >= 0 && m_index < m_queue.count())
        loadAndPlay(m_index);
    else
        emit playingChanged(false);
}

void Player::onCastPosition(double sec) {
    m_castPosition = qint64(sec * 1000.0);
    if (casting()) emit positionChanged(m_castPosition);
}

void Player::onCastDuration(double sec) {
    const qint64 d = qint64(sec * 1000.0);
    if (d <= 0) return;
    m_castDuration = d;
    if (casting()) emit durationChanged(m_castDuration);
}

void Player::onCastPlaying(bool playing) {
    if (m_castPlaying == playing) return;
    m_castPlaying = playing;
    if (casting()) emit playingChanged(playing);
}

void Player::handleUserIdChanged(qint64 uid) {
    m_recentlyPlayed.clear();
    if (uid > 0) {
        QSettings settings;
        QVariantList list = settings.value(QStringLiteral("user_%1/playback/recentlyPlayed").arg(uid)).toList();
        for (const auto &v : list) {
            m_recentlyPlayed.append(v.toMap());
        }
    }
    emit recentlyPlayedChanged();
}

