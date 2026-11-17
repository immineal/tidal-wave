// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QCoreApplication>
#include <QDBusAbstractAdaptor>
#include <QDBusConnection>
#include <QDBusObjectPath>
#include <QElapsedTimer>
#include <QVariantMap>
#include "player/Player.h"

class MprisManager;

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
    explicit MprisRoot(MprisManager *manager);
    bool        canQuit()             const { return true; }
    bool        canRaise()            const { return true; }
    bool        hasTrackList()        const { return true; }
    QString     identity()            const { return "Tidal Wave"; }
    // Must name the installed <app-id>.desktop, the only entry Flatpak exports:
    // clients resolve DesktopEntry to find the icon and name.
    QString     desktopEntry()        const { return "io.github.immineal.TidalWave"; }
    // OpenUri takes the links a command line takes.
    QStringList supportedUriSchemes() const { return { QStringLiteral("tidal") }; }
    QStringList supportedMimeTypes()  const { return {}; }
public slots:
    void Quit()  { qApp->quit(); }
    void Raise();
private:
    MprisManager *m_manager;
};

class MprisPlayer : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString    PlaybackStatus READ playbackStatus)
    Q_PROPERTY(QString    LoopStatus     READ loopStatus      WRITE setLoopStatus)
    Q_PROPERTY(double     Rate           READ rate            WRITE setRate)
    Q_PROPERTY(bool       Shuffle        READ shuffle         WRITE setShuffle)
    Q_PROPERTY(QVariantMap Metadata      READ metadata)
    Q_PROPERTY(double     Volume         READ volume          WRITE setVolume)
    Q_PROPERTY(qlonglong  Position       READ position)
    Q_PROPERTY(double     MinimumRate   READ minimumRate     CONSTANT)
    Q_PROPERTY(double     MaximumRate   READ maximumRate     CONSTANT)
    Q_PROPERTY(bool       CanGoNext      READ canGoNext)
    Q_PROPERTY(bool       CanGoPrevious  READ canGoPrevious)
    Q_PROPERTY(bool       CanPlay        READ canPlay)
    Q_PROPERTY(bool       CanPause       READ canPause)
    Q_PROPERTY(bool       CanSeek        READ canSeek)
    Q_PROPERTY(bool       CanControl     READ canControl      CONSTANT)
public:
    MprisPlayer(Player *player, MprisManager *manager);

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
    // False with no track. Previous at least restarts the track; Next needs a
    // row to go to.
    bool        canGoNext()       const { return hasTrack() && m_player->hasNext(); }
    bool        canGoPrevious()   const { return hasTrack(); }
    bool        canPlay()         const { return hasTrack(); }
    bool        canPause()        const { return hasTrack(); }
    bool        canSeek()         const { return hasTrack(); }
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
    void OpenUri(const QString &uri);

signals:
    void Seeked(qlonglong position);

private:
    // The properties whose changes the specification wants announced.
    QVariantMap announcedProperties() const;
    // Sends one PropertiesChanged with whatever differs from the last one.
    void announce();
    // Once per turn of the loop, so states a change passes through stay unsent.
    void scheduleAnnounce();
    bool hasTrack() const { return !m_player->currentTrackMap().isEmpty(); }
    // Where a client that heard every signal takes the position to be.
    qint64 reckonedPosition() const;
    // The length of what is loaded, and the catalogue's until something is.
    qint64 lengthMs() const;

    // How far the position may be from the reckoned one and go unannounced.
    static constexpr qint64 kReckoningSlackMs = 500;

    Player       *m_player;
    MprisManager *m_manager;
    QVariantMap m_announced;
    bool        m_announceQueued = false;
    // The reckoning starts here, and its clock counts while the status is Playing.
    qlonglong     m_trackId      = 0;
    qint64        m_reckonedFrom = 0;
    QElapsedTimer m_reckonedSince;
    // The player was asked to seek, which is announced whatever the distance.
    bool          m_seeked       = false;
    // The player changed state, so its position is compared as well.
    bool          m_stateChanged = false;
};

// The rows around the current one: a few that played and the next ones up.
// Read-only: a client cannot add or remove rows, only skip to one.
class MprisTrackList : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.TrackList")
    Q_PROPERTY(QList<QDBusObjectPath> Tracks READ tracks)
    Q_PROPERTY(bool CanEditTracks READ canEditTracks CONSTANT)
public:
    MprisTrackList(Player *player, MprisManager *manager);
    QList<QDBusObjectPath> tracks() const;
    bool canEditTracks() const { return false; }

    static constexpr int kPlayedShown   = 5;
    static constexpr int kUpcomingShown = 20;

public slots:
    QList<QVariantMap> GetTracksMetadata(const QList<QDBusObjectPath> &trackIds) const;
    void AddTrack(const QString &, const QDBusObjectPath &, bool) {}
    void RemoveTrack(const QDBusObjectPath &) {}
    void GoTo(const QDBusObjectPath &trackId);

signals:
    void TrackListReplaced(const QList<QDBusObjectPath> &tracks, const QDBusObjectPath &currentTrack);
    void TrackAdded(const QVariantMap &metadata, const QDBusObjectPath &afterTrack);
    void TrackRemoved(const QDBusObjectPath &trackId);
    void TrackMetadataChanged(const QDBusObjectPath &trackId, const QVariantMap &metadata);

private:
    struct Row { QDBusObjectPath path; int index; };
    // A track queued twice is two rows, so each gets its own id; the
    // current row keeps the one Metadata gives it.
    QList<Row> rows() const;
    void scheduleReplace();
    void replace();

    Player                 *m_player;
    QList<QDBusObjectPath>  m_sent;
    QDBusObjectPath         m_sentCurrent;
    bool                    m_queued = false;
};

class MprisManager : public QObject {
    Q_OBJECT
public:
    explicit MprisManager(Player *player, QObject *parent = nullptr);
signals:
    // A client asked for the window. A signal here stays off the bus, where
    // one on the adaptor would be sent as part of the interface.
    void raiseRequested();
    // A client handed over a link to open, already known to be tidal:.
    void openUriRequested(const QString &uri);
private:
    MprisRoot      *m_root;
    MprisPlayer    *m_mprisPlayer;
    MprisTrackList *m_trackList;
};
