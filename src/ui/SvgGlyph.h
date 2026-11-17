// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QColor>
#include <QQmlEngine>
#include <QQuickPaintedItem>
#include <QString>
#include <QSvgRenderer>

// An SVG document painted into the item's box, for the software backend.
// There a Shape scrolled wholly out of a clip draws without the clip and is
// never repainted, so VectorIcon and the rings draw through this instead.
class SvgGlyph : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString svg READ svg WRITE setSvg NOTIFY svgChanged)

public:
    explicit SvgGlyph(QQuickItem *parent = nullptr);

    QString svg() const { return m_svg; }
    void setSvg(const QString &svg);

    void paint(QPainter *painter) override;

    // A stroked arc in a w x h box, as an SVG document: Shape's PathAngleArc
    // with its centre in the middle of the box. Angles in degrees, 0 at three
    // o'clock, clockwise.
    Q_INVOKABLE static QString arc(qreal w, qreal h, qreal thickness, qreal startDeg,
                                   qreal sweepDeg, const QColor &color);

signals:
    void svgChanged();

private:
    QString m_svg;
    QSvgRenderer m_renderer;
};
