// A track Tidal has only in AAC, at the two lossless settings. A localhost
// server stands in for Tidal: it refuses the FLAC request, answers the wider
// one with an AAC DASH manifest and serves the segments. The real client and
// the Player's own load path do the rest. Every Player is muted. Ids invented.

#include <QTest>
#include <QByteArray>
#include <QHash>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QSettings>
#include <QSignalSpy>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>
#include <memory>
#include <utility>

#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"

#include "aac_dash_fixture.inc"

namespace {

// How far a backend's duration and last position may be from the file's own.
constexpr int kSlackMs = 300;

constexpr qlonglong kTrack = 100000001;

QVariantMap oneTrack() {
    QVariantMap t;
    t[QStringLiteral("id")]       = kTrack;
    t[QStringLiteral("title")]    = QStringLiteral("Tone");
    t[QStringLiteral("artists")]  = QStringLiteral("Artist");
    t[QStringLiteral("duration")] = kAacDashDurationMs / 1000;
    return t;
}

// Tidal's manifest for such a track: one Representation with the bare id
// "AACLC", absolute segment URLs, a SegmentTimeline. The timeline is the
// fixture's own.
QByteArray aacManifest(const QString &base)
{
    return "<?xml version='1.0' encoding='UTF-8'?>"
           "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" "
                "profiles=\"urn:mpeg:dash:profile:isoff-main:2011\" type=\"static\" "
                "minBufferTime=\"PT0.697S\" mediaPresentationDuration=\"PT2.000S\">"
           "<Period id=\"0\">"
           "<AdaptationSet id=\"0\" contentType=\"audio\" mimeType=\"audio/mp4\" "
                          "lang=\"und\" group=\"main\" segmentAlignment=\"true\">"
           "<Role schemeIdUri=\"urn:mpeg:dash:role:2011\" value=\"main\"/>"
           "<Representation id=\"AACLC\" codecs=\"mp4a.40.2\" "
                           "bandwidth=\"321589\" audioSamplingRate=\"44100\">"
           "<AudioChannelConfiguration "
               "schemeIdUri=\"urn:mpeg:dash:23003:3:audio_channel_configuration:2011\" value=\"2\"/>"
           "<SegmentTemplate timescale=\"44100\" "
               "initialization=\"" + base.toUtf8() + "0.mp4\" "
               "media=\"" + base.toUtf8() + "$Number$.mp4\" startNumber=\"1\">"
           "<SegmentTimeline><S d=\"30720\"/><S d=\"31744\"/><S d=\"25736\"/></SegmentTimeline>"
           "</SegmentTemplate></Representation></AdaptationSet></Period></MPD>";
}

// The trackManifests answer that carries it.
QByteArray aacAnswer(const QString &base)
{
    const QString uri = QStringLiteral("data:application/dash+xml;base64,")
                      + QString::fromLatin1(aacManifest(base).toBase64());
    const QJsonObject attributes{
        {"trackPresentation", QStringLiteral("FULL")},
        {"formats", QJsonArray{QStringLiteral("AACLC")}},
        {"albumAudioNormalizationData", QJsonObject{{"replayGain", -9.27}}},
        {"trackAudioNormalizationData", QJsonObject{{"replayGain", -3.1}}},
        {"uri", uri},
    };
    return QJsonDocument(QJsonObject{
        {"data", QJsonObject{{"id", QString::number(kTrack)},
                             {"type", QStringLiteral("trackManifests")},
                             {"attributes", attributes}}},
    }).toJson();
}

// The refusal of a request for FLAC alone, in the shape of Tidal's other
// refusals on this endpoint.
QByteArray noFlacRefusal()
{
    return QJsonDocument(QJsonObject{{"errors", QJsonArray{QJsonObject{
        {"code", QStringLiteral("CLIENT_NOT_ENTITLED")},
        {"detail", QStringLiteral("refused")},
        {"status", QStringLiteral("403")}}}}}).toJson();
}

// Tidal on localhost: the manifest endpoint answers in turn, any other path is
// a file.
class Origin : public QTcpServer {
public:
    Origin()
    {
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
                    answer(sock, target);
                    sock->flush();
                    sock->disconnectFromHost();
                });
            }
        });
    }

    using Answer = std::pair<int, QByteArray>;

    QList<Answer>              manifestAnswers;
    QStringList                manifestQueries;
    QHash<QString, QByteArray> files;
    int                        filesServed = 0;

    QString base() const { return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort()); }

private:
    void answer(QTcpSocket *sock, const QString &target)
    {
        const qsizetype mark = target.indexOf(QLatin1Char('?'));
        const QString path = target.left(mark);
        Answer a{404, QByteArray()};
        if (path.startsWith(QStringLiteral("/trackManifests/"))) {
            manifestQueries << (mark < 0 ? QString() : target.mid(mark + 1));
            a = manifestAnswers.isEmpty() ? Answer{500, "{}"} : manifestAnswers.takeFirst();
        } else if (const auto file = files.constFind(path); file != files.constEnd()) {
            ++filesServed;
            a = {200, *file};
        }
        sock->write("HTTP/1.0 " + QByteArray::number(a.first) + " Answer\r\n"
                    "Content-Length: " + QByteArray::number(a.second.size()) + "\r\n\r\n"
                    + a.second);
    }
};

// The real TidalApi with every request to Tidal sent to the local server.
class LocalApi : public TidalApi {
public:
    QString local;

protected:
    QString baseUrl(const QString &) const override { return local; }
};

// What the Player's QMediaPlayer did, as the test needs to ask about it.
struct Watch {
    explicit Watch(QMediaPlayer *mp)
    {
        QObject::connect(mp, &QMediaPlayer::positionChanged, mp, [this](qint64 pos) {
            if (pos > furthest) furthest = pos;
        });
        QObject::connect(mp, &QMediaPlayer::mediaStatusChanged, mp,
                         [this](QMediaPlayer::MediaStatus s) {
            if (s == QMediaPlayer::EndOfMedia) ended = true;
        });
    }
    // The Player stops at the end of its queue, which resets the position.
    qint64 furthest = 0;
    bool   ended    = false;
};

} // namespace

class TestAacOnly : public QObject {
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_aac_only"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // The backend the app selects on this Qt.
        if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
            qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif

        QVERIFY(m_origin.listen(QHostAddress::LocalHost));
        m_origin.files.insert(QStringLiteral("/audio/0.mp4"),
                              QByteArray::fromBase64(QByteArray(kAacDashInitB64)));
        m_origin.files.insert(QStringLiteral("/audio/1.mp4"),
                              QByteArray::fromBase64(QByteArray(kAacDashSeg1B64)));
        m_origin.files.insert(QStringLiteral("/audio/2.mp4"),
                              QByteArray::fromBase64(QByteArray(kAacDashSeg2B64)));
        m_origin.files.insert(QStringLiteral("/audio/3.mp4"),
                              QByteArray::fromBase64(QByteArray(kAacDashSeg3B64)));
    }

    void theTrackPlaysInAacAndIsShownAsHigh_data()
    {
        QTest::addColumn<int>("quality");
        QTest::addColumn<QString>("firstFormats");
        QTest::newRow("Lossless")
            << int(AudioQuality::Lossless) << QStringLiteral("formats=FLAC&");
        QTest::newRow("Hi-Res")
            << int(AudioQuality::HiResLossless) << QStringLiteral("formats=FLAC&formats=FLAC_HIRES&");
    }

    void theTrackPlaysInAacAndIsShownAsHigh()
    {
        QFETCH(int, quality);
        QFETCH(QString, firstFormats);
        if (const char *why = obstacle()) QSKIP(why);

        m_origin.manifestAnswers = {{403, noFlacRefusal()},
                                    {200, aacAnswer(m_origin.base() + QStringLiteral("audio/"))}};
        m_origin.manifestQueries.clear();
        const int servedBefore = m_origin.filesServed;

        LocalApi api;
        api.local = m_origin.base();
        TidalClient client{&api};
        client.setAudioQuality(AudioQuality(quality));

        Player player{&client};
        player.setMuted(true);
        player.setVolume(0.0);
        // The Player builds its audio objects on the first turn of the loop.
        QTRY_VERIFY_WITH_TIMEOUT(player.findChild<QMediaPlayer *>(), 10000);
        auto *mp = player.findChild<QMediaPlayer *>();
        Watch watch(mp);
        QSignalSpy errorSpy(&player, &Player::error);

        player.playTracks(QVariantList{ oneTrack() }, 0);
        QTRY_VERIFY2_WITH_TIMEOUT(player.duration() > 0 || !errorSpy.isEmpty(),
                                  "the track neither loaded nor failed", 10000);
        QVERIFY2(errorSpy.isEmpty(), qPrintable(errorSpy.value(0).value(0).toString()));

        // Asked twice: as every track is, then with the lossy formats as well.
        QCOMPARE(m_origin.manifestQueries.size(), 2);
        QVERIFY2(m_origin.manifestQueries.at(0).startsWith(firstFormats + QStringLiteral("manifestType=")),
                 qPrintable(m_origin.manifestQueries.at(0)));
        QVERIFY2(m_origin.manifestQueries.at(1).startsWith(
                     QStringLiteral("formats=HEAACV1&formats=AACLC&formats=FLAC&manifestType=")),
                 qPrintable(m_origin.manifestQueries.at(1)));
        // The initialization segment and the three media segments.
        QCOMPARE(m_origin.filesServed - servedBefore, 4);

        // The setting says lossless and the player shows what plays.
        QCOMPARE(player.audioQuality(), QStringLiteral("HIGH"));
        QVERIFY2(qAbs(player.duration() - kAacDashDurationMs) <= kSlackMs,
                 qPrintable(QStringLiteral("the track is %1 ms long").arg(player.duration())));

        QTRY_VERIFY2_WITH_TIMEOUT(mp->position() >= 600 || watch.ended,
                                  "the track did not start playing", 10000);
        QVERIFY2(!watch.ended, "the track ended before it could be sought in");

        // Backwards, so a seek that did nothing is told from one that worked.
        watch.furthest = 0;
        player.seek(200);
        QTRY_VERIFY2_WITH_TIMEOUT(mp->position() < 600 || watch.ended,
                                  "the position never left where it was", 5000);
        QVERIFY2(!watch.ended, "the track ran to its end past the seek");
        QCOMPARE(mp->playbackState(), QMediaPlayer::PlayingState);

        QTRY_VERIFY2_WITH_TIMEOUT(watch.ended, "the track never reached its end", 10000);
        QVERIFY2(watch.furthest >= kAacDashDurationMs - kSlackMs,
                 qPrintable(QStringLiteral("the track ended at %1 ms").arg(watch.furthest)));
        QVERIFY2(errorSpy.isEmpty(), qPrintable(errorSpy.value(0).value(0).toString()));
    }

private:
    // Why this Qt on this machine cannot play a track, or null.
    static const char *obstacle()
    {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // With no audio device one backend crashes in play() and the other
        // runs through the track unpaced.
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to play a track at its own pace";
#endif
        return nullptr;
    }

    QTemporaryDir m_dir;
    Origin        m_origin;
};

QTEST_MAIN(TestAacOnly)
#include "tst_aac_only.moc"
