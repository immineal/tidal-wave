#include <QTest>
#include <QDateTime>
#include <QJsonObject>
#include <QTimeZone>
#include "api/Auth.h"

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
};

QTEST_GUILESS_MAIN(TestAuth)
#include "tst_auth.moc"
