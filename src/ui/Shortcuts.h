// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QStringList>

// The one list of keyboard shortcuts, read by Main.qml's Shortcut items and
// by the Settings panel. Sequences are stored in Qt's portable form
// ("Ctrl+Right"); the display form is derived per platform, since Qt maps
// Ctrl to Command on macOS.
class Shortcuts : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    // Default-constructible on purpose: the type holds no state, so QML may
    // build its own instance.
    explicit Shortcuts(QObject *parent = nullptr);

    // Every id in the table, in the order the Settings panel lists them.
    Q_INVOKABLE QStringList ids() const;

    // The portable sequence for an id. Empty for an unknown id: QML's
    // Shortcut ignores an empty sequence, so a mistyped id binds nothing.
    Q_INVOKABLE QString sequence(const QString &id) const;

    // What this platform calls that sequence: "Ctrl+Right" on Linux and
    // Windows, "⌘→" on macOS, with Qt's translations of the key names. The
    // only form that should reach a label.
    Q_INVOKABLE QString display(const QString &id) const;

    // A fixed-pitch family this machine has, for the key badges. "monospace"
    // is not a family on macOS, and a missing name costs startup time.
    Q_INVOKABLE QString monospaceFamily() const;

    // The same conversion for a sequence that is not in the table.
    Q_INVOKABLE QString nativeText(const QString &portableSequence) const;
};
