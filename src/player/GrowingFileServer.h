// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
// Serves the front of a file that is still being written to QMediaPlayer, over
// loopback HTTP with a random token in the path. The ffmpeg backend plays a
// growing local file only up to the size it had when opened.
// The response is chunked with no Content-Length and no Accept-Ranges, a Range
// header is ignored, and the body ends by closing the socket at a chunk
// boundary: FFmpeg 9 hangs in BufferingMedia after a terminating chunk.
#include <QFile>
#include <QHash>
#include <QObject>
#include <QString>

class QTcpServer;
class QTcpSocket;

// While the response is open QMediaPlayer reports one segment's duration and
// claims to be seekable. The caller takes the duration from track metadata and
// holds seeks back until the join is complete.
class GrowingFileServer : public QObject {
    Q_OBJECT
public:
    explicit GrowingFileServer(QObject *parent = nullptr);
    ~GrowingFileServer() override;

    // Starts serving path, of which the first bytesReady bytes are on disk, and
    // returns the URL for QMediaPlayer, or empty when the loopback socket could
    // not be opened. Calling it again invalidates the previous URL.
    QString serve(const QString &path, const QString &mime, qint64 bytesReady);

    // The writer flushed more. Bytes already sent are never re-sent, and a value
    // that does not move anything on is harmless.
    void setBytesReady(qint64 bytes);

    // No more bytes are coming. Sends what is left and then closes the socket.
    // A server that dies mid-track looks the same to the client, so only the
    // caller knows the stream was whole.
    void setComplete();

    // Stops listening and drops every connection. Safe to call twice.
    void stop();

    bool    isListening() const;
    qint64  bytesReady()  const { return m_bytesReady; }
    bool    isComplete()  const { return m_complete; }
    QString url()         const { return m_url; }

private slots:
    void onNewConnection();

private:
    // One response in progress.
    struct Conn {
        qint64 sent     = 0;      // bytes of the file already handed to the socket
        bool   finished = false;  // the last byte went out and the socket was closed
    };

    void handleRequest(QTcpSocket *sock, const QByteArray &requestHead);
    void pump();

    QTcpServer *m_server = nullptr;
    QString     m_url;
    QString     m_path;
    QString     m_mime;
    QByteArray  m_target;          // "/<token>", what a request line must name
    QFile       m_file;            // read handle on the growing file
    qint64      m_bytesReady = 0;
    bool        m_complete   = false;
    bool        m_pumping    = false;

    QHash<QTcpSocket *, QByteArray> m_pending;   // request bytes still arriving
    QHash<QTcpSocket *, Conn>       m_conns;     // responses in progress
};
