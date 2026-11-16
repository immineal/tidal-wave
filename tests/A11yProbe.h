// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

// What a screen reader is told about a QML item, read the way one reads it:
// through QAccessible::queryAccessibleInterface. Installed as `a11y` in
// tst_qml, so a QML test can assert role, name, actions and value.

#include <QAccessible>
#include <QAccessibleActionInterface>
#include <QAccessibleValueInterface>
#include <QObject>
#include <QQuickItem>
#include <QStringList>
#include <QVariant>

class A11yProbe : public QObject {
    Q_OBJECT

public:
    using QObject::QObject;

    // False for an item a screen reader cannot see at all.
    Q_INVOKABLE bool exposed(QQuickItem *item) const { return iface(item) != nullptr; }

    // A QAccessible::Role, which QML compares with Accessible.Button and kin.
    Q_INVOKABLE int role(QQuickItem *item) const {
        QAccessibleInterface *i = iface(item);
        return i ? int(i->role()) : -1;
    }

    Q_INVOKABLE QString name(QQuickItem *item) const {
        QAccessibleInterface *i = iface(item);
        return i ? i->text(QAccessible::Name) : QString();
    }

    Q_INVOKABLE QString description(QQuickItem *item) const {
        QAccessibleInterface *i = iface(item);
        return i ? i->text(QAccessible::Description) : QString();
    }

    Q_INVOKABLE QStringList actions(QQuickItem *item) const {
        QAccessibleInterface *i = iface(item);
        QAccessibleActionInterface *a = i ? i->actionInterface() : nullptr;
        return a ? a->actionNames() : QStringList();
    }

    // What a reader's "activate" does: the press action, or toggle for a switch.
    Q_INVOKABLE bool press(QQuickItem *item) const {
        return doAction(item, QAccessibleActionInterface::pressAction());
    }
    Q_INVOKABLE bool toggle(QQuickItem *item) const {
        return doAction(item, QAccessibleActionInterface::toggleAction());
    }
    Q_INVOKABLE bool increase(QQuickItem *item) const {
        return doAction(item, QAccessibleActionInterface::increaseAction());
    }
    Q_INVOKABLE bool decrease(QQuickItem *item) const {
        return doAction(item, QAccessibleActionInterface::decreaseAction());
    }

    Q_INVOKABLE bool checkable(QQuickItem *item) const {
        QAccessibleInterface *i = iface(item);
        return i && i->state().checkable;
    }
    Q_INVOKABLE bool checked(QQuickItem *item) const {
        QAccessibleInterface *i = iface(item);
        return i && i->state().checked;
    }
    Q_INVOKABLE bool focusable(QQuickItem *item) const {
        QAccessibleInterface *i = iface(item);
        return i && i->state().focusable;
    }

    // Null for an item that offers no value interface.
    Q_INVOKABLE QVariant value(QQuickItem *item) const {
        QAccessibleInterface *i = iface(item);
        QAccessibleValueInterface *v = i ? i->valueInterface() : nullptr;
        return v ? v->currentValue() : QVariant();
    }

private:
    static QAccessibleInterface *iface(QQuickItem *item) {
        return item ? QAccessible::queryAccessibleInterface(item) : nullptr;
    }

    static bool doAction(QQuickItem *item, const QString &action) {
        QAccessibleInterface *i = iface(item);
        QAccessibleActionInterface *a = i ? i->actionInterface() : nullptr;
        if (!a || !a->actionNames().contains(action))
            return false;
        a->doAction(action);
        return true;
    }
};
