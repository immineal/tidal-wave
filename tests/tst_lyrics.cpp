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
    }

    void durations() {
        QVERIFY(lyrics::durationMatches(200, 203));
        QVERIFY(!lyrics::durationMatches(200, 203.5));
        QVERIFY(lyrics::durationMatches(200, 0));     // the source gave none
        QVERIFY(lyrics::durationMatches(0, 500));
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
        arr.append(QJsonDocument::fromJson(lrclibRecord("Harbour Lights", "Paper Lanterns", 200, "", "plain")).object());
        arr.append(QJsonDocument::fromJson(lrclibRecord("Harbour Lights", "Someone Unrelated", 201, "[00:01.00]x", "")).object());
        const LyricsStep r = p.next(q, search, {200, QJsonDocument(arr).toJson(), {}});
        QCOMPARE(r.kind, LyricsStep::Found);
        QCOMPARE(r.result.text, QStringLiteral("plain"));
        QVERIFY(!r.result.timed);

        QCOMPARE(p.next(q, search, {200, "[]", {}}).kind, LyricsStep::Miss);
        QCOMPARE(p.next(q, get, {500, {}, {}}).kind, LyricsStep::Failed);
    }

    void lrclibSkipsInstrumentals() {
        LyricsResult r;
        QVariantMap rec = QJsonDocument::fromJson(
            lrclibRecord("Harbour Lights", "Paper Lanterns", 201, "", "x")).object().toVariantMap();
        rec["instrumental"] = true;
        QVERIFY(!LrclibProvider::fromRecord(query(), rec, &r));
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

    void geniusSearchPicksTheMatchingHit() {
        auto hit = [](const QString &title, const QString &artist, const QString &url) {
            return QJsonObject{{"type", "song"}, {"result", QJsonObject{
                {"title", title}, {"primary_artist", QJsonObject{{"name", artist}}},
                {"artist_names", artist}, {"url", url}, {"lyrics_state", "complete"}}}};
        };
        QJsonArray hits{hit("Harbour Lights (Translation)", "Genius Translations", "https://genius.com/a"),
                        hit("Harbour Lights", "Other Band", "https://genius.com/b"),
                        hit("Harbour Lights", "Paper Lanterns", "https://genius.com/c")};
        const QJsonObject root{{"response", QJsonObject{{"sections", QJsonArray{
            QJsonObject{{"type", "song"}, {"hits", hits}}}}}}};
        const QByteArray json = QJsonDocument(root).toJson();
        QCOMPARE(GeniusProvider::pickHit(query(), json), QUrl("https://genius.com/c"));

        GeniusProvider p;
        const LyricsStep s = p.start(query());
        QCOMPARE(s.url.host(), QStringLiteral("genius.com"));
        const LyricsStep page = p.next(query(), s, {200, json, {}});
        QCOMPARE(page.kind, LyricsStep::Request);
        QCOMPARE(page.url, QUrl("https://genius.com/c"));
        QCOMPARE(p.next(query(), page, {200, "<html></html>", {}}).kind, LyricsStep::Miss);
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
        // Genius is another host, so no wait.
        QTRY_COMPARE(t.calls.size(), 3);
        QCOMPARE(t.calls[2].url.host(), QStringLiteral("genius.com"));
        const QJsonObject res{{"response", QJsonObject{{"sections", QJsonArray{QJsonObject{{"hits", QJsonArray{
            QJsonObject{{"result", QJsonObject{{"title", "Harbour Lights"},
                {"primary_artist", QJsonObject{{"name", "Paper Lanterns"}}},
                {"url", "https://genius.com/Paper-lanterns-harbour-lights-lyrics"}}}}}}}}}}}};
        t.answer(2, 200, QJsonDocument(res).toJson());
        QVERIFY(QTest::qWaitFor([&] { return f->timerActiveForTest(); }));
        m_now += HostPacing::kMinIntervalMs;
        f->fireTimerForTest();
        QCOMPARE(t.calls.size(), 4);
        t.answer(3, 200, "<div data-lyrics-container=\"true\">la<br>la</div>");
        QTRY_COMPARE(calls, 1);
        QCOMPARE(got.text, QStringLiteral("la\nla"));
        QCOMPARE(got.source, QStringLiteral("Genius"));
        QCOMPARE(got.url, QUrl("https://genius.com/Paper-lanterns-harbour-lights-lyrics"));

        // Asked again, it answers from the cache without a request.
        f->find(query(), done);
        QCOMPARE(calls, 2);
        QCOMPARE(t.calls.size(), 4);
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
        delete f;
    }

    void transportMakesNoNetworkUntilAsked() {
        NetworkLyricsTransport t;
        QVERIFY(!t.hasNetwork());
    }
};

QTEST_GUILESS_MAIN(TestLyrics)
#include "tst_lyrics.moc"
