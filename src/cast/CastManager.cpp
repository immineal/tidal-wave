#include "CastManager.h"
#include "CastDiscovery.h"
#include "CastSession.h"
#include "CastMediaServer.h"
#include "CastMediaPrep.h"
#include "player/Player.h"

#include <QVariantMap>

CastManager::CastManager(TidalClient *client, Player *player, QObject *parent)
    : QObject(parent), m_client(client), m_player(player) {
    m_discovery = new CastDiscovery(this);
    m_session   = new CastSession(this);
    m_server    = new CastMediaServer(this);
    m_prep      = new CastMediaPrep(client, this);

    connect(m_discovery, &CastDiscovery::deviceFound,   this, &CastManager::onDeviceFound);
    connect(m_discovery, &CastDiscovery::deviceRemoved, this, &CastManager::onDeviceRemoved);

    connect(m_session, &CastSession::connected,    this, &CastManager::onSessionConnected);
    connect(m_session, &CastSession::disconnected, this, &CastManager::onSessionDisconnected);
    connect(m_session, &CastSession::error, this, [this](const QString &m) { emit error(m); });

    // Device media status → Player (feeds the existing position/duration/playing UI).
    connect(m_session, &CastSession::positionChanged, this,
            [this](double s) { if (m_player) m_player->onCastPosition(s); });
    connect(m_session, &CastSession::durationChanged, this,
            [this](double s) { if (m_player) m_player->onCastDuration(s); });
    connect(m_session, &CastSession::playingChanged, this,
            [this](bool p) { if (m_player) m_player->onCastPlaying(p); });
    connect(m_session, &CastSession::mediaFinished, this,
            [this]() { if (m_player) m_player->next(); });

    // When prep yields a servable file, serve it and LOAD it on the device.
    connect(m_prep, &CastMediaPrep::ready, this, [this](const QString &path, const QString &mime) {
        const QString url = m_server->setCurrentFile(path, mime);
        if (url.isEmpty()) { emit error(QStringLiteral("No LAN address for casting")); return; }
        const QVariantMap t = m_player ? m_player->currentTrackMap() : QVariantMap();
        QString art;
        const QString cover = t.value(QStringLiteral("albumCover")).toString();
        if (!cover.isEmpty())
            art = QStringLiteral("https://resources.tidal.com/images/%1/640x640.jpg")
                      .arg(QString(cover).replace('-', '/'));
        m_session->loadMedia(url, mime,
                             t.value(QStringLiteral("title")).toString(),
                             t.value(QStringLiteral("artists")).toString(),
                             t.value(QStringLiteral("albumTitle")).toString(),
                             art, t.value(QStringLiteral("duration")).toDouble());
    });
    connect(m_prep, &CastMediaPrep::failed, this, [this](const QString &m) { emit error(m); });

    // Track changed while casting → re-prepare + re-load on the device.
    connect(m_player, &Player::castTrackChanged, this, &CastManager::castCurrentTrack);
}

CastManager::~CastManager() = default;

QVariantList CastManager::devices() const {
    QVariantList out;
    for (const Device &d : m_devices) {
        QVariantMap m;
        m.insert(QStringLiteral("id"), d.id);
        m.insert(QStringLiteral("name"), d.name);
        out.append(m);
    }
    return out;
}

void CastManager::startScan() {
    m_discovery->start();
}

void CastManager::onDeviceFound(const QString &id, const QString &name,
                                const QString &host, int port) {
    m_devices.insert(id, Device{id, name, host, port});
    emit devicesChanged();
}

void CastManager::onDeviceRemoved(const QString &id) {
    if (m_devices.remove(id) > 0)
        emit devicesChanged();
}

void CastManager::connectToDevice(const QString &id) {
    if (!m_devices.contains(id)) return;
    const Device d = m_devices.value(id);
    if (m_server->start().isEmpty()) {
        emit error(QStringLiteral("Could not start the local media server"));
        return;
    }
    m_deviceName = d.name;
    emit connectedChanged();               // reflect "connecting…" name immediately
    m_session->connectToDevice(d.host, d.port);
}

void CastManager::disconnect() {
    m_session->disconnectFromDevice();
    onSessionDisconnected();
}

void CastManager::onSessionConnected() {
    m_connected = true;
    if (m_player) m_player->beginCast(m_session);
    emit connectedChanged();
    castCurrentTrack();
}

void CastManager::onSessionDisconnected() {
    const bool was = m_connected;
    m_connected = false;
    const bool hadName = !m_deviceName.isEmpty();
    m_deviceName.clear();
    if (m_prep) m_prep->cancel();
    if (m_player && was) m_player->endCast();
    if (was || hadName) emit connectedChanged();
}

void CastManager::castCurrentTrack() {
    if (!m_connected || !m_player) return;
    const qlonglong id = m_player->currentTrackId();
    if (id > 0) m_prep->prepare(id);
}
