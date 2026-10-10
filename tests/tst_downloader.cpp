// Finding ffmpeg. A desktop launcher gives the app a minimal PATH, so the
// lookup also searches fallback directories, and it runs on every call so an
// ffmpeg installed while the app is open is found.
// Nothing here runs ffmpeg: the scratch executables only need the execute bit.

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

    // ffmpeg off PATH, in a directory only the fallback list names.
    void ffmpegOffTheLauncherPathIsStillFound() {
        const QString elsewhere = m_dir.filePath(QStringLiteral("usr-local-bin"));
        QVERIFY(placeExecutable(elsewhere, QStringLiteral("ffmpeg")));

        const QString nothing = m_dir.filePath(QStringLiteral("empty"));
        QDir().mkpath(nothing);
        qputenv("PATH", nothing.toLocal8Bit());

        QCOMPARE(Downloader::resolveFfmpeg(QStringList{ elsewhere }),
                 elsewhere + QStringLiteral("/ffmpeg"));
    }

    // PATH wins: an ffmpeg the user put on PATH is used before any fallback.
    void pathBeatsTheFallbacks() {
        const QString onPath = m_dir.filePath(QStringLiteral("on-path"));
        const QString fallback = m_dir.filePath(QStringLiteral("fallback"));
        QVERIFY(placeExecutable(onPath, QStringLiteral("ffmpeg")));
        QVERIFY(placeExecutable(fallback, QStringLiteral("ffmpeg")));
        qputenv("PATH", onPath.toLocal8Bit());

        QCOMPARE(Downloader::resolveFfmpeg(QStringList{ fallback }),
                 onPath + QStringLiteral("/ffmpeg"));
    }

    // Pins the list, so dropping an entry fails here.
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
