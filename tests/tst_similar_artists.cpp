// An artist's related artists: `artists/<id>/similar`, asked on its own so the
// rest of the artist page never waits for it. The reply is one page of artist
// objects; a 404 means Tidal has none for this artist. FakeApi overrides
// TidalApi::get, so the cases drive the real TidalClient and TidalBridge.
// Every id, name and picture below is invented.

#include <QTest>
#include <QCoreApplication>
#include <QHash>
#include <QJSEngine>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QPair>
#include <QSettings>
#include <QStandardPaths>
#include <QString>
#include <QTemporaryDir>
#include <QUrlQuery>

#include <functional>

#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"
#include "api/Models.h"

using namespace Tidal;

namespace {

constexpr qint64 kArtistId = 900500001;

// An artist as the similar endpoint lists it, picture null when it has none.
QJsonObject similar(qint64 id, const QString &name, const QString &picture = QString())
{
    QJsonObject o;
    o["id"]           = id;
    o["name"]         = name;
    o["picture"]      = picture.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(picture);
    o["artistTypes"]  = QJsonArray{QStringLiteral("ARTIST"), QStringLiteral("CONTRIBUTOR")};
    o["popularity"]   = 0;
    o["relationType"] = QStringLiteral("SIMILAR_ARTIST");
    o["type"]         = QJsonValue(QJsonValue::Null);
    return o;
}

QJsonObject page(const QList<QJsonObject> &items)
{
    QJsonArray list;
    for (const QJsonObject &o : items) list.append(o);
    QJsonObject root;
    root["limit"]              = 20;
    root["offset"]             = 0;
    // The server reports the page's own length here, not the whole list.
    root["totalNumberOfItems"] = int(items.size());
    root["source"]             = QStringLiteral("TiVo");
    root["items"]              = list;
    return root;
}

class FakeApi : public TidalApi {
public:
    struct Request {
        QString endpoint;
        QUrlQuery params;
    };

    QList<Request> requests;
    // endpoint -> reply body, and endpoint -> error. Unknown endpoints answer {}.
    QHash<QString, QJsonObject> bodies;
    QHash<QString, QString>     errors;
    // When set, the similar endpoint's reply is held until flushSimilar().
    bool holdSimilar = false;
    QList<std::function<void()>> held;

    void get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) override {
        requests.append({endpoint, params});
        const QString err = errors.value(endpoint);
        const QJsonObject body = bodies.value(endpoint);
        if (holdSimilar && endpoint.endsWith(QLatin1String("/similar"))) {
            held.append([cb, body, err] { cb(err.isEmpty() ? body : QJsonObject(), err); });
            return;
        }
        cb(err.isEmpty() ? body : QJsonObject(), err);
    }

    QStringList endpoints() const {
        QStringList out;
        for (const Request &r : requests) out << r.endpoint;
        return out;
    }
};

QString similarPath() { return QStringLiteral("artists/%1/similar").arg(kArtistId); }

QList<qint64> idsOf(const QList<Artist> &list) {
    QList<qint64> out;
    for (const Artist &a : list) out << a.id;
    return out;
}

} // namespace

class TestSimilarArtists : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        // Never the real configuration: the bridge's constructor reads the
        // stored quality.
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_similar_artists"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
    }

    // One request, to the similar path, for one page.
    void asksTheSimilarEndpointForOnePage() {
        FakeApi api;
        api.bodies[similarPath()] = page({similar(900500011, QStringLiteral("Erste Band"))});
        TidalClient client{&api};
        int replies = 0;
        client.fetchSimilarArtists(kArtistId, [&](QList<Artist>, QString) { ++replies; });

        QCOMPARE(replies, 1);
        QCOMPARE(api.endpoints(), QStringList{similarPath()});
        const QUrlQuery &q = api.requests.first().params;
        QCOMPARE(q.queryItemValue(QStringLiteral("limit")).toInt(),
                 TidalClient::kSimilarArtistsLimit);
        QVERIFY(q.queryItemValue(QStringLiteral("offset")).toInt() == 0);
    }

    // The artists come back in the server's order with their name and picture.
    void parsesTheArtistsInOrder() {
        FakeApi api;
        api.bodies[similarPath()] = page({
            similar(900500011, QStringLiteral("Erste Band"),
                    QStringLiteral("aaaaaaaa-1111-2222-3333-444444444444")),
            similar(900500012, QStringLiteral("Zweite Band")),
            similar(900500013, QStringLiteral("Dritte Band"),
                    QStringLiteral("bbbbbbbb-1111-2222-3333-444444444444")),
        });
        TidalClient client{&api};
        QList<Artist> got;
        QString err = QStringLiteral("unset");
        client.fetchSimilarArtists(kArtistId, [&](QList<Artist> a, QString e) { got = a; err = e; });

        QVERIFY(err.isEmpty());
        QCOMPARE(idsOf(got), (QList<qint64>{900500011, 900500012, 900500013}));
        QCOMPARE(got.at(0).name, QStringLiteral("Erste Band"));
        QCOMPARE(got.at(0).picture, QStringLiteral("aaaaaaaa-1111-2222-3333-444444444444"));
        // A null picture is no picture, not the string "null".
        QVERIFY(got.at(1).picture.isEmpty());
    }

    // An artist Tidal has no similar list for answers 404. The page gets the
    // error and an empty list, and hides the row.
    void aRefusalIsAnEmptyListWithTheReason() {
        FakeApi api;
        api.errors[similarPath()] = QStringLiteral("server replied: Not Found");
        TidalClient client{&api};
        QList<Artist> got{Artist{}};
        QString err;
        client.fetchSimilarArtists(kArtistId, [&](QList<Artist> a, QString e) { got = a; err = e; });

        QVERIFY(got.isEmpty());
        QCOMPARE(err, QStringLiteral("server replied: Not Found"));
    }

    // The artist detail does not ask for the similar list, so the header and
    // the bio never wait on it.
    void theDetailDoesNotWaitForTheSimilarList() {
        FakeApi api;
        api.holdSimilar = true;
        QJsonObject artist;
        artist["id"]   = kArtistId;
        artist["name"] = QStringLiteral("Eine Band");
        api.bodies[QStringLiteral("artists/%1").arg(kArtistId)] = artist;
        QJsonObject bio;
        bio["text"] = QStringLiteral("Eine Band spielt.");
        api.bodies[QStringLiteral("artists/%1/bio").arg(kArtistId)] = bio;
        TidalClient client{&api};
        int replies = 0;
        client.fetchArtistDetail(kArtistId, [&](ArtistDetail d, QString err) {
            ++replies;
            QVERIFY(err.isEmpty());
            QCOMPARE(d.bio, QStringLiteral("Eine Band spielt."));
        });

        QCOMPARE(replies, 1);
        QVERIFY(!api.endpoints().contains(similarPath()));
    }

    // What QML gets: id, name and a cover URL where there is a picture.
    void theBridgeHandsQmlTheCards() {
        FakeApi api;
        api.bodies[similarPath()] = page({
            similar(900500011, QStringLiteral("Erste Band"),
                    QStringLiteral("aaaaaaaa-1111-2222-3333-444444444444")),
            similar(900500012, QStringLiteral("Zweite Band")),
        });
        Harness h(&api);
        h.bridge.fetchSimilarArtists(kArtistId, h.callback());

        QCOMPARE(h.seen.property(QStringLiteral("calls")).toInt(), 1);
        QCOMPARE(h.seen.property(QStringLiteral("err")).toString(), QString());
        QCOMPARE(h.seen.property(QStringLiteral("ids")).toString(),
                 QStringLiteral("900500011,900500012"));
        QCOMPARE(h.seen.property(QStringLiteral("names")).toString(),
                 QStringLiteral("Erste Band|Zweite Band"));
        QCOMPARE(h.seen.property(QStringLiteral("covers")).toString(),
                 QStringLiteral("https://resources.tidal.com/images/aaaaaaaa/1111/2222/3333/444444444444/320x320.jpg|"));
    }

    void theBridgePassesARefusalOn() {
        FakeApi api;
        api.errors[similarPath()] = QStringLiteral("server replied: Not Found");
        Harness h(&api);
        h.bridge.fetchSimilarArtists(kArtistId, h.callback());

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
                "(function (s) { return function (artists, err) {"
                " s.calls  = s.calls + 1;"
                " s.err    = String(err);"
                " s.ids    = artists.map(function (a) { return a.id }).join(',');"
                " s.names  = artists.map(function (a) { return a.name }).join('|');"
                " s.covers = artists.map(function (a) { return a.coverUrl || '' }).join('|'); }; })"))
                       .call({seen});
        }
    };

    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestSimilarArtists)
#include "tst_similar_artists.moc"
