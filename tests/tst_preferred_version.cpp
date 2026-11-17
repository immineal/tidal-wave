// Explicit or clean: where search or an artist's top tracks hold a release in
// both versions, the list shows the preferred one. A release of one version
// stays whatever the setting, and so does a saved one. FakeApi overrides
// TidalApi::get; every id, title and name below is invented.

#include <QTest>
#include <QCoreApplication>
#include <QHash>
#include <QJSEngine>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonObject>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUrlQuery>

#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"

namespace {

class FakeApi : public TidalApi {
public:
    QHash<QString, QJsonObject> bodies;
    void get(const QString &endpoint, const QUrlQuery &, JsonCallback cb) override {
        cb(bodies.value(endpoint), {});
    }
};

QJsonArray band() {
    return QJsonArray{QJsonObject{{QStringLiteral("id"), 900700900},
                                  {QStringLiteral("name"), QStringLiteral("Eine Band")}}};
}

QJsonObject track(qint64 id, const QString &title, bool isExplicit, int duration) {
    return QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("title"), title},
                       {QStringLiteral("explicit"), isExplicit},
                       {QStringLiteral("duration"), duration},
                       {QStringLiteral("allowStreaming"), true},
                       {QStringLiteral("streamReady"), true},
                       {QStringLiteral("artists"), band()}};
}

QJsonObject album(qint64 id, const QString &title, bool isExplicit) {
    return QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("title"), title},
                       {QStringLiteral("explicit"), isExplicit},
                       {QStringLiteral("numberOfTracks"), 10},
                       {QStringLiteral("duration"), 2400},
                       {QStringLiteral("allowStreaming"), true},
                       {QStringLiteral("streamReady"), true},
                       {QStringLiteral("artists"), band()}};
}

QJsonObject list(const QList<QJsonObject> &items) {
    QJsonArray a;
    for (const QJsonObject &o : items) a.append(o);
    return QJsonObject{{QStringLiteral("items"), a},
                       {QStringLiteral("totalNumberOfItems"), int(items.size())}};
}

// Explicit and clean of one song and one album, and a song of one version.
QJsonObject searchBody() {
    return QJsonObject{
        {QStringLiteral("tracks"), list({ track(900700001, QStringLiteral("Erstes Lied"), true, 201),
                                          track(900700002, QStringLiteral("Erstes Lied"), false, 200),
                                          track(900700003, QStringLiteral("Nur so"), true, 180) })},
        {QStringLiteral("albums"), list({ album(900700101, QStringLiteral("Nachtfahrt"), false),
                                          album(900700102, QStringLiteral("Nachtfahrt"), true) })},
    };
}

// Saving never reaches a server here: the write answers yes at once.
class SavingClient : public TidalClient {
public:
    using TidalClient::TidalClient;
    void addTrackFavorite(qint64, std::function<void(bool)> cb) override { cb(true); }
};

} // namespace

class TestPreferredVersion : public QObject {
    Q_OBJECT

    struct Harness {
        QJSEngine   engine;
        FakeApi     api;
        SavingClient client{&api};
        TidalBridge bridge{&client};
        QJSValue    keep;
        QJSValue    seen;
        Harness() {
            api.bodies[QStringLiteral("search")] = searchBody();
            api.bodies[QStringLiteral("artists/900700900/toptracks")] = searchBody()[QStringLiteral("tracks")].toObject();
            QJSEngine::setObjectOwnership(&bridge, QJSEngine::CppOwnership);
            keep = engine.newQObject(&bridge);
            seen = engine.newObject();
        }
        QJSValue cb(const QString &body) {
            return engine.evaluate(QStringLiteral("(function (s) { return function (d, err) { %1 }; })")
                                       .arg(body)).call({seen});
        }
        QString search() {
            bridge.search(QStringLiteral("nacht"), cb(QStringLiteral(
                "s.t = d.tracks.map(function (x) { return x.id }).join(',');"
                "s.a = d.albums.map(function (x) { return x.id }).join(',');")));
            return seen.property(QStringLiteral("t")).toString() + QLatin1Char('|')
                 + seen.property(QStringLiteral("a")).toString();
        }
    };

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_preferred_version"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
    }
    void init() { QSettings().clear(); }

    void explicitIsTheDefault() {
        Harness h;
        QVERIFY(h.bridge.preferExplicit());
        QCOMPARE(h.search(), QStringLiteral("900700001,900700003|900700102"));
    }

    void cleanPreferredShowsTheCleanOnes() {
        Harness h;
        h.bridge.setPreferExplicit(false);
        QCOMPARE(h.search(), QStringLiteral("900700002,900700003|900700101"));
    }

    void theChoiceIsKeptAcrossLaunches() {
        {
            Harness h;
            h.bridge.setPreferExplicit(false);
        }
        Harness again;
        QVERIFY(!again.bridge.preferExplicit());
        QVERIFY(!again.client.preferExplicit());
    }

    void anArtistsTopTracksShowThePreferredOne() {
        Harness h;
        h.bridge.setPreferExplicit(false);
        h.bridge.fetchArtistTopTracks(900700900, h.cb(QStringLiteral(
            "s.t = d.map(function (x) { return x.id }).join(',');")));
        QCOMPARE(h.seen.property(QStringLiteral("t")).toString(),
                 QStringLiteral("900700002,900700003"));
    }

    // The one saved stays beside the preferred one; nothing saved is hidden.
    void aSavedVersionIsNeverHidden() {
        Harness h;
        h.bridge.addTrackFavorite(900700002, QJSValue());
        QVERIFY(h.bridge.isTrackFavorite(900700002));
        QCOMPARE(h.search(), QStringLiteral("900700001,900700002,900700003|900700102"));
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestPreferredVersion)
#include "tst_preferred_version.moc"
