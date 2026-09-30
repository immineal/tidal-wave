// UpdateCheck: version ordering, release parsing, and the rules that decide
// whether a launch offers an update at all.
//
// Nothing here touches the network. UpdateCheck::sendRequest() is the single
// place that does, so the fixture overrides it and feeds replies in by hand;
// every other decision is a pure static function and is called directly.

#include <QTest>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QDateTime>

#include "ui/UpdateCheck.h"

namespace {

// -1, 0 or +1, so a comparison test does not depend on the magnitude.
int sgn(int v) { return v < 0 ? -1 : (v > 0 ? 1 : 0); }

QByteArray releaseJson(const QString &tag,
                       const QString &url = QStringLiteral("https://github.com/immineal/tidal-wave/releases/tag/x"),
                       bool draft = false,
                       bool prerelease = false)
{
    return QStringLiteral(R"({"tag_name":"%1","html_url":"%2","draft":%3,"prerelease":%4,"name":"release"})")
        .arg(tag, url,
             draft ? QStringLiteral("true") : QStringLiteral("false"),
             prerelease ? QStringLiteral("true") : QStringLiteral("false"))
        .toUtf8();
}

// Stands in for GitHub. Counts the requests UpdateCheck would have made and
// lets a test hand back whatever reply it wants to exercise.
class OfflineUpdateCheck : public UpdateCheck {
public:
    int  requests = 0;
    QUrl lastUrl;

    void deliver(int httpStatus, const QByteArray &body, bool rateLimited = false) {
        handleReply(httpStatus, body, rateLimited);
    }

protected:
    void sendRequest(const QUrl &url) override { ++requests; lastUrl = url; }
};

} // namespace

class TestUpdate : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_update"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void init() {
        // Every test starts from the settings file a fresh install has.
        QSettings().clear();
        QSettings().sync();
    }

    // ── version ordering ─────────────────────────────────────────────────

    void compareVersions_data() {
        QTest::addColumn<QString>("a");
        QTest::addColumn<QString>("b");
        QTest::addColumn<int>("expected");

        QTest::newRow("identical")          << "1.2.3"   << "1.2.3"   << 0;
        QTest::newRow("leading v")          << "v1.2.3"  << "1.2.3"   << 0;
        QTest::newRow("leading v both")     << "v1.2.3"  << "V1.2.3"  << 0;
        QTest::newRow("surrounding space")  << " v1.2.3 "<< "1.2.3"   << 0;

        QTest::newRow("newer patch")        << "0.4.1"   << "0.4.0"   << 1;
        QTest::newRow("newer minor")        << "0.5.0"   << "0.4.9"   << 1;
        QTest::newRow("newer major")        << "1.0.0"   << "0.99.99" << 1;
        QTest::newRow("older patch")        << "0.4.0"   << "0.4.1"   << -1;

        // The whole reason this is not a string compare.
        QTest::newRow("0.10.0 beats 0.9.0") << "0.10.0"  << "0.9.0"   << 1;
        QTest::newRow("1.0.10 beats 1.0.9") << "1.0.10"  << "1.0.9"   << 1;
        QTest::newRow("10.0.0 beats 9.9.9") << "10.0.0"  << "9.9.9"   << 1;

        // Missing trailing components read as zero, extra ones still count.
        QTest::newRow("short equals long")  << "1.2"     << "1.2.0"   << 0;
        QTest::newRow("bare major")         << "2"       << "2.0.0"   << 0;
        QTest::newRow("fourth component")   << "1.2.3.1" << "1.2.3"   << 1;
        QTest::newRow("fourth is zero")     << "1.2.3.0" << "1.2.3"   << 0;

        // A prerelease is older than the release it leads up to.
        QTest::newRow("prerelease older")   << "1.0.0-beta.2" << "1.0.0" << -1;
        QTest::newRow("stable newer")       << "1.0.0"   << "1.0.0-rc.1"     << 1;
        QTest::newRow("beta 2 over beta 1") << "1.0.0-beta.2" << "1.0.0-beta.1" << 1;
        QTest::newRow("alpha before beta")  << "1.0.0-alpha"  << "1.0.0-beta"   << -1;
        QTest::newRow("numeric id first")   << "1.0.0-1" << "1.0.0-alpha"      << -1;
        QTest::newRow("fewer ids older")    << "1.0.0-beta" << "1.0.0-beta.1"  << -1;
        // ...but the core still decides first.
        QTest::newRow("core outranks tag")  << "1.0.0-beta.1" << "0.9.0" << 1;

        QTest::newRow("build metadata")     << "1.2.3+d1e8a" << "1.2.3" << 0;

        QTest::newRow("empty is oldest")    << ""        << "0.0.1"   << -1;
        QTest::newRow("both empty")         << ""        << ""        << 0;
        QTest::newRow("garbage")            << "not-a-version" << "0.0.1" << -1;
        QTest::newRow("garbage both sides") << "banana"  << "banana"  << 0;
        QTest::newRow("garbage vs empty")   << "banana"  << ""        << 0;
    }

    void compareVersions() {
        QFETCH(QString, a);
        QFETCH(QString, b);
        QFETCH(int, expected);
        QCOMPARE(sgn(UpdateCheck::compareVersions(a, b)), expected);
        // Reversing the arguments has to reverse the answer, always.
        QCOMPARE(sgn(UpdateCheck::compareVersions(b, a)), -expected);
    }

    // ── parsing a release payload ────────────────────────────────────────

    void parsesTagAndUrl() {
        const auto r = UpdateCheck::parseRelease(
            releaseJson(QStringLiteral("v0.4.1"),
                        QStringLiteral("https://github.com/immineal/tidal-wave/releases/tag/v0.4.1")));
        QVERIFY(r.isValid());
        QCOMPARE(r.tag, QStringLiteral("v0.4.1"));
        QCOMPARE(r.url, QStringLiteral("https://github.com/immineal/tidal-wave/releases/tag/v0.4.1"));
    }

    // A release with no html_url still has somewhere sensible to send people.
    void missingUrlFallsBackToTheReleasesPage() {
        const auto r = UpdateCheck::parseRelease(R"({"tag_name":"v0.4.1"})");
        QVERIFY(r.isValid());
        QVERIFY(r.url.startsWith(QStringLiteral("https://github.com/")));
        QCOMPARE(r.url, UpdateCheck::releasesPageUrl());
    }

    void badPayloadsYieldNoUpdate_data() {
        QTest::addColumn<QByteArray>("payload");
        QTest::newRow("empty")            << QByteArray();
        QTest::newRow("whitespace")       << QByteArray("   \n ");
        QTest::newRow("truncated")        << QByteArray(R"({"tag_name": "v0.4.1")");
        QTest::newRow("not json")         << QByteArray("<html>502 Bad Gateway</html>");
        QTest::newRow("json array")       << QByteArray("[]");
        QTest::newRow("json string")      << QByteArray("\"v0.4.1\"");
        QTest::newRow("no tag")           << QByteArray("{\"html_url\":\"https://example.invalid\"}");
        QTest::newRow("empty tag")        << QByteArray(R"({"tag_name":""})");
        QTest::newRow("tag wrong type")   << QByteArray(R"({"tag_name":41})");
        QTest::newRow("github error")     << QByteArray(R"({"message":"Not Found"})");
    }

    void badPayloadsYieldNoUpdate() {
        QFETCH(QByteArray, payload);
        const auto r = UpdateCheck::parseRelease(payload);
        QVERIFY(!r.isValid());
        QVERIFY(r.tag.isEmpty());
    }

    // Drafts are not public yet and prereleases are not for stable builds, so
    // neither one is a release this app knows about.
    void draftsAndPrereleasesAreNotReleases() {
        QVERIFY(!UpdateCheck::parseRelease(
            releaseJson(QStringLiteral("v0.5.0"), QStringLiteral("https://example.invalid"), true, false)).isValid());
        QVERIFY(!UpdateCheck::parseRelease(
            releaseJson(QStringLiteral("v0.5.0"), QStringLiteral("https://example.invalid"), false, true)).isValid());
        QVERIFY(UpdateCheck::parseRelease(
            releaseJson(QStringLiteral("v0.5.0"), QStringLiteral("https://example.invalid"), false, false)).isValid());
    }

    // ── what gets offered ────────────────────────────────────────────────

    void offersOnlyNewerStableVersions() {
        const QString current = QStringLiteral("0.4.0");
        QVERIFY( UpdateCheck::shouldOffer(QStringLiteral("v0.4.1"),  current, QString()));
        QVERIFY( UpdateCheck::shouldOffer(QStringLiteral("0.10.0"),  current, QString()));
        QVERIFY(!UpdateCheck::shouldOffer(QStringLiteral("v0.4.0"),  current, QString()));
        QVERIFY(!UpdateCheck::shouldOffer(QStringLiteral("0.3.9"),   current, QString()));
        QVERIFY(!UpdateCheck::shouldOffer(QString(),                 current, QString()));
        // A prerelease is never pushed at a stable build, even a much newer one.
        QVERIFY(!UpdateCheck::shouldOffer(QStringLiteral("v1.0.0-beta.2"), current, QString()));
        // Someone already running a prerelease is a different matter.
        QVERIFY(UpdateCheck::shouldOffer(QStringLiteral("v1.0.0-beta.2"),
                                         QStringLiteral("1.0.0-beta.1"), QString()));
    }

    void skippedVersionIsNeverOfferedAgain() {
        const QString current = QStringLiteral("0.4.0");
        const QString skipped = QStringLiteral("v0.4.1");
        QVERIFY(!UpdateCheck::shouldOffer(QStringLiteral("v0.4.1"), current, skipped));
        QVERIFY(!UpdateCheck::shouldOffer(QStringLiteral("0.4.1"),  current, skipped));   // same tag, no v
        // ...but skipping one version is not skipping every version after it.
        QVERIFY(UpdateCheck::shouldOffer(QStringLiteral("v0.4.2"),  current, skipped));
        QVERIFY(UpdateCheck::shouldOffer(QStringLiteral("v0.5.0"),  current, skipped));
        QVERIFY(UpdateCheck::shouldOffer(QStringLiteral("v0.10.0"), current, skipped));
    }

    // ── the 24h throttle ─────────────────────────────────────────────────

    void isDue_data() {
        QTest::addColumn<int>("minutesAgo");
        QTest::addColumn<bool>("due");
        QTest::newRow("just now")      << 0            << false;
        QTest::newRow("an hour ago")   << 60           << false;
        QTest::newRow("23h ago")       << 23 * 60      << false;
        QTest::newRow("24h ago")       << 24 * 60      << true;
        QTest::newRow("a week ago")    << 7 * 24 * 60  << true;
    }

    void isDue() {
        QFETCH(int, minutesAgo);
        QFETCH(bool, due);
        const QDateTime now = QDateTime::currentDateTimeUtc();
        QCOMPARE(UpdateCheck::isDue(now.addSecs(-60ll * minutesAgo), now), due);
    }

    void isDueOnFirstLaunchAndAfterAClockJump() {
        const QDateTime now = QDateTime::currentDateTimeUtc();
        QVERIFY(UpdateCheck::isDue(QDateTime(), now));              // never checked
        // A timestamp from the future would otherwise lock the check out for
        // good, which is how a clock correction turns into a silent bug.
        QVERIFY(UpdateCheck::isDue(now.addDays(3), now));
    }

    void throttleStopsARepeatLaunch() {
        {
            QSettings s;
            s.setValue(QStringLiteral("update/lastCheck"), QDateTime::currentDateTimeUtc().addSecs(-3600));
        }
        OfflineUpdateCheck fresh;
        fresh.startupCheck();
        QCOMPARE(fresh.requests, 0);

        {
            QSettings s;
            s.setValue(QStringLiteral("update/lastCheck"), QDateTime::currentDateTimeUtc().addDays(-2));
        }
        OfflineUpdateCheck stale;
        stale.startupCheck();
        QCOMPARE(stale.requests, 1);
        QCOMPARE(stale.lastUrl, UpdateCheck::releasesApiUrl());
    }

    // ── the switch ───────────────────────────────────────────────────────

    void enabledByDefault() {
        OfflineUpdateCheck u;
        QVERIFY(u.enabled());
    }

    void disablingStopsTheCheck() {
        OfflineUpdateCheck u;
        u.setEnabled(false);
        u.startupCheck();
        u.checkNow();
        QCOMPARE(u.requests, 0);

        // ...and it stays off across a restart.
        OfflineUpdateCheck again;
        QVERIFY(!again.enabled());
        again.startupCheck();
        QCOMPARE(again.requests, 0);
    }

    // An update found before the switch was thrown must stop being offered.
    void disablingHidesAPendingOffer() {
        {
            QSettings s;
            s.setValue(QStringLiteral("update/latestVersion"), QStringLiteral("v99.0.0"));
            s.setValue(QStringLiteral("update/releaseUrl"), QStringLiteral("https://example.invalid/r"));
        }
        OfflineUpdateCheck u;
        QVERIFY(u.updateAvailable());
        QSignalSpy spy(&u, &UpdateCheck::updateChanged);
        u.setEnabled(false);
        QVERIFY(!u.updateAvailable());
        QCOMPARE(spy.count(), 1);
    }

    // ── a whole check, end to end, with the network faked out ────────────

    void aSuccessfulCheckOffersTheRelease() {
        OfflineUpdateCheck u;
        QSignalSpy spy(&u, &UpdateCheck::updateChanged);
        u.startupCheck();
        QCOMPARE(u.requests, 1);                       // never checked before

        u.deliver(200, releaseJson(QStringLiteral("v99.0.0"),
                                   QStringLiteral("https://example.invalid/r/v99.0.0")));
        QVERIFY(u.updateAvailable());
        QCOMPARE(u.latestVersion(), QStringLiteral("v99.0.0"));
        QCOMPARE(u.releaseUrl(), QStringLiteral("https://example.invalid/r/v99.0.0"));
        QCOMPARE(spy.count(), 1);

        // The answer is cached, so the next launch costs nothing...
        OfflineUpdateCheck next;
        next.startupCheck();
        QCOMPARE(next.requests, 0);
        QVERIFY(next.updateAvailable());
        QCOMPARE(next.latestVersion(), QStringLiteral("v99.0.0"));
    }

    // The latest release being the one already installed is the common case,
    // and it is cached like any other; it simply is not offered.
    void thisVersionIsNotAnUpdate() {
        OfflineUpdateCheck u;
        u.startupCheck();
        u.deliver(200, releaseJson(QStringLiteral(TIDALWAVE_VERSION)));
        QVERIFY(!u.updateAvailable());
        QCOMPARE(u.latestVersion(), QStringLiteral(TIDALWAVE_VERSION));
    }

    void skipPersistsAcrossLaunches() {
        OfflineUpdateCheck u;
        u.startupCheck();
        u.deliver(200, releaseJson(QStringLiteral("v99.0.0")));
        QVERIFY(u.updateAvailable());
        u.skipThisVersion();
        QVERIFY(!u.updateAvailable());

        OfflineUpdateCheck next;
        QVERIFY(!next.updateAvailable());
        // A later release is still worth mentioning.
        next.checkNow();
        next.deliver(200, releaseJson(QStringLiteral("v99.1.0")));
        QVERIFY(next.updateAvailable());
        QCOMPARE(next.latestVersion(), QStringLiteral("v99.1.0"));
    }

    // "Later" drops the offer for now and waits for the next check to bring
    // it back, so the prompt returns on a later launch rather than this one.
    void laterDefersToTheNextCheck() {
        OfflineUpdateCheck u;
        u.startupCheck();
        u.deliver(200, releaseJson(QStringLiteral("v99.0.0")));
        u.remindLater();
        QVERIFY(!u.updateAvailable());

        OfflineUpdateCheck next;
        QVERIFY(!next.updateAvailable());
        next.startupCheck();
        QCOMPARE(next.requests, 0);          // still inside the 24h window
        next.checkNow();                     // ...the next check that does run
        next.deliver(200, releaseJson(QStringLiteral("v99.0.0")));
        QVERIFY(next.updateAvailable());     // and the offer is back
    }

    // ── failures stay silent ─────────────────────────────────────────────

    void failuresNeverOfferAnything_data() {
        QTest::addColumn<int>("status");
        QTest::addColumn<QByteArray>("body");
        QTest::newRow("no connection")  << 0   << QByteArray();
        QTest::newRow("not found")      << 404 << QByteArray(R"({"message":"Not Found"})");
        QTest::newRow("server error")   << 500 << QByteArray("<html>oops</html>");
        QTest::newRow("ok but broken")  << 200 << QByteArray("<html>captive portal</html>");
    }

    void failuresNeverOfferAnything() {
        QFETCH(int, status);
        QFETCH(QByteArray, body);
        OfflineUpdateCheck u;
        u.startupCheck();
        u.deliver(status, body);
        QVERIFY(!u.updateAvailable());
        QVERIFY(u.latestVersion().isEmpty());
    }

    // A transport failure leaves the timestamp alone, so coming back online
    // is enough to get a check; being rate limited does not retry for a day.
    void rateLimitBacksOffButOfflineRetries() {
        OfflineUpdateCheck offline;
        offline.startupCheck();
        offline.deliver(0, QByteArray());
        OfflineUpdateCheck afterOffline;
        afterOffline.startupCheck();
        QCOMPARE(afterOffline.requests, 1);

        QSettings().clear();
        OfflineUpdateCheck limited;
        limited.startupCheck();
        limited.deliver(403, QByteArray(R"({"message":"API rate limit exceeded"})"), true);
        QVERIFY(!limited.updateAvailable());
        OfflineUpdateCheck afterLimit;
        afterLimit.startupCheck();
        QCOMPARE(afterLimit.requests, 0);
    }

    // A cached release that is no longer newer than the running build, because
    // the user updated, must not keep the prompt alive.
    void anInstalledUpdateStopsBeingOffered() {
        {
            QSettings s;
            s.setValue(QStringLiteral("update/latestVersion"), QStringLiteral(TIDALWAVE_VERSION));
            s.setValue(QStringLiteral("update/releaseUrl"), QStringLiteral("https://example.invalid/r"));
        }
        OfflineUpdateCheck u;
        QVERIFY(!u.updateAvailable());
    }

    void theApiUrlPointsAtGitHub() {
        QCOMPARE(UpdateCheck::releasesApiUrl().host(), QStringLiteral("api.github.com"));
        QVERIFY(UpdateCheck::releasesApiUrl().path().endsWith(QStringLiteral("/releases/latest")));
        QVERIFY(!UpdateCheck::userAgent().isEmpty());   // GitHub rejects requests without one
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestUpdate)
#include "tst_update.moc"
