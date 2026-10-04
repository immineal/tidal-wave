#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

#include <functional>

#include "api/Models.h"

// Items the user pinned above the sidebar library, persisted per Tidal account.
// A pin is {kind, id, title, subtitle, imageUrl}; kind is one of
// "album" | "playlist" | "artist" | "mix". Order is user-defined (drag).
//
// The list goes into QSettings as a JSON array under a per-account key, so
// signing into a second account swaps the whole block rather than merging it,
// and a value written by some other build can be rejected outright instead of
// being half-read into the sidebar.
class PinStore : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the pins context property")
    Q_PROPERTY(QVariantList items READ items NOTIFY changed)
public:
    explicit PinStore(QObject *parent = nullptr);

    // Pins are stored under the signed-in account, so they follow the user.
    void setUserId(qint64 uid);
    qint64 userId() const { return m_userId; }

    // Where the one-shot default pins find something to point at. Pinning is
    // the one feature in the sidebar with nothing on screen to announce it: the
    // only way to find it is to guess that a library row has a context menu. So
    // an account that has never had a pin is given the two personalised mixes -
    // Daily Discovery and New Arrivals, both destinations worth having there in
    // their own right - and from then on the block, and the fact that rows go
    // into it, are simply visible. It used to be Daily Discovery alone, because
    // New Arrivals could not be opened at all when this was written (39b1465).
    //
    // They cannot be written down, because a mix id is minted per account, so
    // the mix list has to be fetched first. Application hands in the client's
    // fetch; a test hands in a canned list and the store never goes near a
    // network. Set this before setUserId(), which is what starts the one shot.
    using MixesHandler = std::function<void(QList<Tidal::Mix>, QString)>;
    using MixSource    = std::function<void(MixesHandler)>;
    void setMixSource(MixSource src) { m_mixSource = std::move(src); }

    // Whether this account has already had its one shot, however it turned out.
    // The sidebar does not read this; it is here so a test can state the rule.
    bool wasSeeded() const;

    QVariantList items() const;

    Q_INVOKABLE bool isPinned(const QString &kind, const QString &id) const;
    Q_INVOKABLE void pin(const QString &kind, const QString &id, const QString &title,
                         const QString &subtitle, const QString &imageUrl);
    Q_INVOKABLE void unpin(const QString &kind, const QString &id);
    Q_INVOKABLE void toggle(const QString &kind, const QString &id, const QString &title,
                            const QString &subtitle, const QString &imageUrl);
    Q_INVOKABLE void move(int from, int to);

    // Position in the pinned block, or -1. LibraryIndex reads this to order
    // the pinned rows and to keep them out of the list below (P5).
    //
    // Q_INVOKABLE because SideBar.qml's endPinDrag() calls it to turn the two
    // row indices the gesture was made in into PinStore indices before asking
    // for the move. It was not invokable for three rounds of "the pins still do
    // not move": QML got `undefined` for both, `undefined === undefined` passed
    // the `fromPin === toPin` guard, and the function returned before move().
    // The indicator was always right; the commit never happened. No warning is
    // printed anywhere a user would see.
    //
    // It survived because tests/TestStubs.h declares its own indexOf
    // Q_INVOKABLE, so every QML test drove a stub that was *more* capable than
    // the real class. tests/tst_qml_cpp_calls.cpp now compares what qml/ calls
    // against these meta-objects, so the stub cannot cover for the real type
    // again.
    Q_INVOKABLE int indexOf(const QString &kind, const QString &id) const;

    // The four things that can be pinned. Anything else is dropped on the way
    // in and on the way out of storage, so neither a stale settings file nor a
    // mistyped QML call can put a row in the block that has no type icon.
    static bool isValidKind(const QString &kind);

signals:
    void changed();

private:
    void load();
    void save() const;

    // The one shot, run from setUserId(). Pins both personalised mixes.
    void seedDefaultPin();
    void markSeeded() const;

    qint64       m_userId = 0;
    QVariantList m_items;
    MixSource    m_mixSource;
};
