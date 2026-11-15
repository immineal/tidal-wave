// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>
#include <QByteArray>

class QSslSocket;
class QTimer;
struct CastMessage;

// Controls a single Chromecast device over the CASTV2 protocol (TLS on :8009):
// launches the default media receiver, LOADs a media URL, relays transport
// commands, and surfaces the device's media status back as signals.
class CastSession : public QObject {
    Q_OBJECT
public:
    explicit CastSession(QObject *parent = nullptr);
    ~CastSession() override;

    void connectToDevice(const QString &host, int port);
    void disconnectFromDevice();
    bool isConnected() const { return m_appConnected; }

    // Test hook: plain TCP instead of TLS, so a QTcpServer can stand in for
    // the receiver. Set before connectToDevice().
    void setPlainTextForTest(bool on) { m_plainText = on; }
    void setConnectTimeoutForTest(int ms) { m_connectTimeoutMs = ms; }

    // Load a media URL onto the receiver, starting at `startSec`. Before
    // `connected()` the load is deferred until the receiver app is up.
    void loadMedia(const QString &url, const QString &contentType,
                   const QString &title, const QString &artist,
                   const QString &album, const QString &artUrl, double durationSec,
                   double startSec = 0);

    void play();
    void pause();
    void seek(double sec);
    void stopMedia();
    void setVolume(double level);   // 0..1

signals:
    void connected();               // receiver launched + virtual connection open
    void disconnected();
    void error(const QString &msg);
    void playingChanged(bool playing);
    void positionChanged(double sec);
    void durationChanged(double sec);
    void mediaFinished();

private slots:
    void onEncrypted();
    void onReadyRead();
    void onTick();

private:
    void reset();                       // drops the socket and all session state
    void fail(const QString &msg);      // error(), then disconnected()
    void sendGoodbye();   // STOP and CLOSE, queued on the socket
    void closeQuietly(QSslSocket *s);
    void sendMessage(const QString &ns, const QString &destination, const QString &payloadJson);
    void handleMessage(const CastMessage &msg);
    void establishAppConnection(const QString &transportId);
    void sendLoad();
    int  nextRequestId() { return ++m_requestId; }

    QSslSocket *m_socket    = nullptr;
    QTimer     *m_timer     = nullptr;   // heartbeat + status poll
    QTimer     *m_connectTimer = nullptr;
    int         m_connectTimeoutMs = 10000;
    QByteArray  m_buffer;

    QString m_transportId;               // media app destination (RECEIVER_STATUS)
    QString m_sessionId;                  // receiver app session (to STOP/quit it)
    int     m_mediaSessionId = 0;
    int     m_requestId      = 0;
    int     m_loadRequestId  = 0;        // requestId of the LOAD in force
    int     m_endedFor       = -1;       // media session whose end was reported
    int     m_tick           = 0;
    bool    m_appConnected   = false;
    bool    m_plainText      = false;

    bool    m_haveLoad = false;          // a media LOAD is queued/desired
    QString m_loadPayload;               // prepared LOAD JSON
};
