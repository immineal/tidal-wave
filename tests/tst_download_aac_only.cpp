// A download of a track Tidal has only in AAC. It asks for FLAC, Tidal
// refuses, and the download ends there with nothing written: no AAC is turned
// into a file that claims to be lossless. The test answers the save dialog and
// a localhost server stands in for Tidal. No ffmpeg runs. Ids invented.

#include <QTest>
#include <QApplication>
#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QSettings>
#include <QSignalSpy>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <QVariantMap>
#include <memory>
#include <utility>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Downloader.h"

namespace {

constexpr qlonglong kTrack = 100000001;

QByteArray noFlacRefusal()
{
    return QJsonDocument(QJsonObject{{"errors", QJsonArray{QJsonObject{
        {"code", QStringLiteral("CLIENT_NOT_ENTITLED")},
        {"detail", QStringLiteral("refused")},
        {"status", QStringLiteral("403")}}}}}).toJson();
}

// What a wider request would be answered with: a whole AAC track.
QByteArray aacAnswer()
{
    const QByteArray mpd =
        "<?xml version='1.0' encoding='UTF-8'?>"
        "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\" "
             "mediaPresentationDuration=\"PT2.000S\"><Period id=\"0\">"
        "<AdaptationSet id=\"0\" contentType=\"audio\" mimeType=\"audio/mp4\">"
        "<Representation id=\"AACLC\" codecs=\"mp4a.40.2\" bandwidth=\"321589\" "
                        "audioSamplingRate=\"44100\">"
        "<SegmentTemplate timescale=\"44100\" initialization=\"http://127.0.0.1:1/0.mp4\" "
                         "media=\"http://127.0.0.1:1/$Number$.mp4\" startNumber=\"1\">"
        "<SegmentTimeline><S d=\"44100\" r=\"1\"/></SegmentTimeline>"
        "</SegmentTemplate></Representation></AdaptationSet></Period></MPD>";
    const QJsonObject attributes{
        {"trackPresentation", QStringLiteral("FULL")},
        {"formats", QJsonArray{QStringLiteral("AACLC")}},
        {"uri", QStringLiteral("data:application/dash+xml;base64,")
                    + QString::fromLatin1(mpd.toBase64())},
    };
    return QJsonDocument(QJsonObject{
        {"data", QJsonObject{{"id", QString::number(kTrack)},
                             {"type", QStringLiteral("trackManifests")},
                             {"attributes", attributes}}},
    }).toJson();
}

// Answers the requests in turn and notes what was asked.
class AnswersInTurn : public QTcpServer {
public:
    AnswersInTurn()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    if (buf->indexOf("\r\n\r\n") < 0) return;
                    targets << QString::fromUtf8(
                        buf->left(buf->indexOf("\r\n")).split(' ').value(1));
                    buf->clear();
                    const Answer a = answers.isEmpty() ? Answer{500, "{}"} : answers.takeFirst();
                    sock->write("HTTP/1.0 " + QByteArray::number(a.first) + " Answer\r\n"
                                "Content-Type: application/json\r\n"
                                "Content-Length: " + QByteArray::number(a.second.size())
                                + "\r\n\r\n" + a.second);
                    sock->flush();
                    sock->disconnectFromHost();
                });
            }
        });
    }

    using Answer = std::pair<int, QByteArray>;

    QList<Answer> answers;
    QStringList   targets;
};

// The real TidalApi with every request to Tidal sent to the local server.
class LocalApi : public TidalApi {
public:
    QString local;

protected:
    QString baseUrl(const QString &) const override { return local; }
};

} // namespace

class TestDownloadAacOnly : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_download_aac_only"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        // The save dialog is Qt's own, which the test can answer. It keeps
        // its state in a native-format file of its own.
        QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
        QSettings::setPath(QSettings::NativeFormat, QSettings::UserScope, m_dir.path());

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

    void theRefusalEndsTheDownloadAndNothingIsWritten()
    {
        if (QGuiApplication::platformName() != QLatin1String("offscreen"))
            QSKIP("answers a save dialog, so it runs with the offscreen platform only");
        // The dialog saves its state when it closes.
        const QSettings dialogState(QSettings::UserScope, QStringLiteral("QtProject"));
        if (!dialogState.fileName().startsWith(m_dir.path()))
            QSKIP("the save dialog's state cannot be kept out of the user's settings here");

        AnswersInTurn tidal;
        QVERIFY(tidal.listen(QHostAddress::LocalHost));
        tidal.answers = {{403, noFlacRefusal()}, {200, aacAnswer()}};
        LocalApi api;
        api.local = QStringLiteral("http://127.0.0.1:%1/").arg(tidal.serverPort());
        TidalClient client{&api};
        // The playback setting: a download does not go by it.
        client.setAudioQuality(AudioQuality::Lossless);

        Downloader downloader{&client};
        QSignalSpy started(&downloader, &Downloader::downloadStarted);
        QSignalSpy finished(&downloader, &Downloader::downloadFinished);
        QSignalSpy failed(&downloader, &Downloader::downloadError);

        const QString saveDir = m_dir.filePath(QStringLiteral("saved"));
        QVERIFY(QDir().mkpath(saveDir));
        const QString target = saveDir + QStringLiteral("/Tone.flac");
        // Where the dialog opens, so it lists no directory of the user's.
        QSettings().setValue(QStringLiteral("download/lastDir"), saveDir);

        // The dialog runs its own event loop, so it is answered from a timer.
        QTimer answerDialog;
        answerDialog.setInterval(20);
        connect(&answerDialog, &QTimer::timeout, this, [&] {
            auto *dialog = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
            if (!dialog) return;
            answerDialog.stop();
            dialog->selectFile(target);
            QMetaObject::invokeMethod(dialog, "accept", Qt::QueuedConnection);
        });
        answerDialog.start();

        QVariantMap track;
        track[QStringLiteral("id")]      = kTrack;
        track[QStringLiteral("title")]   = QStringLiteral("Tone");
        track[QStringLiteral("artists")] = QStringLiteral("Artist");
        downloader.downloadTrack(track);

        QTRY_VERIFY2_WITH_TIMEOUT(!failed.isEmpty() || !finished.isEmpty(),
                                  "the download neither ended nor failed", 15000);
        answerDialog.stop();

        QCOMPARE(started.size(), 1);
        QVERIFY2(finished.isEmpty(), "a track with no FLAC was downloaded");
        QCOMPARE(failed.size(), 1);
        QCOMPARE(failed.first().at(0).toLongLong(), kTrack);
        const QString said = failed.first().at(1).toString();
        QVERIFY2(said.startsWith(QStringLiteral("Could not start the download.")), qPrintable(said));

        // One request, for FLAC, and no second one with the lossy formats.
        QCOMPARE(tidal.targets.size(), 1);
        QVERIFY2(tidal.targets.first().startsWith(QStringLiteral(
                     "/trackManifests/100000001?formats=FLAC&formats=FLAC_HIRES&manifestType=")),
                 qPrintable(tidal.targets.first()));
        QVERIFY(!downloader.isDownloading(kTrack));
        QVERIFY2(!QFile::exists(target), "the refused download left a file");
        QCOMPARE(QDir(saveDir).entryList(QDir::Files).size(), 0);
    }

private:
    QTemporaryDir m_dir;
    QByteArray    m_savedPath;
};

QTEST_MAIN(TestDownloadAacOnly)
#include "tst_download_aac_only.moc"
