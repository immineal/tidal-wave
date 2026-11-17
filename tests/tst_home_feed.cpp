// Tidal's own Home: v2/home/feed/<feed>, the rows Tidal's apps show on Home.
// The fixtures in tests/fixtures/home_feed_*.json follow the shape of the live
// feed; every id, title and image in them is invented. Nothing here touches
// the network: FeedApi answers getV2Web() from those files.

#include <QTest>
#include <QFile>
#include <QJSEngine>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUrlQuery>

#include "api/FavoritesCache.h"
#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"

namespace {

QJsonObject fixture(const QString &name) {
    QFile f(QStringLiteral(TW_FIXTURE_DIR "/") + name);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(f.readAll()).object();
}

// Page one without a cursor, page two for the cursor page one names.
class FeedApi : public TidalApi {
public:
    struct Request { QString endpoint; QUrlQuery params; };
    QList<Request> requests;
    QHash<QString, QJsonObject> pages;    // cursor ("" for the first) to body
    QHash<QString, QString>     errors;   // cursor to the error it answers

    void getV2Web(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) override {
        requests.append({endpoint, params});
        const QString cursor = params.queryItemValue(QStringLiteral("cursor"));
        if (errors.contains(cursor)) { cb({}, errors.value(cursor)); return; }
        cb(pages.value(cursor), {});
    }
};

// The two calls the bridge makes on a sign-in, answered at once, so a bridge
// with a user id never reaches for the network.
class FeedClient : public TidalClient {
public:
    explicit FeedClient(TidalApi *api) : TidalClient(api) {}
    void fetchFavoriteIds(FavoriteIdsCallback cb) override { cb({}, QStringLiteral("not in this test")); }
    void fetchFavoriteMixes(MixesCallback cb) override { cb({}, QStringLiteral("not in this test")); }
};

constexpr qint64 kUid = 4242;

QStringList moduleIds(const HomeFeed &feed) {
    QStringList out;
    for (const HomeModule &m : feed.modules) out << m.id;
    return out;
}

QStringList moduleIds(const QVariantMap &feed) {
    QStringList out;
    for (const QVariant &v : feed.value(QStringLiteral("modules")).toList())
        out << v.toMap().value(QStringLiteral("id")).toString();
    return out;
}

QVariantMap moduleOf(const QVariantMap &feed, const QString &id) {
    for (const QVariant &v : feed.value(QStringLiteral("modules")).toList())
        if (v.toMap().value(QStringLiteral("id")).toString() == id) return v.toMap();
    return {};
}

QList<qlonglong> itemIds(const QVariantMap &module) {
    QList<qlonglong> out;
    for (const QVariant &v : module.value(QStringLiteral("items")).toList())
        out << v.toMap().value(QStringLiteral("id")).toLongLong();
    return out;
}

} // namespace

class TestHomeFeed : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;

    struct Harness {
        FeedApi     api;
        FeedClient  client{&api};
        QJSEngine   engine;
        TidalBridge bridge{&client};
        QJSValue    keepAlive;
        Harness() {
            api.pages.insert(QString(), fixture(QStringLiteral("home_feed_static_1.json")));
            api.pages.insert(QStringLiteral("UEFHRV8y"), fixture(QStringLiteral("home_feed_static_2.json")));
            QJSEngine::setObjectOwnership(&bridge, QJSEngine::CppOwnership);
            keepAlive = engine.newQObject(&bridge);
            client.setUserId(kUid);
        }
        // fetchHomeFeed through the bridge, the answer read back from script.
        QVariantMap fetch(const QString &feed, const QString &language, QString *err = nullptr) {
            QJSValue holder = engine.newObject();
            const QJSValue cb = engine.evaluate(QStringLiteral(
                "(function (h) { return function (feed, err) { h.feed = feed; h.err = err; h.seen = true }; })"))
                .call({holder});
            bridge.fetchHomeFeed(feed, language, cb);
            if (err) *err = holder.property(QStringLiteral("err")).toString();
            if (!holder.property(QStringLiteral("seen")).toBool()) return {{QStringLiteral("unseen"), true}};
            return holder.property(QStringLiteral("feed")).toVariant().toMap();
        }
    };

    static HomeFeed fetchedFeed(FeedApi &api, QString *err = nullptr) {
        TidalClient client(&api);
        QJsonObject got;
        QString error = QStringLiteral("never answered");
        client.fetchHomeFeed(QStringLiteral("static"), QStringLiteral("en_US"),
                             [&](QJsonObject root, QString e) { got = root; error = e; });
        if (err) *err = error;
        return TidalClient::parseHomeFeed(got);
    }

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_home_feed"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
        QVERIFY(!fixture(QStringLiteral("home_feed_static_1.json")).isEmpty());
    }

    void init() {
        QSettings().clear();
        for (const char *feed : {"static", "editorial"})
            QFile::remove(FavoritesCache::path(QStringLiteral("home-") + QLatin1String(feed), kUid));
    }

    // Both pages, in Tidal's order, with the rows Home cannot show left out
    // and the rows Home's own stand in for kept as places.
    void theRowsComeInTidalsOrder() {
        FeedApi api;
        api.pages.insert(QString(), fixture(QStringLiteral("home_feed_static_1.json")));
        api.pages.insert(QStringLiteral("UEFHRV8y"), fixture(QStringLiteral("home_feed_static_2.json")));
        QString err;
        const HomeFeed feed = fetchedFeed(api, &err);
        QVERIFY2(err.isEmpty(), qPrintable(err));
        QCOMPARE(moduleIds(feed), (QStringList{
            "DAILY_MIXES", "CONTINUE_LISTEN_TO", "NEW_ALBUM_SUGGESTIONS",
            "BECAUSE_YOU_LISTENED_TO_ALBUM", "RECOMMENDED_USERS_PLAYLISTS",
            "BASED_ON_YOUR_INTERESTS_1", "ALBUM_RECOMMENDATIONS", "YOUR_FAVORITE_ARTISTS",
            "SUGGESTED_ESSENTIAL_PLAYLISTS", "MY_PLAYLISTS", "POPULAR_PLAYLISTS", "HISTORY_MIXES"}));

        QCOMPARE(api.requests.size(), 2);
        QCOMPARE(api.requests[0].endpoint, QStringLiteral("home/feed/static"));
        QCOMPARE(api.requests[0].params.queryItemValue("locale"), QStringLiteral("en_US"));
        QCOMPARE(api.requests[0].params.queryItemValue("platform"), QStringLiteral("WEB"));
        QCOMPARE(api.requests[0].params.queryItemValue("deviceType"), QStringLiteral("BROWSER"));
        QCOMPARE(api.requests[1].params.queryItemValue("cursor"), QStringLiteral("UEFHRV8y"));

        QStringList owns;
        for (const HomeModule &m : feed.modules) {
            if (m.ownRow.isEmpty()) continue;
            owns << m.id + "=" + m.ownRow;
            QVERIFY2(m.items.isEmpty(), qPrintable(m.id));
        }
        QCOMPARE(owns, (QStringList{"DAILY_MIXES=mixes", "CONTINUE_LISTEN_TO=recent",
                                    "YOUR_FAVORITE_ARTISTS=artists", "MY_PLAYLISTS=playlists"}));

        QCOMPARE(feed.tabs.size(), 2);
        QCOMPARE(feed.tabs[0], (std::pair<QString, QString>{"For you", "static"}));
        QCOMPARE(feed.tabs[1], (std::pair<QString, QString>{"Staff Picks", "editorial"}));
    }

    void theCardsAreReadFromTheFeedsShapes() {
        FeedApi api;
        api.pages.insert(QString(), fixture(QStringLiteral("home_feed_static_1.json")));
        api.pages.insert(QStringLiteral("UEFHRV8y"), fixture(QStringLiteral("home_feed_static_2.json")));
        const HomeFeed feed = fetchedFeed(api);
        QHash<QString, HomeModule> byId;
        for (const HomeModule &m : feed.modules) byId.insert(m.id, m);

        // A mixed row keeps its kinds in order and drops the video.
        const HomeModule mixed = byId.value("BASED_ON_YOUR_INTERESTS_1");
        QCOMPARE(mixed.items.size(), 3);
        QVERIFY(mixed.items[0].kind == HomeItem::Kind::Artist);
        QCOMPARE(mixed.items[0].artist.name, QStringLiteral("Genre Artist"));
        QVERIFY(mixed.items[1].kind == HomeItem::Kind::Playlist);
        QCOMPARE(mixed.items[1].playlist.uuid, QStringLiteral("cccc0002-0000-4000-8000-000000000002"));
        QVERIFY(mixed.items[2].kind == HomeItem::Kind::Album);
        QCOMPARE(mixed.items[2].album.id, qint64(9200005));

        // The feed's own mix shape, and no video mix.
        const HomeModule history = byId.value("HISTORY_MIXES");
        QCOMPARE(history.items.size(), 1);
        const Mix m = history.items[0].mix;
        QCOMPARE(m.id, QStringLiteral("mx0000000000000000000000000002"));
        QCOMPARE(m.title, QStringLiteral("My October"));
        QCOMPARE(m.subTitle, QStringLiteral("Placeholder subtitle"));
        QCOMPARE(m.mixType, QStringLiteral("HISTORY_MONTHLY_MIX"));
        QCOMPARE(m.coverUrl(), QStringLiteral("https://images.tidal.com/0/mx2/640"));

        QCOMPARE(byId.value("BECAUSE_YOU_LISTENED_TO_ALBUM").context, QStringLiteral("Context Album"));
        QCOMPARE(byId.value("NEW_ALBUM_SUGGESTIONS").items.size(), 3);
        // The app writes the name as a word, never in capitals.
        QCOMPARE(byId.value("POPULAR_PLAYLISTS").title, QStringLiteral("Popular playlists on Tidal"));
    }

    // One broken row is left out and the rest stand.
    void aBrokenRowTakesNothingElseDown() {
        const QJsonObject root = QJsonDocument::fromJson(R"json({"items": [
            {"type": "HORIZONTAL_LIST", "moduleId": "A", "title": "Broken", "items": "not a list"},
            {"type": "HORIZONTAL_LIST", "moduleId": "B", "title": "No data", "items": [{"type": "ALBUM"}]},
            {"type": "HORIZONTAL_LIST", "moduleId": "C", "title": "", "items": [{"type": "ALBUM", "data": {"id": 1}}]},
            "not a module",
            {"type": "HORIZONTAL_LIST", "moduleId": "D", "title": "Fine",
             "items": [{"type": "ALBUM", "data": {"id": 2, "title": "Kept"}}]}
        ]})json").object();
        const HomeFeed feed = TidalClient::parseHomeFeed(root);
        QCOMPARE(moduleIds(feed), QStringList{"D"});
        QVERIFY(TidalClient::parseHomeFeed({}).modules.isEmpty());
    }

    void aLaterPageFailingKeepsTheFirst() {
        FeedApi api;
        api.pages.insert(QString(), fixture(QStringLiteral("home_feed_static_1.json")));
        api.errors.insert(QStringLiteral("UEFHRV8y"), QStringLiteral("Host unreachable"));
        QString err;
        const HomeFeed feed = fetchedFeed(api, &err);
        QVERIFY(err.isEmpty());
        QCOMPARE(feed.modules.size(), 6);
        QCOMPARE(feed.modules.last().id, QStringLiteral("BASED_ON_YOUR_INTERESTS_1"));
    }

    void aFirstPageFailingIsAnError() {
        FeedApi api;
        api.errors.insert(QString(), QStringLiteral("Host unreachable"));
        QString err;
        const HomeFeed feed = fetchedFeed(api, &err);
        QCOMPARE(err, QStringLiteral("Host unreachable"));
        QVERIFY(feed.modules.isEmpty());
    }

    // A server that names the same cursor again ends the run.
    void aRepeatedCursorEndsThePaging() {
        FeedApi api;
        QJsonObject p1 = fixture(QStringLiteral("home_feed_static_1.json"));
        api.pages.insert(QString(), p1);
        api.pages.insert(QStringLiteral("UEFHRV8y"), p1);
        fetchedFeed(api);
        QCOMPARE(api.requests.size(), 2);
    }

    // ── the bridge ──────────────────────────────────────────────────────

    void theFeedIsWordedInTheAppsLanguage() {
        Harness h;
        h.fetch(QStringLiteral("static"), QStringLiteral("de"));
        QCOMPARE(h.api.requests.value(0).params.queryItemValue("locale"), QStringLiteral("de_DE"));
        h.fetch(QStringLiteral("editorial"), QStringLiteral("en"));
        QCOMPARE(h.api.requests.last().endpoint, QStringLiteral("home/feed/editorial"));
        QCOMPARE(h.api.requests.last().params.queryItemValue("locale"), QStringLiteral("en_US"));
    }

    // A release Tidal lists explicit and clean shows once, in the version
    // the user prefers, as in search and on artist pages.
    void theVersionPreferenceAppliesToTheRows() {
        Harness h;
        h.bridge.setPreferExplicit(true);
        QVariantMap feed = h.fetch(QStringLiteral("static"), QStringLiteral("en"));
        QCOMPARE(itemIds(moduleOf(feed, "NEW_ALBUM_SUGGESTIONS")), (QList<qlonglong>{9200001, 9200003}));
        h.bridge.setPreferExplicit(false);
        feed = h.bridge.cachedHomeFeed(QStringLiteral("static"));
        QCOMPARE(itemIds(moduleOf(feed, "NEW_ALBUM_SUGGESTIONS")), (QList<qlonglong>{9200002, 9200003}));
    }

    void theBridgeHandsQmlCardMaps() {
        Harness h;
        const QVariantMap feed = h.fetch(QStringLiteral("static"), QStringLiteral("en"));
        QVERIFY(!feed.contains("unseen"));
        const QVariantMap mixed = moduleOf(feed, "BASED_ON_YOUR_INTERESTS_1");
        QCOMPARE(mixed.value("mediaType").toString(), QStringLiteral("recent"));
        const QVariantList items = mixed.value("items").toList();
        QCOMPARE(items.size(), 3);
        QCOMPARE(items[0].toMap().value("kind").toString(), QStringLiteral("artist"));
        QCOMPARE(items[1].toMap().value("kind").toString(), QStringLiteral("playlist"));
        QCOMPARE(items[1].toMap().value("uuid").toString(), QStringLiteral("cccc0002-0000-4000-8000-000000000002"));
        QCOMPARE(items[2].toMap().value("kind").toString(), QStringLiteral("album"));
        QCOMPARE(moduleOf(feed, "HISTORY_MIXES").value("mediaType").toString(), QStringLiteral("mix"));
        QCOMPARE(moduleOf(feed, "MY_PLAYLISTS").value("ownRow").toString(), QStringLiteral("playlists"));
        QCOMPARE(moduleOf(feed, "BECAUSE_YOU_LISTENED_TO_ALBUM").value("context").toString(),
                 QStringLiteral("Context Album"));
        const QVariantList tabs = feed.value("tabs").toList();
        QCOMPARE(tabs.size(), 2);
        QCOMPARE(tabs[1].toMap().value("feed").toString(), QStringLiteral("editorial"));
    }

    // Home opens on the last answer while the next is on its way, and a
    // failed fetch leaves that answer as it was.
    void theLastAnswerIsKeptOnDisk() {
        QStringList landed;
        {
            Harness h;
            QVERIFY(h.bridge.cachedHomeFeed("static").value("modules").toList().isEmpty());
            landed = moduleIds(h.fetch(QStringLiteral("static"), QStringLiteral("en")));
            QCOMPARE(landed.size(), 12);
        }
        {
            Harness h;
            QCOMPARE(moduleIds(h.bridge.cachedHomeFeed("static")), landed);
            h.api.errors.insert(QString(), QStringLiteral("Host unreachable"));
            QString err;
            const QVariantMap failed = h.fetch(QStringLiteral("static"), QStringLiteral("en"), &err);
            QCOMPARE(err, QStringLiteral("Host unreachable"));
            QVERIFY(failed.value("modules").toList().isEmpty());
            QCOMPARE(moduleIds(h.bridge.cachedHomeFeed("static")), landed);
            // Another account reads none of it.
            h.client.setUserId(kUid + 1);
            QVERIFY(h.bridge.cachedHomeFeed("static").value("modules").toList().isEmpty());
            // Nor does a feed the app does not know.
            h.client.setUserId(kUid);
            QVERIFY(h.bridge.cachedHomeFeed("../favorites").value("modules").toList().isEmpty());
        }
    }
};

QTEST_MAIN(TestHomeFeed)
#include "tst_home_feed.moc"
