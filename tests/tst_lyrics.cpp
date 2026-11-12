// LyricsFinder and its providers: matching, parsing, pacing, the cache, and
// that nothing touches the network while the switch is off. No live requests.

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QTemporaryDir>
#include <QTest>
#include <QUrlQuery>

#include "api/LyricsFinder.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"

#include <QJSEngine>

namespace {

class FakeTransport : public LyricsTransport {
public:
    struct Call { QUrl url; Done done; bool aborted = false; };
    QList<Call> calls;
    int get(const QUrl &url, Done done) override {
        calls.append({url, std::move(done)});
        return int(calls.size()) - 1;
    }
    void abort(int h) override { calls[h].aborted = true; }
    void answer(int i, int status, const QByteArray &body = {}, const QByteArray &retry = {}) {
        QVERIFY(!calls[i].aborted);
        calls[i].done(LyricsReply{status, body, retry});
    }
};

LyricsQuery query(qint64 id = 7) {
    LyricsQuery q;
    q.trackId = id;
    q.title = QStringLiteral("Harbour Lights (feat. Someone Else)");
    q.artists = {QStringLiteral("Paper Lanterns"), QStringLiteral("Someone Else")};
    q.album = QStringLiteral("Night Ferry");
    q.duration = 201;
    return q;
}

QByteArray lrclibRecord(const QString &title, const QString &artist, double dur,
                        const QString &synced, const QString &plain) {
    QJsonObject o{{"id", 1}, {"trackName", title}, {"artistName", artist},
                  {"albumName", "Night Ferry"}, {"duration", dur}, {"instrumental", false},
                  {"syncedLyrics", synced.isEmpty() ? QJsonValue() : QJsonValue(synced)},
                  {"plainLyrics", plain.isEmpty() ? QJsonValue() : QJsonValue(plain)}};
    return QJsonDocument(o).toJson();
}

} // namespace

class TestLyrics : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;
    qint64 m_now = 1'000'000'000'000;

    LyricsFinder *makeFinder(FakeTransport *t, bool *enabled) {
        auto *f = new LyricsFinder(this);
        f->setEnabledSource([enabled] { return *enabled; });
        f->setTransport(t);
        f->setCacheDir(m_dir.path() + QStringLiteral("/c") + QString::number(++m_cacheN));
        f->setClock([this] { return m_now; });
        f->setSettleMs(LyricsFinder::kSettleMs);
        f->setJitter([] { return 0.0; });
        return f;
    }
    int m_cacheN = 0;

private slots:
    // ── matching ─────────────────────────────────────────────────────────

    void normalisedTitles_data() {
        QTest::addColumn<QString>("a");
        QTest::addColumn<QString>("b");
        QTest::addColumn<bool>("same");
        QTest::newRow("feat in brackets") << "Song (feat. X)" << "Song" << true;
        QTest::newRow("bare feat") << "Song feat. X & Y" << "Song" << true;
        QTest::newRow("remaster dash") << "Song - 2011 Remaster" << "song" << true;
        QTest::newRow("radio edit") << "Song [Radio Edit]" << "Song" << true;
        QTest::newRow("case and punctuation") << "Don't Stop, Me!" << "dont stop me" << true;
        QTest::newRow("accents") << "Café Noir" << "Cafe Noir" << true;
        QTest::newRow("ampersand") << "Salt & Sea" << "Salt and Sea" << true;
        QTest::newRow("part kept") << "Song (Part 2)" << "Song" << false;
        QTest::newRow("other song") << "Song" << "Another Song" << false;
        QTest::newRow("dash title kept") << "Here - There" << "Here" << false;
        QTest::newRow("cjk kept") << "夜の街 (feat. X)" << "夜の街" << true;
        QTest::newRow("cjk differs") << "夜の街" << "朝の街" << false;
        QTest::newRow("cyrillic") << "Песня" << "песня" << true;
    }
    void normalisedTitles() {
        QFETCH(QString, a);
        QFETCH(QString, b);
        QFETCH(bool, same);
        QCOMPARE(lyrics::titleMatches(a, b), same);
    }

    void artists() {
        const QStringList want{QStringLiteral("The Paper Lanterns")};
        QVERIFY(lyrics::artistMatches(want, QStringLiteral("Paper Lanterns")));
        QVERIFY(lyrics::artistMatches(want, QStringLiteral("Paper Lanterns & Someone")));
        QVERIFY(lyrics::artistMatches({QStringLiteral("Simon & Garfunkel")},
                                      QStringLiteral("Simon and Garfunkel")));
        QVERIFY(!lyrics::artistMatches(want, QStringLiteral("Paper Boats")));
        QVERIFY(!lyrics::artistMatches(want, QString()));
        QVERIFY(lyrics::artistMatches({QStringLiteral("宇多田ヒカル")},
                                      QStringLiteral("宇多田ヒカル")));
        QVERIFY(!lyrics::artistMatches({QStringLiteral("宇多田ヒカル")},
                                       QStringLiteral("横山克")));
    }

    void durations() {
        QVERIFY(lyrics::durationMatches(200, 203));
        QVERIFY(!lyrics::durationMatches(200, 203.5));
        QVERIFY(lyrics::durationMatches(200, 0));     // the source gave none
        QVERIFY(lyrics::durationMatches(0, 500));
        QVERIFY(lyrics::durationMatches(200, 202, 2));
        QVERIFY(!lyrics::durationMatches(200, 202.5, 2));
    }

    // ── LRCLIB ───────────────────────────────────────────────────────────

    void lrclibGetPrefersSynced() {
        LrclibProvider p;
        const LyricsQuery q = query();
        const LyricsStep s = p.start(q);
        QCOMPARE(s.kind, LyricsStep::Request);
        QCOMPARE(s.url.host(), QStringLiteral("lrclib.net"));
        QCOMPARE(s.url.path(), QStringLiteral("/api/get"));
        const QUrlQuery uq(s.url);
        QCOMPARE(uq.queryItemValue("artist_name", QUrl::FullyDecoded), QStringLiteral("Paper Lanterns"));
        QCOMPARE(uq.queryItemValue("duration"), QStringLiteral("201"));
        QCOMPARE(uq.queryItemValue("album_name", QUrl::FullyDecoded), QStringLiteral("Night Ferry"));

        const LyricsStep r = p.next(q, s, {200, lrclibRecord("Harbour Lights", "Paper Lanterns", 202,
                                                             "[00:01.00]one", "one"), {}});
        QCOMPARE(r.kind, LyricsStep::Found);
        QVERIFY(r.result.timed);
        QCOMPARE(r.result.text, QStringLiteral("[00:01.00]one"));
        QCOMPARE(r.result.source, QStringLiteral("LRCLIB"));
    }

    void lrclibFallsBackToSearchAndRejectsWrongLength() {
        LrclibProvider p;
        const LyricsQuery q = query();
        const LyricsStep get = p.start(q);
        const LyricsStep search = p.next(q, get, {404, "{\"code\":404}", {}});
        QCOMPARE(search.kind, LyricsStep::Request);
        QCOMPARE(search.url.path(), QStringLiteral("/api/search"));
        QCOMPARE(QUrlQuery(search.url).queryItemValue("track_name", QUrl::FullyDecoded),
                 QStringLiteral("Harbour Lights"));

        QJsonArray arr;
        arr.append(QJsonDocument::fromJson(lrclibRecord("Harbour Lights", "Paper Lanterns", 260, "[00:01.00]long", "")).object());
        // 2.5 s off: the search keeps only records within 2 s.
        arr.append(QJsonDocument::fromJson(lrclibRecord("Harbour Lights", "Paper Lanterns", 203.5, "[00:01.00]near", "")).object());
        arr.append(QJsonDocument::fromJson(lrclibRecord("Harbour Lights", "Paper Lanterns", 200, "", "plain")).object());
        arr.append(QJsonDocument::fromJson(lrclibRecord("Harbour Lights", "Someone Unrelated", 201, "[00:01.00]x", "")).object());
        const LyricsStep r = p.next(q, search, {200, QJsonDocument(arr).toJson(), {}});
        QCOMPARE(r.kind, LyricsStep::Found);
        QCOMPARE(r.result.text, QStringLiteral("plain"));
        QVERIFY(!r.result.timed);

        QCOMPARE(p.next(q, search, {200, "[]", {}}).kind, LyricsStep::Miss);
        QCOMPARE(p.next(q, get, {500, {}, {}}).kind, LyricsStep::Failed);
    }

    void lrclibInstrumentalIsAnAnswer() {
        LrclibProvider p;
        const LyricsQuery q = query();
        QVariantMap rec = QJsonDocument::fromJson(
            lrclibRecord("Harbour Lights", "Paper Lanterns", 201, "", "")).object().toVariantMap();
        rec["instrumental"] = true;
        const LyricsStep r = p.next(q, p.start(q), {200, QJsonDocument::fromVariant(rec).toJson(), {}});
        QCOMPARE(r.kind, LyricsStep::Instrumental);
        // An instrumental of another song is no answer.
        rec["artistName"] = QStringLiteral("Someone Unrelated");
        QCOMPARE(p.next(q, p.start(q), {200, QJsonDocument::fromVariant(rec).toJson(), {}}).kind,
                 LyricsStep::Request);
    }

    // ── NetEase ──────────────────────────────────────────────────────────

    static QByteArray neteaseSearch() {
        auto song = [](qint64 id, const QString &name, const QString &artist, int ms) {
            return QJsonObject{{"id", id}, {"name", name}, {"duration", ms},
                               {"artists", QJsonArray{QJsonObject{{"name", artist}}}}};
        };
        return QJsonDocument(QJsonObject{{"result", QJsonObject{{"songs", QJsonArray{
            song(11, "Harbour Lights", "Paper Lanterns", 260000),
            song(12, "Harbour Lights", "Other Band", 201000),
            song(13, "Harbour Lights", "Paper Lanterns", 200500)}}}}}).toJson();
    }

    void neteaseSearchThenLyric() {
        NeteaseProvider p;
        const LyricsQuery q = query();
        const LyricsStep s = p.start(q);
        QCOMPARE(s.url.host(), QStringLiteral("music.163.com"));
        QCOMPARE(s.url.path(), QStringLiteral("/api/search/get"));
        const QUrlQuery sq(s.url);
        QCOMPARE(sq.queryItemValue("s", QUrl::FullyDecoded), QStringLiteral("Paper Lanterns Harbour Lights"));
        QCOMPARE(sq.queryItemValue("type"), QStringLiteral("1"));

        const LyricsStep lyric = p.next(q, s, {200, neteaseSearch(), {}});
        QCOMPARE(lyric.kind, LyricsStep::Request);
        QCOMPARE(lyric.url.path(), QStringLiteral("/api/song/lyric"));
        QCOMPARE(QUrlQuery(lyric.url).queryItemValue("id"), QStringLiteral("13"));

        const QString lrc = QStringLiteral(
            "[00:00.00] 作词 : Someone\n[00:00.50] 作曲 : Someone\n"
            "[00:01.00]Lanterns on the water\n[00:04.20]Nobody: nothing but the tide\n");
        const QByteArray body = QJsonDocument(QJsonObject{{"lrc", QJsonObject{{"lyric", lrc}}}}).toJson();
        const LyricsStep r = p.next(q, lyric, {200, body, {}});
        QCOMPARE(r.kind, LyricsStep::Found);
        QVERIFY(r.result.timed);
        QCOMPARE(r.result.text, QStringLiteral(
            "[00:01.00]Lanterns on the water\n[00:04.20]Nobody: nothing but the tide"));
        QCOMPARE(r.result.source, QStringLiteral("NetEase Cloud Music"));
        QCOMPARE(r.result.url, QUrl("https://music.163.com/#/song?id=13"));

        QCOMPARE(p.next(q, lyric, {200, "{\"nolyric\":true}", {}}).kind, LyricsStep::Instrumental);
        QCOMPARE(p.next(q, lyric, {200, "{\"pureMusic\":true,\"lrc\":{\"lyric\":\"[00:01.00]x\"}}", {}}).kind,
                 LyricsStep::Instrumental);
        QCOMPARE(p.next(q, lyric, {200, "{\"lrc\":{\"lyric\":\"[00:00.00] 作词 : A\"}}", {}}).kind,
                 LyricsStep::Miss);
        QCOMPARE(p.next(q, s, {200, "{\"result\":{}}", {}}).kind, LyricsStep::Miss);
    }

    // ── KuGou ────────────────────────────────────────────────────────────

    void kugouSearchThenDownload() {
        KugouProvider p;
        const LyricsQuery q = query();
        const LyricsStep s = p.start(q);
        QCOMPARE(s.url.host(), QStringLiteral("lyrics.kugou.com"));
        QCOMPARE(s.url.path(), QStringLiteral("/search"));
        const QUrlQuery sq(s.url);
        QCOMPARE(sq.queryItemValue("keyword", QUrl::FullyDecoded), QStringLiteral("Paper Lanterns - Harbour Lights"));
        QCOMPARE(sq.queryItemValue("duration"), QStringLiteral("201000"));

        auto cand = [](const QString &id, const QString &song, const QString &singer, int ms) {
            return QJsonObject{{"id", id}, {"accesskey", "K" + id}, {"song", song},
                               {"singer", singer}, {"duration", ms}};
        };
        const QByteArray search = QJsonDocument(QJsonObject{{"candidates", QJsonArray{
            cand("1", "Harbour Lights", "Other Band", 201000),
            cand("2", "Harbour Lights", "Paper Lanterns", 202000)}}}).toJson();
        const LyricsStep dl = p.next(q, s, {200, search, {}});
        QCOMPARE(dl.kind, LyricsStep::Request);
        QCOMPARE(dl.url.path(), QStringLiteral("/download"));
        const QUrlQuery dq(dl.url);
        QCOMPARE(dq.queryItemValue("id"), QStringLiteral("2"));
        QCOMPARE(dq.queryItemValue("accesskey"), QStringLiteral("K2"));
        QCOMPARE(dq.queryItemValue("fmt"), QStringLiteral("lrc"));

        const QByteArray lrc = QStringLiteral(
            "[ar:Paper Lanterns]\n[ti:Harbour Lights]\n[00:00.10]作曲：Someone\n"
            "[00:01.00]First lantern\n[00:03.00]Second lantern\n[00:05.00]Third lantern\n"
            "[00:07.00]Fourth lantern\n").toUtf8();
        const QByteArray body = QJsonDocument(QJsonObject{{"content", QString::fromLatin1(lrc.toBase64())}}).toJson();
        const LyricsStep r = p.next(q, dl, {200, body, {}});
        QCOMPARE(r.kind, LyricsStep::Found);
        QVERIFY(r.result.timed);
        QVERIFY(r.result.text.startsWith(QStringLiteral("[00:01.00]First lantern")));
        QVERIFY(!r.result.text.contains(QStringLiteral("作曲")));
        QCOMPARE(r.result.source, QStringLiteral("KuGou"));
        QCOMPARE(p.next(q, s, {200, "{\"candidates\":[]}", {}}).kind, LyricsStep::Miss);
    }

    void creditLines() {
        QCOMPARE(lyrics::stripCreditLines(QStringLiteral(
                     "[00:00.00]编曲：X\n[00:00.10]Lyrics by: X\n[00:01.00]Time: it waits\n")),
                 QStringLiteral("[00:01.00]Time: it waits"));
    }

    void defaultChainOrder() {
        QStringList names;
        for (const auto &p : lyrics::defaultProviders()) names << p->name();
        QCOMPARE(names, (QStringList{"LRCLIB", "NetEase Cloud Music", "KuGou", "Genius"}));
    }

    // ── Genius ───────────────────────────────────────────────────────────

    void geniusPage() {
        QFile f(QStringLiteral(TW_FIXTURE_DIR "/genius_song.html"));
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QString text = lyrics::geniusLyricsFromHtml(f.readAll());
        QCOMPARE(text, QStringLiteral(
            "[Verse 1]\n"
            "The tide comes & goes in the quiet grey bay\n"
            "We don't say a word, we just \"wait\"\n"
            "\n"
            "[Chorus]\n"
            "Harbour lights, café nights\n"
            "Burning low\n"
            "Over the water <slow>"));
        QVERIFY(!lyrics::looksLikeChallenge(f.readAll()));
    }

    void geniusOldHeaderIsDropped() {
        const QByteArray html = "<div data-lyrics-container=\"true\">12 ContributorsHarbour Lights Lyrics[Intro]<br>la</div>";
        QCOMPARE(lyrics::geniusLyricsFromHtml(html), QStringLiteral("[Intro]\nla"));
        QCOMPARE(lyrics::geniusLyricsFromHtml("<div>nothing here</div>"), QString());
    }

    void geniusPageAddress() {
        QCOMPARE(GeniusProvider::pageUrl(query()),
                 QUrl("https://genius.com/Paper-lanterns-harbour-lights-lyrics"));
        LyricsQuery q = query();
        q.artists = {QStringLiteral("Sigur Rós & Friends")};
        q.title = QStringLiteral("Ára bátur (Live)");
        QCOMPARE(GeniusProvider::pageUrl(q), QUrl("https://genius.com/Sigur-ros-and-friends-ara-batur-lyrics"));
        // Nothing left after folding to ASCII: Genius is not asked at all.
        q.artists = {QStringLiteral("宇多田ヒカル")};
        q.title = QStringLiteral("花束を君に");
        QCOMPARE(GeniusProvider().start(q).kind, LyricsStep::Miss);
    }

    void geniusPageMustNameTheSong() {
        QFile f(QStringLiteral(TW_FIXTURE_DIR "/genius_song.html"));
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QByteArray html = f.readAll();
        GeniusProvider p;
        const LyricsStep s = p.start(query());
        QCOMPARE(s.kind, LyricsStep::Request);
        QCOMPARE(s.url.host(), QStringLiteral("genius.com"));
        const LyricsStep r = p.next(query(), s, {200, html, {}});
        QCOMPARE(r.kind, LyricsStep::Found);
        QCOMPARE(r.result.source, QStringLiteral("Genius"));
        QCOMPARE(r.result.url, s.url);
        QVERIFY(r.result.text.startsWith(QStringLiteral("[Verse 1]")));

        QByteArray other = html;
        other.replace("Paper Lanterns \xe2\x80\x93 Harbour Lights Lyrics", "Other Band \xe2\x80\x93 Harbour Lights Lyrics");
        QVERIFY(other != html);
        QCOMPARE(p.next(query(), s, {200, other, {}}).kind, LyricsStep::Miss);
        QCOMPARE(p.next(query(), s, {404, {}, {}}).kind, LyricsStep::Miss);
    }

    void challengePages() {
        QVERIFY(lyrics::looksLikeChallenge("<html><head><title>Just a moment...</title>"));
        QVERIFY(lyrics::looksLikeChallenge("window._cf_chl_opt={}"));
        QVERIFY(!lyrics::looksLikeChallenge("<html>lyrics</html>"));
    }

    // ── pacing ───────────────────────────────────────────────────────────

    void pacingInterval() {
        HostPacing p;
        const QString h = QStringLiteral("a.example");
        QCOMPARE(p.waitMs(h, 0), 0);
        p.sent(h, 1000);
        QVERIFY(p.busy(h));
        QCOMPARE(p.waitMs(h, 1500), HostPacing::kMinIntervalMs - 500);
        QCOMPARE(p.waitMs(h, 1000 + HostPacing::kMinIntervalMs), 0);
        QCOMPARE(p.waitMs(QStringLiteral("b.example"), 1500), 0);
        p.answered(h);
        QVERIFY(!p.busy(h));
    }

    void pacingBackoff() {
        HostPacing p;
        p.setJitter([] { return 0.0; });
        const QString h = QStringLiteral("a.example");
        p.refused(h, 0, {});
        QVERIFY(p.blocked(h, HostPacing::kFirstBackoffMs - 1));
        QVERIFY(!p.blocked(h, HostPacing::kFirstBackoffMs));
        p.refused(h, 0, {});
        QCOMPARE(p.blockedUntil(h), 2 * HostPacing::kFirstBackoffMs);
        p.refused(h, 0, "120");
        QCOMPARE(p.blockedUntil(h), 120'000);
        p.refused(h, 0, QByteArray::number(10 * 24 * 3600));
        QCOMPARE(p.blockedUntil(h), HostPacing::kMaxBackoffMs);
        // 1'000'000'000'000 ms is Sun, 09 Sep 2001 01:46:40 GMT.
        p.refused(h, 1'000'000'000'000, "Sun, 09 Sep 2001 01:51:40 GMT");
        QCOMPARE(p.blockedUntil(h), 1'000'000'000'000 + 300'000);
    }

    // Up to 30 % on top of the pause, whichever way it was worked out.
    void pacingJitter() {
        HostPacing p;
        const QString h = QStringLiteral("a.example");
        p.setJitter([] { return 0.5; });
        p.refused(h, 0, {});
        QCOMPARE(p.blockedUntil(h), HostPacing::kFirstBackoffMs + HostPacing::kFirstBackoffMs * 15 / 100);
        p.refused(h, 0, "100");
        QCOMPARE(p.blockedUntil(h), 115'000);
        HostPacing real;
        for (int i = 0; i < 20; ++i) {
            real.refused(h, 0, "100");
            QVERIFY(real.blockedUntil(h) >= 100'000);
            QVERIFY(real.blockedUntil(h) <= 130'000);
        }
    }

    // ── cache ────────────────────────────────────────────────────────────

    void cacheHitAndMissExpiry() {
        LyricsCache c(m_dir.path() + QStringLiteral("/cache-direct"));
        LyricsResult out;
        QCOMPARE(c.lookup(1, 0, &out), LyricsCache::Hit::None);
        c.storeMiss(1, 1000);
        QCOMPARE(c.lookup(1, 1000 + LyricsCache::kMissTtlMs - 1, &out), LyricsCache::Hit::Miss);
        QCOMPARE(c.lookup(1, 1000 + LyricsCache::kMissTtlMs, &out), LyricsCache::Hit::None);
        LyricsResult r{QStringLiteral("words"), true, QStringLiteral("LRCLIB"), QUrl("https://lrclib.net/")};
        c.storeFound(2, r, 1000);
        QCOMPARE(c.lookup(2, 1000 + 100 * LyricsCache::kMissTtlMs, &out), LyricsCache::Hit::Found);
        QCOMPARE(out.text, r.text);
        QVERIFY(out.timed);
        QCOMPARE(out.source, r.source);
        QCOMPARE(out.url, r.url);

        c.storeInstrumental(3, 1000);
        LyricsResult instr;
        QCOMPARE(c.lookup(3, 1000 + 100 * LyricsCache::kMissTtlMs, &instr), LyricsCache::Hit::Instrumental);
        QVERIFY(instr.instrumental);
    }

    // ── the finder ───────────────────────────────────────────────────────

    void offMeansNoNetwork() {
        auto *f = new LyricsFinder(this);
        f->setCacheDir(m_dir.path() + QStringLiteral("/off"));
        bool called = false;
        QString err;
        f->find(query(), [&](const LyricsResult &, const QString &e) { called = true; err = e; });
        QVERIFY(called);
        QCOMPARE(err, QStringLiteral("off"));
        QVERIFY(!f->hasTransportForTest());
        QVERIFY(!f->timerActiveForTest());
        QVERIFY(f->findChildren<QNetworkAccessManager *>().isEmpty());
        QVERIFY(!QDir(m_dir.path() + QStringLiteral("/off")).exists());
        delete f;
    }

    void waitsForTheTrackToSettle() {
        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        f->find(query(1), [](const LyricsResult &, const QString &) {});
        QVERIFY(f->timerActiveForTest());
        QCOMPARE(f->timerIntervalForTest(), LyricsFinder::kSettleMs);
        QCOMPARE(t.calls.size(), 0);
        // Skipped to the next track before it settled: nothing was sent.
        f->find(query(2), [](const LyricsResult &, const QString &) {});
        QCOMPARE(t.calls.size(), 0);
        f->fireTimerForTest();
        QCOMPARE(t.calls.size(), 1);
        delete f;
    }

    void chainFindsOnGeniusAndCaches() {
        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        f->setProviders({std::make_shared<LrclibProvider>(), std::make_shared<GeniusProvider>()});
        LyricsResult got;
        int calls = 0;
        auto done = [&](const LyricsResult &r, const QString &) { got = r; ++calls; };
        f->find(query(), done);
        f->fireTimerForTest();
        t.answer(0, 404);                       // lrclib get
        // Same host next, so it waits out the interval first.
        QVERIFY(QTest::qWaitFor([&] { return f->timerActiveForTest(); }));
        QCOMPARE(t.calls.size(), 1);
        QCOMPARE(f->timerIntervalForTest(), int(HostPacing::kMinIntervalMs));
        m_now += HostPacing::kMinIntervalMs;
        f->fireTimerForTest();
        QCOMPARE(t.calls.size(), 2);
        QCOMPARE(t.calls[1].url.path(), QStringLiteral("/api/search"));
        t.answer(1, 200, "[]");
        // Genius is another host, so no wait, and one request: the page.
        QTRY_COMPARE(t.calls.size(), 3);
        QCOMPARE(t.calls[2].url, QUrl("https://genius.com/Paper-lanterns-harbour-lights-lyrics"));
        t.answer(2, 200, "<title>Paper Lanterns \xe2\x80\x93 Harbour Lights Lyrics | Genius Lyrics</title>"
                         "<div data-lyrics-container=\"true\">la<br>la</div>");
        QTRY_COMPARE(calls, 1);
        QCOMPARE(got.text, QStringLiteral("la\nla"));
        QCOMPARE(got.source, QStringLiteral("Genius"));
        QCOMPARE(got.url, QUrl("https://genius.com/Paper-lanterns-harbour-lights-lyrics"));

        // Asked again, it answers from the cache without a request.
        f->find(query(), done);
        QCOMPARE(calls, 2);
        QCOMPARE(t.calls.size(), 3);
        delete f;
    }

    void instrumentalStopsTheChainAndIsCached() {
        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        LyricsResult got;
        int calls = 0;
        auto done = [&](const LyricsResult &r, const QString &) { got = r; ++calls; };
        f->find(query(), done);
        f->fireTimerForTest();
        QVariantMap rec = QJsonDocument::fromJson(
            lrclibRecord("Harbour Lights", "Paper Lanterns", 201, "", "")).object().toVariantMap();
        rec["instrumental"] = true;
        t.answer(0, 200, QJsonDocument::fromVariant(rec).toJson());
        QTRY_COMPARE(calls, 1);
        QVERIFY(got.instrumental);
        QVERIFY(got.text.isEmpty());
        QCOMPARE(t.calls.size(), 1);
        QVERIFY(!f->timerActiveForTest());

        got = {};
        f->find(query(), done);
        QCOMPARE(calls, 2);
        QVERIFY(got.instrumental);
        QCOMPARE(t.calls.size(), 1);
        delete f;
    }

    void refusalSkipsTheHostAndMissIsNotCached() {
        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        f->setProviders({std::make_shared<LrclibProvider>()});
        int calls = 0;
        QString err = QStringLiteral("unset");
        auto done = [&](const LyricsResult &r, const QString &e) { ++calls; err = e; QVERIFY(r.text.isEmpty()); };
        f->find(query(), done);
        f->fireTimerForTest();
        t.answer(0, 429, {}, "60");
        QTRY_COMPARE(calls, 1);
        QCOMPARE(err, QString());
        QCOMPARE(f->pacing().blockedUntil(QStringLiteral("lrclib.net")), m_now + 60'000);

        // Still blocked: the next lookup sends nothing, and the earlier miss
        // was not cached, because the host never really answered.
        f->find(query(), done);
        f->fireTimerForTest();
        QTRY_COMPARE(calls, 2);
        QCOMPARE(t.calls.size(), 1);

        // After the pause the host is asked again.
        m_now += 60'000;
        f->find(query(), done);
        f->fireTimerForTest();
        QCOMPARE(t.calls.size(), 2);
        delete f;
    }

    void challengeCountsAsRefusal() {
        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        f->setProviders({std::make_shared<GeniusProvider>()});
        int calls = 0;
        f->find(query(), [&](const LyricsResult &, const QString &) { ++calls; });
        f->fireTimerForTest();
        t.answer(0, 200, "<title>Just a moment...</title>");
        QTRY_COMPARE(calls, 1);
        QVERIFY(f->pacing().blocked(QStringLiteral("genius.com"), m_now));
        delete f;
    }

    void fullMissIsCached() {
        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        f->setProviders({std::make_shared<LrclibProvider>()});
        int calls = 0;
        auto done = [&](const LyricsResult &, const QString &) { ++calls; };
        f->find(query(), done);
        f->fireTimerForTest();
        t.answer(0, 404);
        QVERIFY(QTest::qWaitFor([&] { return f->timerActiveForTest(); }));
        m_now += HostPacing::kMinIntervalMs;
        f->fireTimerForTest();
        t.answer(1, 200, "[]");
        QTRY_COMPARE(calls, 1);
        f->find(query(), done);
        QCOMPARE(calls, 2);                      // from the cache, at once
        QCOMPARE(t.calls.size(), 2);
        delete f;
    }

    void newerLookupAbortsTheOlder() {
        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        int oldCalls = 0;
        f->find(query(1), [&](const LyricsResult &, const QString &) { ++oldCalls; });
        f->fireTimerForTest();
        QCOMPARE(t.calls.size(), 1);
        f->find(query(2), [](const LyricsResult &, const QString &) {});
        QVERIFY(t.calls[0].aborted);
        QVERIFY(!f->pacing().busy(QStringLiteral("lrclib.net")));
        QCOMPARE(oldCalls, 0);
        delete f;
    }

    void switchedOffMidLookupSendsNothingMore() {
        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        QString err;
        f->find(query(), [&](const LyricsResult &, const QString &e) { err = e; });
        on = false;
        f->fireTimerForTest();
        QCOMPARE(t.calls.size(), 0);
        QCOMPARE(err, QStringLiteral("off"));
        delete f;
    }

    // What NowPlayingPage hands over is a track map; the bridge makes the query.
    void bridgeAsksTheFinderWithTheTrack() {
        TidalClient client(nullptr);
        QJSEngine engine;
        auto *bridge = new TidalBridge(&client);
        engine.globalObject().setProperty(QStringLiteral("bridge"), engine.newQObject(bridge));

        engine.evaluate(QStringLiteral(
            "var got = null; bridge.findLyrics({id: 9, title: 'Harbour Lights'}, "
            "function(r, e) { got = e })"));
        QCOMPARE(engine.globalObject().property("got").toString(), QStringLiteral("off"));

        FakeTransport t;
        bool on = true;
        LyricsFinder *f = makeFinder(&t, &on);
        f->setProviders({std::make_shared<LrclibProvider>()});
        bridge->setLyricsFinder(f);
        engine.evaluate(QStringLiteral(
            "got = null; bridge.findLyrics({id: 9, title: 'Harbour Lights', "
            "artistList: [{id: 1, name: 'Paper Lanterns'}], albumTitle: 'Night Ferry', "
            "duration: 201}, function(r, e) { got = [r.text, r.timed, r.source, r.url, e] })"));
        f->fireTimerForTest();
        QCOMPARE(t.calls.size(), 1);
        const QUrlQuery uq(t.calls[0].url);
        QCOMPARE(uq.queryItemValue("artist_name", QUrl::FullyDecoded), QStringLiteral("Paper Lanterns"));
        QCOMPARE(uq.queryItemValue("track_name", QUrl::FullyDecoded), QStringLiteral("Harbour Lights"));
        QCOMPARE(uq.queryItemValue("duration"), QStringLiteral("201"));
        t.answer(0, 200, lrclibRecord("Harbour Lights", "Paper Lanterns", 201, "[00:01.00]one", ""));
        QTRY_VERIFY(engine.globalObject().property("got").isArray());
        const QVariantList got = engine.globalObject().property("got").toVariant().toList();
        QCOMPARE(got.value(0).toString(), QStringLiteral("[00:01.00]one"));
        QCOMPARE(got.value(1).toBool(), true);
        QCOMPARE(got.value(2).toString(), QStringLiteral("LRCLIB"));
        QCOMPARE(got.value(3).toString(), QStringLiteral("https://lrclib.net/"));
        QCOMPARE(got.value(4).toString(), QString());

        // An instrumental reaches the page as such.
        QVariantMap rec = QJsonDocument::fromJson(
            lrclibRecord("Harbour Lights", "Paper Lanterns", 201, "", "")).object().toVariantMap();
        rec["instrumental"] = true;
        engine.evaluate(QStringLiteral(
            "got = null; bridge.findLyrics({id: 10, title: 'Harbour Lights', "
            "artistList: [{id: 1, name: 'Paper Lanterns'}], duration: 201}, "
            "function(r, e) { got = r.instrumental })"));
        m_now += HostPacing::kMinIntervalMs;
        f->fireTimerForTest();
        t.answer(1, 200, QJsonDocument::fromVariant(rec).toJson());
        QTRY_VERIFY(engine.globalObject().property("got").isBool());
        QVERIFY(engine.globalObject().property("got").toBool());
        delete f;
    }

    void transportMakesNoNetworkUntilAsked() {
        NetworkLyricsTransport t;
        QVERIFY(!t.hasNetwork());
    }
};

QTEST_GUILESS_MAIN(TestLyrics)
#include "tst_lyrics.moc"
