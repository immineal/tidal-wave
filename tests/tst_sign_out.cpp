// What ending a session leaves behind. Application::endAccountSession runs on
// Auth::loggedOut and on Auth::sessionExpired: playback stops, the queue goes,
// and the client, the pins and the library drop the account, so the next
// account to sign in inherits none of it. Also the temp files a run leaves.

#include <QTest>
#include <QDir>
#include <QFile>
#include <QLockFile>
#include <QMediaPlayer>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QVariantList>
#include <memory>

#include "api/LibraryIndex.h"
#include "api/TidalApi.h"
#include "api/TidalClient.h"
#include "player/Player.h"
#include "scrobble/ScrobbleService.h"
#include "scrobble/ScrobbleSink.h"
#include "ui/Application.h"
#include "ui/PinStore.h"

namespace {

// Invented accounts.
constexpr qint64 kOwner = 4242;
constexpr qint64 kNext  = 4343;

QVariantList tracks(int n)
{
    QVariantList out;
    for (int i = 0; i < n; ++i) {
        QVariantMap t;
        t[QStringLiteral("id")]       = qlonglong(1000 + i);
        t[QStringLiteral("title")]    = QStringLiteral("T%1").arg(i);
        t[QStringLiteral("albumId")]  = qlonglong(7);
        t[QStringLiteral("duration")] = 200;
        out.append(t);
    }
    return out;
}

// Never reaches the network: no stream is ever answered.
class QuietClient : public TidalClient {
public:
    using TidalClient::TidalClient;
    void fetchStreamManifest(qint64, StreamCb) override {}
};

// A scrobbling service that answers at once and keeps every listen waiting.
class NoNetworkService : public ScrobbleService {
public:
    QString name() const override { return QStringLiteral("Test"); }
    QString key()  const override { return QStringLiteral("test"); }
    int maxBatch() const override { return 10; }
    void verify(const QString &, Verified done) override { done({}, QStringLiteral("listener")); }
    void nowPlaying(const QString &, const Listen &, Done done) override { done({}); }
    void submit(const QString &, const QList<Listen> &, Done done) override {
        ScrobbleReply r;
        r.kind = ScrobbleReply::Retry;
        done(r);
    }
};

struct Session {
    TidalApi    api;
    QuietClient client{&api};
    PinStore    pins;
    std::unique_ptr<LibraryIndex> library;
    std::unique_ptr<Player>       player;

    explicit Session(qint64 uid = kOwner)
    {
        library = std::make_unique<LibraryIndex>(&client, &pins);
        client.setUserId(uid);
        pins.setUserId(uid);
        player = std::make_unique<Player>(&client);
    }
    ~Session() { player.reset(); library.reset(); }

    bool settle()
    {
        return QTest::qWaitFor([this] { return player->findChild<QMediaPlayer *>() != nullptr; },
                               10000);
    }
    void end(bool forget, const QList<ScrobbleSink *> &scrobbling = {})
    {
        Application::endAccountSession(&client, player.get(), &pins, library.get(), forget,
                                       scrobbling);
    }
    // A sign-in, as Application's loginSucceeded handler makes it.
    void signIn(qint64 uid)
    {
        client.setUserId(uid);
        pins.setUserId(uid);
        library->setUserId(uid);
    }
};

} // namespace

class TestSignOut : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;

private slots:
    void initTestCase()
    {
        QVERIFY(m_dir.isValid());
        qputenv("HOME", m_dir.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", (m_dir.path() + QStringLiteral("/.config")).toUtf8());
        QStandardPaths::setTestModeEnabled(true);
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_sign_out"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
    }

    void init() { QSettings().clear(); }

    // The bug: nothing was cleared, the old queue kept playing, and the next
    // account to sign in had it saved under its own name.
    void aLogOutLeavesNothingForTheNextAccount()
    {
        Session s;
        QVERIFY(s.settle());
        s.player->playTracks(tracks(4), 1);
        QCOMPARE(s.player->queueCount(), 4);

        s.end(true);
        QCOMPARE(s.player->queueCount(), 0);
        QCOMPARE(s.player->queueIndex(), -1);
        QCOMPARE(s.client.userId(), 0);

        s.signIn(kNext);
        QCOMPARE(s.player->queueCount(), 0);
        // Past the Player's save delay, then the next launch for that account:
        // nothing of the old queue was saved under it.
        QTest::qWait(2000);
        s.player.reset();
        Session next(kNext);
        QVERIFY(next.settle());
        QCOMPARE(next.player->queueCount(), 0);
    }

    // An explicit log out forgets the queue: signing in again starts empty.
    void aLogOutForgetsTheQueue()
    {
        Session s;
        QVERIFY(s.settle());
        s.player->playTracks(tracks(4), 1);
        s.player->savePlaybackState();
        s.end(true);
        s.signIn(kOwner);
        QCOMPARE(s.player->queueCount(), 0);
    }

    // A session that expired keeps the saved queue for the same account.
    void anExpiredSessionKeepsTheSavedQueue()
    {
        Session s;
        QVERIFY(s.settle());
        s.player->playTracks(tracks(4), 1);
        s.player->savePlaybackState();
        s.end(false);
        QCOMPARE(s.player->queueCount(), 0);
        QTest::qWait(2000);
        s.signIn(kOwner);
        QCOMPARE(s.player->queueCount(), 4);
    }

    // ── scrobbling ──────────────────────────────────────────────────────
    // A log out disconnects every scrobbling account. What was not sent
    // stays for the same account, as Disconnect in Settings leaves it.
    void aLogOutDisconnectsScrobbling()
    {
        QTemporaryDir dir;
        auto *service = new NoNetworkService;
        ScrobbleSink sink(service, {dir.filePath(QStringLiteral("secret.json")),
                                    dir.filePath(QStringLiteral("queue.json"))});
        sink.setEnabled(true);
        sink.signIn(QStringLiteral("token"));
        QVERIFY(sink.connected());
        Listen l;
        l.trackId = 1; l.artist = QStringLiteral("A"); l.title = QStringLiteral("T");
        l.listenedAt = 1'700'000'000;
        sink.add(l);
        QCOMPARE(sink.queuedCount(), 1);

        Session s;
        QVERIFY(s.settle());
        s.end(false, {&sink});
        QVERIFY2(sink.connected(), "a session that expired took the scrobbling account");
        s.end(true, {&sink});
        QVERIFY(!sink.connected());
        QVERIFY(!QFile::exists(dir.filePath(QStringLiteral("secret.json"))));
        QCOMPARE(sink.queuedCount(), 1);
    }

    // ── temp files ──────────────────────────────────────────────────────
    // This app's names, this user's files; anything else stays.
    void theSweepTakesOnlyThisAppsLeftovers()
    {
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        const QStringList ours = {
            QStringLiteral("tidal-wave-a1B2c3.mp4"), QStringLiteral("tidal-wave-cast-Zz9yX8.mp4"),
            QStringLiteral("tidal-wave-cover-q1w2e3.jpg"), QStringLiteral("tidal-wave-000000.flac"),
            // CastMediaPrep's three: the fetched file and both conversions.
            QStringLiteral("tidal-wave-cast-Aa1Bb2.flac"), QStringLiteral("tidal-wave-cast-q9W8e7.m4a")};
        const QStringList theirs = {
            QStringLiteral("tidal-wave-notes.txt"), QStringLiteral("tidal-wave-a1B2c3.mp4.part"),
            QStringLiteral("other-a1B2c3.mp4"), QStringLiteral("tidal-wave-1000.lock")};
        for (const QString &n : ours + theirs) {
            QFile f(tmp.filePath(n));
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write("x");
        }
        QCOMPARE(Application::sweepStaleTempFiles(tmp.path()), int(ours.size()));
        for (const QString &n : ours) QVERIFY2(!QFile::exists(tmp.filePath(n)), qPrintable(n));
        for (const QString &n : theirs) QVERIFY2(QFile::exists(tmp.filePath(n)), qPrintable(n));
    }

    // A second instance finds the lock held and must not sweep.
    void theTempLockIsHeldByOneInstance()
    {
        QTemporaryDir tmp;
        QLockFile first(Application::tempLockPath(tmp.path()));
        first.setStaleLockTime(0);
        QVERIFY(first.tryLock(0));
        QLockFile second(Application::tempLockPath(tmp.path()));
        second.setStaleLockTime(0);
        QVERIFY(!second.tryLock(0));
    }
};

QTEST_MAIN(TestSignOut)
#include "tst_sign_out.moc"
