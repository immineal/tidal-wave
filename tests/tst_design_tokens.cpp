// SPDX-License-Identifier: GPL-3.0-or-later

// The design tokens in qml/Theme.qml are the only source of font sizes,
// corner radii, spacing, animation durations, icon strokes and tool tip
// delays. This reads qml/ as text and fails on a literal where a token
// belongs, naming the file and line, so a new one cannot slip in.

#include <functional>

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QRegularExpression>
#include <QTest>

namespace {

struct Hit {
    QString file;
    int line;
    QString text;
};

// A line is exempt when one of the few lines above it holds the marker.
// Each entry says why; keep the list short.
struct Exemption {
    const char *file;     // path under qml/
    const char *marker;   // text on the line itself or up to three lines above
    const char *why;
};

const Exemption kExempt[] = {
    {"components/AppMark.qml", "markCorner",
     "the app icon's corner is part of the drawn mark, at its 64-unit size"},
    {"components/VectorIcon.qml", "_fat.indexOf",
     "dot glyphs draw their dots with the stroke, scaled from the one width"},
    {"components/VectorIcon.qml", "modelData.ms",
     "the playing bars keep a rhythm table of their own, so they never beat in step"},
};

// Comments and string contents out, so neither can match. Strings become
// empty quotes; a `//` inside one is not a comment.
QString codeOf(const QString &line) {
    QString out;
    QChar quote;
    for (int i = 0; i < line.size(); ++i) {
        const QChar c = line.at(i);
        if (!quote.isNull()) {
            if (c == QLatin1Char('\\')) { ++i; continue; }
            if (c == quote) { quote = QChar(); out += c; }
            continue;
        }
        if (c == QLatin1Char('"') || c == QLatin1Char('\'')) { quote = c; out += c; continue; }
        if (c == QLatin1Char('/') && i + 1 < line.size() && line.at(i + 1) == QLatin1Char('/'))
            break;
        out += c;
    }
    return out;
}

// The right-hand side of `name: ...` on this line, up to the next `;` or `}`.
QStringList valuesOf(const QString &code, const QRegularExpression &prop) {
    QStringList out;
    auto it = prop.globalMatch(code);
    while (it.hasNext()) {
        const auto m = it.next();
        QString rhs = code.mid(m.capturedEnd());
        int depth = 0, end = rhs.size();
        for (int i = 0; i < rhs.size(); ++i) {
            const QChar c = rhs.at(i);
            if (c == QLatin1Char('(') || c == QLatin1Char('[')) ++depth;
            else if (c == QLatin1Char(')') || c == QLatin1Char(']')) --depth;
            else if (depth <= 0 && (c == QLatin1Char(';') || c == QLatin1Char('}'))) { end = i; break; }
        }
        out << rhs.left(end).trimmed();
    }
    return out;
}

// Numeric literals in an expression, other than the ones every rule allows.
bool hasLiteral(QString rhs, bool allowHalving, bool allowFactor) {
    // Identifiers can hold digits (space4, motionFast); drop them first.
    rhs.replace(QRegularExpression(QStringLiteral("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*")),
                QStringLiteral("x"));
    if (allowHalving)
        rhs.replace(QRegularExpression(QStringLiteral("/\\s*2(?![0-9.])")), QString());
    if (allowFactor)
        rhs.replace(QRegularExpression(QStringLiteral("x\\s*\\*\\s*[0-9]+(?![0-9.])")), QStringLiteral("x"));
    // Zero is no size at all, and a comparison with it says nothing either.
    rhs.replace(QRegularExpression(QStringLiteral("(?<![0-9.])0(\\.0+)?(?![0-9.])")), QString());
    return rhs.contains(QRegularExpression(QStringLiteral("[0-9]")));
}

// The tree to read. The environment can point at another checkout, which is
// how this test is shown to fail on code from before the tokens.
QString qmlDir() {
    return qEnvironmentVariable("TIDALWAVE_QML_DIR", QStringLiteral(TIDALWAVE_QML_DIR));
}

} // namespace

class TestDesignTokens : public QObject {
    Q_OBJECT

    QList<Hit> scan(const std::function<bool(const QString &code)> &bad) const {
        QList<Hit> hits;
        QDirIterator it(qmlDir(), {QStringLiteral("*.qml")},
                        QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            const QString rel = QDir(qmlDir()).relativeFilePath(path);
            if (rel == QLatin1String("Theme.qml")) continue;   // where the values live
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly)) continue;
            const QStringList lines = QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
            for (int i = 0; i < lines.size(); ++i) {
                const QString code = codeOf(lines.at(i));
                if (!bad(code)) continue;
                bool exempt = false;
                for (const Exemption &e : kExempt) {
                    if (rel != QLatin1String(e.file)) continue;
                    for (int k = qMax(0, i - 3); k <= i && !exempt; ++k)
                        exempt = lines.at(k).contains(QLatin1String(e.marker));
                }
                if (!exempt) hits.append({rel, i + 1, lines.at(i).trimmed()});
            }
        }
        return hits;
    }

    // Every line under qml/, strings and all, with no exemptions.
    QList<Hit> scanAll(const std::function<bool(const QString &line)> &match) const {
        QList<Hit> hits;
        QDirIterator it(qmlDir(), {QStringLiteral("*.qml")},
                        QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly)) continue;
            const QStringList lines = QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
            for (int i = 0; i < lines.size(); ++i)
                if (match(lines.at(i)))
                    hits.append({QDir(qmlDir()).relativeFilePath(path), i + 1, lines.at(i).trimmed()});
        }
        return hits;
    }

    static QByteArray describe(const QList<Hit> &hits, const char *token) {
        return report(hits, QStringLiteral("use a literal where qml/Theme.qml has %1")
                                .arg(QLatin1String(token)));
    }

    static QByteArray report(const QList<Hit> &hits, const QString &what) {
        QString s = QStringLiteral("%1 line(s) %2:").arg(hits.size()).arg(what);
        for (const Hit &h : hits)
            s += QStringLiteral("\n  qml/%1:%2  %3").arg(h.file).arg(h.line).arg(h.text);
        return s.toUtf8();
    }

private slots:
    void theSourcesAreThere() {
        QVERIFY2(QFile::exists(qmlDir() + QStringLiteral("/Theme.qml")),
                 "qml/ was not found, so every check below would pass on nothing");
    }

    void fontSizesAreTokens() {
        static const QRegularExpression prop(QStringLiteral("\\b(pixelSize|fontPixelSize)\\s*:"));
        const auto hits = scan([](const QString &code) {
            for (const QString &v : valuesOf(code, prop))
                if (hasLiteral(v, false, false)) return true;
            return false;
        });
        QVERIFY2(hits.isEmpty(), describe(hits, "fontDisplay … fontMicro").constData());
    }

    void radiiAreTokens() {
        static const QRegularExpression prop(QStringLiteral("(?<![\\w.])radius\\s*:"));
        const auto hits = scan([](const QString &code) {
            // A circle is half its own side, whatever the side is.
            for (const QString &v : valuesOf(code, prop))
                if (hasLiteral(v, true, false)) return true;
            return false;
        });
        QVERIFY2(hits.isEmpty(), describe(hits, "radiusSmall … radiusFull").constData());
    }

    void spacingIsOnTheScale() {
        static const QRegularExpression prop(QStringLiteral(
            "(?<![\\w])((anchors|Layout)\\.)?(spacing|rowSpacing|columnSpacing|margins|"
            "leftMargin|rightMargin|topMargin|bottomMargin|padding|leftPadding|rightPadding|"
            "topPadding|bottomPadding|horizontalPadding|verticalPadding)\\s*:"));
        // A bare Item whose only job is a gap: sizes and nothing else, where
        // a 1 on the other axis only keeps a Column or a Row from dropping it.
        static const QRegularExpression spacer(QStringLiteral("\\bItem\\s*\\{([^{}]*)\\}"));
        static const QRegularExpression size(QStringLiteral(
            "^(Layout\\.preferred)?([Hh]eight|[Ww]idth)\\s*:\\s*(.+)$"));
        const auto isSpacerWithLiteral = [](const QString &code) {
            const auto m = spacer.match(code);
            if (!m.hasMatch()) return false;
            bool literal = false;
            for (QString part : m.captured(1).split(QLatin1Char(';'), Qt::SkipEmptyParts)) {
                part = part.trimmed();
                if (part.isEmpty()) continue;
                const auto s = size.match(part);
                if (!s.hasMatch()) return false;            // more than a gap
                if (part == QLatin1String("width: 1") || part == QLatin1String("height: 1")) continue;
                if (hasLiteral(s.captured(3), false, false)) literal = true;
            }
            return literal;
        };
        const auto hits = scan([&](const QString &code) {
            if (code.contains(QRegularExpression(QStringLiteral("^\\s*(readonly\\s+)?property\\s"))))
                return false;
            if (isSpacerWithLiteral(code)) return true;
            for (const QString &v : valuesOf(code, prop))
                if (hasLiteral(v, false, false)) return true;
            return false;
        });
        QVERIFY2(hits.isEmpty(), describe(hits, "spaceHalf … space16").constData());
    }

    void durationsAreTokens() {
        static const QRegularExpression prop(QStringLiteral("(?<![\\w.])duration\\s*:"));
        const auto hits = scan([](const QString &code) {
            // A spinner's turn is a whole number of slow beats.
            for (const QString &v : valuesOf(code, prop))
                if (hasLiteral(v, false, true)) return true;
            return false;
        });
        QVERIFY2(hits.isEmpty(), describe(hits, "motionFast, motionMedium, motionSlow").constData());
    }

    void iconsShareOneStroke() {
        static const QRegularExpression prop(QStringLiteral("(?<![\\w.])strokeWidth\\s*:"));
        const auto hits = scan([](const QString &code) {
            for (const QString &v : valuesOf(code, prop))
                if (hasLiteral(v, false, false)) return true;
            return false;
        });
        QVERIFY2(hits.isEmpty(), describe(hits, "iconStroke").constData());
    }

    void toolTipsShareOneDelay() {
        static const QRegularExpression prop(QStringLiteral("ToolTip\\.delay\\s*:"));
        const auto hits = scan([](const QString &code) {
            for (const QString &v : valuesOf(code, prop))
                if (v != QLatin1String("Theme.tooltipDelay")) return true;
            return false;
        });
        QVERIFY2(hits.isEmpty(), describe(hits, "tooltipDelay").constData());
    }

    // Every tip is the style's ToolTip (qml/style). A tip that dresses itself,
    // or a file that imports a stock style by name, gets the plain system look
    // back the next time the shared one changes.
    void toolTipsWearTheStyle() {
        static const QRegularExpression stock(QStringLiteral(
            "^\\s*import\\s+QtQuick\\.Controls\\.(Basic|Fusion|Material|Universal|Imagine|"
            "FluentWinUI3|Windows|macOS|iOS)\\b"));
        static const QRegularExpression opening(QStringLiteral("(?<![\\w.])ToolTip\\s*\\{"));
        static const QRegularExpression dressing(QStringLiteral("\\b(background|contentItem)\\s*:"));
        QList<Hit> hits;
        QDirIterator it(qmlDir(), {QStringLiteral("*.qml")},
                        QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            const QString rel = QDir(qmlDir()).relativeFilePath(path);
            if (rel.startsWith(QLatin1String("style/"))) continue;   // where the look lives
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly)) continue;
            const QStringList lines = QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
            int depth = 0, tipDepth = -1, tipLine = 0;
            for (int i = 0; i < lines.size(); ++i) {
                const QString code = codeOf(lines.at(i));
                if (stock.match(code).hasMatch()) hits.append({rel, i + 1, lines.at(i).trimmed()});
                const auto open = opening.match(code);
                for (int c = 0; c < code.size(); ++c) {
                    if (tipDepth < 0 && open.hasMatch() && c == open.capturedEnd() - 1) {
                        tipDepth = depth;
                        tipLine = i + 1;
                    }
                    if (code.at(c) == QLatin1Char('{')) ++depth;
                    else if (code.at(c) == QLatin1Char('}') && --depth == tipDepth) tipDepth = -1;
                }
                if (tipDepth >= 0 && dressing.match(code).hasMatch())
                    hits.append({rel, i + 1, QStringLiteral("(ToolTip from line %1) ").arg(tipLine)
                                             + lines.at(i).trimmed()});
            }
        }
        QVERIFY2(QFile::exists(qmlDir() + QStringLiteral("/style/ToolTip.qml")),
                 "qml/style/ToolTip.qml is gone, so no tip wears the app's look");
        QVERIFY2(hits.isEmpty(),
                 report(hits, QStringLiteral("dress a tip of their own or import a stock style, "
                                             "where qml/style/ToolTip.qml is the one look"))
                     .constData());
    }

    // The selected fill is stronger than the hover wash. A hover drawn in it
    // makes a row look chosen.
    void hoverIsNeverTheSelectedFill() {
        const auto hits = scan([](const QString &code) {
            return code.contains(QLatin1String("Theme.surfaceHov"))
                || (code.contains(QLatin1String("Theme.selectedFill"))
                    && code.contains(QRegularExpression(QStringLiteral("[Hh]ov(ered)?\\b|containsMouse"))));
        });
        QVERIFY2(hits.isEmpty(), describe(hits, "hoverFill for a hover").constData());
    }

    // One version of each control, in qml/components. A page that grows its
    // own copy drifts from the shared one in size, hover and focus.
    void controlsAreDefinedOnce() {
        static const QRegularExpression local(QStringLiteral(
            "^\\s*component\\s+(IconButton|CtrlBtn|ChromeButton|Toggle|PanelButton|"
            "ActionButton|SearchField|TabStrip)\\b"));
        const auto hits = scan([](const QString &code) { return local.match(code).hasMatch(); });
        QVERIFY2(hits.isEmpty(),
                 report(hits, QStringLiteral("build their own copy of a control in qml/components"))
                     .constData());
    }

    // The quality badge is one component, so the bar and Now Playing cannot
    // drift apart in size, type or colour again.
    void qualityBadgeIsOneComponent() {
        const auto all = scanAll([](const QString &line) {
            return line.contains(QLatin1String("objectName: \"qualityBadge\""));
        });
        QList<Hit> hits;
        for (const Hit &h : all)
            if (h.file != QLatin1String("components/QualityBadge.qml")) hits.append(h);
        QVERIFY2(!all.isEmpty(), "no quality badge was found under qml/");
        QVERIFY2(hits.isEmpty(),
                 report(hits, QStringLiteral("draw a quality badge of their own instead of QualityBadge"))
                     .constData());
    }

    // Lengths are formatted in Theme.clock() and Theme.lengthText() only.
    void lengthsHaveOneFormatter() {
        const auto hits = scan([](const QString &code) {
            return code.contains(QRegularExpression(QStringLiteral("%\\s*3600\\b")));
        });
        QVERIFY2(hits.isEmpty(),
                 report(hits, QStringLiteral("format a length that Theme.clock() or Theme.lengthText() should"))
                     .constData());
    }

    // No text in capitals and no spaced letters: every label is set in
    // sentence case at the font's own spacing, overlines included.
    void noCapitalsAndNoLetterSpacing() {
        static const QRegularExpression caps(QStringLiteral("\\bcapitalization\\s*:"));
        static const QRegularExpression spaced(QStringLiteral(
            "\\bletterSpacing\\s*:\\s*(?!0(\\.0+)?\\s*($|[;}]))"));
        QList<Hit> hits;
        QDirIterator it(qmlDir(), {QStringLiteral("*.qml")},
                        QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly)) continue;
            const QStringList lines = QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
            for (int i = 0; i < lines.size(); ++i) {
                const QString code = codeOf(lines.at(i));
                if (caps.match(code).hasMatch() || spaced.match(code).hasMatch())
                    hits.append({QDir(qmlDir()).relativeFilePath(path), i + 1, lines.at(i).trimmed()});
            }
        }
        QVERIFY2(hits.isEmpty(),
                 report(hits, QStringLiteral("set text in capitals or space its letters"))
                     .constData());
    }

    // The checks above must see a literal when there is one.
    void theCheckerSeesLiterals() {
        QVERIFY(hasLiteral(QStringLiteral("13"), false, false));
        QVERIFY(hasLiteral(QStringLiteral("hov.hovered ? 12 : Theme.space2"), false, false));
        QVERIFY(!hasLiteral(QStringLiteral("Theme.space4"), false, false));
        QVERIFY(!hasLiteral(QStringLiteral("index === 0 ? Theme.space1 : 0"), false, false));
        QVERIFY(!hasLiteral(QStringLiteral("width / 2"), true, false));
        QVERIFY(hasLiteral(QStringLiteral("width / 3"), true, false));
        QVERIFY(!hasLiteral(QStringLiteral("Theme.dur(Theme.motionSlow * 2)"), false, true));
        QVERIFY(hasLiteral(QStringLiteral("Theme.dur(170)"), false, true));
        QCOMPARE(codeOf(QStringLiteral("text: \"12 // 3\" // spacing: 4")), QStringLiteral("text: \"\" "));
        QVERIFY(!hasLiteral(QStringLiteral("Theme.dur(Math.round(bar.modelData.ms))"), false, true));
    }
};

QTEST_GUILESS_MAIN(TestDesignTokens)
#include "tst_design_tokens.moc"
