#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QStringList>

// The one list of keyboard shortcuts the app has.
//
// There used to be two. Main.qml bound each Shortcut to a literal like
// "Ctrl+Q", and the Settings panel printed its own literal "Ctrl+Q" in a
// hand-written table beside it, so the two could drift and nothing would say
// so. Worse, the printed half was simply wrong off Linux: Qt maps "Ctrl" in a
// portable sequence to the Command key on macOS, so a Mac user pressing what
// the panel told them to press was pressing the wrong key, and the panel had no
// way to know. Both halves now read this table, and the panel prints what
// QKeySequence says this platform calls the sequence.
//
// Sequences are stored in Qt's portable form ("Ctrl+Right"), which is what
// QML's Shortcut.sequence wants and what QKeySequence parses. Nothing stores
// the display form; that is derived, per platform, on the way to the screen.
class Shortcuts : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    // Default-constructible on purpose, unlike ThemePalette: this type holds no
    // state and has nothing to wire, so letting QML build its own instance is
    // the whole of what it needs. (The trap ThemePalette documents is the
    // reverse case - Qt checks std::is_default_constructible before it looks
    // for create(), so a singleton that *does* need wiring must not be
    // default-constructible.)
    explicit Shortcuts(QObject *parent = nullptr);

    // Every id in the table, in the order it is declared. The declaration order
    // is the order the Settings panel lists them in, so the two read the same
    // way down the page.
    Q_INVOKABLE QStringList ids() const;

    // The portable sequence for an id, or an empty string for an id that is not
    // in the table. Empty rather than a guess, because QML's Shortcut ignores an
    // empty sequence: a mistyped id disables that one shortcut instead of
    // binding something arbitrary, and tst_shortcuts.cpp fails on it.
    Q_INVOKABLE QString sequence(const QString &id) const;

    // What this platform calls that sequence: "Ctrl+Right" on Linux and
    // Windows, "⌘→" on macOS. This is the only thing that should ever reach a
    // label. It also picks up Qt's own translations of the key names, so a
    // German catalogue prints "Leertaste" rather than "Space" without the app
    // carrying a translation for every key on the keyboard.
    Q_INVOKABLE QString display(const QString &id) const;

    // The same conversion for a sequence that is not in the table, for a label
    // that has to print a key the app does not bind.
    Q_INVOKABLE QString nativeText(const QString &portableSequence) const;
};
