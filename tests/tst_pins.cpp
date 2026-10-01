// PinStore: the pinned block above the sidebar library (spec P1 to P6).
//
// Written before PinStore.cpp. Two things here are easy to get wrong and
// expensive to notice later: the order is the user's, so it has to come back
// byte for byte after a restart, and the list is per Tidal account, so one
// account must never see another's pins.
//
// Nothing in this file touches the network. PinStore only talks to QSettings,
// and initTestCase() points QSettings at a QTemporaryDir so a test run cannot
// read or scribble on the real install.

#include <QTest>
#include <QSignalSpy>
#include <QSettings>
#include <QTemporaryDir>

#include "ui/PinStore.h"

namespace {

QStringList idsOf(const QVariantList &items) {
    QStringList ids;
    for (const QVariant &v : items) ids << v.toMap().value(QStringLiteral("id")).toString();
    return ids;
}

QStringList keysOf(const QVariantList &items) {
    QStringList keys;
    for (const QVariant &v : items) {
        const QVariantMap m = v.toMap();
        keys << m.value(QStringLiteral("kind")).toString() + QLatin1Char(':')
                + m.value(QStringLiteral("id")).toString();
    }
    return keys;
}

} // namespace

class TestPins : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_pins"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void init() {
        QSettings().clear();
        QSettings().sync();
    }

    // ── the basics ───────────────────────────────────────────────────────

    void addRemoveAndToggle() {
        PinStore p;
        p.setUserId(1001);
        QSignalSpy spy(&p, &PinStore::changed);

        QVERIFY(!p.isPinned(QStringLiteral("album"), QStringLiteral("42")));

        p.pin(QStringLiteral("album"), QStringLiteral("42"), QStringLiteral("Kind of Blue"),
              QStringLiteral("Miles Davis"), QStringLiteral("http://art/42.jpg"));
        QCOMPARE(p.items().size(), 1);
        QVERIFY(p.isPinned(QStringLiteral("album"), QStringLiteral("42")));
        QCOMPARE(spy.count(), 1);

        const QVariantMap m = p.items().first().toMap();
        QCOMPARE(m.value(QStringLiteral("kind")).toString(), QStringLiteral("album"));
        QCOMPARE(m.value(QStringLiteral("id")).toString(), QStringLiteral("42"));
        QCOMPARE(m.value(QStringLiteral("title")).toString(), QStringLiteral("Kind of Blue"));
        QCOMPARE(m.value(QStringLiteral("subtitle")).toString(), QStringLiteral("Miles Davis"));
        QCOMPARE(m.value(QStringLiteral("imageUrl")).toString(), QStringLiteral("http://art/42.jpg"));

        p.unpin(QStringLiteral("album"), QStringLiteral("42"));
        QVERIFY(p.items().isEmpty());
        QVERIFY(!p.isPinned(QStringLiteral("album"), QStringLiteral("42")));
        QCOMPARE(spy.count(), 2);

        // Unpinning something that is not pinned is a no-op, not a signal.
        p.unpin(QStringLiteral("album"), QStringLiteral("42"));
        QCOMPARE(spy.count(), 2);

        p.toggle(QStringLiteral("artist"), QStringLiteral("7"), QStringLiteral("Portishead"),
                 QString(), QString());
        QVERIFY(p.isPinned(QStringLiteral("artist"), QStringLiteral("7")));
        p.toggle(QStringLiteral("artist"), QStringLiteral("7"), QStringLiteral("Portishead"),
                 QString(), QString());
        QVERIFY(!p.isPinned(QStringLiteral("artist"), QStringLiteral("7")));
        QCOMPARE(spy.count(), 4);
    }

    // The same id under two kinds is two different things, and neither of them
    // may appear twice however often it is pinned.
    void pinningTwiceDoesNotDuplicate() {
        PinStore p;
        p.setUserId(1001);

        p.pin(QStringLiteral("album"), QStringLiteral("5"), QStringLiteral("Spirit"),
              QString(), QString());
        p.pin(QStringLiteral("album"), QStringLiteral("5"), QStringLiteral("Spirit"),
              QString(), QString());
        p.pin(QStringLiteral("album"), QStringLiteral("5"), QStringLiteral("Spirit"),
              QString(), QString());
        QCOMPARE(p.items().size(), 1);

        // A playlist that happens to share the id string is its own pin.
        p.pin(QStringLiteral("playlist"), QStringLiteral("5"), QStringLiteral("Drive"),
              QString(), QString());
        QCOMPARE(p.items().size(), 2);
        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("album:5"), QStringLiteral("playlist:5")}));

        // Re-pinning must not move it either: the order belongs to the user.
        p.pin(QStringLiteral("album"), QStringLiteral("5"), QStringLiteral("Spirit"),
              QString(), QString());
        QCOMPARE(idsOf(p.items()).first(), QStringLiteral("5"));
        QCOMPARE(p.items().first().toMap().value(QStringLiteral("kind")).toString(),
                 QStringLiteral("album"));
    }

    // ── order is user-defined, so it has to be durable ───────────────────

    void orderSurvivesARestart() {
        {
            PinStore p;
            p.setUserId(1001);
            p.pin(QStringLiteral("album"),    QStringLiteral("a"), QStringLiteral("Album A"),  QString(), QString());
            p.pin(QStringLiteral("playlist"), QStringLiteral("b"), QStringLiteral("List B"),   QString(), QString());
            p.pin(QStringLiteral("artist"),   QStringLiteral("c"), QStringLiteral("Artist C"), QString(), QString());
            p.pin(QStringLiteral("mix"),      QStringLiteral("d"), QStringLiteral("Mix D"),    QString(), QString());
            p.move(3, 0);     // d a b c
            p.move(1, 2);     // d b a c
            QCOMPARE(idsOf(p.items()), QStringList({"d", "b", "a", "c"}));
        }

        PinStore reopened;
        reopened.setUserId(1001);
        QCOMPARE(idsOf(reopened.items()), QStringList({"d", "b", "a", "c"}));
        // ...and the payload, not only the order.
        QCOMPARE(reopened.items().first().toMap().value(QStringLiteral("title")).toString(),
                 QStringLiteral("Mix D"));
        QCOMPARE(reopened.items().first().toMap().value(QStringLiteral("kind")).toString(),
                 QStringLiteral("mix"));
    }

    void moveToFrontToBackAndNowhere() {
        PinStore p;
        p.setUserId(1001);
        for (const QString &id : {QStringLiteral("a"), QStringLiteral("b"),
                                  QStringLiteral("c"), QStringLiteral("d")})
            p.pin(QStringLiteral("album"), id, id.toUpper(), QString(), QString());
        QCOMPARE(idsOf(p.items()), QStringList({"a", "b", "c", "d"}));

        QSignalSpy spy(&p, &PinStore::changed);

        p.move(2, 0);
        QCOMPARE(idsOf(p.items()), QStringList({"c", "a", "b", "d"}));

        p.move(0, 3);
        QCOMPARE(idsOf(p.items()), QStringList({"a", "b", "d", "c"}));

        QCOMPARE(spy.count(), 2);

        // Dropping an item back where it came from changes nothing and must
        // not churn the model, or the drag handler repaints on every pixel.
        p.move(1, 1);
        QCOMPARE(idsOf(p.items()), QStringList({"a", "b", "d", "c"}));
        QCOMPARE(spy.count(), 2);

        // Out of range indices are ignored rather than crashing a drag that
        // ended outside the list.
        p.move(-1, 2);
        p.move(2, 99);
        p.move(99, 0);
        QCOMPARE(idsOf(p.items()), QStringList({"a", "b", "d", "c"}));
        QCOMPARE(spy.count(), 2);
    }

    // ── one list per account (P6) ────────────────────────────────────────

    void accountsDoNotSeeEachOther() {
        PinStore p;
        p.setUserId(1001);
        p.pin(QStringLiteral("album"), QStringLiteral("one"), QStringLiteral("One"), QString(), QString());
        p.pin(QStringLiteral("mix"),   QStringLiteral("two"), QStringLiteral("Two"), QString(), QString());

        p.setUserId(2002);
        QVERIFY(p.items().isEmpty());
        QVERIFY(!p.isPinned(QStringLiteral("album"), QStringLiteral("one")));
        p.pin(QStringLiteral("artist"), QStringLiteral("nine"), QStringLiteral("Nine"), QString(), QString());
        QCOMPARE(idsOf(p.items()), QStringList({"nine"}));

        // Back to the first account, untouched.
        p.setUserId(1001);
        QCOMPARE(idsOf(p.items()), QStringList({"one", "two"}));

        // And a second store opened on the second account agrees.
        PinStore other;
        other.setUserId(2002);
        QCOMPARE(idsOf(other.items()), QStringList({"nine"}));
    }

    void switchingAccountAnnouncesTheChange() {
        PinStore p;
        p.setUserId(1001);
        QSignalSpy spy(&p, &PinStore::changed);
        p.setUserId(2002);
        QCOMPARE(spy.count(), 1);
        p.setUserId(2002);          // same account, no churn
        QCOMPARE(spy.count(), 1);
    }

    // ── bad input ────────────────────────────────────────────────────────

    void unknownKindIsRejected() {
        PinStore p;
        p.setUserId(1001);

        p.pin(QStringLiteral("podcast"), QStringLiteral("1"), QStringLiteral("Show"), QString(), QString());
        p.pin(QStringLiteral("track"),   QStringLiteral("2"), QStringLiteral("Song"), QString(), QString());
        p.pin(QString(),                 QStringLiteral("3"), QStringLiteral("Huh"),  QString(), QString());
        p.toggle(QStringLiteral("video"), QStringLiteral("4"), QStringLiteral("Clip"), QString(), QString());
        QVERIFY(p.items().isEmpty());
        QVERIFY(!p.isPinned(QStringLiteral("podcast"), QStringLiteral("1")));

        // An empty id is not a thing either.
        p.pin(QStringLiteral("album"), QString(), QStringLiteral("Nameless"), QString(), QString());
        QVERIFY(p.items().isEmpty());

        // The four real kinds all go in.
        p.pin(QStringLiteral("album"),    QStringLiteral("1"), QStringLiteral("A"), QString(), QString());
        p.pin(QStringLiteral("playlist"), QStringLiteral("2"), QStringLiteral("P"), QString(), QString());
        p.pin(QStringLiteral("artist"),   QStringLiteral("3"), QStringLiteral("R"), QString(), QString());
        p.pin(QStringLiteral("mix"),      QStringLiteral("4"), QStringLiteral("M"), QString(), QString());
        QCOMPARE(p.items().size(), 4);
    }

    void corruptStoredValueIsSurvivable_data() {
        QTest::addColumn<QVariant>("stored");
        QTest::newRow("not json")        << QVariant(QStringLiteral("}{ this is not json"));
        QTest::newRow("empty string")    << QVariant(QString());
        QTest::newRow("json but a map")  << QVariant(QStringLiteral("{\"kind\":\"album\"}"));
        QTest::newRow("wrong type")      << QVariant(42);
        QTest::newRow("truncated")       << QVariant(QStringLiteral("[{\"kind\":\"album\",\"id\":"));
        QTest::newRow("scalars inside")  << QVariant(QStringLiteral("[1,\"two\",null,true]"));
        QTest::newRow("rows missing id") << QVariant(QStringLiteral("[{\"kind\":\"album\"},{\"id\":\"9\"}]"));
        QTest::newRow("bad kind inside") << QVariant(QStringLiteral("[{\"kind\":\"podcast\",\"id\":\"9\"}]"));
        QTest::newRow("binary")          << QVariant(QByteArray("\x01\x02\x00\xff", 4));
    }

    void corruptStoredValueIsSurvivable() {
        QFETCH(QVariant, stored);
        { QSettings s; s.setValue(QStringLiteral("user_1001/pins"), stored); }

        PinStore p;
        p.setUserId(1001);
        QVERIFY(p.items().isEmpty());

        // ...and the store still works afterwards, rather than staying wedged.
        p.pin(QStringLiteral("album"), QStringLiteral("7"), QStringLiteral("Seven"), QString(), QString());
        QCOMPARE(idsOf(p.items()), QStringList({"7"}));

        PinStore reopened;
        reopened.setUserId(1001);
        QCOMPARE(idsOf(reopened.items()), QStringList({"7"}));
    }

    // A list written by some other build with the same entry twice must not
    // produce two rows in the pinned block.
    void duplicatesInStorageAreCollapsedOnLoad() {
        { QSettings s; s.setValue(QStringLiteral("user_1001/pins"),
            QStringLiteral("[{\"kind\":\"album\",\"id\":\"3\",\"title\":\"Three\"},"
                           "{\"kind\":\"album\",\"id\":\"3\",\"title\":\"Three again\"},"
                           "{\"kind\":\"mix\",\"id\":\"3\",\"title\":\"Mix three\"}]")); }
        PinStore p;
        p.setUserId(1001);
        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("album:3"), QStringLiteral("mix:3")}));
        QCOMPARE(p.items().first().toMap().value(QStringLiteral("title")).toString(),
                 QStringLiteral("Three"));
    }

    // LibraryIndex asks for this to keep a pinned entry out of the list below
    // the pinned block (P5), so it has to agree with items().
    void indexOfMatchesTheVisibleOrder() {
        PinStore p;
        p.setUserId(1001);
        p.pin(QStringLiteral("album"),  QStringLiteral("a"), QStringLiteral("A"), QString(), QString());
        p.pin(QStringLiteral("mix"),    QStringLiteral("b"), QStringLiteral("B"), QString(), QString());
        p.pin(QStringLiteral("artist"), QStringLiteral("c"), QStringLiteral("C"), QString(), QString());
        p.move(2, 0);

        const QStringList keys = keysOf(p.items());
        for (int i = 0; i < keys.size(); ++i) {
            const QStringList parts = keys.at(i).split(QLatin1Char(':'));
            QCOMPARE(p.indexOf(parts.at(0), parts.at(1)), i);
        }
        QCOMPARE(p.indexOf(QStringLiteral("album"), QStringLiteral("nope")), -1);
        QCOMPARE(p.indexOf(QStringLiteral("podcast"), QStringLiteral("a")), -1);
    }

    // With nobody signed in there is no account to hang a list on. Pinning
    // still works in memory so the UI does not look broken, but nothing is
    // written where the next account would find it.
    void signedOutPinsAreNotPersisted() {
        PinStore p;
        p.pin(QStringLiteral("album"), QStringLiteral("x"), QStringLiteral("X"), QString(), QString());
        QCOMPARE(idsOf(p.items()), QStringList({"x"}));

        p.setUserId(1001);
        QVERIFY(p.items().isEmpty());
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestPins)
#include "tst_pins.moc"
