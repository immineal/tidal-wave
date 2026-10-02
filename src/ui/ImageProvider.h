#pragma once
#include <QQuickAsyncImageProvider>
#include <QImage>
#include <QString>

class TidalImageProvider : public QQuickAsyncImageProvider {
public:
    explicit TidalImageProvider();
    QQuickImageResponse *requestImageResponse(
        const QString &id, const QSize &requestedSize) override;
};

class ImageResponse : public QQuickImageResponse {
    Q_OBJECT
public:
    // `id` is the provider id the QML asked for - everything after
    // "image://tidal/" - and it is kept, not just turned into a URL, because
    // it is the key CoverColorStore is written under. See ImageProvider.cpp.
    ImageResponse(const QString &id, const QUrl &url, const QSize &size);
    QQuickTextureFactory *textureFactory() const override;

private:
    QString m_id;
    QSize  m_size;
    QImage m_image;
};
