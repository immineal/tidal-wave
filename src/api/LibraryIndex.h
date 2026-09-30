#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>

class TidalClient;
class TidalBridge;
class PinStore;

// The sidebar's model: every playlist, album, artist and mix the user saved, in
// one flat list, plus the local search index over them.
//
// Ordering is pinned first, then most recently played, then A-Z for everything
// never played. "Recently played" is tracked locally for all four kinds; Tidal
// exposes no cross-device play history (users/{id}/history is 404 and
// users/{id}/activity only reports favourites added), so phone plays cannot
// contribute.
class LibraryIndex : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use the library context property")
    Q_PROPERTY(QVariantList entries READ entries NOTIFY entriesChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
public:
    explicit LibraryIndex(TidalClient *client, PinStore *pins, QObject *parent = nullptr);

    QVariantList entries() const;
    bool loading() const;

    void setUserId(qint64 uid);

    // Records a play so the entry floats to the top of the library list.
    Q_INVOKABLE void markPlayed(const QString &kind, const QString &id);

    // Filters the library. `kinds` is an empty list for everything, otherwise a
    // subset of album/playlist/artist/mix/track. Matching an artist also
    // surfaces that artist's saved albums and saved tracks; matching a track
    // also surfaces the saved album it belongs to.
    Q_INVOKABLE QVariantList search(const QString &query, const QStringList &kinds) const;

signals:
    void entriesChanged();
    void loadingChanged();

private:
    TidalClient *m_client = nullptr;
    PinStore    *m_pins   = nullptr;
    qint64       m_userId = 0;
};
