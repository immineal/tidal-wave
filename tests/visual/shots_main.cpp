// QtQuickTest runner for the screenshot harness.
//
// Same shape as tests/stress/tst_stress_main.cpp, with one addition the shots
// need and no test does: a "tidal" image provider that paints something.
//
// Why each piece is here:
//
//   * the real Prefs and the real I18n go in as the `prefs` and `i18n` context
//     properties, and Prefs is wired into the ThemePalette singleton, exactly
//     as Application::run() does it. The theme cannot be switched between
//     shots without the first, and the Settings panel's language row is empty
//     without the second - which would make a screenshot of Settings a picture
//     of the harness rather than of the app.
//
//   * the QSettings identity is deliberately not the app's. The shot run
//     writes a theme several times; if the sandbox run.sh builds ever failed
//     to isolate HOME, writing under the app's own organisation and
//     application name would overwrite the developer's live settings. A
//     different pair cannot, whatever happens to the sandbox.
//
//   * the directory the PNGs go in arrives as the `shotOutDir` context
//     property. QML has no getenv, and the procfs trick StressLib.js uses
//     needs QML_XHR_ALLOW_FILE_READ set or it silently returns the fallback
//     and forty PNGs land in /tmp. One context property cannot fail quietly.
//
//   * the application font is the one Application::run() installs. Without it
//     the harness draws in whatever fontconfig calls "sans", which here is
//     Noto Sans - and Noto Sans has no glyph for the wordmark's U+224B, so the
//     logo tile came out blank in every shot while the shipping binary draws
//     it fine out of DejaVu Sans. A screenshot run that gets the font wrong
//     invents missing glyphs and moves every elision point.
//
//   * tests/TestStubs.h hands back a fully transparent image for every
//     image://tidal/ URL, which is right for a layout test and wrong for a
//     screenshot: half of what is being judged here is text and controls drawn
//     *over* cover art, and over a transparent cover they are really drawn
//     over the page background. ShotArtProvider paints a deterministic cover
//     instead, so the art scrims and `artInk` are seen doing their job. It is
//     registered before installTestStubs(), which only adds its own provider
//     when the name is free.
//
// Everything else (auth, bridge, player, downloader, cast, app, pins, library)
// comes from tests/TestStubs.h unchanged.

#include <QtQuickTest/quicktest.h>

#include <QCoreApplication>
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
#include <QSurfaceFormat>

#include "TestStubs.h"

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

class ShotSetup : public QObject {
    Q_OBJECT

public:
    ShotSetup() {
        // Before any QSettings is constructed. See the note above.
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
        // What src/ui/Application.cpp sets before the engine runs, on this
        // platform. Two things there are deliberately not copied because both
        // are compiled out on Linux, which is the only place this harness runs:
        // the macOS arm of the font stack, and QQuickStyle::setStyle("Basic"),
        // which is guarded to macOS and Windows precisely because forcing it
        // here was measured to move 24 of these 51 shots.
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
    }

private:
    Prefs *m_prefs = nullptr;
    I18n  *m_i18n  = nullptr;
};

QUICK_TEST_MAIN_WITH_SETUP(tidalwave_shots, ShotSetup)
#include "shots_main.moc"
