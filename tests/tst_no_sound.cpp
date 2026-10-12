// The Player on a machine whose sound is missing. Each case runs the Player in
// a child process of this binary: Qt connects to the sound server once for a
// process, and a crash has to stay with its case. The child is given a
// PulseAudio daemon of its own, or none.

#include <QTest>
#include <QByteArray>
#include <QDataStream>
#include <QFile>
#include <QAudioDevice>
#include <QGuiApplication>
#include <QHash>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QProcess>
#include <QSettings>
#include <QSocketNotifier>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"
#include "ui/I18n.h"
#include "ui/Prefs.h"

#include <csignal>
#include <cstdio>
#include <memory>

namespace {

const char kChildFlag[] = "--plays";

const char kNoDevice[] =
    "No audio device was found. Check the sound settings of your system.";
const char kSoundLost[] =
    "The sound output was lost. Restart Tidal Wave to get it back.";

// What the Player's watch writes to the log, counted for the parent: a wake
// of a backend that stands, and its verdict on one that stood through them.
const char kWokenLine[]  = "Player: the backend stood still";
const char kJudgedLine[] = "Player: the backend still stands";
int g_woken  = 0;
int g_judged = 0;
QtMessageHandler g_printed = nullptr;

void countWatchLines(QtMsgType type, const QMessageLogContext &context, const QString &line)
{
    if (line.startsWith(QLatin1String(kWokenLine)))  ++g_woken;
    if (line.startsWith(QLatin1String(kJudgedLine))) ++g_judged;
    g_printed(type, context, line);
}

// ── the child ───────────────────────────────────────────────────────────────

QByteArray silentWav(int seconds) {
    const quint32 rate = 8000, channels = 1, bits = 16;
    const quint32 bytes = rate * quint32(seconds) * channels * bits / 8;

    QByteArray d;
    QDataStream s(&d, QIODevice::WriteOnly);
    s.setByteOrder(QDataStream::LittleEndian);
    auto tag = [&s](const char *four) { s.writeRawData(four, 4); };

    tag("RIFF"); s << quint32(36 + bytes); tag("WAVE");
    tag("fmt ");
    s << quint32(16)
      << quint16(1) << quint16(channels)
      << rate << quint32(rate * channels * bits / 8)
      << quint16(channels * bits / 8) << quint16(bits);
    tag("data"); s << bytes;
    s.writeRawData(QByteArray(int(bytes), '\0').constData(), int(bytes));
    return d;
}

// A localhost origin for the audio: every GET answers with the track.
class TrackServer : public QTcpServer {
public:
    TrackServer()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock] {
                    if (!sock->canReadLine()) return;
                    QObject::disconnect(sock, &QTcpSocket::readyRead, nullptr, nullptr);
                    QTimer::singleShot(holdMs, sock, [this, sock] {
                        sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: "
                                    + QByteArray::number(track.size()) + "\r\n\r\n" + track);
                        sock->disconnectFromHost();
                    });
                });
            }
        });
    }
    QByteArray track;
    int        holdMs = 0;   // how long a request waits for its answer
};

// Answers every stream request with one file, as Tidal does for a lossy tier.
class OneFileClient : public TidalClient {
public:
    using TidalClient::TidalClient;

    StreamManifest manifest;

    void fetchStreamManifest(qint64, StreamCb cb) override
    {
        QTimer::singleShot(0, this, [this, cb = std::move(cb)] { cb(manifest, QString()); });
    }
};

// A Player that takes one word a line on stdin and answers on stdout.
class Stage : public QObject {
public:
    Stage()
    {
        m_server.track = silentWav(20);
        m_server.listen(QHostAddress::LocalHost);
        m_client.manifest.type     = StreamManifest::BTS;
        m_client.manifest.url      = QStringLiteral("http://127.0.0.1:%1/track").arg(m_server.serverPort());
        m_client.manifest.mimeType = QStringLiteral("audio/wav");
        m_client.manifest.codec    = QStringLiteral("HIGH");

        m_player = std::make_unique<Player>(&m_client);
        m_player->setMuted(true);
        m_player->setVolume(0.0);
        connect(m_player.get(), &Player::loadErrorChanged, this, [this] {
            if (!m_player->loadError().isEmpty()) say("error " + m_player->loadError().toUtf8());
        });

        // By descriptor: a FILE reads ahead, and a word that came in the same
        // read as another would wait there for the next one.
        if (!m_stdin.open(0, QIODevice::ReadOnly | QIODevice::Unbuffered))
            qFatal("the standard input did not open");
        connect(&m_notifier, &QSocketNotifier::activated, this, [this] { hear(); });
        connect(&m_devices, &QMediaDevices::audioOutputsChanged, this, [this] { ++m_changes; });

        // The Player builds its audio objects on the first turn of the loop.
        auto *up = new QTimer(this);
        connect(up, &QTimer::timeout, this, [this, up] {
            if (!mp()) return;
            up->deleteLater();
            say("up outputs=" + QByteArray::number(QMediaDevices::audioOutputs().count()));
        });
        up->start(10);
    }

private:
    QMediaPlayer *mp() const { return m_player->findChild<QMediaPlayer *>(); }

    static void say(const QByteArray &line)
    {
        std::fputs(line.constData(), stdout);
        std::fputc('\n', stdout);
        std::fflush(stdout);
    }

    static QVariantMap track(qlonglong id)
    {
        QVariantMap t;
        t[QStringLiteral("id")]       = id;
        t[QStringLiteral("title")]    = QStringLiteral("T%1").arg(id);
        t[QStringLiteral("artists")]  = QStringLiteral("Artist");
        t[QStringLiteral("duration")] = 20;
        return t;
    }

    void hear()
    {
        const QByteArray word = m_stdin.readLine().trimmed();
        if (word == "tracks") {
            m_player->playTracks(QVariantList{ track(1), track(2), track(3) }, 0);
        } else if (word == "press") {
            m_player->playPause();
        } else if (word == "next") {
            m_player->next();
        } else if (word == "rebind") {
            m_player->rebindAudioOutput(QMediaDevices::defaultAudioOutput());
        } else if (word == "short") {
            m_server.track = silentWav(6);
        } else if (word == "last") {
            m_player->playTracks(QVariantList{ track(1), track(2), track(3) }, 2);
        } else if (word == "signin") {
            m_client.setUserId(7);
        } else if (word == "shuffle") {
            m_player->setShuffle(true);
        } else if (word == "slow") {
            m_server.holdMs = 8000;
        } else if (word == "outputs") {
            QByteArrayList ids;
            const QList<QAudioDevice> outs = QMediaDevices::audioOutputs();
            for (const QAudioDevice &d : outs) ids << d.id();
            say("outputs count=" + QByteArray::number(outs.count())
                + " bound=" + m_player->activeAudioDeviceId().toUtf8()
                + " default=" + QMediaDevices::defaultAudioOutput().id()
                + " changes=" + QByteArray::number(m_changes)
                + " ids=" + ids.join(','));
        } else if (word == "status") {
            say("status playing=" + QByteArray::number(int(m_player->playing()))
                + " backend=" + QByteArray::number(int(mp()->playbackState()))
                + " position=" + QByteArray::number(mp()->position())
                + " loading=" + QByteArray::number(int(m_player->loading()))
                + " woken=" + QByteArray::number(g_woken)
                + " judged=" + QByteArray::number(g_judged)
                + " track=" + QByteArray::number(m_player->currentTrackMap()
                                                     .value(QStringLiteral("id")).toLongLong()));
        } else if (word == "quit" || word.isEmpty()) {
            // An empty read is the parent gone.
            m_notifier.setEnabled(false);
            QCoreApplication::quit();
        }
    }

    TrackServer             m_server;
    TidalApi                m_api;
    OneFileClient           m_client{&m_api};
    std::unique_ptr<Player> m_player;
    QFile                   m_stdin;
    QSocketNotifier         m_notifier{0, QSocketNotifier::Read};
    QMediaDevices           m_devices;
    int                     m_changes = 0;
};

int playAsChild(QGuiApplication &app, const QString &home)
{
    QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
    QCoreApplication::setApplicationName(QStringLiteral("tst_no_sound"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, home);
    g_printed = qInstallMessageHandler(countWatchLines);
    int rc = 0;
    {
        Stage stage;
        rc = app.exec();
    }
    return rc;
}

// ── the parent ──────────────────────────────────────────────────────────────

// A PulseAudio daemon that belongs to one case.
class SoundServer {
public:
    static QString binary() { return QStandardPaths::findExecutable(QStringLiteral("pulseaudio")); }

    QString address() const { return QStringLiteral("unix:") + socket(); }

    static QString pactlBinary() { return QStandardPaths::findExecutable(QStringLiteral("pactl")); }

    bool start(bool withSink, bool withSecondSink = false)
    {
        QStringList args{ QStringLiteral("-n"), QStringLiteral("--daemonize=no"),
                          QStringLiteral("--exit-idle-time=-1") };
        if (withSink)
            args << QStringLiteral("--load=module-null-sink sink_name=tests_null");
        if (withSecondSink)
            args << QStringLiteral("--load=module-null-sink sink_name=other");
        args << QStringLiteral("--load=module-native-protocol-unix auth-anonymous=1 socket=") + socket();

        // The daemon refuses a home that belongs to another user.
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("HOME"), m_dir.path());
        env.insert(QStringLiteral("XDG_RUNTIME_DIR"), m_dir.path());
        m_proc.setProcessEnvironment(env);
        m_proc.setProcessChannelMode(QProcess::ForwardedErrorChannel);
        m_proc.start(binary(), args);
        return QTest::qWaitFor([this] {
            return QFile::exists(socket()) || m_proc.state() == QProcess::NotRunning;
        }, 15000) && m_proc.state() == QProcess::Running;
    }

    void stop()
    {
        if (m_proc.state() == QProcess::NotRunning) return;
        m_proc.kill();
        m_proc.waitForFinished(10000);
        QFile::remove(socket());
    }

    bool addSink(const char *name)
    {
        return !pactl({ QStringLiteral("load-module"), QStringLiteral("module-null-sink"),
                        QStringLiteral("sink_name=") + QLatin1String(name) }).isNull();
    }

    bool removeSink(const char *name)
    {
        const QByteArray wanted = QByteArray("sink_name=") + name;
        const QList<QByteArray> modules =
            pactl({ QStringLiteral("list"), QStringLiteral("short"), QStringLiteral("modules") }).split('\n');
        for (const QByteArray &line : modules) {
            if (!line.contains(wanted)) continue;
            const QString index = QString::fromLatin1(line.left(line.indexOf('\t')));
            return !pactl({ QStringLiteral("unload-module"), index }).isNull();
        }
        qWarning("no module holds the sink %s", name);
        return false;
    }

    // The daemon keeps its socket and answers nobody.
    bool freeze() { return ::kill(pid_t(m_proc.processId()), SIGSTOP) == 0; }

    // A suspended sink takes nothing, and its streams stand until it is back.
    bool suspend(bool on)
    {
        return !pactl({ QStringLiteral("suspend-sink"), QStringLiteral("tests_null"),
                        QString::number(int(on)) }).isNull();
    }

    ~SoundServer() { stop(); }

private:
    QString socket() const { return m_dir.filePath(QStringLiteral("native")); }

    // What pactl printed when asked of this daemon. Null when it failed.
    QByteArray pactl(const QStringList &args)
    {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("HOME"), m_dir.path());
        env.insert(QStringLiteral("XDG_RUNTIME_DIR"), m_dir.path());
        QProcess tool;
        tool.setProcessEnvironment(env);
        tool.start(pactlBinary(), QStringList{ QStringLiteral("--server"), address() } + args);
        if (!tool.waitForFinished(10000)) {
            qWarning("pactl %s did not end", qPrintable(args.join(QLatin1Char(' '))));
            tool.kill();
            tool.waitForFinished(5000);
            return {};
        }
        if (tool.exitStatus() != QProcess::NormalExit || tool.exitCode() != 0) {
            qWarning("pactl %s: %s", qPrintable(args.join(QLatin1Char(' '))),
                     tool.readAllStandardError().trimmed().constData());
            return {};
        }
        const QByteArray printed = tool.readAllStandardOutput();
        return printed.isNull() ? QByteArray("") : printed;
    }

    QTemporaryDir m_dir;
    QProcess      m_proc;
};

// One run of the child, and the conversation with it.
class Child {
public:
    // pulseServer names the daemon the child may reach. Its runtime directory
    // is empty, so no other sound server of this machine is found.
    void start(const QString &pulseServer)
    {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("HOME"), m_dir.path());
        env.insert(QStringLiteral("XDG_RUNTIME_DIR"), m_dir.path());
        env.insert(QStringLiteral("PULSE_SERVER"), pulseServer);
        env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
        env.remove(QStringLiteral("PIPEWIRE_REMOTE"));
        env.remove(QStringLiteral("PIPEWIRE_RUNTIME_DIR"));
        env.remove(QStringLiteral("PULSE_RUNTIME_PATH"));
        m_proc.setProcessEnvironment(env);
        m_proc.setProcessChannelMode(QProcess::ForwardedErrorChannel);
        m_proc.start(QCoreApplication::applicationFilePath(),
                     { QString::fromLatin1(kChildFlag), m_dir.path() });
    }

    void say(const char *word)
    {
        m_proc.write(word);
        m_proc.write("\n");
        m_proc.waitForBytesWritten(5000);
    }

    // What follows the word on the next line that starts with it. Null when
    // no such line came in time, or the child ended.
    QByteArray hear(const char *word, int ms = 20000)
    {
        const QByteArray start = QByteArray(word) + ' ';
        QDeadlineTimer deadline(ms);
        for (;;) {
            while (m_proc.canReadLine()) {
                const QByteArray line = m_proc.readLine().trimmed() + ' ';
                if (!line.startsWith(start)) continue;
                const QByteArray rest = line.mid(start.size()).trimmed();
                return rest.isNull() ? QByteArray("") : rest;
            }
            if (m_proc.state() == QProcess::NotRunning || deadline.hasExpired()) return {};
            m_proc.waitForReadyRead(int(qMin<qint64>(deadline.remainingTime(), 200)));
        }
    }

    // The child's answer to "status", by name.
    QHash<QByteArray, qint64> status()
    {
        say("status");
        QHash<QByteArray, qint64> out;
        const QList<QByteArray> pairs = hear("status").split(' ');
        for (const QByteArray &pair : pairs) {
            const int eq = pair.indexOf('=');
            if (eq > 0) out.insert(pair.left(eq), pair.mid(eq + 1).toLongLong());
        }
        return out;
    }

    // Waits for the backend to play the track and to leave its start.
    bool playsTrack(qint64 id, int ms = 20000)
    {
        QDeadlineTimer deadline(ms);
        while (!deadline.hasExpired()) {
            const QHash<QByteArray, qint64> now = status();
            if (now.isEmpty()) return false;
            if (now.value("backend") == qint64(QMediaPlayer::PlayingState)
                && now.value("track") == id && now.value("position") > 0)
                return true;
            QTest::qWait(100);
        }
        return false;
    }
    bool plays() { return playsTrack(1); }

    // Whether nothing is said for this long and the child is still there.
    bool quiet(int ms) { return hear("error", ms).isNull() && fate().isEmpty(); }

    // Whether the child answers a question: its main thread is free.
    bool answers(int ms = 5000)
    {
        say("status");
        return !hear("status", ms).isNull();
    }

    // Waits for the track to play. Empty when it does, else what came of it.
    QString startOf(qint64 id, int ms = 20000)
    {
        QDeadlineTimer deadline(ms);
        while (!deadline.hasExpired()) {
            say("status");
            const QByteArray answer = hear("status", 5000);
            if (answer.isNull())
                return fate().isEmpty() ? QStringLiteral("the program did not answer within 5 s") : fate();
            if (answer.contains(" backend=1 ") && !answer.contains(" position=0 ")
                && answer.endsWith(" track=" + QByteArray::number(id)))
                return {};
            QTest::qWait(100);
        }
        return QStringLiteral("track %1 did not start within %2 s").arg(id).arg(ms / 1000);
    }

    // Waits for the child's list of outputs to be these ids, comma separated.
    bool seesOutputs(const QByteArray &ids, int ms = 10000)
    {
        QDeadlineTimer deadline(ms);
        while (!deadline.hasExpired()) {
            say("outputs");
            const QByteArray answer = hear("outputs", 5000);
            if (answer.isNull()) return false;
            if (answer.endsWith(" ids=" + ids)) return true;
            QTest::qWait(100);
        }
        return false;
    }

    // The output the Player is bound to.
    QByteArray boundOutput()
    {
        say("outputs");
        const QList<QByteArray> pairs = hear("outputs", 5000).split(' ');
        for (const QByteArray &pair : pairs)
            if (pair.startsWith("bound=")) return pair.mid(6);
        return {};
    }

    // Empty while the child runs, else how it ended.
    QString fate()
    {
        if (m_proc.state() != QProcess::NotRunning) return {};
        return m_proc.exitStatus() == QProcess::CrashExit
            ? QStringLiteral("the program went down on signal %1").arg(m_proc.exitCode())
            : QStringLiteral("the program left with status %1").arg(m_proc.exitCode());
    }

    // Asks the child to leave. Empty when it left in order and in time.
    QString leave(int ms = 20000)
    {
        if (m_proc.state() != QProcess::NotRunning) say("quit");
        if (!m_proc.waitForFinished(ms)) {
            m_proc.kill();
            m_proc.waitForFinished(5000);
            return QStringLiteral("the program was still there %1 s after it was asked to quit")
                .arg(ms / 1000);
        }
        if (m_proc.exitStatus() == QProcess::NormalExit && m_proc.exitCode() == 0) return {};
        return fate();
    }

    // What the child's settings file holds under a key.
    QVariant saved(const QString &key) const
    {
        const QSettings file(m_dir.filePath(QStringLiteral("TidalWaveTest/tst_no_sound.ini")),
                             QSettings::IniFormat);
        return file.value(key);
    }

    ~Child()
    {
        if (m_proc.state() == QProcess::NotRunning) return;
        m_proc.kill();
        m_proc.waitForFinished(5000);
    }

private:
    QTemporaryDir m_dir;
    QProcess      m_proc;
};

} // namespace

class TestNoSound : public QObject {
    Q_OBJECT

private slots:
    void aTrackStartedWithNoAudioDeviceIsRefusedAndTheProgramStaysUp_data()
    {
        QTest::addColumn<bool>("server");
        QTest::newRow("no sound server")       << false;
        QTest::newRow("a server with no sink") << true;
    }

    void aTrackStartedWithNoAudioDeviceIsRefusedAndTheProgramStaysUp()
    {
        QFETCH(bool, server);
        SoundServer sound;
        if (server) {
            if (SoundServer::binary().isEmpty())
                QSKIP("needs the pulseaudio daemon to offer a sound server with no sink");
            QVERIFY2(sound.start(false), "the pulseaudio daemon did not start");
        }

        Child child;
        child.start(sound.address());
        const QByteArray up = child.hear("up");
        QVERIFY2(!up.isNull(), "the program did not come up");
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        if (up != "outputs=0")
            QSKIP("this Qt finds an audio device without the sound server");
#endif
        QCOMPARE(up, QByteArray("outputs=0"));

        child.say("tracks");
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // Qt 6.4 cannot play into nothing, so the Player does not start it.
        QByteArray told = child.hear("error");
        QVERIFY2(child.fate().isEmpty(), qPrintable(child.fate()));
        QCOMPARE(told, QByteArray(kNoDevice));
        QHash<QByteArray, qint64> now = child.status();
        QCOMPARE(now.value("playing"), 0);
        QCOMPARE(now.value("backend"), qint64(QMediaPlayer::StoppedState));
        QCOMPARE(now.value("loading"), 0);

        // A press on play says it again and starts nothing either.
        child.say("press");
        told = child.hear("error");
        QVERIFY2(child.fate().isEmpty(), qPrintable(child.fate()));
        QCOMPARE(told, QByteArray(kNoDevice));
        now = child.status();
        QCOMPARE(now.value("playing"), 0);
        QCOMPARE(now.value("backend"), qint64(QMediaPlayer::StoppedState));
#else
        // Newer Qt plays into nothing at the pace of a clock.
        QTest::qWait(2000);
        QVERIFY2(!child.status().isEmpty(), qPrintable(child.fate()));
#endif
        QCOMPARE(child.leave(), QString());
    }

    // Qt 6.4 keeps one connection to the sound server for all its sinks and
    // never makes it again. A sink asked for after the server came back does
    // not open, and the backend writes through it all the same.
    void aStartAfterTheSoundServerCameBackIsRefusedAndTheProgramStaysUp_data()
    {
        QTest::addColumn<QByteArray>("start");
        QTest::newRow("the next track")   << QByteArray("next");
        QTest::newRow("the paused track") << QByteArray("press");
    }

    void aStartAfterTheSoundServerCameBackIsRefusedAndTheProgramStaysUp()
    {
        QFETCH(QByteArray, start);
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        QSKIP("covers Qt below 6.5, whose sinks never reach a sound server that came back");
#endif
        if (SoundServer::binary().isEmpty())
            QSKIP("needs the pulseaudio daemon to take the sound server away and bring it back");
        SoundServer sound;
        QVERIFY2(sound.start(true), "the pulseaudio daemon did not start");
        Child child;
        child.start(sound.address());
        QCOMPARE(child.hear("up"), QByteArray("outputs=1"));

        child.say("tracks");
        QVERIFY2(child.plays(), "the first track did not start");
        child.say("press");
        QCOMPARE(child.status().value("backend"), qint64(QMediaPlayer::PausedState));

        sound.stop();
        QVERIFY2(sound.start(true), "the pulseaudio daemon did not start again");

        child.say(start.constData());
        QByteArray told = child.hear("error");
        QVERIFY2(child.fate().isEmpty(), qPrintable(child.fate()));
        QCOMPARE(told, QByteArray(kSoundLost));
        QHash<QByteArray, qint64> now = child.status();
        QCOMPARE(now.value("playing"), 0);
        QVERIFY(now.value("backend") != qint64(QMediaPlayer::PlayingState));

        // A press on play says it again and starts nothing either.
        child.say("press");
        told = child.hear("error");
        QVERIFY2(child.fate().isEmpty(), qPrintable(child.fate()));
        QCOMPARE(told, QByteArray(kSoundLost));
        QCOMPARE(child.status().value("playing"), 0);

        QCOMPARE(child.leave(), QString());
    }

    // Another output is what a user picks when the sound is gone, and the
    // swap makes the backend open a sink while it plays.
    void anOutputSwappedAfterTheSoundServerWentIsRefusedAndTheProgramStaysUp()
    {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        QSKIP("covers Qt below 6.5, whose sinks never reach a sound server that came back");
#endif
        if (SoundServer::binary().isEmpty())
            QSKIP("needs the pulseaudio daemon to take the sound server away");
        SoundServer sound;
        QVERIFY2(sound.start(true), "the pulseaudio daemon did not start");
        Child child;
        child.start(sound.address());
        QCOMPARE(child.hear("up"), QByteArray("outputs=1"));

        // On the second track, whose sinks find the connection as it is.
        child.say("tracks");
        QVERIFY2(child.plays(), "the first track did not start");
        child.say("next");
        QVERIFY2(child.playsTrack(2), "the second track did not start");

        sound.stop();
        QTest::qWait(500);
        child.say("rebind");
        const QByteArray told = child.hear("error");
        QVERIFY2(child.fate().isEmpty(), qPrintable(child.fate()));
        QCOMPARE(told, QByteArray(kSoundLost));
        QCOMPARE(child.status().value("playing"), 0);
    }

    // Qt 6.4 opens the sink of a track by the name of the output it is bound
    // to, and waits for good on a stream the sound server refuses. Its list
    // of outputs follows the server and no signal says so.
    void theTrackAfterTheOutputWasRemovedPlaysOnAnotherOne_data()
    {
        QTest::addColumn<bool>("pressed");
        QTest::newRow("next is pressed")    << true;
        QTest::newRow("the track runs out") << false;
    }

    void theTrackAfterTheOutputWasRemovedPlaysOnAnotherOne()
    {
        QFETCH(bool, pressed);
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        QSKIP("covers Qt below 6.5, which hears of no change of outputs from PulseAudio");
#endif
        if (SoundServer::binary().isEmpty() || SoundServer::pactlBinary().isEmpty())
            QSKIP("needs the pulseaudio daemon and pactl to take an output away");
        SoundServer sound;
        QVERIFY2(sound.start(true, true), "the pulseaudio daemon did not start");
        Child child;
        child.start(sound.address());
        QCOMPARE(child.hear("up"), QByteArray("outputs=2"));
        QCOMPARE(child.boundOutput(), QByteArray("tests_null"));

        if (!pressed) child.say("short");
        child.say("tracks");
        QVERIFY2(child.plays(), "the first track did not start");
        QVERIFY2(sound.removeSink("tests_null"), "the output was not removed");
        QVERIFY2(child.seesOutputs("other"), "the program did not see the output go");
        QCOMPARE(child.status().value("track"), 1);

        if (pressed) child.say("next");
        QCOMPARE(child.startOf(2), QString());
        QCOMPARE(child.boundOutput(), QByteArray("other"));
        QVERIFY2(child.hear("error", 1000).isNull(), "an error was said");
        QCOMPARE(child.leave(), QString());
    }

    // The stream of a paused track dies with its output, and nothing is
    // written into it while it is paused.
    void aPausedTrackWhoseOutputWasRemovedGoesOnWhenAnotherIsThere()
    {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        QSKIP("covers Qt below 6.5, which hears of no change of outputs from PulseAudio");
#endif
        if (SoundServer::binary().isEmpty() || SoundServer::pactlBinary().isEmpty())
            QSKIP("needs the pulseaudio daemon and pactl to take an output away");
        SoundServer sound;
        QVERIFY2(sound.start(true), "the pulseaudio daemon did not start");
        Child child;
        child.start(sound.address());
        QCOMPARE(child.hear("up"), QByteArray("outputs=1"));

        child.say("tracks");
        QVERIFY2(child.plays(), "the first track did not start");
        child.say("press");
        const QHash<QByteArray, qint64> paused = child.status();
        QCOMPARE(paused.value("backend"), qint64(QMediaPlayer::PausedState));

        QVERIFY2(sound.removeSink("tests_null"), "the output was not removed");
        QVERIFY2(sound.addSink("other"), "the other output was not added");
        QVERIFY2(child.seesOutputs("other"), "the program did not see the outputs change");

        child.say("press");
        QVERIFY2(QTest::qWaitFor([&] {
            const QHash<QByteArray, qint64> now = child.status();
            return now.isEmpty() || now.value("position") > paused.value("position") + 1000;
        }, 15000), "the track stood still for 15 s after play was pressed");
        QVERIFY2(child.answers(), "the program did not answer within 5 s");
        QCOMPARE(child.boundOutput(), QByteArray("other"));
        QCOMPARE(child.status().value("playing"), 1);
        QCOMPARE(child.leave(), QString());
    }

    // Qt 6.4 goes on reporting that it plays once the sound server is gone,
    // with a position that stands.
    void soundLostWhileATrackPlaysIsSaidAndTheTrackIsPaused_data()
    {
        QTest::addColumn<bool>("back");
        QTest::newRow("the server stays away") << false;
        QTest::newRow("the server comes back") << true;
    }

    void soundLostWhileATrackPlaysIsSaidAndTheTrackIsPaused()
    {
        QFETCH(bool, back);
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        QSKIP("covers Qt below 6.5, which plays on in silence when the sound server goes");
#endif
        if (SoundServer::binary().isEmpty())
            QSKIP("needs the pulseaudio daemon to take the sound server away");
        SoundServer sound;
        QVERIFY2(sound.start(true), "the pulseaudio daemon did not start");
        Child child;
        child.start(sound.address());
        QCOMPARE(child.hear("up"), QByteArray("outputs=1"));

        child.say("tracks");
        QVERIFY2(child.plays(), "the first track did not start");
        sound.stop();
        if (back) QVERIFY2(sound.start(true), "the pulseaudio daemon did not start again");

        // Nobody presses anything.
        QByteArray told = child.hear("error");
        QVERIFY2(child.fate().isEmpty(), qPrintable(child.fate()));
        QCOMPARE(told, QByteArray(kSoundLost));
        const QHash<QByteArray, qint64> now = child.status();
        QCOMPARE(now.value("playing"), 0);
        QCOMPARE(now.value("backend"), qint64(QMediaPlayer::PausedState));
        QCOMPARE(now.value("track"), 1);

        // A press on play and the next track say it again.
        for (const char *word : { "press", "next" }) {
            child.say(word);
            told = child.hear("error");
            QVERIFY2(child.fate().isEmpty(), qPrintable(child.fate()));
            QCOMPARE(told, QByteArray(kSoundLost));
            QCOMPARE(child.status().value("playing"), 0);
        }
        QVERIFY2(child.answers(), "the program did not answer within 5 s");
    }

    // A track stands for other reasons than a lost sound server, and then
    // nothing is said and nothing is paused.
    void aTrackThatStandsWithItsSoundServerThereIsLeftAlone_data()
    {
        QTest::addColumn<QByteArray>("what");
        QTest::newRow("a track that plays")                   << QByteArray("plays");
        QTest::newRow("a paused track")                       << QByteArray("paused");
        QTest::newRow("a load under way")                     << QByteArray("loads");
        QTest::newRow("the end of the queue")                 << QByteArray("ends");
        QTest::newRow("an output that stands and comes back") << QByteArray("suspended");
    }

    void aTrackThatStandsWithItsSoundServerThereIsLeftAlone()
    {
        QFETCH(QByteArray, what);
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        QSKIP("covers Qt below 6.5, where the Player watches a backend that stands");
#endif
        if (SoundServer::binary().isEmpty() || SoundServer::pactlBinary().isEmpty())
            QSKIP("needs the pulseaudio daemon and pactl to make an output stand");
        SoundServer sound;
        QVERIFY2(sound.start(true), "the pulseaudio daemon did not start");
        Child child;
        child.start(sound.address());
        QCOMPARE(child.hear("up"), QByteArray("outputs=1"));

        if (what == "plays") {
            // Sound starts late on a null sink, and the position stands until then.
            child.say("tracks");
            QVERIFY2(child.plays(), "the first track did not start");
            QVERIFY2(child.quiet(8000), "an error was said");
            const QHash<QByteArray, qint64> now = child.status();
            QCOMPARE(now.value("playing"), 1);
            QVERIFY2(now.value("position") > 4000, QByteArray::number(now.value("position")));
        } else if (what == "paused") {
            child.say("tracks");
            QVERIFY2(child.plays(), "the first track did not start");
            child.say("press");
            const QHash<QByteArray, qint64> paused = child.status();
            QCOMPARE(paused.value("backend"), qint64(QMediaPlayer::PausedState));
            QVERIFY2(child.quiet(8000), "an error was said");
            const QHash<QByteArray, qint64> later = child.status();
            QCOMPARE(later.value("backend"), qint64(QMediaPlayer::PausedState));
            QCOMPARE(later.value("woken"), paused.value("woken"));
            QCOMPARE(later.value("judged"), paused.value("judged"));
            child.say("press");
            QVERIFY2(QTest::qWaitFor([&] {
                return child.status().value("position") > paused.value("position") + 500;
            }, 15000), "the track did not go on after play was pressed");
        } else if (what == "loads") {
            child.say("slow");
            child.say("tracks");
            QCOMPARE(child.status().value("loading"), 1);
            QVERIFY2(child.quiet(6000), "an error was said");
            QCOMPARE(child.status().value("loading"), 1);
            QCOMPARE(child.startOf(1), QString());
        } else if (what == "ends") {
            child.say("short");
            child.say("last");
            QCOMPARE(child.startOf(3), QString());
            QVERIFY2(QTest::qWaitFor([&] { return child.status().value("playing", 1) == 0; }, 30000),
                     "the last track did not end");
            const QHash<QByteArray, qint64> ended = child.status();
            QVERIFY2(child.quiet(8000), "an error was said");
            const QHash<QByteArray, qint64> later = child.status();
            QCOMPARE(later.value("playing"), 0);
            QCOMPARE(later.value("woken"), ended.value("woken"));
            QCOMPARE(later.value("judged"), ended.value("judged"));
        } else {
            child.say("tracks");
            QVERIFY2(child.plays(), "the first track did not start");
            QVERIFY2(QTest::qWaitFor([&] { return child.status().value("position") > 2500; }, 15000),
                     "the first track did not get going");
            const qint64 judgedBefore = child.status().value("judged");
            // The position runs on while the output is suspended, and stands
            // for about as long once it is back.
            QVERIFY2(sound.suspend(true), "the output was not suspended");
            QVERIFY2(child.quiet(8000), "an error was said while the output stood");
            QVERIFY2(sound.suspend(false), "the output was not resumed");
            QVERIFY2(QTest::qWaitFor([&] {
                return child.status().value("judged", judgedBefore + 1) > judgedBefore;
            }, 20000), "the watch did not come to its question");
            const QHash<QByteArray, qint64> stood = child.status();
            QCOMPARE(stood.value("playing"), 1);
            QCOMPARE(stood.value("backend"), qint64(QMediaPlayer::PlayingState));
            QVERIFY2(QTest::qWaitFor([&] {
                return child.status().value("position", stood.value("position") + 1001)
                       > stood.value("position") + 1000;
            }, 20000), "the track did not go on once the output was back");
            QVERIFY2(child.quiet(1000), "an error was said");
            QCOMPARE(child.status().value("playing"), 1);
        }
        QCOMPARE(child.leave(), QString());
    }

    // Qt 6.4 ends its sound engine after main(), and waits there for good on
    // a lock that a write into the lost stream kept.
    void aQuitAfterSoundWasLostEndsWithTheSessionSaved_data()
    {
        QTest::addColumn<QByteArray>("when");
        QTest::newRow("after the loss was said")          << QByteArray("said");
        QTest::newRow("a second after the loss")          << QByteArray("a second");
        QTest::newRow("at the moment of the loss")        << QByteArray("at once");
        QTest::newRow("after the track was paused")       << QByteArray("paused");
        QTest::newRow("after a start that got no answer") << QByteArray("no answer");
    }

    void aQuitAfterSoundWasLostEndsWithTheSessionSaved()
    {
        QFETCH(QByteArray, when);
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        QSKIP("covers Qt below 6.5, whose sound engine does not end once the sound server went");
#endif
        if (SoundServer::binary().isEmpty())
            QSKIP("needs the pulseaudio daemon to take the sound server away");
        SoundServer sound;
        QVERIFY2(sound.start(true), "the pulseaudio daemon did not start");
        Child child;
        child.start(sound.address());
        QCOMPARE(child.hear("up"), QByteArray("outputs=1"));

        child.say("signin");
        if (when == "no answer") {
            QVERIFY2(sound.freeze(), "the pulseaudio daemon was not stopped");
            child.say("tracks");
            QCOMPARE(child.hear("error"), QByteArray(kSoundLost));
        } else {
            child.say("tracks");
            QVERIFY2(child.plays(), "the first track did not start");
            sound.stop();
            if (when == "said") QCOMPARE(child.hear("error"), QByteArray(kSoundLost));
            if (when == "a second" || when == "paused") QTest::qWait(1000);
            if (when == "paused") {
                child.say("press");
                QCOMPARE(child.status().value("backend"), qint64(QMediaPlayer::PausedState));
            }
        }

        // Changed last, so that only the save at the quit can hold it.
        child.say("shuffle");
        QCOMPARE(child.leave(5000), QString());
        QCOMPARE(child.saved(QStringLiteral("user_7/playback/shuffle")).toBool(), true);
        QVERIFY(!child.saved(QStringLiteral("user_7/playback/queue")).toByteArray().isEmpty());
    }

    void theSentencesHaveTheirGerman()
    {
        QTemporaryDir dir;
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, dir.path());
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);
        QVERIFY(i18n.isCatalogueLoaded());
        QVERIFY(QCoreApplication::translate("Player", kNoDevice) != QLatin1String(kNoDevice));
        QVERIFY(QCoreApplication::translate("Player", kSoundLost) != QLatin1String(kSoundLost));
    }
};

int main(int argc, char **argv)
{
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    // The backend the app selects on this Qt.
    if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
        qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif
    QGuiApplication app(argc, argv);
    if (argc == 3 && qstrcmp(argv[1], kChildFlag) == 0)
        return playAsChild(app, QString::fromLocal8Bit(argv[2]));

    QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
    QCoreApplication::setApplicationName(QStringLiteral("tst_no_sound"));
    TestNoSound test;
    QTEST_SET_MAIN_SOURCE_PATH
    return QTest::qExec(&test, argc, argv);
}

#include "tst_no_sound.moc"
