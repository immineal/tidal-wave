#include "MprisPlayer.h"
#include <QDBusConnection>
#include <QDBusMessage>
#include <QCoreApplication>

MprisRoot::MprisRoot(QObject *parent) : QDBusAbstractAdaptor(parent) {
    setAutoRelaySignals(true);
}

MprisPlayer::MprisPlayer(Player *player, QObject *parent)
    : QDBusAbstractAdaptor(parent), m_player(player)
{
    setAutoRelaySignals(true);

    auto notifyProps = [this](const QVariantMap &changed) {
        QDBusMessage msg = QDBusMessage::createSignal(
            "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged");
        msg << "org.mpris.MediaPlayer2.Player" << changed << QStringList();
        QDBusConnection::sessionBus().send(msg);
    };

    connect(m_player, &Player::playingChanged, this, [this, notifyProps]() {
        emit playbackStatusChanged();
        notifyProps({ {"PlaybackStatus", playbackStatus()} });
    });

    connect(m_player, &Player::currentTrackChanged, this, [this, notifyProps]() {
        emit metadataChanged();
        notifyProps({ {"Metadata", metadata()} });
    });

    connect(m_player, &Player::positionChanged, this, [this](qint64 ms) {
        emit Seeked(ms * 1000LL);
    });
}

QString MprisPlayer::playbackStatus() const {
    if (m_player->loading()) return "Loading";
    return m_player->playing() ? "Playing" : "Paused";
}

QString MprisPlayer::loopStatus() const {
    switch (m_player->repeatMode()) {
        case 2:  return "Track";
        case 1:  return "Playlist";
        default: return "None";
    }
}

void MprisPlayer::setLoopStatus(const QString &s) {
    if (s == "Track")         m_player->setRepeatMode(2);
    else if (s == "Playlist") m_player->setRepeatMode(1);
    else                      m_player->setRepeatMode(0);
}

bool MprisPlayer::shuffle() const { return m_player->shuffle(); }
void MprisPlayer::setShuffle(bool s) { m_player->setShuffle(s); }

QVariantMap MprisPlayer::metadata() const {
    QVariantMap m;
    const auto track = m_player->currentTrackMap();
    if (track.isEmpty()) return m;

    qlonglong id = track["id"].toLongLong();
    m["mpris:trackid"]    = QVariant::fromValue(QDBusObjectPath("/org/tidalwave/track/" + QString::number(id)));
    m["mpris:length"]     = (qlonglong)(track["duration"].toLongLong() * 1000000LL);
    m["mpris:artUrl"]     = track["coverUrl"].toString();
    m["xesam:title"]      = track["title"].toString();
    m["xesam:artist"]     = QStringList{ track["artists"].toString() };
    m["xesam:album"]      = track["albumTitle"].toString();
    m["xesam:trackNumber"]= track["trackNumber"].toInt();
    return m;
}

double MprisPlayer::volume() const { return m_player->volume(); }
void   MprisPlayer::setVolume(double v) { m_player->setVolume(v); }
qlonglong MprisPlayer::position() const { return m_player->position() * 1000LL; }

void MprisPlayer::Next()      { m_player->next(); }
void MprisPlayer::Previous()  { m_player->previous(); }
void MprisPlayer::Pause()     { if (m_player->playing()) m_player->playPause(); }
void MprisPlayer::Play()      { if (!m_player->playing()) m_player->playPause(); }
void MprisPlayer::PlayPause() { m_player->playPause(); }
void MprisPlayer::Stop()      { m_player->seek(0); Pause(); }
void MprisPlayer::Seek(qlonglong offsetMicros) { m_player->seek(m_player->position() + offsetMicros/1000); }
void MprisPlayer::SetPosition(const QDBusObjectPath &, qlonglong posMicros) { m_player->seek(posMicros/1000); }

MprisManager::MprisManager(Player *player, QObject *parent) : QObject(parent) {
    m_root        = new MprisRoot(this);
    m_mprisPlayer = new MprisPlayer(player, this);

    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.registerService("org.mpris.MediaPlayer2.tidalwave");
    bus.registerObject("/org/mpris/MediaPlayer2", this, QDBusConnection::ExportAdaptors);
}
