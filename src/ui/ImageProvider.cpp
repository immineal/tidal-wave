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
    // Create QNAM on the calling thread (QQuickPixmapReader) so there's no
    // cross-thread parent/child relationship when the reply is created.
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
            // The fullscreen Now Playing page paints a gradient derived from
            // the artwork, and this is the one place in the app where a cover
            // exists as a QImage on a thread that is not the GUI thread. The
            // store skips an id it already has, so this costs a 32x32 downscale
            // once per cover and nothing on every later load of the same one.
            //
            // Unconditional, rather than gated on the preference: the colour
            // has to be here the moment somebody turns the preference on, and
            // by then Qt's pixmap cache is holding the artwork and this
            // provider will never be asked for it again.
            if (!m_image.isNull())
                CoverColorStore::instance()->record(m_id, m_image);
        }
        emit finished();
    });
}

QQuickTextureFactory *ImageResponse::textureFactory() const {
    return QQuickTextureFactory::textureFactoryForImage(m_image);
}
