#pragma once
#include <QObject>
#include <QString>
#include <QHash>

class QTcpServer;
class QTcpSocket;

// Tiny single-file HTTP server that streams the current track to a Chromecast.
// Binds to the LAN IPv4 so the device can reach it, and serves GET /track with
// HTTP Range support (Chromecast issues Range requests when buffering).
class CastMediaServer : public QObject {
    Q_OBJECT
public:
    explicit CastMediaServer(QObject *parent = nullptr);
    ~CastMediaServer() override;

    // Start listening. Returns the base URL (http://<lan-ip>:<port>) or empty.
    QString start();
    void    stop();
    bool    isListening() const;

    // Point the server at the file to serve with its MIME type; returns the full
    // media URL. A token in the URL changes each call so the device re-fetches.
    QString setCurrentFile(const QString &path, const QString &mime);

private slots:
    void onNewConnection();

private:
    void handleRequest(QTcpSocket *sock, const QByteArray &request);

    QTcpServer *m_server = nullptr;
    QString     m_baseUrl;
    QString     m_path;
    QString     m_mime;
    int         m_token = 0;
    QHash<QTcpSocket *, QByteArray> m_pending;   // per-connection request buffer
};
