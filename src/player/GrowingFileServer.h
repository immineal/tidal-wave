#pragma once
//
// Handing QMediaPlayer the front of a file that is still being written.
//
// Lossless and hi-res arrive as DASH and DashFetcher joins the segments into one
// fragmented MP4, writing them in play order. Until now playback waited for the
// last segment, which measured 15-70 s on a real track before the first note.
// The front of that file is already a shorter fragmented MP4 of the same track,
// so there is nothing to wait for except enough of it.
//
// What QMediaPlayer will not do is open a local file that grows: the ffmpeg
// backend opens it, sees the size it has, and plays that much. A local HTTP
// socket can hold a response open and keep appending to it, which is what this
// is - a one-file, one-purpose HTTP server on the loopback interface.
//
// NOTHING IN THE APP CALLS THIS YET. Player still waits for the whole join; the
// wiring is deliberately a separate change, because it has to decide what a seek
// and a duration mean on a track that is not all there (see below), and that is
// state in Player, not here. What is here is measured end to end by
// tst_progressive.cpp against a real QMediaPlayer over a real socket.
//
// ── the response, and why each part of it is the way it is ──────────────────
//
// Measured against QMediaPlayer on Qt 6.12 / ffmpeg 7.1.3, serving a growing
// 8-segment fragmented MP4 (tst_progressive.cpp has the harness):
//
//   Transfer-Encoding: chunked, no Content-Length, Range ignored
//                                     first sample 0.6 s, all 64000 frames, a
//                                     clean EndOfMedia.           <- this
//   Content-Length of the final size  first sample 2.4 s of a 2.7 s join: with a
//                                     length the input looks seekable *and*
//                                     complete, and ffmpeg's mov demuxer walks
//                                     every moof in the file before open()
//                                     returns. That walk is the wait we are
//                                     removing.
//   no Content-Length, no chunking    first sample 0.9 s, but the socket close
//                                     is an I/O error rather than an end of
//                                     stream: 50688 of 64000 frames, then the
//                                     demuxer spins on EIO.
//   Content-Length of what exists,
//   close at the cursor               nothing at all. ffmpeg does not re-request
//                                     the rest; it reports "Demuxing failed" and
//                                     decodes zero frames.
//
// So: chunked, because the terminating zero-length chunk is an unambiguous end
// of body that a bare socket close is not; no Content-Length and no
// Accept-Ranges, because a client that believes it can seek will try to, and
// there is nothing behind the write cursor to seek to; and a Range header is
// ignored rather than answered, because answering it would be claiming to have
// bytes we do not have.
//
// A request whose body reaches the write cursor is *parked*: the socket stays
// open and silent until more bytes exist. It is never answered short, because a
// short read is end-of-stream as far as a demuxer is concerned. Parking costs an
// idle socket and a QHash entry; it blocks nothing, because the waiting is the
// client's, not this process's.
//
// ── seeking, and duration ───────────────────────────────────────────────────
//
// Both are the caller's problem and both have to be solved before this is wired
// up. Measured on the same harness: while the response is open QMediaPlayer
// reports isSeekable() == true and a duration of one segment, and a setPosition()
// past that clamps to it and leaves the decoder emitting more frames than the
// track has. So a caller must take its duration from the track metadata it
// already has, and must not pass a seek through while the join is running.
//
// ── reach ───────────────────────────────────────────────────────────────────
//
// Loopback only, so the track is not on the LAN, and a 128-bit token in the path
// so another process on this machine cannot guess the URL. A new serve() mints a
// new token, which is also how a QMediaPlayer still holding the previous track's
// URL gets a 404 instead of this track's bytes.
//
// This is deliberately not CastMediaServer. That one binds the LAN address (a
// Chromecast has to reach it), is compiled only where the Chromecast backend is,
// serves a complete file, and sends its body in a blocking loop with
// waitForBytesWritten() - which cannot park on a write cursor without stopping
// the GUI thread. Nothing it does is wrong for its job; none of it is this job.
//
#include <QFile>
#include <QHash>
#include <QObject>
#include <QString>

class QTcpServer;
class QTcpSocket;

class GrowingFileServer : public QObject {
    Q_OBJECT
public:
    explicit GrowingFileServer(QObject *parent = nullptr);
    ~GrowingFileServer() override;

    // Starts serving path, of which the first bytesReady bytes are on disk, and
    // returns the URL to hand QMediaPlayer. Empty when the loopback socket could
    // not be opened, which the caller should treat as "fall back to waiting".
    // Calling it again retargets the server and invalidates the previous URL.
    QString serve(const QString &path, const QString &mime, qint64 bytesReady);

    // The writer flushed more. Bytes already sent are never re-sent, and a value
    // that does not move anything on is harmless.
    void setBytesReady(qint64 bytes);

    // No more bytes are coming. Sends what is left plus the terminating chunk,
    // which is what lets the client end the stream cleanly rather than treat the
    // close as an error.
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
        bool   finished = false;  // the terminating chunk went out
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
