#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

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
    int indexOf(const QString &kind, const QString &id) const;

    // The four things that can be pinned. Anything else is dropped on the way
    // in and on the way out of storage, so neither a stale settings file nor a
    // mistyped QML call can put a row in the block that has no type icon.
    static bool isValidKind(const QString &kind);

signals:
    void changed();

private:
    void load();
    void save() const;

    qint64       m_userId = 0;
    QVariantList m_items;
};
