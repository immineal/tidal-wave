// SPDX-License-Identifier: GPL-3.0-or-later

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

    // After these the position is compared with the reckoned one as well.
    const auto stateChanged = [this] {
        m_stateChanged = true;
        scheduleAnnounce();
    };
    connect(m_player, &Player::playingChanged,      this, stateChanged);
    connect(m_player, &Player::loadingChanged,      this, stateChanged);
    connect(m_player, &Player::currentTrackChanged, this, stateChanged);
    connect(m_player, &Player::seeked, this, [this] {
        m_seeked = true;
        scheduleAnnounce();
    });
    // These leave the position alone. A cast device's is too old to compare.
    connect(m_player, &Player::currentIndexChanged, this, &MprisPlayer::scheduleAnnounce);
    connect(m_player, &Player::queueChanged,        this, &MprisPlayer::scheduleAnnounce);
    connect(m_player, &Player::repeatModeChanged,   this, &MprisPlayer::scheduleAnnounce);

    m_announced    = announcedProperties();
    m_trackId      = m_player->currentTrackMap().value(QStringLiteral("id")).toLongLong();
    m_reckonedFrom = m_player->position();
    m_reckonedSince.start();
}

qint64 MprisPlayer::reckonedPosition() const {
    const bool counting =
        m_announced.value(QStringLiteral("PlaybackStatus")) == QLatin1String("Playing");
    return m_reckonedFrom + (counting ? m_reckonedSince.elapsed() : 0);
}

QVariantMap MprisPlayer::announcedProperties() const {
    return {
        { QStringLiteral("PlaybackStatus"), playbackStatus() },
        { QStringLiteral("Metadata"),       metadata() },
        { QStringLiteral("CanGoNext"),      canGoNext() },
        { QStringLiteral("CanGoPrevious"),  canGoPrevious() },
        { QStringLiteral("CanPlay"),        canPlay() },
        { QStringLiteral("CanPause"),       canPause() },
        { QStringLiteral("CanSeek"),        canSeek() },
    };
}

void MprisPlayer::scheduleAnnounce() {
    if (m_announceQueued) return;
    m_announceQueued = true;
    QMetaObject::invokeMethod(this, &MprisPlayer::announce, Qt::QueuedConnection);
}

void MprisPlayer::announce() {
    m_announceQueued = false;
    const QVariantMap now = announcedProperties();
    QVariantMap changed;
    for (auto it = now.cbegin(); it != now.cend(); ++it)
        if (m_announced.value(it.key()) != it.value()) changed.insert(it.key(), it.value());

    // A client starts a new track at 0, and counts on from where it was only
    // while the status is Playing.
    const qlonglong trackId =
        m_player->currentTrackMap().value(QStringLiteral("id")).toLongLong();
    if (trackId != m_trackId || changed.contains(QStringLiteral("PlaybackStatus"))) {
        m_reckonedFrom = trackId != m_trackId ? 0 : reckonedPosition();
        m_reckonedSince.restart();
        m_trackId = trackId;
    }

    if (!changed.isEmpty()) {
        m_announced = now;
        QDBusMessage msg = QDBusMessage::createSignal(
            "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged");
        msg << "org.mpris.MediaPlayer2.Player" << changed << QStringList();
        QDBusConnection::sessionBus().send(msg);
    }

    // Seeked is for a position that the client cannot have reckoned.
    if (!m_seeked && !m_stateChanged) return;
    m_stateChanged = false;
    const qint64 at = m_player->position();
    if (m_seeked || qAbs(at - reckonedPosition()) > kReckoningSlackMs) {
        m_seeked       = false;
        m_reckonedFrom = at;
        m_reckonedSince.restart();
        emit Seeked(at * 1000LL);
    }
}

QString MprisPlayer::playbackStatus() const {
    if (m_player->currentTrackMap().isEmpty()) return QStringLiteral("Stopped");
    // A load that ends in playback counts as playing, so a widget does not
    // show a pause between one track and the next.
    if (m_player->playing() || m_player->startingPlayback()) return QStringLiteral("Playing");
    return QStringLiteral("Paused");
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

// "If playback is paused or stopped, it remains that way."
void MprisPlayer::Next()      { m_player->next(playbackStatus() != QLatin1String("Playing")); }
void MprisPlayer::Previous()  { m_player->previous(playbackStatus() != QLatin1String("Playing")); }
void MprisPlayer::Pause()     { if (m_player->playing()) m_player->playPause(); }
void MprisPlayer::Play()      { if (!m_player->playing()) m_player->playPause(); }
void MprisPlayer::PlayPause() { m_player->playPause(); }
void MprisPlayer::Stop()      { m_player->seek(0); Pause(); }
void MprisPlayer::Seek(qlonglong offsetMicros) { m_player->seek(m_player->position() + offsetMicros/1000); }
void MprisPlayer::SetPosition(const QDBusObjectPath &trackId, qlonglong posMicros) {
    // A call that names another track was meant for one that has since gone.
    const QVariantMap current = metadata();
    if (trackId != current.value(QStringLiteral("mpris:trackid")).value<QDBusObjectPath>()) return;
    const qlonglong length = current.value(QStringLiteral("mpris:length")).toLongLong();
    if (posMicros < 0 || (length > 0 && posMicros > length)) return;
    m_player->seek(posMicros / 1000);
}

MprisManager::MprisManager(Player *player, QObject *parent) : QObject(parent) {
    m_root        = new MprisRoot(this);
    m_mprisPlayer = new MprisPlayer(player, this);

    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.registerService("org.mpris.MediaPlayer2.tidalwave");
    bus.registerObject("/org/mpris/MediaPlayer2", this, QDBusConnection::ExportAdaptors);
}
