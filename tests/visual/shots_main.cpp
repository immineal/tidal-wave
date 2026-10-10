// QtQuickTest runner for the screenshot harness. The real Prefs and I18n go in
// as context properties and Prefs is wired into ThemePalette, as
// Application::run() does. The QSettings identity is deliberately not the
// app's, so a failed sandbox cannot overwrite live settings. ShotArtProvider
// paints covers, because TestStubs.h hands back transparent images. Everything
// else comes from tests/TestStubs.h unchanged.

#include <QtQuickTest/quicktest.h>

#include <QCoreApplication>
#include <QEventLoop>
#include <QFont>
#include <QGuiApplication>
#include <QConicalGradient>
#include <QCryptographicHash>
#include <QLinearGradient>
#include <QObject>
#include <QPainter>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickImageProvider>
#include <QQuickItem>
#include <QQuickItemGrabResult>
#include <QQuickWindow>
#include <QSurfaceFormat>
#include <QTimer>

#include "TestStubs.h"
#include "StoreArt.h"

#include "I18n.h"
#include "Prefs.h"
#include "ThemePalette.h"

namespace {

// A stand-in for album art: deterministic per URL, saturated, and busy enough
// near the edges that a scrim either works or visibly does not.
class ShotArtProvider : public QQuickImageProvider {
public:
    ShotArtProvider() : QQuickImageProvider(QQuickImageProvider::Image) {}

    QImage requestImage(const QString &id, QSize *size, const QSize &requested) override {
        // The store set has its own art; every other id keeps the wash below.
        if (storeart::handles(id)) {
            const QImage cover = storeart::render(id, requested);
            if (size) *size = cover.size();
            return cover;
        }

        const int w = requested.width()  > 0 ? requested.width()  : 600;
        const int h = requested.height() > 0 ? requested.height() : 600;

        // Hash rather than a counter, so the same cover URL is the same colour
        // in every theme and the shots can be compared side by side.
        const QByteArray digest =
            QCryptographicHash::hash(id.toUtf8(), QCryptographicHash::Md5);
        const int hue  = quint8(digest.at(0)) * 360 / 256;
        const int hue2 = (hue + 150) % 360;

        QImage img(w, h, QImage::Format_ARGB32_Premultiplied);
        QPainter p(&img);
        p.setRenderHint(QPainter::Antialiasing, true);

        QLinearGradient g(0, 0, w, h);
        g.setColorAt(0.0, QColor::fromHsv(hue,  200, 230));
        g.setColorAt(1.0, QColor::fromHsv(hue2, 220,  70));
        p.fillRect(0, 0, w, h, g);

        // Two shapes so the cover is not a flat wash: a flat one would hide a
        // scrim that is too weak over a detailed sleeve.
        p.setPen(Qt::NoPen);
        p.setBrush(QColor::fromHsv((hue + 60) % 360, 180, 255, 180));
        p.drawEllipse(QRectF(w * 0.08, h * 0.52, w * 0.52, w * 0.52));
        p.setBrush(QColor(255, 255, 255, 60));
        p.drawEllipse(QRectF(w * 0.55, h * 0.06, w * 0.40, w * 0.40));
        p.end();

        if (size) *size = QSize(w, h);
        return img;
    }
};

} // namespace

// Saves an item at one pixel per logical pixel, averaged down from however
// many device pixels it was drawn with. On a 2x display that is the
// antialiasing the 1px icon strokes need.
class ShotGrabber : public QObject {
    Q_OBJECT

public:
    using QObject::QObject;

    Q_INVOKABLE bool save(QQuickItem *item, const QString &path) {
        if (!item) return false;
        const QSharedPointer<QQuickItemGrabResult> grab = item->grabToImage();
        if (!grab) return false;
        QEventLoop loop;
        connect(grab.data(), &QQuickItemGrabResult::ready, &loop, &QEventLoop::quit);
        QTimer::singleShot(10000, &loop, &QEventLoop::quit);
        loop.exec();
        const QImage drawn = grab->image();
        if (drawn.isNull() || !item->window()) return false;
        // Over the window's own colour, which is what shows through wherever
        // the item paints nothing.
        QImage flat(drawn.size(), QImage::Format_RGB32);
        flat.setDevicePixelRatio(drawn.devicePixelRatio());
        flat.fill(item->window()->color());
        QPainter(&flat).drawImage(0, 0, drawn);
        return flat.scaled(item->size().toSize(), Qt::IgnoreAspectRatio,
                           Qt::SmoothTransformation)
                   .save(path);
    }
};

class ShotSetup : public QObject {
    Q_OBJECT

public:
    ShotSetup() {
        // Before any QSettings is constructed: see the file header.
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveVisual"));
        QCoreApplication::setApplicationName(QStringLiteral("Tidal Wave Visual"));

        // The app asks for 4x multisampling before its window exists. Without
        // it the stroked icons come out as hairlines, or not at all.
        QSurfaceFormat format;
        format.setSamples(4);
        QSurfaceFormat::setDefaultFormat(format);
    }

public slots:
    // Called by QtQuickTest once per QML scene file, before that file is loaded.
    void qmlEngineAvailable(QQmlEngine *engine) {
        // What Application::run() sets before the engine runs, on Linux, the
        // only platform this harness runs on. With another font the shots move
        // their elision points and can lose glyphs the app has.
        QFont appFont(QStringLiteral("Inter"));
        appFont.setFamilies({QStringLiteral("Inter"), QStringLiteral("DejaVu Sans"),
                             QStringLiteral("sans-serif")});
        QGuiApplication::setFont(appFont);

        // First, so installTestStubs() leaves the name alone.
        if (!engine->imageProvider(QStringLiteral("tidal")))
            engine->addImageProvider(QStringLiteral("tidal"), new ShotArtProvider());

        installTestStubs(engine, this);

        m_prefs = new Prefs(this);
        m_i18n  = new I18n(m_prefs, this);
        m_i18n->setEngine(engine);
        ThemePalette::instance()->setPrefs(m_prefs);

        QQmlContext *ctx = engine->rootContext();
        ctx->setContextProperty(QStringLiteral("prefs"), m_prefs);
        ctx->setContextProperty(QStringLiteral("i18n"), m_i18n);
        ctx->setContextProperty(QStringLiteral("shotOutDir"),
                                qEnvironmentVariable("TW_SHOT_OUT"));
        ctx->setContextProperty(QStringLiteral("shotGrabber"), new ShotGrabber(this));
    }

private:
    Prefs *m_prefs = nullptr;
    I18n  *m_i18n  = nullptr;
};

QUICK_TEST_MAIN_WITH_SETUP(tidalwave_shots, ShotSetup)
#include "shots_main.moc"
