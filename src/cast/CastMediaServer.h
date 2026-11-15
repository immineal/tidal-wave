// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>

class QTcpServer;
class QTcpSocket;

// Tiny single-file HTTP server that streams the current track to a Chromecast.
// Binds to the LAN IPv4 so the device can reach it, and serves the current file
// at an unguessable path with Range support (receivers ask for ranges).
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
    // media URL, /track/<token>. Each call makes a new random token, and every
    // other path is answered 404.
    QString setCurrentFile(const QString &path, const QString &mime);

private slots:
    void onNewConnection();

private:
    struct Transfer;   // one connection's request and the bytes it is owed
    void handleRequest(QTcpSocket *sock, Transfer *t, const QByteArray &request);
    void pump(QTcpSocket *sock, Transfer *t);
    // A reply with no body, which ends the connection.
    void reply(QTcpSocket *sock, const QByteArray &status, const QByteArray &headers = {});

    QTcpServer *m_server = nullptr;
    QString     m_baseUrl;
    QString     m_path;
    QString     m_mime;
    QByteArray  m_token;   // 128 random bits in hex, the path of the current file
};
