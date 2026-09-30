#include <QTest>
#include <QJsonObject>
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
                           {"firstName", "Linus"},
                           {"username", "someone@example.com"}}
            << QStringLiteral("waveboy");

        QTest::newRow("real name beats the address")
            << QJsonObject{{"firstName", "Linus"},
                           {"lastName", "Linhof"},
                           {"username", "someone@example.com"}}
            << QStringLiteral("Linus Linhof");

        // The shape of the reporter's own account: a first name, no last name,
        // no profile name, and an address sitting in "username".
        QTest::newRow("first name only")
            << QJsonObject{{"firstName", "Linus"},
                           {"lastName", ""},
                           {"profileName", ""},
                           {"username", "someone@example.com"}}
            << QStringLiteral("Linus");

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
};

QTEST_APPLESS_MAIN(TestAuth)
#include "tst_auth.moc"
