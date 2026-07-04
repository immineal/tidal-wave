#include "CastDiscovery.h"
#include <QtGlobal>

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

void resolveCb(AvahiServiceResolver *r, AvahiIfIndex, AvahiProtocol,
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
        self->onResolved(instance, id, fn, QString::fromUtf8(addr), int(port));
    }
    avahi_service_resolver_free(r);
}

void browseCb(AvahiServiceBrowser *, AvahiIfIndex iface, AvahiProtocol proto,
              AvahiBrowserEvent event, const char *name, const char *type,
              const char *domain, AvahiLookupResultFlags, void *userdata) {
    auto *self = static_cast<CastDiscovery *>(userdata);
    if (event == AVAHI_BROWSER_NEW) {
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
    m_nameToId.clear();
}

void CastDiscovery::onResolved(const QString &instanceName, const QString &id,
                               const QString &name, const QString &host, int port) {
    m_nameToId.insert(instanceName, id);
    emit deviceFound(id, name, host, port);
}

void CastDiscovery::onRemoved(const QString &instanceName) {
    const QString id = m_nameToId.take(instanceName);
    if (!id.isEmpty())
        emit deviceRemoved(id);
}
