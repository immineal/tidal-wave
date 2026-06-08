#ifndef DISCORDRPC_H
#define DISCORDRPC_H

#include <QObject>
#include <QLocalSocket>
#include <QTimer>
#include <QJsonObject>
#include <QJsonDocument>

class DiscordRPC : public QObject
{
    Q_OBJECT
public:
    explicit DiscordRPC(QObject *parent = nullptr);
    ~DiscordRPC();

    void updateActivity(const QString &title, const QString &artist, const QString &album,
                        const QString &artUrl, double position, double duration, bool playing);
    void clearActivity();

private slots:
    void onConnected();
    void onDisconnected();
    void onError(QLocalSocket::LocalSocketError socketError);
    void tryConnect();

private:
    void sendPacket(int opcode, const QJsonObject &payload);
    QString getSocketPath();

    QLocalSocket *m_socket;
    QTimer *m_reconnectTimer;
    QString m_clientId;
    bool m_connected;
};

#endif // DISCORDRPC_H
