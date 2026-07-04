#include "CastSession.h"
#include "CastMessage.h"

#include <QSslSocket>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QtEndian>

namespace {
const QString NS_CONNECTION = QStringLiteral("urn:x-cast:com.google.cast.tp.connection");
const QString NS_HEARTBEAT  = QStringLiteral("urn:x-cast:com.google.cast.tp.heartbeat");
const QString NS_RECEIVER   = QStringLiteral("urn:x-cast:com.google.cast.receiver");
const QString NS_MEDIA      = QStringLiteral("urn:x-cast:com.google.cast.media");
const QString SENDER        = QStringLiteral("sender-0");
const QString RECEIVER      = QStringLiteral("receiver-0");
const QString MEDIA_APP_ID  = QStringLiteral("CC1AD845");   // Default Media Receiver

QString jsonToString(const QJsonObject &o) {
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}
} // namespace

CastSession::CastSession(QObject *parent) : QObject(parent) {}

CastSession::~CastSession() {
    disconnectFromDevice();
}

void CastSession::connectToDevice(const QString &host, int port) {
    disconnectFromDevice();

    m_socket = new QSslSocket(this);
    // Chromecast devices present a self-signed certificate — expected for CASTV2.
    m_socket->setPeerVerifyMode(QSslSocket::VerifyNone);
    connect(m_socket, &QSslSocket::encrypted, this, &CastSession::onEncrypted);
    connect(m_socket, &QSslSocket::readyRead, this, &CastSession::onReadyRead);
    connect(m_socket, &QSslSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        emit error(m_socket ? m_socket->errorString() : QStringLiteral("socket error"));
    });
    connect(m_socket, &QSslSocket::disconnected, this, [this]() {
        m_appConnected = false;
        emit disconnected();
    });
    m_socket->ignoreSslErrors();
    m_socket->connectToHostEncrypted(host, quint16(port));

    if (!m_timer) {
        m_timer = new QTimer(this);
        m_timer->setInterval(1000);
        connect(m_timer, &QTimer::timeout, this, &CastSession::onTick);
    }
}

void CastSession::disconnectFromDevice() {
    if (m_timer) m_timer->stop();
    if (m_socket) {
        m_socket->disconnect(this);
        m_socket->abort();
        m_socket->deleteLater();
        m_socket = nullptr;
    }
    m_buffer.clear();
    m_transportId.clear();
    m_mediaSessionId = 0;
    m_appConnected = false;
    m_haveLoad = false;
    m_loadPayload.clear();
}

void CastSession::onEncrypted() {
    // Open the sender's virtual connection to the receiver, then launch the app.
    sendMessage(NS_CONNECTION, RECEIVER, jsonToString({{"type", "CONNECT"}}));
    QJsonObject launch{{"type", "LAUNCH"}, {"requestId", nextRequestId()}, {"appId", MEDIA_APP_ID}};
    sendMessage(NS_RECEIVER, RECEIVER, jsonToString(launch));
    if (m_timer) m_timer->start();
}

void CastSession::sendMessage(const QString &ns, const QString &destination,
                              const QString &payloadJson) {
    if (!m_socket || m_socket->state() != QAbstractSocket::ConnectedState)
        return;
    CastMessage m;
    m.sourceId      = SENDER;
    m.destinationId = destination;
    m.ns            = ns;
    m.payload       = payloadJson;
    const QByteArray body = m.encode();
    QByteArray frame;
    frame.resize(4);
    qToBigEndian<quint32>(quint32(body.size()), frame.data());
    frame.append(body);
    m_socket->write(frame);
}

void CastSession::onReadyRead() {
    if (!m_socket) return;
    m_buffer.append(m_socket->readAll());
    // Frames are: 4-byte big-endian length + protobuf body.
    while (m_buffer.size() >= 4) {
        const quint32 len = qFromBigEndian<quint32>(m_buffer.constData());
        if (m_buffer.size() < int(4 + len)) break;
        const QByteArray body = m_buffer.mid(4, int(len));
        m_buffer.remove(0, int(4 + len));
        CastMessage msg;
        if (CastMessage::decode(body, msg))
            handleMessage(msg);
    }
}

void CastSession::handleMessage(const CastMessage &msg) {
    const QJsonObject payload =
        QJsonDocument::fromJson(msg.payload.toUtf8()).object();
    const QString type = payload.value("type").toString();

    if (msg.ns == NS_HEARTBEAT) {
        if (type == "PING")
            sendMessage(NS_HEARTBEAT, RECEIVER, jsonToString({{"type", "PONG"}}));
        return;
    }

    if (msg.ns == NS_RECEIVER && type == "RECEIVER_STATUS") {
        const QJsonArray apps = payload.value("status").toObject().value("applications").toArray();
        for (const QJsonValue &a : apps) {
            const QJsonObject app = a.toObject();
            if (app.value("appId").toString() == MEDIA_APP_ID) {
                establishAppConnection(app.value("transportId").toString());
                return;
            }
        }
        return;
    }

    if (msg.ns == NS_MEDIA && type == "MEDIA_STATUS") {
        const QJsonArray statusArr = payload.value("status").toArray();
        if (statusArr.isEmpty()) return;
        const QJsonObject st = statusArr.first().toObject();
        if (st.contains("mediaSessionId"))
            m_mediaSessionId = st.value("mediaSessionId").toInt();
        if (st.contains("media") && st.value("media").toObject().contains("duration"))
            emit durationChanged(st.value("media").toObject().value("duration").toDouble());
        if (st.contains("currentTime"))
            emit positionChanged(st.value("currentTime").toDouble());
        const QString playerState = st.value("playerState").toString();
        if (!playerState.isEmpty())
            emit playingChanged(playerState == "PLAYING");
        if (playerState == "IDLE" && st.value("idleReason").toString() == "FINISHED")
            emit mediaFinished();
        return;
    }
}

void CastSession::establishAppConnection(const QString &transportId) {
    if (transportId.isEmpty() || transportId == m_transportId)
        return;
    m_transportId = transportId;
    // Virtual connection to the media app is required before media messages.
    sendMessage(NS_CONNECTION, m_transportId, jsonToString({{"type", "CONNECT"}}));
    m_appConnected = true;
    emit connected();
    if (m_haveLoad)
        sendLoad();
}

void CastSession::loadMedia(const QString &url, const QString &contentType,
                            const QString &title, const QString &artist,
                            const QString &album, const QString &artUrl, double durationSec) {
    QJsonObject metadata{{"metadataType", 3}, {"title", title},
                         {"artist", artist}, {"albumName", album}};
    if (!artUrl.isEmpty())
        metadata.insert("images", QJsonArray{QJsonObject{{"url", artUrl}}});

    QJsonObject media{{"contentId", url}, {"streamType", "BUFFERED"},
                      {"contentType", contentType}, {"metadata", metadata}};
    if (durationSec > 0)
        media.insert("duration", durationSec);

    QJsonObject load{{"type", "LOAD"}, {"requestId", nextRequestId()},
                     {"media", media}, {"autoplay", true}};
    m_loadPayload = jsonToString(load);
    m_haveLoad = true;
    if (m_appConnected)
        sendLoad();
}

void CastSession::sendLoad() {
    if (!m_loadPayload.isEmpty())
        sendMessage(NS_MEDIA, m_transportId, m_loadPayload);
}

void CastSession::play() {
    if (m_mediaSessionId)
        sendMessage(NS_MEDIA, m_transportId,
                    jsonToString({{"type", "PLAY"}, {"requestId", nextRequestId()},
                                  {"mediaSessionId", m_mediaSessionId}}));
}

void CastSession::pause() {
    if (m_mediaSessionId)
        sendMessage(NS_MEDIA, m_transportId,
                    jsonToString({{"type", "PAUSE"}, {"requestId", nextRequestId()},
                                  {"mediaSessionId", m_mediaSessionId}}));
}

void CastSession::seek(double sec) {
    if (m_mediaSessionId)
        sendMessage(NS_MEDIA, m_transportId,
                    jsonToString({{"type", "SEEK"}, {"requestId", nextRequestId()},
                                  {"mediaSessionId", m_mediaSessionId}, {"currentTime", sec}}));
}

void CastSession::stopMedia() {
    if (m_mediaSessionId)
        sendMessage(NS_MEDIA, m_transportId,
                    jsonToString({{"type", "STOP"}, {"requestId", nextRequestId()},
                                  {"mediaSessionId", m_mediaSessionId}}));
}

void CastSession::setVolume(double level) {
    QJsonObject vol{{"level", qBound(0.0, level, 1.0)}};
    sendMessage(NS_RECEIVER, RECEIVER,
                jsonToString({{"type", "SET_VOLUME"}, {"requestId", nextRequestId()},
                              {"volume", vol}}));
}

void CastSession::onTick() {
    if (!m_appConnected) return;
    ++m_tick;
    if (m_tick % 5 == 0)                 // heartbeat PING every 5s
        sendMessage(NS_HEARTBEAT, RECEIVER, jsonToString({{"type", "PING"}}));
    if (m_mediaSessionId)                // poll media status for smooth position
        sendMessage(NS_MEDIA, m_transportId,
                    jsonToString({{"type", "GET_STATUS"}, {"requestId", nextRequestId()},
                                  {"mediaSessionId", m_mediaSessionId}}));
}
