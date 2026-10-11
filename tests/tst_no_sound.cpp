// The Player on a machine whose sound is missing. Each case runs the Player in
// a child process of this binary: Qt connects to the sound server once for a
// process, and a crash has to stay with its case. The child is given a
// PulseAudio daemon of its own, or none.

#include <QTest>
#include <QByteArray>
#include <QDataStream>
#include <QFile>
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

#include <cstdio>
#include <memory>

namespace {

const char kChildFlag[] = "--plays";

const char kNoDevice[] =
    "No audio device was found. Check the sound settings of your system.";

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
                    sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: "
                                + QByteArray::number(track.size()) + "\r\n\r\n" + track);
                    sock->disconnectFromHost();
                });
            }
        });
    }
    QByteArray track;
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

        m_stdin.open(stdin, QIODevice::ReadOnly | QIODevice::Unbuffered);
        connect(&m_notifier, &QSocketNotifier::activated, this, [this] { hear(); });

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
        } else if (word == "status") {
            say("status playing=" + QByteArray::number(int(m_player->playing()))
                + " backend=" + QByteArray::number(int(mp()->playbackState()))
                + " position=" + QByteArray::number(mp()->position())
                + " loading=" + QByteArray::number(int(m_player->loading()))
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
};

int playAsChild(QGuiApplication &app, const QString &home)
{
    QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
    QCoreApplication::setApplicationName(QStringLiteral("tst_no_sound"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, home);
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

    bool start(bool withSink)
    {
        QStringList args{ QStringLiteral("-n"), QStringLiteral("--daemonize=no"),
                          QStringLiteral("--exit-idle-time=-1") };
        if (withSink)
            args << QStringLiteral("--load=module-null-sink sink_name=tests_null");
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

    ~SoundServer() { stop(); }

private:
    QString socket() const { return m_dir.filePath(QStringLiteral("native")); }

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

    // Empty while the child runs, else how it ended.
    QString fate()
    {
        if (m_proc.state() != QProcess::NotRunning) return {};
        return m_proc.exitStatus() == QProcess::CrashExit
            ? QStringLiteral("the program went down on signal %1").arg(m_proc.exitCode())
            : QStringLiteral("the program left with status %1").arg(m_proc.exitCode());
    }

    // Asks the child to leave. Empty when it left in order.
    QString leave()
    {
        if (m_proc.state() != QProcess::NotRunning) say("quit");
        if (!m_proc.waitForFinished(20000)) {
            m_proc.kill();
            m_proc.waitForFinished(5000);
            return QStringLiteral("the program did not leave when asked to quit");
        }
        if (m_proc.exitStatus() == QProcess::NormalExit && m_proc.exitCode() == 0) return {};
        return fate();
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

    void theSentenceHasItsGerman()
    {
        QTemporaryDir dir;
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, dir.path());
        Prefs prefs;
        prefs.setLanguage(QStringLiteral("de"));
        I18n i18n(&prefs);
        QVERIFY(i18n.isCatalogueLoaded());
        QVERIFY(QCoreApplication::translate("Player", kNoDevice) != QLatin1String(kNoDevice));
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
