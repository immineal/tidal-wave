#pragma once
#include <QObject>
#include <QMediaPlayer>
#include <QAudioOutput>
#include <QVariantMap>
#include <QVariantList>
#include <QTemporaryFile>
#include "api/TidalClient.h"
#include "api/Models.h"

class QNetworkReply;
class CastSession;

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
    Q_PROPERTY(int        queueIndex      READ queueIndex      NOTIFY queueChanged)
    Q_PROPERTY(QVariantList queueTracks   READ queueTracks     NOTIFY queueChanged)
    Q_PROPERTY(QVariantList recentlyPlayed READ recentlyPlayed NOTIFY recentlyPlayedChanged)
    // "Playing from" context — where the current queue was started from.
    Q_PROPERTY(QString sourceType READ sourceType NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceId   READ sourceId   NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceName READ sourceName NOTIFY sourceChanged)

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

    // ── Chromecast handoff ──────────────────────────────────────────────
    // While casting, playback lives on the device: transport routes to the
    // CastSession and position/duration/playing mirror the device's status.
    bool casting() const { return m_castSession != nullptr; }
    void beginCast(CastSession *session);
    void endCast();
    void onCastPosition(double sec);
    void onCastDuration(double sec);
    void onCastPlaying(bool playing);

    // QML-callable play methods — tracks are QVariantMaps from TidalBridge
    Q_INVOKABLE void playTracks      (const QVariantList &tracks, int startIndex = 0);
    Q_INVOKABLE void appendQueue     (const QVariantList &tracks);
    Q_INVOKABLE void jumpToQueue     (int index);
    Q_INVOKABLE void clearQueue      ();
    Q_INVOKABLE void removeFromQueue (int index);
    Q_INVOKABLE void moveQueueItem   (int from, int to);

    Q_INVOKABLE void playPause ();
    Q_INVOKABLE void next      ();
    Q_INVOKABLE void previous  ();
    Q_INVOKABLE void seek      (qint64 ms);
    Q_INVOKABLE void setVolume (double v);
    Q_INVOKABLE void setMuted  (bool m);
    Q_INVOKABLE void setShuffle    (bool s);
    Q_INVOKABLE void setRepeatMode (int  m);

    Q_INVOKABLE QVariantMap queueTrackAt(int index) const;
    // Tracks that will play after the current one, in true playback order
    // (respects shuffle). max < 0 means "all". Single source of truth for
    // every "up next" view so they stay consistent with what actually plays.
    Q_INVOKABLE QVariantList upcomingTracks(int max = -1) const;
    // The whole queue in true playback order. When shuffle is on, each entry
    // carries a "_queueIndex" with its real index in m_queue so the Queue panel
    // can still map rows back for jump/remove. Linear order when not shuffled.
    Q_INVOKABLE QVariantList playbackOrderTracks() const;

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
    void queueChanged        ();
    void recentlyPlayedChanged();
    void sourceChanged       ();
    void castTrackChanged    ();   // current track changed while casting
    void error               (const QString &msg);

private slots:
    void initAudio();
    void onMediaStatusChanged(QMediaPlayer::MediaStatus status);
    void onPlaybackStateChanged(QMediaPlayer::PlaybackState state);
    void onErrorOccurred(QMediaPlayer::Error error, const QString &msg);

private:
    void handleUserIdChanged(qint64 uid);
    void loadAndPlay(int index);
    void setLoading(bool l);
    Track trackFromMap(const QVariantMap &m) const;
    void buildShuffleOrder();
    int  nextIndex() const;
    int  previousIndex() const;
    void preloadNext();
    void cancelPreload();

    TidalClient         *m_client;
    QMediaPlayer        *m_player    = nullptr;
    QAudioOutput        *m_audioOut  = nullptr;
    double               m_pendingVolume = 0.7;
    bool                 m_pendingMuted  = false;

    QList<QVariantMap>   m_queue;
    QList<QVariantMap>   m_recentlyPlayed;
    QList<int>           m_shuffleOrder;
    int                  m_index         = -1;
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

    // Cast state (non-null while casting; owned by CastManager).
    CastSession         *m_castSession   = nullptr;
    qint64               m_castPosition  = 0;   // ms
    qint64               m_castDuration  = 0;   // ms
    bool                 m_castPlaying   = false;
    QTemporaryFile      *m_mpdTempFile    = nullptr;
    QNetworkReply       *m_activeDownload = nullptr;

    // Preload state for the next queued track
    int                  m_preloadIndex    = -1;
    bool                 m_preloadReady    = false;
    QString              m_preloadQuality;
    QTemporaryFile      *m_preloadTempFile = nullptr;
    QNetworkReply       *m_preloadDownload = nullptr;
};
