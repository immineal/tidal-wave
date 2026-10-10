// A SIGTERM, SIGINT or SIGHUP must become an ordinary quit: the session is
// saved and the temp media file is removed, both of which only ~Player does.
// The child is this binary re-executed with --child. It runs the real
// Application, signal handlers and Player; only the stream manifest is stubbed
// to a localhost URL. The bytes served are not audio and the player is muted.
// Signals go only to the pid this test started, never by name.

#include <QTest>
#include <QApplication>
#include <QByteArray>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QFile>
#include <QHostAddress>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSettings>
#include <QString>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

#include <csignal>
#include <memory>
#include <unistd.h>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"
#include "ui/Application.h"

namespace {

// Invented values.
constexpr qint64   kUser       = 7731;
constexpr qlonglong kTrackBase = 55500001;
constexpr double   kVolume     = 0.37;
constexpr int      kRepeatMode = 2;

const char kChildFlag[] = "--child";

// Comfortably past Player's 1.5 s persist debounce, so the child can be sure
// the debounced write has already happened before it clears the settings.
constexpr int kQuiesceMs = 2400;

// How long the child will wait for its own temp file to appear before giving
// up, and how long it will sit there unsignalled before taking itself out.
constexpr int kChildSetupTimeoutMs = 25000;
constexpr int kChildWatchdogMs     = 120000;

// ── a localhost origin for the media bytes ───────────────────────────────
// One body for every path: a real fetch only has to land a real file on disk.
class MediaServer : public QTcpServer {
public:
    explicit MediaServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, &MediaServer::accept);
    }

    QByteArray body;

    QString trackUrl() const
    {
        return QStringLiteral("http://127.0.0.1:%1/track.mp4").arg(serverPort());
    }

private:
    void accept()
    {
        while (QTcpSocket *sock = nextPendingConnection()) {
            auto buf = std::make_shared<QByteArray>();
            connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                buf->append(sock->readAll());
                if (buf->indexOf("\r\n\r\n") < 0) return;
                buf->clear();
                sock->write("HTTP/1.0 200 OK\r\nContent-Type: audio/mp4\r\n"
                            "Content-Length: " + QByteArray::number(body.size())
                            + "\r\n\r\n");
                sock->write(body);
                sock->flush();
                sock->disconnectFromHost();
            });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        }
    }
};

// The one seam. Everything the Player does with the answer is the shipped
// code; this only decides what the answer is, the way the network would.
class LocalStreamClient : public TidalClient {
public:
    LocalStreamClient(TidalApi *api, QString url, QObject *parent = nullptr)
        : TidalClient(api, parent), m_url(std::move(url)) {}

    void fetchStreamManifest(qint64 trackId, StreamCb cb) override
    {
        Q_UNUSED(trackId);
        // Through the event loop, like a reply, so the Player is not called
        // back from inside its own playTracks().
        QTimer::singleShot(0, this, [cb = std::move(cb), url = m_url] {
            StreamManifest m;
            m.type     = StreamManifest::BTS;
            m.url      = url;
            m.mimeType = QStringLiteral("audio/mp4");
            m.codec    = QStringLiteral("aac");
            cb(m, QString());
        });
    }

private:
    QString m_url;
};

QVariantList inventedQueue(int n)
{
    QVariantList out;
    for (int i = 0; i < n; ++i) {
        QVariantMap t;
        t[QStringLiteral("id")]         = qlonglong(kTrackBase + i);
        t[QStringLiteral("title")]      = QStringLiteral("Track %1").arg(i);
        t[QStringLiteral("artists")]    = QStringLiteral("Artist");
        t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
        t[QStringLiteral("albumId")]    = qlonglong(90001);
        t[QStringLiteral("duration")]   = 200;
        out.append(t);
    }
    return out;
}

// The one tidal-wave temp file in this child's private temp directory (its
// TMPDIR), or an empty string.
QString soleTempMediaFile()
{
    const QStringList hits =
        QDir(QDir::tempPath()).entryList({ QStringLiteral("tidal-wave-*.mp4") },
                                         QDir::Files);
    if (hits.size() != 1) return {};
    return QDir(QDir::tempPath()).filePath(hits.first());
}

void writeReady(const QString &path, const QString &text)
{
    // Via a rename, so the parent can never read a half-written line.
    const QString part = path + QStringLiteral(".part");
    QFile f(part);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    f.write(text.toUtf8());
    f.flush();
    f.close();
    QFile::rename(part, path);
}

// ── the child ────────────────────────────────────────────────────────────

int runChild(int argc, char **argv)
{
    QApplication app(argc, argv);

    const QString settingsDir = QString::fromLocal8Bit(argv[2]);
    const QString readyPath   = QString::fromLocal8Bit(argv[3]);

    QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
    QCoreApplication::setApplicationName(QStringLiteral("tst_signals"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settingsDir);

    MediaServer server;
    if (!server.listen(QHostAddress::LocalHost)) {
        writeReady(readyPath, QStringLiteral("ERROR the fixture's own server would not listen\n"));
        return 3;
    }
    // Not audio: enough bytes to be a real file on disk, nothing a decoder
    // will ever make a sound out of.
    server.body = QByteArray(256 * 1024, '\x11');

    TidalApi          api;
    LocalStreamClient client(&api, server.trackUrl());
    client.setUserId(kUser);

    // Declared last of the long-lived objects, so it is destroyed *first*:
    // ~Player calls savePlaybackState(), which reads the account id back off
    // the client, and the client has to still be there when it does.
    Application appObj;
    const bool installed = appObj.installSignalHandlers();

    // Parented to the Application exactly as Application::run() parents it,
    // so the destructor under test is reached by the production route.
    auto *player = new Player(&client, &appObj);

    // Driven from a timer: Player defers its audio init by one turn of the
    // event loop, and a playTracks() called before that is silently dropped,
    // so no temp file would ever be made.
    QTimer::singleShot(150, player, [player] {
        player->setMuted(true);
        player->setVolume(kVolume);
        player->setRepeatMode(kRepeatMode);
        player->setPlaybackSource(QStringLiteral("album"), QStringLiteral("90001"),
                                  QStringLiteral("Album"));
        player->playTracks(inventedQueue(5), 0);
    });

    // Take itself out through _exit() if nobody ever signals it: an orphan
    // that tidied up with quit() would look like a child that was signalled.
    QTimer::singleShot(kChildWatchdogMs, qApp, [] { ::_exit(97); });

    // Wait for the shipped code to put a temp file on disk, then go quiet
    // long enough for the debounced save to have happened, then wipe the
    // settings so that anything found there afterwards came from ~Player.
    auto *poll = new QTimer(&app);
    auto  clock = std::make_shared<QElapsedTimer>();
    clock->start();
    poll->setInterval(25);
    QObject::connect(poll, &QTimer::timeout, poll, [poll, readyPath, clock, installed] {
        const QString media = soleTempMediaFile();
        if (media.isEmpty()) {
            if (clock->elapsed() > kChildSetupTimeoutMs) {
                poll->stop();
                writeReady(readyPath,
                           QStringLiteral("ERROR no temp media file appeared; the "
                                          "fixture never reached the leak\n"));
            }
            return;
        }
        poll->stop();
        QTimer::singleShot(kQuiesceMs, poll, [media, readyPath, installed] {
            QSettings s;
            s.clear();
            s.sync();
            writeReady(readyPath, QStringLiteral("OK %1\n%2\n")
                                      .arg(installed ? QStringLiteral("installed")
                                                     : QStringLiteral("not-installed"),
                                           media));
        });
    });
    poll->start();

    return app.exec();
}

} // namespace

class TestSignals : public QObject {
    Q_OBJECT

private slots:
    void cleanup() { stopChild(); }

    // A SIGTERM to a live process leaves no temp file behind and the session
    // on disk.
    void sigtermLeavesNoTempFileAndSavesTheSession()
    {
        QString why;
        QVERIFY2(startChildAndWaitForReady(&why), qPrintable(why));

        // Pre-conditions: there is a real temp file, and there is no saved
        // session that could be mistaken for the one the destructor writes.
        QVERIFY2(QFile::exists(m_mediaPath),
                 qPrintable(QStringLiteral("the child reported %1 but it is not there")
                                .arg(m_mediaPath)));
        QVERIFY2(QFile(m_mediaPath).size() > 0, "the temp media file is empty");
        QVERIFY2(!rawSettingsContain("playback"),
                 "the settings already held a session before the signal, so "
                 "this test could not tell a destructor save from a debounced one");

        QVERIFY2(signalChild(SIGTERM), "could not signal the child");

        QVERIFY2(m_child->waitForFinished(15000),
                 "the process did not finish after SIGTERM - a shutdown that "
                 "hangs hangs the user's logout");
        // The two effects first, so a failure names what the user lost.
        QVERIFY2(!QFile::exists(m_mediaPath),
                 qPrintable(QStringLiteral("the temp media file survived SIGTERM: %1")
                                .arg(m_mediaPath)));

        const QString prefix = QStringLiteral("user_%1/playback/").arg(kUser);
        QVERIFY2(!savedValue(prefix + QStringLiteral("queue")).toByteArray().isEmpty(),
                 "the queue was not saved, so ~Player never ran");
        QVERIFY(qAbs(savedValue(prefix + QStringLiteral("volume")).toDouble() - kVolume) < 0.001);
        QCOMPARE(savedValue(prefix + QStringLiteral("repeat")).toInt(), kRepeatMode);
        QCOMPARE(savedValue(prefix + QStringLiteral("sourceName")).toString(),
                 QStringLiteral("Album"));

        // And the process exited normally.
        QCOMPARE(m_child->exitStatus(), QProcess::NormalExit);
        QCOMPARE(m_child->exitCode(), 0);
    }

    // Ctrl-C in a terminal and the hang-up of a session going away are the
    // same request and take the same path.
    void aTerminalSignalTakesTheSameCleanPath_data()
    {
        QTest::addColumn<int>("sig");
        QTest::newRow("SIGINT") << int(SIGINT);
        QTest::newRow("SIGHUP") << int(SIGHUP);
    }

    void aTerminalSignalTakesTheSameCleanPath()
    {
        QFETCH(int, sig);

        QString why;
        QVERIFY2(startChildAndWaitForReady(&why), qPrintable(why));
        QVERIFY(QFile::exists(m_mediaPath));

        QVERIFY2(signalChild(sig), "could not signal the child");

        QVERIFY2(m_child->waitForFinished(15000), "the process did not finish");
        QVERIFY2(!QFile::exists(m_mediaPath), "the temp media file survived the signal");
        QCOMPARE(m_child->exitStatus(), QProcess::NormalExit);
        QCOMPARE(m_child->exitCode(), 0);
    }

    // A logout manager sends SIGTERM, waits and sends another. The handlers are
    // installed with SA_RESETHAND, so the second gets the default disposition.
    // Asserted: the process goes away promptly, by either route.
    void aSecondSignalCannotWedgeTheShutdown()
    {
        QString why;
        QVERIFY2(startChildAndWaitForReady(&why), qPrintable(why));

        QVERIFY2(signalChild(SIGTERM), "could not signal the child");
        QVERIFY2(signalChild(SIGTERM), "could not signal the child a second time");

        QElapsedTimer t;
        t.start();
        QVERIFY2(m_child->waitForFinished(15000),
                 "two SIGTERMs left the process running");
        qInfo("gone %lld ms after the second SIGTERM", t.elapsed());
    }

private:
    std::unique_ptr<QTemporaryDir> m_tmpDir;    // the child's TMPDIR
    std::unique_ptr<QTemporaryDir> m_cfgDir;    // the child's QSettings root
    std::unique_ptr<QProcess>      m_child;
    QString                        m_mediaPath;

    // Starts this binary again in --child mode and blocks until it says it is
    // ready, which it only does once the shipped code has a temp media file on
    // disk and the settings have been wiped.
    bool startChildAndWaitForReady(QString *why)
    {
        m_tmpDir = std::make_unique<QTemporaryDir>();
        m_cfgDir = std::make_unique<QTemporaryDir>();
        if (!m_tmpDir->isValid() || !m_cfgDir->isValid()) {
            *why = QStringLiteral("could not make the child's scratch directories");
            return false;
        }
        const QString readyPath = m_tmpDir->filePath(QStringLiteral("ready"));

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        // QDir::tempPath() in the child is a directory of its own, far from
        // the real /tmp.
        env.insert(QStringLiteral("TMPDIR"), m_tmpDir->path());
        // Never a window on the real screen, whatever ctest was given.
        env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));

        m_child = std::make_unique<QProcess>();
        m_child->setProcessEnvironment(env);
        m_child->setProgram(QCoreApplication::applicationFilePath());
        m_child->setArguments({ QString::fromLatin1(kChildFlag),
                                m_cfgDir->path(), readyPath });
        m_child->setProcessChannelMode(QProcess::ForwardedErrorChannel);
        m_child->start();
        if (!m_child->waitForStarted(10000)) {
            *why = QStringLiteral("the child process would not start");
            return false;
        }

        QElapsedTimer t;
        t.start();
        while (!QFile::exists(readyPath) && t.elapsed() < 40000) {
            if (m_child->state() != QProcess::Running) {
                *why = QStringLiteral("the child exited (%1) before it was ready")
                           .arg(m_child->exitCode());
                return false;
            }
            QTest::qWait(25);
        }
        if (!QFile::exists(readyPath)) {
            *why = QStringLiteral("the child never reported ready");
            return false;
        }

        QFile f(readyPath);
        if (!f.open(QIODevice::ReadOnly)) {
            *why = QStringLiteral("could not read the child's ready file");
            return false;
        }
        const QStringList lines =
            QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
        if (lines.isEmpty() || !lines.first().startsWith(QStringLiteral("OK"))) {
            *why = QStringLiteral("the child could not set the fixture up: %1")
                       .arg(lines.value(0));
            return false;
        }
        if (lines.first().contains(QStringLiteral("not-installed"))) {
            // On a platform with no POSIX signals there is nothing to assert.
            *why = QStringLiteral("Application::installSignalHandlers() returned false");
            return false;
        }
        m_mediaPath = lines.value(1);
        if (m_mediaPath.isEmpty()) {
            *why = QStringLiteral("the child named no temp media file");
            return false;
        }
        return true;
    }

    // Only ever the pid this test started, by that pid, and never by name.
    bool signalChild(int sig)
    {
        if (!m_child) return false;
        const qint64 pid = m_child->processId();
        if (pid <= 0) return false;
        return ::kill(static_cast<pid_t>(pid), sig) == 0;
    }

    void stopChild()
    {
        if (m_child && m_child->state() != QProcess::NotRunning) {
            const qint64 pid = m_child->processId();
            if (pid > 0) ::kill(static_cast<pid_t>(pid), SIGKILL);
            m_child->waitForFinished(5000);
        }
        m_child.reset();
        m_tmpDir.reset();
        m_cfgDir.reset();
        m_mediaPath.clear();
    }

    // One value out of the settings file the child left behind. Read through a
    // QSettings built fresh and sync()ed each time, because the child wrote
    // that file after this process last looked at it.
    QVariant savedValue(const QString &key) const
    {
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_cfgDir->path());
        QSettings s(QSettings::IniFormat, QSettings::UserScope,
                    QStringLiteral("TidalWaveTest"), QStringLiteral("tst_signals"));
        s.sync();
        return s.value(key);
    }

    // Read as bytes rather than through QSettings, so the pre-condition check
    // cannot be answered out of this process's own QSettings cache.
    bool rawSettingsContain(const QString &needle) const
    {
        QDirIterator it(m_cfgDir->path(), QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            QFile f(it.next());
            if (!f.open(QIODevice::ReadOnly)) continue;
            if (QString::fromUtf8(f.readAll()).contains(needle)) return true;
        }
        return false;
    }
};

int main(int argc, char **argv)
{
    if (argc >= 4 && qstrcmp(argv[1], kChildFlag) == 0)
        return runChild(argc, argv);

    QApplication app(argc, argv);
    TestSignals tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "tst_signals.moc"
