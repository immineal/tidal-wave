#pragma once
#include <QObject>
#include <QMediaPlayer>
#include <QAudioOutput>
#include <QVariantMap>
#include <QVariantList>
#include <QTemporaryFile>
#include "api/TidalClient.h"
#include "api/Models.h"

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
    Q_PROPERTY(int        queueCount   READ queueCount  NOTIFY queueChanged)
    Q_PROPERTY(int        queueIndex   READ queueIndex  NOTIFY queueChanged)

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
    QString     audioQuality()const { return m_streamedQuality; }
    int         queueCount()  const { return m_queue.count(); }
    int         queueIndex()  const { return m_index; }

    // For MPRIS (internal use)
    Track currentTrack() const { return m_currentTrack; }

    // QML-callable play methods — tracks are QVariantMaps from TidalBridge
    Q_INVOKABLE void playTracks (const QVariantList &tracks, int startIndex = 0);
    Q_INVOKABLE void appendQueue(const QVariantList &tracks);
    Q_INVOKABLE void jumpToQueue(int index);

    Q_INVOKABLE void playPause ();
    Q_INVOKABLE void next      ();
    Q_INVOKABLE void previous  ();
    Q_INVOKABLE void seek      (qint64 ms);
    Q_INVOKABLE void setVolume (double v);
    Q_INVOKABLE void setMuted  (bool m);
    Q_INVOKABLE void setShuffle    (bool s);
    Q_INVOKABLE void setRepeatMode (int  m);

    Q_INVOKABLE QVariantMap queueTrackAt(int index) const;

signals:
    void playingChanged     (bool playing);
    void loadingChanged     (bool loading);
    void positionChanged    (qint64 ms);
    void durationChanged    (qint64 ms);
    void volumeChanged      (double v);
    void mutedChanged       (bool m);
    void currentTrackChanged();
    void shuffleChanged     (bool s);
    void repeatModeChanged  (int  m);
    void queueChanged       ();
    void error              (const QString &msg);

private slots:
    void initAudio();
    void onMediaStatusChanged(QMediaPlayer::MediaStatus status);
    void onPlaybackStateChanged(QMediaPlayer::PlaybackState state);
    void onErrorOccurred(QMediaPlayer::Error error, const QString &msg);

private:
    void loadAndPlay(int index);
    void setLoading(bool l);
    Track trackFromMap(const QVariantMap &m) const;
    void buildShuffleOrder();
    int  nextIndex() const;
    int  previousIndex() const;

    TidalClient         *m_client;
    QMediaPlayer        *m_player    = nullptr;
    QAudioOutput        *m_audioOut  = nullptr;
    double               m_pendingVolume = 0.7;
    bool                 m_pendingMuted  = false;

    QList<QVariantMap>   m_queue;
    QList<int>           m_shuffleOrder;
    int                  m_index         = -1;
    Track                m_currentTrack;
    bool                 m_loading       = false;
    bool                 m_shuffle       = false;
    int                  m_repeatMode    = 0;  // 0=no 1=all 2=one
    QString              m_streamedQuality;
    QTemporaryFile      *m_mpdTempFile   = nullptr;
};
