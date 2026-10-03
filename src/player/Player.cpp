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

    // The now-playing bars' analyser. Taken here rather than handed in,
    // because the Player is the only source of decoded audio there is; see
    // setSpectrumAnalyzer() in the header. Nothing is attached to the
    // QMediaPlayer until the preference is actually on.
    setSpectrumAnalyzer(SpectrumAnalyzer::instance());

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

    // The session was restored before there was anything to play it with:
    // handleUserIdChanged() runs from the constructor, this runs an event loop
    // turn later.
    if (m_restorePending) {
        m_restorePending = false;
        loadAndPlay(m_index);
    }

    // There is finally a QMediaPlayer to hang it off. Does nothing unless the
    // preference was already on when the app started.
    applySpectrumTap();
}

Player::~Player() {
    // Last chance to record where the user got to; the debounced save may
    // still be pending, and position() needs the player to still be here.
    savePlaybackState();
    cancelPreload();
    delete m_mpdTempFile;
    // Detach and drop the output here rather than leaving it to QObject's
    // child cleanup: an output destroyed after its player calls back into an
    // object that is already gone.
    if (m_player) m_player->setAudioOutput(nullptr);
    delete m_audioOut;
    m_audioOut = nullptr;
#if TIDALWAVE_HAS_BUFFER_OUTPUT
    // Same ordering rule as the output above: unhook it from the player
    // before destroying it, rather than leaving the two to be collected as
    // children in whatever order QObject picks.
    if (m_player) m_player->setAudioBufferOutput(nullptr);
    delete m_bufferOut;
    m_bufferOut = nullptr;
#endif
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
    // The analyser reads its own switch straight off the preferences object,
    // by property name rather than by type, so it needs no Prefs header and
    // this line does not have to change when the switch is added there.
    if (m_spectrum) m_spectrum->setPrefsSource(m_prefs);
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
    //
    // Deferred to the next event loop turn, NOT called directly. This signal
    // arrives from the multimedia backend while PipeWire still holds its
    // thread loop lock, and rebinding tears down a QAudioOutput, which takes
    // that same lock: the app deadlocks in pw_thread_loop_lock with the main
    // thread parked in futex_do_wait. It is the same hazard the deferral at
    // the top of this file exists for, reached by a different route, and it
    // only bites when a device actually changes, so it survived every test.
    // Letting the callback unwind first costs one turn and nothing else.
    QTimer::singleShot(0, this, [this] {
        applyAudioDevice();
        // After the rebind, so a listener that asks which device is active
        // gets the answer that is already true.
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
//
// Nothing here is in the audio path while the preference is off: with no
// QAudioBufferOutput attached, QMediaPlayer never produces the buffers in the
// first place, so "off" costs a null pointer check when the switch moves and
// nothing at all per frame.
//
// Switching it on mid-track does not light the bars until the next track, and
// that is a backend limitation rather than an oversight here. A
// QAudioBufferOutput attached to a QMediaPlayer that is already playing
// delivers nothing for the media already loaded - measured against ffmpeg on
// Qt 6.12, where seeking and a pause/play round trip both fail to shake it
// loose and only re-setting the source works. Re-setting the source means
// re-fetching the Tidal stream and a hole in the audio, which is far too much
// to pay for a visualiser, so the tap is attached and waits. The Settings row
// says so, and tests/tst_spectrum.cpp pins it.
//
// Switching it off is immediate: detaching mid-track is inaudible and the
// bars go back to their own animation in the same frame.

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
        // Queued, deliberately. The backend may emit this from its own
        // decoding thread, and the analyser is not thread-safe - nor should
        // it be, since what it feeds is QML bindings, which are the main
        // thread's business. QAudioBuffer is implicitly shared, so the
        // marshalling copies a refcount and not the audio.
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
qint64 Player::position() const {
    if (casting()) return m_castPosition;
    // A position that is owed to media which is not there yet: a restored
    // session, or a seek that raced the stream fetch. Reporting it rather than
    // 0 is what makes the scrubber come back where the user left it.
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
//
// Two sections, one order: what is playing, then the rows the user queued by
// hand, then the rest of the album, playlist or mix they started from.
//
// It is held as one list in exactly that order rather than as three lists,
// because the panel's sections and the older flat API are then slices of the
// same thing and cannot drift apart:
//
//     [0, m_index)                         already gone by  -> queuePlayed
//      m_index                             playing          -> currentTrack
//     (m_index, m_index + m_manualCount]   queued by hand   -> queueManual
//     (m_index + m_manualCount, count)     the rest of it   -> queueContext
//
// It also keeps the expensive case free. A plain advance moves m_index and
// touches nothing else, so no view has to copy the queue to learn that one
// row started playing; that copy is what made a 5000-row queue take 815ms per
// track change before (see tests/tst_queue_perf.cpp).
//
// Each row remembers whether the user put it there, and if not, where it sat
// in the context's own order. That is everything shuffle needs: it reorders
// the context rows still ahead of the cursor and leaves the manual ones
// alone, and unshuffling sorts them back by that remembered position.

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

    // The manual queue is the user's own list, not part of the context, so a
    // new album replaces everything else and leaves it standing. Rows already
    // behind the cursor are not lifted: those have played, and they belong to
    // the context that is going away.
    QList<Entry> manual;
    if (m_manualCount > 0)
        manual = m_queue.mid(m_index + 1, m_manualCount);

    m_queue.clear();
    m_queue.reserve(tracks.count() + manual.count());
    for (int i = 0; i < tracks.count(); ++i)
        m_queue.append(Entry{ tracks.at(i).toMap(), false, i });

    setManualCount(0);
    setIndex(qBound(0, startIndex, m_queue.count() - 1));
    // Only what is still to come. The rows before the starting point are the
    // part of the album the user skipped past, and shuffling those would be
    // shuffling history.
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
    // contextName/contextType read these and notify on queueChanged, which the
    // playTracks() immediately after this call emits. Raising it here as well
    // would republish the whole queue twice for one navigation.
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
    // Everything above it in the manual queue was deliberately passed over, so
    // it is dropped rather than left to turn up again two tracks later.
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
    // The list is already in playback order, so all this does is start it at
    // the row that is playing and hand back the index each row came from.
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
        // The row being stepped onto is the head of the manual queue, so it is
        // consumed: it stops being "next in queue" and becomes what plays.
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
    m_player->setPosition(ms);
    // Nothing is loaded to seek inside yet, so hold it until something is.
    // Without this a seek issued while the stream is still being fetched is
    // simply swallowed.
    m_pendingSeek = (m_player->duration() > 0) ? 0 : qMax<qint64>(0, ms);
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
    // While casting the local output is force-muted; don't override that here
    // (the preference is re-applied on endCast). Mute still updates the UI state.
    if (m_audioOut && !casting()) m_audioOut->setMuted(m);
    emit mutedChanged(m);
    schedulePersist();
}

void Player::setShuffle(bool s) {
    m_shuffle = s;
    reorderContext();
    emit shuffleChanged(s);
    // What is still to come is in a different order now, so every queue view
    // has to hear about it. The manual queue did not move, which is the point.
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
    // Repeat applies to the context, so a loop restarts at the context's first
    // row. A manual row that has already played is spent and stays spent.
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

    // Lift the manual queue out first, so nothing below has to reason about
    // where it currently sits. It goes back directly after the new current
    // row, because "the manual queue" means whatever the user put next, not a
    // fixed stretch of the list.
    QList<Entry> block;
    if (m_manualCount > 0) {
        block = m_queue.mid(from + 1, m_manualCount);
        m_queue.remove(from + 1, m_manualCount);
        if (target > from) target -= m_manualCount;   // it moved down with the gap
        structural = true;
    }

    // Stepping back over rows the user had queued and that have already played.
    // A consumed manual row is gone for good, so it must not be walked into a
    // second time on the way forward again.
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
        // A user-queued row that one of the flat mutators dragged out of the
        // run. Leaving the flag on would leave a second, invisible manual
        // queue behind it, so it becomes an ordinary context row where it lies.
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
        // Back to the order the album, playlist or mix came in. Stable, so the
        // handful of rows with no natural position of their own stay put.
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
    // Parse artists string back to artist struct (simplified)
    Artist a;
    a.name = m["artists"].toString();
    a.id   = m["artistId"].toLongLong();
    t.artists.append(a);
    return t;
}

void Player::loadAndPlay(int index) {
    if (!m_player || index < 0 || index >= m_queue.count()) return;

    // The order matters. stop() takes a playing track back to LoadedMedia and
    // setSource({}) takes it to NoMedia, and both of those go through
    // onMediaStatusChanged - so a flag raised before them is lowered again by
    // the teardown of the track being left, and the app reports "not loading"
    // for the whole of the next track's manifest fetch and download.
    m_player->stop();
    m_player->setSource(QUrl());
    setLoading(true);

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
        // Still loading, for the same reason as above: the file is local and
        // already on disk, but it is not open yet. The media status clears the
        // flag when it is, which is a few milliseconds of spinner rather than
        // one frame of "done" followed by LoadingMedia putting it back.
        m_player->setSource(QUrl::fromLocalFile(m_mpdTempFile->fileName()));
        beginPlayback();
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
                // A restored queue can name a track that no longer streams
                // (pulled from the catalogue, region-locked since). Step over
                // it rather than greeting the user with an error dialog the
                // moment the app opens.
                if (m_restoreSkips) { skipUnplayableTrack(); return; }
                emit error(tr("Could not load this track for playback. %1").arg(err));
                return;
            }
            // Something resolved, so the restore is over and later failures are
            // real failures again.
            m_restoreSkips = false;
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
                        if (m_restoreSkips) { skipUnplayableTrack(); return; }
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
                        beginPlayback();
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
                    beginPlayback();
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
        setLoading(false);
        // Where the restored track was left. It can only be applied once the
        // media has a duration, which is why it waits here and not in the
        // restore itself.
        if (m_pendingSeek > 0 && m_player) {
            const qint64 to = m_pendingSeek;
            m_pendingSeek = 0;
            m_player->setPosition(to);
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
    // Audio is coming out: the load is over whatever the media status did or
    // did not say. The backstop is what stops a missed status leaving the
    // spinner on top of a track that is audibly playing, and it belongs after
    // the guard above - a rebind's transient Playing is not a load finishing.
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

    qlonglong trackId = m_queue[next].track.value("id").toLongLong();

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

    // Only on the way in. A userIdChanged in the middle of a session (a token
    // refresh that re-announces the account) must not pull the queue out from
    // under whatever is playing.
    if (uid > 0 && m_queue.isEmpty()) restorePlaybackState();
}

// ─── Session persistence ───────────────────────────
//
// Volume, mute, shuffle, repeat, the queue and the position come back on the
// next launch of the same account, paused and exactly where they were left.
//
// Two things keep it off the critical path. The writes are debounced into one
// timer, because the state changes far more often than it is worth writing
// and the whole queue goes out as a single value. And only a window around
// the cursor is stored: a 5000-row playlist costs real time to serialise on
// every change and to parse again at launch, and nobody comes back to a
// session for row 4000 of it, so the far tail is dropped. What the user
// queued by hand is kept whole, because they chose it.

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
    // The rows worth keeping, in playback order, with where the cursor and
    // the manual run end up among them.
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
    // qUncompress warns on anything it cannot read, including nothing at all,
    // which is exactly what a fresh install has here.
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

    // Which section each row belonged to, worked out before anything is
    // dropped, so the cursor and the manual run can be found again afterwards.
    enum Section { Behind, Current, Manual, Context };
    QList<int> section;
    section.reserve(rows.count());
    for (int i = 0; i < rows.count(); ++i) {
        if (savedIndex >= 0 && i == savedIndex)                       section.append(Current);
        else if (savedIndex >= 0 && i <  savedIndex)                  section.append(Behind);
        else if (i > savedIndex && i <= savedIndex + savedManual)     section.append(Manual);
        else                                                          section.append(Context);
    }

    // A row with no track id cannot name a stream any more, whatever the
    // catalogue does: drop it here rather than stalling the restore on it.
    for (int i = rows.count() - 1; i >= 0; --i) {
        if (rows.at(i).track.value(QStringLiteral("id")).toLongLong() > 0) continue;
        rows.removeAt(i);
        section.removeAt(i);
    }

    int newIndex = section.indexOf(int(Current));
    const bool sameTrack = newIndex >= 0;
    if (newIndex < 0 && savedIndex >= 0) {
        // The row that was playing did not survive. Come back on the next one
        // that did rather than on nothing at all.
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
        if (m_player) loadAndPlay(m_index);
        else          m_restorePending = true;   // initAudio() will pick it up
    }

    m_suspendPersist = false;
}

void Player::beginPlayback() {
    if (!m_player) return;
    if (m_restorePaused) {
        // A restored session comes back where it was left and stops there.
        // Opening the app must never start making noise on its own.
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

    // Whatever slides into place takes over as the current row. If that is the
    // head of the manual queue, it has been consumed rather than passed over.
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
    loadAndPlay(m_index);
}

