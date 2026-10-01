// What the queue is supposed to do, in the terms the user put it in.
//
// The old queue was one flat list that playTracks() replaced wholesale, so
// anything deliberately queued was destroyed the moment an album was played,
// and nothing told "the rest of this album" apart from "things I chose".
//
// The model here is two sections behind one playback order: the current
// track, then the manual queue in the order the user built it, then the
// remainder of the context. These tests are written against that sentence
// rather than against the data structure, so they stay true if the structure
// changes again.

#include <QTest>
#include <QTemporaryDir>
#include <QSettings>
#include <QSignalSpy>
#include <QSet>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

// Ids are distinct per family so a failure message says which list a stray
// row came from: 1xxx is the context, 2xxx the first album, 9xxx hand-queued.
QVariantMap trackOf(qlonglong id, const QString &title) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = title;
    t[QStringLiteral("artists")]    = QStringLiteral("Artist");
    t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
    t[QStringLiteral("albumId")]    = qlonglong(7);
    t[QStringLiteral("duration")]   = 200;
    return t;
}

// A context of n rows with ids base+0 .. base+n-1.
QVariantList contextOf(qlonglong base, int n) {
    QVariantList out;
    for (int i = 0; i < n; ++i)
        out.append(trackOf(base + i, QStringLiteral("T%1").arg(base + i)));
    return out;
}

QVariantList one(qlonglong id) {
    return QVariantList{ trackOf(id, QStringLiteral("T%1").arg(id)) };
}

QList<qlonglong> ids(const QVariantList &rows) {
    QList<qlonglong> out;
    for (const QVariant &v : rows)
        out.append(v.toMap().value(QStringLiteral("id")).toLongLong());
    return out;
}

qlonglong currentId(const Player &p) {
    return p.currentTrackMap().value(QStringLiteral("id")).toLongLong();
}

// Player defers its audio init to the event loop (a PipeWire deadlock guard),
// and next()/previous() do nothing until that has run.
struct Rig {
    TidalApi    api;
    TidalClient client{&api};
    Player      player{&client};
    Rig() { QTest::qWait(30); }
};

} // namespace

class TestQueueModel : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_queue_model"));
        // Redirect the settings file into a scratch directory as well as
        // renaming it. Renaming alone keeps the user's own config safe but
        // still leaves a stray directory in their home after every run.
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_settingsDir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_settingsDir.path());
    }

    // ── the invariant every other test leans on ─────────────────────────────

    // The flat view is the sections laid end to end. NowPlayingPage, PlayerBar
    // and TrackRow still index the queue as one list, so the two descriptions
    // of it must never be able to disagree; of everything here this is the one
    // most likely to rot, so almost every test below ends up back in it.
    void verify(Player &p) {
        QVariantList rebuilt = p.queuePlayed();
        if (p.queueIndex() >= 0) rebuilt.append(p.currentTrackMap());
        rebuilt += p.queueManual();
        rebuilt += p.queueContext();

        QCOMPARE(ids(rebuilt), ids(p.queueTracks()));
        QCOMPARE(rebuilt.count(), p.queueCount());
        QCOMPARE(p.queuePlayed().count(), qMax(0, p.queueIndex()));
        QCOMPARE(p.queueManual().count(), p.manualCount());

        // Nothing is in two places at once, least of all what is playing.
        if (p.queueIndex() >= 0) {
            const qlonglong cur = currentId(p);
            QVERIFY2(!ids(p.queueManual()).contains(cur),
                     "the track that is playing is still listed as next in queue");
            QVERIFY2(!ids(p.queueContext()).contains(cur),
                     "the track that is playing is still listed as upcoming");
            QVERIFY2(!ids(p.queuePlayed()).contains(cur),
                     "the track that is playing is also in the history");
        }
    }

    // ── playing an album leaves the manual queue standing ───────────────────

    void playingAnAlbumDoesNotDestroyWhatYouQueued() {
        Rig rig;
        auto &p = rig.player;

        p.setPlaybackSource(QStringLiteral("album"), QStringLiteral("1"),
                            QStringLiteral("Life 1"));
        p.playTracks(contextOf(1000, 5), 0);
        p.addToQueue(one(9001));
        p.addToQueue(one(9002));

        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001, 9002}));
        QCOMPARE(p.contextName(), QStringLiteral("Life 1"));
        QCOMPARE(p.contextType(), QStringLiteral("album"));
        verify(p);

        // A different album arrives. The context goes; the two rows the user
        // picked out by hand do not.
        p.setPlaybackSource(QStringLiteral("playlist"), QStringLiteral("2"),
                            QStringLiteral("Life 2"));
        p.playTracks(contextOf(2000, 4), 0);

        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001, 9002}));
        QCOMPARE(currentId(p), 2000);
        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{2001, 2002, 2003}));
        QCOMPARE(p.contextName(), QStringLiteral("Life 2"));
        QCOMPARE(p.contextType(), QStringLiteral("playlist"));
        QCOMPARE(p.queueCount(), 6);   // four of the album, two of theirs
        verify(p);

        // And nothing of the old context is left anywhere.
        for (qlonglong id : ids(p.queueTracks()))
            QVERIFY2(id < 1000 || id >= 2000, "a row of the replaced context survived");
    }

    // ── where a queued track lands ──────────────────────────────────────────

    void playNextLandsImmediatelyAfterTheCurrentTrack() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 5), 0);

        p.addToQueue(one(9001));
        p.addToQueue(one(9002));
        p.playNext(one(9003));

        // In front of everything already queued, but still behind what plays.
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9003, 9001, 9002}));
        QCOMPARE(currentId(p), 1000);
        QCOMPARE(ids(p.queueTracks()).at(p.queueIndex() + 1), 9003);
        verify(p);

        // A second playNext goes in front of the first.
        p.playNext(one(9004));
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9004, 9003, 9001, 9002}));
        verify(p);
    }

    void addToQueueLandsAfterEverythingAlreadyQueued() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 3), 0);

        p.addToQueue(one(9001));
        p.playNext(one(9002));
        p.addToQueue(one(9003));

        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9002, 9001, 9003}));
        verify(p);

        // A whole album queued at once keeps its own order at the back.
        p.addToQueue(contextOf(8000, 3));
        QCOMPARE(ids(p.queueManual()),
                 (QList<qlonglong>{9002, 9001, 9003, 8000, 8001, 8002}));
        verify(p);
    }

    // ── a manual track is consumed when it plays ────────────────────────────

    void aQueuedTrackIsConsumedWhenItPlaysAndDoesNotComeBack() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 3), 0);
        p.addToQueue(one(9001));

        QCOMPARE(p.manualCount(), 1);
        p.next();

        QCOMPARE(currentId(p), 9001);
        QCOMPARE(p.manualCount(), 0);
        QVERIFY2(p.queueManual().isEmpty(), "a track that is playing is still queued");
        QCOMPARE(ids(p.queuePlayed()), (QList<qlonglong>{1000}));
        verify(p);

        // Playing on to the end never meets it again.
        p.next();
        QCOMPARE(currentId(p), 1001);
        QVERIFY(!ids(p.queueContext()).contains(9001));
        p.next();
        QCOMPARE(currentId(p), 1002);
        QVERIFY(p.queueContext().isEmpty());
        verify(p);

        // And the end of the queue is the end of it.
        p.next();
        QCOMPARE(currentId(p), 1002);
    }

    void theManualQueueDrainsBeforeTheContextResumes() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 4), 0);
        p.addToQueue(one(9001));
        p.addToQueue(one(9002));

        QList<qlonglong> order{ currentId(p) };
        for (int i = 0; i < 5; ++i) { p.next(); order.append(currentId(p)); verify(p); }

        QCOMPARE(order, (QList<qlonglong>{1000, 9001, 9002, 1001, 1002, 1003}));
    }

    // ── shuffle ─────────────────────────────────────────────────────────────

    void shuffleReordersTheContextAndLeavesTheManualQueueAlone() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 60), 0);
        p.addToQueue(one(9001));
        p.addToQueue(one(9002));
        p.addToQueue(one(9003));

        QList<qlonglong> natural;
        for (int i = 1; i < 60; ++i) natural.append(1000 + i);
        QCOMPARE(ids(p.queueContext()), natural);

        p.setShuffle(true);

        // Same rows, different order. 59 rows landing back in order by chance
        // is not a thing that happens.
        const QList<qlonglong> shuffled = ids(p.queueContext());
        QCOMPARE(shuffled.count(), natural.count());
        QCOMPARE(QSet<qlonglong>(shuffled.begin(), shuffled.end()),
                 QSet<qlonglong>(natural.begin(), natural.end()));
        QVERIFY2(shuffled != natural, "shuffle left the context in its original order");

        // Shuffling something the user ordered on purpose is never wanted.
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001, 9002, 9003}));
        QCOMPARE(currentId(p), 1000);
        verify(p);

        p.setShuffle(false);
        QCOMPARE(ids(p.queueContext()), natural);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001, 9002, 9003}));
        verify(p);
    }

    void shuffleAppliesToAnAlbumStartedWhileItIsOn() {
        Rig rig;
        auto &p = rig.player;
        p.setShuffle(true);
        p.addToQueue(one(9001));
        p.playTracks(contextOf(1000, 60), 0);

        QList<qlonglong> natural;
        for (int i = 1; i < 60; ++i) natural.append(1000 + i);
        QVERIFY2(ids(p.queueContext()) != natural,
                 "an album started with shuffle already on came out in order");
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001}));
        verify(p);
    }

    // ── walking the combined order ──────────────────────────────────────────

    void nextAndPreviousWalkAcrossTheBoundaryBetweenSections() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 4), 0);
        p.addToQueue(one(9001));

        p.next();                       // into the manual queue
        QCOMPARE(currentId(p), 9001);
        p.next();                       // and out the other side
        QCOMPARE(currentId(p), 1001);
        verify(p);

        p.previous();                   // back onto the track they queued
        QCOMPARE(currentId(p), 9001);
        QCOMPARE(ids(p.queuePlayed()), (QList<qlonglong>{1000}));
        verify(p);

        p.previous();
        QCOMPARE(currentId(p), 1000);
        QVERIFY(p.queuePlayed().isEmpty());
        // Stepping back past a queue entry that has already played is the end
        // of it. It was consumed when it played, so the album carries on from
        // here without it rather than offering it a second time.
        QVERIFY2(!ids(p.queueTracks()).contains(9001),
                 "a queue entry that had already played came back");
        verify(p);

        // Stepping back off the front stays put.
        p.previous();
        QCOMPARE(currentId(p), 1000);

        // Forward from here is the album, in order.
        p.next();
        QCOMPARE(currentId(p), 1001);
        p.next();
        QCOMPARE(currentId(p), 1002);
        verify(p);
    }

    // Stepping back over a track the user had queued and that has already
    // played must not re-queue it: it was consumed, and the rows still waiting
    // stay in front of whatever plays.
    void steppingBackPastAConsumedTrackDoesNotPutItBackInTheQueue() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 4), 0);
        p.addToQueue(one(9001));
        p.addToQueue(one(9002));

        p.next();                 // 9001 plays and is consumed
        p.next();                 // 9002 plays and is consumed
        QCOMPARE(currentId(p), 9002);
        QCOMPARE(p.manualCount(), 0);

        p.addToQueue(one(9003));  // something new waiting
        p.jumpToPlayed(0);        // all the way back to the first album track

        QCOMPARE(currentId(p), 1000);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9003}));
        QVERIFY2(!ids(p.queueContext()).contains(9001),
                 "a consumed queue entry came back as upcoming");
        QVERIFY2(!ids(p.queueContext()).contains(9002),
                 "a consumed queue entry came back as upcoming");
        verify(p);

        // And the walk forward from here is the album with the new row first.
        QList<qlonglong> order{ currentId(p) };
        for (int i = 0; i < 4; ++i) { p.next(); order.append(currentId(p)); }
        QCOMPARE(order, (QList<qlonglong>{1000, 9003, 1001, 1002, 1003}));
    }

    // ── the three jumps ─────────────────────────────────────────────────────

    void jumpToManualPlaysItAndDropsWhatItSkipped() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 3), 0);
        p.addToQueue(one(9001));
        p.addToQueue(one(9002));
        p.addToQueue(one(9003));

        p.jumpToManual(1);

        QCOMPARE(currentId(p), 9002);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9003}));
        QVERIFY2(!ids(p.queueTracks()).contains(9001),
                 "the entry that was skipped past is still in the queue");
        QCOMPARE(ids(p.queuePlayed()), (QList<qlonglong>{1000}));
        verify(p);
    }

    void jumpToContextLandsOnTheRightTrack() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 5), 0);
        p.addToQueue(one(9001));

        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{1001, 1002, 1003, 1004}));
        p.jumpToContext(2);

        QCOMPARE(currentId(p), 1003);
        QCOMPARE(ids(p.queuePlayed()), (QList<qlonglong>{1000, 1001, 1002}));
        // The manual queue is "whatever the user put next", so it follows.
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001}));
        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{1004}));
        verify(p);
    }

    void jumpToPlayedGoesBackToSomethingAlreadyPlayed() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 5), 3);

        QCOMPARE(currentId(p), 1003);
        QCOMPARE(ids(p.queuePlayed()), (QList<qlonglong>{1000, 1001, 1002}));

        p.jumpToPlayed(1);
        QCOMPARE(currentId(p), 1001);
        QCOMPARE(ids(p.queuePlayed()), (QList<qlonglong>{1000}));
        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{1002, 1003, 1004}));
        verify(p);

        // Out of range does nothing at all.
        p.jumpToPlayed(7);
        QCOMPARE(currentId(p), 1001);
        p.jumpToPlayed(-1);
        QCOMPARE(currentId(p), 1001);
    }

    // ── history ─────────────────────────────────────────────────────────────

    void historyAccumulatesInPlayOrder() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 4), 0);
        p.playNext(one(9001));

        QList<qlonglong> played;
        for (int i = 0; i < 4; ++i) {
            QCOMPARE(ids(p.queuePlayed()), played);
            played.append(currentId(p));
            verify(p);
            p.next();
        }
        QCOMPARE(played, (QList<qlonglong>{1000, 9001, 1001, 1002}));
    }

    // The in-session history is not the persisted recently-played list; they
    // are different features and must not be mistaken for one another.
    void theHistorySectionIsNotTheRecentlyPlayedList() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 3), 2);

        // Two album tracks sit above the current one, and none of them has
        // been played, so recentlyPlayed knows nothing about them.
        QCOMPARE(ids(p.queuePlayed()), (QList<qlonglong>{1000, 1001}));
        QCOMPARE(p.recentlyPlayed().count(), 1);
        QCOMPARE(ids(p.recentlyPlayed()), (QList<qlonglong>{1002}));
    }

    // ── mutating the manual queue while it is playing ───────────────────────

    void removingAndMovingQueueEntriesWhileOneOfThemPlays() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 3), 0);
        p.addToQueue(one(9001));
        p.addToQueue(one(9002));
        p.addToQueue(one(9003));

        p.next();                       // 9001 is now playing, not queued
        QCOMPARE(currentId(p), 9001);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9002, 9003}));

        // Index 0 of the manual queue is the next one, never the one playing.
        p.removeManual(0);
        QCOMPARE(currentId(p), 9001);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9003}));
        verify(p);

        p.addToQueue(one(9004));
        p.addToQueue(one(9005));
        p.moveManual(2, 0);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9005, 9003, 9004}));
        QCOMPARE(currentId(p), 9001);
        verify(p);

        // Out of range is a no-op, not a crash or a silently wrong row.
        p.removeManual(9);
        p.removeManual(-1);
        p.moveManual(0, 9);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9005, 9003, 9004}));
        verify(p);

        p.clearManual();
        QVERIFY(p.queueManual().isEmpty());
        QCOMPARE(currentId(p), 9001);
        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{1001, 1002}));
        verify(p);
    }

    // ── the empty cases ─────────────────────────────────────────────────────

    void anEmptyManualQueueAndAnEmptyContext() {
        Rig rig;
        auto &p = rig.player;

        QCOMPARE(p.queueCount(), 0);
        QCOMPARE(p.queueIndex(), -1);
        QVERIFY(p.queuePlayed().isEmpty());
        QVERIFY(p.queueManual().isEmpty());
        QVERIFY(p.queueContext().isEmpty());
        verify(p);

        // Nothing to do, and nothing said about it.
        QSignalSpy queueSpy(&p, &Player::queueChanged);
        p.clearManual();
        p.removeManual(0);
        p.moveManual(0, 1);
        p.jumpToManual(0);
        p.jumpToContext(0);
        p.jumpToPlayed(0);
        p.playTracks(QVariantList{}, 0);
        p.playNext(QVariantList{});
        p.addToQueue(QVariantList{});
        QCOMPARE(queueSpy.count(), 0);
        QCOMPARE(p.queueCount(), 0);

        // Queuing with nothing playing puts the rows in the manual queue and
        // leaves the cursor where it is.
        p.addToQueue(one(9001));
        p.addToQueue(one(9002));
        QCOMPARE(p.queueIndex(), -1);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001, 9002}));
        QVERIFY(p.queueContext().isEmpty());
        QCOMPARE(p.queueCount(), 2);
        verify(p);

        // An empty context around a manual queue still plays it through.
        p.next();
        QCOMPARE(currentId(p), 9001);
        p.next();
        QCOMPARE(currentId(p), 9002);
        QVERIFY(p.queueManual().isEmpty());
        QVERIFY(p.queueContext().isEmpty());
        verify(p);

        // A context with no manual queue behind it.
        p.clearQueue();
        p.playTracks(contextOf(1000, 2), 0);
        QVERIFY(p.queueManual().isEmpty());
        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{1001}));
        verify(p);
    }

    // ── repeat ──────────────────────────────────────────────────────────────

    // Repeat loops the context. A track the user queued has been consumed by
    // the time the loop comes round, so it is not part of what repeats.
    void repeatAllLoopsTheContextAndNotTheQueuedTracks() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 3), 0);
        p.addToQueue(one(9001));
        p.setRepeatMode(1);

        QList<qlonglong> order{ currentId(p) };
        for (int i = 0; i < 5; ++i) { p.next(); order.append(currentId(p)); verify(p); }

        QCOMPARE(order, (QList<qlonglong>{1000, 9001, 1001, 1002, 1000, 1001}));
        QVERIFY2(!ids(p.queueTracks()).contains(9001),
                 "a consumed queue entry survived the loop back to the album");
    }

    void repeatOneStaysPut() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 3), 1);
        p.addToQueue(one(9001));
        p.setRepeatMode(2);

        p.next();
        QCOMPARE(currentId(p), 1001);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001}));
        verify(p);
    }

    // ── the flat view the rest of the app still uses ────────────────────────

    void theFlattenedViewAgreesWithTheSectionsThroughEveryMutation() {
        Rig rig;
        auto &p = rig.player;

        p.playTracks(contextOf(1000, 8), 2);                     verify(p);
        p.addToQueue(one(9001));                                 verify(p);
        p.playNext(one(9002));                                   verify(p);
        p.next();                                                verify(p);
        p.appendQueue(one(9003));                                verify(p);
        p.previous();                                            verify(p);
        p.setShuffle(true);                                      verify(p);
        p.jumpToContext(1);                                      verify(p);
        p.setShuffle(false);                                     verify(p);
        p.moveQueueItem(p.queueCount() - 1, 0);                  verify(p);
        p.removeFromQueue(0);                                    verify(p);
        p.jumpToQueue(p.queueCount() - 1);                       verify(p);
        p.removeManual(0);                                       verify(p);
        p.jumpToPlayed(0);                                       verify(p);
        p.clearManual();                                         verify(p);
        p.setRepeatMode(1);
        for (int i = 0; i < 12; ++i) { p.next(); verify(p); }
        p.clearQueue();                                          verify(p);
        QCOMPARE(p.queueCount(), 0);
        QCOMPARE(p.queueIndex(), -1);
        QCOMPARE(p.manualCount(), 0);
    }

    // appendQueue is addToQueue under its old name; everything that still
    // calls it has to keep behaving.
    void appendQueueIsAddToQueue() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 3), 0);

        p.appendQueue(one(9001));
        p.appendQueue(one(9002));
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9001, 9002}));
        QCOMPARE(ids(p.queueTracks()),
                 (QList<qlonglong>{1000, 9001, 9002, 1001, 1002}));
        verify(p);
    }

    // The flat jump has to find the same track the panel pointed at, whichever
    // section the row came from.
    void jumpToQueueAgreesWithTheSectionJumps() {
        Rig rig;
        auto &p = rig.player;
        p.playTracks(contextOf(1000, 6), 1);
        p.addToQueue(one(9001));
        p.addToQueue(one(9002));

        // flat: 1000 | 1001* | 9001 9002 | 1002 1003 1004 1005
        QCOMPARE(ids(p.queueTracks()),
                 (QList<qlonglong>{1000, 1001, 9001, 9002, 1002, 1003, 1004, 1005}));
        QCOMPARE(p.queueIndex(), 1);
        QCOMPARE(p.manualCount(), 2);

        // A flat jump into the manual run is a manual jump, drops and all.
        p.jumpToQueue(3);
        QCOMPARE(currentId(p), 9002);
        QVERIFY(!ids(p.queueTracks()).contains(9001));
        verify(p);

        p.addToQueue(one(9003));
        const int contextRow = p.queueIndex() + p.manualCount() + 2;
        const qlonglong want = ids(p.queueTracks()).at(contextRow);
        p.jumpToQueue(contextRow);
        QCOMPARE(currentId(p), want);
        QCOMPARE(ids(p.queueManual()), (QList<qlonglong>{9003}));
        verify(p);
    }

private:
    QTemporaryDir m_settingsDir;
};

QTEST_MAIN(TestQueueModel)
#include "tst_queue_model.moc"
