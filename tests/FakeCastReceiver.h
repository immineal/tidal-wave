// A fake Chromecast for tests: a local QTcpServer that speaks CASTV2 framing
// without TLS, for CastSession's plain-text test hook. It answers LAUNCH and
// LOAD the way the Default Media Receiver does; a test sends the rest.

#pragma once

#include <QByteArray>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QtEndian>

#include "cast/CastMessage.h"
#include "cast/CastSession.h"

namespace fakecast {

const QString kConnection = QStringLiteral("urn:x-cast:com.google.cast.tp.connection");
const QString kReceiver   = QStringLiteral("urn:x-cast:com.google.cast.receiver");
const QString kMedia      = QStringLiteral("urn:x-cast:com.google.cast.media");
const QString kAppId      = QStringLiteral("CC1AD845");
const QString kTransport  = QStringLiteral("web-1");

struct Received {
    QString     ns;
    QString     destination;
    QJsonObject payload;
    QString type() const { return payload.value(QStringLiteral("type")).toString(); }
};

class FakeReceiver : public QTcpServer {
public:
    enum class LoadAnswer { Plays, Fails };

    FakeReceiver()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *s = nextPendingConnection()) {
                peer = s;
                connect(s, &QTcpSocket::readyRead, this, [this] { if (m_reading) drain(); });
            }
        });
    }

    QTcpSocket     *peer = nullptr;
    QList<Received> got;
    LoadAnswer      loadAnswer   = LoadAnswer::Plays;
    int             mediaSession = 7;   // the id the next LOAD is given

    int count(const QString &ns, const QString &type) const
    {
        int n = 0;
        for (const Received &r : got) n += (r.ns == ns && r.type() == type);
        return n;
    }
    QJsonObject last(const QString &ns, const QString &type) const
    {
        for (qsizetype i = got.size() - 1; i >= 0; --i)
            if (got[i].ns == ns && got[i].type() == type) return got[i].payload;
        return {};
    }

    // Stops reading, like a device whose input is backed up.
    void stopReading()
    {
        m_reading = false;
        if (peer) peer->setReadBufferSize(4096);
    }
    void resumeReading()
    {
        m_reading = true;
        if (peer) { peer->setReadBufferSize(0); drain(); }
    }

    void send(const QString &ns, const QJsonObject &payload,
              const QString &source = QStringLiteral("receiver-0"))
    {
        CastMessage m;
        m.sourceId      = source;
        m.destinationId = QStringLiteral("sender-0");
        m.ns            = ns;
        m.payload = QString::fromUtf8(QJsonDocument(payload).toJson(QJsonDocument::Compact));
        const QByteArray body = m.encode();
        QByteArray frame(4, '\0');
        qToBigEndian<quint32>(quint32(body.size()), frame.data());
        peer->write(frame + body);
    }

    void sendMediaStatus(const QJsonObject &status)
    {
        send(kMedia, QJsonObject{{"type", "MEDIA_STATUS"}, {"requestId", 0},
                                 {"status", QJsonArray{status}}}, kTransport);
    }

private:
    void drain()
    {
        m_buf += peer->readAll();
        while (m_buf.size() >= 4) {
            const quint32 len = qFromBigEndian<quint32>(m_buf.constData());
            if (m_buf.size() < qsizetype(4 + len)) break;
            CastMessage m;
            const bool ok = CastMessage::decode(m_buf.mid(4, len), m);
            m_buf.remove(0, 4 + len);
            if (!ok) continue;
            const Received r{m.ns, m.destinationId,
                             QJsonDocument::fromJson(m.payload.toUtf8()).object()};
            got << r;
            answer(r);
        }
    }

    void answer(const Received &r)
    {
        const int requestId = r.payload.value(QStringLiteral("requestId")).toInt();
        if (r.ns == kReceiver && r.type() == QStringLiteral("LAUNCH")) {
            const QJsonObject app{{"appId", kAppId}, {"sessionId", "session-1"},
                                  {"transportId", kTransport}};
            send(kReceiver, QJsonObject{{"type", "RECEIVER_STATUS"}, {"requestId", requestId},
                                        {"status", QJsonObject{{"applications",
                                                                QJsonArray{app}}}}});
        } else if (r.ns == kMedia && r.type() == QStringLiteral("LOAD")) {
            if (loadAnswer == LoadAnswer::Fails) {
                send(kMedia, QJsonObject{{"type", "LOAD_FAILED"}, {"requestId", requestId}},
                     kTransport);
                return;
            }
            const int id = mediaSession++;
            send(kMedia, QJsonObject{{"type", "MEDIA_STATUS"}, {"requestId", requestId},
                                     {"status", QJsonArray{QJsonObject{
                                         {"mediaSessionId", id},
                                         {"playerState", "PLAYING"},
                                         {"currentTime", r.payload.value("currentTime")
                                                             .toDouble()}}}}},
                 kTransport);
        }
    }

    QByteArray m_buf;
    bool       m_reading = true;
};

// Connects `session` to `receiver` and waits until the media app is up.
inline bool connectTo(CastSession &session, FakeReceiver &receiver)
{
    QSignalSpy up(&session, &CastSession::connected);
    session.setPlainTextForTest(true);
    session.connectToDevice(QStringLiteral("127.0.0.1"), receiver.serverPort());
    return up.wait(5000) || up.count() > 0;
}

} // namespace fakecast
