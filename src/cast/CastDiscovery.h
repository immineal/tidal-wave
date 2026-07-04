#pragma once
#include <QObject>
#include <QString>
#include <QHash>

// Discovers Chromecast / Google Cast devices on the LAN via mDNS (Avahi),
// browsing the _googlecast._tcp service type. Avahi runs on its own threaded
// poll; results are delivered to the main thread via queued signal emissions.
class CastDiscovery : public QObject {
    Q_OBJECT
public:
    explicit CastDiscovery(QObject *parent = nullptr);
    ~CastDiscovery() override;

    void start();
    void stop();

    // Called from the Avahi poll thread by the C callbacks (see .cpp).
    void *clientHandle() const { return m_client; }
    void  onResolved(const QString &instanceName, const QString &id,
                     const QString &name, const QString &host, int port);
    void  onRemoved(const QString &instanceName);

signals:
    // id:   the device's "id" TXT value (stable per device);
    // name: friendly name ("fn" TXT); host: resolved IP; port: cast port (8009).
    void deviceFound(const QString &id, const QString &name,
                     const QString &host, int port);
    void deviceRemoved(const QString &id);

private:
    // Opaque Avahi handles (void* so avahi headers stay out of this header).
    void *m_poll    = nullptr;   // AvahiThreadedPoll*
    void *m_client  = nullptr;   // AvahiClient*
    void *m_browser = nullptr;   // AvahiServiceBrowser*
    // mDNS instance name -> stable device id, so a REMOVE (which only carries
    // the instance name) can be mapped back to the id we emitted on discovery.
    QHash<QString, QString> m_nameToId;
};
