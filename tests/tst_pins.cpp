// PinStore: the pinned block above the sidebar library. The order is the
// user's, so it has to come back byte for byte after a restart, and the list
// is per Tidal account, so one account must never see another's pins.
// Nothing here touches the network: PinStore only talks to QSettings, which
// initTestCase() points at a QTemporaryDir.

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

// The mixes `pages/my_collection_my_mixes` answers, as TidalClient hands them
// on: the two personalised ones first. Only the types matter to PinStore.
Tidal::Mix mkMix(const QString &id, const QString &title, const QString &type) {
    Tidal::Mix m;
    m.id       = id;
    m.title    = title;
    m.subTitle = QStringLiteral("subtitle of ") + title;
    m.cover    = QStringLiteral("http://art/") + id + QStringLiteral(".jpg");
    m.mixType  = type;
    return m;
}

QList<Tidal::Mix> cannedMixes() {
    return {
        mkMix(QStringLiteral("016disco"), QStringLiteral("My Daily Discovery"), QStringLiteral("DISCOVERY_MIX")),
        mkMix(QStringLiteral("011new"),   QStringLiteral("My New Arrivals"),    QStringLiteral("NEW_RELEASE_MIX")),
        mkMix(QStringLiteral("002one"),   QStringLiteral("My Mix 1"),           QStringLiteral("DAILY_MIX")),
        mkMix(QStringLiteral("002two"),   QStringLiteral("My Mix 2"),           QStringLiteral("DAILY_MIX")),
    };
}

// Answers the moment it is asked.
PinStore::MixSource answering(const QList<Tidal::Mix> &mixes, const QString &err = {}) {
    return [mixes, err](PinStore::MixesHandler done) { done(mixes, err); };
}

// Records that it was asked and answers only when told to, which is what the
// real one does: the request is out while the user carries on.
struct DeferredMixes {
    int calls = 0;
    PinStore::MixesHandler done;

    PinStore::MixSource source() {
        return [this](PinStore::MixesHandler h) { ++calls; done = std::move(h); };
    }
    void answer(const QList<Tidal::Mix> &mixes, const QString &err = {}) {
        if (done) done(mixes, err);
    }
};

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

        // Unpinning something that is not pinned emits nothing.
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
        // ...and the payload with it.
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

    // ── one list per account ─────────────────────────────────────────────

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

        // An empty id is rejected too.
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

        // ...and the store still works afterwards.
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

    // ── a pin stores facts, never rendered text ──────────────────────────
    // A pin's subtitle is a datum Tidal sent, such as an album's artists. A row
    // in QSettings outlives the locale it was written in. A playlist has no such
    // datum, so a rendered "%n track(s)" handed to pin() is dropped.

    void aPlaylistPinKeepsNoRenderedSubtitle() {
        PinStore p;
        p.setUserId(1001);

        // A rendered, translated, count-bearing subtitle, as a tile shows it.
        p.pin(QStringLiteral("playlist"), QStringLiteral("uuid-evening"),
              QStringLiteral("Evening Drive"), QStringLiteral("31 Titel"),
              QStringLiteral("http://art/evening.jpg"));

        const QVariantMap m = p.items().first().toMap();
        QCOMPARE(m.value(QStringLiteral("subtitle")).toString(), QString());
        // Everything else about the row is kept.
        QCOMPARE(m.value(QStringLiteral("title")).toString(), QStringLiteral("Evening Drive"));
        QCOMPARE(m.value(QStringLiteral("id")).toString(), QStringLiteral("uuid-evening"));
        QCOMPARE(m.value(QStringLiteral("imageUrl")).toString(),
                 QStringLiteral("http://art/evening.jpg"));

        // ...and it is gone on disk too.
        PinStore reopened;
        reopened.setUserId(1001);
        QCOMPARE(reopened.items().first().toMap().value(QStringLiteral("subtitle")).toString(),
                 QString());
    }

    // The other three kinds keep their subtitle: an album's artists and a mix's
    // own subtitle came from Tidal. Every call site hands an artist pin "".
    void theOtherKindsKeepTheirSubtitle_data() {
        QTest::addColumn<QString>("kind");
        QTest::addColumn<QString>("subtitle");
        QTest::newRow("album: its artists")  << QStringLiteral("album")  << QStringLiteral("Miles Davis");
        QTest::newRow("mix: Tidal's own")    << QStringLiteral("mix")    << QStringLiteral("Based on Portishead");
        QTest::newRow("artist: nothing")     << QStringLiteral("artist") << QString();
    }

    void theOtherKindsKeepTheirSubtitle() {
        QFETCH(QString, kind);
        QFETCH(QString, subtitle);

        PinStore p;
        p.setUserId(1001);
        p.pin(kind, QStringLiteral("9"), QStringLiteral("Whatever"), subtitle, QString());
        QCOMPARE(p.items().first().toMap().value(QStringLiteral("subtitle")).toString(), subtitle);

        PinStore reopened;
        reopened.setUserId(1001);
        QCOMPARE(reopened.items().first().toMap().value(QStringLiteral("subtitle")).toString(),
                 subtitle);
    }

    // A stored playlist row that carries a rendered count keeps its kind, id,
    // title, artwork and place, and loses only the subtitle. Nothing is
    // rewritten on disk until the next edit.
    void aRowWrittenBeforeThisRuleLosesOnlyItsFrozenCount() {
        { QSettings s; s.setValue(QStringLiteral("user_1001/pins"),
            QStringLiteral("[{\"kind\":\"playlist\",\"id\":\"uuid-evening\","
                           "\"title\":\"Evening Drive\",\"subtitle\":\"31 Titel\","
                           "\"imageUrl\":\"http://art/evening.jpg\"},"
                           "{\"kind\":\"album\",\"id\":\"42\",\"title\":\"Kind of Blue\","
                           "\"subtitle\":\"Miles Davis\","
                           "\"imageUrl\":\"http://art/42.jpg\"}]")); }

        PinStore p;
        p.setUserId(1001);

        // Both rows, in the order they were written.
        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("playlist:uuid-evening"),
                                                 QStringLiteral("album:42")}));

        const QVariantMap list = p.items().at(0).toMap();
        QCOMPARE(list.value(QStringLiteral("subtitle")).toString(), QString());
        QCOMPARE(list.value(QStringLiteral("title")).toString(), QStringLiteral("Evening Drive"));
        QCOMPARE(list.value(QStringLiteral("imageUrl")).toString(),
                 QStringLiteral("http://art/evening.jpg"));

        // The album row is not touched by any of this.
        const QVariantMap album = p.items().at(1).toMap();
        QCOMPARE(album.value(QStringLiteral("subtitle")).toString(), QStringLiteral("Miles Davis"));
        QCOMPARE(album.value(QStringLiteral("title")).toString(), QStringLiteral("Kind of Blue"));
    }

    // load() keeps a row that carries fields beyond the five it knows and drops
    // those fields, so the next save() writes them away. A new field added here
    // would not survive a run of an older build.
    void anUnknownFieldDoesNotCostTheRow() {
        { QSettings s; s.setValue(QStringLiteral("user_1001/pins"),
            QStringLiteral("[{\"kind\":\"album\",\"id\":\"42\",\"title\":\"Kind of Blue\","
                           "\"subtitle\":\"Miles Davis\",\"imageUrl\":\"http://art/42.jpg\","
                           "\"trackCount\":5,\"somethingNewer\":{\"a\":1}}]")); }

        PinStore p;
        p.setUserId(1001);
        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("album:42")}));
        const QVariantMap m = p.items().first().toMap();
        QCOMPARE(m.value(QStringLiteral("title")).toString(), QStringLiteral("Kind of Blue"));
        QCOMPARE(m.value(QStringLiteral("subtitle")).toString(), QStringLiteral("Miles Davis"));
        QVERIFY2(!m.contains(QStringLiteral("somethingNewer")),
                 "an unknown field is dropped on load - see the comment above");
        QVERIFY(!m.contains(QStringLiteral("trackCount")));
    }

    // LibraryIndex asks for this to keep a pinned entry out of the list below
    // the pinned block, so it has to agree with items().
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

    // ── the one-shot default pins ────────────────────────────────────────
    // An account that has never had a pin is handed the two personalised
    // mixes, Daily Discovery and New Arrivals, so the pinned block is visible.
    // This happens once per account and never again.

    void aFreshAccountIsGivenBothPersonalisedMixes() {
        PinStore p;
        p.setMixSource(answering(cannedMixes()));
        QSignalSpy spy(&p, &PinStore::changed);
        p.setUserId(1001);

        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("mix:016disco"),
                                                 QStringLiteral("mix:011new")}));
        const QVariantMap discovery = p.items().at(0).toMap();
        QCOMPARE(discovery.value(QStringLiteral("title")).toString(), QStringLiteral("My Daily Discovery"));
        QCOMPARE(discovery.value(QStringLiteral("subtitle")).toString(),
                 QStringLiteral("subtitle of My Daily Discovery"));
        QCOMPARE(discovery.value(QStringLiteral("imageUrl")).toString(),
                 QStringLiteral("http://art/016disco.jpg"));
        const QVariantMap arrivals = p.items().at(1).toMap();
        QCOMPARE(arrivals.value(QStringLiteral("title")).toString(), QStringLiteral("My New Arrivals"));
        QCOMPARE(arrivals.value(QStringLiteral("subtitle")).toString(),
                 QStringLiteral("subtitle of My New Arrivals"));
        QCOMPARE(arrivals.value(QStringLiteral("imageUrl")).toString(),
                 QStringLiteral("http://art/011new.jpg"));
        QVERIFY(p.wasSeeded());
        // The sidebar has to hear about it, or the rows appear only on the next
        // restart.
        QVERIFY(spy.count() >= 1);

        // And it is on disk.
        PinStore reopened;
        reopened.setMixSource(answering(cannedMixes()));
        reopened.setUserId(1001);
        QCOMPARE(keysOf(reopened.items()), QStringList({QStringLiteral("mix:016disco"),
                                                        QStringLiteral("mix:011new")}));
    }

    // Daily Discovery first, then New Arrivals, whatever order the mix list
    // arrives in: `pages/my_collection_my_mixes` makes no promise about order.
    void theSeededPairIsAlwaysDiscoveryThenArrivals() {
        QList<Tidal::Mix> reversed = {
            mkMix(QStringLiteral("002one"),   QStringLiteral("My Mix 1"),        QStringLiteral("DAILY_MIX")),
            mkMix(QStringLiteral("011new"),   QStringLiteral("My New Arrivals"), QStringLiteral("NEW_RELEASE_MIX")),
            mkMix(QStringLiteral("016disco"), QStringLiteral("My Daily Discovery"), QStringLiteral("DISCOVERY_MIX")),
        };
        PinStore p;
        p.setMixSource(answering(reversed));
        p.setUserId(1001);
        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("mix:016disco"),
                                                 QStringLiteral("mix:011new")}));
    }

    // The mixes are picked by mixType. The titles arrive in the account's own
    // language, so a title match would seed nothing for most users.
    void theSeedIsPickedByTypeNotByTitle() {
        QList<Tidal::Mix> german = {
            mkMix(QStringLiteral("016disco"), QStringLiteral("Meine taegliche Entdeckung"),
                  QStringLiteral("DISCOVERY_MIX")),
            mkMix(QStringLiteral("011new"), QStringLiteral("Meine Neuheiten"),
                  QStringLiteral("NEW_RELEASE_MIX")),
            mkMix(QStringLiteral("002one"), QStringLiteral("Mein Mix 1"),
                  QStringLiteral("DAILY_MIX")),
        };
        PinStore p;
        p.setMixSource(answering(german));
        p.setUserId(1001);

        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("mix:016disco"),
                                                 QStringLiteral("mix:011new")}));
        QCOMPARE(p.items().at(0).toMap().value(QStringLiteral("title")).toString(),
                 QStringLiteral("Meine taegliche Entdeckung"));
        QCOMPARE(p.items().at(1).toMap().value(QStringLiteral("title")).toString(),
                 QStringLiteral("Meine Neuheiten"));
    }

    // An account that has pinned anything is left alone, and the network is not
    // asked.
    void anAccountThatAlreadyHasPinsIsLeftAlone() {
        { QSettings s; s.setValue(QStringLiteral("user_1001/pins"),
            QStringLiteral("[{\"kind\":\"album\",\"id\":\"42\",\"title\":\"Kind of Blue\"}]")); }

        DeferredMixes net;
        PinStore p;
        p.setMixSource(net.source());
        p.setUserId(1001);

        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("album:42")}));
        QCOMPARE(net.calls, 0);
        QVERIFY(p.wasSeeded());
    }

    // Unpinning the seeded rows is final. The list is empty again at that
    // point, so only the marker stops the next sign-in from seeding again.
    void unpinningTheSeededRowsIsFinal() {
        PinStore p;
        p.setMixSource(answering(cannedMixes()));
        p.setUserId(1001);
        QCOMPARE(p.items().size(), 2);

        // Unpinning one of the pair must not bring it back either: the marker
        // is one per account.
        p.unpin(QStringLiteral("mix"), QStringLiteral("016disco"));
        PinStore halfWay;
        halfWay.setMixSource(answering(cannedMixes()));
        halfWay.setUserId(1001);
        QCOMPARE(keysOf(halfWay.items()), QStringList({QStringLiteral("mix:011new")}));

        p.unpin(QStringLiteral("mix"), QStringLiteral("011new"));
        QVERIFY(p.items().isEmpty());

        // Away and back, which is what a restart looks like from here.
        p.setUserId(2002);
        p.setUserId(1001);
        QVERIFY(p.items().isEmpty());

        PinStore relaunched;
        relaunched.setMixSource(answering(cannedMixes()));
        relaunched.setUserId(1001);
        QVERIFY(relaunched.items().isEmpty());
    }

    // Tidal builds these mixes out of listening history, so a new account has
    // none yet. The one shot is not spent on an empty answer.
    void anAccountWithNoMixesYetIsAskedAgainLater() {
        PinStore first;
        first.setMixSource(answering({}));
        first.setUserId(1001);
        QVERIFY(first.items().isEmpty());
        QVERIFY(!first.wasSeeded());

        // Once Tidal has generated them, the pins arrive.
        PinStore later;
        later.setMixSource(answering(cannedMixes()));
        later.setUserId(1001);
        QCOMPARE(keysOf(later.items()), QStringList({QStringLiteral("mix:016disco"),
                                                     QStringLiteral("mix:011new")}));
    }

    void aFailedRequestIsNotSpent() {
        PinStore first;
        first.setMixSource(answering(cannedMixes(), QStringLiteral("network unreachable")));
        first.setUserId(1001);
        QVERIFY(first.items().isEmpty());
        QVERIFY(!first.wasSeeded());

        PinStore later;
        later.setMixSource(answering(cannedMixes()));
        later.setUserId(1001);
        QCOMPARE(keysOf(later.items()), QStringList({QStringLiteral("mix:016disco"),
                                                     QStringLiteral("mix:011new")}));
    }

    // An account with mixes but neither personalised one gets nothing, and the
    // shot is spent, because the list came back.
    void anAccountWithNeitherPersonalisedMixIsGivenNothing() {
        PinStore p;
        p.setMixSource(answering({
            mkMix(QStringLiteral("002one"), QStringLiteral("My Mix 1"), QStringLiteral("DAILY_MIX")),
            mkMix(QStringLiteral("abc"),    QStringLiteral("Some Radio"), QStringLiteral("ARTIST_MIX")),
        }));
        p.setUserId(1001);

        QVERIFY(p.items().isEmpty());
        QVERIFY(p.wasSeeded());
    }

    // An account with only one of the two gets that one, and the shot is spent.
    void anAccountWithOnlyOneOfThePairGetsThatOne_data() {
        QTest::addColumn<QString>("type");
        QTest::addColumn<QString>("id");
        QTest::newRow("only discovery") << QStringLiteral("DISCOVERY_MIX")   << QStringLiteral("016disco");
        QTest::newRow("only arrivals")  << QStringLiteral("NEW_RELEASE_MIX") << QStringLiteral("011new");
    }

    void anAccountWithOnlyOneOfThePairGetsThatOne() {
        QFETCH(QString, type);
        QFETCH(QString, id);

        PinStore p;
        p.setMixSource(answering({
            mkMix(QStringLiteral("002one"), QStringLiteral("My Mix 1"), QStringLiteral("DAILY_MIX")),
            mkMix(id, QStringLiteral("The one it has"), type),
        }));
        p.setUserId(1001);

        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("mix:") + id}));
        QVERIFY(p.wasSeeded());
    }

    // The two personalised mixes and nothing else, though four mixes come back.
    void onlyThePersonalisedMixesAreSeeded() {
        PinStore p;
        p.setMixSource(answering(cannedMixes()));
        p.setUserId(1001);
        QCOMPARE(p.items().size(), 2);
        const QStringList keys = keysOf(p.items());
        QVERIFY2(!keys.contains(QStringLiteral("mix:002one"))
                     && !keys.contains(QStringLiteral("mix:002two")),
                 qPrintable(QStringLiteral("a plain daily mix was seeded too: %1")
                                .arg(keys.join(QLatin1String(", ")))));
    }

    // The request is out while the user carries on, so its answer is checked
    // against the account that is signed in when it lands.
    void anAnswerForAnAccountThatSignedOutIsDropped() {
        DeferredMixes net;
        PinStore p;
        p.setMixSource(net.source());
        p.setUserId(1001);
        QCOMPARE(net.calls, 1);
        const PinStore::MixesHandler answerFor1001 = net.done;

        p.setUserId(2002);                              // a second account signs in
        answerFor1001(cannedMixes(), QString());        // 1001's answer lands now

        // Nothing was written for either account.
        QVERIFY(p.items().isEmpty());
        QVERIFY(!p.wasSeeded());                        // 2002's own request is still out
        PinStore first;
        first.setUserId(1001);
        QVERIFY(first.items().isEmpty());
        QVERIFY(!first.wasSeeded());
    }

    // Pinning something by hand in the seconds the request was out also counts
    // as having found the feature.
    void aPinMadeWhileTheRequestWasOutWins() {
        DeferredMixes net;
        PinStore p;
        p.setMixSource(net.source());
        p.setUserId(1001);

        p.pin(QStringLiteral("album"), QStringLiteral("42"), QStringLiteral("Kind of Blue"),
              QString(), QString());
        net.answer(cannedMixes());

        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("album:42")}));
        QVERIFY(p.wasSeeded());
    }

    // No source means no seeding and no marker, so an unwired build does not
    // spend every account's one shot.
    void withoutAMixSourceNothingHappens() {
        PinStore p;
        p.setUserId(1001);
        QVERIFY(p.items().isEmpty());
        QVERIFY(!p.wasSeeded());
    }

    // The marker is per account, like the list it guards.
    void theOneShotIsPerAccount() {
        PinStore p;
        p.setMixSource(answering(cannedMixes()));
        p.setUserId(1001);
        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("mix:016disco"),
                                                 QStringLiteral("mix:011new")}));

        p.setUserId(2002);
        QCOMPARE(keysOf(p.items()), QStringList({QStringLiteral("mix:016disco"),
                                                 QStringLiteral("mix:011new")}));
        QVERIFY(p.wasSeeded());

        // Neither account's rows leaked into the other's list.
        PinStore one;  one.setUserId(1001);
        PinStore two;  two.setUserId(2002);
        QCOMPARE(one.items().size(), 2);
        QCOMPARE(two.items().size(), 2);
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestPins)
#include "tst_pins.moc"
