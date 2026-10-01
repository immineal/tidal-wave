#include "ui/Shortcuts.h"

#include <QKeySequence>

namespace {

struct Binding { const char *id; const char *sequence; };

// The table. Order is the order Settings lists them in.
//
// Two rules a new entry has to keep, both of them learned the hard way on a
// first run under macOS, where Qt maps "Ctrl" onto the Command key:
//
//   * Nothing may use a sequence the system takes before the app sees it. The
//     queue toggle used to be Ctrl+Q, which on macOS is Command-Q, which is
//     Quit: pressing it on the Mac did not open the queue, it ended the
//     process. Ctrl+Q is a poor binding on Linux too, where it is the
//     conventional quit. Ctrl+W (Close Window), Ctrl+H (Hide),
//     Ctrl+Shift+Q (Log Out) are the others in that class, and
//     tst_shortcuts.cpp refuses all four.
//   * The sequence has to be written the way QKeySequence's portable format
//     spells it, because that is what parses it back. A typo like "Ctrl+Shft+J"
//     is not a compile error and not a runtime warning; it is a shortcut that
//     silently never fires. tst_shortcuts.cpp round-trips every one of these
//     through QKeySequence to catch that.
//
// Two collisions are known and deliberately left alone, because unlike Ctrl+Q
// they cost the user a shortcut rather than their session: on macOS Ctrl+M is
// Command-M (Minimize) and F11 is Mission Control's Show Desktop, so mute and
// fullscreen do not reach the app there. Changing either would move a shortcut
// that is right on Linux, which is where the app actually ships today.
constexpr Binding kBindings[] = {
    // Playback.
    { "playPause",   "Space"       },
    { "next",        "Ctrl+Right"  },
    { "previous",    "Ctrl+Left"   },
    { "seekForward", "Right"       },
    { "seekBack",    "Left"        },
    { "volumeUp",    "Up"          },
    { "volumeDown",  "Down"        },
    { "mute",        "Ctrl+M"      },
    { "shuffle",     "Ctrl+S"      },
    { "repeat",      "Ctrl+R"      },
    // Navigation.
    { "home",        "Ctrl+1"      },
    { "search",      "Ctrl+2"      },
    { "collection",  "Ctrl+3"      },
    { "nowPlaying",  "Ctrl+N"      },
    { "fullScreen",  "F11"         },
    // Ctrl+J, not Ctrl+Q: see the first rule above. J is free on both
    // platforms - macOS claims no Command-J, and no Linux desktop or toolkit
    // binds Ctrl+J either - and it follows the editor convention of a letter
    // near Ctrl+B for "toggle the panel at the side".
    { "queue",       "Ctrl+J"      },
    { "settings",    "Ctrl+,"      },
    { "back",        "Alt+Left"    },
    // "Esc", not "Escape": the table stores sequences exactly as
    // QKeySequence prints them back in portable form, which is what lets
    // tst_shortcuts.cpp round-trip every entry through the parser and catch a
    // typo in a modifier. Qt's canonical spelling of this key is the short one.
    { "escape",      "Esc"         },
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
