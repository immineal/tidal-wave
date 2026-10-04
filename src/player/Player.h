#pragma once
#include <QObject>
#include <QMediaPlayer>
#include <QAudioOutput>
#include <QAudioDevice>
#include <QPointer>
#include <QVariantMap>
#include <QVariantList>
#include <QTemporaryFile>
#include "api/TidalClient.h"
#include "api/Models.h"
// For TIDALWAVE_HAS_BUFFER_OUTPUT and the analyser type below.
#include "player/SpectrumAnalyzer.h"

class QNetworkReply;
class QMediaDevices;
class DashFetcher;
class QTimer;
class CastSession;
class Prefs;
class QAudioBufferOutput;

class Player : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool       playing      READ playing      NOTIFY playingChanged)
    Q_PROPERTY(bool       loading      READ loading      NOTIFY loadingChanged)
    Q_PROPERTY(qint64     position     READ position     NOTIFY positionChanged)
    Q_PROPERTY(qint64     duration     READ duration     NOTIFY durationChanged)
    Q_PROPERTY(double     volume       READ volume  WRITE setVolume  NOTIFY volumeChanged)
    Q_PROPERTY(bool       muted        READ muted   WRITE setMuted   NOTIFY mutedChanged)
    Q_PROPERTY(QVariantMap currentTrack READ currentTrackMap NOTIFY currentTrackChanged)
    Q_PROPERTY(bool       shuffle      READ shuffle WRITE setShuffle  NOTIFY shuffleChanged)
    Q_PROPERTY(int        repeatMode   READ repeatMode WRITE setRepeatMode NOTIFY repeatModeChanged)
    Q_PROPERTY(QString    audioQuality READ audioQuality NOTIFY currentTrackChanged)
    Q_PROPERTY(int        queueCount      READ queueCount      NOTIFY queueChanged)
    // Notified separately from queueChanged: moving the current track is not a
    // change to the queue, and a 5000-row queue cannot afford to be republished
    // on every advance. See the signals below.
    Q_PROPERTY(int        queueIndex      READ queueIndex      NOTIFY currentIndexChanged)
    Q_PROPERTY(QVariantList queueTracks   READ queueTracks     NOTIFY queueChanged)
    Q_PROPERTY(QVariantList recentlyPlayed READ recentlyPlayed NOTIFY recentlyPlayedChanged)
    // "Playing from" context — where the current queue was started from.
    Q_PROPERTY(QString sourceType READ sourceType NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceId   READ sourceId   NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceName READ sourceName NOTIFY sourceChanged)

    // ── The two sections the Queue panel shows ──────────────────────────
    // One playback order, read as three slices: what has gone past, the rows
    // the user queued by hand, and the rest of whatever they started from.
    // See "The queue" in Player.cpp for why this is one list and not three.
    Q_PROPERTY(QVariantList queuePlayed  READ queuePlayed  NOTIFY queueChanged)
    Q_PROPERTY(QVariantList queueManual  READ queueManual  NOTIFY queueChanged)
    Q_PROPERTY(QVariantList queueContext READ queueContext NOTIFY queueChanged)
    Q_PROPERTY(QString contextName READ contextName NOTIFY queueChanged)
    Q_PROPERTY(QString contextType READ contextType NOTIFY queueChanged)
    // Where the manual section ends, for a view that renders the single
    // queueTracks list and only needs to know where to draw the headings.
    // Its own notifier, for the same reason queueIndex has one: a row being
    // consumed must not cost a republish of the whole queue.
    Q_PROPERTY(int manualCount READ manualCount NOTIFY manualCountChanged)

public:
    explicit Player(TidalClient *client, QObject *parent = nullptr);
    ~Player() override;

    bool        playing()     const;
    bool        loading()     const { return m_loading; }
    qint64      position()    const;
    qint64      duration()    const;
    double      volume()      const;
    bool        muted()       const;
    QVariantMap currentTrackMap() const;
    bool        shuffle()     const { return m_shuffle; }
    int         repeatMode()  const { return m_repeatMode; }
    QString     audioQuality()const;
    // Maps a raw Tidal quality code (LOW/HIGH/LOSSLESS/HI_RES_LOSSLESS) to the
    // user-facing label. Single source of truth so every badge stays consistent.
    Q_INVOKABLE QString qualityLabel(const QString &code) const;
    int          queueCount()    const { return m_queue.count(); }
    int          queueIndex()    const { return m_index; }
    QVariantList queueTracks()   const;
    QVariantList recentlyPlayed() const;
    QString      sourceType() const { return m_sourceType; }
    QString      sourceId()   const { return m_sourceId; }
    QString      sourceName() const { return m_sourceName; }

    // Records where playback was started from (e.g. "playlist"/"album"/"mix"/
    // "collection"/"radio"/"artist"). Call immediately before playTracks() from
    // the originating page so Now Playing can link back to it.
    Q_INVOKABLE void setPlaybackSource(const QString &type, const QString &id, const QString &name);

    // For MPRIS (internal use)
    Track currentTrack() const { return m_currentTrack; }
    qlonglong currentTrackId() const { return m_currentTrack.id; }

    // ── Audio output routing ────────────────────────────────────────────
    // The output device is rebound live: on a system-default change, on
    // hot-plug, and when the user picks a device in Settings. Everything
    // below exists so that swap is invisible to whoever is listening.

    // Watches prefs->audioDevice(). Empty means "follow the system default".
    void setPrefs(Prefs *prefs);

    // For the Settings picker: [{id, label, isDefault}], "System default"
    // first with an empty id. isDefault marks the device the OS currently
    // treats as the default, so the picker can say what "System default"
    // resolves to; the sentinel row itself is never marked.
    Q_INVOKABLE QVariantList availableAudioDevices() const;
    // Id of the device the output is bound to right now; empty before the
    // output exists, or on a box with no audio devices.
    Q_INVOKABLE QString activeAudioDeviceId() const;
    // Re-resolves the preference against the current device list and rebinds
    // if the answer changed. Cheap and idempotent.
    Q_INVOKABLE void refreshAudioDevice();

    // ── The spectrum tap ────────────────────────────────────────────────
    // Off by default and free when off. Only with the preference on does a
    // QAudioBufferOutput get attached to the QMediaPlayer at all, so with the
    // switch untouched the audio path is byte for byte what it always was.
    //
    // The analyser is the process-wide QML singleton the now-playing bars
    // bind to, and it is reached from here rather than wired in by
    // Application for one reason: the Player is the only thing in the app
    // that has decoded audio, so there is exactly one place this can come
    // from and nothing is gained by routing it through a third party.
    //
    // Needs Qt 6.8 for QAudioBufferOutput. Below that the analyser reports
    // itself unavailable, the preference cannot switch it on, and everything
    // here compiles down to nothing.
    void setSpectrumAnalyzer(SpectrumAnalyzer *analyzer);

    // Whether a QAudioBufferOutput is hooked into the QMediaPlayer right now.
    // Public because the claim this feature rests on - that with the
    // preference off nothing at all is attached, so the audio path is the one
    // the app has always had - is otherwise invisible from outside, and an
    // invisible claim is one that quietly stops being true.
    bool spectrumTapAttached() const;

    // What has to come through a device swap untouched.
    struct AudioState {
        qint64 position = 0;
        bool   playing  = false;
        double volume   = 0.0;
        bool   muted    = false;
    };
    // Public so a test can exercise the swap even where a device list of one
    // makes every rebind a no-op, and the snapshot even where nothing plays.
    AudioState captureAudioState() const;
    void       restoreAudioState(const AudioState &state);
    void       rebindAudioOutput(const QAudioDevice &device);

    // ── Chromecast handoff ──────────────────────────────────────────────
    // While casting, playback lives on the device: transport routes to the
    // CastSession and position/duration/playing mirror the device's status.
    bool casting() const { return m_castSession != nullptr; }
    void beginCast(CastSession *session);
    void endCast();
    void onCastPosition(double sec);
    void onCastDuration(double sec);
    void onCastPlaying(bool playing);

    // ── Playing ─────────────────────────────────────────────────────────
    // Tracks are QVariantMaps from TidalBridge.

    // Replaces the context, and only the context: whatever the user queued by
    // hand survives this and still plays before the new context does.
    Q_INVOKABLE void playTracks      (const QVariantList &tracks, int startIndex = 0);

    Q_INVOKABLE void playPause ();
    Q_INVOKABLE void next      ();
    Q_INVOKABLE void previous  ();
    Q_INVOKABLE void seek      (qint64 ms);
    Q_INVOKABLE void setVolume (double v);
    Q_INVOKABLE void setMuted  (bool m);
    Q_INVOKABLE void setShuffle    (bool s);
    Q_INVOKABLE void setRepeatMode (int  m);

    // ── The manual queue ────────────────────────────────────────────────
    // What the user deliberately lined up. It outlives the context it was
    // built next to, it keeps the order they put it in even under shuffle,
    // and a row leaves it for good the moment it starts playing.
    Q_INVOKABLE void playNext    (const QVariantList &tracks);  // front
    Q_INVOKABLE void addToQueue  (const QVariantList &tracks);  // back
    Q_INVOKABLE void removeManual(int index);
    Q_INVOKABLE void moveManual  (int from, int to);
    Q_INVOKABLE void clearManual ();
    // Play a row now. jumpToManual drops the rows it skipped past, because
    // they were explicitly passed over; jumpToContext and jumpToPlayed only
    // move the cursor, so the rest of the context is still there afterwards.
    Q_INVOKABLE void jumpToManual (int index);
    Q_INVOKABLE void jumpToContext(int index);
    Q_INVOKABLE void jumpToPlayed (int index);

    QVariantList queuePlayed()  const;
    QVariantList queueManual()  const;
    QVariantList queueContext() const;
    // The context is the "playing from" source under another name; the pages
    // still set it through setPlaybackSource() before calling playTracks().
    QString contextName() const { return m_sourceName; }
    QString contextType() const { return m_sourceType; }
    int     manualCount() const { return m_manualCount; }

    // ── Flat view over the same queue (deprecated) ──────────────────────
    // NowPlayingPage, PlayerBar and TrackRow index the queue as one list.
    // Every one of these is a slice or a translation of the sections above,
    // so the two can never disagree; prefer the section API in new code.
    Q_INVOKABLE void appendQueue     (const QVariantList &tracks);  // == addToQueue
    Q_INVOKABLE void jumpToQueue     (int index);
    Q_INVOKABLE void clearQueue      ();
    Q_INVOKABLE void removeFromQueue (int index);
    Q_INVOKABLE void moveQueueItem   (int from, int to);

    Q_INVOKABLE QVariantMap queueTrackAt(int index) const;
    // Tracks that will play after the current one, in true playback order.
    // max < 0 means "all". Single source of truth for every "up next" view so
    // they stay consistent with what actually plays.
    Q_INVOKABLE QVariantList upcomingTracks(int max = -1) const;
    // Deprecated. The queue is held in playback order now, so this is the
    // queue rotated to start at what is playing, each row carrying the
    // "_queueIndex" it came from. The old Queue panel reads it while shuffled.
    Q_INVOKABLE QVariantList playbackOrderTracks() const;

    // ── Session persistence ─────────────────────────────────────────────
    // Volume, mute, shuffle, repeat, the queue and the position come back on
    // the next launch of the same Tidal account. Public so the tests can
    // round-trip them without a second process; the app drives both ends by
    // itself (a debounced save, and a restore on userIdChanged).
    void savePlaybackState();
    void restorePlaybackState();
    // Public for the same reason: the real caller is the restore path's
    // stream-fetch error handler, and a test cannot make the network fail.
    // Drops the row that will not resolve and comes back on the next one.
    void skipUnplayableTrack();

signals:
    void playingChanged     (bool playing);
    void loadingChanged     (bool loading);
    void positionChanged    (qint64 ms);
    void durationChanged    (qint64 ms);
    void volumeChanged      (double v);
    void mutedChanged       (bool m);
    void currentTrackChanged();
    void shuffleChanged      (bool s);
    void repeatModeChanged   (int  m);
    // The queue itself: tracks added, removed, reordered, shuffled, cleared, or
    // replaced by a new context. Anything bound to it copies the whole queue
    // into QML, so this must not stand in for "the current track moved".
    void queueChanged        ();
    // Only the current position moved. Highlighting and "up next" bind to this.
    void currentIndexChanged (int index);
    // Only the manual section's length changed. Consuming a row on an advance
    // raises this; the rows themselves have not moved, so a view that renders
    // queueTracks needs nothing more than the new boundary.
    void manualCountChanged  (int count);
    void recentlyPlayedChanged();
    void sourceChanged       ();
    void castTrackChanged    ();   // current track changed while casting
    // The set of output devices changed - one appeared, one went away, or the
    // system default moved. Anything showing a device list binds to this and
    // re-reads availableAudioDevices(); without it an open picker shows the
    // list as it was when it opened, which is what a hot-plug test on the
    // Debian box caught: a sink added while the menu was up never appeared,
    // and closing and reopening was the only way to see it.
    //
    // Raised from the deferred turn in onAudioOutputsChanged(), never straight
    // from the backend callback, for exactly the reason written out there: a
    // handler that re-reads the device list would do so while PipeWire still
    // holds its thread loop lock.
    void audioDevicesChanged ();
    void error               (const QString &msg);

private slots:
    void initAudio();
    void onAudioOutputsChanged();
    void onMediaStatusChanged(QMediaPlayer::MediaStatus status);
    void onPlaybackStateChanged(QMediaPlayer::PlaybackState state);
    void onErrorOccurred(QMediaPlayer::Error error, const QString &msg);

private:
    // One row of the single playback order.
    struct Entry {
        QVariantMap track;
        // The user put this row here. Shuffle leaves it alone, playTracks()
        // does not throw it away, and once it is behind the cursor it has
        // been consumed and must never be walked into again.
        bool        manual  = false;
        // Position in the context's own order, so unshuffling can restore it.
        // -1 on a manual row, which has no natural position.
        int         natural = -1;
    };

    void handleUserIdChanged(qint64 uid);
    // Single door onto m_index, so no path can move the current track without
    // saying so.
    void setIndex(int i);
    void setManualCount(int n);
    void loadAndPlay(int index);
    void setLoading(bool l);
    Track trackFromMap(const QVariantMap &m) const;
    int  nextIndex() const;
    int  previousIndex() const;
    // First row belonging to the context, for a repeat-all wrap: repeat
    // applies to the context, and a consumed manual row does not come back.
    int  firstContextRow() const;
    void preloadNext();
    void cancelPreload();
    // Puts the manual queue back in the order the user gave it, directly after
    // whatever is playing. Returns true if the list itself changed, which is
    // the only case a queue view has to hear about.
    bool relocateTo(int target);
    void insertManual(const QVariantList &tracks, int at);
    // Re-derives the manual run from the rows themselves. The flat mutators
    // can tear it, and a stray user-queued row outside the run would be an
    // invisible second manual queue.
    void normalizeManualSpan();
    void reorderContext();
    // Starts the track that was just loaded, unless this is the first load of
    // a restored session, which comes back paused where it was left.
    void beginPlayback();
    // The device the current preference resolves to: the chosen one if it is
    // still present, the system default otherwise (never silence).
    QAudioDevice resolveAudioDevice() const;
    // Rebinds only when the resolved device differs from the bound one.
    void applyAudioDevice();

    // Attaches or drops the QAudioBufferOutput to match the analyser's
    // enabled state. Idempotent, and a no-op before initAudio() has made a
    // QMediaPlayer to attach it to - initAudio() calls it again on the way up.
    void applySpectrumTap();

    // Coalesces the writes: the state changes far more often than it is worth
    // writing, and the whole queue goes out in one value.
    void schedulePersist();
    QByteArray serializeQueue() const;
    QString    settingsPrefix() const;

    TidalClient         *m_client;
    QMediaPlayer        *m_player    = nullptr;
    QAudioOutput        *m_audioOut  = nullptr;
    QMediaDevices       *m_devices   = nullptr;
    QPointer<Prefs>      m_prefs;
    // Set while an output swap is in flight, so the transport churn the swap
    // causes stays inside the Player instead of reaching the UI.
    bool                 m_rebinding     = false;
    double               m_pendingVolume = 0.7;
    bool                 m_pendingMuted  = false;

    // The spectrum tap. m_bufferOut exists only while the preference is on.
    // A QPointer because the analyser is a singleton that outlives any one
    // Player, and more than one Player exists across a test run.
    QPointer<SpectrumAnalyzer> m_spectrum;
#if TIDALWAVE_HAS_BUFFER_OUTPUT
    QAudioBufferOutput  *m_bufferOut = nullptr;
#endif

    // The queue, in playback order. m_index is what plays; the m_manualCount
    // rows straight after it are the manual queue; everything past those is
    // the rest of the context; everything before it has gone by.
    QList<Entry>         m_queue;
    int                  m_index         = -1;
    int                  m_manualCount   = 0;
    QList<QVariantMap>   m_recentlyPlayed;
    Track                m_currentTrack;
    bool                 m_loading       = false;
    bool                 m_shuffle       = false;
    int                  m_repeatMode    = 0;  // 0=no 1=all 2=one
    QString              m_sourceType;
    QString              m_sourceId;
    QString              m_sourceName;
    // Set by setPlaybackSource(), consumed by the next playTracks(). Lets
    // playTracks() clear a stale "playing from" when a play has no source.
    bool                 m_pendingSource = false;
    QString              m_streamedQuality;

    // ── Restore ─────────────────────────────────────────────────────────
    QTimer              *m_persistTimer  = nullptr;
    // Set while restorePlaybackState() is writing into the Player, so the
    // restore does not immediately save what it has just read.
    bool                 m_suspendPersist = false;
    // The restore ran before initAudio(), so the load is owed.
    bool                 m_restorePending = false;
    // The next successful load belongs to a restored session: hold it paused.
    bool                 m_restorePaused  = false;
    // Until a restored track resolves, a stream that will not load is a stale
    // queue entry rather than something to put in front of the user.
    bool                 m_restoreSkips   = false;
    // Where the restored track was left, applied once the media is ready.
    qint64               m_pendingSeek    = 0;

    // Cast state (non-null while casting; owned by CastManager).
    CastSession         *m_castSession   = nullptr;
    qint64               m_castPosition  = 0;   // ms
    qint64               m_castDuration  = 0;   // ms
    bool                 m_castPlaying   = false;
    // The audio for the current track, always a plain .mp4 whichever manifest
    // it came from: BTS hands over one URL, DASH is joined out of its segments
    // by DashFetcher. It has not been a .mpd since the Qt installer's ffmpeg
    // turned out to have no DASH demuxer; the name stayed.
    QTemporaryFile      *m_mpdTempFile    = nullptr;
    QNetworkReply       *m_activeDownload = nullptr;
    // Joining the current track's DASH segments (lossless); see DashFetcher.h.
    DashFetcher         *m_dash           = nullptr;

    // Preload state for the next queued track
    int                  m_preloadIndex    = -1;
    bool                 m_preloadReady    = false;
    QString              m_preloadQuality;
    QTemporaryFile      *m_preloadTempFile = nullptr;
    QNetworkReply       *m_preloadDownload = nullptr;
    DashFetcher         *m_preloadDash     = nullptr;
};
