// Finding ffmpeg.
//
// Downloads shell out to ffmpeg, and the app has to find it in the environment
// it was *launched* in. A desktop launcher hands a process
// PATH=/usr/bin:/bin:/usr/sbin:/sbin and nothing else - not the user's shell
// PATH - so an ffmpeg in /usr/local/bin or ~/.local/bin is invisible to an app
// started from the menu while working fine from a terminal. And a path
// resolved once at construction means installing ffmpeg does not take effect
// until the app is restarted, which is not what "install ffmpeg" sounds like.
//
// Nothing here runs ffmpeg; the scratch executables below are empty files with
// the execute bit set, because the question is only where the lookup looks.

#include <QTest>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Downloader.h"

namespace {

bool placeExecutable(const QString &dir, const QString &name) {
    QDir().mkpath(dir);
    QFile f(dir + QLatin1Char('/') + name);
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write("#!/bin/sh\nexit 0\n");
    f.close();
    return f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner
                            | QFileDevice::ExeOwner);
}

} // namespace

class TestDownloader : public QObject {
    Q_OBJECT

private slots:
    void init() {
        m_savedPath = qgetenv("PATH");
        QVERIFY(m_dir.isValid());
    }

    void cleanup() { qputenv("PATH", m_savedPath); }

    // The regression: ffmpeg installed while the app is open.
    void ffmpegInstalledAfterStartupIsFound() {
        const QString binDir = m_dir.filePath(QStringLiteral("bin"));
        QDir().mkpath(binDir);
        qputenv("PATH", binDir.toLocal8Bit());

        TidalApi    api;
        TidalClient client{&api};
        Downloader  dl{&client};
        QVERIFY2(dl.ffmpegPath().isEmpty(),
                 "the scratch PATH was supposed to have no ffmpeg on it");

        QVERIFY(placeExecutable(binDir, QStringLiteral("ffmpeg")));

        QCOMPARE(dl.ffmpegPath(), binDir + QStringLiteral("/ffmpeg"));
    }

    // The launcher's PATH, reproduced exactly, with ffmpeg somewhere a
    // package manager did not put it.
    void ffmpegOffTheLauncherPathIsStillFound() {
        const QString elsewhere = m_dir.filePath(QStringLiteral("usr-local-bin"));
        QVERIFY(placeExecutable(elsewhere, QStringLiteral("ffmpeg")));

        const QString nothing = m_dir.filePath(QStringLiteral("empty"));
        QDir().mkpath(nothing);
        qputenv("PATH", nothing.toLocal8Bit());

        QCOMPARE(Downloader::resolveFfmpeg(QStringList{ elsewhere }),
                 elsewhere + QStringLiteral("/ffmpeg"));
    }

    // PATH still wins: a user who put a particular ffmpeg on their PATH gets
    // that one and not whatever is in /usr/local/bin.
    void pathBeatsTheFallbacks() {
        const QString onPath = m_dir.filePath(QStringLiteral("on-path"));
        const QString fallback = m_dir.filePath(QStringLiteral("fallback"));
        QVERIFY(placeExecutable(onPath, QStringLiteral("ffmpeg")));
        QVERIFY(placeExecutable(fallback, QStringLiteral("ffmpeg")));
        qputenv("PATH", onPath.toLocal8Bit());

        QCOMPARE(Downloader::resolveFfmpeg(QStringList{ fallback }),
                 onPath + QStringLiteral("/ffmpeg"));
    }

    // The list itself, so that dropping an entry is a failure here rather than
    // a bug report from whoever installs ffmpeg that way.
    void theFallbackListCoversTheUsualPlaces() {
        const QStringList dirs = Downloader::ffmpegFallbackDirs();
        QVERIFY2(dirs.contains(QStringLiteral("/usr/local/bin")),
                 "the classic make-install location is not searched");
        QVERIFY2(dirs.contains(QDir::homePath() + QStringLiteral("/.local/bin")),
                 "a per-user install is not searched");
        QVERIFY2(dirs.contains(QStringLiteral("/snap/bin")),
                 "a snap-installed ffmpeg is not searched");
    }

private:
    QTemporaryDir m_dir;
    QByteArray    m_savedPath;
};

QTEST_MAIN(TestDownloader)
#include "tst_downloader.moc"
