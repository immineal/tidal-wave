// Handing the current track to a cast device and taking it back. The device
// is a CastSession that never connects, so nothing leaves the machine, and
// stream requests are never answered, so nothing is played here either.

#include <QTest>
#include <QSettings>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#ifdef Q_OS_LINUX
#include "cast/CastSession.h"
#endif
#include "player/Player.h"

namespace {

QVariantList rowsOf(int n) {
    QVariantList out;
    for (qlonglong id = 1; id <= n; ++id) {
        QVariantMap t;
        t[QStringLiteral("id")]       = id;
        t[QStringLiteral("title")]    = QStringLiteral("T%1").arg(id);
        t[QStringLiteral("artists")]  = QStringLiteral("Artist");
        t[QStringLiteral("duration")] = 200;
        out.append(t);
    }
    return out;
}

// Counts the stream requests and answers none of them.
class CountingClient : public TidalClient {
public:
    using TidalClient::TidalClient;
    int asked = 0;
    void fetchStreamManifest(qint64, StreamCb) override { ++asked; }
};

qlonglong currentId(const Player &p) {
    return p.currentTrackMap().value(QStringLiteral("id")).toLongLong();
}

} // namespace

class TestCastHandoff : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_cast_handoff"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

#ifdef Q_OS_LINUX
    // The bar shows where the track was here until the device says otherwise.
    void theDeviceStartsFromTheLocalPosition() {
        TidalApi api;
        CountingClient client{&api};
        Player p{&client};
        QTest::qWait(30);
        p.playTracks(rowsOf(2), 0);
        p.seek(12000);
        QCOMPARE(p.position(), qint64(12000));

        CastSession device;
        p.beginCast(&device);
        QCOMPARE(p.position(), qint64(12000));
        p.endCast();
    }

    // Back from the device, the track goes on where the device left it.
    void takingItBackGoesOnFromTheCastPosition_data() {
        QTest::addColumn<bool>("playingThere");
        QTest::newRow("playing on the device") << true;
        QTest::newRow("paused on the device")  << false;
    }

    void takingItBackGoesOnFromTheCastPosition() {
        QFETCH(bool, playingThere);
        TidalApi api;
        CountingClient client{&api};
        Player p{&client};
        QTest::qWait(30);
        p.playTracks(rowsOf(2), 0);

        CastSession device;
        p.beginCast(&device);
        p.onCastPosition(42.5);
        p.onCastPlaying(playingThere);
        const int askedBefore = client.asked;

        p.endCast();
        QVERIFY(!p.casting());
        QCOMPARE(currentId(p), 1);
        QCOMPARE(p.position(), qint64(42500));
        QCOMPARE(p.playing(), playingThere);
        // A paused track is not fetched until play.
        QCOMPARE(client.asked > askedBefore, playingThere);
    }

    // Under repeat-one a track the device played out starts over there; a
    // press on Next would move on.
    void aTrackThatRanOutOnTheDeviceRepeatsUnderRepeatOne() {
        TidalApi api;
        CountingClient client{&api};
        Player p{&client};
        QTest::qWait(30);
        p.setLoadDelay(400);
        p.playTracks(rowsOf(3), 0);
        p.setRepeatMode(2);

        CastSession device;
        p.beginCast(&device);
        QSignalSpy recast(&p, &Player::castTrackChanged);

        p.onCastFinished();
        QCOMPARE(currentId(p), 1);
        QCOMPARE(recast.count(), 1);

        // Without repeat it moves on at once, with no wait for more steps.
        p.setRepeatMode(0);
        p.onCastFinished();
        QCOMPARE(currentId(p), 2);
        QCOMPARE(recast.count(), 2);
        p.endCast();
    }
#else
    void castingIsLinuxOnly() { QSKIP("casting is built on Linux only"); }
#endif

private:
    QTemporaryDir m_dir;
};

QTEST_MAIN(TestCastHandoff)
#include "tst_cast_handoff.moc"
