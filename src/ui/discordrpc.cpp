#include "discordrpc.h"
#include <QCoreApplication>
#include <QFile>
#include <QDateTime>
#include <QtEndian>
#include <QDebug>
#include <unistd.h>

DiscordRPC::DiscordRPC(QObject *parent)
    : QObject(parent)
    , m_socket(new QLocalSocket(this))
    , m_reconnectTimer(new QTimer(this))
    , m_clientId("465997235547635712") // Official TIDAL client ID
    , m_connected(false)
{
    connect(m_socket, &QLocalSocket::connected, this, &DiscordRPC::onConnected);
    connect(m_socket, &QLocalSocket::disconnected, this, &DiscordRPC::onDisconnected);
#if QT_VERSION >= QT_VERSION_CHECK(5, 15, 0)
    connect(m_socket, &QLocalSocket::errorOccurred, this, &DiscordRPC::onError);
#else
    connect(m_socket, static_cast<void(QLocalSocket::*)(QLocalSocket::LocalSocketError)>(&QLocalSocket::error), this, &DiscordRPC::onError);
#endif

    m_reconnectTimer->setInterval(10000); // Reconnect timer every 10 seconds
    connect(m_reconnectTimer, &QTimer::timeout, this, &DiscordRPC::tryConnect);

    tryConnect();
}

DiscordRPC::~DiscordRPC()
{
    clearActivity();
    m_socket->close();
}

QString DiscordRPC::getSocketPath()
{
    QString path = QString::fromLocal8Bit(qgetenv("XDG_RUNTIME_DIR"));
    if (path.isEmpty()) {
        path = QString("/run/user/%1").arg(getuid());
    }

    // Try discord-ipc-0 to discord-ipc-9 in runtime folder
    for (int i = 0; i < 10; ++i) {
        QString socketPath = QString("%1/discord-ipc-%2").arg(path).arg(i);
        if (QFile::exists(socketPath)) {
            return socketPath;
        }
    }

    // Try /tmp/discord-ipc-0 to 9 as fallback
    for (int i = 0; i < 10; ++i) {
        QString socketPath = QString("/tmp/discord-ipc-%1").arg(i);
        if (QFile::exists(socketPath)) {
            return socketPath;
        }
    }

    return QString();
}

void DiscordRPC::tryConnect()
{
    if (m_connected || m_socket->state() == QLocalSocket::ConnectingState || m_socket->state() == QLocalSocket::ConnectedState) {
        return;
    }

    QString socketPath = getSocketPath();
    if (!socketPath.isEmpty()) {
        m_socket->connectToServer(socketPath);
    }
}

void DiscordRPC::onConnected()
{
    m_connected = true;
    m_reconnectTimer->stop();

    // Handshake packet (Opcode 0)
    QJsonObject handshake;
    handshake["v"] = 1;
    handshake["client_id"] = m_clientId;
    sendPacket(0, handshake);
}

void DiscordRPC::onDisconnected()
{
    m_connected = false;
    m_reconnectTimer->start();
}

void DiscordRPC::onError(QLocalSocket::LocalSocketError socketError)
{
    Q_UNUSED(socketError);
    m_connected = false;
    m_reconnectTimer->start();
}

void DiscordRPC::sendPacket(int opcode, const QJsonObject &payload)
{
    if (m_socket->state() != QLocalSocket::ConnectedState) {
        return;
    }

    QJsonDocument doc(payload);
    QByteArray body = doc.toJson(QJsonDocument::Compact);

    QByteArray header;
    header.resize(8);

    // Format header: Opcode (4 bytes LE) + Length (4 bytes LE)
    quint32 op = static_cast<quint32>(opcode);
    quint32 len = static_cast<quint32>(body.length());
    qToLittleEndian(op, reinterpret_cast<uchar*>(header.data()));
    qToLittleEndian(len, reinterpret_cast<uchar*>(header.data() + 4));

    m_socket->write(header);
    m_socket->write(body);
    m_socket->flush();
}

void DiscordRPC::updateActivity(const QString &title, const QString &artist, const QString &album,
                                const QString &artUrl, double position, double duration, bool playing)
{
    if (!m_connected) return;

    QJsonObject activity;
    activity["details"] = title.left(128);
    activity["state"] = QString("by %1").arg(artist).left(128);

    QJsonObject assets;
    if (!artUrl.isEmpty()) {
        assets["large_image"] = artUrl;
    } else {
        assets["large_image"] = QString("tidal"); // Default asset name if registered
    }
    assets["large_text"] = album.isEmpty() ? QString("TIDAL") : album.left(128);
    activity["assets"] = assets;

    // Handle timestamps for progress display
    if (playing && duration > 0) {
        qint64 now = QDateTime::currentMSecsSinceEpoch() / 1000;
        qint64 start = now - static_cast<qint64>(position);
        qint64 end = start + static_cast<qint64>(duration);

        QJsonObject timestamps;
        timestamps["start"] = start;
        timestamps["end"] = end;
        activity["timestamps"] = timestamps;
    }

    QJsonObject args;
    args["pid"] = static_cast<int>(getpid());
    args["activity"] = activity;

    QJsonObject payload;
    payload["cmd"] = "SET_ACTIVITY";
    payload["args"] = args;
    payload["nonce"] = QString::number(QDateTime::currentMSecsSinceEpoch());

    sendPacket(1, payload); // Frame packet (Opcode 1)
}

void DiscordRPC::clearActivity()
{
    if (!m_connected) return;

    QJsonObject args;
    args["pid"] = static_cast<int>(getpid());
    args["activity"] = QJsonValue::Null;

    QJsonObject payload;
    payload["cmd"] = "SET_ACTIVITY";
    payload["args"] = args;
    payload["nonce"] = QString::number(QDateTime::currentMSecsSinceEpoch());

    sendPacket(1, payload);
}
