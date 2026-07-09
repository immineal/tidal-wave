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

    // Load a media URL onto the receiver. Safe to call before `connected()` —
    // it is deferred until the receiver app is up.
    void loadMedia(const QString &url, const QString &contentType,
                   const QString &title, const QString &artist,
                   const QString &album, const QString &artUrl, double durationSec);

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
    void sendMessage(const QString &ns, const QString &destination, const QString &payloadJson);
    void handleMessage(const CastMessage &msg);
    void establishAppConnection(const QString &transportId);
    void sendLoad();
    int  nextRequestId() { return ++m_requestId; }

    QSslSocket *m_socket    = nullptr;
    QTimer     *m_timer     = nullptr;   // heartbeat + status poll
    QByteArray  m_buffer;

    QString m_transportId;               // media app destination (RECEIVER_STATUS)
    QString m_sessionId;                  // receiver app session (to STOP/quit it)
    int     m_mediaSessionId = 0;
    int     m_requestId      = 0;
    int     m_tick           = 0;
    bool    m_appConnected   = false;

    bool    m_haveLoad = false;          // a media LOAD is queued/desired
    QString m_loadPayload;               // prepared LOAD JSON
};
