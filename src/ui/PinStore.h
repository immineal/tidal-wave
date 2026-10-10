// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

#include <functional>

#include "api/Models.h"

// Items the user pinned above the sidebar library, persisted per Tidal account
// as a JSON array in QSettings. A pin is {kind, id, title, subtitle, imageUrl};
// kind is "album" | "playlist" | "artist" | "mix". Order is user-defined.
// The subtitle is a datum Tidal sent, never rendered text; a playlist pin
// carries none. See storableSubtitle() in the .cpp.
class PinStore : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the pins context property")
    Q_PROPERTY(QVariantList items READ items NOTIFY changed)
public:
    explicit PinStore(QObject *parent = nullptr);

    // Loads that account's pins and runs the one-shot default pin.
    void setUserId(qint64 uid);
    qint64 userId() const { return m_userId; }

    // Where the one-shot default pins come from. An account that never had a
    // pin gets its two personalised mixes; mix ids are per account, so the
    // list has to be fetched. Set this before setUserId().
    using MixesHandler = std::function<void(QList<Tidal::Mix>, QString)>;
    using MixSource    = std::function<void(MixesHandler)>;
    void setMixSource(MixSource src) { m_mixSource = std::move(src); }

    // Whether this account has had its one shot, however it turned out.
    bool wasSeeded() const;

    QVariantList items() const;

    Q_INVOKABLE bool isPinned(const QString &kind, const QString &id) const;
    Q_INVOKABLE void pin(const QString &kind, const QString &id, const QString &title,
                         const QString &subtitle, const QString &imageUrl);
    Q_INVOKABLE void unpin(const QString &kind, const QString &id);
    Q_INVOKABLE void toggle(const QString &kind, const QString &id, const QString &title,
                            const QString &subtitle, const QString &imageUrl);
    Q_INVOKABLE void move(int from, int to);

    // Position in the pinned block, or -1. LibraryIndex orders the pinned
    // rows by it. Has to stay Q_INVOKABLE: SideBar.qml calls it for a drag,
    // and a non-invokable method reads as undefined in QML with no warning.
    Q_INVOKABLE int indexOf(const QString &kind, const QString &id) const;

    // The four kinds that can be pinned. Anything else is dropped on the way
    // into and out of storage.
    static bool isValidKind(const QString &kind);

signals:
    void changed();

private:
    void load();
    void save() const;

    // Run from setUserId(). Pins both personalised mixes, once per account.
    void seedDefaultPin();
    void markSeeded() const;

    qint64       m_userId = 0;
    QVariantList m_items;
    MixSource    m_mixSource;
};
