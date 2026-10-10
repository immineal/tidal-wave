// Generated cover art for the store screenshots. Nothing here is real artwork,
// and one id always paints the same picture.
//
// Ids: store/album/<slug>, store/artist/<slug>, store/mix/<number>/<slug>, and
// store/playlist/<slug>+<slug>+<slug>+<slug> for a mosaic of four albums.
#pragma once

#include <cmath>
#include <iterator>

#include <QColor>
#include <QCryptographicHash>
#include <QFont>
#include <QImage>
#include <QList>
#include <QPainter>
#include <QPainterPath>
#include <QRadialGradient>
#include <QString>
#include <QStringList>
#include <QtEndian>
#include <QtMath>

namespace storeart {

// Every family draws into this square; the painter is scaled to the image.
inline constexpr double kSide = 1000.0;
inline const QRectF kCanvas(0, 0, kSide, kSide);

// A stream of choices seeded by the id, so a cover never depends on run order.
class Dice {
public:
    explicit Dice(const QString &seed) {
        const QByteArray d =
            QCryptographicHash::hash(seed.toUtf8(), QCryptographicHash::Sha1);
        m_state = qFromLittleEndian<quint64>(d.constData()) | 1u;
    }
    quint32 next() {
        m_state ^= m_state << 13;
        m_state ^= m_state >> 7;
        m_state ^= m_state << 17;
        return quint32(m_state >> 32);
    }
    int below(int n) { return int(next() % quint32(n)); }
    double between(double a, double b) { return a + (b - a) * (next() / 4294967296.0); }

private:
    quint64 m_state;
};

struct Inks {
    QColor ground, ink, second, third;
};

inline double luma(const QColor &c) {
    return 0.299 * c.red() + 0.587 * c.green() + 0.114 * c.blue();
}

inline QColor mix(const QColor &a, const QColor &b, double t) {
    return QColor(int(a.red() + (b.red() - a.red()) * t),
                  int(a.green() + (b.green() - a.green()) * t),
                  int(a.blue() + (b.blue() - a.blue()) * t));
}

// Twelve four-colour sets. Any of the four can be the ground; the ink is then
// whichever of the rest is furthest from it in lightness.
inline Inks pickInks(Dice &d) {
    static const QRgb sets[][4] = {
        {0x1d2b3a, 0xf2e8d5, 0xe4674a, 0x7fa6a3},
        {0x2a2725, 0xd9a441, 0xf4efe6, 0x8c3f2b},
        {0x2f3b34, 0x8fa58b, 0xf3efe4, 0xc4613e},
        {0x4a2a3a, 0xd7a7a0, 0xf5ece6, 0xb0503f},
        {0x12383a, 0x1f6f72, 0xe9dcc3, 0xf08a5d},
        {0x141414, 0xefefec, 0xc93a2e, 0xd8cdb8},
        {0x2e2a5c, 0xb9b2e3, 0xf2c94c, 0xf4f1fb},
        {0x1f3d2f, 0xa9d6bf, 0xf6b89a, 0xf1f5ee},
        {0x1e2a36, 0x46607c, 0xdbe6ee, 0xe98a3a},
        {0x1c1b19, 0xb9b2a5, 0xe0b03b, 0xf3f0ea},
        {0x5a1f2b, 0xe9c4bb, 0xcfa24a, 0xf6ede8},
        {0x0e4a5c, 0x9fd3d6, 0xf4f4ee, 0xf25f5c},
    };
    const QRgb *set = sets[d.below(int(std::size(sets)))];
    const int g = d.below(4);
    QList<QColor> rest;
    for (int i = 0; i < 4; ++i)
        if (i != g) rest << QColor(set[i]);
    const QColor ground(set[g]);
    int far = 0;
    for (int i = 1; i < rest.size(); ++i)
        if (qAbs(luma(rest[i]) - luma(ground)) > qAbs(luma(rest[far]) - luma(ground)))
            far = i;
    const QColor ink = rest.takeAt(far);
    if (d.below(2)) rest.swapItemsAt(0, 1);
    return {ground, ink, rest[0], rest[1]};
}

// ── the families ────────────────────────────────────────────────────────────

inline void blocks(QPainter &p, Dice &d, const Inks &c) {
    QList<QRectF> cells{kCanvas};
    for (int i = 0; i < 5; ++i) {
        int big = 0;
        for (int j = 1; j < cells.size(); ++j)
            if (cells[j].width() * cells[j].height()
                > cells[big].width() * cells[big].height())
                big = j;
        const QRectF r = cells.takeAt(big);
        const double t = d.between(0.34, 0.66);
        if (r.width() >= r.height()) {
            cells << QRectF(r.left(), r.top(), r.width() * t, r.height())
                  << QRectF(r.left() + r.width() * t, r.top(), r.width() * (1 - t), r.height());
        } else {
            cells << QRectF(r.left(), r.top(), r.width(), r.height() * t)
                  << QRectF(r.left(), r.top() + r.height() * t, r.width(), r.height() * (1 - t));
        }
    }
    const QColor fills[] = {c.ink, c.second, c.ground, c.third, c.ink, c.ground};
    const int shift = d.below(6);
    p.fillRect(kCanvas, c.ground);
    for (int i = 0; i < cells.size(); ++i)
        p.fillRect(cells[i].adjusted(9, 9, -9, -9), fills[(i + shift) % 6]);
}

inline void stripes(QPainter &p, Dice &d, const Inks &c) {
    static const double angles[] = {0, 90, 45, -45, 20, -20};
    p.fillRect(kCanvas, c.ground);
    p.translate(kSide / 2, kSide / 2);
    p.rotate(angles[d.below(6)]);
    p.translate(-kSide / 2, -kSide / 2);
    const QColor fills[] = {c.ink, c.ground, c.second, c.ground, c.ink, c.third};
    int i = d.below(6);
    for (double x = -260; x < 1260;) {
        const double w = d.between(55, 180);
        p.fillRect(QRectF(x, -260, w + 1, 1520), fills[i++ % 6]);
        x += w;
    }
}

inline void rings(QPainter &p, Dice &d, const Inks &c) {
    const QPointF o(d.between(200, 800), d.between(200, 800));
    const double far = std::hypot(qMax(o.x(), kSide - o.x()), qMax(o.y(), kSide - o.y()));
    const int n = 6 + d.below(4);
    const int odd = 1 + d.below(n - 2);
    p.fillRect(kCanvas, c.ground);
    p.setPen(Qt::NoPen);
    for (int i = 0; i < n; ++i) {
        const double r = far * (n - i) / n;
        p.setBrush(i == odd ? c.second : (i % 2 ? c.ink : c.ground));
        p.drawEllipse(o, r, r);
    }
    p.setBrush(c.third);
    p.drawEllipse(o, far / n * 0.45, far / n * 0.45);
}

inline void letter(QPainter &p, Dice &d, const Inks &c, QChar initial) {
    p.fillRect(kCanvas, c.ground);
    QFont f(QStringLiteral("Inter"));
    f.setFamilies({QStringLiteral("Inter"), QStringLiteral("DejaVu Sans")});
    f.setBold(true);
    p.setPen(Qt::NoPen);
    if (d.below(2)) {
        // Set large and low, so the glyph runs off the sleeve's corner.
        f.setPixelSize(940);
        p.setFont(f);
        p.setPen(c.ink);
        p.drawText(QRectF(-40, 180, 1200, 1100), Qt::AlignLeft | Qt::AlignTop, QString(initial));
        p.setPen(Qt::NoPen);
        p.setBrush(c.second);
        p.drawEllipse(QPointF(820, 180), 78, 78);
    } else {
        f.setPixelSize(600);
        p.setFont(f);
        p.setPen(c.ink);
        p.drawText(kCanvas.adjusted(0, -40, 0, -40), Qt::AlignCenter, QString(initial));
        p.fillRect(QRectF(120, 860, 760, 22), c.second);
    }
}

inline void split(QPainter &p, Dice &d, const Inks &c) {
    p.fillRect(kCanvas, c.ground);
    p.setPen(Qt::NoPen);
    p.setBrush(c.ink);
    QPointF dot(d.between(560, 780), d.between(200, 340));
    switch (d.below(3)) {
    case 0: {
        const double left = d.between(380, 720), right = d.between(380, 720);
        p.drawPolygon(QPolygonF({QPointF(0, left), QPointF(kSide, right),
                                 QPointF(kSide, kSide), QPointF(0, kSide)}));
        break;
    }
    case 1:
        p.drawEllipse(QPointF(0, kSide), 780, 780);
        break;
    default:
        p.drawRect(QRectF(0, 0, d.between(400, 560), kSide));
        dot = QPointF(d.between(690, 800), d.between(620, 780));
        break;
    }
    p.setBrush(c.second);
    const double r = d.between(80, 130);
    p.drawEllipse(dot, r, r);
}

inline void dots(QPainter &p, Dice &d, const Inks &c) {
    const int n = 5 + d.below(4);
    const double cell = kSide / n;
    const QPointF focus(d.between(0, kSide), d.between(0, kSide));
    const int hot = d.below(n * n);
    p.fillRect(kCanvas, c.ground);
    p.setPen(Qt::NoPen);
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) {
            const QPointF q((x + 0.5) * cell, (y + 0.5) * cell);
            const double near = 1.0 - qMin(1.0, std::hypot(q.x() - focus.x(), q.y() - focus.y()) / 950.0);
            const double r = cell * (0.10 + 0.34 * near);
            p.setBrush(y * n + x == hot ? c.second : c.ink);
            p.drawEllipse(q, r, r);
        }
    }
}

inline void arcs(QPainter &p, Dice &d, const Inks &c) {
    const int n = 3 + d.below(2);
    const double cell = kSide / n;
    p.fillRect(kCanvas, c.ground);
    p.setPen(Qt::NoPen);
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) {
            const QRectF r(x * cell, y * cell, cell, cell);
            const int corner = d.below(4);
            const int tone = d.below(6);
            const QPointF o(corner % 2 ? r.right() : r.left(), corner / 2 ? r.bottom() : r.top());
            p.save();
            p.setClipRect(r);
            p.setBrush(tone < 3 ? c.ink : (tone < 5 ? c.second : c.third));
            p.drawEllipse(o, cell, cell);
            p.restore();
        }
    }
}

inline void horizon(QPainter &p, Dice &d, const Inks &c) {
    p.fillRect(kCanvas, c.ground);
    p.setPen(Qt::NoPen);
    p.setBrush(c.second);
    const double sun = d.between(110, 180);
    p.drawEllipse(QPointF(d.between(280, 720), d.between(300, 440)), sun, sun);
    const QColor hills[] = {c.third, mix(c.third, c.ink, 0.5), c.ink};
    for (int layer = 0; layer < 3; ++layer) {
        const double base = 560 + 125 * layer;
        const double amp = d.between(35, 85);
        const double turns = d.between(0.7, 1.6);
        const double phase = d.between(0, 2 * M_PI);
        QPainterPath path(QPointF(0, kSide));
        for (int x = 0; x <= 1000; x += 20)
            path.lineTo(x, base + amp * std::sin(x / kSide * 2 * M_PI * turns + phase));
        path.lineTo(kSide, kSide);
        path.closeSubpath();
        p.fillPath(path, hills[layer]);
    }
}

inline void bars(QPainter &p, Dice &d, const Inks &c) {
    const int n = 7 + d.below(5);
    const double slot = 760.0 / n;
    const int hot = d.below(n);
    double h = d.between(260, 560);
    p.fillRect(kCanvas, c.ground);
    p.setPen(Qt::NoPen);
    for (int i = 0; i < n; ++i) {
        h = qBound(160.0, h + d.between(-190, 190), 660.0);
        const QRectF r(120 + i * slot, 500 - h / 2, slot * 0.58, h);
        p.setBrush(i == hot ? c.second : c.ink);
        p.drawRoundedRect(r, r.width() / 2, r.width() / 2);
    }
}

inline void moons(QPainter &p, Dice &d, const Inks &c) {
    const double r = d.between(250, 310);
    const double lift = d.between(-90, 90);
    QPainterPath a, b;
    a.addEllipse(QPointF(500 - r * 0.55, 500 - lift), r, r);
    b.addEllipse(QPointF(500 + r * 0.55, 500 + lift), r, r);
    p.fillRect(kCanvas, c.ground);
    p.fillPath(a, c.ink);
    p.fillPath(b, c.second);
    p.fillPath(a.intersected(b), c.third);
}

// Soft lights on a ground, for the pictures an artist would have a photo in.
inline void aura(QPainter &p, Dice &d, const Inks &c) {
    p.fillRect(kCanvas, c.ground);
    const QColor lights[] = {c.ink, c.second, c.third};
    for (const QColor &light : lights) {
        const QPointF o(d.between(150, 850), d.between(150, 850));
        QRadialGradient g(o, d.between(420, 700));
        QColor solid = light, clear = light;
        solid.setAlpha(235);
        clear.setAlpha(0);
        g.setColorAt(0.0, solid);
        g.setColorAt(1.0, clear);
        p.fillRect(kCanvas, g);
    }
}

// One motif for every mix, so a row of them reads as a set. The hue steps
// round the wheel with the mix's number, so neighbours never share a colour.
inline void waves(QPainter &p, Dice &d, int number) {
    const int hue = (200 + number * 137) % 360;
    const QColor line = QColor::fromHsv(hue, 36, 244);
    const double phase = d.between(0, 2 * M_PI);
    const double length = d.between(380, 560);
    p.fillRect(kCanvas, QColor::fromHsv(hue, 132, 104));
    p.setBrush(Qt::NoBrush);
    for (int i = 0; i < 6; ++i) {
        QPainterPath path;
        for (int x = -40; x <= 1040; x += 10) {
            const double y = 330 + i * 92 + 44 * std::sin(x / length * 2 * M_PI + phase + i * 0.55);
            x == -40 ? path.moveTo(x, y) : path.lineTo(x, y);
        }
        QColor stroke = line;
        stroke.setAlpha(245 - i * 34);
        p.setPen(QPen(stroke, 30, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawPath(path);
    }
    p.setPen(Qt::NoPen);
    p.setBrush(QColor(0xf2e8d5));
    p.drawEllipse(QPointF(790, 180), 62, 62);
}

// ── dispatch ────────────────────────────────────────────────────────────────

inline QChar initialOf(const QString &slug) {
    for (const QChar ch : slug)
        if (ch.isLetterOrNumber()) return ch.toUpper();
    return QLatin1Char('A');
}

inline void drawSleeve(QPainter &p, const QString &slug) {
    Dice d(QStringLiteral("sleeve:") + slug);
    const Inks c = pickInks(d);
    switch (d.below(10)) {
    case 0: blocks(p, d, c); break;
    case 1: stripes(p, d, c); break;
    case 2: rings(p, d, c); break;
    case 3: letter(p, d, c, initialOf(slug)); break;
    case 4: split(p, d, c); break;
    case 5: dots(p, d, c); break;
    case 6: arcs(p, d, c); break;
    case 7: horizon(p, d, c); break;
    case 8: bars(p, d, c); break;
    default: moons(p, d, c); break;
    }
}

inline void drawPortrait(QPainter &p, const QString &slug) {
    Dice d(QStringLiteral("portrait:") + slug);
    const Inks c = pickInks(d);
    switch (d.below(5)) {
    case 0: horizon(p, d, c); break;
    case 1: moons(p, d, c); break;
    case 2: split(p, d, c); break;
    default: aura(p, d, c); break;
    }
}

inline void drawMosaic(QPainter &p, const QStringList &slugs) {
    if (slugs.isEmpty()) return;
    for (int i = 0; i < 4; ++i) {
        const QRectF tile((i % 2) * kSide / 2, (i / 2) * kSide / 2, kSide / 2, kSide / 2);
        p.save();
        p.setClipRect(tile);
        p.translate(tile.topLeft());
        p.scale(0.5, 0.5);
        drawSleeve(p, slugs.at(i % slugs.size()));
        p.restore();
    }
}

inline void drawCover(QPainter &p, const QString &id) {
    const QString kind = id.section(QLatin1Char('/'), 1, 1);
    const QString rest = id.section(QLatin1Char('/'), 2);
    if (kind == QLatin1String("playlist")) {
        drawMosaic(p, rest.split(QLatin1Char('+'), Qt::SkipEmptyParts));
    } else if (kind == QLatin1String("artist")) {
        drawPortrait(p, rest);
    } else if (kind == QLatin1String("mix")) {
        Dice d(QStringLiteral("mix:") + rest);
        waves(p, d, qAbs(rest.section(QLatin1Char('/'), 0, 0).toInt()));
    } else {
        drawSleeve(p, rest);
    }
}

inline bool handles(const QString &id) {
    return id.startsWith(QLatin1String("store/"));
}

inline QImage render(const QString &id, const QSize &requested) {
    const int w = requested.width() > 0 ? requested.width() : 640;
    const int h = requested.height() > 0 ? requested.height() : 640;
    QImage img(w, h, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::black);
    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setRenderHint(QPainter::TextAntialiasing, true);
    p.setClipRect(QRect(0, 0, w, h));
    p.scale(w / kSide, h / kSide);
    drawCover(p, id);
    p.end();
    return img;
}

} // namespace storeart
