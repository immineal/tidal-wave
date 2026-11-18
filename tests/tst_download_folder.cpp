// The download folder: what it starts as, that Settings can move it, that the
// save dialog opens in it, and "Show in folder", which asks the desktop's
// file manager over org.freedesktop.FileManager1 and opens the folder when
// none answers. A private bus stands in for the desktop. No network, no ffmpeg.

#include <QTest>
#include <QApplication>
#include <QDBusAbstractAdaptor>
#include <QDBusConnection>
#include <QDBusError>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QProcess>
#include <QSettings>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTimer>
#include <QUrl>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Downloader.h"

namespace {

QString g_busAddress;

// A file manager's side of ShowItems.
class FileManager : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.FileManager1")
public:
    QStringList shown;
public slots:
    void ShowItems(const QStringList &uris, const QString &startupId) {
        Q_UNUSED(startupId);
        shown << uris;
    }
};

// Catches what QDesktopServices would hand the desktop.
class UrlCatcher : public QObject {
    Q_OBJECT
public:
    QList<QUrl> opened;
public slots:
    void open(const QUrl &url) { opened << url; }
};

} // namespace

class TestDownloadFolder : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_download_folder"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
        QSettings::setPath(QSettings::NativeFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);

        // The download looks for ffmpeg before it asks where to save.
        const QString bin = m_dir.filePath(QStringLiteral("bin"));
        QVERIFY(QDir().mkpath(bin));
        QFile ffmpeg(bin + QStringLiteral("/ffmpeg"));
        QVERIFY(ffmpeg.open(QIODevice::WriteOnly));
        ffmpeg.write("#!/bin/sh\nexit 1\n");
        ffmpeg.close();
        QVERIFY(ffmpeg.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                      | QFileDevice::ExeOwner));
        m_savedPath = qgetenv("PATH");
        qputenv("PATH", QFile::encodeName(bin));
    }

    void cleanupTestCase() { qputenv("PATH", m_savedPath); }

    void init() { QSettings().clear(); }

    // A user who saved somewhere before keeps that place as the folder.
    void theFolderStartsWhereTheLastSaveWent() {
        TidalApi api;
        TidalClient client{&api};
        Downloader dl{&client};
        const QString music = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
        QCOMPARE(dl.folder(), music.isEmpty() ? QDir::homePath() : music);

        const QString before = m_dir.filePath(QStringLiteral("earlier"));
        QVERIFY(QDir().mkpath(before));
        QSettings().setValue(QStringLiteral("download/lastDir"), before);
        QCOMPARE(dl.folder(), before);
    }

    void settingTheFolderKeepsIt() {
        TidalApi api;
        TidalClient client{&api};
        Downloader dl{&client};
        QSignalSpy changed(&dl, &Downloader::folderChanged);
        const QString chosen = m_dir.filePath(QStringLiteral("chosen"));
        QVERIFY(QDir().mkpath(chosen));
        dl.setFolder(chosen);
        QCOMPARE(changed.size(), 1);
        QCOMPARE(dl.folder(), chosen);

        Downloader later{&client};
        QCOMPARE(later.folder(), chosen);
    }

    void theSaveDialogOpensInTheFolder() {
        if (QGuiApplication::platformName() != QLatin1String("offscreen"))
            QSKIP("answers a save dialog, so it runs with the offscreen platform only");
        const QSettings dialogState(QSettings::UserScope, QStringLiteral("QtProject"));
        if (!dialogState.fileName().startsWith(m_dir.path()))
            QSKIP("the save dialog's state cannot be kept out of the user's settings here");

        TidalApi api;
        TidalClient client{&api};
        Downloader dl{&client};
        const QString chosen = m_dir.filePath(QStringLiteral("for-dialog"));
        QVERIFY(QDir().mkpath(chosen));
        dl.setFolder(chosen);

        QString openedIn;
        QTimer answer;
        answer.setInterval(20);
        connect(&answer, &QTimer::timeout, this, [&] {
            auto *dialog = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
            if (!dialog) return;
            answer.stop();
            openedIn = dialog->directory().absolutePath();
            QMetaObject::invokeMethod(dialog, "reject", Qt::QueuedConnection);
        });
        answer.start();

        QVariantMap track;
        track[QStringLiteral("id")]      = qlonglong(100000002);
        track[QStringLiteral("title")]   = QStringLiteral("Tone");
        track[QStringLiteral("artists")] = QStringLiteral("Artist");
        dl.downloadTrack(track);
        QTRY_VERIFY_WITH_TIMEOUT(!openedIn.isEmpty(), 10000);
        QCOMPARE(openedIn, chosen);
    }

    void showInFolderAsksTheFileManager() {
        if (g_busAddress.isEmpty())
            QSKIP("no private dbus-daemon could be started, so there is no bus to test on");
        QDBusConnection desktop = QDBusConnection::connectToBus(g_busAddress, QStringLiteral("fm"));
        QVERIFY2(desktop.isConnected(), qPrintable(desktop.lastError().message()));
        FileManager fm;
        QVERIFY(desktop.registerObject(QStringLiteral("/org/freedesktop/FileManager1"), &fm,
                                       QDBusConnection::ExportAllSlots));
        QVERIFY(desktop.registerService(QStringLiteral("org.freedesktop.FileManager1")));

        UrlCatcher catcher;
        QDesktopServices::setUrlHandler(QStringLiteral("file"), &catcher, "open");

        const QString file = m_dir.filePath(QStringLiteral("Artist - Tone.flac"));
        QFile f(file);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();

        TidalApi api;
        TidalClient client{&api};
        Downloader dl{&client};
        dl.showInFolder(file);
        QTRY_COMPARE(fm.shown, QStringList{QUrl::fromLocalFile(file).toString()});
        QTest::qWait(50);
        QVERIFY2(catcher.opened.isEmpty(), "the folder was opened as well as shown");

        desktop.unregisterService(QStringLiteral("org.freedesktop.FileManager1"));
        desktop.unregisterObject(QStringLiteral("/org/freedesktop/FileManager1"));
        QDesktopServices::unsetUrlHandler(QStringLiteral("file"));
    }

    // With no file manager on the bus the folder opens, with nothing selected.
    void showInFolderFallsBackToTheFolder() {
        if (g_busAddress.isEmpty())
            QSKIP("no private dbus-daemon could be started, so there is no bus to test on");
        UrlCatcher catcher;
        QDesktopServices::setUrlHandler(QStringLiteral("file"), &catcher, "open");

        const QString file = m_dir.filePath(QStringLiteral("Other - Tone.flac"));
        QFile f(file);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();

        TidalApi api;
        TidalClient client{&api};
        Downloader dl{&client};
        dl.showInFolder(file);
        QTRY_COMPARE_WITH_TIMEOUT(catcher.opened.size(), 1, 8000);
        QCOMPARE(catcher.opened.first(), QUrl::fromLocalFile(m_dir.path()));
        QDesktopServices::unsetUrlHandler(QStringLiteral("file"));
    }

private:
    QTemporaryDir m_dir;
    QByteArray    m_savedPath;
};

int main(int argc, char **argv) {
    // A bus of this test's own, so nothing here reaches the session it runs in.
    // It names no service directories: the session's would start the real
    // file manager for a ShowItems that nothing on the bus answers.
    QTemporaryDir busDir;
    const QString config = busDir.filePath(QStringLiteral("bus.conf"));
    {
        QFile f(config);
        if (f.open(QIODevice::WriteOnly))
            f.write("<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN\"\n"
                    " \"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">\n"
                    "<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>"
                    "<auth>EXTERNAL</auth><policy context=\"default\">"
                    "<allow send_destination=\"*\" eavesdrop=\"true\"/>"
                    "<allow eavesdrop=\"true\"/><allow own=\"*\"/></policy></busconfig>\n");
    }
    QProcess daemon;
    daemon.start(QStringLiteral("dbus-daemon"),
                 { QStringLiteral("--config-file=") + config, QStringLiteral("--nofork"),
                   QStringLiteral("--print-address") });
    if (daemon.waitForStarted(3000) && daemon.waitForReadyRead(3000))
        g_busAddress = QString::fromLocal8Bit(daemon.readLine()).trimmed();
    if (g_busAddress.isEmpty())
        qputenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/no-bus");
    else
        qputenv("DBUS_SESSION_BUS_ADDRESS", g_busAddress.toLocal8Bit());

    int rc = 0;
    {
        QApplication app(argc, argv);
        TestDownloadFolder test;
        rc = QTest::qExec(&test, argc, argv);
    }
    daemon.kill();
    daemon.waitForFinished(3000);
    return rc;
}

#include "tst_download_folder.moc"
