// SPDX-License-Identifier: GPL-3.0-or-later

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
    // `id` is everything after "image://tidal/". It is kept because it is the
    // key CoverColorStore is written under.
    ImageResponse(const QString &id, const QUrl &url, const QSize &size);
    QQuickTextureFactory *textureFactory() const override;

private:
    QString m_id;
    QSize  m_size;
    QImage m_image;
};
