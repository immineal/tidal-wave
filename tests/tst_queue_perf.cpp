// What a track change costs on a long queue, and what it may tell the UI.
// Every open view of the queue answers queueChanged() by pulling
// player.queueTracks(), a copy of every row handed to JS. Moving the current
// index is not a change to the queue, so an advance must not emit it. Every
// real mutation still does, and the contents survive all of it.

#include <QTest>
#include <QTemporaryDir>
#include <QSettings>
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

// Big enough that a per-advance full copy shows up as seconds.
constexpr int kQueueSize = 5000;

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
        // The settings file is redirected into a scratch directory, so no run
        // touches or leaves anything in the user's home.
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_settingsDir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_settingsDir.path());
    }

    // ── an advance is not a queue change ────────────────────────────────────

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

    // queueIndex has its own notifier, so every mutation that shifts the current
    // track has to raise it too, or a highlight sticks to the wrong row.
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

    // rebuilds == 0 is the real guard. The clock is a second net for anything
    // else that makes an advance expensive, with a ceiling far above the cost of
    // an index move and well below the cost of republishing the queue.
    void fortyAdvancesStayCheapWithTheQueuePanelOpen() {
        Rig rig;
        rig.player.playTracks(queueOf(kQueueSize), 0);

        // Stands in for the Queue panel and the Up Next list: an open view
        // answers queueChanged by pulling the whole queue across to JS. The JS
        // conversion is the expensive half, so it is part of the listener.
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

private:
    QTemporaryDir m_settingsDir;
};

QTEST_MAIN(TestQueuePerf)
#include "tst_queue_perf.moc"
