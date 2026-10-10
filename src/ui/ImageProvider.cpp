// SPDX-License-Identifier: GPL-3.0-or-later

#include "ImageProvider.h"
#include "CoverColor.h"
#include <QNetworkReply>
#include <QNetworkAccessManager>
#include <QQuickTextureFactory>
#include <QImageReader>
#include <QBuffer>

TidalImageProvider::TidalImageProvider()
    : QQuickAsyncImageProvider()
{}

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
    // The QNAM is created on the calling thread (QQuickPixmapReader), so the
    // reply has no cross-thread parent.
    auto *nam = new QNetworkAccessManager();
    auto *reply = nam->get(QNetworkRequest(url));
    connect(reply, &QNetworkReply::finished, this, [this, reply, nam]() {
        reply->deleteLater();
        nam->deleteLater();
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

QQuickTextureFactory *ImageResponse::textureFactory() const {
    return QQuickTextureFactory::textureFactoryForImage(m_image);
}
