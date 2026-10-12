// A track Tidal does not stream is played from another id of the same
// recording, found by its ISRC. The test holds each lookup and each stream
// request until it answers it, and the audio is a silent WAV from a localhost
// server. Every Player is muted before its output opens.

#include <QTest>
#include <QByteArray>
#include <QDataStream>
#include <QJsonArray>
#include <QJsonObject>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QNetworkAccessManager>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrlQuery>
#include <QVariantList>
#include <QVariantMap>
#include <initializer_list>
#include <memory>

#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"
#include "player/Player.h"

namespace {

constexpr qint64 kUser = 4242;

// Invented, like every id and title in this file.
const QString kIsrc      = QStringLiteral("XXTW12600017");
const QString kOtherIsrc = QStringLiteral("XXTW12600018");

QVariantMap rowOf(qlonglong id) {
    QVariantMap t;
    t[QStringLiteral("id")]         = id;
    t[QStringLiteral("title")]      = QStringLiteral("T%1").arg(id);
    t[QStringLiteral("artists")]    = QStringLiteral("Artist");
    t[QStringLiteral("albumTitle")] = QStringLiteral("Album");
    t[QStringLiteral("albumId")]    = qlonglong(7);
    t[QStringLiteral("duration")]   = 30;
    return t;
}

QVariantMap withIsrc(QVariantMap row, const QString &isrc = kIsrc) {
    row[QStringLiteral("isrc")] = isrc;
    return row;
}

// The row as a list hands it over when Tidal has flagged the track.
QVariantMap unstreamable(QVariantMap row) {
    row[QStringLiteral("streamable")] = false;
    return row;
}

QVariantList contextOf(qlonglong base, int n) {
    QVariantList out;
    for (int i = 0; i < n; ++i) out.append(rowOf(base + i));
    return out;
}

QList<qlonglong> ids(const QVariantList &rows) {
    QList<qlonglong> out;
    for (const QVariant &v : rows)
        out.append(v.toMap().value(QStringLiteral("id")).toLongLong());
    return out;
}

qlonglong currentId(const Player &p) {
    return p.currentTrackMap().value(QStringLiteral("id")).toLongLong();
}

qlonglong standsFor(const QVariantMap &row) {
    return row.value(QStringLiteral("standsForId")).toLongLong();
}

// One track of a lookup's answer.
struct Listed {
    qlonglong id         = 0;
    QString   album      = QStringLiteral("Album");
    bool      hiRes      = false;
    int       popularity = 10;
    QString   isrc       = kIsrc;
    bool      streams    = true;
};

QString coverOf(qlonglong id) {
    return QStringLiteral("c0ffee00-0000-4000-8000-%1").arg(id, 12, 10, QLatin1Char('0'));
}

qlonglong albumIdOf(qlonglong id) { return id + 500000; }

// A track object the way v1 lists it under `tracks?isrc=`.
QJsonObject listed(const Listed &l) {
    const QJsonObject album{
        {QStringLiteral("id"), albumIdOf(l.id)},
        {QStringLiteral("title"), l.album},
        {QStringLiteral("cover"), coverOf(l.id)},
    };
    const QJsonObject artist{
        {QStringLiteral("id"), 77},
        {QStringLiteral("name"), QStringLiteral("Artist")},
        {QStringLiteral("type"), QStringLiteral("MAIN")},
    };
    QJsonArray tags{QStringLiteral("LOSSLESS")};
    if (l.hiRes) tags.append(QStringLiteral("HIRES_LOSSLESS"));
    return QJsonObject{
        {QStringLiteral("id"), l.id},
        {QStringLiteral("title"), QStringLiteral("T%1").arg(l.id)},
        {QStringLiteral("duration"), 30},
        {QStringLiteral("isrc"), l.isrc},
        {QStringLiteral("allowStreaming"), l.streams},
        {QStringLiteral("streamReady"), l.streams},
        {QStringLiteral("audioQuality"), QStringLiteral("LOSSLESS")},
        {QStringLiteral("popularity"), l.popularity},
        {QStringLiteral("trackNumber"), 3},
        {QStringLiteral("volumeNumber"), 1},
        {QStringLiteral("explicit"), false},
        {QStringLiteral("album"), album},
        {QStringLiteral("artist"), artist},
        {QStringLiteral("artists"), QJsonArray{artist}},
        {QStringLiteral("mediaMetadata"), QJsonObject{{QStringLiteral("tags"), tags}}},
    };
}

QJsonObject answerOf(std::initializer_list<Listed> tracks) {
    QJsonArray items;
    for (const Listed &l : tracks) items.append(listed(l));
    return QJsonObject{
        {QStringLiteral("items"), items},
        {QStringLiteral("limit"), 10},
        {QStringLiteral("offset"), 0},
        {QStringLiteral("totalNumberOfItems"), int(items.size())},
    };
}

// Half a minute of silence, long enough that no test reaches its end.
QByteArray silentWav() {
    const quint32 rate = 8000, channels = 1, bits = 16;
    const quint32 bytes = rate * 30 * channels * bits / 8;

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
    s.writeRawData(QByteArray(bytes, '\0').constData(), int(bytes));
    return d;
}

// A localhost origin for the audio: /track is the WAV, nothing else is there.
class MediaServer : public QTcpServer {
public:
    explicit MediaServer(QObject *parent = nullptr) : QTcpServer(parent)
    {
        connect(this, &QTcpServer::newConnection, this, &MediaServer::accept);
    }

    QByteArray track;

    QString url(const QString &path) const
    {
        return QStringLiteral("http://127.0.0.1:%1%2").arg(serverPort()).arg(path);
    }

private:
    void accept()
    {
        while (QTcpSocket *sock = nextPendingConnection()) {
            auto buf = std::make_shared<QByteArray>();
            connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                buf->append(sock->readAll());
                if (buf->indexOf("\r\n\r\n") < 0) return;
                const QByteArray path = buf->mid(4, buf->indexOf(' ', 4) - 4);
                buf->clear();
                const bool found = path == "/track";
                const QByteArray body = found ? track : QByteArray();
                sock->write(found ? "HTTP/1.0 200 OK\r\n" : "HTTP/1.0 404 Not Found\r\n");
                sock->write("Content-Type: audio/wav\r\nContent-Length: "
                            + QByteArray::number(body.size()) + "\r\n\r\n");
                sock->write(body);
                sock->flush();
                sock->disconnectFromHost();
            });
            connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
        }
    }
};

// Holds each lookup by ISRC until the test answers it. No other request of
// the v1 API is expected, and none is sent on.
class HeldApi : public TidalApi {
public:
    using TidalApi::TidalApi;

    QStringList lookups;      // the ISRCs asked for, in order
    QStringList unexpected;   // any other request

    void get(const QString &endpoint, const QUrlQuery &params, JsonCallback cb) override
    {
        const QString isrc = params.queryItemValue(QStringLiteral("isrc"));
        if (endpoint != QLatin1String("tracks") || isrc.isEmpty()
            || params.queryItems().count() != 1) {
            unexpected.append(endpoint + QLatin1Char('?') + params.toString());
            return;
        }
        lookups.append(isrc);
        m_held.append({ isrc, std::move(cb) });
    }

    // Answers the oldest lookup still out for this ISRC.
    bool answer(const QString &isrc, const QJsonObject &body, const QString &err = QString())
    {
        for (int i = 0; i < m_held.count(); ++i) {
            if (m_held.at(i).first != isrc) continue;
            const JsonCallback cb = m_held.takeAt(i).second;
            cb(body, err);
            return true;
        }
        return false;
    }

    int waiting() const { return int(m_held.count()); }

private:
    QList<std::pair<QString, JsonCallback>> m_held;
};

// Holds each stream request until the test answers it, as a slow Tidal does.
class HeldClient : public TidalClient {
public:
    using TidalClient::TidalClient;

    QList<qlonglong> asked;

    void fetchStreamManifest(qint64 trackId, StreamCb cb) override
    {
        asked.append(trackId);
        m_held.append({ trackId, std::move(cb) });
    }

    // Answers the oldest request still out for this track.
    bool answer(qlonglong trackId, const StreamManifest &manifest,
                const QString &err = QString())
    {
        for (int i = 0; i < m_held.count(); ++i) {
            if (m_held.at(i).first != trackId) continue;
            const StreamCb cb = m_held.takeAt(i).second;
            cb(manifest, err);
            return true;
        }
        return false;
    }

    int waiting() const { return int(m_held.count()); }

private:
    QList<std::pair<qlonglong, StreamCb>> m_held;
};

StreamManifest oneFileAt(const QString &url) {
    StreamManifest m;
    m.type     = StreamManifest::BTS;
    m.url      = url;
    m.mimeType = QStringLiteral("audio/mp4");
    m.codec    = QStringLiteral("HIGH");
    return m;
}

StreamManifest refusedAs(StreamManifest::Reason reason) {
    StreamManifest m;
    m.reason = reason;
    return m;
}

// Qt's text for a transfer the server turned down.
const QString kRefused = QStringLiteral(
    "Error transferring https://api.example.invalid/v1/tracks/1 - server replied: Not Found");

const QString kGoneSaid = QStringLiteral("This track is no longer available on Tidal.");
const QString kNotForAccountSaid =
    QStringLiteral("This track is not available for your account or region.");

QString saidFor(StreamManifest::Reason reason) {
    return reason == StreamManifest::Gone ? kGoneSaid : kNotForAccountSaid;
}

QString skipped(qlonglong id) {
    return QStringLiteral("“T%1” is no longer available on Tidal and was skipped.").arg(id);
}

// One launch of the app. With the account set first, the Player restores
// from its constructor as it does at startup.
struct Launch {
    HeldApi                 api;
    HeldClient              client{&api};
    std::unique_ptr<Player> player;

    Launch() {
        client.setUserId(kUser);
        player = std::make_unique<Player>(&client);
        player->setMuted(true);
        player->setVolume(0.0);
    }
    Player &p() { return *player; }
    QMediaPlayer *mp() { return player->findChild<QMediaPlayer *>(); }
    QNetworkAccessManager *network() { return api.findChild<QNetworkAccessManager *>(); }
    // The Player builds its audio objects on the first turn of the loop.
    bool audioUp() {
        return QTest::qWaitFor([this] { return mp() != nullptr; }, 10000);
    }
    bool started() { return mp()->playbackState() == QMediaPlayer::PlayingState; }
};

} // namespace

Q_DECLARE_METATYPE(StreamManifest::Reason)

class TestTrackTwins : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("TidalWaveTest"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_track_twins"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        // The backend the app selects on this Qt.
        if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND"))
            qputenv("QT_MEDIA_BACKEND", QByteArrayLiteral("ffmpeg"));
#endif

        m_server.track = silentWav();
        QVERIFY(m_server.listen(QHostAddress::LocalHost));
    }

    void init() {
        QSettings().clear();
    }

    // ── what a track says about itself ──────────────────────────────────────

    // Many answers carry neither flag, and those tracks are streamed.
    void theBridgesMapCarriesTheIsrcAndWhetherTheTrackIsStreamed_data() {
        QTest::addColumn<QJsonObject>("extra");
        QTest::addColumn<QString>("isrc");
        QTest::addColumn<bool>("streamable");

        QTest::newRow("a row Tidal flags")
            << QJsonObject{{QStringLiteral("isrc"), kIsrc},
                           {QStringLiteral("allowStreaming"), false},
                           {QStringLiteral("streamReady"), false},
                           {QStringLiteral("streamStartDate"), QJsonValue()}}
            << kIsrc << false;
        QTest::newRow("a row Tidal streams")
            << QJsonObject{{QStringLiteral("isrc"), kIsrc},
                           {QStringLiteral("allowStreaming"), true},
                           {QStringLiteral("streamReady"), true}}
            << kIsrc << true;
        QTest::newRow("an answer with neither key") << QJsonObject{} << QString() << true;
        QTest::newRow("not allowed alone")
            << QJsonObject{{QStringLiteral("allowStreaming"), false}} << QString() << false;
        QTest::newRow("not ready alone")
            << QJsonObject{{QStringLiteral("streamReady"), false}} << QString() << false;
    }

    void theBridgesMapCarriesTheIsrcAndWhetherTheTrackIsStreamed() {
        QFETCH(QJsonObject, extra);
        QFETCH(QString, isrc);
        QFETCH(bool, streamable);
        QJsonObject json{{QStringLiteral("id"), 8001}, {QStringLiteral("title"), QStringLiteral("T8001")}};
        for (auto it = extra.constBegin(); it != extra.constEnd(); ++it)
            json.insert(it.key(), it.value());

        const QVariantMap map = TidalBridge::trackToMap(Track::fromJson(json));

        QVERIFY2(map.contains(QStringLiteral("isrc")), "the map has no key for the ISRC");
        QCOMPARE(map.value(QStringLiteral("isrc")).toString(), isrc);
        QVERIFY2(map.contains(QStringLiteral("streamable")),
                 "the map has no key for whether the track is streamed");
        QCOMPARE(map.value(QStringLiteral("streamable")).toBool(), streamable);
    }

    // ── the lookup ──────────────────────────────────────────────────────────

    void theLookupAsksForTheTracksOfOneIsrc() {
        HeldApi    api;
        HeldClient client{&api};
        const Track of = Track::fromJson(listed({8001}));
        int     answers = 0;
        Track   twin;
        QString failure;
        const auto keep = [&](Track t, QString err) { ++answers; twin = t; failure = err; };

        client.fetchTwin(of, keep);
        QCOMPARE(api.lookups, QStringList{kIsrc});
        QVERIFY2(api.unexpected.isEmpty(), qPrintable(api.unexpected.join(QLatin1Char(' '))));
        QVERIFY(api.answer(kIsrc, answerOf({{8001}, {9001}})));
        QCOMPARE(answers, 1);
        QCOMPARE(twin.id, 9001);
        QCOMPARE(failure, QString());

        // A failed request hands on its error and no track.
        client.fetchTwin(of, keep);
        QVERIFY(api.answer(kIsrc, QJsonObject(), kRefused));
        QCOMPARE(answers, 2);
        QCOMPARE(twin.id, 0);
        QCOMPARE(failure, kRefused);

        // Without an ISRC there is nothing to ask for.
        client.fetchTwin(Track::fromJson(listed({8001, {}, false, 10, QString()})), keep);
        QCOMPARE(answers, 3);
        QCOMPARE(twin.id, 0);
        QCOMPARE(api.lookups.count(), 2);
        QVERIFY2(api.unexpected.isEmpty(), qPrintable(api.unexpected.join(QLatin1Char(' '))));
    }

    // The album of the same title first, then hi-res, then the more popular
    // one, then the lower id. The row's own id is no twin of itself.
    void ofSeveralTwinsOneIsChosen_data() {
        QTest::addColumn<QJsonObject>("answer");
        QTest::addColumn<qlonglong>("chosen");

        QTest::newRow("nothing listed") << answerOf({}) << 0LL;
        QTest::newRow("only the track itself") << answerOf({{8001}}) << 0LL;
        QTest::newRow("one twin beside the track itself") << answerOf({{8001}, {9001}}) << 9001LL;
        QTest::newRow("the album of the same title, before hi-res")
            << answerOf({{9001, QStringLiteral("Anderes Album"), true, 90},
                         {9002, QStringLiteral("Album"), false, 5}})
            << 9002LL;
        QTest::newRow("hi-res, before the popularity")
            << answerOf({{9001, QStringLiteral("Anderes Album"), false, 90},
                         {9002, QStringLiteral("Drittes Album"), true, 5}})
            << 9002LL;
        QTest::newRow("the more popular one, before the lower id")
            << answerOf({{9001, QStringLiteral("Anderes Album"), true, 5},
                         {9002, QStringLiteral("Drittes Album"), true, 90}})
            << 9002LL;
        QTest::newRow("the lower id, listed last")
            << answerOf({{9003}, {9002}, {9001}}) << 9001LL;
        QTest::newRow("no track Tidal marks as not streamed")
            << answerOf({{9001, QStringLiteral("Album"), true, 90, kIsrc, false}, {9002}})
            << 9002LL;
        QTest::newRow("no track of another ISRC")
            << answerOf({{9001, QStringLiteral("Album"), true, 90, kOtherIsrc}, {9002}})
            << 9002LL;
    }

    void ofSeveralTwinsOneIsChosen() {
        QFETCH(QJsonObject, answer);
        QFETCH(qlonglong, chosen);
        const Track of = Track::fromJson(listed({8001}));

        QCOMPARE(TidalClient::pickTwin(answer, of).id, chosen);
    }

    // ── a row the user picks ────────────────────────────────────────────────

    // Tidal flags the row, so its twin is looked for before anything is asked
    // of the row itself. The queue row becomes the twin and nothing is said.
    void aFlaggedRowThatIsPickedIsPlayedFromItsTwin() {
        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = unstreamable(withIsrc(rowOf(8001)));
        a.p().playTracks(rows, 1);

        QCOMPARE(a.api.lookups, QStringList{kIsrc});
        QVERIFY2(a.client.asked.isEmpty(), "the flagged row was asked for before its twin was");
        QVERIFY(a.p().loading());
        QSignalSpy queueSpy(&a.p(), &Player::queueChanged);
        QSignalSpy trackSpy(&a.p(), &Player::currentTrackChanged);

        QVERIFY(a.api.answer(kIsrc, answerOf({{9002, QStringLiteral("Drittes Album")},
                                              {9001, QStringLiteral("Anderes Album"), true}})));

        QCOMPARE(a.client.asked, (QList<qlonglong>{9001}));
        QCOMPARE(errorSpy.count(), 0);
        QCOMPARE(a.p().loadError(), QString());
        QVERIFY(a.p().loading());

        const QVariantMap now = a.p().currentTrackMap();
        QCOMPARE(now.value(QStringLiteral("id")).toLongLong(), 9001);
        QCOMPARE(standsFor(now), 8001);
        QCOMPARE(now.value(QStringLiteral("title")).toString(), QStringLiteral("T9001"));
        QCOMPARE(now.value(QStringLiteral("albumTitle")).toString(), QStringLiteral("Anderes Album"));
        QCOMPARE(now.value(QStringLiteral("albumId")).toLongLong(), albumIdOf(9001));
        QCOMPARE(now.value(QStringLiteral("albumCover")).toString(), coverOf(9001));
        QVERIFY(now.value(QStringLiteral("coverUrl")).toString().contains(QStringLiteral("c0ffee00")));
        QCOMPARE(now.value(QStringLiteral("isrc")).toString(), kIsrc);
        QCOMPARE(now.value(QStringLiteral("streamable")).toBool(), true);

        // What MPRIS and the cast read.
        QCOMPARE(a.p().currentTrackId(), 9001);
        QCOMPARE(a.p().currentTrack().album.id, albumIdOf(9001));

        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 9001, 8002}));
        QCOMPARE(ids(a.p().recentlyPlayed()), (QList<qlonglong>{9001}));
        QVERIFY2(queueSpy.count() >= 1, "the views of the queue were not told that a row changed");
        QVERIFY2(trackSpy.count() >= 1, "the views of the track were not told that it changed");
        QVERIFY2(a.api.unexpected.isEmpty(), qPrintable(a.api.unexpected.join(QLatin1Char(' '))));

        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(a.client.answer(9001, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the twin never played", 10000);
        QCOMPARE(currentId(a.p()), 9001);
        QCOMPARE(a.api.lookups.count(), 1);
        QCOMPARE(errorSpy.count(), 0);
    }

    // No twin, or no answer about one: the row is asked for itself and
    // reported the way it is without a lookup. Play asks again, lookup and all.
    void aFlaggedRowWithNoTwinIsReportedAsBefore_data() {
        QTest::addColumn<QJsonObject>("answer");
        QTest::addColumn<QString>("failure");
        QTest::newRow("nothing listed") << answerOf({}) << QString();
        QTest::newRow("only the track itself") << answerOf({{8001}}) << QString();
        QTest::newRow("the lookup failed") << QJsonObject() << kRefused;
    }

    void aFlaggedRowWithNoTwinIsReportedAsBefore() {
        QFETCH(QJsonObject, answer);
        QFETCH(QString, failure);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = unstreamable(withIsrc(rowOf(8001)));
        a.p().playTracks(rows, 1);
        QCOMPARE(a.api.lookups, QStringList{kIsrc});

        QVERIFY(a.api.answer(kIsrc, answer, failure));

        QCOMPARE(a.client.asked, (QList<qlonglong>{8001}));
        QCOMPARE(errorSpy.count(), 0);
        QVERIFY(a.p().loading());
        QVERIFY(a.client.answer(8001, refusedAs(StreamManifest::Gone), kRefused));

        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), kGoneSaid);
        QCOMPARE(a.api.lookups.count(), 1);
        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 8001, 8002}));
        QCOMPARE(a.p().currentTrackMap(), rows.at(1).toMap());
        QVERIFY(!a.p().loading());

        a.p().playPause();
        QCOMPARE(a.api.lookups.count(), 2);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001}));
    }

    // An unflagged row is asked for first. Refused, its twin is looked for,
    // and nothing is said while that is out or once the twin is found.
    void aRefusedRowIsPlayedFromItsTwin_data() {
        QTest::addColumn<StreamManifest::Reason>("reason");
        QTest::newRow("Tidal no longer has it")     << StreamManifest::Gone;
        QTest::newRow("not for this account")       << StreamManifest::NotForAccount;
    }

    void aRefusedRowIsPlayedFromItsTwin() {
        QFETCH(StreamManifest::Reason, reason);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = withIsrc(rowOf(8001));
        a.p().playTracks(rows, 1);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001}));
        QVERIFY2(a.api.lookups.isEmpty(), "a row was looked up before anything refused it");

        QVERIFY(a.client.answer(8001, refusedAs(reason), kRefused));

        QCOMPARE(a.api.lookups, QStringList{kIsrc});
        QCOMPARE(errorSpy.count(), 0);
        QVERIFY(a.p().loading());
        QCOMPARE(currentId(a.p()), 8001);

        QVERIFY(a.api.answer(kIsrc, answerOf({{8001}, {9001}})));

        QCOMPARE(a.client.asked, (QList<qlonglong>{8001, 9001}));
        QCOMPARE(currentId(a.p()), 9001);
        QCOMPARE(standsFor(a.p().currentTrackMap()), 8001);
        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 9001, 8002}));
        QCOMPARE(errorSpy.count(), 0);

        if (const char *why = obstacle()) QSKIP(why);
        QVERIFY(a.client.answer(9001, oneFileAt(m_server.url(QStringLiteral("/track")))));
        QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the twin never played", 10000);
        QCOMPARE(errorSpy.count(), 0);
        QCOMPARE(a.api.lookups.count(), 1);
    }

    void aRefusedRowWithNoTwinIsReportedAsBefore_data() {
        QTest::addColumn<StreamManifest::Reason>("reason");
        QTest::addColumn<QJsonObject>("answer");
        QTest::addColumn<QString>("failure");
        QTest::newRow("Tidal no longer has it, nothing listed")
            << StreamManifest::Gone << answerOf({}) << QString();
        QTest::newRow("not for this account, only the track itself")
            << StreamManifest::NotForAccount << answerOf({{8001}}) << QString();
        QTest::newRow("Tidal no longer has it, the lookup failed")
            << StreamManifest::Gone << QJsonObject() << kRefused;
    }

    void aRefusedRowWithNoTwinIsReportedAsBefore() {
        QFETCH(StreamManifest::Reason, reason);
        QFETCH(QJsonObject, answer);
        QFETCH(QString, failure);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = withIsrc(rowOf(8001));
        a.p().playTracks(rows, 1);
        QVERIFY(a.client.answer(8001, refusedAs(reason), kRefused));
        QCOMPARE(a.api.lookups, QStringList{kIsrc});

        QVERIFY(a.api.answer(kIsrc, answer, failure));

        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), saidFor(reason));
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001}));
        QCOMPARE(a.p().currentTrackMap(), rows.at(1).toMap());
        QCOMPARE(a.p().queueCount(), 3);
        QVERIFY(!a.p().loading());

        a.p().playPause();
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001, 8001}));
    }

    // The twin is refused as well. That is said about the twin, and nothing
    // is looked for a second time.
    void aTwinThatIsRefusedIsNotLookedUpAgain() {
        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = withIsrc(rowOf(8001));
        a.p().playTracks(rows, 1);
        QVERIFY(a.client.answer(8001, refusedAs(StreamManifest::Gone), kRefused));
        QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001, 9001}));

        QVERIFY(a.client.answer(9001, refusedAs(StreamManifest::NotForAccount), kRefused));

        QCOMPARE(a.api.lookups.count(), 1);
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), kNotForAccountSaid);
        QCOMPARE(currentId(a.p()), 9001);
        QVERIFY(!a.p().loading());
    }

    // Without an ISRC there is nothing to look a twin up by.
    void aRowWithNoIsrcIsNotLookedUp_data() {
        QTest::addColumn<bool>("flagged");
        QTest::newRow("a flagged row")   << true;
        QTest::newRow("an unflagged row") << false;
    }

    void aRowWithNoIsrcIsNotLookedUp() {
        QFETCH(bool, flagged);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        if (flagged) rows[1] = unstreamable(rowOf(8001));
        a.p().playTracks(rows, 1);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001}));

        QVERIFY(a.client.answer(8001, refusedAs(StreamManifest::Gone), kRefused));

        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), kGoneSaid);
        QVERIFY2(a.api.lookups.isEmpty(), "a row with no ISRC was looked up");
        QVERIFY2(a.api.unexpected.isEmpty(), qPrintable(a.api.unexpected.join(QLatin1Char(' '))));
    }

    // A request that failed says nothing about the track, and a row whose
    // list said nothing about streaming is streamed.
    void onlyARefusalOrAFlagSendsALookup() {
        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = withIsrc(rowOf(8001));
        a.p().playTracks(rows, 1);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001}));
        QVERIFY2(a.api.lookups.isEmpty(), "a row with no flag was taken for a flagged one");

        QVERIFY(a.client.answer(8001, StreamManifest{}, kRefused));

        QVERIFY2(a.api.lookups.isEmpty(), "a failed request was taken for a refusal");
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(),
                 QStringLiteral("Could not load this track for playback."));
    }

    // ── a queue on its way ──────────────────────────────────────────────────

    // The queue comes onto a flagged row by a step or by itself. The twin
    // plays in its place, every row is still there and nothing is said.
    void aQueueOnItsWayPlaysTheTwin_data() {
        QTest::addColumn<QString>("move");
        QTest::addColumn<qlonglong>("from");
        QTest::newRow("Next")              << QStringLiteral("next")     << 8001LL;
        QTest::newRow("Previous")          << QStringLiteral("previous") << 8003LL;
        QTest::newRow("the track ran out") << QStringLiteral("end")      << 8001LL;
    }

    void aQueueOnItsWayPlaysTheTwin() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(QString, move);
        QFETCH(qlonglong, from);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QSignalSpy fetched(a.network(), &QNetworkAccessManager::finished);
        QVariantList rows = contextOf(8000, 5);
        rows[2] = unstreamable(withIsrc(rowOf(8002)));
        a.p().playTracks(rows, int(from - 8000));
        QVERIFY(a.client.answer(from, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        if (move == QLatin1String("end")) {
            // The row ahead is looked up and fetched while this one plays.
            a.p().seek(6000);
            QTRY_COMPARE_WITH_TIMEOUT(a.api.lookups, QStringList{kIsrc}, 5000);
            QCOMPARE(a.client.asked, (QList<qlonglong>{from}));
            QVERIFY(a.api.answer(kIsrc, answerOf({{9002}})));
            QCOMPARE(a.client.asked, (QList<qlonglong>{from, 9002}));
            QCOMPARE(currentId(a.p()), from);
            QVERIFY(a.client.answer(9002, track));
            QTRY_COMPARE_WITH_TIMEOUT(fetched.count(), 2, 10000);
            a.p().seek(29000);
            QTRY_COMPARE_WITH_TIMEOUT(currentId(a.p()), 9002, 10000);
        } else {
            if (move == QLatin1String("next")) a.p().next();
            else                               a.p().previous();
            QCOMPARE(a.api.lookups, QStringList{kIsrc});
            QCOMPARE(a.client.asked, (QList<qlonglong>{from}));
            QVERIFY(a.api.answer(kIsrc, answerOf({{9002}})));
            QCOMPARE(a.client.asked, (QList<qlonglong>{from, 9002}));
            QVERIFY(a.client.answer(9002, track));
        }

        QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the twin never played", 10000);
        QCOMPARE(currentId(a.p()), 9002);
        QCOMPARE(standsFor(a.p().currentTrackMap()), 8002);
        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 8001, 9002, 8003, 8004}));
        QCOMPARE(a.client.asked, (QList<qlonglong>{from, 9002}));
        QCOMPARE(a.api.lookups.count(), 1);
        QCOMPARE(errorSpy.count(), 0);
        QCOMPARE(a.p().loadError(), QString());
    }

    // A step onto a row with no twin passes over it the way it does without a
    // lookup: the row Tidal no longer has is dropped and named once.
    void aQueueOnItsWayPassesOverARowWithNoTwin() {
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 5);
        rows[2] = withIsrc(rowOf(8002));
        a.p().playTracks(rows, 1);
        QVERIFY(a.client.answer(8001, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);

        a.p().next();
        QVERIFY(a.client.answer(8002, refusedAs(StreamManifest::Gone), kRefused));
        QCOMPARE(a.api.lookups, QStringList{kIsrc});
        QCOMPARE(currentId(a.p()), 8002);
        QCOMPARE(errorSpy.count(), 0);
        QVERIFY(a.api.answer(kIsrc, answerOf({})));

        QCOMPARE(currentId(a.p()), 8003);
        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 8001, 8003, 8004}));
        QCOMPARE(a.client.asked, (QList<qlonglong>{8001, 8002, 8003}));
        QCOMPARE(errorSpy.count(), 1);
        QCOMPARE(errorSpy.at(0).at(0).toString(), skipped(8002));
    }

    // ── the row ahead ───────────────────────────────────────────────────────

    // Refused while it is still the row ahead, a row with a twin keeps its
    // place. The twin is fetched ahead and handed over without a second request.
    void aRowAheadThatIsRefusedIsFetchedAheadFromItsTwin_data() {
        QTest::addColumn<StreamManifest::Reason>("reason");
        QTest::newRow("Tidal no longer has it") << StreamManifest::Gone;
        QTest::newRow("not for this account")   << StreamManifest::NotForAccount;
    }

    void aRowAheadThatIsRefusedIsFetchedAheadFromItsTwin() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(StreamManifest::Reason, reason);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QSignalSpy fetched(a.network(), &QNetworkAccessManager::finished);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = withIsrc(rowOf(8001));
        a.p().playTracks(rows, 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{8000, 8001}), 5000);

        QVERIFY(a.client.answer(8001, refusedAs(reason), kRefused));

        QCOMPARE(a.api.lookups, QStringList{kIsrc});
        QCOMPARE(a.p().queueCount(), 3);
        QCOMPARE(a.p().loadError(), QString());
        QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001, 9001}));
        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 9001, 8002}));
        QCOMPARE(standsFor(a.p().queueTrackAt(1)), 8001);
        QCOMPARE(currentId(a.p()), 8000);
        QVERIFY(a.p().playing());

        QVERIFY(a.client.answer(9001, track));
        QTRY_COMPARE_WITH_TIMEOUT(fetched.count(), 2, 10000);
        a.p().seek(29000);
        QTRY_COMPARE_WITH_TIMEOUT(currentId(a.p()), 9001, 10000);
        QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the twin fetched ahead never played", 10000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001, 9001}));
        QCOMPARE(a.api.lookups.count(), 1);
        QCOMPARE(errorSpy.count(), 0);
    }

    // With no twin the row ahead is treated as it is without a lookup: one
    // Tidal no longer has is dropped and named, the other kind is kept.
    void aRowAheadWithNoTwinIsTreatedAsBefore_data() {
        QTest::addColumn<StreamManifest::Reason>("reason");
        QTest::addColumn<int>("rowsLeft");
        QTest::addColumn<QString>("said");
        QTest::newRow("Tidal no longer has it") << StreamManifest::Gone << 2 << skipped(8001);
        QTest::newRow("not for this account")   << StreamManifest::NotForAccount << 3 << QString();
    }

    void aRowAheadWithNoTwinIsTreatedAsBefore() {
        if (const char *why = obstacle()) QSKIP(why);
        QFETCH(StreamManifest::Reason, reason);
        QFETCH(int, rowsLeft);
        QFETCH(QString, said);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QVariantList rows = contextOf(8000, 3);
        rows[1] = withIsrc(rowOf(8001));
        a.p().playTracks(rows, 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.client.asked, (QList<qlonglong>{8000, 8001}), 5000);
        QVERIFY(a.client.answer(8001, refusedAs(reason), kRefused));
        QCOMPARE(a.api.lookups, QStringList{kIsrc});
        QCOMPARE(a.p().queueCount(), 3);

        QVERIFY(a.api.answer(kIsrc, answerOf({})));

        QCOMPARE(a.p().queueCount(), rowsLeft);
        QCOMPARE(a.p().loadError(), said);
        QCOMPARE(currentId(a.p()), 8000);
        QVERIFY(a.p().playing());
    }

    // A row ahead that Tidal lists as not streamed has its twin looked up
    // ahead. The stream of the id it came with is never asked for.
    void aFlaggedRowAheadIsFetchedAheadFromItsTwin() {
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QSignalSpy fetched(a.network(), &QNetworkAccessManager::finished);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = unstreamable(withIsrc(rowOf(8001)));
        a.p().playTracks(rows, 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.api.lookups, QStringList{kIsrc}, 5000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000}));

        QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 9001}));
        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 9001, 8002}));
        QCOMPARE(standsFor(a.p().queueTrackAt(1)), 8001);
        QCOMPARE(currentId(a.p()), 8000);
        QVERIFY(a.p().playing());

        QVERIFY(a.client.answer(9001, track));
        QTRY_COMPARE_WITH_TIMEOUT(fetched.count(), 2, 10000);
        a.p().seek(29000);
        QTRY_COMPARE_WITH_TIMEOUT(currentId(a.p()), 9001, 10000);
        QTRY_VERIFY2_WITH_TIMEOUT(a.started(), "the twin fetched ahead never played", 10000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 9001}));
        QCOMPARE(a.api.lookups.count(), 1);
        QCOMPARE(errorSpy.count(), 0);
    }

    // The same row with no twin is asked for as itself, and its refusal is
    // taken as it stands: this fetch ahead has looked once.
    void aFlaggedRowAheadWithNoTwinIsAskedForAsItself() {
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QVariantList rows = contextOf(8000, 3);
        rows[1] = unstreamable(withIsrc(rowOf(8001)));
        a.p().playTracks(rows, 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.api.lookups, QStringList{kIsrc}, 5000);
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000}));

        QVERIFY(a.api.answer(kIsrc, answerOf({})));
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 8001}));
        QCOMPARE(a.p().queueCount(), 3);

        QVERIFY(a.client.answer(8001, refusedAs(StreamManifest::Gone), kRefused));
        QVERIFY2(a.api.lookups.count() == 1, "the row ahead was looked up a second time");
        QCOMPARE(a.p().queueCount(), 2);
        QCOMPARE(a.p().loadError(), skipped(8001));
        QCOMPARE(currentId(a.p()), 8000);
        QVERIFY(a.p().playing());
    }

    // ── answers nobody is waiting for ───────────────────────────────────────

    // The lookup answers after the user picked another track. The row it was
    // for stays as it is and nothing is asked for the twin.
    void aLookupAnsweredAfterAnotherPickChangesNothing_data() {
        QTest::addColumn<bool>("flagged");
        QTest::newRow("looked up before the request") << true;
        QTest::newRow("looked up after the refusal")  << false;
    }

    void aLookupAnsweredAfterAnotherPickChangesNothing() {
        QFETCH(bool, flagged);

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = flagged ? unstreamable(withIsrc(rowOf(8001))) : withIsrc(rowOf(8001));
        a.p().playTracks(rows, 1);
        if (!flagged) QVERIFY(a.client.answer(8001, refusedAs(StreamManifest::Gone), kRefused));
        QCOMPARE(a.api.lookups, QStringList{kIsrc});
        const QList<qlonglong> askedSoFar = a.client.asked;

        a.p().jumpToQueue(2);
        QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));

        QCOMPARE(currentId(a.p()), 8002);
        QCOMPARE(a.client.asked, askedSoFar + QList<qlonglong>{8002});
        QCOMPARE(a.p().queueTracks(), rows);
        QCOMPARE(errorSpy.count(), 0);
        QVERIFY(a.p().loading());
    }

    // Two clicks on one row are two loads of it. The answer to the first
    // lookup belongs to a load that was replaced.
    void aRowPickedTwiceTakesTheSecondLookupsAnswer() {
        Launch a;
        QVERIFY(a.audioUp());
        QVariantList rows = contextOf(8000, 3);
        rows[1] = unstreamable(withIsrc(rowOf(8001)));
        a.p().playTracks(rows, 1);
        a.p().playTracks(rows, 1);
        QCOMPARE(a.api.lookups, (QStringList{kIsrc, kIsrc}));

        QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));
        QVERIFY2(a.client.asked.isEmpty(), "the answer to a replaced load was acted on");
        QCOMPARE(currentId(a.p()), 8001);

        QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));
        QCOMPARE(a.client.asked, (QList<qlonglong>{9001}));
        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 9001, 8002}));
    }

    // The row ahead is being looked up when the user steps onto it. The step
    // is a load of its own, and the lookup made ahead is no longer waited for.
    void aLookupMadeAheadIsLeftBehindByAStep() {
        if (const char *why = obstacle()) QSKIP(why);
        const StreamManifest track = oneFileAt(m_server.url(QStringLiteral("/track")));

        Launch a;
        QVERIFY(a.audioUp());
        QSignalSpy errorSpy(&a.p(), &Player::error);
        QVariantList rows = contextOf(8000, 3);
        rows[1] = unstreamable(withIsrc(rowOf(8001)));
        a.p().playTracks(rows, 0);
        QVERIFY(a.client.answer(8000, track));
        QTRY_VERIFY_WITH_TIMEOUT(a.started(), 10000);
        a.p().seek(6000);
        QTRY_COMPARE_WITH_TIMEOUT(a.api.lookups, QStringList{kIsrc}, 5000);

        a.p().next();
        QCOMPARE(a.api.lookups, (QStringList{kIsrc, kIsrc}));
        QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));
        QVERIFY2(a.client.asked == (QList<qlonglong>{8000}),
                 "the lookup made ahead was acted on after the step");
        QCOMPARE(currentId(a.p()), 8001);

        QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));
        QCOMPARE(a.client.asked, (QList<qlonglong>{8000, 9001}));
        QCOMPARE(currentId(a.p()), 9001);
        QCOMPARE(ids(a.p().queueTracks()), (QList<qlonglong>{8000, 9001, 8002}));
        QCOMPARE(errorSpy.count(), 0);
    }

    // ── a saved session ─────────────────────────────────────────────────────

    // The row comes back as the twin with the id it stands for, and is asked
    // for as itself. A flagged row behind it kept its flag and its ISRC.
    void theRowsComeBackFromASavedSession() {
        QVariantList rows = contextOf(8000, 3);
        rows[1] = unstreamable(withIsrc(rowOf(8001)));
        rows[2] = unstreamable(withIsrc(rowOf(8002), kOtherIsrc));
        QVariantMap twinRow;
        {
            Launch a;
            QVERIFY(a.audioUp());
            a.p().playTracks(rows, 1);
            QVERIFY(a.api.answer(kIsrc, answerOf({{9001}})));
            twinRow = a.p().currentTrackMap();
            QCOMPARE(standsFor(twinRow), 8001);
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.audioUp());
        QCOMPARE(b.p().currentTrackMap(), twinRow);
        QCOMPARE(b.p().queueTrackAt(2), rows.at(2).toMap());
        QCOMPARE(b.client.asked, (QList<qlonglong>{9001}));
        QVERIFY2(b.api.lookups.isEmpty(), "the twin that came back was looked up again");

        b.p().next();
        QCOMPARE(b.api.lookups, QStringList{kOtherIsrc});
        QCOMPARE(b.client.asked, (QList<qlonglong>{9001}));
    }

    // A session saved before rows had these keys: every row is streamed as
    // far as the program knows, and none has an ISRC to look up.
    void aSessionSavedWithoutTheKeysLoads() {
        {
            Launch a;
            QVERIFY(a.audioUp());
            a.p().playTracks(contextOf(1000, 5), 2);
            a.p().savePlaybackState();
        }

        Launch b;
        QVERIFY(b.audioUp());
        QCOMPARE(currentId(b.p()), 1002);
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002}));
        QVERIFY(b.p().currentTrack().streamable);
        QCOMPARE(b.p().currentTrack().isrc, QString());

        // Ruled out, the restored row is dropped in silence as it always was.
        QVERIFY(b.client.answer(1002, refusedAs(StreamManifest::Gone), kRefused));
        QCOMPARE(b.client.asked, (QList<qlonglong>{1002, 1003}));
        QCOMPARE(b.p().queueCount(), 4);
        QVERIFY2(b.api.lookups.isEmpty(), "a row with no ISRC was looked up");
        QVERIFY2(b.api.unexpected.isEmpty(), qPrintable(b.api.unexpected.join(QLatin1Char(' '))));
    }

private:
    // Why this Qt on this machine cannot run the cases that load audio, or null.
    static const char *obstacle()
    {
#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
        if (QMediaDevices::audioOutputs().isEmpty())
            return "Qt 6.4 needs an audio device to load a track";
#endif
        return nullptr;
    }

    QTemporaryDir m_dir;
    MediaServer   m_server;
};

QTEST_MAIN(TestTrackTwins)
#include "tst_track_twins.moc"
