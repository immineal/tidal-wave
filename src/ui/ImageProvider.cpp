// SPDX-License-Identifier: GPL-3.0-or-later

#include "ImageProvider.h"
#include "CoverColor.h"
#include <QNetworkReply>
#include <QNetworkAccessManager>
#include <QQuickTextureFactory>
#include <QImageReader>
#include <QBuffer>
#include <QMutex>
#include <QNetworkDiskCache>
#include <QStandardPaths>
#include <QThreadStorage>

TidalImageProvider::TidalImageProvider()
    : QQuickAsyncImageProvider()
{}

QNetworkAccessManager *TidalImageProvider::manager(const QString &cacheDir)
{
    static QThreadStorage<QNetworkAccessManager *> perThread;
    if (perThread.hasLocalData()) return perThread.localData();
    auto *nam = new QNetworkAccessManager();
    // A cache directory has one owner; a second engine's thread goes without.
    static QMutex lock;
    static bool cacheTaken = false;
    {
        QMutexLocker held(&lock);
        if (!cacheTaken) {
            cacheTaken = true;
            auto *cache = new QNetworkDiskCache(nam);
            cache->setCacheDirectory(!cacheDir.isEmpty() ? cacheDir
                : QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                      + QStringLiteral("/covers"));
            nam->setCache(cache);
        }
    }
    perThread.setLocalData(nam);
    return nam;
}

QQuickImageResponse *TidalImageProvider::requestImageResponse(
    const QString &id, const QSize &requestedSize)
{
    QUrl url(id.startsWith("http") ? id : ("https://" + id));
    return new ::ImageResponse(id, url, requestedSize);
}

// ─── ImageResponse ─────────────────────────────────

ImageResponse::ImageResponse(const QString &id, const QUrl &url, const QSize &size)
    : m_id(id), m_size(size)
{
    // Called on the loading thread (QQuickPixmapReader), whose manager this is.
    QNetworkRequest request(url);
    // A cover URL names one image for good, so a cached copy is never stale.
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute,
                         QNetworkRequest::PreferCache);
    auto *reply = TidalImageProvider::manager()->get(request);
    m_reply = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() == QNetworkReply::NoError) {
            QByteArray data = reply->readAll();
            QBuffer buf(&data);
            QImageReader reader(&buf);
            if (m_size.isValid()) reader.setScaledSize(m_size);
            m_image = reader.read();
            // Records the cover's colour off the GUI thread, once per cover.
            // Not gated on the preference: once Qt's pixmap cache holds the
            // artwork this provider is not called for it again.
            if (!m_image.isNull())
                CoverColorStore::instance()->record(m_id, m_image);
        }
        emit finished();
    });
}

void ImageResponse::cancel()
{
    // Queued: abort() emits finished at once, and the engine must not see
    // finished() from inside its own cancel() call.
    if (m_reply)
        QMetaObject::invokeMethod(m_reply.data(), [r = m_reply] { if (r) r->abort(); },
                                  Qt::QueuedConnection);
}

QQuickTextureFactory *ImageResponse::textureFactory() const {
    return QQuickTextureFactory::textureFactoryForImage(m_image);
}
