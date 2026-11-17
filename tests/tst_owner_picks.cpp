// SPDX-License-Identifier: GPL-3.0-or-later

// Values that were chosen on purpose: words, colours, sizes and defaults.
// Each check names what it pins. These are chosen values: do not change one,
// or this test, without asking. TIDALWAVE_QML_DIR comes from tests/CMakeLists.txt.

#include <algorithm>
#include <cmath>

#include <QColor>
#include <QCoreApplication>
#include <QFile>
#include <QRegularExpression>
#include <QSettings>
#include <QTemporaryDir>
#include <QTest>
#include <QVariantMap>
#include <QXmlStreamReader>

#include "api/TidalBridge.h"
#include "player/Downloader.h"
#include "scrobble/ScrobbleSink.h"
#include "ui/CoverColor.h"
#include "ui/Prefs.h"
#include "ui/ThemePalette.h"
#include "ui/UpdateCheck.h"

namespace {

QString repoFile(const QString &rel) {
    return QStringLiteral(TIDALWAVE_QML_DIR "/../") + rel;
}

QString readText(const QString &rel) {
    QFile f(repoFile(rel));
    if (!f.open(QIODevice::ReadOnly)) return {};
    return QString::fromUtf8(f.readAll());
}

struct Entry {
    QString source;
    QString comment;   // the disambiguation, empty for most
    QString german;
};

QList<Entry> readCatalogue() {
    QList<Entry> out;
    QFile f(repoFile(QStringLiteral("i18n/tidal-wave_de.ts")));
    if (!f.open(QIODevice::ReadOnly)) return out;
    QXmlStreamReader xml(&f);
    Entry e;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isEndElement() && xml.name() == QLatin1String("message")) {
            out << e;
            e = Entry();
        } else if (xml.isStartElement() && xml.name() == QLatin1String("source")) {
            e.source = xml.readElementText();
        } else if (xml.isStartElement() && xml.name() == QLatin1String("comment")) {
            e.comment = xml.readElementText();
        } else if (xml.isStartElement() && xml.name() == QLatin1String("translation")) {
            e.german = xml.readElementText(QXmlStreamReader::IncludeChildElements);
        }
    }
    return out;
}

QColor token(const char *theme, const char *key, bool tinted = true) {
    return theme::palette(QString::fromLatin1(theme), false, tinted)
        .value(QString::fromLatin1(key)).value<QColor>();
}

// OKLab, for the cover tint: its chroma is what the chosen 70% is of.
struct OkLab { double L, a, b; };

double toLinear(double c) {
    return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
}

OkLab okLab(const QColor &c) {
    const double r = toLinear(c.redF()), g = toLinear(c.greenF()), b = toLinear(c.blueF());
    const double l = std::cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const double m = std::cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const double s = std::cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return { 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
             1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
             0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s };
}

double okChroma(const QColor &c) { const OkLab o = okLab(c); return std::hypot(o.a, o.b); }
double okHue(const QColor &c) {
    const OkLab o = okLab(c);
    const double h = std::atan2(o.b, o.a) * 180.0 / M_PI;
    return h < 0 ? h + 360.0 : h;
}

// An sRGB colour at OKLCH (L, C, h), rounded to 8 bits.
QColor fromOkLch(double L, double C, double hDeg) {
    const double a = C * std::cos(hDeg * M_PI / 180.0), b = C * std::sin(hDeg * M_PI / 180.0);
    const double l = std::pow(L + 0.3963377774 * a + 0.2158037573 * b, 3.0);
    const double m = std::pow(L - 0.1055613458 * a - 0.0638541728 * b, 3.0);
    const double s = std::pow(L - 0.0894841775 * a - 1.2914855480 * b, 3.0);
    auto enc = [](double v) {
        v = std::clamp(v, 0.0, 1.0);
        return v <= 0.0031308 ? 12.92 * v : 1.055 * std::pow(v, 1.0 / 2.4) - 0.055;
    };
    return QColor::fromRgbF(float(enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)),
                            float(enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)),
                            float(enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)))
        .toRgb();
}

} // namespace

class TestOwnerPicks : public QObject {
    Q_OBJECT

    QList<Entry> m_catalogue;
    QTemporaryDir m_dir;

    // Every entry with this source, or only those without a disambiguation.
    void expectGerman(const QString &source, const QString &german, bool plainOnly = false) {
        bool found = false;
        for (const Entry &e : std::as_const(m_catalogue)) {
            if (e.source != source || (plainOnly && !e.comment.isEmpty())) continue;
            found = true;
            QCOMPARE(e.german, german);
        }
        QVERIFY2(found, qPrintable("not in the German catalogue: " + source));
    }

    void expectInQml(const QString &file, const QString &source) {
        const QString text = readText(QStringLiteral("qml/") + file);
        QVERIFY2(!text.isEmpty(), qPrintable("could not read qml/" + file));
        QVERIFY2(text.contains(QStringLiteral("qsTr(\"") + source + QLatin1Char('"')),
                 qPrintable(QStringLiteral("qml/%1 no longer says \"%2\"").arg(file, source)));
    }

private slots:
    void initTestCase() {
        m_catalogue = readCatalogue();
        QVERIFY2(m_catalogue.size() > 300, "the German catalogue reads as nearly empty");
        // Prefs reads a settings file; give it an empty one of its own.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_owner_picks"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    // ── words ────────────────────────────────────────────────────────────

    void theColourSwitchIsLetTheColourIn() {
        const QString text = readText(QStringLiteral("qml/components/SettingsPanel.qml"));
        QCOMPARE(text.count(QStringLiteral("qsTr(\"Let the colour in\")")), 2);   // label and switch
        expectGerman(QStringLiteral("Let the colour in"), QStringLiteral("Mehr Farbe wagen"));
    }

    void labelsSayMyNotYour() {
        expectInQml(QStringLiteral("pages/HomePage.qml"), QStringLiteral("My mixes"));
        expectInQml(QStringLiteral("pages/HomePage.qml"), QStringLiteral("My playlists"));
        expectInQml(QStringLiteral("components/SideBar.qml"), QStringLiteral("My account"));
        expectGerman(QStringLiteral("My mixes"), QStringLiteral("Meine Mixe"));
        expectGerman(QStringLiteral("My playlists"), QStringLiteral("Meine Playlists"));
        expectGerman(QStringLiteral("My account"), QStringLiteral("Mein Konto"));
    }

    void collectionAndLikedTracks() {
        expectInQml(QStringLiteral("pages/CollectionPage.qml"), QStringLiteral("Collection"));
        expectInQml(QStringLiteral("pages/CollectionPage.qml"), QStringLiteral("Liked tracks"));
        expectGerman(QStringLiteral("Collection"), QStringLiteral("Sammlung"));
        expectGerman(QStringLiteral("Liked tracks"), QStringLiteral("Lieblingstitel"));
    }

    // The page's name. Home's "Now playing" over the current track is a
    // different line, with a comment of its own.
    void nowPlayingIsJetztLaeuft() {
        expectGerman(QStringLiteral("Now playing"), QStringLiteral("Jetzt läuft"), true);
    }

    void losslessSaysSixteenBit() {
        expectInQml(QStringLiteral("components/SettingsPanel.qml"), QStringLiteral("Lossless (16-bit)"));
        expectGerman(QStringLiteral("Lossless (16-bit)"), QStringLiteral("Lossless (16 Bit)"));
    }

    void surpriseMeAndTheSyncedNote() {
        expectInQml(QStringLiteral("pages/CollectionPage.qml"), QStringLiteral("Surprise me"));
        expectInQml(QStringLiteral("pages/NowPlayingPage.qml"),
                    QStringLiteral("Synced automatically, may be off"));
    }

    // Product names, the same six words in every language.
    void themeNamesAreUntranslated() {
        QStringList labels;
        for (const auto &t : theme::themes()) labels << t.label;
        QCOMPARE(labels, (QStringList{ "Sea", "Pine", "Rust", "Sky", "Sand", "Clay" }));
        for (const QString &l : std::as_const(labels))
            for (const Entry &e : std::as_const(m_catalogue))
                QVERIFY2(e.source != l, qPrintable("the theme name is in the catalogue: " + l));
    }

    void feedbackGoesToTheProjectMailbox() {
        QVERIFY(readText(QStringLiteral("src/ui/Feedback.cpp"))
                    .contains(QStringLiteral("tidal-wave@linu.li")));
    }

    // ── colours ──────────────────────────────────────────────────────────

    void skyAccentAndRed() {
        for (bool tinted : {true, false}) {
            QCOMPARE(token("sky", "accent", tinted), QColor("#0074B5"));
            QCOMPARE(token("sky", "red", tinted), QColor("#C51B32"));
        }
    }

    void sandGrounds() {
        QCOMPARE(token("sand", "bg"),          QColor("#F9F4E8"));
        QCOMPARE(token("sand", "surface"),     QColor("#EFE7D8"));
        QCOMPARE(token("sand", "surfaceHigh"), QColor("#E4DBC8"));
        QCOMPARE(token("sand", "surfaceHov"),  QColor("#C8BCA3"));
        QCOMPARE(token("sand", "border"),      QColor("#C8BCA5"));
    }

    void clayGrounds() {
        QCOMPARE(token("clay", "bg"),          QColor("#F8EFEA"));
        QCOMPARE(token("clay", "surface"),     QColor("#F3E4DE"));
        QCOMPARE(token("clay", "surfaceHigh"), QColor("#EED7CF"));
        QCOMPARE(token("clay", "surfaceHov"),  QColor("#D2B4AB"));
        QCOMPARE(token("clay", "border"),      QColor("#E6CAC1"));
    }

    void accentsOfTheOtherThemes() {
        QCOMPARE(token("sand", "accent"),     QColor("#2F6F4E"));   // Sand keeps a green
        QCOMPARE(token("rust", "accent"),     QColor("#BA5702"));
        QCOMPARE(token("rust", "accentDim"),  QColor("#8B3E00"));
        QCOMPARE(token("clay", "accent"),     QColor("#AB5D2B"));
        QCOMPARE(token("clay", "accentDim"),  QColor("#7E4118"));
        QCOMPARE(token("clay", "accentText"), QColor("#944812"));
    }

    // The lighter accent text on the dark themes.
    void darkAccentText() {
        QCOMPARE(token("sea",  "accentText"), QColor("#42BEFA"));
        QCOMPARE(token("pine", "accentText"), QColor("#50C886"));
        QCOMPARE(token("rust", "accentText"), QColor("#FAA36C"));
    }

    // The tile keeps the brand blue in every theme, as the icon does.
    void appMarkIsBrandBlue() {
        QVERIFY(readText(QStringLiteral("qml/components/AppMark.qml"))
                    .contains(QStringLiteral("readonly property color brandTile: \"#0079A8\"")));
        QVERIFY(readText(QStringLiteral("assets/icon.svg")).contains(QStringLiteral("fill=\"#0079A8\"")));
        QVERIFY(readText(QStringLiteral("tools/make-icon.py")).contains(QStringLiteral("TILE = \"#0079A8\"")));
    }

    // A yellow cover (OKLCH hue 70 to 125) keeps 70% of its chroma on a dark
    // theme, every other hue keeps all of it, and a light theme keeps it all.
    void yellowCoversKeepSeventyPercentOnDark_data() {
        QTest::addColumn<double>("hue");
        QTest::addColumn<bool>("calmed");
        QTest::newRow("hue 64") << 64.0 << false;
        QTest::newRow("hue 73") << 73.0 << true;
        QTest::newRow("hue 90") << 90.0 << true;
        QTest::newRow("hue 105") << 105.0 << true;
        QTest::newRow("hue 122") << 122.0 << true;
        QTest::newRow("hue 131") << 131.0 << false;
        QTest::newRow("hue 200") << 200.0 << false;
    }
    void yellowCoversKeepSeventyPercentOnDark() {
        QFETCH(double, hue);
        QFETCH(bool, calmed);
        const QColor in = fromOkLch(0.8, 0.09, hue);
        QVERIFY2(std::abs(okHue(in) - hue) < 1.5, "the probe colour missed its hue");
        const QColor calm = coverart::calmYellow(in);
        if (calmed) {
            const double kept = okChroma(calm) / okChroma(in);
            QVERIFY2(std::abs(kept - 0.7) <= 0.02,
                     qPrintable(QStringLiteral("kept %1 of its chroma").arg(kept, 0, 'f', 3)));
        } else {
            QCOMPARE(calm, in);
        }
        for (const char *t : {"sea", "pine", "rust"})
            QCOMPARE(coverart::bandTint(in, token(t, "bg"), token(t, "surfaceHigh")),
                     coverart::clampToBand(calm, token(t, "bg"), token(t, "surfaceHigh")));
        for (const char *t : {"sky", "sand", "clay"})
            QCOMPARE(coverart::bandTint(in, token(t, "bg"), token(t, "surfaceHigh")),
                     coverart::clampToBand(in, token(t, "bg"), token(t, "surfaceHigh")));
    }

    // ── sizes ────────────────────────────────────────────────────────────

    // One radius per role; popups and dialogs at 14.
    void radiusTable() {
        const QVariantMap r = theme::radii();
        QCOMPARE(r.value("chip").toInt(), 999);
        QCOMPARE(r.value("field").toInt(), 14);
        QCOMPARE(r.value("row").toInt(), 7);
        QCOMPARE(r.value("button").toInt(), 8);
        QCOMPARE(r.value("art").toInt(), 5);
        QCOMPARE(r.value("card").toInt(), 11);
        QCOMPARE(r.value("popup").toInt(), 14);
        QCOMPARE(r.value("badge").toInt(), 4);
        QCOMPARE(r.value("mark").toInt(), 14);
        QCOMPARE(r.size(), 9);
    }

    // The sidebar's filter chips: icons only, a fixed 30px, five in 190px.
    // tst_sidebar checks the drawn pill at every sidebar width.
    void filterChipsAreThirtyWide() {
        const QString text = readText(QStringLiteral("qml/components/LibraryFinder.qml"));
        QVERIFY(QRegularExpression(QStringLiteral("readonly property int chipWidth: 30\\b"))
                    .match(text).hasMatch());
        QVERIFY(!text.contains(QStringLiteral("finderChipLabel")));
        QCOMPARE(Prefs::minSidebarWidth, 190);
    }

    void cardsAreAFixed160() {
        QVERIFY(readText(QStringLiteral("qml/components/HorizontalSection.qml"))
                    .contains(QStringLiteral("readonly property int  cardSize: 160")));
    }

    // ── defaults and timings ─────────────────────────────────────────────

    void freshInstallDefaults() {
        QSettings().clear();
        QSettings().sync();
        Prefs p;
        QCOMPARE(p.theme(), QStringLiteral("sea"));
        QVERIFY(p.oledBlack());
        QVERIFY(p.tintedGreys());
        QVERIFY(!p.autoplay());
        QVERIFY(p.normalizeLoudness());
        QVERIFY(!p.crossfade());
        QVERIFY(!p.trackNotifications());
        QVERIFY(p.lyricsLrclib());
        QVERIFY(!p.lyricsOtherSites());
        QVERIFY(p.lyricsAutoSync());
        QVERIFY(!p.spectrumBars());
        QVERIFY(p.coverGradient());
    }

    void timingsAndCaps() {
        QCOMPARE(UpdateCheck::checkIntervalHours, 24);
        QCOMPARE(Downloader::kCollectionSpacingMs, 20000);
        QCOMPARE(ScrobbleSink::kMaxQueued, 10000);
        QCOMPARE(kRecentSearchCap, 8);
        QVERIFY(readText(QStringLiteral("src/player/Player.h"))
                    .contains(QStringLiteral("kPositionSaveMs = 30000")));
        QVERIFY(readText(QStringLiteral("qml/Main.qml"))
                    .contains(QStringLiteral("readonly property int maxKeptPages: 5")));
    }
};

QTEST_GUILESS_MAIN(TestOwnerPicks)
#include "tst_owner_picks.moc"
