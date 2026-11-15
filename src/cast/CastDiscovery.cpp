// SPDX-License-Identifier: GPL-3.0-or-later

#include "CastDiscovery.h"
#include <QtGlobal>
#include <QHostAddress>
#include <QNetworkInterface>

#include <avahi-client/client.h>
#include <avahi-client/lookup.h>
#include <avahi-common/thread-watch.h>
#include <avahi-common/error.h>
#include <avahi-common/address.h>
#include <avahi-common/strlst.h>
#include <avahi-common/malloc.h>

namespace {

// Read a single TXT record key ("fn", "id", …) as a QString.
QString txtValue(AvahiStringList *txt, const char *key) {
    AvahiStringList *e = avahi_string_list_find(txt, key);
    if (!e) return QString();
    char *k = nullptr;
    char *v = nullptr;
    size_t vs = 0;
    if (avahi_string_list_get_pair(e, &k, &v, &vs) < 0)
        return QString();
    QString out = v ? QString::fromUtf8(v, int(vs)) : QString();
    if (k) avahi_free(k);
    if (v) avahi_free(v);
    return out;
}

void resolveCb(AvahiServiceResolver *r, AvahiIfIndex iface, AvahiProtocol,
               AvahiResolverEvent event, const char *name, const char * /*type*/,
               const char * /*domain*/, const char * /*hostName*/,
               const AvahiAddress *address, uint16_t port,
               AvahiStringList *txt, AvahiLookupResultFlags, void *userdata) {
    auto *self = static_cast<CastDiscovery *>(userdata);
    if (event == AVAHI_RESOLVER_FOUND && address) {
        char addr[AVAHI_ADDRESS_STR_MAX];
        avahi_address_snprint(addr, sizeof(addr), address);
        QString id = txtValue(txt, "id");
        QString fn = txtValue(txt, "fn");
        const QString instance = QString::fromUtf8(name);
        if (id.isEmpty()) id = instance;
        if (fn.isEmpty()) fn = instance;
        self->onResolved(instance, id, fn,
                         CastDiscovery::withScope(QString::fromUtf8(addr), int(iface)),
                         int(port));
    }
    avahi_service_resolver_free(r);
}

void browseCb(AvahiServiceBrowser *, AvahiIfIndex iface, AvahiProtocol proto,
              AvahiBrowserEvent event, const char *name, const char *type,
              const char *domain, AvahiLookupResultFlags, void *userdata) {
    auto *self = static_cast<CastDiscovery *>(userdata);
    if (event == AVAHI_BROWSER_NEW) {
        self->onBrowsed(QString::fromUtf8(name));
        auto *client = static_cast<AvahiClient *>(self->clientHandle());
        if (client)
            avahi_service_resolver_new(client, iface, proto, name, type, domain,
                                       AVAHI_PROTO_UNSPEC, AvahiLookupFlags(0),
                                       resolveCb, self);
    } else if (event == AVAHI_BROWSER_REMOVE) {
        self->onRemoved(QString::fromUtf8(name));
    }
}

void clientCb(AvahiClient *, AvahiClientState, void *) {}

} // namespace

CastDiscovery::CastDiscovery(QObject *parent) : QObject(parent) {}

CastDiscovery::~CastDiscovery() {
    stop();
}

void CastDiscovery::start() {
    if (m_poll) return;   // already running

    auto *poll = avahi_threaded_poll_new();
    if (!poll) return;
    m_poll = poll;

    int err = 0;
    auto *client = avahi_client_new(avahi_threaded_poll_get(poll), AvahiClientFlags(0),
                                    clientCb, this, &err);
    if (!client) {
        avahi_threaded_poll_free(poll);
        m_poll = nullptr;
        return;
    }
    m_client = client;

    m_browser = avahi_service_browser_new(client, AVAHI_IF_UNSPEC, AVAHI_PROTO_UNSPEC,
                                          "_googlecast._tcp", nullptr, AvahiLookupFlags(0),
                                          browseCb, this);

    avahi_threaded_poll_start(poll);
}

void CastDiscovery::stop() {
    if (m_poll)
        avahi_threaded_poll_stop(static_cast<AvahiThreadedPoll *>(m_poll));
    if (m_browser) {
        avahi_service_browser_free(static_cast<AvahiServiceBrowser *>(m_browser));
        m_browser = nullptr;
    }
    if (m_client) {
        avahi_client_free(static_cast<AvahiClient *>(m_client));
        m_client = nullptr;
    }
    if (m_poll) {
        avahi_threaded_poll_free(static_cast<AvahiThreadedPoll *>(m_poll));
        m_poll = nullptr;
    }
    m_instances.clear();
}

QString CastDiscovery::withScope(const QString &address, int ifIndex) {
    const QHostAddress a(address);
    if (a.protocol() != QAbstractSocket::IPv6Protocol || !a.isLinkLocal()
        || !a.scopeId().isEmpty())
        return address;
    const QString iface = QNetworkInterface::interfaceNameFromIndex(ifIndex);
    return iface.isEmpty() ? address : address + QLatin1Char('%') + iface;
}

void CastDiscovery::onBrowsed(const QString &instanceName) {
    QMetaObject::invokeMethod(this, [this, instanceName] { addRecord(instanceName); },
                              Qt::QueuedConnection);
}

void CastDiscovery::onResolved(const QString &instanceName, const QString &id,
                               const QString &name, const QString &host, int port) {
    QMetaObject::invokeMethod(this, [=] { addResolved(instanceName, id, name, host, port); },
                              Qt::QueuedConnection);
}

void CastDiscovery::onRemoved(const QString &instanceName) {
    QMetaObject::invokeMethod(this, [this, instanceName] { removeRecord(instanceName); },
                              Qt::QueuedConnection);
}

void CastDiscovery::addRecord(const QString &instanceName) {
    ++m_instances[instanceName].records;
}

void CastDiscovery::addResolved(const QString &instanceName, const QString &id,
                                const QString &name, const QString &host, int port) {
    Instance &in = m_instances[instanceName];
    in.id = id;
    // Both families resolve. IPv4 is kept: it is what every device answers
    // on, and a link-local IPv6 address is tied to one interface.
    const auto isV4 = [](const QString &h) {
        return QHostAddress(h).protocol() == QAbstractSocket::IPv4Protocol;
    };
    if (!isV4(host) && isV4(in.host)) return;
    in.host = host;
    emit deviceFound(id, name, host, port);
}

void CastDiscovery::removeRecord(const QString &instanceName) {
    const auto it = m_instances.find(instanceName);
    if (it == m_instances.end()) return;
    if (--it->records > 0) return;   // still there over the other family
    const QString id = it->id;
    m_instances.erase(it);
    if (!id.isEmpty())
        emit deviceRemoved(id);
}
