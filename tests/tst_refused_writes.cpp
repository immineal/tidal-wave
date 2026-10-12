// A like, a playlist edit or a save that the server refuses: what TidalApi
// hands on and what TidalBridge then shows. The server is on loopback, the
// home directory and the settings are scratch ones.

#include <QTest>
#include <QCoreApplication>
#include <QDir>
#include <QHash>
#include <QHostAddress>
#include <QJSEngine>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QSettings>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrlQuery>
#include <functional>
#include <memory>
#include <utility>

#include "api/TidalApi.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"

namespace {

// All invented.
const qlonglong kTrack  = 41;
const qlonglong kAlbum  = 5;
const qlonglong kArtist = 9;
const QString   kMix    = QStringLiteral("0a1b2c3d4e5f60718293a4b5c6d7e8");
const QString   kUuid   = QStringLiteral("pl-tape-1");

const QString kSaid   = QStringLiteral("The server says no to this");
// The reason phrase of every refusal, which Qt puts into its own sentence.
const QString kPhrase = QStringLiteral("Kaputt");

// The shape Tidal's v1 gives a refusal.
QByteArray refusal(int status, int subStatus = 2001)
{
    return QJsonDocument(QJsonObject{{QStringLiteral("status"), status},
                                     {QStringLiteral("subStatus"), subStatus},
                                     {QStringLiteral("userMessage"), kSaid}})
        .toJson(QJsonDocument::Compact);
}

// Tidal on loopback. A GET is answered from `reads`, every other verb with
// `write`.
class Loopback : public QTcpServer {
public:
    struct Seen { QByteArray verb; QString path; QByteArray bearer; };
    struct Answer { int status = 204; QByteArray body; };

    Loopback()
    {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket *sock = nextPendingConnection()) {
                auto buf = std::make_shared<QByteArray>();
                connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    const qsizetype end = buf->indexOf("\r\n\r\n");
                    if (end < 0) return;
                    const QList<QByteArray> lines = buf->left(end).split('\n');
                    Seen one;
                    qsizetype length = 0;
                    for (const QByteArray &raw : lines.mid(1)) {
                        const QByteArray line = raw.trimmed();
                        const QByteArray name = line.left(line.indexOf(':')).toLower();
                        const QByteArray value = line.mid(line.indexOf(':') + 1).trimmed();
                        if (name == "content-length") length = value.toLongLong();
                        if (name == "authorization") one.bearer = value.mid(7);
                    }
                    if (buf->size() < end + 4 + length) return;
                    const QList<QByteArray> request = lines.first().trimmed().split(' ');
                    const QString target = QString::fromUtf8(request.value(1));
                    one.verb = request.value(0);
                    one.path = target.left(target.indexOf(QLatin1Char('?')));
                    buf->clear();
                    seen << one;
                    if (one.verb == "GET")
                        answer(sock, {200, reads.value(one.path, QByteArrayLiteral("{}"))});
                    else
                        answer(sock, write);
                });
                connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
            }
        });
    }

    QString base() const { return QStringLiteral("http://127.0.0.1:%1/").arg(serverPort()); }

    int writes() const
    {
        int n = 0;
        for (const Seen &s : seen)
            if (s.verb != "GET") ++n;
        return n;
    }

    Answer write;
    QHash<QString, QByteArray> reads;
    QList<Seen> seen;

private:
    static void answer(QTcpSocket *sock, const Answer &a)
    {
        const QByteArray phrase = a.status >= 400 ? kPhrase.toLatin1() : QByteArray("Fine");
        sock->write("HTTP/1.0 " + QByteArray::number(a.status) + " " + phrase
                    + "\r\nContent-Type: application/json\r\nETag: \"e1\"\r\n"
                      "Content-Length: " + QByteArray::number(a.body.size()) + "\r\n\r\n" + a.body);
        sock->flush();
        sock->disconnectFromHost();
    }
};

// The real TidalApi with every host on the local server.
class LocalApi : public TidalApi {
public:
    QString local;

    // No request is on its way and no answer is waiting to be handled.
    bool idle() const { return findChildren<QNetworkReply *>().isEmpty(); }

protected:
    QString baseUrl(const QString &) const override { return local + QLatin1String("api/"); }
    bool takesTokens(const QUrl &url) const override
    {
        return url.path().startsWith(QLatin1String("/api/"));
    }
};

const char *const kWrites[] = {"postApiForm", "postApiFormEtag", "deleteApi", "deleteApiEtag",
                               "putV2"};

void sendWrite(TidalApi &api, const QString &kind, TidalApi::JsonCallback cb)
{
    QUrlQuery form;
    form.addQueryItem(QStringLiteral("trackIds"), QStringLiteral("41"));
    const QString etag = QStringLiteral("\"e1\"");
    const QString x = QStringLiteral("x");
    if (kind == QLatin1String("postApiForm")) api.postApiForm(x, form, cb);
    else if (kind == QLatin1String("postApiFormEtag")) api.postApiFormEtag(x, form, etag, cb);
    else if (kind == QLatin1String("deleteApi")) api.deleteApi(x, form, cb);
    else if (kind == QLatin1String("deleteApiEtag")) api.deleteApiEtag(x, form, etag, cb);
    else if (kind == QLatin1String("putV2")) api.putV2(x, form, cb);
    else qFatal("unknown kind of write");
}

// A real bridge on a real client, signed in as an invented user 7.
struct Rig {
    // The signals the bridge sent, by name.
    QStringList said;
    // Before the rest, so it goes after it: a request holds script values.
    QJSEngine   engine;
    Loopback    tidal;
    LocalApi    api;
    TidalClient client{&api};
    TidalBridge bridge{&client};
    QJSValue    keepAlive;

    Rig()
    {
        if (!tidal.listen(QHostAddress::LocalHost)) qFatal("no loopback server");
        api.local = tidal.base();
        api.setCountryCode(QStringLiteral("DE"));
        QJSEngine::setObjectOwnership(&bridge, QJSEngine::CppOwnership);
        keepAlive = engine.newQObject(&bridge);
        client.setUserId(7);

        const auto note = [this](const char *name) {
            return [this, name] { said << QLatin1String(name); };
        };
        using B = TidalBridge;
        QObject::connect(&bridge, &B::favoriteTracksChanged, &bridge, note("favoriteTracksChanged"));
        QObject::connect(&bridge, &B::favoriteAlbumsChanged, &bridge, note("favoriteAlbumsChanged"));
        QObject::connect(&bridge, &B::favoriteArtistsChanged, &bridge, note("favoriteArtistsChanged"));
        QObject::connect(&bridge, &B::favoriteMixesChanged, &bridge, note("favoriteMixesChanged"));
        QObject::connect(&bridge, &B::favoritePlaylistsChanged, &bridge,
                         note("favoritePlaylistsChanged"));
        QObject::connect(&bridge, &B::favoriteTrackAdded, &bridge, note("favoriteTrackAdded"));
        QObject::connect(&bridge, &B::favoriteAlbumAdded, &bridge, note("favoriteAlbumAdded"));
        QObject::connect(&bridge, &B::favoriteArtistAdded, &bridge, note("favoriteArtistAdded"));
        QObject::connect(&bridge, &B::favoriteMixAdded, &bridge, note("favoriteMixAdded"));
        QObject::connect(&bridge, &B::favoriteRemoved, &bridge, note("favoriteRemoved"));
        QObject::connect(&bridge, &B::playlistCreated, &bridge, note("playlistCreated"));
        QObject::connect(&bridge, &B::playlistUpdated, &bridge, note("playlistUpdated"));
        QObject::connect(&bridge, &B::playlistStatsChanged, &bridge, note("playlistStatsChanged"));
    }

    // What a page was told, recorded in script. A write answers a bool,
    // createPlaylist a playlist and an error.
    struct Told {
        QJSValue fn;
        QJSValue holder;
        int     calls() const   { return holder.property(QStringLiteral("calls")).toInt(); }
        bool    ok() const      { return holder.property(QStringLiteral("ok")).toBool(); }
        QString message() const { return holder.property(QStringLiteral("message")).toString(); }
    };

    Told slot()
    {
        QJSValue holder = engine.newObject();
        holder.setProperty(QStringLiteral("calls"), 0);
        // Starts true, so an answer that never came cannot pass for a no.
        holder.setProperty(QStringLiteral("ok"), true);
        holder.setProperty(QStringLiteral("message"), QString());
        const QJSValue fn = engine.evaluate(QStringLiteral(
            "(function (h) { return function (a, b) {"
            "  h.calls += 1;"
            "  if (typeof a === 'boolean') { h.ok = a; return; }"
            "  h.message = b ? String(b) : '';"
            "  h.ok = !!(a && a.uuid) && h.message.length === 0;"
            "}; })")).call({holder});
        return {fn, holder};
    }

    void act(const QString &what, const QJSValue &cb)
    {
        if (what == QLatin1String("like a song")) bridge.addTrackFavorite(kTrack, cb);
        else if (what == QLatin1String("unlike a song")) bridge.removeTrackFavorite(kTrack, cb);
        else if (what == QLatin1String("save an album")) bridge.addAlbumFavorite(kAlbum, cb);
        else if (what == QLatin1String("unsave an album")) bridge.removeAlbumFavorite(kAlbum, cb);
        else if (what == QLatin1String("follow an artist")) bridge.addArtistFavorite(kArtist, cb);
        else if (what == QLatin1String("unfollow an artist")) bridge.removeArtistFavorite(kArtist, cb);
        else if (what == QLatin1String("save a mix")) bridge.addMixFavorite(kMix, cb);
        else if (what == QLatin1String("unsave a mix")) bridge.removeMixFavorite(kMix, cb);
        else if (what == QLatin1String("create a playlist"))
            bridge.createPlaylist(QStringLiteral("Tape"), cb);
        else if (what == QLatin1String("rename a playlist"))
            bridge.editPlaylist(kUuid, QStringLiteral("Abends"), QStringLiteral("Am Fluss"), cb);
        else if (what == QLatin1String("add a song to a playlist"))
            bridge.addTracksToPlaylist(kUuid, kTrack, cb);
        else if (what == QLatin1String("take a song out of a playlist"))
            bridge.removeTrackFromPlaylist(kUuid, 0, cb);
        else qFatal("unknown action");
    }

    // The server takes this write: how it answers it, and what it answers to
    // the reads that follow.
    void serverTakes(const QString &what)
    {
        const auto playlist = [](const char *title, const char *description, int tracks) {
            return QJsonDocument(QJsonObject{{QStringLiteral("uuid"), kUuid},
                                             {QStringLiteral("title"), QLatin1String(title)},
                                             {QStringLiteral("description"), QLatin1String(description)},
                                             {QStringLiteral("numberOfTracks"), tracks}})
                .toJson(QJsonDocument::Compact);
        };
        const QString header = QStringLiteral("/api/playlists/") + kUuid;
        tidal.write = {200, {}};
        if (what == QLatin1String("like a song"))
            tidal.reads[QStringLiteral("/api/tracks/41")] = R"({"id":41,"title":"Lied"})";
        else if (what == QLatin1String("save an album"))
            tidal.reads[QStringLiteral("/api/albums/5")] = R"({"id":5,"title":"Platte"})";
        else if (what == QLatin1String("follow an artist"))
            tidal.reads[QStringLiteral("/api/artists/9")] = R"({"id":9,"name":"Kapelle"})";
        else if (what == QLatin1String("save a mix"))
            tidal.write = {200, "{\"addedItems\":[\"" + kMix.toLatin1() + "\"]}"};
        else if (what == QLatin1String("unsave a mix"))
            tidal.write = {200, "{\"deletedItems\":[\"" + kMix.toLatin1() + "\"]}"};
        else if (what == QLatin1String("create a playlist")) {
            tidal.write = {201, playlist("Tape", "", 0)};
            tidal.reads[header] = playlist("Tape", "", 0);
        } else if (what == QLatin1String("add a song to a playlist")) {
            tidal.write = {200, R"({"lastUpdated":1,"addedItemIds":[41]})"};
            tidal.reads[header] = playlist("Tape", "", 1);
        } else if (what == QLatin1String("take a song out of a playlist")) {
            tidal.reads[header] = playlist("Tape", "", 0);
        } else if (what.startsWith(QLatin1String("un")) || what == QLatin1String("rename a playlist")) {
            tidal.write = {204, {}};
        } else qFatal("unknown action");
    }

    // The state `what` starts from, made by writes the server takes.
    void prepare(const QString &what)
    {
        QStringList first;
        if (what == QLatin1String("unlike a song")) first << QStringLiteral("like a song");
        if (what == QLatin1String("unsave an album")) first << QStringLiteral("save an album");
        if (what == QLatin1String("unfollow an artist")) first << QStringLiteral("follow an artist");
        if (what == QLatin1String("unsave a mix")) first << QStringLiteral("save a mix");
        if (what.endsWith(QLatin1String("a playlist")) && !what.startsWith(QLatin1String("create")))
            first << QStringLiteral("create a playlist");
        if (what == QLatin1String("take a song out of a playlist"))
            first << QStringLiteral("add a song to a playlist");
        for (const QString &step : std::as_const(first)) {
            serverTakes(step);
            const Told told = slot();
            act(step, told.fn);
            QTRY_VERIFY_WITH_TIMEOUT(told.calls() == 1 && api.idle(), 5000);
            QVERIFY2(told.ok(), qPrintable(step));
        }
    }

    // What the pages read back from the bridge.
    QString shown() const
    {
        QStringList s;
        if (bridge.isTrackFavorite(kTrack)) s << QStringLiteral("song liked");
        if (bridge.isAlbumFavorite(kAlbum)) s << QStringLiteral("album saved");
        if (bridge.isArtistFavorite(kArtist)) s << QStringLiteral("artist followed");
        if (bridge.isMixFavorite(kMix)) s << QStringLiteral("mix saved");
        const QVariantList playlists = bridge.getUserPlaylists();
        for (const QVariant &v : playlists) {
            const QVariantMap m = v.toMap();
            s << QStringLiteral("playlist %1 (%2) of %3")
                     .arg(m.value(QStringLiteral("title")).toString(),
                          m.value(QStringLiteral("description")).toString())
                     .arg(m.value(QStringLiteral("numTracks")).toInt());
        }
        return s.join(QLatin1String(", "));
    }
};

} // namespace

class TestRefusedWrites : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;

private slots:
    void initTestCase()
    {
        // Never the real configuration: the bridge reads and writes settings.
        QVERIFY(m_dir.isValid());
        qputenv("HOME", m_dir.path().toUtf8());
        QCOMPARE(QDir::homePath(), m_dir.path());
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_refused_writes"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
    }

    // ── the request layer ───────────────────────────────────────────────
    void theAnswerOfAWrite_data()
    {
        QTest::addColumn<QString>("kind");
        QTest::addColumn<int>("status");
        QTest::addColumn<QByteArray>("body");
        for (const char *kind : kWrites) {
            const QString k = QLatin1String(kind);
            const auto row = [&k](const QString &what) -> QTestData & {
                return QTest::newRow(qPrintable(k + QLatin1String(": ") + what));
            };
            for (int status : {400, 401, 403, 404, 412, 429, 500})
                row(QStringLiteral("refused, %1 with Tidal's body").arg(status))
                    << k << status << refusal(status);
            // A refusal in JSON that has no sentence for the user.
            row(QStringLiteral("refused, 400 with a body that has no userMessage"))
                << k << 400 << QByteArray(R"({"errors":[{"code":"BAD_REQUEST"}]})");
            row(QStringLiteral("refused, 502 with a body that is no JSON"))
                << k << 502 << QByteArray("<html>Bad Gateway</html>");
            row(QStringLiteral("refused, 403 with no body")) << k << 403 << QByteArray();
            row(QStringLiteral("accepted, 204 with no body")) << k << 204 << QByteArray();
            row(QStringLiteral("accepted, 200 with a body"))
                << k << 200 << QByteArray(R"({"lastUpdated":1,"addedItemIds":[41]})");
        }
    }

    void theAnswerOfAWrite()
    {
        QFETCH(QString, kind);
        QFETCH(int, status);
        QFETCH(QByteArray, body);
        Loopback tidal;
        QVERIFY(tidal.listen(QHostAddress::LocalHost));
        LocalApi api;
        api.local = tidal.base();
        tidal.write = {status, body};

        int answers = 0;
        QString err;
        QJsonObject got;
        sendWrite(api, kind, [&](QJsonObject o, QString e) { ++answers; got = o; err = e; });
        QTRY_VERIFY_WITH_TIMEOUT(answers > 0 && api.idle(), 5000);
        QCOMPARE(answers, 1);
        QCOMPARE(tidal.writes(), 1);

        const QJsonObject sent = QJsonDocument::fromJson(body).object();
        if (status < 400) {
            QVERIFY2(err.isEmpty(), qPrintable(err));
            QCOMPARE(got, sent);
            return;
        }
        QVERIFY2(!err.isEmpty(),
                 qPrintable(QStringLiteral("an answer of %1 was handed on as a success").arg(status)));
        // The body of a refusal still reaches the caller.
        QCOMPARE(got, sent);
        if (sent.contains(QLatin1String("userMessage"))) {
            QCOMPARE(err, kSaid);
        } else {
            // What the network layer says holds the server's reason phrase.
            QVERIFY2(err.contains(kPhrase), qPrintable(err));
        }
    }

    // A request refused for its token is sent once more. A write refused
    // again has failed.
    void aWriteRefusedAgainAfterTheResendHasFailed_data()
    {
        QTest::addColumn<QString>("kind");
        for (const char *kind : kWrites) QTest::newRow(kind) << QString::fromLatin1(kind);
    }

    void aWriteRefusedAgainAfterTheResendHasFailed()
    {
        QFETCH(QString, kind);
        Loopback tidal;
        QVERIFY(tidal.listen(QHostAddress::LocalHost));
        LocalApi api;
        api.local = tidal.base();
        api.setAccessToken(QStringLiteral("first"));
        int renewals = 0;
        api.setTokenRenewer([&](const QString &, std::function<void(bool)> done) {
            ++renewals;
            api.setAccessToken(QStringLiteral("second"));
            done(true);
        });
        // 11003 is the code of an expired token.
        tidal.write = {401, refusal(401, 11003)};

        int answers = 0;
        QString err;
        sendWrite(api, kind, [&](QJsonObject, QString e) { ++answers; err = e; });
        QTRY_VERIFY_WITH_TIMEOUT(answers > 0 && api.idle(), 5000);
        QCOMPARE(answers, 1);
        QCOMPARE(renewals, 1);
        QCOMPARE(tidal.writes(), 2);
        QCOMPARE(tidal.seen.at(0).bearer, QByteArray("first"));
        QCOMPARE(tidal.seen.at(1).bearer, QByteArray("second"));
        QCOMPARE(err, kSaid);
    }

    // ── what the user did, through the real client and bridge ───────────
    void whatTheUserDid_data()
    {
        QTest::addColumn<QString>("action");
        QTest::addColumn<int>("status");
        QTest::addColumn<QByteArray>("body");
        QTest::addColumn<QString>("before");
        QTest::addColumn<QString>("after");

        struct Action { const char *name, *before, *after; };
        const Action actions[] = {
            {"like a song",        "", "song liked"},
            {"unlike a song",      "song liked", ""},
            {"save an album",      "", "album saved"},
            {"unsave an album",    "album saved", ""},
            {"follow an artist",   "", "artist followed"},
            {"unfollow an artist", "artist followed", ""},
            {"save a mix",         "", "mix saved"},
            {"unsave a mix",       "mix saved", ""},
            {"create a playlist",  "", "playlist Tape () of 0"},
            {"rename a playlist",  "playlist Tape () of 0", "playlist Abends (Am Fluss) of 0"},
            {"add a song to a playlist", "playlist Tape () of 0", "playlist Tape () of 1"},
            {"take a song out of a playlist", "playlist Tape () of 1", "playlist Tape () of 0"},
        };
        for (const Action &a : actions) {
            const QString name = QLatin1String(a.name);
            const auto row = [&](const char *how, int status, const QByteArray &body) {
                QTest::newRow(qPrintable(name + QLatin1String(": ") + QLatin1String(how)))
                    << name << status << body << QString::fromLatin1(a.before)
                    << QString::fromLatin1(a.after);
            };
            row("the server takes it", 200, {});
            row("refused, 404 with Tidal's body", 404, refusal(404));
            // What a playlist edit gets when its ETag is stale.
            row("refused, 412 with Tidal's body", 412, refusal(412));
            row("refused, 502 with a body that is no JSON", 502, "<html>Bad Gateway</html>");
            row("refused, 403 with no body", 403, {});
        }
    }

    void whatTheUserDid()
    {
        QFETCH(QString, action);
        QFETCH(int, status);
        QFETCH(QByteArray, body);
        QFETCH(QString, before);
        QFETCH(QString, after);
        const bool refused = status >= 400;

        Rig rig;
        QTRY_VERIFY_WITH_TIMEOUT(rig.api.idle(), 5000);
        rig.prepare(action);
        if (QTest::currentTestFailed()) return;
        QCOMPARE(rig.shown(), before);

        if (refused) rig.tidal.write = {status, body};
        else         rig.serverTakes(action);
        rig.said.clear();
        const Rig::Told told = rig.slot();
        rig.act(action, told.fn);
        QTRY_VERIFY_WITH_TIMEOUT(told.calls() > 0 && rig.api.idle(), 5000);
        QCOMPARE(told.calls(), 1);

        if (!refused) {
            QVERIFY2(told.ok(), qPrintable(told.message()));
            QCOMPARE(rig.shown(), after);
            return;
        }
        QVERIFY2(!told.ok(), "the page was told that the server took it");
        QCOMPARE(rig.shown(), before);
        QCOMPARE(rig.said.join(QLatin1String(", ")), QString());
        if (action != QLatin1String("create a playlist")) return;
        // The one write whose page shows the reason.
        if (QJsonDocument::fromJson(body).isObject()) QCOMPARE(told.message(), kSaid);
        else QVERIFY2(told.message().contains(kPhrase), qPrintable(told.message()));
    }
};

QTEST_GUILESS_MAIN(TestRefusedWrites)
#include "tst_refused_writes.moc"
