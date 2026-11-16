// The command line and its hand-off to a running instance: what each option
// asks for, what goes over the single-instance socket, and that the running
// side acts on it only once it has a session.

#include <QCoreApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QSignalSpy>
#include <QThread>
#include <QTemporaryDir>
#include <QTest>

#include "ui/RemoteControl.h"

using Command = LaunchRequest::Command;

class TestRemoteControl : public QObject {
    Q_OBJECT

    static RemoteControl::Parsed parse(const QStringList &args) {
        return RemoteControl::parseArguments(QStringList{QStringLiteral("tidal-wave")} + args);
    }

private slots:
    void initTestCase() {
        QCoreApplication::setApplicationName(QStringLiteral("Tidal Wave"));
        QCoreApplication::setApplicationVersion(QStringLiteral("9.8.7"));
        QVERIFY(m_dir.isValid());
    }

    // ── the command line ────────────────────────────────────────────────

    void plainLaunchShows() {
        const auto p = parse({});
        QVERIFY(!p.exit);
        QVERIFY(p.request.isPlainShow());
    }

    void playbackOptions_data() {
        QTest::addColumn<QStringList>("args");
        QTest::addColumn<QList<Command>>("commands");
        QTest::newRow("play-pause") << QStringList{"--play-pause"} << QList<Command>{Command::PlayPause};
        QTest::newRow("next")       << QStringList{"--next"}       << QList<Command>{Command::Next};
        QTest::newRow("previous")   << QStringList{"--previous"}   << QList<Command>{Command::Previous};
        QTest::newRow("single dash") << QStringList{"-next"}       << QList<Command>{Command::Next};
        QTest::newRow("two") << QStringList{"--next", "--play-pause"}
                             << QList<Command>{Command::PlayPause, Command::Next};
    }
    void playbackOptions() {
        QFETCH(QStringList, args);
        QFETCH(QList<Command>, commands);
        const auto p = parse(args);
        QVERIFY2(!p.exit, qPrintable(p.error));
        QCOMPARE(p.request.commands, commands);
        // A media key bound to --next must not pull the window up.
        QVERIFY(!p.request.show);
    }

    void aLinkShowsAndIsCarried() {
        const auto p = parse({QStringLiteral("tidal://album/1")});
        QVERIFY(!p.exit);
        QVERIFY(p.request.show);
        QCOMPARE(p.request.urls, QStringList{QStringLiteral("tidal://album/1")});
    }

    void helpAndVersionEndTheLaunch_data() {
        QTest::addColumn<QString>("arg");
        QTest::addColumn<QString>("expect");
        QTest::newRow("--help")    << "--help"    << "--play-pause";
        QTest::newRow("-h")        << "-h"        << "--play-pause";
        QTest::newRow("--version") << "--version" << "Tidal Wave 9.8.7";
        QTest::newRow("-v")        << "-v"        << "Tidal Wave 9.8.7";
    }
    void helpAndVersionEndTheLaunch() {
        QFETCH(QString, arg);
        QFETCH(QString, expect);
        const auto p = parse({arg});
        QVERIFY(p.exit);
        QCOMPARE(p.exitCode, 0);
        QVERIFY2(p.output.contains(expect), qPrintable(p.output));
    }

    void anUnknownOptionIsAnError() {
        const auto p = parse({QStringLiteral("--frobnicate")});
        QVERIFY(p.exit);
        QCOMPARE(p.exitCode, 1);
        QVERIFY(p.error.contains(QStringLiteral("frobnicate")));
    }

    // main() answers these before any display connection is opened.
    void infoOptionsAreSpottedInTheRawArguments() {
        auto check = [](std::initializer_list<const char *> args) {
            QList<QByteArray> store;
            for (const char *a : args) store << QByteArray(a);
            QList<char *> argv;
            for (QByteArray &a : store) argv << a.data();
            return RemoteControl::asksForInfoOnly(int(argv.size()), argv.data());
        };
        QVERIFY(check({"tidal-wave", "--help"}));
        QVERIFY(check({"tidal-wave", "--next", "--version"}));
        QVERIFY(!check({"tidal-wave"}));
        QVERIFY(!check({"tidal-wave", "--next", "-reverse"}));
        QVERIFY(!check({"tidal-wave", "--", "--help"}));
    }

    // ── the socket message ──────────────────────────────────────────────

    // Every version before this one sends and expects exactly "show".
    void aPlainLaunchSendsTheOldMessage() {
        QCOMPARE(LaunchRequest{}.encode(), QByteArray("show"));
        const auto decoded = LaunchRequest::decode("show");
        QVERIFY(decoded);
        QVERIFY(decoded->isPlainShow());
    }

    void aRequestSurvivesTheTrip() {
        LaunchRequest r;
        r.show = false;
        r.commands = {Command::Next, Command::PlayPause};
        r.urls = {QStringLiteral("https://tidal.com/browse/track/5?u")};
        const QByteArray wire = r.encode();
        QVERIFY(wire.endsWith('\n'));
        QCOMPARE(wire.count('\n'), 1);
        const auto back = LaunchRequest::decode(wire);
        QVERIFY(back);
        QCOMPARE(*back, r);
    }

    void junkIsNotARequest() {
        QVERIFY(!LaunchRequest::decode("hello"));
        QVERIFY(!LaunchRequest::decode("[1,2]"));
        QVERIFY(!LaunchRequest::decode("{\"show\":"));
        // A command a later version added is skipped.
        const auto r = LaunchRequest::decode("{\"commands\":[\"shuffle\",\"next\"]}");
        QVERIFY(r);
        QCOMPARE(r->commands, QList<Command>{Command::Next});
    }

    // ── the running side ────────────────────────────────────────────────

    void commandsWaitUntilReady() {
        RemoteControl rc;
        QSignalSpy next(&rc, &RemoteControl::nextRequested);
        QSignalSpy show(&rc, &RemoteControl::showRequested);
        LaunchRequest r;
        r.show = false;
        r.commands = {Command::Next};
        rc.submit(r);
        QCOMPARE(next.count(), 0);
        QCOMPARE(show.count(), 0);
        rc.setReady(true);
        QCOMPARE(next.count(), 1);
        // Done once, not again on the next sign-in.
        rc.setReady(false);
        rc.setReady(true);
        QCOMPARE(next.count(), 1);
        rc.submit(r);
        QCOMPARE(next.count(), 2);
    }

    void showDoesNotWait() {
        RemoteControl rc;
        QSignalSpy show(&rc, &RemoteControl::showRequested);
        rc.submit(LaunchRequest{});
        QCOMPARE(show.count(), 1);
    }

    void aSecondLaunchReachesTheRunningOne() {
        const QString name = m_dir.filePath(QStringLiteral("sock"));
        QLocalServer server;
        QVERIFY(server.listen(name));
        RemoteControl rc;
        rc.listen(&server);
        rc.setReady(true);
        QSignalSpy prev(&rc, &RemoteControl::previousRequested);
        QSignalSpy show(&rc, &RemoteControl::showRequested);

        LaunchRequest r;
        r.show = false;
        r.commands = {Command::Previous};
        // The sending side blocks, so it runs on its own thread.
        bool sent = false;
        std::unique_ptr<QThread> t(QThread::create([&] {
            sent = RemoteControl::sendToRunning(name, r, 2000);
        }));
        t->start();
        QTRY_COMPARE(prev.count(), 1);
        QVERIFY(t->wait(5000));
        QVERIFY(sent);
        QCOMPARE(show.count(), 0);
    }

    // What 0.4 and earlier send: "show", then the process ends.
    void anOlderLaunchStillShowsTheWindow() {
        const QString name = m_dir.filePath(QStringLiteral("sock-old"));
        QLocalServer server;
        QVERIFY(server.listen(name));
        RemoteControl rc;
        rc.listen(&server);
        QSignalSpy show(&rc, &RemoteControl::showRequested);

        std::unique_ptr<QThread> t(QThread::create([&] {
            QLocalSocket socket;
            socket.connectToServer(name);
            if (socket.waitForConnected(2000)) {
                socket.write("show");
                socket.waitForBytesWritten(2000);
            }
        }));
        t->start();
        QTRY_COMPARE(show.count(), 1);
        QVERIFY(t->wait(5000));
    }

    void nobodyListening() {
        QVERIFY(!RemoteControl::sendToRunning(m_dir.filePath(QStringLiteral("none")),
                                              LaunchRequest{}, 200));
    }

    // ── links ───────────────────────────────────────────────────────────

    void aLinkOpensOnceReady() {
        RemoteControl rc;
        QSignalSpy open(&rc, &RemoteControl::openRequested);
        LaunchRequest r;
        r.urls = {QStringLiteral("https://tidal.com/browse/artist/9")};
        rc.submit(r);
        QCOMPARE(open.count(), 0);
        rc.setReady(true);
        QCOMPARE(open.count(), 1);
        QCOMPARE(open.first().at(0).toString(), QStringLiteral("artist"));
        QCOMPARE(open.first().at(1).toString(), QStringLiteral("9"));
    }

    // A track has no page; its album opens.
    void aTrackLinkOpensItsAlbum() {
        RemoteControl rc;
        rc.setReady(true);
        qint64 askedFor = 0;
        rc.setAlbumOfTrack([&](qint64 trackId, std::function<void(qint64)> done) {
            askedFor = trackId;
            done(trackId == 1234 ? 77 : 0);
        });
        QSignalSpy open(&rc, &RemoteControl::openRequested);
        LaunchRequest r;
        r.urls = {QStringLiteral("tidal://track/1234")};
        rc.submit(r);
        QCOMPARE(askedFor, 1234);
        QCOMPARE(open.count(), 1);
        QCOMPARE(open.first().at(0).toString(), QStringLiteral("album"));
        QCOMPARE(open.first().at(1).toString(), QStringLiteral("77"));

        // The lookup failed: nothing opens.
        r.urls = {QStringLiteral("tidal://track/5")};
        QTest::ignoreMessage(QtWarningMsg, "tidal-wave: no album found for track 5");
        rc.submit(r);
        QCOMPARE(open.count(), 1);
    }

    void junkLinksOpenNothing() {
        RemoteControl rc;
        rc.setReady(true);
        QSignalSpy open(&rc, &RemoteControl::openRequested);
        LaunchRequest r;
        r.urls = {QStringLiteral("https://example.com/album/1")};
        QTest::ignoreMessage(QtWarningMsg,
                             "tidal-wave: not a Tidal link, ignored: https://example.com/album/1");
        rc.submit(r);
        QCOMPARE(open.count(), 0);
    }

    // Commands and links act in the order they were given.
    void pendingItemsKeepTheirOrder() {
        RemoteControl rc;
        QStringList seen;
        connect(&rc, &RemoteControl::nextRequested, this, [&] { seen << "next"; });
        connect(&rc, &RemoteControl::openRequested, this,
                [&](const QString &kind, const QString &) { seen << kind; });
        LaunchRequest r;
        r.commands = {Command::Next};
        r.urls = {QStringLiteral("tidal://album/1")};
        rc.submit(r);
        rc.setReady(true);
        QCOMPARE(seen, (QStringList{"next", "album"}));
    }

private:
    QTemporaryDir m_dir;
};

QTEST_GUILESS_MAIN(TestRemoteControl)
#include "tst_remote_control.moc"
