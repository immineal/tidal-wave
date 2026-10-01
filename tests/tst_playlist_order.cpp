// Playlists are ordered by how recently the user last had anything to do with
// them, which is more than "last played".
//
// The old key was the locally stored play time alone, sorted descending and
// stable, so every playlist the user had never played kept whatever order the
// API happened to return. A playlist created a minute ago therefore sat behind
// every playlist the user had ever played — the reported bug. The key is now
// max(local last-played time, Playlist::addedAt), where addedAt is when this
// user acquired the playlist, so creating one, saving someone else's and playing
// an old one all move it to the front.
//
// Two halves to pin: the ordering itself, and the parsing that feeds it addedAt.
// The ordering lives in sortPlaylistsByRecency() rather than in
// TidalBridge::sortPlaylists() precisely so it can be exercised here without a
// Tidal session or QSettings. For the parsing, a playlist the user merely saved
// arrives inside a favourites row whose "created" is when they saved it, while
// the playlist's own "created" is the original author's and may be years old;
// taking the wrong one of those two would sort a just-saved playlist as though
// it were ancient.

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QVariantMap>

#include "api/Models.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"

using namespace Tidal;

namespace {

constexpr qint64 oneDay = 24LL * 60 * 60 * 1000;

Playlist made(const QString &uuid, qint64 addedAt = 0) {
    Playlist p;
    p.uuid  = uuid;
    p.title = uuid;
    p.addedAt = addedAt;
    return p;
}

QStringList uuidsOf(const QList<Playlist> &playlists) {
    QStringList uuids;
    for (const Playlist &p : playlists) uuids << p.uuid;
    return uuids;
}

QJsonObject json(const char *text) {
    QJsonParseError err{};
    const QJsonObject o = QJsonDocument::fromJson(QByteArray(text), &err).object();
    Q_ASSERT(err.error == QJsonParseError::NoError);
    return o;
}

// Computed with QDateTime straight from the string, so the expectations below do
// not lean on the helper they are checking.
qint64 instant(const char *iso) {
    return QDateTime::fromString(QString::fromUtf8(iso), Qt::ISODate).toMSecsSinceEpoch();
}

} // namespace

class TestPlaylistOrder : public QObject {
    Q_OBJECT

private:
    qint64 m_now = 0;

private slots:
    void initTestCase() {
        m_now = QDateTime::currentMSecsSinceEpoch();
    }

    // ── the ordering ─────────────────────────────────────────────────────

    // The behaviour that already worked, and still has to.
    void playedBeatsUnplayed() {
        QList<Playlist> playlists { made("never"), made("played") };
        QVariantMap playtimes;
        playtimes[QStringLiteral("played")] = m_now - oneDay;

        sortPlaylistsByRecency(playlists, playtimes);
        QCOMPARE(uuidsOf(playlists), QStringList({ "played", "never" }));
    }

    // The reported bug. A playlist created today has never been played, so under
    // the old play-time-only key it lost to anything ever played; under
    // max(lastPlayed, addedAt) its addedAt is today and it wins.
    void addedTodayBeatsPlayedLastWeek() {
        QList<Playlist> playlists { made("playedLastWeek"), made("createdToday", m_now) };
        QVariantMap playtimes;
        playtimes[QStringLiteral("playedLastWeek")] = m_now - 7 * oneDay;

        sortPlaylistsByRecency(playlists, playtimes);
        QCOMPARE(uuidsOf(playlists), QStringList({ "createdToday", "playedLastWeek" }));
    }

    // The other direction: the newest playlist is not stuck at the front. Play an
    // old one and it comes back, because the play time is the larger half of its
    // key.
    void playingAnOldPlaylistMovesItToTheFront() {
        QList<Playlist> playlists { made("createdToday", m_now),
                                    made("ancient", m_now - 900 * oneDay) };
        QVariantMap playtimes;
        playtimes[QStringLiteral("ancient")] = m_now + 1000;  // just played

        sortPlaylistsByRecency(playlists, playtimes);
        QCOMPARE(uuidsOf(playlists), QStringList({ "ancient", "createdToday" }));
    }

    // Equal keys must not be reordered: the API's order is the tiebreak, which is
    // what std::stable_sort buys. A comparator that answered true for equal keys
    // would also be an invalid strict weak ordering.
    void equalKeysKeepInputOrder() {
        const qint64 same = m_now - 3 * oneDay;
        QList<Playlist> playlists { made("first", same), made("second", same),
                                    made("third", same) };
        QVariantMap playtimes;
        // Reached by the other half of the key too, not just by addedAt.
        playtimes[QStringLiteral("third")] = same;

        sortPlaylistsByRecency(playlists, playtimes);
        QCOMPARE(uuidsOf(playlists), QStringList({ "first", "second", "third" }));
    }

    // A playlist with no timestamp at all sorts last and, among its own kind,
    // keeps API order. This is every playlist on an account that has just logged
    // in on a fresh install.
    void everythingZeroKeepsInputOrder() {
        QList<Playlist> playlists { made("a"), made("b"), made("c"), made("d") };

        sortPlaylistsByRecency(playlists, QVariantMap());
        QCOMPARE(uuidsOf(playlists), QStringList({ "a", "b", "c", "d" }));
    }

    void datelessPlaylistsSortLast() {
        QList<Playlist> playlists { made("noDate"), made("dated", m_now - oneDay) };

        sortPlaylistsByRecency(playlists, QVariantMap());
        QCOMPARE(uuidsOf(playlists), QStringList({ "dated", "noDate" }));
    }

    // ── parsing addedAt ──────────────────────────────────────────────────

    // A playlist handed over on its own — the create-playlist response, or a
    // row from users/{id}/playlists — carries its own creation date, and that is
    // the date the user made it.
    void plainPlaylistUsesItsOwnCreated() {
        const Playlist p = Playlist::fromJson(json(R"({
            "uuid": "own-date",
            "title": "Mine",
            "created": "2024-05-01T10:00:00.000+0000",
            "lastUpdated": "2026-09-30T23:59:59.000+0000"
        })"));

        QCOMPARE(p.uuid, QStringLiteral("own-date"));
        QCOMPARE(p.addedAt, instant("2024-05-01T10:00:00.000+0000"));
        // Not lastUpdated: adding a track to a playlist must not reorder the
        // home row.
        QVERIFY(p.addedAt != instant("2026-09-30T23:59:59.000+0000"));
    }

    // The favourites row's "created" is when this user saved the playlist. The
    // item's own is the original author's, years earlier here.
    void favouritesWrapperCreatedWinsOverTheItems() {
        const QJsonObject row = json(R"({
            "created": "2026-09-28T08:30:00.000+0000",
            "item": {
                "uuid": "saved-from-someone-else",
                "title": "Theirs",
                "created": "2015-02-11T12:00:00.000+0000"
            }
        })");

        const Playlist p = Playlist::fromJson(row["item"].toObject(), row);
        QCOMPARE(p.addedAt, instant("2026-09-28T08:30:00.000+0000"));
    }

    // The wrapper only wins where it has a date; a row without one must still
    // fall back to the playlist's own rather than reporting 0.
    void wrapperWithoutCreatedFallsBackToTheItem() {
        const QJsonObject row = json(R"({
            "type": "USER_CREATED",
            "item": { "uuid": "no-wrapper-date", "created": "2020-01-02T03:04:05.000+0000" }
        })");

        const Playlist p = Playlist::fromJson(row["item"].toObject(), row);
        QCOMPARE(p.addedAt, instant("2020-01-02T03:04:05.000+0000"));
    }

    // An unparseable or missing date has to land on 0 — an invalid QDateTime's
    // toMSecsSinceEpoch() is undefined, and letting it through would sort the
    // playlist on garbage.
    void unparseableOrMissingCreatedIsZero() {
        QCOMPARE(Playlist::fromJson(json(R"({"uuid":"x","created":"last Tuesday"})")).addedAt, 0LL);
        QCOMPARE(Playlist::fromJson(json(R"({"uuid":"x"})")).addedAt, 0LL);
        QCOMPARE(Playlist::fromJson(json(R"({"uuid":"x","created":""})")).addedAt, 0LL);
    }

    // The plumbing, not just the semantics: the wrapper has to survive
    // TidalClient's unwrapping and reach fromJson. It used to be unwrapped and
    // thrown away, which is how a saved playlist got the author's date.
    void parsePlaylistsKeepsTheWrapperDate() {
        const QList<Playlist> parsed = TidalClient::parsePlaylists(json(R"({
            "items": [
                { "created": "2026-09-28T08:30:00.000+0000",
                  "item": { "uuid": "saved", "created": "2015-02-11T12:00:00.000+0000" } },
                { "created": "2026-09-20T08:30:00.000+0000",
                  "playlist": { "uuid": "favourited", "created": "2016-03-04T05:06:07.000+0000" } },
                { "uuid": "unwrapped", "created": "2024-05-01T10:00:00.000+0000" }
            ]
        })"));

        QCOMPARE(parsed.size(), 3);
        QCOMPARE(parsed[0].addedAt, instant("2026-09-28T08:30:00.000+0000"));
        QCOMPARE(parsed[1].addedAt, instant("2026-09-20T08:30:00.000+0000"));
        QCOMPARE(parsed[2].addedAt, instant("2024-05-01T10:00:00.000+0000"));
    }
};

QTEST_GUILESS_MAIN(TestPlaylistOrder)
#include "tst_playlist_order.moc"
