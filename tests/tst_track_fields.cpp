// What a track row is told about one track beyond its title: the version
// that tells two recordings of a title apart and when the track was added to
// the list, from the API through the favourites cache to the map QML reads.
// Every id, title and date is invented.

#include <QTest>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrlQuery>
#include <QVariantMap>

#include "api/FavoritesCache.h"
#include "api/Models.h"
#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"

using namespace Tidal;

namespace {

// Answers every list request with `body`, as favourites pages arrive.
class FakeApi : public TidalApi {
public:
    QByteArray body;
    void getBody(const QString &, const QUrlQuery &, RawCallback cb) override { cb(body, {}); }
};

const QString kCreated = QStringLiteral("2025-03-04T05:06:07.000+0000");

qint64 msOf(const QString &iso) {
    return QDateTime::fromString(iso, Qt::ISODate).toMSecsSinceEpoch();
}

} // namespace

class TestTrackFields : public QObject {
    Q_OBJECT
private slots:
    void theVersionIsRead() {
        const Track t = Track::fromJson(QJsonObject{
            {"id", 501}, {"title", "Ein Lied"}, {"version", "Live in Bremen"}});
        QCOMPARE(t.version, QStringLiteral("Live in Bremen"));
    }

    // Most tracks answer "version": null.
    void aNullVersionIsNone() {
        const Track t = Track::fromJson(QJsonObject{
            {"id", 502}, {"title", "Ein Lied"}, {"version", QJsonValue::Null}});
        QVERIFY(t.version.isEmpty());
    }

    void theRowMapCarriesTheVersion() {
        Track t;
        t.id = 503;
        t.title = QStringLiteral("Ein Lied");
        t.version = QStringLiteral("Remastered 2011");
        const QVariantMap m = TidalBridge::trackToMap(t);
        QCOMPARE(m.value("version").toString(), QStringLiteral("Remastered 2011"));
    }

    // The liked list is drawn from the disk copy at start, so the copy keeps it.
    void theCacheKeepsTheVersion() {
        Track t;
        t.id = 504;
        t.title = QStringLiteral("Ein Lied");
        t.version = QStringLiteral("Acoustic");
        const Track back = Track::fromJson(FavoritesCache::toJson(t));
        QCOMPARE(back.version, QStringLiteral("Acoustic"));
    }

    // Liked tracks: the date is on the favourites row, not on the track.
    void aLikedTrackKnowsWhenItWasLiked() {
        FakeApi api;
        const QJsonObject item{{"id", 601}, {"title", "Ein Lied"}};
        api.body = QJsonDocument(QJsonObject{{"items", QJsonArray{
            QJsonObject{{"created", kCreated}, {"item", item}}}}}).toJson();
        TidalClient client(&api);
        QList<Track> got;
        int calls = 0;
        client.fetchFavoriteTracks([&](QList<Track> t, QString) { got = t; ++calls; }, 50, 0);
        QTRY_COMPARE(calls, 1);
        QCOMPARE(got.size(), 1);
        QCOMPARE(got.first().addedAt, msOf(kCreated));
    }

    // A playlist's tracks carry the date on the track itself.
    void aPlaylistTrackKnowsWhenItWasAdded() {
        const Track t = Track::fromJson(QJsonObject{
            {"id", 602}, {"title", "Ein Lied"}, {"dateAdded", kCreated}});
        QCOMPARE(t.addedAt, msOf(kCreated));
    }

    void anUndatedTrackSaysZero() {
        QCOMPARE(Track::fromJson(QJsonObject{{"id", 603}}).addedAt, qint64(0));
    }

    void theRowMapAndTheCacheKeepTheDate() {
        Track t;
        t.id = 604;
        t.addedAt = msOf(kCreated);
        QCOMPARE(TidalBridge::trackToMap(t).value("addedAt").toLongLong(), msOf(kCreated));
        QCOMPARE(Track::fromJson(FavoritesCache::toJson(t)).addedAt, msOf(kCreated));
    }
};

QTEST_GUILESS_MAIN(TestTrackFields)
#include "tst_track_fields.moc"
