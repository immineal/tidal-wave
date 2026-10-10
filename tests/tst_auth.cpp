#include <QTest>
#include <QDateTime>
#include <QJsonObject>
#include <QTimeZone>
#include "api/Auth.h"

// Tidal's users/{id} response puts the account's *email address* in "username"
// on most accounts, so the sidebar was showing an address where a name belongs.
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

        // A first name, no last name, no profile name, an address in "username".
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
    //
    // The expiry is the one persisted value whose meaning must not depend on
    // where the machine was when it was written. Stored as a bare wall clock
    // it does: read back one timezone to the east a live token looks expired,
    // one to the west a dead one looks current. Both land in
    // refreshAccessToken() and recover while the refresh token holds, so the
    // cost is a wasted round trip rather than a sign-out - but the stored
    // instant should still be an instant.

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

        // January, so the two offsets are +01:00 and -05:00 and no DST rule
        // can make them agree by accident.
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

    // Every credentials.json written before the change above holds a bare wall
    // clock. It is still read as the local time it was written as, so an
    // upgraded install sits exactly where it sat; the next save rewrites it.
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
};

QTEST_APPLESS_MAIN(TestAuth)
#include "tst_auth.moc"
