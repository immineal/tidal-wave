// What survives quitting the app, and what must not happen on the way back.
// The session is stored per Tidal account in the Player's own QSettings:
// volume, mute, shuffle, repeat, both queue sections, the current track and
// the position inside it. It comes back paused with nothing fetched, and on
// play a saved track that no longer resolves is stepped over.

#include <QTest>
#include <QAudio>
#include <QAudioOutput>
#include <QDataStream>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QElapsedTimer>
#include <QHash>
#include <QMediaPlayer>
#include <QSettings>
#include <QSignalSpy>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <memory>

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

// Answers every stream fetch as the test says, a turn of the event loop later
// like a reply, and records what was asked for. Nothing reaches the network.
class ScriptedClient : public TidalClient {
public:
    enum Answer { Silent, Unreachable, Unavailable, NotForAccount };
    using TidalClient::TidalClient;

    Answer                   answer = Silent;   // for any track not named below
    QHash<qlonglong, Answer> answerFor;
    QList<qlonglong>         asked;
    int                      undelivered = 0;   // replies scheduled, not yet handled

    void fetchStreamManifest(qint64 trackId, StreamCb cb) override {
        asked.append(trackId);
        const Answer a = answerFor.value(trackId, answer);
        if (a == Silent) return;
        ++undelivered;
        QTimer::singleShot(0, this, [this, cb = std::move(cb), a] {
            StreamManifest m;
            if (a == Unavailable)   m.reason = StreamManifest::Gone;
            if (a == NotForAccount) m.reason = StreamManifest::NotForAccount;
            cb(m, a == Unavailable   ? QStringLiteral("Not Found")
                : a == NotForAccount ? QStringLiteral("only a preview")
                                     : QStringLiteral("Host not found"));
            --undelivered;
        });
    }
};

// One launch of the app. The account id is set before the Player exists, so
// the Player restores from its constructor as it does at startup. The Player
// goes first on the way out.
struct Launch {
    TidalApi                api;
    ScriptedClient          client{&api};
    std::unique_ptr<Player> player;

    explicit Launch(ScriptedClient::Answer answer = ScriptedClient::Silent,
                    qint64 uid = kUser) {
        client.answer = answer;
        client.setUserId(uid);
        player = std::make_unique<Player>(&client);
    }
    Player &p() { return *player; }
    // Returns once the audio is up and every reply has been handled, along
    // with whatever fetch it set off in turn. No fixed wait is involved.
    bool settle() {
        return QTest::qWaitFor([this] {
            return player->findChild<QMediaPlayer *>() && client.undelivered == 0;
        }, 10000);
    }
};

// Five rows left on the third, twelve seconds in.
bool saveFiveRowSession() {
    Launch a;
    if (!a.settle()) return false;
    a.p().playTracks(contextOf(1000, 5), 2);
    a.p().seek(12000);
    a.p().savePlaybackState();
    return true;
}

} // namespace

class TestQueuePersist : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_queue_persist"));
        // The settings file is redirected into a scratch directory, so no run
        // touches or leaves anything in the user's home.
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_settingsDir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_settingsDir.path());
    }

    void init() {
        QSettings().clear();   // every test starts from a fresh install
        const QDir dir = rowsDir();
        for (const QString &f : dir.entryList({ QStringLiteral("queue-*") }, QDir::Files))
            QFile::remove(dir.filePath(f));
    }

    // ── the knobs ───────────────────────────────────────────────────────────

    void volumeMuteShuffleAndRepeatComeBack() {
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 6), 0);
            a.p().setVolume(0.33);
            a.p().setMuted(true);
            a.p().setShuffle(true);
            a.p().setRepeatMode(1);
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.settle());
        QVERIFY(qAbs(b.p().volume() - 0.33) < 0.001);
        QCOMPARE(b.p().muted(), true);
        QCOMPARE(b.p().shuffle(), true);
        QCOMPARE(b.p().repeatMode(), 1);
    }

    // An earlier version saved the output's linear factor. It comes back as
    // loud as it was, with the slider where that loudness sits.
    void aVolumeAnEarlierVersionSavedSoundsTheSame() {
        QSettings().setValue(QStringLiteral("user_%1/playback/volume").arg(kUser), 0.33);
        Launch b;
        QVERIFY(b.settle());
        const double slider = QAudio::convertVolume(0.33f, QAudio::LinearVolumeScale,
                                                    QAudio::LogarithmicVolumeScale);
        QVERIFY2(qAbs(b.p().volume() - slider) < 0.001, qPrintable(QString::number(b.p().volume())));
        QAudioOutput *out = b.p().findChild<QAudioOutput *>();
        QVERIFY(out);
        QVERIFY2(qAbs(out->volume() - 0.33) < 0.001, qPrintable(QString::number(out->volume())));
    }

    // A fresh install restores nothing and asks for nothing.
    void nothingSavedMeansNothingRestored() {
        Launch a;
        QVERIFY(a.settle());
        QVERIFY(a.client.asked.isEmpty());
        QCOMPARE(a.p().queueCount(), 0);
        QCOMPARE(a.p().queueIndex(), -1);
        QCOMPARE(a.p().shuffle(), false);
        QCOMPARE(a.p().repeatMode(), 0);
    }

    // The state is per account, so signing in as somebody else gets their
    // session and not the last one.
    void theSessionIsPerAccount() {
        {
            Launch a(ScriptedClient::Silent, kUser);
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 4), 1);
            a.p().savePlaybackState();
        }
        Launch other(ScriptedClient::Silent, kUser + 1);
        QVERIFY(other.settle());
        QCOMPARE(other.p().queueCount(), 0);

        Launch same(ScriptedClient::Silent, kUser);
        QVERIFY(same.settle());
        QCOMPARE(same.p().queueCount(), 4);
        QCOMPARE(currentId(same.p()), 1001);
    }

    // ── the queue and the position ──────────────────────────────────────────

    void bothSectionsTheCurrentTrackAndThePositionComeBack() {
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().setPlaybackSource(QStringLiteral("album"), QStringLiteral("7"),
                                    QStringLiteral("Life 1"));
            a.p().playTracks(contextOf(1000, 6), 2);
            a.p().addToQueue(one(9001));
            a.p().addToQueue(one(9002));
            a.p().seek(42000);
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.settle());
        auto &p = b.p();
        QCOMPARE(currentId(p), 1002);
        QCOMPARE(ids(p.queuePlayed()),  (QList<qlonglong>{1000, 1001}));
        QCOMPARE(ids(p.queueManual()),  (QList<qlonglong>{9001, 9002}));
        QCOMPARE(ids(p.queueContext()), (QList<qlonglong>{1003, 1004, 1005}));
        QCOMPARE(p.queueCount(), 8);
        QCOMPARE(p.position(), qint64(42000));
        QCOMPARE(p.contextName(), QStringLiteral("Life 1"));
        QCOMPARE(p.contextType(), QStringLiteral("album"));

        // And it is a working queue: the manual rows still drain before the
        // album resumes.
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
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 40), 0);
            a.p().setShuffle(true);
            expected = ids(a.p().queueTracks());
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.settle());
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
            QVERIFY(a.settle());
            QVariantList ctx = contextOf(1000, 5);
            ctx[3] = trackOf(0, QStringLiteral("gone"));   // no id: unresolvable
            a.p().playTracks(ctx, 1);
            a.p().addToQueue(QVariantList{ trackOf(0, QStringLiteral("also gone")) });
            a.p().addToQueue(one(9002));
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.settle());
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
            QVERIFY(a.settle());
            QVariantList ctx = contextOf(1000, 4);
            ctx[1] = trackOf(0, QStringLiteral("gone"));
            a.p().playTracks(ctx, 1);
            a.p().seek(42000);
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.settle());
        QCOMPARE(currentId(b.p()), 1002);
        QCOMPARE(b.p().position(), qint64(0));
    }

    // The row looks fine and Tidal rules the track out anyway, as it does for
    // one pulled from the catalogue. Play steps over it and says so.
    void aStreamThatWillNotResolveIsSteppedOverOnPlay() {
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 4), 0);
            a.p().addToQueue(one(9001));
            a.p().savePlaybackState();
        }

        {
            Launch b;
            b.client.answerFor[1000] = ScriptedClient::Unavailable;
            auto &p = b.p();
            QCOMPARE(currentId(p), 1000);

            QSignalSpy errorSpy(&p, &Player::error);
            QVERIFY(b.settle());
            QCOMPARE(b.client.asked, QList<qlonglong>());

            // The dead row is gone and the queue carried on. The row that moves
            // up is the one the user queued, which is consumed by taking over.
            p.playPause();
            QVERIFY(b.settle());
            QCOMPARE(b.client.asked, (QList<qlonglong>{1000, 9001}));
            QCOMPARE(currentId(p), 9001);
            QCOMPARE(p.manualCount(), 0);
            QVERIFY2(!ids(p.queueTracks()).contains(1000),
                     "the track that would not resolve is still in the queue");
            QCOMPARE(p.queueCount(), 4);
            QCOMPARE(errorSpy.count(), 1);
            QCOMPARE(errorSpy.at(0).at(0).toString(),
                     QStringLiteral("“T1000” is no longer available on Tidal and was skipped."));
        }

        // Four rows, every one of them dead: fewer than a run that gives up,
        // so play drops them all and ends.
        Launch c(ScriptedClient::Unavailable);
        QSignalSpy errorSpy(&c.p(), &Player::error);
        QVERIFY(c.settle());
        c.p().playPause();
        QVERIFY(c.settle());
        QCOMPARE(c.client.asked, (QList<qlonglong>{9001, 1001, 1002, 1003}));
        QCOMPARE(c.p().queueCount(), 0);
        QCOMPARE(c.p().queueIndex(), -1);
        QVERIFY(!c.p().playing());
        QCOMPARE(c.p().loadError(),
                 QStringLiteral("Several tracks are no longer available on Tidal and were skipped."));
    }

    // Play on a restored session asks for five rows in a row and for no more,
    // however many are saved. The rows it did not ask for are as they were,
    // the queue rests on the first of them, and one sentence says why.
    void aRestoreStopsAskingAfterARunOfRowsThatCannotBePlayed_data() {
        QTest::addColumn<int>("answer");
        QTest::addColumn<QList<qlonglong>>("rowsLeft");
        QTest::addColumn<QString>("said");

        QList<qlonglong> all;
        for (qlonglong id = 1000; id < 1040; ++id) all.append(id);
        QTest::newRow("Tidal has none of them")
            << int(ScriptedClient::Unavailable)
            << (all.mid(0, 2) + all.mid(7))
            << QStringLiteral("Several tracks in a row are no longer available on Tidal, "
                              "so playback stopped here.");
        QTest::newRow("none is for this account")
            << int(ScriptedClient::NotForAccount) << all
            << QStringLiteral("Several tracks in a row are not available for your account "
                              "or region, so playback stopped here.");
    }

    void aRestoreStopsAskingAfterARunOfRowsThatCannotBePlayed() {
        QFETCH(int, answer);
        QFETCH(QList<qlonglong>, rowsLeft);
        QFETCH(QString, said);
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 40), 2);
            a.p().seek(12000);
            a.p().savePlaybackState();
        }
        {
            Launch b{ScriptedClient::Answer(answer)};
            QSignalSpy errorSpy(&b.p(), &Player::error);
            QVERIFY(b.settle());
            QCOMPARE(b.client.asked, QList<qlonglong>());
            b.p().playPause();
            QVERIFY(b.settle());

            QVERIFY2(b.client.asked == (QList<qlonglong>{1002, 1003, 1004, 1005, 1006}),
                     qPrintable(QStringLiteral("%1 rows were asked for").arg(b.client.asked.count())));
            QCOMPARE(ids(b.p().queueTracks()), rowsLeft);
            QCOMPARE(currentId(b.p()), 1007);
            QCOMPARE(b.p().position(), qint64(0));
            QVERIFY(!b.p().loading());
            QVERIFY(!b.p().playing());
            QCOMPARE(b.p().loadError(), said);
            QCOMPARE(errorSpy.constLast().at(0).toString(), said);

            // Play is the user's own request for the row the queue rests on.
            b.client.answer = ScriptedClient::Silent;
            b.p().playPause();
            QCOMPARE(b.client.asked.count(), 6);
            QCOMPARE(b.client.asked.constLast(), 1007);
        }

        Launch c;
        QVERIFY(c.settle());
        QCOMPARE(ids(c.p().queueTracks()), rowsLeft);
        QCOMPARE(currentId(c.p()), 1007);
    }

    // ── a launch that cannot ask ────────────────────────────────────────────

    // A request that fails says nothing about the track, so no row is dropped
    // for it. With no network that is every row's request.
    void aRestoreThatCannotReachTidalKeepsTheWholeQueue() {
        QVERIFY(saveFiveRowSession());
        {
            Launch b(ScriptedClient::Unreachable);
            QSignalSpy errorSpy(&b.p(), &Player::error);
            QVERIFY(b.settle());
            b.p().playPause();
            QVERIFY(b.settle());

            QCOMPARE(b.client.asked, (QList<qlonglong>{1002}));
            QCOMPARE(ids(b.p().queueTracks()),
                     (QList<qlonglong>{1000, 1001, 1002, 1003, 1004}));
            QCOMPARE(currentId(b.p()), 1002);
            QCOMPARE(b.p().position(), qint64(12000));
            QVERIFY(!b.p().loading());
            QVERIFY(!b.p().playing());
            QCOMPARE(errorSpy.count(), 1);
        }

        // The Player saves on its way out, so the next launch shows what it kept.
        Launch c;
        QVERIFY(c.settle());
        QCOMPARE(c.p().queueCount(), 5);
        QCOMPARE(currentId(c.p()), 1002);
        QCOMPARE(c.p().position(), qint64(12000));
    }

    // Tidal has the track and does not play it to this account. The row stays
    // in the queue, play passes over it, and the next launch finds every row.
    void aTrackTheAccountMayNotPlayIsPassedOverOnRestoreAndKept() {
        QVERIFY(saveFiveRowSession());
        {
            Launch b;
            b.client.answerFor[1002] = ScriptedClient::NotForAccount;
            QSignalSpy errorSpy(&b.p(), &Player::error);
            QVERIFY(b.settle());
            b.p().playPause();
            QVERIFY(b.settle());

            QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1003}));
            QCOMPARE(ids(b.p().queueTracks()),
                     (QList<qlonglong>{1000, 1001, 1002, 1003, 1004}));
            QCOMPARE(currentId(b.p()), 1003);
            QCOMPARE(b.p().position(), qint64(0));
            QCOMPARE(errorSpy.count(), 1);
            QCOMPARE(errorSpy.at(0).at(0).toString(),
                     QStringLiteral("“T1002” is not available for your account or region "
                                    "and was skipped."));
        }

        Launch c;
        QVERIFY(c.settle());
        QCOMPARE(c.p().queueCount(), 5);
        QCOMPARE(currentId(c.p()), 1003);
    }

    // The account gets none of the saved rows. Play asks for those from the
    // saved one to the end and rests there with the queue whole.
    void aRestoreOntoRowsTheAccountMayNotPlayKeepsTheQueue() {
        QVERIFY(saveFiveRowSession());

        Launch b(ScriptedClient::NotForAccount);
        QVERIFY(b.settle());
        b.p().playPause();
        QVERIFY(b.settle());

        QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1003, 1004}));
        QCOMPARE(ids(b.p().queueTracks()), (QList<qlonglong>{1000, 1001, 1002, 1003, 1004}));
        QCOMPARE(currentId(b.p()), 1004);
        QVERIFY(!b.p().loading());
        QVERIFY(!b.p().playing());

        // Play again asks for the row it rests on, and its failure is said.
        QSignalSpy errorSpy(&b.p(), &Player::error);
        b.p().playPause();
        QVERIFY(b.settle());
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1003, 1004, 1004}));
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(),
                 QStringLiteral("This track is not available for your account or region."));
    }

    // The other answer: Tidal no longer has the track. On play that row is
    // dropped and the one after it is asked for.
    void aTrackTidalRulesOutIsSteppedOverOnRestore() {
        QVERIFY(saveFiveRowSession());

        Launch b;
        b.client.answerFor[1002] = ScriptedClient::Unavailable;
        QSignalSpy errorSpy(&b.p(), &Player::error);
        QVERIFY(b.settle());
        b.p().playPause();
        QVERIFY(b.settle());

        QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1003}));
        QCOMPARE(ids(b.p().queueTracks()), (QList<qlonglong>{1000, 1001, 1003, 1004}));
        QCOMPARE(currentId(b.p()), 1003);
        QCOMPARE(b.p().position(), qint64(0));
        QCOMPARE(errorSpy.count(), 1);
    }

    // A track left unloaded is asked for again each time play is pressed, and
    // a failure then is reported like any other.
    void pressingPlayLoadsTheTrackAFailedRestoreLeftUnloaded() {
        QVERIFY(saveFiveRowSession());

        Launch b(ScriptedClient::Unreachable);
        QSignalSpy errorSpy(&b.p(), &Player::error);
        QVERIFY(b.settle());
        QCOMPARE(b.client.asked, QList<qlonglong>());
        QCOMPARE(errorSpy.count(), 0);

        b.p().playPause();
        QVERIFY(b.settle());
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002}));
        QCOMPARE(errorSpy.count(), 1);

        b.p().playPause();
        QVERIFY(b.settle());
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1002}));
        QCOMPARE(errorSpy.count(), 2);

        QCOMPARE(b.p().queueCount(), 5);
        QCOMPARE(currentId(b.p()), 1002);
        QCOMPARE(b.p().position(), qint64(12000));
    }

    // The saved position belongs to the saved track. Another track chosen
    // before that one ever loaded starts from its own beginning.
    void aPositionHeldForAnUnloadedTrackDoesNotCarryToAnother() {
        QVERIFY(saveFiveRowSession());

        Launch b(ScriptedClient::Unreachable);
        QVERIFY(b.settle());
        QCOMPARE(b.p().position(), qint64(12000));

        b.p().playTracks(contextOf(2000, 3), 0);
        QCOMPARE(currentId(b.p()), 2000);
        QCOMPARE(b.p().position(), qint64(0));
    }

    // ── it comes back paused ────────────────────────────────────────────────

    // Nothing in a restore may start playback, and nothing is asked for: a
    // launch that nobody listens to costs the account nothing.
    void aRestoredSessionNeverStartsPlayingByItself() {
        QVERIFY(saveFiveRowSession());

        Launch b;
        Player &player = b.p();
        QSignalSpy playingSpy(&player, &Player::playingChanged);
        QVERIFY(b.settle());
        QTest::qWait(60);   // whatever initAudio() set going has run by now

        QCOMPARE(b.client.asked, QList<qlonglong>());
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

    // ── a restore the user overtakes ────────────────────────────────────────

    // The user moves on from the restored track, 1002, before it ever played.
    // The load is the user's own and its failure is reported. A row the user
    // picked stays; one a step landed on is passed over.
    void aLoadTheUserStartsDuringARestoreIsTheUsersOwn_data() {
        QTest::addColumn<QString>("action");
        QTest::addColumn<qlonglong>("picked");
        QTest::addColumn<bool>("ruledOut");
        QTest::addColumn<qlonglong>("beyond");   // asked for after a step, 0 for none

        QTest::newRow("a new context")       << QStringLiteral("play")     << qlonglong(2000) << true  << qlonglong(0);
        QTest::newRow("next")                << QStringLiteral("next")     << qlonglong(1003) << true  << qlonglong(1004);
        QTest::newRow("previous")            << QStringLiteral("previous") << qlonglong(1001) << true  << qlonglong(1000);
        QTest::newRow("a queue jump")        << QStringLiteral("jump")     << qlonglong(1004) << true  << qlonglong(0);
        QTest::newRow("next, unreachable")   << QStringLiteral("next")     << qlonglong(1003) << false << qlonglong(0);
    }

    void aLoadTheUserStartsDuringARestoreIsTheUsersOwn() {
        QFETCH(QString, action);
        QFETCH(qlonglong, picked);
        QFETCH(bool, ruledOut);
        QFETCH(qlonglong, beyond);
        QVERIFY(saveFiveRowSession());

        Launch b;
        b.client.answerFor[picked] = ruledOut ? ScriptedClient::Unavailable
                                              : ScriptedClient::Unreachable;
        QSignalSpy errorSpy(&b.p(), &Player::error);
        QVERIFY(b.settle());
        QCOMPARE(b.client.asked, QList<qlonglong>());

        if (action == QLatin1String("play")) {
            b.p().playTracks(contextOf(2000, 3), 0);
        } else if (action == QLatin1String("next")) {
            b.p().next();
        } else if (action == QLatin1String("previous")) {
            // Twelve seconds in, the first press only rewinds.
            b.p().previous();
            b.p().previous();
        } else {
            b.p().jumpToQueue(4);
        }
        QVERIFY(b.settle());

        if (beyond) {
            QCOMPARE(b.client.asked, (QList<qlonglong>{picked, beyond}));
            QCOMPARE(currentId(b.p()), beyond);
            QVERIFY2(!ids(b.p().queueTracks()).contains(picked),
                     "the withdrawn track the step landed on is still in the queue");
        } else {
            QCOMPARE(b.client.asked, (QList<qlonglong>{picked}));
            QCOMPARE(currentId(b.p()), picked);
            QVERIFY2(ids(b.p().queueTracks()).contains(picked),
                     "the track the user picked was dropped from the queue");
        }
        QCOMPARE(errorSpy.count(), 1);
    }

    // ── a stale or enormous queue must not slow the launch ──────────────────

    // The whole queue comes back, however long, and saving it costs the GUI
    // thread next to nothing: the rows are written on a worker.
    void anEnormousQueueComesBackWholeAndCostsTheGuiThreadNothing() {
        constexpr int kHuge = 10000;
        constexpr qint64 kCeilingMs = 50;

        qint64 saveMs = 0, writtenMs = 0;
        QList<qlonglong> expected;
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, kHuge), kHuge / 2);
            a.p().addToQueue(contextOf(90000, 20));
            a.p().seek(42000);
            expected = ids(a.p().queueTracks());

            QElapsedTimer t;
            t.start();
            a.p().savePlaybackState();
            saveMs = t.elapsed();
            a.p().flushPlaybackState();
            writtenMs = t.elapsed();
        }

        QElapsedTimer t;
        t.start();
        Launch b;
        const qint64 restoreMs = t.elapsed();
        Player &player = b.p();

        qint64 stored = 0;
        const QFileInfoList files = rowsDir()
            .entryInfoList({ QStringLiteral("queue-*") }, QDir::Files);
        for (const QFileInfo &f : files) stored += f.size();

        qInfo("a %d-row queue: %lldms of the GUI thread to save, %lldms until written, "
              "%lldms to come back, %lld bytes stored, %d rows kept",
              kHuge + 20, saveMs, writtenMs, restoreMs, stored, player.queueCount());

        QVERIFY2(saveMs < kCeilingMs,
                 qPrintable(QStringLiteral("saving a %1-row queue held the GUI thread for %2ms")
                                .arg(kHuge).arg(saveMs)));
        QVERIFY2(restoreMs < 1000,
                 qPrintable(QStringLiteral("coming back to a %1-row queue took %2ms")
                                .arg(kHuge).arg(restoreMs)));

        QCOMPARE(ids(player.queueTracks()), expected);
        QCOMPARE(currentId(player), 1000 + kHuge / 2);
        QCOMPARE(player.manualCount(), 20);
        QCOMPARE(player.position(), qint64(42000));
        QVERIFY(b.settle());
    }

    // A move along the queue saves the cursor and leaves the rows alone.
    void aStepSavesTheCursorAndNotTheRows() {
        Launch a;
        QVERIFY(a.settle());
        a.p().playTracks(contextOf(1000, 50), 0);
        a.p().savePlaybackState();
        const QString key = QStringLiteral("user_%1/playback/queueGeneration").arg(kUser);
        const qulonglong first = QSettings().value(key).toULongLong();

        a.p().next();
        a.p().seek(5000);
        a.p().savePlaybackState();
        QCOMPARE(QSettings().value(key).toULongLong(), first);

        a.p().addToQueue(one(9001));
        a.p().savePlaybackState();
        QCOMPARE(QSettings().value(key).toULongLong(), first + 1);
    }

    // Saves in quick succession: the last state is the one that lands.
    void theLastOfManySavesWins() {
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 3000), 0);
            for (int i = 0; i < 20; ++i) {
                a.p().addToQueue(one(9000 + i));
                a.p().savePlaybackState();
            }
        }
        Launch b;
        QVERIFY(b.settle());
        QCOMPARE(b.p().manualCount(), 20);
        QCOMPARE(b.p().queueCount(), 3020);
        QCOMPARE(ids(b.p().queueManual()).constLast(), qlonglong(9019));
    }

    // The window of rows an earlier version kept in the settings comes back,
    // and the next save moves it into the file.
    void aQueueSavedByAnEarlierVersionComesBack() {
        const QString p = QStringLiteral("user_%1/playback/").arg(kUser);
        {
            QByteArray raw;
            QDataStream out(&raw, QIODevice::WriteOnly);
            out.setVersion(QDataStream::Qt_6_0);
            out << quint32(1) << qint32(4);
            for (qlonglong id : { 1000, 1001, 9001, 1002 })
                out << trackOf(id, QStringLiteral("T%1").arg(id)) << (id == 9001)
                    << qint32(id == 9001 ? -1 : int(id - 1000));
            out << qint32(1) << qint32(1) << qint64(7000);
            QSettings s;
            s.setValue(p + QStringLiteral("queue"), qCompress(raw, 6));
        }
        {
            Launch b;
            QVERIFY(b.settle());
            QCOMPARE(ids(b.p().queueTracks()), (QList<qlonglong>{1000, 1001, 9001, 1002}));
            QCOMPARE(currentId(b.p()), 1001);
            QCOMPARE(ids(b.p().queueManual()), (QList<qlonglong>{9001}));
            QCOMPARE(b.p().position(), qint64(7000));
            b.p().savePlaybackState();
        }
        QVERIFY(!QSettings().contains(p + QStringLiteral("queue")));
        Launch c;
        QVERIFY(c.settle());
        QCOMPARE(ids(c.p().queueTracks()), (QList<qlonglong>{1000, 1001, 9001, 1002}));
        QCOMPARE(currentId(c.p()), 1001);
        QCOMPARE(c.p().manualCount(), 1);
        QCOMPARE(c.p().position(), qint64(7000));
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
        QVERIFY(a.settle());
        QCOMPARE(a.p().queueCount(), 0);
        QCOMPARE(a.p().queueIndex(), -1);
        QCOMPARE(a.p().shuffle(), true);   // the readable parts still apply
    }

    // Nor does a rows file cut short or written by something else.
    void aDamagedRowsFileIsIgnored() {
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 200), 3);
            a.p().savePlaybackState();
        }
        const QStringList files = rowsDir().entryList({ QStringLiteral("queue-*") }, QDir::Files);
        QCOMPARE(files.size(), 1);
        QFile f(rowsDir().filePath(files.constFirst()));
        QVERIFY(f.open(QIODevice::ReadWrite));
        QVERIFY(f.resize(f.size() / 2));
        f.close();

        Launch b;
        QVERIFY(b.settle());
        QCOMPARE(b.p().queueCount(), 0);
        QCOMPARE(b.p().queueIndex(), -1);
    }

    // A restore that lands in the middle of a session would pull the queue out
    // from under whatever is playing.
    void restoringDoesNotDisturbASessionAlreadyUnderWay() {
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 4), 0);
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.settle());
        QCOMPARE(b.p().queueCount(), 4);

        b.p().playTracks(contextOf(2000, 3), 1);
        b.p().addToQueue(one(9001));
        b.client.setUserId(kUser);   // a token refresh re-announcing the account

        QCOMPARE(currentId(b.p()), 2001);
        QCOMPARE(ids(b.p().queueManual()), (QList<qlonglong>{9001}));
        QCOMPARE(b.p().queueCount(), 4);
    }

    // A row queued by hand is the track that was handed in, with no key of
    // the Player's own, in the queue and in the session it saves.
    void aTrackQueuedByHandCarriesNoKeyOfThePlayers() {
        const QVariantMap track = trackOf(9001, QStringLiteral("T9001"));
        {
            Launch a;
            QVERIFY(a.settle());
            a.p().playTracks(contextOf(1000, 3), 0);
            a.p().addToQueue(QVariantList{ track });
            QCOMPARE(a.p().queueManual().value(0).toMap().keys(), track.keys());
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.settle());
        QCOMPARE(ids(b.p().queueManual()), (QList<qlonglong>{9001}));
        QCOMPARE(b.p().queueManual().value(0).toMap().keys(), track.keys());
    }

private:
    // The rows are saved beside the settings file.
    static QDir rowsDir() { return QFileInfo(QSettings().fileName()).absoluteDir(); }

    QTemporaryDir m_settingsDir;
};

QTEST_MAIN(TestQueuePersist)
#include "tst_queue_persist.moc"
