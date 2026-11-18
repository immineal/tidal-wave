// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QQuickAsyncImageProvider>
#include <QImage>
#include <QPointer>
#include <QString>

class QNetworkAccessManager;
class QNetworkReply;

class TidalImageProvider : public QQuickAsyncImageProvider {
public:
    explicit TidalImageProvider();
    QQuickImageResponse *requestImageResponse(
        const QString &id, const QSize &requestedSize) override;

    // One manager per loading thread, so covers share connections. The first
    // one keeps a disk cache in `cacheDir`; empty means the app's cache dir.
    static QNetworkAccessManager *manager(const QString &cacheDir = QString());
};

class ImageResponse : public QQuickImageResponse {
    Q_OBJECT
public:
    // `id` is everything after "image://tidal/". It is kept because it is the
    // key CoverColorStore is written under.
    ImageResponse(const QString &id, const QUrl &url, const QSize &size);
    QQuickTextureFactory *textureFactory() const override;
    // A cover scrolled past: its download stops. finished() still follows.
    void cancel() override;

private:
    QPointer<QNetworkReply> m_reply;
    QString m_id;
    QSize  m_size;
    QImage m_image;
};
