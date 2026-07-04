#include "CastMediaServer.h"

#include <QTcpServer>
#include <QTcpSocket>
#include <QNetworkInterface>
#include <QFile>
#include <QFileInfo>

namespace {

// First non-loopback IPv4 address — the address the Chromecast must reach.
QString lanAddress() {
    const auto addrs = QNetworkInterface::allAddresses();
    for (const QHostAddress &a : addrs) {
        if (a.protocol() == QAbstractSocket::IPv4Protocol && !a.isLoopback())
            return a.toString();
    }
    return QString();
}

} // namespace

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
    m_pending.clear();
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
        m_pending.insert(sock, QByteArray());
        connect(sock, &QTcpSocket::readyRead, this, [this, sock]() {
            QByteArray &buf = m_pending[sock];
            buf.append(sock->readAll());
            const int end = buf.indexOf("\r\n\r\n");
            if (end >= 0)
                handleRequest(sock, buf.left(end));
        });
        connect(sock, &QTcpSocket::disconnected, this, [this, sock]() {
            m_pending.remove(sock);
            sock->deleteLater();
        });
    }
}

void CastMediaServer::handleRequest(QTcpSocket *sock, const QByteArray &request) {
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

    QFile file(m_path);
    if (m_path.isEmpty() || !file.open(QIODevice::ReadOnly)) {
        sock->write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        sock->disconnectFromHost();
        return;
    }

    const qint64 total = file.size();
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

    if (!isHead) {
        file.seek(start);
        qint64 remaining = length;
        const qint64 chunk = 64 * 1024;
        while (remaining > 0 && sock->state() == QAbstractSocket::ConnectedState) {
            const QByteArray data = file.read(qMin(chunk, remaining));
            if (data.isEmpty()) break;
            sock->write(data);
            sock->waitForBytesWritten(5000);   // backpressure to the device
            remaining -= data.size();
        }
    }
    file.close();
    sock->disconnectFromHost();
}
