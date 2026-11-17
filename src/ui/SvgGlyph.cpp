// SPDX-License-Identifier: GPL-3.0-or-later

#include "ui/SvgGlyph.h"

#include <QPainter>
#include <QtMath>

SvgGlyph::SvgGlyph(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setAntialiasing(true);
}

void SvgGlyph::setSvg(const QString &svg) {
    if (svg == m_svg)
        return;
    m_svg = svg;
    m_renderer.load(svg.toUtf8());
    emit svgChanged();
    update();
}

void SvgGlyph::paint(QPainter *painter) {
    if (!m_renderer.isValid())
        return;
    painter->setRenderHint(QPainter::Antialiasing);
    m_renderer.render(painter, QRectF(0, 0, width(), height()));
}

QString SvgGlyph::arc(qreal w, qreal h, qreal thickness, qreal startDeg, qreal sweepDeg,
                      const QColor &color) {
    const qreal cx = w / 2, cy = h / 2;
    const qreal rx = (w - thickness) / 2, ry = (h - thickness) / 2;
    const qreal sweep = qBound<qreal>(0, sweepDeg, 360);
    auto point = [&](qreal deg) {
        const qreal a = qDegreesToRadians(deg);
        return QStringLiteral("%1 %2").arg(cx + rx * qCos(a)).arg(cy + ry * qSin(a));
    };
    QString d;
    if (sweep > 0 && rx > 0 && ry > 0) {
        // SVG cannot draw a full circle as one arc: two halves.
        const qreal mid = sweep >= 360 ? startDeg + 180 : startDeg + sweep;
        const QString radii = QStringLiteral(" A %1 %2 0 ").arg(rx).arg(ry);
        d = QStringLiteral("M ") + point(startDeg) + radii
            + (sweep > 180 && sweep < 360 ? QStringLiteral("1") : QStringLiteral("0"))
            + QStringLiteral(" 1 ") + point(mid);
        if (sweep >= 360)
            d += radii + QStringLiteral("0 1 ") + point(startDeg + 360);
    }
    return QStringLiteral(
               "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %1 %2\" "
               "preserveAspectRatio=\"none\"><path d=\"%3\" fill=\"none\" "
               "stroke=\"%4\" stroke-opacity=\"%5\" stroke-width=\"%6\" "
               "stroke-linecap=\"round\"/></svg>")
        .arg(w).arg(h).arg(d, color.name(QColor::HexRgb)).arg(color.alphaF()).arg(thickness);
}
