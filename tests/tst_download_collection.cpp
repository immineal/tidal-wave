// Downloading a whole album or playlist. Each track costs one stream request,
// which counts against the account's playback budget, so the run goes one
// track at a time, keeps a gap between stream requests, stops on a 429, and
// a segment retry never asks for the manifest again. A localhost server
// stands in for Tidal and a shell script for ffmpeg. Ids invented.

#include <QTest>
#include <QByteArray>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QHash>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QSignalSpy>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Downloader.h"

namespace {

QByteArray manifestFor(const QString &base, qlonglong id)
{
    const QString seg = base + QStringLiteral("seg/%1/").arg(id);
    const QByteArray mpd = QStringLiteral(
        "<?xml version='1.0' encoding='UTF-8'?>"
        "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\" "
             "mediaPresentationDuration=\"PT1.000S\"><Period id=\"0\">"
        "<AdaptationSet id=\"0\" contentType=\"audio\" mimeType=\"audio/mp4\">"
        "<Representation id=\"FLAC,44100,16\" codecs=\"flac\" bandwidth=\"1000000\" "
                        "audioSamplingRate=\"44100\">"
        "<SegmentTemplate timescale=\"1000\" initialization=\"%1i.mp4\" "
                         "media=\"%1$Number$.mp4\" startNumber=\"1\">"
        "<SegmentTimeline><S d=\"500\" r=\"1\"/></SegmentTimeline>"
        "</SegmentTemplate></Representation></AdaptationSet></Period></MPD>")
        .arg(seg).toUtf8();
    const QJsonObject attributes{
        {"trackPresentation", QStringLiteral("FULL")},
        {"formats", QJsonArray{QStringLiteral("FLAC")}},
        {"uri", QStringLiteral("data:application/dash+xml;base64,")
                    + QString::fromLatin1(mpd.toBase64())},
    };
    return QJsonDocument(QJsonObject{
        {"data", QJsonObject{{"id", QString::number(id)},
                             {"type", QStringLiteral("trackManifests")},
                             {"attributes", attributes}}},
    }).toJson();
}

QByteArray notEntitled()
{
    return QJsonDocument(QJsonObject{{"errors", QJsonArray{QJsonObject{
        {"code", QStringLiteral("CLIENT_NOT_ENTITLED")},
        {"status", QStringLiteral("403")}}}}}).toJson();
}

struct Refusal { int status = 0; QByteArray retryAfter; QByteArray body; };

// Tidal's manifest endpoint and its CDN in one. `log` gets "m:<id>" for each
// manifest request and "s:<path>" for each segment, in arrival order.
class FakeTidal : public QTcpServer {
public:
    FakeTidal()
    {
        clock.start();
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    if (buf->indexOf("\r\n\r\n") < 0) return;
                    const QString target = QString::fromUtf8(
                        buf->left(buf->indexOf("\r\n")).split(' ').value(1));
                    buf->clear();
                    const QString path = target.section(QLatin1Char('?'), 0, 0);
                    QTimer::singleShot(delaysMs.value(path, 0), sock,
                                       [this, sock, path] { answer(sock, path); });
                    if (path.startsWith(QLatin1String("/trackManifests/"))) {
                        log << QStringLiteral("m:") + path.section(QLatin1Char('/'), 2);
                        manifestTimes << clock.elapsed();
                    } else {
                        log << QStringLiteral("s:") + path;
                    }
                });
            }
        });
    }

    QString base() const { return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort()); }
    int manifestsAsked() const { return int(log.filter(QStringLiteral("m:")).size()); }

    QHash<QString, QList<Refusal>> refuse;   // path -> answers before the real one
    QHash<QString, int> delaysMs;
    QStringList log;
    QList<qint64> manifestTimes;
    QElapsedTimer clock;

private:
    void reply(QTcpSocket *sock, int status, const QByteArray &body, const QByteArray &extra = {})
    {
        sock->write("HTTP/1.0 " + QByteArray::number(status) + " Answer\r\n" + extra
                    + "Content-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
        sock->flush();
        sock->disconnectFromHost();
    }

    void answer(QTcpSocket *sock, const QString &path)
    {
        QList<Refusal> &r = refuse[path];
        if (!r.isEmpty()) {
            const Refusal no = r.takeFirst();
            reply(sock, no.status, no.body,
                  no.retryAfter.isEmpty() ? QByteArray() : "Retry-After: " + no.retryAfter + "\r\n");
            return;
        }
        if (path.startsWith(QLatin1String("/trackManifests/"))) {
            reply(sock, 200, manifestFor(base(), path.section(QLatin1Char('/'), 2).toLongLong()),
                  "Content-Type: application/json\r\n");
        } else if (path.startsWith(QLatin1String("/seg/"))) {
            reply(sock, 200, path.toUtf8(), "Content-Type: audio/mp4\r\n");
        } else {
            reply(sock, 404, {});
        }
    }
};

// The real TidalApi with every request to Tidal sent to the local server.
class LocalApi : public TidalApi {
public:
    QString local;

protected:
    QString baseUrl(const QString &) const override { return local; }
};

QVariantMap trackOf(qlonglong id, const QString &title, int number)
{
    // No cover fields: the cover would be fetched from Tidal's image host.
    return {{QStringLiteral("id"), id},
            {QStringLiteral("title"), title},
            {QStringLiteral("artists"), QStringLiteral("Artist")},
            {QStringLiteral("albumTitle"), QStringLiteral("Album")},
            {QStringLiteral("trackNumber"), number}};
}

QVariantList threeTracks()
{
    return {trackOf(101, QStringLiteral("A"), 1), trackOf(102, QStringLiteral("B"), 2),
            trackOf(103, QStringLiteral("C"), 3)};
}

// Builds the client stack against one FakeTidal.
struct Rig {
    FakeTidal  tidal;
    LocalApi   api;
    std::unique_ptr<TidalClient> client;
    std::unique_ptr<Downloader>  downloader;

    Rig()
    {
        tidal.listen(QHostAddress::LocalHost);
        api.local = tidal.base();
        client     = std::make_unique<TidalClient>(&api);
        downloader = std::make_unique<Downloader>(client.get());
        downloader->setCollectionSpacingMs(0);
    }

    QString state(const QString &kind, const QString &id) const
    {
        return downloader->collectionState(kind, id).value(QStringLiteral("state")).toString();
    }
};

} // namespace

class TestDownloadCollection : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_download_collection"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

        // Writes something at the output path, which is its last argument.
        const QString bin = m_dir.filePath(QStringLiteral("bin"));
        QVERIFY(QDir().mkpath(bin));
        QFile ffmpeg(bin + QStringLiteral("/ffmpeg"));
        QVERIFY(ffmpeg.open(QIODevice::WriteOnly));
        ffmpeg.write("#!/bin/sh\nfor a in \"$@\"; do last=\"$a\"; done\nprintf x > \"$last\"\n");
        ffmpeg.close();
        QVERIFY(ffmpeg.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                      | QFileDevice::ExeOwner));
        m_savedPath = qgetenv("PATH");
        qputenv("PATH", QFile::encodeName(bin) + ":/usr/bin:/bin");
    }

    void cleanupTestCase() { qputenv("PATH", m_savedPath); }

    void init()
    {
        m_out = std::make_unique<QTemporaryDir>();
        QVERIFY(m_out->isValid());
    }

    // A segment that fails once is asked for again. The manifest, and with
    // it a stream request, is not.
    void aSegmentRetryCostsNoSecondStreamRequest()
    {
        Rig rig;
        rig.tidal.refuse[QStringLiteral("/seg/101/1.mp4")] = {{503, {}, {}}};
        QSignalSpy finished(rig.downloader.get(), &Downloader::downloadFinished);

        rig.downloader->downloadCollectionInto(QStringLiteral("playlist"), QStringLiteral("p1"),
                                               QStringLiteral("Mine"),
                                               {trackOf(101, QStringLiteral("A"), 1)},
                                               m_out->path());
        QTRY_COMPARE_WITH_TIMEOUT(rig.state(QStringLiteral("playlist"), QStringLiteral("p1")),
                                  QStringLiteral("done"), 10000);
        QCOMPARE(finished.size(), 1);
        QCOMPARE(rig.tidal.manifestsAsked(), 1);
        QCOMPARE(int(rig.tidal.log.count(QStringLiteral("s:/seg/101/1.mp4"))), 2);
        QVERIFY(QFile::exists(m_out->filePath(QStringLiteral("Mine/Artist - A.flac"))));
        const QVariantMap st = rig.downloader->collectionState(QStringLiteral("playlist"),
                                                               QStringLiteral("p1"));
        QCOMPARE(st.value(QStringLiteral("saved")).toInt(), 1);
        QCOMPARE(st.value(QStringLiteral("failed")).toInt(), 0);
    }

    // A run asks for one stream every 20 s at most: a 100-track playlist
    // takes over half an hour and stays clear of Tidal's playback limit.
    void theAppsGapBetweenStreamRequestsIsTwentySeconds()
    {
        QCOMPARE(Downloader::kCollectionSpacingMs, 20000);
    }

    // One track at a time: the next stream request goes only once the track
    // before it is saved, and never sooner than the spacing after the last.
    void tracksGoOneAtATimeWithAGapBetweenStreamRequests()
    {
        Rig rig;
        rig.downloader->setCollectionSpacingMs(400);
        QStringList order;
        connect(rig.downloader.get(), &Downloader::downloadFinished, this,
                [&](qlonglong id) { order << rig.tidal.log.filter(QStringLiteral("m:")).join(QLatin1Char(','))
                                           + QStringLiteral(" f:%1").arg(id); });

        rig.downloader->downloadCollectionInto(QStringLiteral("album"), QStringLiteral("7"),
                                               QStringLiteral("Artist - Album"), threeTracks(),
                                               m_out->path());
        QTRY_COMPARE_WITH_TIMEOUT(rig.state(QStringLiteral("album"), QStringLiteral("7")),
                                  QStringLiteral("done"), 15000);
        QCOMPARE(order, (QStringList{QStringLiteral("m:101 f:101"),
                                     QStringLiteral("m:101,m:102 f:102"),
                                     QStringLiteral("m:101,m:102,m:103 f:103")}));
        const QList<qint64> t = rig.tidal.manifestTimes;
        QCOMPARE(int(t.size()), 3);
        QVERIFY2(t[1] - t[0] >= 380 && t[2] - t[1] >= 380,
                 qPrintable(QStringLiteral("gaps of %1 and %2 ms").arg(t[1] - t[0]).arg(t[2] - t[1])));
        // An album's files are numbered.
        const QDir folder(m_out->filePath(QStringLiteral("Artist - Album")));
        QCOMPARE(folder.entryList(QDir::Files),
                 (QStringList{QStringLiteral("01 A.flac"), QStringLiteral("02 B.flac"),
                              QStringLiteral("03 C.flac")}));
    }

    // A 429 on a stream request stops the run. Nothing further is asked for,
    // and starting it again while Tidal's wait runs sends nothing either.
    void a429OnAStreamRequestStopsTheRun()
    {
        Rig rig;
        rig.tidal.refuse[QStringLiteral("/trackManifests/102")] = {{429, "1200", {}}};
        QSignalSpy failed(rig.downloader.get(), &Downloader::downloadError);

        rig.downloader->downloadCollectionInto(QStringLiteral("playlist"), QStringLiteral("p2"),
                                               QStringLiteral("Mine"), threeTracks(), m_out->path());
        QTRY_COMPARE_WITH_TIMEOUT(rig.state(QStringLiteral("playlist"), QStringLiteral("p2")),
                                  QStringLiteral("paused"), 10000);
        QVariantMap st = rig.downloader->collectionState(QStringLiteral("playlist"), QStringLiteral("p2"));
        QCOMPARE(st.value(QStringLiteral("saved")).toInt(), 1);
        QCOMPARE(st.value(QStringLiteral("failed")).toInt(), 0);
        QVERIFY(st.value(QStringLiteral("pauseSecs")).toInt() > 1100);
        QCOMPARE(failed.size(), 1);
        QTest::qWait(1000);
        QCOMPARE(rig.tidal.manifestsAsked(), 2);

        // Again, while the wait runs: it stops before asking.
        rig.downloader->downloadCollectionInto(QStringLiteral("playlist"), QStringLiteral("p2"),
                                               QStringLiteral("Mine"), threeTracks(), m_out->path());
        QTRY_COMPARE_WITH_TIMEOUT(rig.state(QStringLiteral("playlist"), QStringLiteral("p2")),
                                  QStringLiteral("paused"), 5000);
        QTest::qWait(500);
        QCOMPARE(rig.tidal.manifestsAsked(), 2);
        st = rig.downloader->collectionState(QStringLiteral("playlist"), QStringLiteral("p2"));
        // The first track was found where the first run put it.
        QCOMPARE(st.value(QStringLiteral("saved")).toInt(), 1);
    }

    // A long 429 on a segment stops the run the same way.
    void a429OnASegmentStopsTheRun()
    {
        Rig rig;
        rig.tidal.refuse[QStringLiteral("/seg/101/2.mp4")] = {{429, "1200", {}}};

        rig.downloader->downloadCollectionInto(QStringLiteral("playlist"), QStringLiteral("p3"),
                                               QStringLiteral("Mine"), threeTracks(), m_out->path());
        QTRY_COMPARE_WITH_TIMEOUT(rig.state(QStringLiteral("playlist"), QStringLiteral("p3")),
                                  QStringLiteral("paused"), 10000);
        QTest::qWait(1000);
        QCOMPARE(rig.tidal.manifestsAsked(), 1);
        QCOMPARE(QDir(m_out->filePath(QStringLiteral("Mine"))).entryList(QDir::Files).size(), 0);
    }

    // Cancel ends the track in flight and the run, and leaves no part file.
    void cancelEndsTheRunAndLeavesNothingHalfWritten()
    {
        Rig rig;
        rig.tidal.delaysMs[QStringLiteral("/seg/101/1.mp4")] = 1500;
        QSignalSpy cancelled(rig.downloader.get(), &Downloader::downloadCancelled);
        QSignalSpy failed(rig.downloader.get(), &Downloader::downloadError);

        rig.downloader->downloadCollectionInto(QStringLiteral("playlist"), QStringLiteral("p4"),
                                               QStringLiteral("Mine"), threeTracks(), m_out->path());
        QTRY_VERIFY_WITH_TIMEOUT(rig.tidal.log.contains(QStringLiteral("s:/seg/101/1.mp4")), 5000);
        QCOMPARE(rig.state(QStringLiteral("playlist"), QStringLiteral("p4")), QStringLiteral("running"));
        rig.downloader->cancelCollection(QStringLiteral("playlist"), QStringLiteral("p4"));

        QCOMPARE(rig.state(QStringLiteral("playlist"), QStringLiteral("p4")), QStringLiteral("cancelled"));
        QCOMPARE(cancelled.size(), 1);
        QCOMPARE(cancelled.first().at(0).toLongLong(), 101);
        QVERIFY(!rig.downloader->isDownloading(101));
        QTest::qWait(2000);
        QCOMPARE(failed.size(), 0);
        QCOMPARE(rig.tidal.manifestsAsked(), 1);
        QCOMPARE(QDir(m_out->filePath(QStringLiteral("Mine"))).entryList(QDir::Files).size(), 0);
    }

    // A track Tidal will not hand over is passed over; the run goes on.
    void aRefusedTrackIsPassedOver()
    {
        Rig rig;
        rig.tidal.refuse[QStringLiteral("/trackManifests/102")] = {{403, {}, notEntitled()}};

        rig.downloader->downloadCollectionInto(QStringLiteral("playlist"), QStringLiteral("p5"),
                                               QStringLiteral("Mine"), threeTracks(), m_out->path());
        QTRY_COMPARE_WITH_TIMEOUT(rig.state(QStringLiteral("playlist"), QStringLiteral("p5")),
                                  QStringLiteral("done"), 10000);
        const QVariantMap st = rig.downloader->collectionState(QStringLiteral("playlist"),
                                                               QStringLiteral("p5"));
        QCOMPARE(st.value(QStringLiteral("saved")).toInt(), 2);
        QCOMPARE(st.value(QStringLiteral("failed")).toInt(), 1);
        QVERIFY(!st.value(QStringLiteral("error")).toString().isEmpty());
        QCOMPARE(rig.tidal.manifestsAsked(), 3);
    }

    // A track already in the folder costs nothing.
    void aTrackAlreadySavedIsNotAskedFor()
    {
        Rig rig;
        const QString folder = m_out->filePath(QStringLiteral("Artist - Album"));
        QVERIFY(QDir().mkpath(folder));
        QFile there(folder + QStringLiteral("/02 B.flac"));
        QVERIFY(there.open(QIODevice::WriteOnly));
        there.close();

        rig.downloader->downloadCollectionInto(QStringLiteral("album"), QStringLiteral("8"),
                                               QStringLiteral("Artist - Album"), threeTracks(),
                                               m_out->path());
        QTRY_COMPARE_WITH_TIMEOUT(rig.state(QStringLiteral("album"), QStringLiteral("8")),
                                  QStringLiteral("done"), 10000);
        QCOMPARE(rig.tidal.log.filter(QStringLiteral("m:")),
                 (QStringList{QStringLiteral("m:101"), QStringLiteral("m:103")}));
        QCOMPARE(rig.downloader->collectionState(QStringLiteral("album"), QStringLiteral("8"))
                     .value(QStringLiteral("saved")).toInt(), 3);
    }

    // A second run waits for the first, so two never ask at once.
    void aSecondRunWaitsForTheFirst()
    {
        Rig rig;
        rig.downloader->downloadCollectionInto(QStringLiteral("album"), QStringLiteral("9"),
                                               QStringLiteral("One"),
                                               {trackOf(101, QStringLiteral("A"), 1),
                                                trackOf(102, QStringLiteral("B"), 2)},
                                               m_out->path());
        rig.downloader->downloadCollectionInto(QStringLiteral("playlist"), QStringLiteral("p6"),
                                               QStringLiteral("Two"),
                                               {trackOf(103, QStringLiteral("C"), 1)},
                                               m_out->path());
        QCOMPARE(rig.state(QStringLiteral("playlist"), QStringLiteral("p6")), QStringLiteral("waiting"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.state(QStringLiteral("playlist"), QStringLiteral("p6")),
                                  QStringLiteral("done"), 10000);
        QCOMPARE(rig.tidal.log.filter(QStringLiteral("m:")),
                 (QStringList{QStringLiteral("m:101"), QStringLiteral("m:102"),
                              QStringLiteral("m:103")}));
        QCOMPARE(rig.state(QStringLiteral("album"), QStringLiteral("9")), QStringLiteral("done"));
    }

private:
    QTemporaryDir m_dir;
    std::unique_ptr<QTemporaryDir> m_out;
    QByteArray m_savedPath;
};

QTEST_MAIN(TestDownloadCollection)
#include "tst_download_collection.moc"
