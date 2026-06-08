#pragma once
#include <QQuickAsyncImageProvider>
#include <QImage>

class TidalImageProvider : public QQuickAsyncImageProvider {
public:
    explicit TidalImageProvider();
    QQuickImageResponse *requestImageResponse(
        const QString &id, const QSize &requestedSize) override;
};

class ImageResponse : public QQuickImageResponse {
    Q_OBJECT
public:
    ImageResponse(const QUrl &url, const QSize &size);
    QQuickTextureFactory *textureFactory() const override;

private:
    QSize  m_size;
    QImage m_image;
};
