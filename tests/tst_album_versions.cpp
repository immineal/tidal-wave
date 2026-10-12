// The other versions of a record, as Tidal's own album page names them.
// `pages/album` answers rows of modules. Three of them are album lists, and
// only the title tells "Other versions" from the two that follow it, so the
// request names the locale that title is matched in. FakeApi overrides
// TidalApi::get, so the cases drive the real TidalClient and TidalBridge.
// Every id, title and name below is invented.

#include <QTest>
#include <QCoreApplication>
#include <QJSEngine>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QPair>
#include <QSettings>
#include <QStandardPaths>
#include <QString>
#include <QStringList>
#include <QTemporaryDir>
#include <QUrlQuery>

#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"
#include "api/Models.h"

using namespace Tidal;

namespace {

constexpr qint64 kAlbumId       = 900400001;   // explicit, hi-res stereo
constexpr qint64 kCleanId       = 900400002;   // clean, hi-res stereo
constexpr qint64 kAtmosId       = 900400003;   // explicit, Dolby Atmos only
constexpr qint64 kCleanAtmosId  = 900400004;   // clean, Dolby Atmos only

const QStringList kStereo = {QStringLiteral("STEREO")};
const QStringList kAtmos  = {QStringLiteral("DOLBY_ATMOS")};
const QStringList kHiRes  = {QStringLiteral("LOSSLESS"), QStringLiteral("HIRES_LOSSLESS")};

// An album as a page module lists it: no `type` and no barcode.
QJsonObject product(qint64 id, const QString &title, bool isExplicit,
                    const QStringList &modes, const QStringList &tags)
{
    QJsonObject o;
    o["id"]             = id;
    o["title"]          = title;
    o["cover"]          = QStringLiteral("%1-0000-0000-0000-000000000000")
                              .arg(id % 100000000, 8, 10, QLatin1Char('0'));
    o["explicit"]       = isExplicit;
    o["audioQuality"]   = modes == kAtmos ? QStringLiteral("LOW") : QStringLiteral("LOSSLESS");
    o["audioModes"]     = QJsonArray::fromStringList(modes);
    o["mediaMetadata"]  = QJsonObject{{QStringLiteral("tags"), QJsonArray::fromStringList(tags)}};
    o["numberOfTracks"] = 9;
    o["duration"]       = 2140;
    o["releaseDate"]    = QStringLiteral("2031-03-14");
    o["allowStreaming"] = true;
    o["streamReady"]    = true;
    o["artists"]        = QJsonArray{QJsonObject{{QStringLiteral("id"), 900400900},
                                                 {QStringLiteral("name"), QStringLiteral("Marit Solvang")}}};
    return o;
}

QJsonObject module(const QString &type, const QString &title,
                   const QList<QJsonObject> &items = {})
{
    QJsonArray list;
    for (const QJsonObject &o : items) list.append(o);
    QJsonObject paged;
    paged["limit"]              = 5;
    paged["offset"]             = 0;
    paged["totalNumberOfItems"] = int(items.size());
    paged["items"]              = list;

    QJsonObject m;
    m["type"]      = type;
    m["title"]     = title;
    m["pagedList"] = paged;
    return m;
}

// One module to a row, as the server sends a page.
QJsonObject page(const QList<QJsonObject> &modules)
{
    QJsonArray rows;
    for (const QJsonObject &m : modules)
        rows.append(QJsonObject{{QStringLiteral("modules"), QJsonArray{m}}});
    QJsonObject root;
    root["title"] = QStringLiteral("Salzwiesen");
    root["rows"]  = rows;
    return root;
}

QJsonObject headerModule()
{
    QJsonObject m;
    m["type"]  = QStringLiteral("ALBUM_HEADER");
    m["title"] = QString();
    m["album"] = product(kAlbumId, QStringLiteral("Salzwiesen"), true, kStereo, kHiRes);
    return m;
}

QList<QJsonObject> theOtherThree()
{
    return {
        product(kCleanId,      QStringLiteral("Salzwiesen"), false, kStereo, kHiRes),
        product(kAtmosId,      QStringLiteral("Salzwiesen"), true,  kAtmos,  kAtmos),
        product(kCleanAtmosId, QStringLiteral("Salzwiesen"), false, kAtmos,  kAtmos),
    };
}

QJsonObject moreByTheArtist()
{
    return module(QStringLiteral("ALBUM_LIST"), QStringLiteral("More Albums by Marit Solvang"),
                  { product(900400101, QStringLiteral("Priel"),      false, kStereo, kHiRes),
                    product(900400102, QStringLiteral("Hochwasser"), true,  kStereo, kHiRes) });
}

QJsonObject relatedAlbums()
{
    return module(QStringLiteral("ALBUM_LIST"), QStringLiteral("Related Albums"),
                  { product(900400201, QStringLiteral("Nebelhorn"), false, kStereo, kHiRes),
                    product(900400202, QStringLiteral("Schlick"),   true,  kAtmos,  kAtmos) });
}

// The whole page of a record with other versions: header, tracks, the three
// album lists and the artists that close it.
QJsonObject fullPage(const QList<QJsonObject> &otherVersions,
                     const QString &title = QStringLiteral("Other versions"))
{
    return page({ headerModule(),
                  module(QStringLiteral("ALBUM_ITEMS"), QString()),
                  module(QStringLiteral("ALBUM_LIST"), title, otherVersions),
                  moreByTheArtist(),
                  relatedAlbums(),
                  module(QStringLiteral("ARTIST_LIST"), QStringLiteral("Related Artists")) });
}

QList<qint64> idsOf(const QList<Album> &albums)
{
    QList<qint64> out;
    for (const Album &a : albums) out << a.id;
    return out;
}

// A TidalApi that answers every GET with one canned body or one error, and
// keeps what was asked.
class FakeApi : public TidalApi {
public:
    struct Request {
        QString endpoint;
        QList<QPair<QString, QString>> params;
        QString value(const QString &key) const {
            for (const auto &p : params) if (p.first == key) return p.second;
            return {};
        }
    };

    QList<Request> requests;
    QJsonObject    body;
    QString        error;

    void get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) override {
        requests.append({endpoint, params.queryItems()});
        if (!error.isEmpty()) { cb(QJsonObject(), error); return; }
        cb(body, QString());
    }
};

// One fetchAlbumOtherVersions() run and what it delivered.
struct Run {
    QList<Album> albums;
    QString      err;
    int          replies = 0;
};

void start(TidalClient &client, Run &run, qint64 albumId = kAlbumId) {
    client.fetchAlbumOtherVersions(albumId, [&run](QList<Album> albums, QString err) {
        ++run.replies;
        run.albums = albums;
        run.err    = err;
    });
}

} // namespace

class TestAlbumVersions : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        // Never the real configuration: the bridge's constructor reads the
        // stored quality.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_album_versions"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
    }

    // ── the parser ───────────────────────────────────────────────────────────

    // Of the three album lists the one titled "Other versions" is taken, in
    // the order the page has it, and nothing from the two that follow.
    void thePageWithThreeAlbumListsYieldsItsOtherVersions() {
        const QList<Album> got =
            TidalClient::parseAlbumOtherVersions(fullPage(theOtherThree()), kAlbumId);
        QCOMPARE(idsOf(got), (QList<qint64>{kCleanId, kAtmosId, kCleanAtmosId}));
    }

    // What the album page words a card from has to come through the parse.
    void whatTellsAVersionApartSurvivesTheParse() {
        const QList<Album> got =
            TidalClient::parseAlbumOtherVersions(fullPage(theOtherThree()), kAlbumId);
        QCOMPARE(got.size(), 3);
        QCOMPARE(got.at(0).explicit_, false);
        QCOMPARE(got.at(0).audioModes, kStereo);
        QCOMPARE(got.at(0).mediaTags, kHiRes);
        QCOMPARE(got.at(0).audioQuality, QStringLiteral("LOSSLESS"));
        QCOMPARE(got.at(1).explicit_, true);
        QCOMPARE(got.at(1).audioModes, kAtmos);
        QCOMPARE(got.at(1).audioQuality, QStringLiteral("LOW"));
        QCOMPARE(got.at(2).explicit_, false);
        QCOMPARE(got.at(2).title, QStringLiteral("Salzwiesen"));
        QCOMPARE(got.at(2).artistNames(), QStringLiteral("Marit Solvang"));
        QVERIFY2(!got.at(2).cover.isEmpty(), "a version came through without its cover");
    }

    // A record with one product: the page has the two other lists only.
    void aPageWithoutTheModuleYieldsNothing() {
        const QJsonObject root = page({ headerModule(),
                                        module(QStringLiteral("ALBUM_ITEMS"), QString()),
                                        moreByTheArtist(),
                                        relatedAlbums() });
        const QList<Album> got = TidalClient::parseAlbumOtherVersions(root, kAlbumId);
        QVERIFY2(got.isEmpty(),
                 qPrintable(QStringLiteral("%1 albums of another list were taken for versions")
                                .arg(got.size())));
    }

    void anEmptyModuleYieldsNothing() {
        QVERIFY(TidalClient::parseAlbumOtherVersions(fullPage({}), kAlbumId).isEmpty());

        // The module without its list at all.
        QJsonObject bare;
        bare["type"]  = QStringLiteral("ALBUM_LIST");
        bare["title"] = QStringLiteral("Other versions");
        QVERIFY(TidalClient::parseAlbumOtherVersions(page({ bare, relatedAlbums() }), kAlbumId)
                    .isEmpty());
    }

    void aBodyThatIsNoPageYieldsNothing_data() {
        QTest::addColumn<QJsonObject>("root");
        QTest::newRow("empty") << QJsonObject();
        QTest::newRow("a refusal")
            << QJsonObject{{QStringLiteral("status"), 404},
                           {QStringLiteral("userMessage"), QStringLiteral("Not found")}};
        QTest::newRow("rows is a string")
            << QJsonObject{{QStringLiteral("rows"), QStringLiteral("Other versions")}};
        QTest::newRow("rows of numbers")
            << QJsonObject{{QStringLiteral("rows"), QJsonArray{1, 2, 3}}};
        QTest::newRow("modules is an object")
            << QJsonObject{{QStringLiteral("rows"),
                            QJsonArray{QJsonObject{{QStringLiteral("modules"),
                                module(QStringLiteral("ALBUM_LIST"),
                                       QStringLiteral("Other versions"), theOtherThree())}}}}};
        // A bare album list, the shape artists/<id>/albums answers.
        QJsonArray items;
        for (const QJsonObject &o : theOtherThree()) items.append(o);
        QTest::newRow("a plain list") << QJsonObject{{QStringLiteral("items"), items}};
    }
    void aBodyThatIsNoPageYieldsNothing() {
        QFETCH(QJsonObject, root);
        QVERIFY(TidalClient::parseAlbumOtherVersions(root, kAlbumId).isEmpty());
    }

    // The title is all that names the module, so its case and outer spaces do
    // not decide. A module of another type under that title is no album list.
    void theTitleNamesTheModule_data() {
        QTest::addColumn<QString>("type");
        QTest::addColumn<QString>("title");
        QTest::addColumn<int>("expected");
        QTest::newRow("as served")      << QStringLiteral("ALBUM_LIST") << QStringLiteral("Other versions")   << 3;
        QTest::newRow("capitals")       << QStringLiteral("ALBUM_LIST") << QStringLiteral("Other Versions")   << 3;
        QTest::newRow("outer spaces")   << QStringLiteral("ALBUM_LIST") << QStringLiteral(" Other versions ") << 3;
        QTest::newRow("another title")  << QStringLiteral("ALBUM_LIST") << QStringLiteral("Other records")    << 0;
        QTest::newRow("no title")       << QStringLiteral("ALBUM_LIST") << QString()                          << 0;
        QTest::newRow("another type")   << QStringLiteral("TRACK_LIST") << QStringLiteral("Other versions")   << 0;
    }
    void theTitleNamesTheModule() {
        QFETCH(QString, type);
        QFETCH(QString, title);
        QFETCH(int, expected);
        const QJsonObject root = page({ headerModule(), module(type, title, theOtherThree()),
                                        relatedAlbums() });
        QCOMPARE(int(TidalClient::parseAlbumOtherVersions(root, kAlbumId).size()), expected);
    }

    // The album the page is about is no other version of itself, an id listed
    // twice is one card, and an entry without an id is none.
    void theAlbumItselfAndRepeatsAreLeftOut() {
        QList<QJsonObject> listed = theOtherThree();
        listed.prepend(product(kAlbumId, QStringLiteral("Salzwiesen"), true, kStereo, kHiRes));
        listed.append(product(kCleanId, QStringLiteral("Salzwiesen"), false, kStereo, kHiRes));
        QJsonObject nameless;
        nameless["title"] = QStringLiteral("Salzwiesen");
        listed.append(nameless);

        const QList<Album> got = TidalClient::parseAlbumOtherVersions(fullPage(listed), kAlbumId);
        QCOMPARE(idsOf(got), (QList<qint64>{kCleanId, kAtmosId, kCleanAtmosId}));
    }

    // ── the request ──────────────────────────────────────────────────────────

    void oneRequestToTheAlbumPageInTheLocaleOfTheTitle() {
        FakeApi api;
        api.body = fullPage(theOtherThree());
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        QCOMPARE(int(api.requests.size()), 1);
        const FakeApi::Request &r = api.requests.first();
        QCOMPARE(r.endpoint, QStringLiteral("pages/album"));
        QCOMPARE(r.value(QStringLiteral("albumId")), QStringLiteral("900400001"));
        QCOMPARE(r.value(QStringLiteral("deviceType")), QStringLiteral("BROWSER"));
        // Pinned as a literal: the module is found by its English title.
        QCOMPARE(r.value(QStringLiteral("locale")), QStringLiteral("en_US"));
        QCOMPARE(int(r.params.size()), 3);

        QCOMPARE(run.err, QString());
        QCOMPARE(idsOf(run.albums), (QList<qint64>{kCleanId, kAtmosId, kCleanAtmosId}));
    }

    void aFailedRequestReportsTheReasonAndNoVersions() {
        FakeApi api;
        api.body  = fullPage(theOtherThree());
        api.error = QStringLiteral("server replied: Not Found");
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        QCOMPARE(run.err, QStringLiteral("server replied: Not Found"));
        QVERIFY(run.albums.isEmpty());
    }

    // A record with no other version is an answer and no failure.
    void aPageThatNamesNoneIsNoFailure() {
        FakeApi api;
        api.body = page({ headerModule(), moreByTheArtist(), relatedAlbums() });
        TidalClient client{&api};
        Run run;
        start(client, run);

        QCOMPARE(run.replies, 1);
        QCOMPARE(run.err, QString());
        QVERIFY(run.albums.isEmpty());
    }

    // ── the hop to QML ───────────────────────────────────────────────────────

    // function(albums, error), the albums as the maps every album card reads.
    void theBridgeHandsTheVersionsToQmlAsAlbumMaps() {
        FakeApi api;
        api.body = fullPage(theOtherThree());
        Harness h{&api};

        h.bridge.fetchAlbumOtherVersions(kAlbumId, h.callback());

        QCOMPARE(h.seen.property(QStringLiteral("calls")).toInt(), 1);
        QCOMPARE(h.seen.property(QStringLiteral("err")).toString(), QString());
        QCOMPARE(h.seen.property(QStringLiteral("ids")).toString(),
                 QStringLiteral("900400002,900400003,900400004"));
        QCOMPARE(h.seen.property(QStringLiteral("explicit")).toString(),
                 QStringLiteral("false,true,false"));
        QCOMPARE(h.seen.property(QStringLiteral("modes")).toString(),
                 QStringLiteral("STEREO|DOLBY_ATMOS|DOLBY_ATMOS"));
        QCOMPARE(h.seen.property(QStringLiteral("quality")).toString(),
                 QStringLiteral("LOSSLESS,LOW,LOW"));
    }

    void theBridgeHandsAFailureOverAsAnEmptyListAndTheReason() {
        FakeApi api;
        api.error = QStringLiteral("server replied: Not Found");
        Harness h{&api};

        h.bridge.fetchAlbumOtherVersions(kAlbumId, h.callback());

        QCOMPARE(h.seen.property(QStringLiteral("calls")).toInt(), 1);
        QCOMPARE(h.seen.property(QStringLiteral("err")).toString(),
                 QStringLiteral("server replied: Not Found"));
        QCOMPARE(h.seen.property(QStringLiteral("ids")).toString(), QString());
    }

private:
    // A bridge over the real client, and a script callback that keeps what it
    // was called with: a QJSValue callback can be observed nowhere else.
    struct Harness {
        QJSEngine   engine;
        TidalClient client;
        TidalBridge bridge{&client};
        QJSValue    keepAlive;
        QJSValue    seen;

        explicit Harness(TidalApi *api) : client(api) {
            QJSEngine::setObjectOwnership(&bridge, QJSEngine::CppOwnership);
            keepAlive = engine.newQObject(&bridge);
            seen = engine.newObject();
            seen.setProperty(QStringLiteral("calls"), 0);
        }

        QJSValue callback() {
            return engine.evaluate(QStringLiteral(
                "(function (s) { return function (albums, err) {"
                " s.calls    = s.calls + 1;"
                " s.err      = String(err);"
                " s.ids      = albums.map(function (a) { return a.id }).join(',');"
                " s.explicit = albums.map(function (a) { return a.explicit_ }).join(',');"
                " s.modes    = albums.map(function (a) { return a.audioModes.join('+') }).join('|');"
                " s.quality  = albums.map(function (a) { return a.quality }).join(','); }; })"))
                       .call({seen});
        }
    };

    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestAlbumVersions)
#include "tst_album_versions.moc"
