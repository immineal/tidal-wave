// The favourites lists as TidalClient fetches them: the body is parsed on a
// pool thread and the rows come back on the GUI thread. FakeApi overrides
// TidalApi::getBody and get, so the cases drive the real TidalClient. Every id
// and title below is invented.

#include <QTest>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QThread>
#include <QUrlQuery>

#include <functional>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "api/Models.h"

using namespace Tidal;

class FakeApi : public TidalApi {
public:
    QByteArray body;
    QString    error;
    // order=INDEX answers this error, whatever `error` says.
    QString    indexError;
    QList<QUrlQuery> asked;
    QJsonObject ids;

    void getBody(const QString &, const QUrlQuery &params, RawCallback cb) override {
        asked << params;
        if (!indexError.isEmpty() && params.queryItemValue("order") == "INDEX") {
            cb({}, indexError);
            return;
        }
        cb(error.isEmpty() ? body : QByteArray(), error);
    }
    void get(const QString &, const QUrlQuery &, JsonCallback cb) override { cb(ids, {}); }
};

static QByteArray page(int n) {
    QJsonArray items;
    for (int i = 0; i < n; ++i) {
        QJsonObject item{{"id", 1000 + i}, {"title", QStringLiteral("Song %1").arg(i)}};
        items.append(QJsonObject{{"created", "2026-01-01T00:00:00.000+0000"}, {"item", item}});
    }
    return QJsonDocument(QJsonObject{{"items", items}}).toJson(QJsonDocument::Compact);
}

struct Reply {
    QList<Track> tracks;
    QString      err;
    int          calls = 0;
    QThread     *thread = nullptr;
};

class TestFavoritesParse : public QObject {
    Q_OBJECT
private slots:
    void theRowsArriveLaterOnTheGuiThread() {
        FakeApi api;
        api.body = page(300);
        TidalClient client(&api);
        Reply r;
        client.fetchFavoriteTracks([&r](QList<Track> t, QString e) {
            r.tracks = t; r.err = e; ++r.calls; r.thread = QThread::currentThread(); },
            10000, 0);
        QCOMPARE(r.calls, 0);
        QTRY_COMPARE(r.calls, 1);
        QVERIFY(r.err.isEmpty());
        QCOMPARE(r.thread, QThread::currentThread());
        QCOMPARE(r.tracks.size(), 300);
        QCOMPARE(r.tracks.first().id, 1000);
        QCOMPARE(r.tracks.last().id, 1299);
    }

    void aBodyThatIsNotJsonIsAnError() {
        FakeApi api;
        api.body = "{\"items\": [";
        TidalClient client(&api);
        Reply r;
        client.fetchFavoriteAlbums([&r](QList<Album>, QString e) { r.err = e; ++r.calls; },
                                   10000, 0);
        QTRY_COMPARE(r.calls, 1);
        QVERIFY(!r.err.isEmpty());
    }

    void aTransportErrorPassesThrough() {
        FakeApi api;
        api.error = QStringLiteral("refused");
        TidalClient client(&api);
        Reply r;
        client.fetchFavoriteArtists([&r](QList<Artist>, QString e) { r.err = e; ++r.calls; },
                                    10000, 0);
        QCOMPARE(r.calls, 1);
        QCOMPARE(r.err, QStringLiteral("refused"));
    }

    // The continuation is bound to the client, so a reply that lands after it
    // is gone is dropped.
    void aGoneClientGetsNoReply() {
        FakeApi api;
        api.body = page(2000);
        auto *client = new TidalClient(&api);
        int calls = 0;
        client->fetchFavoriteTracks([&calls](QList<Track>, QString) { ++calls; }, 10000, 0);
        delete client;
        QTest::qWait(300);
        QCOMPARE(calls, 0);
    }

    void aRefusedIndexOrderIsAskedByDate() {
        FakeApi api;
        api.body = page(5);
        api.indexError = QStringLiteral("404");
        TidalClient client(&api);
        Reply r;
        client.fetchFavoriteTracksByIndex([&r](QList<Track> t, QString e) {
            r.tracks = t; r.err = e; ++r.calls; }, 100, 0, false);
        QTRY_COMPARE(r.calls, 1);
        QVERIFY(r.err.isEmpty());
        QCOMPARE(r.tracks.size(), 5);
        QCOMPARE(api.asked.size(), 2);
        QCOMPARE(api.asked.at(1).queryItemValue("order"), QStringLiteral("DATE"));
    }

    void theIdsListReadsStringsAndNumbers() {
        FakeApi api;
        api.ids = QJsonObject{{"TRACK", QJsonArray{"11", 12}}, {"ALBUM", QJsonArray{"21"}},
                              {"ARTIST", QJsonArray{31}}, {"PLAYLIST", QJsonArray{"a-b"}}};
        TidalClient client(&api);
        FavoriteIds got;
        client.fetchFavoriteIds([&got](FavoriteIds ids, QString) { got = ids; });
        QCOMPARE(got.tracks, (QSet<qint64>{11, 12}));
        QCOMPARE(got.albums, (QSet<qint64>{21}));
        QCOMPARE(got.artists, (QSet<qint64>{31}));
    }
};

QTEST_GUILESS_MAIN(TestFavoritesParse)
#include "tst_favorites_parse.moc"
