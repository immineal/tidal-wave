// SPDX-License-Identifier: GPL-3.0-or-later

#include "CastMediaServer.h"

#include <QTcpServer>
#include <QTcpSocket>
#include <QNetworkInterface>
#include <QFile>
#include <QFileInfo>
#include <QRandomGenerator>

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

constexpr qint64 kChunk      = 64 * 1024;
constexpr qint64 kMaxRequest = 16 * 1024;   // a receiver's GET is well under 1 KiB
// Bytes kept queued per connection. A receiver that stops reading holds this
// much of the app's memory and no more.
constexpr qint64 kHighWater = 256 * 1024;

bool isDigits(const QByteArray &s) {
    if (s.isEmpty()) return false;
    for (char ch : s)
        if (ch < '0' || ch > '9') return false;
    return true;
}

struct ByteRange {
    enum Kind { Whole, Part, Unsatisfiable } kind = Whole;
    qint64 first = 0, last = 0;
};

// A Range header against a file of `size` bytes, after RFC 9110 section 14.
// What it cannot parse, another unit or several ranges is ignored: the whole
// file is an answer the RFC allows to all three.
ByteRange parseRange(const QByteArray &value, qint64 size) {
    const int eq = value.indexOf('=');
    if (eq < 0 || value.left(eq).trimmed().toLower() != "bytes") return {};
    const QByteArray set = value.mid(eq + 1).trimmed();
    if (set.contains(',')) return {};
    const int dash = set.indexOf('-');
    if (dash < 0) return {};
    const QByteArray a = set.left(dash).trimmed();
    const QByteArray b = set.mid(dash + 1).trimmed();

    bool ok = false;
    if (a.isEmpty()) {                        // bytes=-N: the last N bytes
        if (!isDigits(b)) return {};
        qint64 n = b.toLongLong(&ok);
        if (!ok) n = size;                    // more digits than qint64: all of it
        if (n == 0 || size == 0) return {ByteRange::Unsatisfiable};
        return {ByteRange::Part, qMax<qint64>(0, size - n), size - 1};
    }
    if (!isDigits(a) || (!b.isEmpty() && !isDigits(b))) return {};
    const qint64 first = a.toLongLong(&ok);
    if (!ok || first >= size) return {ByteRange::Unsatisfiable};
    qint64 last = size - 1;                   // bytes=N-: open to the end
    if (!b.isEmpty()) {
        const qint64 l = b.toLongLong(&ok);
        if (ok && l < first) return {};      // invalid, so ignored
        if (ok) last = qMin(l, size - 1);
    }
    return {ByteRange::Part, first, last};
}

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
    m_token.clear();
}

bool CastMediaServer::isListening() const {
    return m_server && m_server->isListening();
}

QString CastMediaServer::setCurrentFile(const QString &path, const QString &mime) {
    m_path = path;
    m_mime = mime;
    // Anyone on the LAN reaches the port, so the path is the secret.
    quint32 words[4];
    QRandomGenerator::system()->fillRange(words);
    m_token = QByteArray(reinterpret_cast<const char *>(words), sizeof(words)).toHex();
    if (m_baseUrl.isEmpty())
        return QString();
    return m_baseUrl + QStringLiteral("/track/") + QString::fromLatin1(m_token);
}

void CastMediaServer::onNewConnection() {
    while (m_server && m_server->hasPendingConnections()) {
        QTcpSocket *sock = m_server->nextPendingConnection();
        auto *t = new Transfer(sock);
        connect(sock, &QTcpSocket::readyRead, this, [this, sock, t]() {
            if (t->answered) { sock->readAll(); return; }
            t->request.append(sock->readAll());
            const int end = t->request.indexOf("\r\n\r\n");
            if (end < 0 && t->request.size() > kMaxRequest) {
                t->answered = true;
                reply(sock, "431 Request Header Fields Too Large");
                return;
            }
            if (end < 0) return;
            t->answered = true;
            handleRequest(sock, t, t->request.left(end));
        });
        // Topped up as the receiver drains it, never waited for.
        connect(sock, &QTcpSocket::bytesWritten, t, [this, sock, t]() { pump(sock, t); });
        connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
    }
}

void CastMediaServer::reply(QTcpSocket *sock, const QByteArray &status,
                            const QByteArray &headers) {
    sock->write("HTTP/1.1 " + status + "\r\n" + headers
                + "Content-Length: 0\r\nConnection: close\r\n\r\n");
    sock->disconnectFromHost();
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

    // Request line: METHOD SP target SP version. The query plays no part.
    const QList<QByteArray> parts = lines.first().trimmed().split(' ');
    const QByteArray method = parts.value(0);
    const QByteArray target = parts.value(1);
    const qsizetype  query  = target.indexOf('?');
    const QByteArray path   = query < 0 ? target : target.left(query);
    if (parts.size() != 3 || m_token.isEmpty() || path != "/track/" + m_token) {
        reply(sock, "404 Not Found");
        return;
    }
    if (method != "GET" && method != "HEAD") {
        reply(sock, "405 Method Not Allowed", "Allow: GET, HEAD\r\n");
        return;
    }
    const bool isHead = method == "HEAD";

    QByteArray rangeHeader;
    for (const QByteArray &l : lines) {
        const int colon = l.indexOf(':');
        if (colon > 0 && l.left(colon).trimmed().toLower() == "range") {
            rangeHeader = l.mid(colon + 1).trimmed();
            break;
        }
    }

    t->file.setFileName(m_path);
    if (m_path.isEmpty() || !t->file.open(QIODevice::ReadOnly)) {
        reply(sock, "404 Not Found");
        return;
    }

    const qint64    total = t->file.size();
    const ByteRange range = parseRange(rangeHeader, total);
    if (range.kind == ByteRange::Unsatisfiable) {
        reply(sock, "416 Range Not Satisfiable",
              "Content-Range: bytes */" + QByteArray::number(total) + "\r\n");
        return;
    }
    const bool   partial = range.kind == ByteRange::Part;
    const qint64 start   = partial ? range.first : 0;
    const qint64 end     = partial ? range.last  : total - 1;
    const qint64 length  = end - start + 1;

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
