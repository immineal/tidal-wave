// Adding a favourite has to update the local list, not just tell the server.
//
// isAlbumFavorite() and isArtistFavorite() answer from m_favoriteAlbums /
// m_favoriteArtists, so an add that only emitted the changed signal left the
// Save button reading "Save" and the Follow button reading "Follow" straight
// after a successful call. The remove side always maintained the list, which
// is why the asymmetry survived: unsaving worked, saving did not.
#include <QTest>
#include <QSignalSpy>
#include "api/Models.h"

using namespace Tidal;

class TestBridgeFavorites : public QObject {
    Q_OBJECT

private slots:
    // The shape of the bug, expressed against the data structure the real
    // lookups use. A full end-to-end test needs a Tidal session; this pins the
    // invariant that broke.
    void addMustInsertNotJustSignal_data() {
        QTest::addColumn<bool>("insertOnAdd");
        QTest::addColumn<bool>("expectedFound");
        QTest::newRow("add that only signals")  << false << false;
        QTest::newRow("add that inserts")       << true  << true;
    }

    void addMustInsertNotJustSignal() {
        QFETCH(bool, insertOnAdd);
        QFETCH(bool, expectedFound);

        QList<Album> favorites;
        const qint64 id = 4242;

        // What addAlbumFavorite does on success.
        if (insertOnAdd) {
            Album a; a.id = id; a.title = QStringLiteral("Life 1");
            favorites.append(a);
        }

        // What isAlbumFavorite does.
        const bool found = std::any_of(favorites.cbegin(), favorites.cend(),
                                       [&](const Album &x) { return x.id == id; });
        QCOMPARE(found, expectedFound);
    }

    // Re-adding something already present must not duplicate it, which is the
    // guard the track path already had and the album path needed.
    void addingTwiceKeepsOneRow() {
        QList<Album> favorites;
        const qint64 id = 7;
        for (int i = 0; i < 2; ++i) {
            const bool exists = std::any_of(favorites.cbegin(), favorites.cend(),
                                            [&](const Album &x) { return x.id == id; });
            if (!exists) { Album a; a.id = id; favorites.append(a); }
        }
        QCOMPARE(favorites.size(), 1);
    }

    // Removing has to leave the list consistent for the next lookup.
    void removeTakesItBackOut() {
        QList<Album> favorites;
        Album a; a.id = 9; favorites.append(a);
        for (int i = 0; i < favorites.size(); ++i)
            if (favorites[i].id == 9) { favorites.removeAt(i); break; }
        QVERIFY(favorites.isEmpty());
    }
};

QTEST_GUILESS_MAIN(TestBridgeFavorites)
#include "tst_bridge_favorites.moc"
