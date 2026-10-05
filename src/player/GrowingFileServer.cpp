#include "GrowingFileServer.h"

#include <QHostAddress>
#include <QRandomGenerator>
#include <QTcpServer>
#include <QTcpSocket>

namespace {

// How much is allowed to sit in one socket's write queue before the pump stops
// filling it. Writing the whole of what is ready in one go would copy the track
// into memory, which is the thing joining it on disk avoids.
constexpr qint64 kSocketHighWater = 256 * 1024;

// One read from the growing file per turn of the loop below.
constexpr qint64 kReadChunk = 64 * 1024;

// Request heads longer than this are not requests this serves.
constexpr int kMaxRequestHead = 8 * 1024;

QByteArray mintToken()
{
    // 128 bits from the system generator: this URL is the only thing between
    // another local process and the track.
    QByteArray t;
    t.reserve(32);
    for (int i = 0; i < 4; ++i)
        t += QByteArray::number(QRandomGenerator::system()->generate(), 16).rightJustified(8, '0');
    return t;
}

} // namespace

GrowingFileServer::GrowingFileServer(QObject *parent) : QObject(parent) {}

GrowingFileServer::~GrowingFileServer()
{
    stop();
}

QString GrowingFileServer::serve(const QString &path, const QString &mime, qint64 bytesReady)
{
    // Whatever was being served is not this track. Dropping the connections is
    // what stops a QMediaPlayer that has not noticed the change from carrying on
    // reading the previous file through a handle this one is about to retarget.
    const auto previous = m_conns.keys();
    for (QTcpSocket *s : previous)
        s->abort();
    m_conns.clear();
    m_pending.clear();

    m_file.close();
    m_path = path;
    m_mime = mime;
    m_bytesReady = qMax<qint64>(0, bytesReady);
    m_complete = false;
    m_target = "/" + mintToken();

    m_file.setFileName(m_path);
    if (!m_file.open(QIODevice::ReadOnly)) {
        m_url.clear();
        return QString();
    }

    if (!m_server) {
        m_server = new QTcpServer(this);
        connect(m_server, &QTcpServer::newConnection,
                this, &GrowingFileServer::onNewConnection);
    }
    // Loopback, and an ephemeral port: this is for this machine's own decoder.
    if (!m_server->isListening()
        && !m_server->listen(QHostAddress::LocalHost, 0)) {
        m_file.close();
        m_url.clear();
        return QString();
    }

    m_url = QStringLiteral("http://127.0.0.1:%1%2")
                .arg(m_server->serverPort())
                .arg(QString::fromLatin1(m_target));
    return m_url;
}

void GrowingFileServer::setBytesReady(qint64 bytes)
{
    if (bytes <= m_bytesReady) return;
    m_bytesReady = bytes;
    pump();
}

void GrowingFileServer::setComplete()
{
    if (m_complete) return;
    m_complete = true;
    pump();
}

void GrowingFileServer::stop()
{
    const auto open = m_conns.keys();
    for (QTcpSocket *s : open)
        s->abort();
    m_conns.clear();
    m_pending.clear();
    if (m_server) {
        m_server->close();
        m_server->deleteLater();
        m_server = nullptr;
    }
    m_file.close();
    m_url.clear();
    m_path.clear();
    m_target.clear();
    m_bytesReady = 0;
    m_complete = false;
}

bool GrowingFileServer::isListening() const
{
    return m_server && m_server->isListening();
}

void GrowingFileServer::onNewConnection()
{
    while (m_server && m_server->hasPendingConnections()) {
        QTcpSocket *sock = m_server->nextPendingConnection();
        m_pending.insert(sock, QByteArray());
        connect(sock, &QTcpSocket::readyRead, this, [this, sock] {
            const auto it = m_pending.find(sock);
            if (it == m_pending.end()) {       // already answered; ignore the rest
                sock->readAll();
                return;
            }
            it->append(sock->readAll());
            const int end = it->indexOf("\r\n\r\n");
            if (end < 0) {
                if (it->size() > kMaxRequestHead) sock->abort();
                return;
            }
            const QByteArray head = it->left(end);
            m_pending.erase(it);               // one request per connection
            handleRequest(sock, head);
        });
        connect(sock, &QTcpSocket::bytesWritten, this, [this] { pump(); });
        connect(sock, &QTcpSocket::disconnected, this, [this, sock] {
            m_pending.remove(sock);
            m_conns.remove(sock);
            sock->deleteLater();
        });
    }
}

void GrowingFileServer::handleRequest(QTcpSocket *sock, const QByteArray &requestHead)
{
    const int eol = requestHead.indexOf("\r\n");
    const QByteArray line = eol < 0 ? requestHead : requestHead.left(eol);
    const int sp1 = line.indexOf(' ');
    const int sp2 = line.indexOf(' ', sp1 + 1);

    const QByteArray method = sp1 > 0 ? line.left(sp1) : QByteArray();
    QByteArray target = (sp1 > 0 && sp2 > sp1) ? line.mid(sp1 + 1, sp2 - sp1 - 1)
                                               : QByteArray();
    const int query = target.indexOf('?');
    if (query >= 0) target.truncate(query);

    // The token is the only thing that makes this URL the track's, so a mismatch
    // is a 404 and not a hint. Nothing here is secret enough to need a timing-safe
    // compare, but nothing here tells a caller how close it got either.
    const bool wanted = !m_target.isEmpty() && target == m_target && m_file.isOpen();
    if (!wanted || (method != "GET" && method != "HEAD")) {
        sock->write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
                    "Connection: close\r\n\r\n");
        sock->disconnectFromHost();
        return;
    }

    // No Content-Length, no Accept-Ranges, and any Range header in the request is
    // ignored: see GrowingFileServer.h for the four responses this was measured
    // against and what each one cost.
    QByteArray headers;
    headers += "HTTP/1.1 200 OK\r\n";
    headers += "Content-Type: " + m_mime.toUtf8() + "\r\n";
    headers += "Transfer-Encoding: chunked\r\n";
    headers += "Cache-Control: no-store\r\n";
    headers += "Connection: close\r\n\r\n";
    sock->write(headers);

    if (method == "HEAD") {
        sock->disconnectFromHost();
        return;
    }

    m_conns.insert(sock, Conn{});
    pump();
}

void GrowingFileServer::pump()
{
    // bytesWritten() can arrive while this is still writing, and the loop below
    // reads the same file handle for every connection.
    if (m_pumping || !m_file.isOpen()) return;
    m_pumping = true;

    const auto sockets = m_conns.keys();
    for (QTcpSocket *sock : sockets) {
        const auto it = m_conns.find(sock);
        if (it == m_conns.end()) continue;      // dropped by an earlier iteration
        Conn &c = it.value();
        if (c.finished || sock->state() != QAbstractSocket::ConnectedState)
            continue;

        while (c.sent < m_bytesReady && sock->bytesToWrite() < kSocketHighWater) {
            if (!m_file.seek(c.sent)) break;
            const QByteArray data = m_file.read(qMin(kReadChunk, m_bytesReady - c.sent));
            if (data.isEmpty()) break;          // the writer has not flushed yet
            sock->write(QByteArray::number(data.size(), 16) + "\r\n");
            sock->write(data);
            sock->write("\r\n");
            c.sent += data.size();
        }

        // Only once everything the writer will ever produce has gone out. A
        // terminator sent at the write cursor would be an end of track.
        if (m_complete && c.sent >= m_bytesReady) {
            sock->write("0\r\n\r\n");
            c.finished = true;
            sock->disconnectFromHost();
        }
    }

    m_pumping = false;
}
