// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QString>
#include <QHash>

// Discovers Chromecast / Google Cast devices on the LAN via mDNS (Avahi),
// browsing the _googlecast._tcp service type. Avahi runs on its own threaded
// poll; its results are posted to this object's thread and handled there.
class CastDiscovery : public QObject {
    Q_OBJECT
public:
    explicit CastDiscovery(QObject *parent = nullptr);
    ~CastDiscovery() override;

    void start();
    void stop();

    // Called from the Avahi poll thread by the C callbacks (see .cpp). They
    // only post to this object's thread, where all the bookkeeping is done.
    void *clientHandle() const { return m_client; }
    void  onBrowsed(const QString &instanceName);
    void  onResolved(const QString &instanceName, const QString &id,
                     const QString &name, const QString &host, int port);
    void  onRemoved(const QString &instanceName);

    // `address` with the interface as its scope when it is IPv6 link-local:
    // fe80:: without one cannot be connected to.
    static QString withScope(const QString &address, int ifIndex);

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
    // Per mDNS instance name, since a REMOVE carries only that. Each address
    // family is a record of its own. Touched on the main thread only.
    struct Instance { QString id, host; int records = 0; };
    QHash<QString, Instance> m_instances;

    void addRecord(const QString &instanceName);
    void addResolved(const QString &instanceName, const QString &id,
                     const QString &name, const QString &host, int port);
    void removeRecord(const QString &instanceName);
};
