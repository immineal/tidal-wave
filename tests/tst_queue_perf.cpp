// What a track change costs on a long queue, and what it is allowed to tell
// the UI about.
//
// A stress run on a 5000-track queue measured ~815ms per track change (40 jumps
// in 32.6s), identically on offscreen, xcb and Wayland — so it was marshalling,
// not rendering. The cause: next()/previous()/jumpToQueue() emitted
// queueChanged(), and every open view of the queue answers that by pulling
// player.queueTracks(), which copies all 5000 QVariantMaps into a fresh
// QVariantList and hands it to JS. Moving the current index is not a change to
// the queue, so it must not say that it is.
//
// These tests assert the behaviour rather than only the clock: an advance emits
// queueChanged *zero* times while still moving the index, every real mutation
// still emits it, and the queue's contents survive all of it. The one timing
// test keeps a model-rebuilding listener attached, which is what made the cost
// visible in the first place.

#include <QTest>
#include <QElapsedTimer>
#include <QJSEngine>
#include <QJSValue>
#include <QSignalSpy>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

// The size the stress harness used. Big enough that a per-advance full copy
// shows up as seconds rather than as noise.
constexpr int kQueueSize = 5000;

// 40 advances across that queue is the stress run's own figure (32.6s before).
constexpr int kAdvances = 40;

// Wall-clock ceiling for those 40 advances with a listener that rebuilds its
// model on every queueChanged. See the timing test for how it was picked.
constexpr qint64 kAdvanceCeilingMs = 150;

QVariantMap track(int i) {
    QVariantMap t;
    t[QStringLiteral("id")]         = qlonglong(100000 + i);
    t[QStringLiteral("title")]      = QStringLiteral("Track %1").arg(i);
    t[QStringLiteral("artists")]    = QStringLiteral("Artist %1").arg(i % 97);
    t[QStringLiteral("albumTitle")] = QStringLiteral("Album %1").arg(i % 311);
    t[QStringLiteral("albumId")]    = qlonglong(900000 + (i % 311));
    t[QStringLiteral("duration")]   = 180 + (i % 60);
    t[QStringLiteral("coverUrl80")] = QStringLiteral("cover/%1").arg(i % 311);
    return t;
}

QVariantList queueOf(int n) {
    QVariantList out;
    out.reserve(n);
    for (int i = 0; i < n; ++i) out.append(track(i));
    return out;
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

class TestQueuePerf : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_queue_perf"));
    }

    // ── the regression itself ───────────────────────────────────────────────

    void advancingDoesNotRebuildTheQueue() {
        Rig rig;
        rig.player.playTracks(queueOf(kQueueSize), 0);
        QCOMPARE(rig.player.queueCount(), kQueueSize);
        QCOMPARE(rig.player.queueIndex(), 0);

        QSignalSpy queueSpy(&rig.player, &Player::queueChanged);
        QSignalSpy indexSpy(&rig.player, &Player::currentIndexChanged);

        rig.player.next();
        QCOMPARE(rig.player.queueIndex(), 1);
        QCOMPARE(indexSpy.count(), 1);
        QCOMPARE(indexSpy.takeFirst().at(0).toInt(), 1);
        QCOMPARE(queueSpy.count(), 0);

        rig.player.next();
        QCOMPARE(rig.player.queueIndex(), 2);
        QCOMPARE(queueSpy.count(), 0);

        rig.player.previous();
        QCOMPARE(rig.player.queueIndex(), 1);
        QCOMPARE(queueSpy.count(), 0);

        // A jump is still only the index moving, however far it travels.
        rig.player.jumpToQueue(4321);
        QCOMPARE(rig.player.queueIndex(), 4321);
        QCOMPARE(queueSpy.count(), 0);

        QCOMPARE(indexSpy.count(), 3);   // next, previous, jump
    }

    // Stepping back is an index move like any other, and a step back that is
    // refused is not a move at all.
    void steppingBackReportsOnlyTheIndex() {
        Rig rig;
        rig.player.playTracks(queueOf(16), 4);

        QSignalSpy queueSpy(&rig.player, &Player::queueChanged);
        QSignalSpy indexSpy(&rig.player, &Player::currentIndexChanged);

        rig.player.previous();   // position is 0 here, so this really steps back
        QCOMPARE(rig.player.queueIndex(), 3);
        QCOMPARE(indexSpy.count(), 1);
        QCOMPARE(queueSpy.count(), 0);

        // Stepping back off the front is refused, and says nothing.
        rig.player.jumpToQueue(0);
        indexSpy.clear();
        rig.player.previous();
        QCOMPARE(rig.player.queueIndex(), 0);
        QCOMPARE(indexSpy.count(), 0);
        QCOMPARE(queueSpy.count(), 0);
    }

    // ── everything that genuinely changes the queue must still announce it ───

    void realMutationsStillEmitQueueChanged() {
        Rig rig;
        rig.player.playTracks(queueOf(200), 10);

        QSignalSpy queueSpy(&rig.player, &Player::queueChanged);

        rig.player.appendQueue({ track(90001) });
        QCOMPARE(queueSpy.count(), 1);
        QCOMPARE(rig.player.queueCount(), 201);

        rig.player.removeFromQueue(199);
        QCOMPARE(queueSpy.count(), 2);
        QCOMPARE(rig.player.queueCount(), 200);

        rig.player.moveQueueItem(50, 20);
        QCOMPARE(queueSpy.count(), 3);

        rig.player.setShuffle(true);
        QCOMPARE(queueSpy.count(), 4);
        rig.player.setShuffle(false);
        QCOMPARE(queueSpy.count(), 5);

        rig.player.clearQueue();
        QCOMPARE(queueSpy.count(), 6);
        QCOMPARE(rig.player.queueCount(), 0);

        // A new context is a new queue.
        rig.player.playTracks(queueOf(30), 0);
        QCOMPARE(queueSpy.count(), 7);
        QCOMPARE(rig.player.queueCount(), 30);
    }

    // queueIndex is read off a different notifier now, so every mutation that
    // shifts the current track has to raise that one too or a highlight sticks
    // to the wrong row.
    void mutationsThatMoveTheCurrentTrackReportTheNewIndex() {
        Rig rig;
        rig.player.playTracks(queueOf(50), 20);

        QSignalSpy indexSpy(&rig.player, &Player::currentIndexChanged);

        // Removing ahead of the current track leaves it where it is.
        rig.player.removeFromQueue(40);
        QCOMPARE(rig.player.queueIndex(), 20);
        QCOMPARE(indexSpy.count(), 0);

        // Removing behind it pulls it down one.
        rig.player.removeFromQueue(0);
        QCOMPARE(rig.player.queueIndex(), 19);
        QCOMPARE(indexSpy.count(), 1);

        // Dragging the current track elsewhere takes the index with it.
        rig.player.moveQueueItem(19, 3);
        QCOMPARE(rig.player.queueIndex(), 3);
        QCOMPARE(indexSpy.count(), 2);

        // Appending inserts after the current track, which does not move it.
        rig.player.appendQueue({ track(90002) });
        QCOMPARE(rig.player.queueIndex(), 3);
        QCOMPARE(indexSpy.count(), 2);

        rig.player.clearQueue();
        QCOMPARE(rig.player.queueIndex(), -1);
        QCOMPARE(indexSpy.count(), 3);
    }

    // ── the contents have to survive all of it ──────────────────────────────

    void contentsStayCorrectThroughout() {
        Rig rig;
        rig.player.playTracks(queueOf(kQueueSize), 0);

        for (int i = 0; i < 25; ++i) rig.player.next();
        QCOMPARE(rig.player.queueIndex(), 25);
        QCOMPARE(rig.player.queueCount(), kQueueSize);
        QCOMPARE(rig.player.currentTrackMap().value(QStringLiteral("id")).toLongLong(),
                 qlonglong(100025));

        const QVariantList all = rig.player.queueTracks();
        QCOMPARE(all.count(), kQueueSize);
        QCOMPARE(all.first().toMap().value(QStringLiteral("title")).toString(),
                 QStringLiteral("Track 0"));
        QCOMPARE(all.last().toMap().value(QStringLiteral("title")).toString(),
                 QStringLiteral("Track %1").arg(kQueueSize - 1));
        QCOMPARE(rig.player.queueTrackAt(25).value(QStringLiteral("id")).toLongLong(),
                 qlonglong(100025));

        // The row under the current one is what "up next" shows.
        const QVariantList up = rig.player.upcomingTracks(3);
        QCOMPARE(up.count(), 3);
        QCOMPARE(up.first().toMap().value(QStringLiteral("id")).toLongLong(),
                 qlonglong(100026));

        // Shuffle rewrites the play order but not the queue.
        rig.player.setShuffle(true);
        QCOMPARE(rig.player.queueCount(), kQueueSize);
        const QVariantList order = rig.player.playbackOrderTracks();
        QCOMPARE(order.count(), kQueueSize);
        QVERIFY2(order.first().toMap().value(QStringLiteral("_queueIndex")).toInt()
                     == rig.player.queueIndex(),
                 "the shuffled order should start at the track that is playing");

        // Rows still map back to real queue indices while shuffled.
        QSet<int> seen;
        for (const QVariant &v : order) {
            const int qi = v.toMap().value(QStringLiteral("_queueIndex")).toInt();
            QVERIFY(qi >= 0 && qi < kQueueSize);
            seen.insert(qi);
        }
        QCOMPARE(seen.count(), kQueueSize);

        rig.player.setShuffle(false);
        QCOMPARE(rig.player.queueTracks().count(), kQueueSize);
    }

    // ── the clock ───────────────────────────────────────────────────────────

    // rebuilds == 0 is the real guard; the clock is a second net for anything
    // else that turns an advance expensive. 40 advances measure ~1ms here now,
    // and 326ms with the per-advance republish still in (the full app paid far
    // more than that again in delegate churn: 32.6s for these 40 jumps). 150ms
    // sits 150x above the measured cost, which no loaded machine will reach,
    // and still less than half of what the regression costs.
    void fortyAdvancesStayCheapWithTheQueuePanelOpen() {
        Rig rig;
        rig.player.playTracks(queueOf(kQueueSize), 0);

        // Stands in for the Queue panel and the Up Next list: any open view of
        // the queue answers queueChanged by pulling the whole thing across and
        // handing it to JS. Without a listener this test would pass even if the
        // signal still fired, because nothing would be paying for it; and
        // without the JS conversion it would understate the bill by more than
        // an order of magnitude, because the QVariantList copy is the cheap half.
        QJSEngine js;
        int rebuilds = 0;
        QJSValue sink;
        QObject::connect(&rig.player, &Player::queueChanged, &rig.player, [&] {
            ++rebuilds;
            sink = js.toScriptValue(rig.player.queueTracks());
        });

        QElapsedTimer timer;
        timer.start();
        for (int i = 0; i < kAdvances; ++i) rig.player.next();
        const qint64 elapsed = timer.elapsed();

        // Reported before the assertions so a failing run still says what it
        // measured.
        qInfo("%d advances across a %d-track queue: %lldms, %d queue rebuilds",
              kAdvances, kQueueSize, elapsed, rebuilds);

        QCOMPARE(rig.player.queueIndex(), kAdvances);
        QVERIFY2(elapsed < kAdvanceCeilingMs,
                 qPrintable(QStringLiteral("%1 advances across a %2-track queue took %3ms, "
                                           "over the %4ms ceiling (%5 queue rebuilds)")
                                .arg(kAdvances).arg(kQueueSize)
                                .arg(elapsed).arg(kAdvanceCeilingMs).arg(rebuilds)));
        QCOMPARE(rebuilds, 0);
    }
};

QTEST_MAIN(TestQueuePerf)
#include "tst_queue_perf.moc"
