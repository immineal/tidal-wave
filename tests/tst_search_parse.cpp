// What TidalClient::parseSearch makes of a /v1/search reply: the five lists
// and the server's own best match, `topHit`. The shape is the live API's;
// every id and name is invented. Nothing here touches the network.

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>

#include "api/TidalClient.h"

using namespace Tidal;

namespace {

QJsonObject reply(const char *topHit) {
    const QByteArray body = QByteArray(R"json({
      "artists":   {"limit": 20, "offset": 0, "totalNumberOfItems": 1,
                    "items": [{"id": 7001, "name": "Beispielkapelle"}]},
      "albums":    {"limit": 20, "offset": 0, "totalNumberOfItems": 0, "items": []},
      "tracks":    {"limit": 20, "offset": 0, "totalNumberOfItems": 0, "items": []},
      "playlists": {"limit": 20, "offset": 0, "totalNumberOfItems": 0, "items": []},
      "topHit": )json") + topHit + "}";
    return QJsonDocument::fromJson(body).object();
}

} // namespace

class TestSearchParse : public QObject {
    Q_OBJECT

private slots:
    void anArtistTopHitIsKept() {
        const SearchResults r = TidalClient::parseSearch(reply(
            R"({"type": "ARTISTS", "value": {"id": 7001, "name": "Beispielkapelle"}})"));
        QCOMPARE(r.topHitKind, QStringLiteral("artist"));
        QCOMPARE(r.topArtist.id, 7001LL);
        QCOMPARE(r.topArtist.name, QStringLiteral("Beispielkapelle"));
        QCOMPARE(r.artists.size(), 1);
    }

    void anAlbumTopHitIsKept() {
        const SearchResults r = TidalClient::parseSearch(reply(
            R"({"type": "ALBUMS", "value": {"id": 8001, "title": "Erfundenes Album",
                "explicit": true, "artists": [{"id": 7001, "name": "Beispielkapelle"}]}})"));
        QCOMPARE(r.topHitKind, QStringLiteral("album"));
        QCOMPARE(r.topAlbum.id, 8001LL);
        QVERIFY(r.topAlbum.explicit_);
        QCOMPARE(r.topAlbum.artistNames(), QStringLiteral("Beispielkapelle"));
    }

    void aTrackTopHitIsKept() {
        const SearchResults r = TidalClient::parseSearch(reply(
            R"({"type": "TRACKS", "value": {"id": 9001, "title": "Erfundenes Lied",
                "album": {"id": 8001, "title": "Erfundenes Album"}}})"));
        QCOMPARE(r.topHitKind, QStringLiteral("track"));
        QCOMPARE(r.topTrack.id, 9001LL);
        QCOMPARE(r.topTrack.album.id, 8001LL);
    }

    void aPlaylistTopHitIsKept() {
        const SearchResults r = TidalClient::parseSearch(reply(
            R"({"type": "PLAYLISTS", "value": {"uuid": "erfunden-1", "title": "Erfundene Playlist"}})"));
        QCOMPARE(r.topHitKind, QStringLiteral("playlist"));
        QCOMPARE(r.topPlaylist.uuid, QStringLiteral("erfunden-1"));
    }

    // The app plays no videos, so a video hit is no hit at all.
    void aVideoTopHitIsDropped() {
        const SearchResults r = TidalClient::parseSearch(reply(
            R"({"type": "VIDEOS", "value": {"id": 6001, "title": "Erfundenes Video"}})"));
        QVERIFY(r.topHitKind.isEmpty());
    }

    void aReplyWithoutATopHitNamesNone_data() {
        QTest::addColumn<QByteArray>("hit");
        QTest::newRow("null")       << QByteArray("null");
        QTest::newRow("no value")   << QByteArray(R"({"type": "ARTISTS"})");
        QTest::newRow("no id")      << QByteArray(R"({"type": "ALBUMS", "value": {"title": "x"}})");
        QTest::newRow("no uuid")    << QByteArray(R"({"type": "PLAYLISTS", "value": {"title": "x"}})");
    }
    void aReplyWithoutATopHitNamesNone() {
        QFETCH(QByteArray, hit);
        const SearchResults r = TidalClient::parseSearch(reply(hit.constData()));
        QVERIFY2(r.topHitKind.isEmpty(), qPrintable(r.topHitKind));
        QCOMPARE(r.artists.size(), 1);
    }
};

QTEST_GUILESS_MAIN(TestSearchParse)
#include "tst_search_parse.moc"
