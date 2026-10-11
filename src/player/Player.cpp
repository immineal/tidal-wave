// SPDX-License-Identifier: GPL-3.0-or-later

#include "Player.h"
#include <QDebug>
#include <QUrl>
#include <QTimer>
#include <QNetworkReply>
#include <QSettings>
#include <QDataStream>
#include <QDir>
#include <QMediaDevices>
#include <QSet>
#include "cast/CastSession.h"
#include "player/DashFetcher.h"
#include "ui/Prefs.h"
#include "player/SpectrumAnalyzer.h"
#if TIDALWAVE_HAS_BUFFER_OUTPUT
#include <QAudioBufferOutput>
#endif
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

    setSpectrumAnalyzer(SpectrumAnalyzer::instance());

    // Defer audio device init until after the event loop starts to avoid
    // a PipeWire pw_thread_loop_lock deadlock under -O3 optimisation.
    QTimer::singleShot(0, this, &Player::initAudio);
}

void Player::initAudio() {
    m_player   = new QMediaPlayer(this);
    // Bound to the resolved device: a default-constructed output latches onto
    // the default at construction and never notices a later change.
    m_audioOut = new QAudioOutput(resolveAudioDevice(), this);
    m_player->setAudioOutput(m_audioOut);
    m_audioOut->setVolume(m_pendingVolume);
    m_audioOut->setMuted(m_pendingMuted);

    // Needs an instance: audioOutputsChanged is not a static signal.
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
        if (dur > 0 && pos >= kPreloadAfterMs)
            preloadNext();
        emit positionChanged(pos);
    });
    connect(m_player, &QMediaPlayer::durationChanged,
            this, &Player::durationChanged);

    // A session restored from the constructor had no player yet; load it now.
    if (m_restorePending) {
        m_restorePending = false;
        startLoad(m_index);
    }

    applySpectrumTap();
}

Player::~Player() {
    // The debounced save may still be pending, and position() needs the player.
    savePlaybackState();
    cancelPreload();
    delete m_dash;
    m_dash = nullptr;
    // remove() as well as delete: autoRemove is off on these, so deleting the
    // object alone closes the file and leaves the bytes on disk.
    if (m_mpdTempFile) {
        m_mpdTempFile->remove();
        delete m_mpdTempFile;
        m_mpdTempFile = nullptr;
    }
    // Detach and delete the output here: one destroyed after its player, by
    // QObject's child cleanup, calls back into an object that is already gone.
    if (m_player) m_player->setAudioOutput(nullptr);
    delete m_audioOut;
    m_audioOut = nullptr;
#if TIDALWAVE_HAS_BUFFER_OUTPUT
    // Same ordering rule as the output above.
    if (m_player) m_player->setAudioBufferOutput(nullptr);
    delete m_bufferOut;
    m_bufferOut = nullptr;
#endif
}

// ─── Audio output routing ──────────────────────────────────
// A pick in Settings, a moved system default and an unplugged device all end
// up in applyAudioDevice(). A plain ALSA backend may never emit the change
// signal, so the fallback to the default must work without it.

void Player::setPrefs(Prefs *prefs) {
    if (m_prefs == prefs) return;
    if (m_prefs) disconnect(m_prefs, &Prefs::audioDeviceChanged, this, nullptr);
    m_prefs = prefs;
    if (m_prefs) {
        connect(m_prefs, &Prefs::audioDeviceChanged, this, [this] { applyAudioDevice(); });
    }
    applyAudioDevice();
    // The analyser reads its switch off this object by property name.
    if (m_spectrum) m_spectrum->setPrefsSource(m_prefs);
}

QAudioDevice Player::resolveAudioDevice() const {
    const QString wanted = m_prefs ? m_prefs->audioDevice() : QString();
    if (!wanted.isEmpty()) {
        const QList<QAudioDevice> outs = QMediaDevices::audioOutputs();
        for (const QAudioDevice &d : outs) {
            if (QString::fromUtf8(d.id()) == wanted) return d;
        }
        // The chosen device is gone; the default beats going silent.
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
        // An empty id collides with the sentinel; a repeat would duplicate a row.
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
    // Deferred a turn: the backend emits this while PipeWire holds its thread
    // loop lock, and a rebind destroys a QAudioOutput, which takes the same
    // lock. applyAudioDevice() rebinds only if our device changed.
    QTimer::singleShot(0, this, [this] {
        applyAudioDevice();
        // After the rebind, so listeners read the new active device.
        emit audioDevicesChanged();
    });
}

void Player::applyAudioDevice() {
    if (!m_player || !m_audioOut) return;   // initAudio() resolves it on the way up
    const QAudioDevice target = resolveAudioDevice();
    if (m_audioOut->device() == target) return;
    rebindAudioOutput(target);
}

// ─── The spectrum tap ──────────────────────────────────────────────────────
// With no QAudioBufferOutput attached QMediaPlayer produces no buffers, so
// the tap costs nothing while the preference is off. A tap attached mid-track
// delivers nothing until the next source is set; detaching is immediate.

void Player::setSpectrumAnalyzer(SpectrumAnalyzer *analyzer) {
    if (m_spectrum == analyzer) return;
    if (m_spectrum) disconnect(m_spectrum, nullptr, this, nullptr);
    m_spectrum = analyzer;
    if (m_spectrum) {
        connect(m_spectrum, &SpectrumAnalyzer::enabledChanged,
                this, [this] { applySpectrumTap(); });
        if (m_prefs) m_spectrum->setPrefsSource(m_prefs);
    }
    applySpectrumTap();
}

bool Player::spectrumTapAttached() const {
#if TIDALWAVE_HAS_BUFFER_OUTPUT
    return m_bufferOut != nullptr;
#else
    return false;
#endif
}

void Player::applySpectrumTap() {
#if TIDALWAVE_HAS_BUFFER_OUTPUT
    if (!m_player) return;   // initAudio() calls this again on the way up
    const bool want = m_spectrum && m_spectrum->enabled();
    if (want == (m_bufferOut != nullptr)) return;

    if (want) {
        m_bufferOut = new QAudioBufferOutput(this);
        // Queued: the backend may emit this from its decoding thread and the
        // analyser is main-thread only. QAudioBuffer is implicitly shared.
        connect(m_bufferOut, &QAudioBufferOutput::audioBufferReceived,
                m_spectrum.data(), &SpectrumAnalyzer::processBuffer,
                Qt::QueuedConnection);
        m_player->setAudioBufferOutput(m_bufferOut);
    } else {
        m_player->setAudioBufferOutput(nullptr);
        delete m_bufferOut;
        m_bufferOut = nullptr;
        if (m_spectrum) m_spectrum->reset();
    }
#endif
}

Player::AudioState Player::captureAudioState() const {
    AudioState s;
    // The local player's state: playing() and position() report the cast
    // device while casting, and the swap disturbs the local side.
    s.position = m_player ? m_player->position() : 0;
    s.playing  = m_player && m_player->playbackState() == QMediaPlayer::PlayingState;
    s.volume   = m_audioOut ? m_audioOut->volume()  : m_pendingVolume;
    s.muted    = m_audioOut ? m_audioOut->isMuted() : m_pendingMuted;
    return s;
}

void Player::restoreAudioState(const AudioState &state) {
    if (m_audioOut) {
        m_audioOut->setVolume(state.volume);
        // The live value: while casting the local output is force-muted and
        // must stay that way across a swap, whatever m_pendingMuted says.
        m_audioOut->setMuted(state.muted);
    }
    if (!m_player) return;
    // A swap can drop the backend back to the start of the track. Seek back,
    // and never re-set the source: that would re-fetch the stream.
    if (state.position > 0 && m_player->position() != state.position && m_player->isSeekable())
        setPlayerPosition(state.position);
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

    // Detach, delete the old output outright, then attach. A destroyed output
    // unbinds whatever output the player holds at that moment, so attaching
    // first, or deleteLater, would leave playback with no sink.
    QAudioOutput *old = m_audioOut;
    m_audioOut = fresh;
    if (old) {
        m_player->setAudioOutput(nullptr);
        delete old;
    }
    m_player->setAudioOutput(fresh);

    restoreAudioState(state);
    m_rebinding = false;

    // If the swap changed the state after all, tell the UI.
    if (!casting()) {
        const bool playing = m_player->playbackState() == QMediaPlayer::PlayingState;
        if (playing != state.playing) emit playingChanged(playing);
        if (m_player->position() != state.position) emit positionChanged(m_player->position());
    }
}

bool   Player::playing()  const { return casting() ? m_castPlaying  : (m_player && m_player->playbackState() == QMediaPlayer::PlayingState); }
qint64 Player::position() const {
    if (casting()) return m_castPosition;
    // A position owed to media that is not loaded yet: a restored session,
    // or a seek that raced the stream fetch.
    if (m_pendingSeek > 0) return m_pendingSeek;
    return m_player ? m_player->position() : 0;
}
qint64 Player::duration() const { return casting() ? m_castDuration : (m_player ? m_player->duration() : 0); }
double Player::volume()   const { return m_audioOut ? m_audioOut->volume() : m_pendingVolume; }
bool   Player::muted()    const { return m_audioOut ? m_audioOut->isMuted() : m_pendingMuted; }

QVariantMap Player::currentTrackMap() const {
    if (m_index < 0 || m_index >= m_queue.count()) return {};
    return m_queue[m_index].track;
}

void Player::setLoading(bool l) {
    if (m_loading == l) return;
    m_loading = l;
    emit loadingChanged(l);
}

void Player::setIndex(int i) {
    if (m_index == i) return;
    m_index = i;
    emit currentIndexChanged(m_index);
    schedulePersist();
}

void Player::setManualCount(int n) {
    if (m_manualCount == n) return;
    m_manualCount = n;
    emit manualCountChanged(m_manualCount);
}

// ─── The queue ─────────────────────────────────────
// One list in playback order: [0, m_index) played, m_index playing, the next
// m_manualCount rows queued by hand, then the rest of the context. A plain
// advance moves m_index only, so no view copies the queue on a track change.

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

    // The manual queue is the user's own list and survives a new context.
    // Rows behind the cursor have played and go with the old one.
    QList<Entry> manual;
    if (m_manualCount > 0)
        manual = m_queue.mid(m_index + 1, m_manualCount);

    m_queue.clear();
    m_queue.reserve(tracks.count() + manual.count());
    for (int i = 0; i < tracks.count(); ++i)
        m_queue.append(Entry{ tracks.at(i).toMap(), false, i });

    setManualCount(0);
    setIndex(qBound(0, startIndex, m_queue.count() - 1));
    // Rows before the starting point keep their order.
    if (m_shuffle) reorderContext();

    for (int i = 0; i < manual.count(); ++i)
        m_queue.insert(m_index + 1 + i, manual.at(i));
    setManualCount(manual.count());

    emit queueChanged();
    schedulePersist();
    loadAndPlay(m_index);
}

void Player::setPlaybackSource(const QString &type, const QString &id, const QString &name) {
    m_pendingSource = true;   // consumed by the playTracks() that follows
    if (m_sourceType == type && m_sourceId == id && m_sourceName == name) return;
    m_sourceType = type;
    m_sourceId   = id;
    m_sourceName = name;
    emit sourceChanged();
    // contextName/contextType notify on queueChanged, which the playTracks()
    // that follows emits. Emitting it here too would publish the queue twice.
}

// ─── The manual queue ──────────────────────────────

void Player::insertManual(const QVariantList &tracks, int at) {
    if (tracks.isEmpty()) return;
    const int base = m_index + 1 + qBound(0, at, m_manualCount);
    for (int i = 0; i < tracks.count(); ++i) {
        QVariantMap t = tracks.at(i).toMap();
        // Legacy marker: the old Queue panel styles a row by reading this.
        t[QStringLiteral("_userQueued")] = true;
        m_queue.insert(base + i, Entry{ t, true, -1 });
    }
    setManualCount(m_manualCount + tracks.count());
    emit queueChanged();
    schedulePersist();
}

void Player::playNext(const QVariantList &tracks) {
    insertManual(tracks, 0);
}

void Player::addToQueue(const QVariantList &tracks) {
    insertManual(tracks, m_manualCount);
}

void Player::removeManual(int index) {
    if (index < 0 || index >= m_manualCount) return;
    m_queue.removeAt(m_index + 1 + index);
    setManualCount(m_manualCount - 1);
    emit queueChanged();
    schedulePersist();
}

void Player::moveManual(int from, int to) {
    if (from < 0 || from >= m_manualCount ||
        to   < 0 || to   >= m_manualCount || from == to) return;
    m_queue.move(m_index + 1 + from, m_index + 1 + to);
    emit queueChanged();
    schedulePersist();
}

void Player::clearManual() {
    if (m_manualCount <= 0) return;
    m_queue.remove(m_index + 1, m_manualCount);
    setManualCount(0);
    emit queueChanged();
    schedulePersist();
}

void Player::jumpToManual(int index) {
    if (index < 0 || index >= m_manualCount) return;
    cancelPreload();
    const int start = m_index + 1;
    // Rows above it in the manual queue were passed over, so they are dropped.
    if (index > 0) m_queue.remove(start, index);
    setManualCount(m_manualCount - index - 1);
    setIndex(start);
    emit queueChanged();
    loadAndPlay(m_index);
}

void Player::jumpToContext(int index) {
    if (index < 0) return;
    jumpToQueue(m_index + m_manualCount + 1 + index);
}

void Player::jumpToPlayed(int index) {
    if (index < 0 || index >= qMax(0, m_index)) return;
    jumpToQueue(index);
}

QVariantList Player::queuePlayed() const {
    QVariantList out;
    const int end = qMax(0, m_index);
    out.reserve(end);
    for (int i = 0; i < end; ++i) out.append(m_queue.at(i).track);
    return out;
}

QVariantList Player::queueManual() const {
    QVariantList out;
    out.reserve(m_manualCount);
    for (int i = 0; i < m_manualCount; ++i)
        out.append(m_queue.at(m_index + 1 + i).track);
    return out;
}

QVariantList Player::queueContext() const {
    QVariantList out;
    const int first = m_index + 1 + m_manualCount;
    out.reserve(qMax(0, m_queue.count() - first));
    for (int i = first; i < m_queue.count(); ++i) out.append(m_queue.at(i).track);
    return out;
}

// ─── Flat view over the same queue (deprecated) ────

void Player::appendQueue(const QVariantList &tracks) {
    addToQueue(tracks);
}

void Player::jumpToQueue(int index) {
    if (index < 0 || index >= m_queue.count()) return;
    // A row inside the manual run is a manual jump whichever list the caller
    // was looking at, and a manual jump drops what it skipped.
    if (m_manualCount > 0 && index > m_index && index <= m_index + m_manualCount) {
        jumpToManual(index - m_index - 1);
        return;
    }
    cancelPreload();
    if (index == m_index) { loadAndPlay(m_index); return; }
    if (relocateTo(index)) emit queueChanged();
    loadAndPlay(m_index);
}

void Player::clearQueue() {
    cancelPreload();
    if (m_player) m_player->stop();
    m_queue.clear();
    setManualCount(0);
    setIndex(-1);
    m_currentTrack = Track{};
    setLoading(false);
    emit currentTrackChanged();
    emit queueChanged();
    schedulePersist();
}

void Player::removeFromQueue(int index) {
    if (index < 0 || index >= m_queue.count()) return;
    m_queue.removeAt(index);
    if (index < m_index) {
        setIndex(m_index - 1);
    } else if (index == m_index) {
        if (m_queue.isEmpty()) {
            if (m_player) m_player->stop();
            setIndex(-1);
            m_currentTrack = Track{};
            setLoading(false);
            emit currentTrackChanged();
        } else {
            setIndex(qMin(m_index, m_queue.count() - 1));
            loadAndPlay(m_index);
        }
    }
    normalizeManualSpan();
    emit queueChanged();
    schedulePersist();
}

void Player::moveQueueItem(int from, int to) {
    if (from < 0 || from >= m_queue.count() ||
        to   < 0 || to   >= m_queue.count() || from == to) return;
    m_queue.move(from, to);
    if      (m_index == from)                          setIndex(to);
    else if (from < m_index && to >= m_index)          setIndex(m_index - 1);
    else if (from > m_index && to <= m_index)          setIndex(m_index + 1);
    normalizeManualSpan();
    emit queueChanged();
    schedulePersist();
}

QVariantMap Player::queueTrackAt(int index) const {
    if (index < 0 || index >= m_queue.count()) return {};
    return m_queue.at(index).track;
}

QVariantList Player::queueTracks() const {
    QVariantList out;
    out.reserve(m_queue.count());
    for (const auto &e : m_queue)
        out.append(e.track);
    return out;
}

QVariantList Player::upcomingTracks(int max) const {
    QVariantList out;
    if (m_queue.isEmpty() || m_index < 0) return out;
    for (int i = m_index + 1; i < m_queue.count(); ++i) {
        out.append(m_queue.at(i).track);
        if (max >= 0 && out.count() >= max) break;
    }
    return out;
}

QVariantList Player::playbackOrderTracks() const {
    if (!m_shuffle) return queueTracks();
    // Already in playback order: rotate to the playing row and tag each index.
    QVariantList out;
    const int n = m_queue.count();
    if (n == 0) return out;
    out.reserve(n);
    const int start = (m_index >= 0 && m_index < n) ? m_index : 0;
    for (int k = 0; k < n; ++k) {
        const int i = (start + k) % n;
        QVariantMap m = m_queue.at(i).track;
        m[QStringLiteral("_queueIndex")] = i;
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
    // Nothing is loaded behind the current track for play() to start.
    if (m_loadOwed) { loadAndPlay(m_index); return; }
    if (m_player->playbackState() == QMediaPlayer::PlayingState)
        m_player->pause();
    else
        m_player->play();
}

void Player::next() {
    if (!m_player) return;
    const int n = nextIndex();
    if (n < 0) { m_player->stop(); return; }
    if (n == m_index) { loadAndPlay(m_index); return; }   // repeat one
    if (n == m_index + 1 && m_manualCount > 0) {
        // Stepping onto the head of the manual queue consumes it.
        setManualCount(m_manualCount - 1);
        setIndex(n);
        emit queueChanged();
    } else if (relocateTo(n)) {
        emit queueChanged();
    }
    loadAndPlay(m_index);
}

void Player::previous() {
    if (position() > 3000) { seek(0); return; }
    const int p = previousIndex();
    if (p < 0) { seek(0); return; }
    if (relocateTo(p)) emit queueChanged();
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
    if (!m_player) return;
    setPlayerPosition(ms);
    // Nothing is loaded to seek inside yet, so hold it until something is.
    m_pendingSeek = (m_player->duration() > 0) ? 0 : qMax<qint64>(0, ms);
}

void Player::setPlayerPosition(qint64 ms) {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    // Qt 6.4 stops reading a file once it has read to its end, and a seek
    // while playing does not start it again. Resuming from a pause does.
    if (m_player->playbackState() == QMediaPlayer::PlayingState) {
        m_seekToggling = true;
        m_player->pause();
        m_player->setPosition(ms);
        m_player->play();
        m_seekToggling = false;
        // If it did not come back up, the UI has to hear of it.
        if (!m_rebinding && m_player->playbackState() != QMediaPlayer::PlayingState)
            emit playingChanged(false);
        return;
    }
#endif
    m_player->setPosition(ms);
}

void Player::setVolume(double v) {
    m_pendingVolume = qBound(0.0, v, 1.0);
#ifdef Q_OS_LINUX
    if (casting() && m_castSession) m_castSession->setVolume(m_pendingVolume);
#endif
    if (m_audioOut) m_audioOut->setVolume(m_pendingVolume);
    emit volumeChanged(m_pendingVolume);
    schedulePersist();
}

void Player::setMuted(bool m) {
    m_pendingMuted = m;
    // While casting the local output stays force-muted; endCast() re-applies
    // the preference.
    if (m_audioOut && !casting()) m_audioOut->setMuted(m);
    emit mutedChanged(m);
    schedulePersist();
}

void Player::setShuffle(bool s) {
    m_shuffle = s;
    reorderContext();
    emit shuffleChanged(s);
    emit queueChanged();
    schedulePersist();
}

void Player::setRepeatMode(int m) {
    m_repeatMode = m;
    emit repeatModeChanged(m);
    schedulePersist();
}

// ─── Internals ─────────────────────────────────────

int Player::nextIndex() const {
    if (m_queue.isEmpty()) return -1;
    if (m_repeatMode == 2) return m_index;   // repeat one
    if (m_index < m_queue.count() - 1) return m_index + 1;
    // Repeat applies to the context; a manual row that has played stays spent.
    if (m_repeatMode == 1) return firstContextRow();
    return -1;
}

int Player::previousIndex() const {
    return m_index > 0 ? m_index - 1 : -1;
}

int Player::firstContextRow() const {
    for (int i = 0; i < m_queue.count(); ++i)
        if (!m_queue.at(i).manual) return i;
    return m_queue.isEmpty() ? -1 : 0;
}

bool Player::relocateTo(int target) {
    if (target < 0 || target >= m_queue.count() || target == m_index) return false;
    const int from = m_index;
    bool structural = false;

    // Lift the manual queue out; it goes back right after the new current row.
    QList<Entry> block;
    if (m_manualCount > 0) {
        block = m_queue.mid(from + 1, m_manualCount);
        m_queue.remove(from + 1, m_manualCount);
        if (target > from) target -= m_manualCount;   // it moved down with the gap
        structural = true;
    }

    // Stepping back over manual rows that have played: a consumed manual row
    // is gone, so it must not be walked into again on the way forward.
    if (target < from) {
        for (int p = qMin(from, m_queue.count() - 1); p > target; --p) {
            if (m_queue.at(p).manual) {
                m_queue.removeAt(p);
                structural = true;
            }
        }
    }

    for (int i = 0; i < block.count(); ++i)
        m_queue.insert(target + 1 + i, block.at(i));

    setIndex(target);
    return structural;
}

void Player::normalizeManualSpan() {
    int n = 0;
    while (m_index + 1 + n < m_queue.count() && m_queue.at(m_index + 1 + n).manual) ++n;
    for (int i = m_index + 1 + n; i < m_queue.count(); ++i) {
        if (!m_queue.at(i).manual) continue;
        // A manual row that a flat mutator dragged out of the run becomes a
        // context row, or it would form a second, invisible manual queue.
        m_queue[i].manual  = false;
        m_queue[i].natural = (i > 0) ? m_queue.at(i - 1).natural : -1;
        m_queue[i].track.remove(QStringLiteral("_userQueued"));
    }
    setManualCount(n);
}

void Player::reorderContext() {
    const int from = qMax(0, m_index + 1 + m_manualCount);
    if (from >= m_queue.count()) return;
    if (m_shuffle) {
        // Fisher-Yates over the upcoming context only.
        for (int i = m_queue.count() - 1; i > from; --i) {
            const int j = from + int(QRandomGenerator::global()->bounded(i - from + 1));
            m_queue.swapItemsAt(i, j);
        }
    } else {
        // The context's own order. Stable, so rows without a position stay put.
        std::stable_sort(m_queue.begin() + from, m_queue.end(),
                         [](const Entry &a, const Entry &b) { return a.natural < b.natural; });
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
    // The joined artists string becomes a single Artist.
    Artist a;
    a.name = m["artists"].toString();
    a.id   = m["artistId"].toLongLong();
    t.artists.append(a);
    return t;
}

// A DashFetcher reports from inside its own callback, so deleting it there
// would destroy an object whose method is still on the stack.
static void disposeDash(DashFetcher *dash, QObject *ctx) {
    if (!dash) return;
    QTimer::singleShot(0, ctx, [dash] { delete dash; });
}

void Player::loadAndPlay(int index) {
    if (index < 0 || index >= m_queue.count()) return;
    // The user asked for this track, so a restore still waiting on its own
    // load is over: this one plays, and its failures are reported.
    m_restorePaused = false;
    m_restoreSkips  = false;
    startLoad(index);
}

void Player::startLoad(int index) {
    if (!m_player || index < 0 || index >= m_queue.count()) return;

    // Replies still out for an earlier load, the download aborted below
    // among them, find a newer number and drop out.
    const quint64 serial = ++m_loadSerial;

    // stop() and setSource({}) both pass through onMediaStatusChanged, which
    // lowers the loading flag. Raised before them it would be lowered again
    // for the whole of the next track's fetch.
    m_player->stop();
    m_player->setSource(QUrl());
    setLoading(true);

    if (m_activeDownload) {
        auto *dl = m_activeDownload;
        m_activeDownload = nullptr;
        dl->abort();
        dl->deleteLater();
    }

    if (m_dash) {
        auto *d = m_dash;
        m_dash = nullptr;
        delete d;          // aborts whatever segments were still coming
    }

    if (m_mpdTempFile) {
        m_mpdTempFile->remove();
        delete m_mpdTempFile;
        m_mpdTempFile = nullptr;
    }

    m_streamedQuality.clear();
    m_loadOwed = false;
    // A position held for a track that never loaded does not carry to another.
    if (m_queue[index].track.value("id").toLongLong() != m_currentTrack.id)
        m_pendingSeek = 0;
    m_currentTrack = trackFromMap(m_queue[index].track);
    emit currentTrackChanged();

    // Track recently played (max 20 unique entries)
    QVariantMap trackMap = m_queue[index].track;
    qlonglong trackId = trackMap.value("id").toLongLong();
    for (int i = m_recentlyPlayed.count() - 1; i >= 0; --i) {
        if (m_recentlyPlayed.at(i).value("id").toLongLong() == trackId)
            m_recentlyPlayed.removeAt(i);
    }
    m_recentlyPlayed.prepend(trackMap);
    if (m_recentlyPlayed.count() > 20)
        m_recentlyPlayed = m_recentlyPlayed.mid(0, 20);
    emit recentlyPlayedChanged();

    qint64 uid = m_client->userId();
    if (uid > 0) {
        QVariantList saveList;
        for (const auto &m : m_recentlyPlayed) {
            saveList.append(m);
        }
        QSettings settings;
        settings.setValue(QStringLiteral("user_%1/playback/recentlyPlayed").arg(uid), saveList);
    }

    // While casting, hand the current track to the cast device; CastManager
    // prepares and LOADs it.
    if (casting()) {
        setLoading(false);
        emit castTrackChanged();
        return;
    }

    // A new track is starting, so a failed preload may be tried again.
    m_preloadFailedIndex = -1;

    // Matched by track id. The queue can be reordered, inserted into and
    // reshuffled while a preload is in flight without cancelling it, so an
    // index match can mean another track's bytes.
    if (m_preloadReady && m_preloadTempFile && m_preloadTrackId != 0
        && m_preloadTrackId == m_currentTrack.id) {
        m_mpdTempFile     = m_preloadTempFile;
        m_preloadTempFile = nullptr;
        m_streamedQuality = m_preloadQuality;
        m_preloadIndex    = -1;
        m_preloadTrackId  = 0;
        m_preloadReady    = false;
        m_preloadQuality  = {};
        emit currentTrackChanged();
        // Still loading until the media status says the file is open.
        m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
        beginPlayback();
        return;
    }

    cancelPreload();

    qlonglong loadingTrackId = m_currentTrack.id;
    m_client->fetchStreamManifest(loadingTrackId,
        [this, loadingTrackId, serial](StreamManifest manifest, QString err) {
            if (serial != m_loadSerial || m_currentTrack.id != loadingTrackId) {
                return;
            }
            if (!err.isEmpty()) {
                setLoading(false);
                // A restored queue can name a track that no longer streams.
                // Step over it without an error dialog at startup.
                if (m_restoreSkips && manifest.unavailable) { skipUnplayableTrack(); return; }
                // Nothing is loaded behind this track, so the next play asks again.
                m_loadOwed = true;
                if (m_restoreSkips) {
                    // The request failed, as it does with no network. That is no
                    // verdict on the track, so the restore ends with the queue whole.
                    m_restorePaused = false;
                    m_restoreSkips  = false;
                    return;
                }
                emit error(tr("Could not load this track for playback. %1").arg(err));
                return;
            }
            // Something resolved: the restore is over, later failures are reported.
            m_restoreSkips = false;
            m_streamedQuality = manifest.codec;
            emit currentTrackChanged();

            if (manifest.type == StreamManifest::BTS) {
                m_activeDownload = m_client->fetchRaw(QUrl(manifest.url), [this, loadingTrackId, serial](QByteArray data, QString err) {
                    if (serial != m_loadSerial) return;
                    m_activeDownload = nullptr;
                    if (m_currentTrack.id != loadingTrackId) {
                        return;
                    }
                    if (!err.isEmpty() || data.isEmpty()) {
                        failLoad(err.isEmpty()
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
                        // Casting may have started while this fetch was in flight.
                        if (casting()) { setLoading(false); emit castTrackChanged(); return; }
                        m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
                        beginPlayback();
                    } else {
                        failLoad(tr("Could not save the audio to a temporary file. "
                                    "Check that there is free disk space."));
                    }
                });
            } else {
                // DASH (lossless): the segments are joined into a plain fragmented
                // MP4, because libavformat's DASH demuxer may be missing.
                auto *fetcher = new DashFetcher(m_client, manifest.url);
                if (!fetcher->isValid() || !fetcher->openedTempFile()) {
                    const bool manifestWasReadable = fetcher->isValid();
                    delete fetcher;
                    failLoad(manifestWasReadable
                        ? tr("Could not save the audio to a temporary file. "
                             "Check that there is free disk space.")
                        : tr("Could not read the lossless stream details for this track."));
                    return;
                }
                m_dash = fetcher;
                fetcher->start([this, fetcher, loadingTrackId, serial](QTemporaryFile *file, const QString &dashErr) {
                    // Dispose this callback's fetcher, whatever the member holds.
                    if (m_dash == fetcher) m_dash = nullptr;
                    disposeDash(fetcher, this);
                    if (serial != m_loadSerial || m_currentTrack.id != loadingTrackId) {
                        if (file) { file->remove(); delete file; }
                        return;
                    }
                    if (!file) {
                        failLoad(dashErr.isEmpty()
                            ? tr("Could not download the audio for this track. No data came back.")
                            : tr("Could not download the audio for this track. %1").arg(dashErr));
                        return;
                    }
                    m_mpdTempFile = file;
                    // Casting may have started while the segments were in flight.
                    if (casting()) { setLoading(false); emit castTrackChanged(); return; }
                    m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
                    beginPlayback();
                });
            }
        });
}

void Player::failLoad(const QString &msg) {
    setLoading(false);
    m_loadOwed = true;
    emit error(msg);
}

void Player::onMediaStatusChanged(QMediaPlayer::MediaStatus status) {
    switch (status) {
    case QMediaPlayer::LoadingMedia:
    case QMediaPlayer::BufferingMedia:
        setLoading(true); break;
    case QMediaPlayer::BufferedMedia:
    case QMediaPlayer::LoadedMedia:
        setLoading(false);
        // A held position can only be applied once the media has a duration.
        if (m_pendingSeek > 0 && m_player) {
            const qint64 to = m_pendingSeek;
            m_pendingSeek = 0;
            setPlayerPosition(to);
        }
        break;
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
    if (m_seekToggling) return;   // the state a seek started in is the one it ends in
    // Audio is coming out, so the load is over even if a media status was
    // missed. After the guard above: a rebind's transient Playing is no load.
    if (state == QMediaPlayer::PlayingState) setLoading(false);
    emit playingChanged(state == QMediaPlayer::PlayingState);
    schedulePersist();         // a pause is the position worth coming back to
}

void Player::onErrorOccurred(QMediaPlayer::Error, const QString &msg) {
    setLoading(false);
    qWarning() << "Player error:" << msg;
    emit error(msg);
}

void Player::cancelPreload() {
    // Before the abort: it runs the download's callback at once, and with no
    // row claimed that callback drops out and records no failed preload.
    m_preloadIndex = -1;
    if (m_preloadDownload) {
        auto *dl = m_preloadDownload;
        m_preloadDownload = nullptr;
        dl->abort();
        dl->deleteLater();
    }
    if (m_preloadDash) {
        auto *d = m_preloadDash;
        m_preloadDash = nullptr;
        delete d;          // aborts whatever segments were still coming
    }
    if (m_preloadTempFile) {
        m_preloadTempFile->remove();
        delete m_preloadTempFile;
        m_preloadTempFile = nullptr;
    }
    m_preloadTrackId = 0;
    m_preloadReady   = false;
    m_preloadQuality = {};
}

void Player::preloadGaveUp(int next) {
    if (m_preloadIndex == next) m_preloadIndex = -1;
    m_preloadTrackId     = 0;
    m_preloadFailedIndex = next;
}

void Player::preloadNext() {
    int next = nextIndex();
    if (next < 0 || next == m_preloadIndex || next == m_preloadFailedIndex) return;
    // Repeat-one: the playing row's bytes are already on disk.
    if (next == m_index) return;

    cancelPreload();
    m_preloadIndex = next;

    qlonglong trackId = m_queue[next].track.value("id").toLongLong();

    m_client->fetchStreamManifest(trackId, [this, next, trackId](StreamManifest manifest, QString err) {
        if (m_preloadIndex != next) return;
        if (!err.isEmpty()) { preloadGaveUp(next); return; }

        m_preloadQuality = manifest.codec;

        if (manifest.type == StreamManifest::BTS) {
            m_preloadDownload = m_client->fetchRaw(QUrl(manifest.url), [this, next, trackId](QByteArray data, QString dlErr) {
                m_preloadDownload = nullptr;
                if (m_preloadIndex != next) return;
                if (!dlErr.isEmpty() || data.isEmpty()) { preloadGaveUp(next); return; }
                auto *f = new QTemporaryFile(QDir::tempPath() + QStringLiteral("/tidal-wave-XXXXXX.mp4"));
                f->setAutoRemove(false);
                if (f->open()) {
                    f->write(data); f->flush(); f->close();
                    m_preloadTempFile = f;
                    m_preloadTrackId  = trackId;
                    m_preloadReady    = true;
                } else {
                    // A full temp directory lands here. Silent: a failed preload
                    // costs a wait, and the live load reports the disk itself.
                    delete f;
                    preloadGaveUp(next);
                }
            });
        } else {
            // Same route as the live load above.
            auto *fetcher = new DashFetcher(m_client, manifest.url);
            if (!fetcher->isValid() || !fetcher->openedTempFile()) {
                delete fetcher;
                preloadGaveUp(next);
                return;
            }
            m_preloadDash = fetcher;
            fetcher->start([this, fetcher, next, trackId](QTemporaryFile *file, const QString &) {
                if (m_preloadDash == fetcher) m_preloadDash = nullptr;
                disposeDash(fetcher, this);
                if (m_preloadIndex != next || !file) {
                    if (file) { file->remove(); delete file; }
                    // Leave no index claiming a preload: the trigger guards on it,
                    // and a stale one would stop this track being tried again.
                    if (m_preloadIndex == next) preloadGaveUp(next);
                    return;
                }
                m_preloadTempFile = file;
                m_preloadTrackId  = trackId;
                m_preloadReady    = true;
            });
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
    // The tier names Tidal's own apps show.
    if (code == QStringLiteral("HI_RES_LOSSLESS")) return tr("Max");
    if (code == QStringLiteral("LOSSLESS"))        return tr("Lossless");
    if (code == QStringLiteral("HIGH"))            return tr("High");
    if (code == QStringLiteral("LOW"))             return tr("Low");
    return code;
}

void Player::beginCast(CastSession *session) {
    m_castSession = session;
    // Muted as well as paused: a stream fetch that resolves after this point
    // must not play locally alongside the cast.
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

    // Only on the way in: a userIdChanged mid-session (a token refresh that
    // re-announces the account) must not replace the queue that is playing.
    if (uid > 0 && m_queue.isEmpty()) restorePlaybackState();
}

// ─── Session persistence ───────────────────────────
// Writes are debounced into one timer and the queue goes out as a single
// value. Only a window around the cursor is stored, plus the manual queue up
// to its own limit.

namespace {
constexpr int kPersistBehind = 50;
constexpr int kPersistAhead  = 450;
constexpr int kPersistManual = 200;
// Refuses a blob that claims more rows than this build could ever have
// written, so a corrupt or foreign value cannot make the launch allocate.
constexpr int kPersistMaxRows = kPersistBehind + kPersistAhead + kPersistManual + 1;
constexpr quint32 kPersistFormat = 1;
}

QString Player::settingsPrefix() const {
    const qint64 uid = m_client ? m_client->userId() : 0;
    if (uid <= 0) return {};
    return QStringLiteral("user_%1/playback/").arg(uid);
}

void Player::schedulePersist() {
    if (m_suspendPersist) return;
    if (settingsPrefix().isEmpty()) return;   // signed out: nowhere to put it
    if (!m_persistTimer) {
        m_persistTimer = new QTimer(this);
        m_persistTimer->setSingleShot(true);
        // Long enough that dragging the volume slider or reordering the queue
        // writes once, short enough that a crash costs a couple of seconds.
        m_persistTimer->setInterval(1500);
        connect(m_persistTimer, &QTimer::timeout, this, &Player::savePlaybackState);
    }
    m_persistTimer->start();
}

QByteArray Player::serializeQueue() const {
    QList<int> rows;
    const int cur = m_index;
    const int head = qMax(cur, 0);
    for (int i = qMax(0, head - kPersistBehind); i < head; ++i) rows.append(i);

    int savedIndex = -1;
    if (cur >= 0 && cur < m_queue.count()) {
        savedIndex = rows.count();
        rows.append(cur);
    }
    const int manualKept = qMin(m_manualCount, kPersistManual);
    for (int i = 0; i < manualKept; ++i) rows.append(cur + 1 + i);

    const int ctxFirst = cur + 1 + m_manualCount;
    for (int i = qMax(0, ctxFirst); i < qMin(m_queue.count(), qMax(0, ctxFirst) + kPersistAhead); ++i)
        rows.append(i);

    QByteArray raw;
    QDataStream out(&raw, QIODevice::WriteOnly);
    out.setVersion(QDataStream::Qt_6_0);
    out << kPersistFormat << qint32(rows.count());
    for (int i : rows) {
        const Entry &e = m_queue.at(i);
        out << e.track << e.manual << qint32(e.natural);
    }
    out << qint32(savedIndex) << qint32(manualKept) << qint64(position());
    return qCompress(raw, 6);
}

void Player::savePlaybackState() {
    const QString p = settingsPrefix();
    if (p.isEmpty()) return;
    QSettings s;
    s.setValue(p + QStringLiteral("volume"),     volume());
    s.setValue(p + QStringLiteral("muted"),      muted());
    s.setValue(p + QStringLiteral("shuffle"),    m_shuffle);
    s.setValue(p + QStringLiteral("repeat"),     m_repeatMode);
    s.setValue(p + QStringLiteral("sourceType"), m_sourceType);
    s.setValue(p + QStringLiteral("sourceId"),   m_sourceId);
    s.setValue(p + QStringLiteral("sourceName"), m_sourceName);
    s.setValue(p + QStringLiteral("queue"),      serializeQueue());
}

void Player::restorePlaybackState() {
    const QString p = settingsPrefix();
    if (p.isEmpty()) return;
    QSettings s;

    // Nothing read back here is worth writing straight out again.
    m_suspendPersist = true;

    if (s.contains(p + QStringLiteral("volume")))
        setVolume(s.value(p + QStringLiteral("volume")).toDouble());
    if (s.contains(p + QStringLiteral("muted")))
        setMuted(s.value(p + QStringLiteral("muted")).toBool());

    // Set straight onto the members: the queue does not exist yet, so there
    // is nothing for setShuffle() to reorder.
    m_shuffle    = s.value(p + QStringLiteral("shuffle"), false).toBool();
    m_repeatMode = s.value(p + QStringLiteral("repeat"),  0).toInt();
    emit shuffleChanged(m_shuffle);
    emit repeatModeChanged(m_repeatMode);

    m_sourceType = s.value(p + QStringLiteral("sourceType")).toString();
    m_sourceId   = s.value(p + QStringLiteral("sourceId")).toString();
    m_sourceName = s.value(p + QStringLiteral("sourceName")).toString();
    emit sourceChanged();

    const QByteArray stored = s.value(p + QStringLiteral("queue")).toByteArray();
    // qUncompress warns on empty input, which is what a fresh install has.
    if (stored.size() < 5) { m_suspendPersist = false; return; }
    const QByteArray raw = qUncompress(stored);
    if (raw.isEmpty()) { m_suspendPersist = false; return; }

    QDataStream in(const_cast<QByteArray *>(&raw), QIODevice::ReadOnly);
    in.setVersion(QDataStream::Qt_6_0);
    quint32 format = 0;
    qint32  count  = 0;
    in >> format >> count;
    if (format != kPersistFormat || count < 0 || count > kPersistMaxRows) {
        m_suspendPersist = false;
        return;
    }

    QList<Entry> rows;
    rows.reserve(count);
    for (int i = 0; i < count; ++i) {
        Entry  e;
        qint32 natural = -1;
        in >> e.track >> e.manual >> natural;
        e.natural = natural;
        rows.append(e);
    }
    qint32 savedIndex = -1, savedManual = 0;
    qint64 savedPos   = 0;
    in >> savedIndex >> savedManual >> savedPos;
    if (in.status() != QDataStream::Ok) { m_suspendPersist = false; return; }

    // Each row's section, worked out before anything is dropped.
    enum Section { Behind, Current, Manual, Context };
    QList<int> section;
    section.reserve(rows.count());
    for (int i = 0; i < rows.count(); ++i) {
        if (savedIndex >= 0 && i == savedIndex)                       section.append(Current);
        else if (savedIndex >= 0 && i <  savedIndex)                  section.append(Behind);
        else if (i > savedIndex && i <= savedIndex + savedManual)     section.append(Manual);
        else                                                          section.append(Context);
    }

    // A row with no track id can never name a stream: drop it.
    for (int i = rows.count() - 1; i >= 0; --i) {
        if (rows.at(i).track.value(QStringLiteral("id")).toLongLong() > 0) continue;
        rows.removeAt(i);
        section.removeAt(i);
    }

    int newIndex = section.indexOf(int(Current));
    const bool sameTrack = newIndex >= 0;
    if (newIndex < 0 && savedIndex >= 0) {
        // The row that was playing did not survive: come back on the next one.
        for (int i = 0; i < section.count(); ++i) {
            if (section.at(i) == Manual || section.at(i) == Context) { newIndex = i; break; }
        }
    }
    int newManual = 0;
    for (int i = 0; i < section.count(); ++i)
        if (section.at(i) == Manual && i > newIndex) ++newManual;

    m_queue = rows;
    setManualCount(newManual);
    setIndex(newIndex);
    emit queueChanged();

    if (m_index >= 0 && m_index < m_queue.count()) {
        m_currentTrack = trackFromMap(m_queue.at(m_index).track);
        emit currentTrackChanged();
        // Only the track it was actually left on gets its position back.
        m_pendingSeek   = sameTrack ? qMax<qint64>(0, savedPos) : 0;
        m_restorePaused = true;
        m_restoreSkips  = true;
        if (m_player) startLoad(m_index);
        else          m_restorePending = true;   // initAudio() will pick it up
    }

    m_suspendPersist = false;
}

void Player::beginPlayback() {
    if (!m_player) return;
    if (m_restorePaused) {
        // A restored session stays paused: opening the app must not play.
        m_restorePaused = false;
        m_player->pause();
        return;
    }
    m_player->play();
}

void Player::skipUnplayableTrack() {
    if (m_index < 0 || m_index >= m_queue.count()) return;
    m_pendingSeek = 0;   // that position belonged to the row being dropped
    m_queue.removeAt(m_index);

    // If the head of the manual queue slides into place, it has been consumed.
    if (m_index < m_queue.count() && m_queue.at(m_index).manual && m_manualCount > 0)
        setManualCount(m_manualCount - 1);

    if (m_queue.isEmpty()) {
        if (m_player) m_player->stop();
        setIndex(-1);
        m_currentTrack  = Track{};
        m_restorePaused = false;
        m_restoreSkips  = false;
        setLoading(false);
        emit currentTrackChanged();
        emit queueChanged();
        return;
    }
    if (m_index >= m_queue.count()) setIndex(m_queue.count() - 1);
    emit queueChanged();
    startLoad(m_index);
}

