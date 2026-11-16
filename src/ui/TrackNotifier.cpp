// SPDX-License-Identifier: GPL-3.0-or-later

#include "TrackNotifier.h"

#include <QPointer>
#include <QStringList>

#ifdef Q_OS_LINUX
#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <memory>
#endif

TrackNotifier::TrackNotifier(QObject *parent) : QObject(parent) {}

void TrackNotifier::update(const QVariantMap &track, bool playing) {
    const qint64 id = track.value(QStringLiteral("id")).toLongLong();
    if (!playing || id <= 0 || id == m_lastTrack)
        return;
    // Counted as announced even when nothing is shown, so a later pause and
    // resume of the same track stays quiet.
    m_lastTrack = id;
    if (!m_send || !m_enabled || !m_enabled())
        return;
    if (m_windowActive && m_windowActive())
        return;

    Notification n;
    n.title = track.value(QStringLiteral("title")).toString();
    QStringList lines;
    const QString artists = track.value(QStringLiteral("artists")).toString();
    const QString album = track.value(QStringLiteral("albumTitle")).toString();
    if (!artists.isEmpty()) lines << artists;
    if (!album.isEmpty()) lines << album;
    n.body = lines.join(QLatin1Char('\n'));

    const QUrl cover(track.value(QStringLiteral("coverUrl")).toString());
    if (!m_fetchCover || !cover.isValid() || cover.isEmpty()) {
        m_send(n);
        return;
    }
    const quint64 generation = ++m_generation;
    QPointer<TrackNotifier> self(this);
    m_fetchCover(cover, [self, generation, n](const QImage &image) mutable {
        // A newer track started while this cover loaded: its own notice wins.
        if (!self || generation != self->m_generation || !self->m_send) return;
        n.cover = image;
        self->m_send(n);
    });
}

#ifdef Q_OS_LINUX
namespace {

// The spec's image-data hint, (iiibiiay): pixels sent in the message, which a
// notification server outside a Flatpak sandbox can read.
struct NotifyImage {
    int width = 0, height = 0, stride = 0;
    bool alpha = true;
    int bitsPerSample = 8, channels = 4;
    QByteArray data;
};

QDBusArgument &operator<<(QDBusArgument &arg, const NotifyImage &i) {
    arg.beginStructure();
    arg << i.width << i.height << i.stride << i.alpha << i.bitsPerSample << i.channels << i.data;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, NotifyImage &i) {
    arg.beginStructure();
    arg >> i.width >> i.height >> i.stride >> i.alpha >> i.bitsPerSample >> i.channels >> i.data;
    arg.endStructure();
    return arg;
}

} // namespace

Q_DECLARE_METATYPE(NotifyImage)

TrackNotifier::Sender TrackNotifier::freedesktopSender(const QDBusConnection &bus, QObject *context) {
    qDBusRegisterMetaType<NotifyImage>();
    // The id the server gave the last one, so the next replaces it.
    auto lastId = std::make_shared<uint>(0);
    // Asked once. A server without body markup would show "&amp;" as is.
    auto markup = std::make_shared<bool>(true);
    QPointer<QObject> guard(context);
    auto *caps = new QDBusPendingCallWatcher(bus.asyncCall(QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.Notifications"),
        QStringLiteral("/org/freedesktop/Notifications"),
        QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("GetCapabilities"))),
        context);
    QObject::connect(caps, &QDBusPendingCallWatcher::finished, caps,
                     [markup](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<QStringList> reply = *w;
        if (reply.isValid()) *markup = reply.value().contains(QStringLiteral("body-markup"));
        w->deleteLater();
    });
    return [bus, lastId, markup, guard](const Notification &n) {
        QVariantMap hints;
        hints.insert(QStringLiteral("desktop-entry"), QStringLiteral("io.github.immineal.TidalWave"));
        hints.insert(QStringLiteral("suppress-sound"), true);
        hints.insert(QStringLiteral("urgency"), QVariant::fromValue<uchar>(0));
        if (!n.cover.isNull()) {
            const QImage img = n.cover.scaled(128, 128, Qt::KeepAspectRatio, Qt::SmoothTransformation)
                                   .convertToFormat(QImage::Format_RGBA8888);
            NotifyImage ni;
            ni.width = img.width();
            ni.height = img.height();
            ni.stride = int(img.bytesPerLine());
            ni.data = QByteArray(reinterpret_cast<const char *>(img.constBits()),
                                 img.sizeInBytes());
            hints.insert(QStringLiteral("image-data"), QVariant::fromValue(ni));
        }

        QDBusMessage call = QDBusMessage::createMethodCall(
            QStringLiteral("org.freedesktop.Notifications"),
            QStringLiteral("/org/freedesktop/Notifications"),
            QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("Notify"));
        // A server that reads markup would take "&" or "<" in a name as a tag.
        call << QStringLiteral("Tidal Wave") << *lastId << QStringLiteral("tidal-wave")
             << n.title << (*markup ? n.body.toHtmlEscaped() : n.body) << QStringList()
             << hints << -1;

        auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(call), guard.data());
        QObject::connect(watcher, &QDBusPendingCallWatcher::finished, watcher,
                         [lastId](QDBusPendingCallWatcher *w) {
            const QDBusPendingReply<uint> reply = *w;
            if (reply.isValid()) *lastId = reply.value();
            w->deleteLater();
        });
    };
}
#endif
