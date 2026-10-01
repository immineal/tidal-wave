// What survives quitting the app, and what must not happen on the way back.
//
// The session is stored per Tidal account in the Player's own QSettings:
// volume, mute, shuffle, repeat, both queue sections, the current track and
// the position inside it. Two rules carry the whole feature. It comes back
// paused, because an app that starts making noise the moment it opens is a
// bug nobody forgives. And a saved track that no longer resolves is stepped
// over, because the stream has to be fetched again at launch and the
// catalogue does not stand still.

#include <QTest>
#include <QTemporaryDir>
#include <QElapsedTimer>
#include <QMediaPlayer>
#include <QSettings>
#include <QSignalSpy>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

constexpr qint64 kUser = 4242;

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

// One launch of the app. The account id is set before the Player exists, so
// the Player restores from its constructor exactly as it does at startup.
struct Launch {
    TidalApi    api;
    TidalClient client{&api};
    Player     *player = nullptr;

    explicit Launch(qint64 uid = kUser) {
        client.setUserId(uid);
        player = new Player(&client);
        QTest::qWait(30);   // Player defers its audio init by one event loop turn
    }
    ~Launch() { delete player; }
    Player &p() { return *player; }
};

} // namespace

class TestQueuePersist : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_queue_persist"));
        // Redirect the settings file into a scratch directory as well as
        // renaming it. Renaming alone keeps the user's own config safe but
        // still leaves a stray directory in their home after every run.
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_settingsDir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_settingsDir.path());
    }

    void init() {
        QSettings().clear();   // every test starts from a fresh install
    }

    // ── the knobs ───────────────────────────────────────────────────────────

    void volumeMuteShuffleAndRepeatComeBack() {
        {
            Launch a;
            a.p().playTracks(contextOf(1000, 6), 0);
            a.p().setVolume(0.33);
            a.p().setMuted(true);
            a.p().setShuffle(true);
            a.p().setRepeatMode(1);
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(qAbs(b.p().volume() - 0.33) < 0.001);
        QCOMPARE(b.p().muted(), true);
        QCOMPARE(b.p().shuffle(), true);
        QCOMPARE(b.p().repeatMode(), 1);
    }

    // A fresh install restores nothing and must not pretend otherwise.
    void nothingSavedMeansNothingRestored() {
        Launch a;
        QCOMPARE(a.p().queueCount(), 0);
        QCOMPARE(a.p().queueIndex(), -1);
        QCOMPARE(a.p().shuffle(), false);
        QCOMPARE(a.p().repeatMode(), 0);
    }

    // The state is per account, so signing in as somebody else gets their
    // session and not the last one.
    void theSessionIsPerAccount() {
        {
            Launch a(kUser);
            a.p().playTracks(contextOf(1000, 4), 1);
            a.p().savePlaybackState();
        }
        Launch other(kUser + 1);
        QCOMPARE(other.p().queueCount(), 0);

        Launch same(kUser);
        QCOMPARE(same.p().queueCount(), 4);
        QCOMPARE(currentId(same.p()), 1001);
    }

    // ── the queue and the position ──────────────────────────────────────────

    void bothSectionsTheCurrentTrackAndThePositionComeBack() {
        {
            Launch a;
            a.p().setPlaybackSource(QStringLiteral("album"), QStringLiteral("7"),
                                    QStringLiteral("Life 1"));
            a.p().playTracks(contextOf(1000, 6), 2);
            a.p().addToQueue(one(9001));
            a.p().addToQueue(one(9002));
            a.p().seek(42000);
            a.p().savePlaybackState();
        }

        Launch b;
        auto &p = b.p();
        QCOMPARE(currentId(p), 1002);
        QCOMPARE(ids(p.queuePlayed()),  (QList<qlonglong>{1000, 1001}));
        QCOMPARE(ids(p.queueManual()),  (QList<qlonglong>{9001, 9002}));
        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{1003, 1004, 1005}));
        QCOMPARE(p.queueCount(), 8);
        QCOMPARE(p.position(), qint64(42000));
        QCOMPARE(p.contextName(), QStringLiteral("Life 1"));
        QCOMPARE(p.contextType(), QStringLiteral("album"));

        // And it is a working queue, not a snapshot: the manual rows still
        // drain before the album resumes.
        QList<qlonglong> order{ currentId(p) };
        for (int i = 0; i < 3; ++i) { p.next(); order.append(currentId(p)); }
        QCOMPARE(order, (QList<qlonglong>{1002, 9001, 9002, 1003}));
    }

    // Shuffle is stored as the order of the rows themselves, so a session
    // saved mid-shuffle resumes into the same running order.
    void aShuffledQueueComesBackInTheOrderItWasLeftIn() {
        QList<qlonglong> expected;
        {
            Launch a;
            a.p().playTracks(contextOf(1000, 40), 0);
            a.p().setShuffle(true);
            expected = ids(a.p().queueTracks());
            a.p().savePlaybackState();
        }

        Launch b;
        QCOMPARE(ids(b.p().queueTracks()), expected);
        QCOMPARE(b.p().shuffle(), true);
    }

    // ── a track that will not resolve any more ──────────────────────────────

    // The flat-out unresolvable case: a stored row with no track id behind it
    // can never name a stream, so the restore drops it instead of carrying a
    // dead row into the queue.
    void aStoredTrackThatCannotResolveIsDropped() {
        {
            Launch a;
            QVariantList ctx = contextOf(1000, 5);
            ctx[3] = trackOf(0, QStringLiteral("gone"));   // no id: unresolvable
            a.p().playTracks(ctx, 1);
            a.p().addToQueue(QVariantList{ trackOf(0, QStringLiteral("also gone")) });
            a.p().addToQueue(one(9002));
            a.p().savePlaybackState();
        }

        Launch b;
        auto &p = b.p();
        QCOMPARE(currentId(p), 1001);
        QCOMPARE(ids(p.queueManual()),  (QList<qlonglong>{9002}));
        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{1002, 1004}));
        QCOMPARE(ids(p.queuePlayed()),  (QList<qlonglong>{1000}));
        QCOMPARE(p.queueCount(), 5);   // seven stored, two of them unresolvable
        for (qlonglong id : ids(p.queueTracks()))
            QVERIFY2(id > 0, "a row that could never resolve survived the restore");
    }

    // The track that was playing is the one that is gone. The restore comes
    // back on the next row rather than on nothing at all, and drops the
    // position with it, because that position belonged to another track.
    void losingTheTrackItWasLeftOnComesBackOnTheNextOne() {
        {
            Launch a;
            QVariantList ctx = contextOf(1000, 4);
            ctx[1] = trackOf(0, QStringLiteral("gone"));
            a.p().playTracks(ctx, 1);
            a.p().seek(42000);
            a.p().savePlaybackState();
        }

        Launch b;
        QCOMPARE(currentId(b.p()), 1002);
        QCOMPARE(b.p().position(), qint64(0));
    }

    // The other half: the row looks fine, and the stream fetch fails anyway
    // (pulled from the catalogue, region-locked since). That path cannot be
    // reached from a test without a network, so the handler it ends in is
    // called directly.
    void aStreamThatWillNotResolveIsSteppedOverNotReported() {
        {
            Launch a;
            a.p().playTracks(contextOf(1000, 4), 0);
            a.p().addToQueue(one(9001));
            a.p().savePlaybackState();
        }

        Launch b;
        auto &p = b.p();
        QCOMPARE(currentId(p), 1000);

        QSignalSpy errorSpy(&p, &Player::error);
        QSignalSpy playingSpy(&p, &Player::playingChanged);

        p.skipUnplayableTrack();

        // The dead row is gone and the queue carried on. The row that moves up
        // is the one the user queued, which is consumed by taking over.
        QCOMPARE(currentId(p), 9001);
        QCOMPARE(p.manualCount(), 0);
        QVERIFY2(!ids(p.queueTracks()).contains(1000),
                 "the track that would not resolve is still in the queue");
        QCOMPARE(p.queueCount(), 4);

        // No error dialog at launch, and still nothing playing.
        QCOMPARE(errorSpy.count(), 0);
        for (const QList<QVariant> &args : playingSpy)
            QVERIFY2(!args.at(0).toBool(), "skipping a dead track started playback");

        // Even if every single one is dead, the restore ends quietly.
        p.skipUnplayableTrack();
        p.skipUnplayableTrack();
        p.skipUnplayableTrack();
        p.skipUnplayableTrack();
        QCOMPARE(p.queueCount(), 0);
        QCOMPARE(p.queueIndex(), -1);
        QCOMPARE(errorSpy.count(), 0);
    }

    // ── it comes back paused ────────────────────────────────────────────────

    // Nothing in a restore may start playback. The stream cannot resolve in a
    // test, so what is checked is that nothing ever claims to be playing and
    // that no transport was started on the way through.
    void aRestoredSessionNeverStartsPlayingByItself() {
        {
            Launch a;
            a.p().playTracks(contextOf(1000, 5), 2);
            a.p().seek(12000);
            a.p().savePlaybackState();
        }

        TidalApi    api;
        TidalClient client{&api};
        client.setUserId(kUser);
        Player player{&client};

        QSignalSpy playingSpy(&player, &Player::playingChanged);
        QTest::qWait(60);   // initAudio() and everything it sets going

        QCOMPARE(currentId(player), 1002);
        QCOMPARE(player.position(), qint64(12000));
        QVERIFY2(!player.playing(), "a restored session came back playing");

        for (const QList<QVariant> &args : playingSpy)
            QVERIFY2(!args.at(0).toBool(), "a restored session announced that it was playing");

        auto *qmp = player.findChild<QMediaPlayer *>();
        QVERIFY(qmp);
        QVERIFY2(qmp->playbackState() != QMediaPlayer::PlayingState,
                 "the media player was started by the restore");
    }

    // ── a stale or enormous queue must not slow the launch ──────────────────

    // Both halves of the bill: what quitting costs, and what the next launch
    // costs. The window around the cursor is capped, so a 5000-row playlist
    // cannot turn either into something the user notices. Measured at ~15ms to
    // save and ~5ms to come back here; the ceiling sits far enough above that
    // a loaded machine will not trip it and far enough below the uncapped cost
    // (hundreds of ms, and a settings file megabytes wide) to still catch it.
    void anEnormousQueueCostsNeitherEndAnythingNoticeable() {
        constexpr int kHuge = 5000;
        constexpr qint64 kCeilingMs = 250;

        qint64 saveMs = 0;
        {
            Launch a;
            a.p().playTracks(contextOf(1000, kHuge), kHuge / 2);
            a.p().addToQueue(contextOf(90000, 20));

            QElapsedTimer t;
            t.start();
            a.p().savePlaybackState();
            saveMs = t.elapsed();
        }

        QElapsedTimer t;
        t.start();
        TidalApi    api;
        TidalClient client{&api};
        client.setUserId(kUser);
        Player player{&client};
        const qint64 restoreMs = t.elapsed();

        const int stored =
            QSettings().value(QStringLiteral("user_%1/playback/queue").arg(kUser))
                .toByteArray().size();

        qInfo("a %d-row queue: %lldms to save, %lldms to come back, %d bytes stored, %d rows kept",
              kHuge, saveMs, restoreMs, stored, player.queueCount());

        QVERIFY2(saveMs < kCeilingMs,
                 qPrintable(QStringLiteral("saving a %1-row queue took %2ms")
                                .arg(kHuge).arg(saveMs)));
        QVERIFY2(restoreMs < kCeilingMs,
                 qPrintable(QStringLiteral("coming back to a %1-row queue took %2ms")
                                .arg(kHuge).arg(restoreMs)));

        // Capped, and still a usable session: what was playing, some of what
        // led up to it, everything the user queued, and plenty of what is next.
        QVERIFY2(player.queueCount() < kHuge,
                 "the whole queue was stored, so it can grow without limit");
        QCOMPARE(currentId(player), 1000 + kHuge / 2);
        QCOMPARE(player.manualCount(), 20);
        QVERIFY(player.queuePlayed().count()  > 0);
        QVERIFY(player.queueContext().count() > 100);
        QTest::qWait(30);
    }

    // A value written by another build, or a corrupted one, must not take the
    // launch down with it.
    void rubbishInTheSettingsIsIgnored() {
        QSettings s;
        const QString p = QStringLiteral("user_%1/playback/").arg(kUser);
        s.setValue(p + QStringLiteral("queue"), QByteArray("not a queue at all"));
        s.setValue(p + QStringLiteral("shuffle"), true);
        s.sync();

        Launch a;
        QCOMPARE(a.p().queueCount(), 0);
        QCOMPARE(a.p().queueIndex(), -1);
        QCOMPARE(a.p().shuffle(), true);   // the readable parts still apply
    }

    // A restore that lands in the middle of a session would pull the queue out
    // from under whatever is playing.
    void restoringDoesNotDisturbASessionAlreadyUnderWay() {
        {
            Launch a;
            a.p().playTracks(contextOf(1000, 4), 0);
            a.p().savePlaybackState();
        }

        Launch b;
        QCOMPARE(b.p().queueCount(), 4);

        b.p().playTracks(contextOf(2000, 3), 1);
        b.p().addToQueue(one(9001));
        b.client.setUserId(kUser);   // a token refresh re-announcing the account

        QCOMPARE(currentId(b.p()), 2001);
        QCOMPARE(ids(b.p().queueManual()), (QList<qlonglong>{9001}));
        QCOMPARE(b.p().queueCount(), 4);
    }

private:
    QTemporaryDir m_settingsDir;
};

QTEST_MAIN(TestQueuePersist)
#include "tst_queue_persist.moc"
