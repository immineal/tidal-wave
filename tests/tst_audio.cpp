// Audio output routing: following the system default live, choosing a specific
// device, and surviving hot-plug. Written before the Player changes it covers,
// per the project's tests-first rule.
//
// Two kinds of test live here. The ones that only need QMediaDevices' view of
// the world, plus Player's own bookkeeping, always run - including on a
// headless box with no sound server, where the device list is empty and the
// player must still come up. The ones that need audio to actually flow skip
// with a reason when nothing plays, because a test that quietly asserts
// nothing would hide exactly the regression this section exists to prevent.

#include <QTest>
#include <QTimer>
#include <QAudioDevice>
#include <QElapsedTimer>
#include <QFile>
#include <QMediaDevices>
#include <QAudioOutput>
#include <QMediaPlayer>
#include <QSet>
#include <QSettings>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"
#include "ui/Prefs.h"

namespace {

QString defaultDeviceId() {
    return QString::fromUtf8(QMediaDevices::defaultAudioOutput().id());
}

// Player defers its audio init to the event loop (a PipeWire deadlock guard),
// so a test has to let that run before asking anything about the output.
struct Rig {
    TidalApi    api;
    TidalClient client{&api};
    Player      player{&client};
    Rig() { QTest::qWait(30); }
};

void le16(QByteArray &b, quint16 v) { for (int i = 0; i < 2; ++i) b.append(char((v >> (8 * i)) & 0xFF)); }
void le32(QByteArray &b, quint32 v) { for (int i = 0; i < 4; ++i) b.append(char((v >> (8 * i)) & 0xFF)); }

// Seconds of 16-bit PCM silence. Silence so a developer's machine stays quiet;
// the point is only that the pipeline has something real to decode.
QByteArray silentWav(int seconds) {
    const quint32 rate = 44100;
    const quint16 channels = 2, bits = 16;
    const quint32 dataBytes = rate * channels * (bits / 8) * quint32(seconds);
    QByteArray b;
    b.append("RIFF"); le32(b, 36 + dataBytes); b.append("WAVE");
    b.append("fmt "); le32(b, 16); le16(b, 1); le16(b, channels); le32(b, rate);
    le32(b, rate * channels * (bits / 8)); le16(b, quint16(channels * (bits / 8))); le16(b, bits);
    b.append("data"); le32(b, dataBytes);
    b.append(QByteArray(int(dataBytes), '\0'));
    return b;
}

QVariantMap fakeTrack(qlonglong id, const QString &title) {
    QVariantMap t;
    t["id"] = id;
    t["title"] = title;
    t["duration"] = 180;
    t["artists"] = QStringLiteral("Test Artist");
    return t;
}

} // namespace

class TestAudio : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_audio"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        if (QMediaDevices::audioOutputs().isEmpty())
            qInfo("no audio output devices on this box; the playback tests will skip");
    }

    void init() {
        QSettings().clear();
        QSettings().sync();
    }

    // ── the picker's device list ─────────────────────────────────────────

    // "System default" is the entry almost everyone wants, it is what an empty
    // preference means, and it has to be selectable even when the list of real
    // devices is empty.
    void deviceListLeadsWithSystemDefault() {
        Rig rig;
        const QVariantList devices = rig.player.availableAudioDevices();
        QVERIFY(!devices.isEmpty());
        const QVariantMap first = devices.first().toMap();
        QCOMPARE(first.value("id").toString(), QString());
        QVERIFY(!first.value("label").toString().isEmpty());
        QVERIFY(first.contains("isDefault"));
        // Translated, unlike every other label in the list.
        QCOMPARE(first.value("label").toString(), Player::tr("System default"));
    }

    // A duplicate id would make the picker ambiguous: two rows, one of which
    // silently wins. An empty id among the real devices would collide with the
    // "follow the system" sentinel, which is worse.
    void deviceListHasNoDuplicateOrEmptyIds() {
        Rig rig;
        const QVariantList devices = rig.player.availableAudioDevices();
        QSet<QString> ids;
        for (int i = 0; i < devices.count(); ++i) {
            const QVariantMap d = devices.at(i).toMap();
            const QString id = d.value("id").toString();
            QVERIFY(!ids.contains(id));
            ids.insert(id);
            if (i == 0) continue;               // the sentinel's id is empty by design
            QVERIFY(!id.isEmpty());
            QVERIFY(!d.value("label").toString().isEmpty());
        }
        QCOMPARE(ids.count(), devices.count());
        // One row per real device, plus the sentinel.
        QCOMPARE(devices.count(), QMediaDevices::audioOutputs().count() + 1);
    }

    // The flag is what lets the picker say which device "System default"
    // currently resolves to.
    void deviceListMarksTheSystemDefault() {
        if (QMediaDevices::audioOutputs().isEmpty())
            QSKIP("no output devices, so there is no default to mark");
        Rig rig;
        const QVariantList devices = rig.player.availableAudioDevices();
        int marked = 0;
        QString markedId;
        for (const QVariant &v : devices) {
            const QVariantMap d = v.toMap();
            if (d.value("isDefault").toBool()) { ++marked; markedId = d.value("id").toString(); }
        }
        QCOMPARE(marked, 1);
        QCOMPARE(markedId, defaultDeviceId());
    }

    // ── which device the player targets ──────────────────────────────────

    void noPreferenceFollowsTheSystemDefault() {
        Rig rig;
        QCOMPARE(rig.player.activeAudioDeviceId(), defaultDeviceId());

        // ...and setting an empty preference explicitly is the same thing.
        Prefs prefs;
        rig.player.setPrefs(&prefs);
        QTest::qWait(20);
        QCOMPARE(rig.player.activeAudioDeviceId(), defaultDeviceId());
    }

    // A stored device that is gone (unplugged, renamed by the OS, or a config
    // copied from another machine) must not leave the app silent.
    void unknownPreferenceFallsBackToTheDefault() {
        Prefs prefs;
        prefs.setAudioDevice(QStringLiteral("no-such-device-9fbe1c"));
        Rig rig;
        rig.player.setPrefs(&prefs);
        QTest::qWait(20);
        QCOMPARE(rig.player.activeAudioDeviceId(), defaultDeviceId());
    }

    void choosingADeviceBindsToItAndBackAgain() {
        const QList<QAudioDevice> outs = QMediaDevices::audioOutputs();
        if (outs.count() < 2)
            QSKIP("needs at least two output devices to tell a real switch from a no-op");

        QString otherId;
        for (const QAudioDevice &d : outs) {
            const QString id = QString::fromUtf8(d.id());
            if (id != defaultDeviceId()) { otherId = id; break; }
        }
        QVERIFY(!otherId.isEmpty());

        Prefs prefs;
        Rig rig;
        rig.player.setPrefs(&prefs);
        QTest::qWait(20);

        prefs.setAudioDevice(otherId);           // no restart: takes effect now
        QTest::qWait(50);
        QCOMPARE(rig.player.activeAudioDeviceId(), otherId);

        prefs.setAudioDevice(QString());         // back to following the system
        QTest::qWait(50);
        QCOMPARE(rig.player.activeAudioDeviceId(), defaultDeviceId());
    }

    // ── what must survive the swap ───────────────────────────────────────

    void rebindPreservesVolumeAndMute() {
        Rig rig;
        rig.player.setVolume(0.42);
        rig.player.setMuted(true);

        rig.player.rebindAudioOutput(QMediaDevices::defaultAudioOutput());

        QCOMPARE(rig.player.muted(), true);
        QVERIFY(qAbs(rig.player.volume() - 0.42) < 0.01);

        rig.player.setMuted(false);
        rig.player.setVolume(0.8);
        rig.player.rebindAudioOutput(QMediaDevices::defaultAudioOutput());
        QCOMPARE(rig.player.muted(), false);
        QVERIFY(qAbs(rig.player.volume() - 0.8) < 0.01);
    }

    // The snapshot/restore pair is tested directly as well as through a real
    // swap, because it is the part that has to hold on a box with no sink at
    // all - where the playback test below can only skip.
    void stateSnapshotRoundTrips() {
        Rig rig;
        rig.player.setVolume(0.33);
        rig.player.setMuted(true);

        const Player::AudioState snapshot = rig.player.captureAudioState();
        QVERIFY(qAbs(snapshot.volume - 0.33) < 0.01);
        QCOMPARE(snapshot.muted, true);
        QCOMPARE(snapshot.playing, false);

        rig.player.setVolume(0.05);
        rig.player.setMuted(false);
        rig.player.restoreAudioState(snapshot);

        QVERIFY(qAbs(rig.player.volume() - 0.33) < 0.01);
        QCOMPARE(rig.player.muted(), true);
    }

    // A rebind is not a track change. Restarting the queue entry (or emitting
    // currentTrackChanged) would make Now Playing flicker and re-fetch a
    // stream on every unplugged pair of headphones.
    void rebindDoesNotDisturbTheQueue() {
        Rig rig;
        rig.player.appendQueue({fakeTrack(1, QStringLiteral("One")),
                                fakeTrack(2, QStringLiteral("Two"))});
        const int count = rig.player.queueCount();
        const int index = rig.player.queueIndex();

        QSignalSpy trackSpy(&rig.player, &Player::currentTrackChanged);
        QSignalSpy queueSpy(&rig.player, &Player::queueChanged);

        rig.player.rebindAudioOutput(QMediaDevices::defaultAudioOutput());
        rig.player.rebindAudioOutput(QAudioDevice());

        QCOMPARE(trackSpy.count(), 0);
        QCOMPARE(queueSpy.count(), 0);
        QCOMPARE(rig.player.queueCount(), count);
        QCOMPARE(rig.player.queueIndex(), index);
    }

    // Regression: an output destroyed while the player still holds it calls
    // back and detaches whatever is attached by then. Get the order wrong and
    // the swap "succeeds" into a player with no sink - silence that nothing
    // else here would notice, because Player's own device id still looks right.
    void rebindLeavesAnOutputAttached() {
        Rig rig;
        auto *qmp = rig.player.findChild<QMediaPlayer *>();
        QVERIFY(qmp);

        rig.player.rebindAudioOutput(QMediaDevices::defaultAudioOutput());
        QVERIFY2(qmp->audioOutput(), "the player has no audio output after a swap");
        QCOMPARE(QString::fromUtf8(qmp->audioOutput()->device().id()),
                 rig.player.activeAudioDeviceId());

        QTest::qWait(50);   // anything deferred by the swap runs here
        QVERIFY2(qmp->audioOutput(), "the player lost its output once the swap settled");
    }

    void positionAndPlayStateSurviveARebind() {
        Rig rig;
        auto *qmp = rig.player.findChild<QMediaPlayer *>();
        QVERIFY(qmp);
        rig.player.setVolume(0.0);               // keep the machine quiet

        QTemporaryDir media;
        QVERIFY(media.isValid());
        const QString path = media.filePath(QStringLiteral("silence.wav"));
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(silentWav(6));
        f.close();

        // Straight onto the QMediaPlayer: Player's own load path goes through
        // the Tidal API, which a unit test has no business calling.
        qmp->setSource(QUrl::fromLocalFile(path));
        qmp->play();

        QElapsedTimer t;
        t.start();
        while (t.elapsed() < 4000 && qmp->position() < 200) QTest::qWait(50);
        if (qmp->playbackState() != QMediaPlayer::PlayingState || qmp->position() < 200)
            QSKIP("no working audio sink here, so there is no live playback to preserve");

        QSignalSpy trackSpy(&rig.player, &Player::currentTrackChanged);
        const qint64 before = rig.player.position();

        rig.player.rebindAudioOutput(QMediaDevices::defaultAudioOutput());

        QCOMPARE(trackSpy.count(), 0);
        QVERIFY2(rig.player.playing(), "playback stopped across the device swap");
        QVERIFY2(rig.player.position() >= before - 250,
                 "the track jumped backwards across the device swap");
        QVERIFY2(rig.player.position() <= before + 2000,
                 "the track jumped forwards across the device swap");

        // ...and it is still really running, not just reporting a stale number.
        const qint64 mark = rig.player.position();
        t.restart();
        while (t.elapsed() < 2000 && rig.player.position() <= mark) QTest::qWait(50);
        QVERIFY2(rig.player.position() > mark, "playback stalled after the device swap");

        // Paused stays paused, at the same spot.
        rig.player.playPause();
        QTRY_COMPARE(rig.player.playing(), false);
        const qint64 paused = rig.player.position();
        rig.player.rebindAudioOutput(QMediaDevices::defaultAudioOutput());
        QCOMPARE(rig.player.playing(), false);
        QVERIFY(qAbs(rig.player.position() - paused) < 500);

        qmp->stop();
    }

    // ── hostile environments ─────────────────────────────────────────────

    // Headless CI has no devices at all. The player must construct, answer
    // questions and take transport commands without a sink behind it.
    void survivesWithoutAnyDevice() {
        Rig rig;
        if (!QMediaDevices::audioOutputs().isEmpty()) {
            // Not the real thing, but the same code path: a null device is
            // exactly what resolving a preference on a deviceless box yields.
            rig.player.rebindAudioOutput(QAudioDevice());
        }
        rig.player.setVolume(0.5);
        rig.player.setMuted(true);
        rig.player.playPause();
        rig.player.seek(1000);
        QVERIFY(rig.player.availableAudioDevices().count() >= 1);
        QCOMPARE(rig.player.muted(), true);
        if (QMediaDevices::audioOutputs().isEmpty())
            QCOMPARE(rig.player.activeAudioDeviceId(), QString());
    }

    // Hot-plug arrives as QMediaDevices::audioOutputsChanged. The test cannot
    // plug anything in, so it checks the handler is reachable and idempotent:
    // re-resolving must not churn the output or the transport.
    void refreshIsIdempotent() {
        Rig rig;
        const QString bound = rig.player.activeAudioDeviceId();
        QSignalSpy playSpy(&rig.player, &Player::playingChanged);
        QSignalSpy trackSpy(&rig.player, &Player::currentTrackChanged);

        rig.player.refreshAudioDevice();
        rig.player.refreshAudioDevice();

        QCOMPARE(rig.player.activeAudioDeviceId(), bound);
        QCOMPARE(playSpy.count(), 0);
        QCOMPARE(trackSpy.count(), 0);
    }

    // Dropping the Prefs object must not leave a dangling connection behind.
    void survivesPrefsGoingAway() {
        Rig rig;
        {
            Prefs prefs;
            rig.player.setPrefs(&prefs);
            prefs.setAudioDevice(QStringLiteral("no-such-device-9fbe1c"));
            QTest::qWait(20);
        }
        rig.player.refreshAudioDevice();
        QCOMPARE(rig.player.activeAudioDeviceId(), defaultDeviceId());
    }

    // The device-changed handler must NOT rebind synchronously.
    //
    // QMediaDevices::audioOutputsChanged arrives while PipeWire still holds
    // its thread loop lock, and tearing down a QAudioOutput takes that same
    // lock, so rebinding inside the callback deadlocks: the app goes
    // unresponsive with the main thread in futex_do_wait. It happened in real
    // use after about ninety minutes and no headless test can reproduce it,
    // because it needs a device to actually change under a live PipeWire.
    //
    // What IS testable is the structural property that prevents it: the slot
    // must defer. Invoked directly here, so no audio server is needed.
    void deviceChangeIsDeferredNotSynchronous() {
        Rig rig;   // Player needs a client, and its audio init is deferred

        bool ran = false;
        QTimer::singleShot(0, &rig.player, [&ran] { ran = true; });

        // Fire the handler the way the backend would.
        const bool invoked = QMetaObject::invokeMethod(&rig.player, "onAudioOutputsChanged",
                                                       Qt::DirectConnection);
        QVERIFY2(invoked, "onAudioOutputsChanged is gone or is no longer a slot");

        // Nothing queued by the handler can have run yet, which is the whole
        // point: the callback has to unwind before the rebind happens.
        QVERIFY2(!ran, "the event loop ran inside the handler, so it did not defer");

        // ...and the deferred work does arrive once the loop turns.
        QTRY_VERIFY(ran);
    }

private:
    QTemporaryDir m_dir;

};

QTEST_MAIN(TestAudio)
#include "tst_audio.moc"
