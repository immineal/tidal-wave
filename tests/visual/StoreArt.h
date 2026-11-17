// Generated cover art for the store screenshots. Nothing here is real artwork,
// there is no lettering at all, and one id always paints the same picture.
//
// Ids: store/album/<slug>, store/artist/<slug>, store/mix/<number>/<slug>, and
// store/playlist/<slug>+<slug>+<slug>+<slug> for a mosaic of four albums.
//
// The sleeves are printed-looking rather than flat: soft colour fields, noise
// landscapes, light, halftone and marbled paint, all under a film grain. The
// palettes keep clear of ochre and of the indigo-violet zone; they were
// checked with the colour model before going in.
#pragma once

#include <algorithm>
#include <cmath>
#include <iterator>

#include <QColor>
#include <QCryptographicHash>
#include <QImage>
#include <QList>
#include <QPainter>
#include <QPainterPath>
#include <QRadialGradient>
#include <QLinearGradient>
#include <QString>
#include <QStringList>
#include <QtEndian>
#include <QtMath>

namespace storeart {

// Every family draws into this square; the painter is scaled to the image.
inline constexpr double kSide = 1000.0;
inline const QRectF kCanvas(0, 0, kSide, kSide);

// Per-pixel layers are computed at this size and drawn scaled.
inline constexpr int kField = 360;

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

// ── noise ───────────────────────────────────────────────────────────────────

inline double lattice(int x, int y, quint32 seed) {
    quint32 h = seed ^ (quint32(x) * 0x27d4eb2dU) ^ (quint32(y) * 0x165667b1U);
    h ^= h >> 15; h *= 0x85ebca6bU;
    h ^= h >> 13; h *= 0xc2b2ae35U;
    h ^= h >> 16;
    return h / 4294967295.0;
}

// Value noise in 0..1, smooth between lattice points.
inline double noise(double x, double y, quint32 seed) {
    const int xi = int(std::floor(x)), yi = int(std::floor(y));
    const double fx = x - xi, fy = y - yi;
    const double u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy);
    const double a = lattice(xi, yi, seed),     b = lattice(xi + 1, yi, seed);
    const double c = lattice(xi, yi + 1, seed), d = lattice(xi + 1, yi + 1, seed);
    return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v;
}

// Five octaves, normalised back to 0..1.
inline double fbm(double x, double y, quint32 seed) {
    double sum = 0, amp = 0.5, norm = 0;
    for (int o = 0; o < 5; ++o) {
        sum += amp * noise(x, y, seed + quint32(o) * 101u);
        norm += amp;
        x *= 2.03; y *= 2.03; amp *= 0.5;
    }
    return sum / norm;
}

inline double smooth(double e0, double e1, double x) {
    const double t = std::clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3 - 2 * t);
}

inline QColor mix(const QColor &a, const QColor &b, double t) {
    t = std::clamp(t, 0.0, 1.0);
    return QColor::fromRgbF(float(a.redF()   + (b.redF()   - a.redF())   * t),
                            float(a.greenF() + (b.greenF() - a.greenF()) * t),
                            float(a.blueF()  + (b.blueF()  - a.blueF())  * t));
}

// ── palettes ────────────────────────────────────────────────────────────────

struct Inks {
    QColor dark, light, mid, pop;
};

// Twelve sets of dark, light, mid and a pop colour. No ochre or amber, nothing
// near indigo or violet; the neutrals are paper, not cream.
inline Inks pickInks(Dice &d) {
    static const QRgb sets[][4] = {
        {0x0e3b43, 0xf1ede4, 0x8fc1b5, 0xe8664f},
        {0x141b2d, 0xdce6ee, 0x4f6d8f, 0xf08a4b},
        {0x1f3b2c, 0xeeebe2, 0x9db89a, 0xc4533a},
        {0x1b1b1d, 0xf3f1ec, 0xb8b2a8, 0xd6402f},
        {0x4e1e2c, 0xf6e9e6, 0xd99aa5, 0x2d7f7a},
        {0x14507a, 0xf7f7f4, 0xd7e5f2, 0xe5533d},
        {0x234b3a, 0xf4f1ea, 0xa8dcc4, 0xf2a3a0},
        {0x5b1a24, 0xf4ece6, 0xf3b49a, 0x3e5566},
        {0x101010, 0xf2f2f2, 0x29a6c9, 0xe0457b},
        {0x2b1d18, 0xebcdbe, 0xb8553a, 0x9cc3d5},
        {0x0b5568, 0xeaf4f2, 0x63c2c6, 0xf2757a},
        {0x2a2d34, 0xf5f4f7, 0xc9c5d6, 0xf26b3a},
    };
    const QRgb *s = sets[d.below(int(std::size(sets)))];
    Inks c{QColor(s[0]), QColor(s[1]), QColor(s[2]), QColor(s[3])};
    // Half the sleeves are printed light on dark, half dark on light.
    if (d.below(2)) std::swap(c.dark, c.light);
    return c;
}

// Mixes share one motif; these are their grounds, in turn.
inline QColor mixGround(int number) {
    static const QRgb grounds[] = {
        0x0f4c5c, 0x7a2e3a, 0x1f4d3a, 0x2a4a6b, 0x8a3b26, 0x24443f, 0x14507a, 0x4e1e2c,
    };
    return QColor(grounds[qAbs(number) % int(std::size(grounds))]);
}

// A per-pixel layer: `shade` maps a point in 0..1 to a colour.
template <typename F>
inline void field(QPainter &p, F shade) {
    QImage img(kField, kField, QImage::Format_RGB32);
    for (int y = 0; y < kField; ++y) {
        QRgb *row = reinterpret_cast<QRgb *>(img.scanLine(y));
        for (int x = 0; x < kField; ++x)
            row[x] = shade((x + 0.5) / kField, (y + 0.5) / kField).rgb();
    }
    p.save();
    p.setRenderHint(QPainter::SmoothPixmapTransform, true);
    p.drawImage(kCanvas, img);
    p.restore();
}

// ── the families ────────────────────────────────────────────────────────────

// Two or three soft-edged bands of colour on a ground, edges a little ragged,
// as brushed paint is.
inline void colourField(QPainter &p, Dice &d, const Inks &c) {
    const quint32 seed = d.next();
    const int n = 2 + d.below(2);
    const QColor fills[] = {c.mid, c.pop, c.light};
    double top = d.between(0.08, 0.14);
    struct Band { double y0, y1; QColor col; };
    QList<Band> bands;
    for (int i = 0; i < n; ++i) {
        const double h = (0.84 - (n - 1) * 0.05) / n * d.between(0.8, 1.2);
        bands.append({top, std::min(0.92, top + h), fills[(i + d.below(3)) % 3]});
        top += h + 0.05;
    }
    const double inset = d.between(0.07, 0.12);
    field(p, [&](double x, double y) {
        QColor out = c.dark;
        const double rough = (fbm(x * 9, y * 9, seed) - 0.5) * 0.03;
        for (const Band &b : bands) {
            const double e = 0.012;
            const double in = smooth(b.y0 - e, b.y0 + e, y + rough)
                            * (1 - smooth(b.y1 - e, b.y1 + e, y - rough))
                            * smooth(inset - e, inset + e, x + rough)
                            * (1 - smooth(1 - inset - e, 1 - inset + e, x - rough));
            // Streaks along the brush, at most 12% towards the ground.
            const double streak = 0.12 * fbm(x * 3, y * 14, seed + 7);
            out = mix(out, mix(b.col, c.dark, streak), in);
        }
        return out;
    });
}

// A landscape under a wide sky: ridges fading into haze, as a photograph of
// distant hills printed in two or three inks.
inline void landscape(QPainter &p, Dice &d, const Inks &c) {
    const quint32 seed = d.next();
    const bool night = d.below(2);
    const QColor skyTop = night ? c.dark : c.light;
    const QColor skyLow = mix(c.mid, c.light, night ? 0.2 : 0.55);
    const QColor nearInk = night ? mix(c.dark, QColor(Qt::black), 0.35) : c.dark;
    const double sunX = d.between(0.25, 0.75), sunY = d.between(0.28, 0.42);
    const double sunR = d.between(0.06, 0.1);
    const int layers = 4;
    field(p, [&](double x, double y) {
        QColor out = mix(skyTop, skyLow, smooth(0.0, 0.62, y));
        const double sd = std::hypot(x - sunX, y - sunY);
        out = mix(out, c.pop, (1 - smooth(sunR - 0.004, sunR + 0.004, sd)) * 0.95);
        out = mix(out, c.pop, (1 - smooth(0, sunR * 4, sd)) * 0.18);
        for (int i = 0; i < layers; ++i) {
            const double base = 0.5 + 0.11 * i;
            const double ridge = base - 0.14 * fbm(x * (1.6 + i), i * 3.7, seed + quint32(i))
                               + 0.04 * (fbm(x * 9, i * 1.3, seed + 50) - 0.5);
            const double haze = 1.0 - double(i) / (layers - 1);
            const QColor ink = mix(nearInk, skyLow, haze * 0.75);
            out = mix(out, ink, smooth(ridge - 0.002, ridge + 0.002, y));
        }
        return out;
    });
}

// Out-of-focus light on a dark ground: a night street through a wet window.
inline void glow(QPainter &p, Dice &d, const Inks &c) {
    const QColor ground = c.dark.lightness() < c.light.lightness() ? c.dark : c.light;
    const QColor deep = mix(ground, QColor(Qt::black), 0.55);
    p.fillRect(kCanvas, deep);
    p.setPen(Qt::NoPen);
    p.setCompositionMode(QPainter::CompositionMode_Screen);
    const QColor lights[] = {c.pop, c.mid, mix(c.pop, Qt::white, 0.4)};
    const int n = 4 + d.below(4);
    for (int i = 0; i < n; ++i) {
        const QPointF o(d.between(80, 920), d.between(120, 880));
        const double r = d.between(90, 330);
        QColor core = lights[i % 3];
        QRadialGradient g(o, r);
        core.setAlphaF(float(d.between(0.45, 0.85)));
        QColor edge = core;
        edge.setAlpha(0);
        g.setColorAt(0.0, core);
        g.setColorAt(0.55, QColor::fromRgbF(core.redF(), core.greenF(), core.blueF(),
                                            core.alphaF() * 0.55f));
        g.setColorAt(1.0, edge);
        p.setBrush(g);
        p.drawEllipse(o, r, r);
    }
    p.setCompositionMode(QPainter::CompositionMode_SourceOver);
}

// A two-colour halftone print: a disc in the pop colour and a dark ground
// rising from the foot, each its own dot screen, on a tinted stock.
inline void halftone(QPainter &p, Dice &d, const Inks &c) {
    const bool lightIsLight = c.light.lightness() > c.dark.lightness();
    const QColor paper = mix(lightIsLight ? c.light : c.dark, c.mid, 0.25);
    const QColor ink = lightIsLight ? c.dark : c.light;
    const QPointF sun(d.between(320, 680), d.between(300, 460));
    const double sunR = d.between(190, 260);
    const double rise = d.between(560, 700);
    const double cell = d.between(22, 30);
    const quint32 seed = d.next();
    p.fillRect(kCanvas, paper);
    p.setPen(Qt::NoPen);
    // weight(x, y) in 0..1 is the share of the cell the dot covers.
    auto screen = [&](const QColor &col, double angle, auto weight) {
        const double a = qDegreesToRadians(angle);
        const double ca = std::cos(a), sa = std::sin(a);
        p.setBrush(col);
        for (double v = -800; v < 800; v += cell) {
            for (double u = -800; u < 800; u += cell) {
                const QPointF q(500 + u * ca - v * sa, 500 + u * sa + v * ca);
                if (q.x() < -cell || q.y() < -cell || q.x() > kSide + cell || q.y() > kSide + cell)
                    continue;
                const double w = std::clamp(weight(q.x(), q.y()), 0.0, 1.0);
                const double r = cell * 0.5 * std::sqrt(w) * 1.25;
                if (r > 0.8) p.drawEllipse(q, r, r);
            }
        }
    };
    screen(c.pop, 15, [&](double x, double y) {
        const double dist = std::hypot(x - sun.x(), y - sun.y());
        return (1.0 - smooth(sunR * 0.75, sunR * 1.15, dist)) * 0.85;
    });
    p.setCompositionMode(QPainter::CompositionMode_Multiply);
    screen(ink, 45, [&](double x, double y) {
        const double edge = rise + 60 * (fbm(x / 300, 0.5, seed) - 0.5);
        return smooth(edge - 40, edge + 260, y) * 0.9 + 0.08;
    });
    p.setCompositionMode(QPainter::CompositionMode_SourceOver);
}

// Marbled paint: noise pushed through noise and cut into three inks.
inline void marble(QPainter &p, Dice &d, const Inks &c) {
    const quint32 seed = d.next();
    const double scale = d.between(1.6, 2.6);
    const double swirl = d.between(1.4, 2.4);
    field(p, [&](double x, double y) {
        const double qx = fbm(x * scale, y * scale, seed);
        const double qy = fbm(x * scale + 5.2, y * scale + 1.3, seed);
        const double v = fbm(x * scale + swirl * qx * 4, y * scale + swirl * qy * 4, seed + 9);
        const double t = v * 2.2 - 0.6;
        QColor out = mix(c.dark, c.mid, smooth(0.25, 0.32, t));
        out = mix(out, c.light, smooth(0.52, 0.58, t));
        out = mix(out, c.pop, smooth(0.80, 0.84, t) * 0.9);
        return out;
    });
}

// A sun sinking into water: a sky gradient, a disc cut by the horizon and its
// reflection broken into lines.
inline void sunset(QPainter &p, Dice &d, const Inks &c) {
    const QColor top = c.dark.lightness() < c.light.lightness() ? c.dark : c.light;
    const QColor low = mix(c.pop, c.light, 0.35);
    const double horizon = d.between(560, 680);
    QLinearGradient sky(0, 0, 0, horizon);
    sky.setColorAt(0, top);
    sky.setColorAt(0.65, mix(top, c.mid, 0.6));
    sky.setColorAt(1, low);
    p.fillRect(QRectF(0, 0, kSide, horizon), sky);
    QLinearGradient sea(0, horizon, 0, kSide);
    sea.setColorAt(0, mix(top, c.mid, 0.45));
    sea.setColorAt(1, mix(top, QColor(Qt::black), 0.3));
    p.fillRect(QRectF(0, horizon, kSide, kSide - horizon), sea);

    const double r = d.between(140, 210);
    const double cx = d.between(360, 640);
    QPainterPath disc;
    disc.addEllipse(QPointF(cx, horizon - r * d.between(0.2, 0.6)), r, r);
    QPainterPath above;
    above.addRect(QRectF(0, 0, kSide, horizon));
    p.fillPath(disc.intersected(above), c.pop);
    p.setPen(Qt::NoPen);
    QColor glint = c.pop;
    for (int i = 0; i < 9; ++i) {
        const double y = horizon + 18 + i * 34;
        const double w = r * (1.6 - i * 0.14) * d.between(0.7, 1.1);
        glint.setAlphaF(float(0.75 - i * 0.07));
        p.setBrush(glint);
        p.drawRoundedRect(QRectF(cx - w / 2, y, w, 9), 4.5, 4.5);
    }
}

// Torn paper laid on a ground, each scrap with a shadow under it.
inline void collage(QPainter &p, Dice &d, const Inks &c) {
    p.fillRect(kCanvas, c.light);
    const quint32 seed = d.next();
    const QColor scraps[] = {c.dark, c.mid, c.pop};
    p.setPen(Qt::NoPen);
    for (int i = 0; i < 3; ++i) {
        const QPointF o(d.between(260, 740), d.between(260, 740));
        const double w = d.between(300, 560), h = d.between(260, 520);
        const double turn = d.between(-25, 25);
        QPolygonF corners;
        for (const QPointF k : {QPointF(-1, -1), QPointF(1, -1), QPointF(1, 1), QPointF(-1, 1)})
            corners << QPointF(k.x() * w / 2, k.y() * h / 2);
        // The torn edge: every side walked in short steps, each nudged.
        QPainterPath path;
        for (int side = 0; side < 4; ++side) {
            const QPointF a = corners[side], b = corners[(side + 1) % 4];
            for (int s = 0; s < 40; ++s) {
                const double t = s / 40.0;
                const QPointF q = a + (b - a) * t;
                const QPointF n(-(b - a).y(), (b - a).x());
                const double len = std::hypot(n.x(), n.y());
                const double jag = (noise(side * 40 + s * 0.9, i * 7.0, seed) - 0.5) * 16;
                const QPointF pt = q + n / len * jag;
                if (side == 0 && s == 0) path.moveTo(pt); else path.lineTo(pt);
            }
        }
        path.closeSubpath();
        p.save();
        p.translate(o);
        p.rotate(turn);
        p.translate(8, 10);
        p.fillPath(path, QColor(0, 0, 0, 46));
        p.translate(-8, -10);
        p.fillPath(path, scraps[(i + d.below(3)) % 3]);
        p.restore();
    }
}

// A large shape cut by a band: a sleeve set in the Swiss manner, on a paper
// ground, with its second colour slightly off register.
inline void swiss(QPainter &p, Dice &d, const Inks &c) {
    p.fillRect(kCanvas, c.light);
    p.setPen(Qt::NoPen);
    const QPointF o(d.between(380, 620), d.between(360, 560));
    const double r = d.between(240, 330);
    p.setBrush(c.pop);
    p.drawEllipse(o + QPointF(9, -6), r, r);
    p.setCompositionMode(QPainter::CompositionMode_Multiply);
    p.setBrush(c.mid);
    p.drawEllipse(o, r, r);
    p.setCompositionMode(QPainter::CompositionMode_SourceOver);
    const double band = d.between(560, 760);
    p.fillRect(QRectF(0, band, kSide, d.between(70, 130)), c.dark);
    p.fillRect(QRectF(80, 120, d.between(60, 240), 6), c.dark);
    p.fillRect(QRectF(80, 138, d.between(40, 160), 6), c.dark);
}

// A figure against the light, for an artist: head and shoulders in shadow
// with a rim of light, on a soft studio backdrop.
inline void silhouette(QPainter &p, Dice &d, const Inks &c) {
    const QColor back = c.mid;
    QRadialGradient g(QPointF(d.between(380, 620), d.between(300, 420)), 760);
    g.setColorAt(0, mix(back, Qt::white, 0.35));
    g.setColorAt(0.6, back);
    g.setColorAt(1, mix(back, c.dark, 0.6));
    p.fillRect(kCanvas, g);

    const double cx = d.between(440, 560);
    const double headY = d.between(390, 450), headR = d.between(120, 145);
    QPainterPath figure;
    figure.addEllipse(QPointF(cx, headY), headR * 0.86, headR);
    QPainterPath body;
    const double neck = headY + headR * 0.9;
    const double h = headR;
    body.moveTo(cx - h * 0.4, neck - 20);
    body.lineTo(cx + h * 0.4, neck - 20);
    // Neck, the slope of a shoulder, then the arm falling off the frame.
    body.cubicTo(cx + h * 0.45, neck + h * 0.5, cx + h * 1.6, neck + h * 0.5, cx + h * 2.3, neck + h * 0.9);
    body.cubicTo(cx + h * 2.8, neck + h * 1.2, cx + h * 3.0, neck + h * 2.0, cx + h * 3.1, kSide + 10);
    body.lineTo(cx - h * 3.1, kSide + 10);
    body.cubicTo(cx - h * 3.0, neck + h * 2.0, cx - h * 2.8, neck + h * 1.2, cx - h * 2.3, neck + h * 0.9);
    body.cubicTo(cx - h * 1.6, neck + h * 0.5, cx - h * 0.45, neck + h * 0.5, cx - h * 0.4, neck - 20);
    figure = figure.united(body);
    // The rim: the figure a few units up and to one side, in the light.
    const double side = d.below(2) ? 10 : -10;
    p.save();
    p.translate(side, -6);
    p.fillPath(figure, mix(c.pop, Qt::white, 0.3));
    p.restore();
    const QColor shade = c.dark.lightness() < c.light.lightness() ? c.dark : c.light;
    p.fillPath(figure, mix(shade, QColor(Qt::black), 0.4));
}

// One motif for every mix, so a row of them reads as a set: soft lines over a
// ground that steps through mixGround() with the mix's number.
inline void waves(QPainter &p, Dice &d, int number) {
    const QColor ground = mixGround(number);
    QRadialGradient g(QPointF(300, 260), 900);
    g.setColorAt(0, mix(ground, Qt::white, 0.18));
    g.setColorAt(1, mix(ground, Qt::black, 0.25));
    p.fillRect(kCanvas, g);
    const QColor line = mix(ground, QColor(0xf4f1ea), 0.85);
    const double phase = d.between(0, 2 * M_PI);
    const double length = d.between(380, 560);
    p.setBrush(Qt::NoBrush);
    for (int i = 0; i < 6; ++i) {
        QPainterPath path;
        for (int x = -40; x <= 1040; x += 10) {
            const double y = 330 + i * 92 + 44 * std::sin(x / length * 2 * M_PI + phase + i * 0.55);
            x == -40 ? path.moveTo(x, y) : path.lineTo(x, y);
        }
        QColor stroke = line;
        stroke.setAlpha(235 - i * 32);
        p.setPen(QPen(stroke, 26, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawPath(path);
    }
}

// ── dispatch ────────────────────────────────────────────────────────────────

inline void drawSleeve(QPainter &p, const QString &slug) {
    Dice d(QStringLiteral("sleeve:") + slug);
    const Inks c = pickInks(d);
    switch (d.below(8)) {
    case 0: colourField(p, d, c); break;
    case 1: landscape(p, d, c); break;
    case 2: glow(p, d, c); break;
    case 3: halftone(p, d, c); break;
    case 4: marble(p, d, c); break;
    case 5: sunset(p, d, c); break;
    case 6: collage(p, d, c); break;
    default: swiss(p, d, c); break;
    }
}

inline void drawPortrait(QPainter &p, const QString &slug) {
    Dice d(QStringLiteral("portrait:") + slug);
    const Inks c = pickInks(d);
    switch (d.below(4)) {
    case 0: landscape(p, d, c); break;
    case 1: glow(p, d, c); break;
    case 2: sunset(p, d, c); break;
    default: silhouette(p, d, c); break;
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
        waves(p, d, rest.section(QLatin1Char('/'), 0, 0).toInt());
    } else {
        drawSleeve(p, rest);
    }
}

// Film grain at the output's own pixel size, so it survives the downscale.
inline void grain(QImage &img, const QString &id) {
    const quint32 seed = qFromLittleEndian<quint32>(
        QCryptographicHash::hash(id.toUtf8(), QCryptographicHash::Md5).constData());
    for (int y = 0; y < img.height(); ++y) {
        QRgb *row = reinterpret_cast<QRgb *>(img.scanLine(y));
        for (int x = 0; x < img.width(); ++x) {
            const int n = int((lattice(x, y, seed) - 0.5) * 18);
            row[x] = qRgb(std::clamp(qRed(row[x]) + n, 0, 255),
                          std::clamp(qGreen(row[x]) + n, 0, 255),
                          std::clamp(qBlue(row[x]) + n, 0, 255));
        }
    }
}

inline bool handles(const QString &id) {
    return id.startsWith(QLatin1String("store/"));
}

inline QImage render(const QString &id, const QSize &requested) {
    const int w = requested.width() > 0 ? requested.width() : 640;
    const int h = requested.height() > 0 ? requested.height() : 640;
    QImage img(w, h, QImage::Format_RGB32);
    img.fill(Qt::black);
    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setClipRect(QRect(0, 0, w, h));
    p.scale(w / kSide, h / kSide);
    drawCover(p, id);
    p.end();
    grain(img, id);
    return img;
}

} // namespace storeart
