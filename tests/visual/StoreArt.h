// Cover art for the store screenshots: real records' sleeves and artist
// photos under free licences, read from tests/visual/store/art/. Each file's
// source and licence is in tests/visual/store/CREDITS.md.
//
// Ids: store/album/<slug>, store/artist/<slug>, and
// store/playlist/<slug>+<slug>+<slug>+<slug> for a mosaic of four albums.
#pragma once

#include <QColor>
#include <QImage>
#include <QPainter>
#include <QString>
#include <QStringList>
#include <QtGlobal>

#ifndef STORE_ART_DIR
#error "STORE_ART_DIR must name tests/visual/store/art"
#endif

namespace storeart {

inline QImage load(const QString &kind, const QString &slug) {
    const QString path = QStringLiteral(STORE_ART_DIR "/%1/%2.jpg").arg(kind, slug);
    QImage img(path);
    // A missing file is a broken fixture; QWARN is what run.sh reports.
    if (img.isNull())
        qWarning("store art: no image at %s", qPrintable(path));
    return img.convertToFormat(QImage::Format_RGB32);
}

// Four sleeves in a square, the way a playlist without its own art looks.
inline QImage mosaic(const QStringList &slugs, int side) {
    QImage img(side, side, QImage::Format_RGB32);
    img.fill(Qt::black);
    if (slugs.isEmpty()) return img;
    QPainter p(&img);
    p.setRenderHint(QPainter::SmoothPixmapTransform, true);
    const int half = side / 2;
    for (int i = 0; i < 4; ++i) {
        const QRect tile((i % 2) * half, (i / 2) * half,
                         i % 2 ? side - half : half, i / 2 ? side - half : half);
        p.drawImage(tile, load(QStringLiteral("album"), slugs.at(i % slugs.size())));
    }
    return img;
}

inline bool handles(const QString &id) {
    return id.startsWith(QLatin1String("store/"));
}

inline QImage render(const QString &id, const QSize &requested) {
    const QString kind = id.section(QLatin1Char('/'), 1, 1);
    const QString rest = id.section(QLatin1Char('/'), 2);
    QImage img = kind == QLatin1String("playlist")
        ? mosaic(rest.split(QLatin1Char('+'), Qt::SkipEmptyParts), 640)
        : load(kind, rest);
    if (img.isNull()) {
        img = QImage(64, 64, QImage::Format_RGB32);
        img.fill(Qt::gray);
    }
    if (requested.width() > 0 && requested.height() > 0)
        img = img.scaled(requested, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    else if (requested.width() > 0)
        img = img.scaledToWidth(requested.width(), Qt::SmoothTransformation);
    else if (requested.height() > 0)
        img = img.scaledToHeight(requested.height(), Qt::SmoothTransformation);
    return img;
}

} // namespace storeart
