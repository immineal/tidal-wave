// What a track row is told about one track beyond its title: the version
// that tells two recordings of a title apart, from the API through the
// favourites cache to the map QML reads. Every id and title is invented.

#include <QTest>
#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include "api/FavoritesCache.h"
#include "api/Models.h"
#include "api/TidalBridge.h"

using namespace Tidal;

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
};

QTEST_GUILESS_MAIN(TestTrackFields)
#include "tst_track_fields.moc"
