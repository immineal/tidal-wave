#include <QTest>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QTimeZone>
#include <QTimer>
#include "api/Auth.h"
#include "api/TidalApi.h"

namespace {

// Sends nothing. A saved session that is still valid asks for `sessions`
// as soon as it is loaded, and that request must stay in the process.
class SilentApi : public TidalApi {
public:
    int gets = 0;
    void get(const QString &, const QUrlQuery &, JsonCallback) override { ++gets; }
};

} // namespace

// Tidal's users/{id} response carries the account's email address in
// "username" on most accounts. A display name must never be that address.
class TestAuth : public QObject {
    Q_OBJECT

private slots:
    void displayName_data() {
        QTest::addColumn<QJsonObject>("user");
        QTest::addColumn<QString>("expected");

        QTest::newRow("profile name wins")
            << QJsonObject{{"profileName", "waveboy"},
                           {"firstName", "Robin"},
                           {"username", "someone@example.com"}}
            << QStringLiteral("waveboy");

        QTest::newRow("real name beats the address")
            << QJsonObject{{"firstName", "Robin"},
                           {"lastName", "Ashby"},
                           {"username", "someone@example.com"}}
            << QStringLiteral("Robin Ashby");

        QTest::newRow("first name only")
            << QJsonObject{{"firstName", "Robin"},
                           {"lastName", ""},
                           {"profileName", ""},
                           {"username", "someone@example.com"}}
            << QStringLiteral("Robin");

        QTest::newRow("a username without an @ is a real username")
            << QJsonObject{{"username", "waveboy"}}
            << QStringLiteral("waveboy");

        QTest::newRow("nothing usable rather than an address")
            << QJsonObject{{"username", "someone@example.com"}}
            << QString();

        QTest::newRow("empty object")
            << QJsonObject{} << QString();

        QTest::newRow("whitespace is not a name")
            << QJsonObject{{"profileName", "   "}, {"firstName", "  "}, {"lastName", "  "}}
            << QString();
    }

    void displayName() {
        QFETCH(QJsonObject, user);
        QFETCH(QString, expected);
        QCOMPARE(Auth::displayNameFrom(user), expected);
    }

    // ── the token expiry in credentials.json ─────────────────────────────
    // The stored expiry must mean the same instant in every timezone. A bare
    // wall clock read back in another zone names a different instant.

    // What a reader whose system timezone is `zoneId` makes of `stored`. A
    // string that names no offset is a wall clock, and this is exactly what
    // QDateTime does with one: keep the digits, read them in the local zone.
    static QDateTime readIn(const QString &stored, const char *zoneId) {
        QDateTime dt = Auth::expiryFromString(stored);
        if (dt.timeSpec() == Qt::LocalTime)
            dt.setTimeZone(QTimeZone(zoneId));
        return dt;
    }

    void expiryIsStoredAsAnInstant() {
        // Exactly what the refresh handler holds: local time, whole seconds.
        const QDateTime when =
            QDateTime::fromSecsSinceEpoch(QDateTime::currentSecsSinceEpoch() + 3600);
        const QString stored = Auth::expiryToString(when);

        // Two zones whose offsets never agree.
        const QDateTime east = readIn(stored, "Europe/Berlin");
        const QDateTime west = readIn(stored, "America/New_York");

        QVERIFY2(east == west,
                 qPrintable(QStringLiteral("\"%1\" means a different instant in "
                                           "Berlin (%2) than in New York (%3)")
                                .arg(stored, east.toUTC().toString(Qt::ISODate),
                                     west.toUTC().toString(Qt::ISODate))));
        QCOMPARE(east, when);
    }

    void expiryRoundTrips() {
        const QDateTime when =
            QDateTime::fromSecsSinceEpoch(QDateTime::currentSecsSinceEpoch() + 86400);
        // ISO-8601 has no sub-second field here, which is why `when` is built
        // from whole seconds; the real value is whole seconds too.
        QCOMPARE(Auth::expiryFromString(Auth::expiryToString(when)), when);
    }

    // A credentials.json from an older version holds a bare wall clock. It is
    // read as local time, and the next save rewrites it.
    void aStoredWallClockExpiryIsStillRead() {
        const QDateTime legacy = Auth::expiryFromString(QStringLiteral("2027-01-15T12:00:00"));
        QVERIFY(legacy.isValid());
        QCOMPARE(legacy, QDateTime(QDate(2027, 1, 15), QTime(12, 0, 0)));
    }

    void anUnreadableExpiryIsInvalid() {
        QVERIFY(!Auth::expiryFromString(QString()).isValid());
        QVERIFY(!Auth::expiryFromString(QStringLiteral("never")).isValid());
        QVERIFY(Auth::expiryToString(QDateTime()).isEmpty());
    }

    void theRefreshWaitsForAnExpiryFarAhead_data() {
        QTest::addColumn<qint64>("aheadSecs");

        QTest::newRow("an hour")   << qint64(3600);
        // Past what an int of milliseconds holds, about 24.8 days.
        QTest::newRow("30 days")   << qint64(30) * 86400;
        QTest::newRow("50 days")   << qint64(50) * 86400;
        QTest::newRow("a year")    << qint64(365) * 86400;
    }

    // The timer is read and never left to fire: no event loop runs here, so
    // a refresh that is due at once still sends nothing.
    void theRefreshWaitsForAnExpiryFarAhead() {
        QFETCH(qint64, aheadSecs);

        QTemporaryDir home;
        QVERIFY(home.isValid());
        const QByteArray realHome = qgetenv("HOME");
        qputenv("HOME", home.path().toUtf8());
        const auto restore = qScopeGuard([&] { qputenv("HOME", realHome); });

        const QDateTime expiry = QDateTime::fromSecsSinceEpoch(
            QDateTime::currentSecsSinceEpoch() + aheadSecs);
        QVERIFY(QDir(home.path()).mkpath(QStringLiteral(".config/tidal-wave")));
        QFile creds(home.path() + QStringLiteral("/.config/tidal-wave/credentials.json"));
        QVERIFY(creds.open(QIODevice::WriteOnly));
        creds.write(QJsonDocument(QJsonObject{
            {QStringLiteral("access_token"),  QStringLiteral("a")},
            {QStringLiteral("refresh_token"), QStringLiteral("r")},
            {QStringLiteral("expires_at"),    Auth::expiryToString(expiry)},
            {QStringLiteral("user_id"),       1},
            {QStringLiteral("country_code"),  QStringLiteral("DE")},
        }).toJson());
        creds.close();

        SilentApi api;
        Auth auth(&api);
        auth.loadCredentials();
        QCOMPARE(auth.state(), Auth::State::LoggedIn);
        QCOMPARE(api.gets, 1);

        // The poll timer repeats; the refresh timer is the single shot.
        QTimer *refresh = nullptr;
        const auto timers = auth.findChildren<QTimer *>(QString(), Qt::FindDirectChildrenOnly);
        for (QTimer *t : timers)
            if (t->isSingleShot()) refresh = t;
        QVERIFY(refresh);

        // A minute before the expiry, or as long as a timer can wait if that
        // is further off. Ten seconds of slack for a slow machine.
        const qint64 dueMs  = (aheadSecs - 60) * 1000;
        const qint64 day    = qint64(86400) * 1000;
        const qint64 atLeast = qMin(dueMs - 10000, 20 * day);
        QVERIFY2(refresh->isActive(),
                 qPrintable(QStringLiteral("no refresh is scheduled for a token that "
                                           "expires in %1 s").arg(aheadSecs)));
        QVERIFY2(refresh->interval() >= atLeast && refresh->interval() <= dueMs,
                 qPrintable(QStringLiteral("a token that expires in %1 s is refreshed "
                                           "after %2 ms, wanted between %3 and %4")
                                .arg(aheadSecs).arg(refresh->interval())
                                .arg(atLeast).arg(dueMs)));
    }
};

QTEST_GUILESS_MAIN(TestAuth)
#include "tst_auth.moc"
