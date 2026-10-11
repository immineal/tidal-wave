// SPDX-License-Identifier: GPL-3.0-or-later

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
    // Its own notifier: an advance must not republish the whole queue.
    Q_PROPERTY(int        queueIndex      READ queueIndex      NOTIFY currentIndexChanged)
    Q_PROPERTY(QVariantList queueTracks   READ queueTracks     NOTIFY queueChanged)
    Q_PROPERTY(QVariantList recentlyPlayed READ recentlyPlayed NOTIFY recentlyPlayedChanged)
    // Where the current queue was started from.
    Q_PROPERTY(QString sourceType READ sourceType NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceId   READ sourceId   NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceName READ sourceName NOTIFY sourceChanged)

    // ── The two sections the Queue panel shows ──────────────────────────
    // One playback order, read as slices: played, queued by hand, the context.
    Q_PROPERTY(QVariantList queuePlayed  READ queuePlayed  NOTIFY queueChanged)
    Q_PROPERTY(QVariantList queueManual  READ queueManual  NOTIFY queueChanged)
    Q_PROPERTY(QVariantList queueContext READ queueContext NOTIFY queueChanged)
    Q_PROPERTY(QString contextName READ contextName NOTIFY queueChanged)
    Q_PROPERTY(QString contextType READ contextType NOTIFY queueChanged)
    // Where the manual section ends. Its own notifier, so a consumed row
    // does not republish the whole queue.
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
    // Maps a Tidal quality code such as HI_RES_LOSSLESS to its label.
    Q_INVOKABLE QString qualityLabel(const QString &code) const;
    int          queueCount()    const { return m_queue.count(); }
    int          queueIndex()    const { return m_index; }
    QVariantList queueTracks()   const;
    QVariantList recentlyPlayed() const;
    QString      sourceType() const { return m_sourceType; }
    QString      sourceId()   const { return m_sourceId; }
    QString      sourceName() const { return m_sourceName; }

    // Where playback was started from (playlist, album, mix, collection, radio,
    // artist). Call immediately before playTracks().
    Q_INVOKABLE void setPlaybackSource(const QString &type, const QString &id, const QString &name);

    // For MPRIS.
    Track currentTrack() const { return m_currentTrack; }
    qlonglong currentTrackId() const { return m_currentTrack.id; }
    // Nothing sounds yet, and the load under way ends in playback.
    bool startingPlayback() const;

    // ── Audio output routing ────────────────────────────────────────────
    // Watches prefs->audioDevice(). Empty means follow the system default.
    void setPrefs(Prefs *prefs);

    // For the Settings picker: [{id, label, isDefault}], the system default
    // row first with an empty id and never marked isDefault.
    Q_INVOKABLE QVariantList availableAudioDevices() const;
    // Id of the device the output is bound to; empty before the output exists.
    Q_INVOKABLE QString activeAudioDeviceId() const;
    // Re-resolves the preference and rebinds if the answer changed. Idempotent.
    Q_INVOKABLE void refreshAudioDevice();

    // ── The spectrum tap ────────────────────────────────────────────────
    // A QAudioBufferOutput is attached only while the preference is on.
    // Needs Qt 6.8; below that the analyser reports itself unavailable.
    void setSpectrumAnalyzer(SpectrumAnalyzer *analyzer);

    // Whether a QAudioBufferOutput is attached right now. Public for the tests.
    bool spectrumTapAttached() const;

    // What has to come through a device swap untouched.
    struct AudioState {
        qint64 position = 0;
        bool   playing  = false;
        double volume   = 0.0;
        bool   muted    = false;
    };
    // Public so a test can exercise the swap where every rebind is a no-op.
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

    // Replaces the context only: the manual queue survives and plays first.
    Q_INVOKABLE void playTracks      (const QVariantList &tracks, int startIndex = 0);

    Q_INVOKABLE void playPause ();
    // heldPaused is for MPRIS: the track changes and waits there for play.
    Q_INVOKABLE void next      (bool heldPaused = false);
    Q_INVOKABLE void previous  (bool heldPaused = false);
    Q_INVOKABLE void seek      (qint64 ms);
    Q_INVOKABLE void setVolume (double v);
    Q_INVOKABLE void setMuted  (bool m);
    Q_INVOKABLE void setShuffle    (bool s);
    Q_INVOKABLE void setRepeatMode (int  m);

    // ── The manual queue ────────────────────────────────────────────────
    // What the user lined up. It outlives its context, keeps its order under
    // shuffle, and a row leaves it for good when it starts playing.
    Q_INVOKABLE void playNext    (const QVariantList &tracks);  // front
    Q_INVOKABLE void addToQueue  (const QVariantList &tracks);  // back
    Q_INVOKABLE void removeManual(int index);
    Q_INVOKABLE void moveManual  (int from, int to);
    Q_INVOKABLE void clearManual ();
    // Play a row now. jumpToManual drops the rows it skipped past;
    // jumpToContext and jumpToPlayed only move the cursor.
    Q_INVOKABLE void jumpToManual (int index);
    Q_INVOKABLE void jumpToContext(int index);
    Q_INVOKABLE void jumpToPlayed (int index);

    QVariantList queuePlayed()  const;
    QVariantList queueManual()  const;
    QVariantList queueContext() const;
    // The context is the playback source; pages set it through
    // setPlaybackSource() before calling playTracks().
    QString contextName() const { return m_sourceName; }
    QString contextType() const { return m_sourceType; }
    int     manualCount() const { return m_manualCount; }

    // ── Flat view over the same queue (deprecated) ──────────────────────
    // NowPlayingPage, PlayerBar and TrackRow index the queue as one list.
    // Each of these is a slice of the sections above; prefer those in new code.
    Q_INVOKABLE void appendQueue     (const QVariantList &tracks);  // == addToQueue
    Q_INVOKABLE void jumpToQueue     (int index);
    Q_INVOKABLE void clearQueue      ();
    Q_INVOKABLE void removeFromQueue (int index);
    Q_INVOKABLE void moveQueueItem   (int from, int to);

    Q_INVOKABLE QVariantMap queueTrackAt(int index) const;
    // Tracks that will play after the current one, in playback order.
    // max < 0 means all.
    Q_INVOKABLE QVariantList upcomingTracks(int max = -1) const;
    // Deprecated. The queue rotated to start at what is playing, each row
    // carrying the _queueIndex it came from.
    Q_INVOKABLE QVariantList playbackOrderTracks() const;

    // ── Session persistence ─────────────────────────────────────────────
    // Public so the tests can round-trip them.
    void savePlaybackState();
    void restorePlaybackState();
    // Drops the row that will not resolve and comes back on the next one.
    // Public because a test cannot make the network fail.
    void skipUnplayableTrack();

signals:
    void playingChanged     (bool playing);
    void loadingChanged     (bool loading);
    void positionChanged    (qint64 ms);
    // The position was moved by seek(). MPRIS announces that and stays
    // silent about the progress of a track.
    void seeked             ();
    void durationChanged    (qint64 ms);
    void volumeChanged      (double v);
    void mutedChanged       (bool m);
    void currentTrackChanged();
    void shuffleChanged      (bool s);
    void repeatModeChanged   (int  m);
    // The queue's rows changed. Anything bound to it copies the whole queue
    // into QML, so it must not stand in for a plain advance.
    void queueChanged        ();
    // Only the current position moved.
    void currentIndexChanged (int index);
    // Only the manual section's length changed; the rows have not moved.
    void manualCountChanged  (int count);
    void recentlyPlayedChanged();
    void sourceChanged       ();
    void castTrackChanged    ();   // current track changed while casting
    // The set of output devices or the system default changed; device lists
    // re-read availableAudioDevices(). Raised from the deferred turn in
    // onAudioOutputsChanged(), never straight from the backend callback.
    void audioDevicesChanged ();
    void error               (const QString &msg);

private slots:
    void initAudio();
    void onAudioOutputsChanged();
    void onMediaStatusChanged(QMediaPlayer::MediaStatus status);
    void onPlaybackStateChanged(QMediaPlayer::PlaybackState state);
    void onErrorOccurred(QMediaPlayer::Error error, const QString &msg);

private:
    struct Entry {
        QVariantMap track;
        // The user put this row here. Shuffle and playTracks() leave it alone,
        // and once behind the cursor it must never be walked into again.
        bool        manual  = false;
        // Position in the context's own order, so unshuffling can restore it.
        // -1 on a manual row, which has no natural position.
        int         natural = -1;
    };

    void handleUserIdChanged(qint64 uid);
    // The only way to change m_index, so every move is announced.
    void setIndex(int i);
    void setManualCount(int n);
    // A load the user asked for. It ends a restore that has not loaded yet.
    void loadAndPlay(int index, bool heldPaused = false);
    // The load itself. Only the restore calls it directly, to stay in force.
    void startLoad(int index);
    // The load ended with nothing to play: reports why, and owes the track
    // another load on the next press on play.
    void failLoad(const QString &msg);
    void setPlayerPosition(qint64 ms);
    void setLoading(bool l);
    Track trackFromMap(const QVariantMap &m) const;
    int  nextIndex() const;
    int  previousIndex() const;
    // First row belonging to the context, for a repeat-all wrap.
    int  firstContextRow() const;
    void preloadNext();
    void cancelPreload();
    // A preload attempt for the row at `next` gave up. Clears the in-progress
    // index and records the row so the trigger does not retry it.
    void preloadGaveUp(int next);
    // Moves the cursor to target and puts the manual queue directly after it.
    // Returns true if the list itself changed.
    bool relocateTo(int target);
    void insertManual(const QVariantList &tracks, int at);
    // Re-derives the manual run from the rows themselves; the flat mutators
    // can tear it.
    void normalizeManualSpan();
    void reorderContext();
    // Starts the track that was just loaded, unless this is the first load of
    // a restored session, which comes back paused where it was left.
    void beginPlayback();
    // The chosen device if it is still present, else the system default.
    QAudioDevice resolveAudioDevice() const;
    // Rebinds only when the resolved device differs from the bound one.
    void applyAudioDevice();

    // Attaches or drops the QAudioBufferOutput to match the analyser's
    // enabled state. Idempotent, and a no-op before initAudio().
    void applySpectrumTap();

    // Debounces the writes.
    void schedulePersist();
    QByteArray serializeQueue() const;
    QString    settingsPrefix() const;

    TidalClient         *m_client;
    QMediaPlayer        *m_player    = nullptr;
    QAudioOutput        *m_audioOut  = nullptr;
    QMediaDevices       *m_devices   = nullptr;
    QPointer<Prefs>      m_prefs;
    // Set during an output swap, so its transport churn does not reach the UI.
    bool                 m_rebinding     = false;
    // Set while a seek pauses and resumes the backend around itself.
    bool                 m_seekToggling  = false;
    double               m_pendingVolume = 0.7;
    bool                 m_pendingMuted  = false;

    // A QPointer: the analyser is a singleton that outlives any one Player.
    // m_bufferOut exists only while the preference is on.
    QPointer<SpectrumAnalyzer> m_spectrum;
#if TIDALWAVE_HAS_BUFFER_OUTPUT
    QAudioBufferOutput  *m_bufferOut = nullptr;
#endif

    // The queue, in playback order: m_index plays, the next m_manualCount
    // rows are the manual queue, the rest is the context.
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
    // Set while restorePlaybackState() runs, so it does not save what it read.
    bool                 m_suspendPersist = false;
    // The restore ran before initAudio(), so the load is owed.
    bool                 m_restorePending = false;
    // The next successful load comes up paused: a restored session, or a step
    // MPRIS made while paused.
    bool                 m_restorePaused  = false;
    // Whether the load under way ends in playback. Set as the load starts.
    bool                 m_loadPlays      = false;
    // Until a restored track resolves, a failed load stays quiet: the row is
    // dropped if Tidal ruled the track out, and left to load on play otherwise.
    bool                 m_restoreSkips   = false;
    // The current track's load failed and left nothing loaded; the next play
    // asks again.
    bool                 m_loadOwed       = false;
    // Numbers the loads, so a reply can tell that a newer load has replaced
    // the one that asked for it.
    quint64              m_loadSerial     = 0;
    // Where the restored track was left, applied once the media is ready.
    qint64               m_pendingSeek    = 0;

    // Cast state (non-null while casting; owned by CastManager).
    CastSession         *m_castSession   = nullptr;
    qint64               m_castPosition  = 0;   // ms
    qint64               m_castDuration  = 0;   // ms
    bool                 m_castPlaying   = false;
    // The audio for the current track, always a plain .mp4 despite the name:
    // BTS hands over one URL, DASH is joined from its segments by DashFetcher.
    QTemporaryFile      *m_mpdTempFile    = nullptr;
    QNetworkReply       *m_activeDownload = nullptr;
    // Joining the current track's DASH segments (lossless); see DashFetcher.h.
    DashFetcher         *m_dash           = nullptr;

    // How far into a track the preload of the next one starts. A whole track
    // is downloaded before it can play, so the preload gets the rest of the
    // current one; a track skipped inside this window costs no preload.
    static constexpr qint64 kPreloadAfterMs = 5000;

    // Preload state for the next queued track
    int                  m_preloadIndex    = -1;
    // Which track the bytes on disk are for. Queue edits can change which
    // track sits at m_preloadIndex without cancelling the preload, so the
    // file is matched on the id.
    qlonglong            m_preloadTrackId  = 0;
    // The row whose preload gave up; not retried until the track changes.
    int                  m_preloadFailedIndex = -1;
    bool                 m_preloadReady    = false;
    QString              m_preloadQuality;
    QTemporaryFile      *m_preloadTempFile = nullptr;
    QNetworkReply       *m_preloadDownload = nullptr;
    DashFetcher         *m_preloadDash     = nullptr;
};
