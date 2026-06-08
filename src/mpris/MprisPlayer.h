#pragma once
#include <QObject>
#include <QCoreApplication>
#include <QDBusAbstractAdaptor>
#include <QDBusConnection>
#include <QDBusObjectPath>
#include <QVariantMap>
#include "player/Player.h"

class MprisRoot : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    Q_PROPERTY(bool     CanQuit           READ canQuit          CONSTANT)
    Q_PROPERTY(bool     CanRaise          READ canRaise         CONSTANT)
    Q_PROPERTY(bool     HasTrackList      READ hasTrackList     CONSTANT)
    Q_PROPERTY(QString  Identity          READ identity         CONSTANT)
    Q_PROPERTY(QString  DesktopEntry      READ desktopEntry     CONSTANT)
    Q_PROPERTY(QStringList SupportedUriSchemes READ supportedUriSchemes CONSTANT)
    Q_PROPERTY(QStringList SupportedMimeTypes  READ supportedMimeTypes  CONSTANT)
public:
    explicit MprisRoot(QObject *parent);
    bool        canQuit()             const { return true; }
    bool        canRaise()            const { return true; }
    bool        hasTrackList()        const { return false; }
    QString     identity()            const { return "Tidal Wave"; }
    QString     desktopEntry()        const { return "tidal-wave"; }
    QStringList supportedUriSchemes() const { return {}; }
    QStringList supportedMimeTypes()  const { return {}; }
public slots:
    void Quit()  { qApp->quit(); }
    void Raise() { emit raiseRequested(); }
signals:
    void raiseRequested();
};

class MprisPlayer : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString    PlaybackStatus READ playbackStatus  NOTIFY playbackStatusChanged)
    Q_PROPERTY(QString    LoopStatus     READ loopStatus      WRITE setLoopStatus)
    Q_PROPERTY(double     Rate           READ rate            WRITE setRate)
    Q_PROPERTY(bool       Shuffle        READ shuffle         WRITE setShuffle)
    Q_PROPERTY(QVariantMap Metadata      READ metadata        NOTIFY metadataChanged)
    Q_PROPERTY(double     Volume         READ volume          WRITE setVolume)
    Q_PROPERTY(qlonglong  Position       READ position)
    Q_PROPERTY(double     MinimumRate   READ minimumRate     CONSTANT)
    Q_PROPERTY(double     MaximumRate   READ maximumRate     CONSTANT)
    Q_PROPERTY(bool       CanGoNext      READ canGoNext       CONSTANT)
    Q_PROPERTY(bool       CanGoPrevious  READ canGoPrevious   CONSTANT)
    Q_PROPERTY(bool       CanPlay        READ canPlay         CONSTANT)
    Q_PROPERTY(bool       CanPause       READ canPause        CONSTANT)
    Q_PROPERTY(bool       CanSeek        READ canSeek         CONSTANT)
    Q_PROPERTY(bool       CanControl     READ canControl      CONSTANT)
public:
    explicit MprisPlayer(Player *player, QObject *parent);

    QString     playbackStatus()  const;
    QString     loopStatus()      const;
    void        setLoopStatus(const QString &s);
    double      rate()            const { return 1.0; }
    void        setRate(double)   {}
    bool        shuffle()         const;
    void        setShuffle(bool s);
    QVariantMap metadata()        const;
    double      volume()          const;
    void        setVolume(double v);
    qlonglong   position()        const;
    double      minimumRate()     const { return 1.0; }
    double      maximumRate()     const { return 1.0; }
    bool        canGoNext()       const { return true; }
    bool        canGoPrevious()   const { return true; }
    bool        canPlay()         const { return true; }
    bool        canPause()        const { return true; }
    bool        canSeek()         const { return true; }
    bool        canControl()      const { return true; }

public slots:
    void Next();
    void Previous();
    void Pause();
    void PlayPause();
    void Stop();
    void Play();
    void Seek(qlonglong offset);
    void SetPosition(const QDBusObjectPath &trackId, qlonglong pos);
    void OpenUri(const QString &) {}

signals:
    void playbackStatusChanged();
    void metadataChanged();
    void Seeked(qlonglong position);

private:
    Player *m_player;
};

class MprisManager : public QObject {
    Q_OBJECT
public:
    explicit MprisManager(Player *player, QObject *parent = nullptr);
private:
    MprisRoot   *m_root;
    MprisPlayer *m_mprisPlayer;
};
