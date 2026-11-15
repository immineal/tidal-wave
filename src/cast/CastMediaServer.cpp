// SPDX-License-Identifier: GPL-3.0-or-later

#include "CastMediaServer.h"

#include <QTcpServer>
#include <QTcpSocket>
#include <QNetworkInterface>
#include <QFile>
#include <QFileInfo>

namespace {

// First non-loopback IPv4 address, which the Chromecast must reach.
QString lanAddress() {
    const auto addrs = QNetworkInterface::allAddresses();
    for (const QHostAddress &a : addrs) {
        if (a.protocol() == QAbstractSocket::IPv4Protocol && !a.isLoopback())
            return a.toString();
    }
    return QString();
}

constexpr qint64 kChunk     = 64 * 1024;
// Bytes kept queued per connection. A receiver that stops reading holds this
// much of the app's memory and no more.
constexpr qint64 kHighWater = 256 * 1024;

} // namespace

// Owned by its socket, so it goes when the connection does.
struct CastMediaServer::Transfer : QObject {
    explicit Transfer(QTcpSocket *sock) : QObject(sock) {}
    QByteArray request;
    bool       answered  = false;
    QFile      file;
    qint64     remaining = 0;
};

CastMediaServer::CastMediaServer(QObject *parent) : QObject(parent) {}

CastMediaServer::~CastMediaServer() {
    stop();
}

QString CastMediaServer::start() {
    if (m_server && m_server->isListening())
        return m_baseUrl;

    const QString ip = lanAddress();
    if (ip.isEmpty())
        return QString();

    if (!m_server) {
        m_server = new QTcpServer(this);
        connect(m_server, &QTcpServer::newConnection, this, &CastMediaServer::onNewConnection);
    }
    if (!m_server->listen(QHostAddress(ip), 0))   // 0 = ephemeral port
        return QString();

    m_baseUrl = QStringLiteral("http://%1:%2").arg(ip).arg(m_server->serverPort());
    return m_baseUrl;
}

void CastMediaServer::stop() {
    if (m_server) {
        m_server->close();
        m_server->deleteLater();
        m_server = nullptr;
    }
    m_baseUrl.clear();
    m_path.clear();
}

bool CastMediaServer::isListening() const {
    return m_server && m_server->isListening();
}

QString CastMediaServer::setCurrentFile(const QString &path, const QString &mime) {
    m_path = path;
    m_mime = mime;
    ++m_token;
    if (m_baseUrl.isEmpty())
        return QString();
    return QStringLiteral("%1/track?v=%2").arg(m_baseUrl).arg(m_token);
}

void CastMediaServer::onNewConnection() {
    while (m_server && m_server->hasPendingConnections()) {
        QTcpSocket *sock = m_server->nextPendingConnection();
        auto *t = new Transfer(sock);
        connect(sock, &QTcpSocket::readyRead, this, [this, sock, t]() {
            if (t->answered) { sock->readAll(); return; }
            t->request.append(sock->readAll());
            const int end = t->request.indexOf("\r\n\r\n");
            if (end < 0) return;
            t->answered = true;
            handleRequest(sock, t, t->request.left(end));
        });
        // Topped up as the receiver drains it, never waited for.
        connect(sock, &QTcpSocket::bytesWritten, t, [this, sock, t]() { pump(sock, t); });
        connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
    }
}

void CastMediaServer::pump(QTcpSocket *sock, Transfer *t) {
    if (!t->file.isOpen()) return;
    while (t->remaining > 0 && sock->bytesToWrite() < kHighWater) {
        const QByteArray data = t->file.read(qMin(kChunk, t->remaining));
        if (data.isEmpty()) { t->remaining = 0; break; }
        sock->write(data);
        t->remaining -= data.size();
    }
    if (t->remaining <= 0) {
        t->file.close();
        sock->disconnectFromHost();   // after what is queued has gone out
    }
}

void CastMediaServer::handleRequest(QTcpSocket *sock, Transfer *t, const QByteArray &request) {
    const QList<QByteArray> lines = request.split('\n');
    if (lines.isEmpty()) { sock->disconnectFromHost(); return; }

    const QByteArray requestLine = lines.first().trimmed();
    const bool isHead = requestLine.startsWith("HEAD");

    // Parse a Range: bytes=start-end header if present.
    qint64 rangeStart = -1, rangeEnd = -1;
    for (const QByteArray &l : lines) {
        const QByteArray line = l.trimmed();
        if (line.toLower().startsWith("range:")) {
            const int eq = line.indexOf('=');
            if (eq >= 0) {
                const QByteArray spec = line.mid(eq + 1).trimmed();
                const int dash = spec.indexOf('-');
                if (dash >= 0) {
                    rangeStart = spec.left(dash).toLongLong();
                    const QByteArray endStr = spec.mid(dash + 1);
                    if (!endStr.isEmpty()) rangeEnd = endStr.toLongLong();
                }
            }
            break;
        }
    }

    t->file.setFileName(m_path);
    if (m_path.isEmpty() || !t->file.open(QIODevice::ReadOnly)) {
        sock->write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        sock->disconnectFromHost();
        return;
    }

    const qint64 total = t->file.size();
    qint64 start = 0, end = total - 1;
    bool partial = false;
    if (rangeStart >= 0) {
        partial = true;
        start = qBound<qint64>(0, rangeStart, total - 1);
        end   = (rangeEnd >= 0) ? qBound<qint64>(start, rangeEnd, total - 1) : total - 1;
    }
    const qint64 length = end - start + 1;

    QByteArray headers;
    headers += partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
    headers += "Content-Type: " + m_mime.toUtf8() + "\r\n";
    headers += "Accept-Ranges: bytes\r\n";
    headers += "Content-Length: " + QByteArray::number(length) + "\r\n";
    if (partial)
        headers += "Content-Range: bytes " + QByteArray::number(start) + "-" +
                   QByteArray::number(end) + "/" + QByteArray::number(total) + "\r\n";
    headers += "Connection: close\r\n\r\n";
    sock->write(headers);

    t->remaining = isHead ? 0 : length;
    t->file.seek(start);
    pump(sock, t);
}
