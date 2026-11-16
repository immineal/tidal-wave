// SPDX-License-Identifier: GPL-3.0-or-later

#include <QFontDatabase>
#include "ui/Shortcuts.h"

#include <QKeySequence>

namespace {

struct Binding { const char *id; const char *sequence; };

// In the order Settings lists them. No entry may use a sequence the system
// takes first, except Quit on Ctrl+Q; Qt maps Ctrl to Command on macOS. No bare
// arrow either: those move the focused list or slider. Spell each one in
// QKeySequence's portable form: a typo never fires.
constexpr Binding kBindings[] = {
    // Playback.
    { "playPause",   "Space"       },
    { "next",        "Ctrl+Right"  },
    { "previous",    "Ctrl+Left"   },
    { "seekForward", "Shift+Right" },
    { "seekBack",    "Shift+Left"  },
    { "volumeUp",    "Ctrl+Up"     },
    { "volumeDown",  "Ctrl+Down"   },
    { "mute",        "Ctrl+M"      },
    { "shuffle",     "Ctrl+S"      },
    { "repeat",      "Ctrl+R"      },
    // Navigation.
    { "home",        "Ctrl+1"      },
    { "search",      "Ctrl+2"      },
    { "collection",  "Ctrl+3"      },
    { "nowPlaying",  "Ctrl+4"      },
    { "find",        "Ctrl+F"      },
    { "findAlt",     "Ctrl+L"      },
    { "fullScreen",  "F11"         },
    { "queue",       "Ctrl+J"      },
    { "settings",    "Ctrl+,"      },
    { "back",        "Alt+Left"    },
    // "Esc" is how QKeySequence spells this key in portable form.
    { "escape",      "Esc"         },
    // The app. Ctrl+Z is QKeySequence::Undo here; on macOS, Command+Z.
    { "undo",        "Ctrl+Z"      },
    { "newPlaylist", "Ctrl+N"      },
    { "quit",        "Ctrl+Q"      },
};

} // namespace

Shortcuts::Shortcuts(QObject *parent) : QObject(parent) {
}

QStringList Shortcuts::ids() const {
    QStringList out;
    out.reserve(int(std::size(kBindings)));
    for (const Binding &b : kBindings)
        out << QString::fromLatin1(b.id);
    return out;
}

QString Shortcuts::sequence(const QString &id) const {
    for (const Binding &b : kBindings) {
        if (id == QLatin1String(b.id))
            return QString::fromLatin1(b.sequence);
    }
    return QString();
}

QString Shortcuts::display(const QString &id) const {
    return nativeText(sequence(id));
}

QString Shortcuts::nativeText(const QString &portableSequence) const {
    if (portableSequence.isEmpty())
        return QString();
    return QKeySequence(portableSequence, QKeySequence::PortableText)
        .toString(QKeySequence::NativeText);
}

QString Shortcuts::monospaceFamily() const {
    const QString fixed = QFontDatabase::systemFont(QFontDatabase::FixedFont).family();
    // Only trusted if the database agrees the family exists.
    if (!fixed.isEmpty() && QFontDatabase::hasFamily(fixed))
        return fixed;
    for (const QString &f : { QStringLiteral("DejaVu Sans Mono"),
                              QStringLiteral("Menlo"),
                              QStringLiteral("Consolas"),
                              QStringLiteral("Courier New") }) {
        if (QFontDatabase::hasFamily(f))
            return f;
    }
    // Nothing fixed-pitch here. An empty family means the default font,
    // which is cheaper than naming a family that is missing.
    return QString();
}
