#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

// Items the user pinned above the sidebar library, persisted per Tidal account.
// A pin is {kind, id, title, subtitle, imageUrl}; kind is one of
// "album" | "playlist" | "artist" | "mix". Order is user-defined (drag).
class PinStore : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the pins context property")
    Q_PROPERTY(QVariantList items READ items NOTIFY changed)
public:
    explicit PinStore(QObject *parent = nullptr);

    // Pins are stored under the signed-in account, so they follow the user.
    void setUserId(qint64 uid);

    QVariantList items() const;

    Q_INVOKABLE bool isPinned(const QString &kind, const QString &id) const;
    Q_INVOKABLE void pin(const QString &kind, const QString &id, const QString &title,
                         const QString &subtitle, const QString &imageUrl);
    Q_INVOKABLE void unpin(const QString &kind, const QString &id);
    Q_INVOKABLE void toggle(const QString &kind, const QString &id, const QString &title,
                            const QString &subtitle, const QString &imageUrl);
    Q_INVOKABLE void move(int from, int to);

signals:
    void changed();

private:
    qint64       m_userId = 0;
    QVariantList m_items;
};
