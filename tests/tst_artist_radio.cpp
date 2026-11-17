// An artist's radio: `artists/<id>` names it under `mixes.ARTIST_MIX`, the
// way a track names its own under TRACK_MIX. The page opens it on MixPage.
// FakeApi overrides TidalApi::get; every id and name below is invented.

#include <QTest>
#include <QCoreApplication>
#include <QHash>
#include <QJSEngine>
#include <QJSValue>
#include <QJsonObject>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUrlQuery>

#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"
#include "api/Models.h"

using namespace Tidal;

namespace {

constexpr qint64 kArtistId = 900600001;

class FakeApi : public TidalApi {
public:
    QHash<QString, QJsonObject> bodies;
    void get(const QString &endpoint, const QUrlQuery &, JsonCallback cb) override {
        cb(bodies.value(endpoint), {});
    }
};

QJsonObject artist(const QJsonObject &mixes) {
    QJsonObject o;
    o["id"]   = kArtistId;
    o["name"] = QStringLiteral("Eine Band");
    if (!mixes.isEmpty()) o["mixes"] = mixes;
    return o;
}

QString artistPath() { return QStringLiteral("artists/%1").arg(kArtistId); }

} // namespace

class TestArtistRadio : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_artist_radio"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
    }

    void theArtistNamesItsRadio() {
        FakeApi api;
        api.bodies[artistPath()] = artist(QJsonObject{
            {QStringLiteral("ARTIST_MIX"), QStringLiteral("00aa11bb22cc33dd44ee55ff6677")}});
        TidalClient client{&api};
        ArtistDetail got;
        client.fetchArtistDetail(kArtistId, [&](ArtistDetail d, QString) { got = d; });
        QCOMPARE(got.artistMixId, QStringLiteral("00aa11bb22cc33dd44ee55ff6677"));
    }

    // Many artists have no radio; nothing is made up for them.
    void anArtistWithoutARadioNamesNone() {
        FakeApi api;
        api.bodies[artistPath()] = artist({});
        TidalClient client{&api};
        ArtistDetail got;
        got.artistMixId = QStringLiteral("unset");
        client.fetchArtistDetail(kArtistId, [&](ArtistDetail d, QString) { got = d; });
        QVERIFY(got.artistMixId.isEmpty());
    }

    void theBridgeHandsTheRadioToQml() {
        FakeApi api;
        api.bodies[artistPath()] = artist(QJsonObject{
            {QStringLiteral("ARTIST_MIX"), QStringLiteral("00aa11bb22cc33dd44ee55ff6677")}});
        QJSEngine engine;
        TidalClient client{&api};
        TidalBridge bridge{&client};
        QJSEngine::setObjectOwnership(&bridge, QJSEngine::CppOwnership);
        QJSValue keep = engine.newQObject(&bridge);
        QJSValue seen = engine.newObject();
        QJSValue cb = engine.evaluate(QStringLiteral(
            "(function (s) { return function (d, err) { s.mix = d.artistMixId; }; })")).call({seen});
        bridge.fetchArtistDetail(kArtistId, cb);
        QCOMPARE(seen.property(QStringLiteral("mix")).toString(),
                 QStringLiteral("00aa11bb22cc33dd44ee55ff6677"));
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestArtistRadio)
#include "tst_artist_radio.moc"
