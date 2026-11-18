// What the main window costs where the app should feel quick: switching tabs,
// opening the queue, opening pages and going back, scrolling long lists, and
// the first Home frame. The whole window runs on the test stubs, filled with
// the invented library of BenchLibrary.h; the sidebar's index is the real one.
// TW_BENCH_PRINT=1 prints the timings. Without it only what is counted is
// checked (what a step builds and asks for), which no machine's speed moves.

#include <QTest>
#include <QElapsedTimer>
#include <QPointer>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSet>
#include <QSettings>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>

#include <algorithm>
#include <functional>
#include <memory>

#include "BenchLibrary.h"
#include "TestStubs.h"
#include "api/TidalBridge.h"
#include "ui/Application.h"
#include "ui/PinStore.h"

using namespace Tidal;
using namespace bench;

namespace {

constexpr qint64 kUid = 4242;

double ms(qint64 ns) { return double(ns) / 1e6; }

// ── the stubs' data, in the shapes the real bridge hands over ─────────────
QVariantMap artistMap(const Artist &a) {
    return {{QStringLiteral("id"), a.id}, {QStringLiteral("name"), a.name},
            {QStringLiteral("coverUrl"), a.picture}, {QStringLiteral("coverUrl480"), a.picture}};
}
QVariantMap playlistMap(const Playlist &p) {
    return {{QStringLiteral("uuid"), p.uuid}, {QStringLiteral("title"), p.title},
            {QStringLiteral("description"), QString()}, {QStringLiteral("numTracks"), p.numTracks},
            {QStringLiteral("duration"), p.duration}, {QStringLiteral("coverUrl"), p.image},
            {QStringLiteral("type"), p.type}, {QStringLiteral("editable"), true}};
}
QVariantMap mixMap(const Mix &m) {
    return {{QStringLiteral("id"), m.id}, {QStringLiteral("title"), m.title},
            {QStringLiteral("subtitle"), m.subTitle}, {QStringLiteral("coverUrl"), m.cover},
            {QStringLiteral("mixType"), m.mixType}};
}
QVariantList tracksOf(const QList<Track> &list) {
    QVariantList out;
    out.reserve(list.size());
    for (const Track &t : list) out << TidalBridge::trackToMap(t);
    return out;
}

// A Home feed as the bridge parses one: `rows` rows of twelve cards, of the
// kinds Tidal's rows hold, plus the favourite rows it places itself.
QVariantMap feedOf(const Library &L, const QString &prefix, int rows, int seed) {
    QVariantList modules;
    static const char *const kinds[] = {"album", "playlist", "mix", "album", "artist", "album"};
    for (int r = 0; r < rows; ++r) {
        const QString kind = QLatin1String(kinds[r % 6]);
        QVariantList items;
        for (int i = 0; i < 12; ++i) {
            const int k = (seed * 131 + r * 12 + i) % 997;
            QVariantMap it;
            it[QStringLiteral("kind")] = kind;
            if (kind == QLatin1String("album")) {
                const Album &a = L.albums.at(k);
                it[QStringLiteral("id")] = a.id;
                it[QStringLiteral("title")] = a.title;
                it[QStringLiteral("artists")] = a.artists.first().name;
                it[QStringLiteral("coverUrl")] = QStringLiteral("%1-%2").arg(prefix).arg(a.cover);
            } else if (kind == QLatin1String("playlist")) {
                const Playlist &p = L.playlists.at(k % L.playlists.size());
                it[QStringLiteral("uuid")] = p.uuid + prefix;
                it[QStringLiteral("title")] = p.title;
                it[QStringLiteral("numTracks")] = p.numTracks;
                it[QStringLiteral("coverUrl")] = QStringLiteral("%1-%2").arg(prefix, p.image);
            } else if (kind == QLatin1String("mix")) {
                const Mix &m = L.mixes.at(k % L.mixes.size());
                it[QStringLiteral("id")] = m.id + prefix;
                it[QStringLiteral("title")] = m.title;
                it[QStringLiteral("subtitle")] = m.subTitle;
                it[QStringLiteral("coverUrl")] = QStringLiteral("%1-%2").arg(prefix, m.cover);
            } else {
                const Artist &a = L.artists.at(k % L.artists.size());
                it[QStringLiteral("id")] = a.id;
                it[QStringLiteral("name")] = a.name;
                it[QStringLiteral("coverUrl")] = QStringLiteral("%1-%2").arg(prefix, a.picture);
            }
            items << it;
        }
        modules << QVariantMap{{QStringLiteral("id"), QStringLiteral("%1_ROW_%2").arg(prefix).arg(r)},
                               {QStringLiteral("title"), QStringLiteral("Row %1 of %2").arg(r).arg(prefix)},
                               {QStringLiteral("context"), QString()}, {QStringLiteral("ownRow"), QString()},
                               {QStringLiteral("mediaType"), kind}, {QStringLiteral("items"), items}};
        if (r == 2) modules << QVariantMap{{QStringLiteral("id"), QStringLiteral("ARTISTS")},
                                           {QStringLiteral("ownRow"), QStringLiteral("artists")}};
        if (r == 4) modules << QVariantMap{{QStringLiteral("id"), QStringLiteral("PLAYLISTS")},
                                           {QStringLiteral("ownRow"), QStringLiteral("playlists")}};
    }
    const QVariantList tabs = {
        QVariantMap{{QStringLiteral("name"), QStringLiteral("For You")}, {QStringLiteral("feed"), QStringLiteral("static")}},
        QVariantMap{{QStringLiteral("name"), QStringLiteral("Staff Picks")}, {QStringLiteral("feed"), QStringLiteral("editorial")}},
    };
    return {{QStringLiteral("tabs"), tabs}, {QStringLiteral("modules"), modules},
            {QStringLiteral("fetchedAt"), 0}};
}

// Every item in the scene, by address, so a step can say what it built.
void collect(QQuickItem *from, QSet<QQuickItem *> &into) {
    into.insert(from);
    for (QQuickItem *kid : from->childItems()) collect(kid, into);
}

struct Step {
    QString what;
    double action = 0;      // the call itself, with every binding it ran
    double first = 0;       // the frame after it
    double settled = 0;     // to the frame with every cover in
    double worst = 0;       // the longest frame of any animation that followed
    int    frames = 0;      // frames drawn while it ran
    int    slow = 0;        // of those, over 16 ms
    int    built = 0;       // items that were not in the scene before
    int    covers = 0;      // cover requests the step made
    double total() const { return action + first; }
};

} // namespace

class TestUiPerf : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;
    Library L;
    std::unique_ptr<PinStore>     m_pins;
    std::unique_ptr<BenchLibrary> m_library;
    std::unique_ptr<QQmlEngine>   m_engine;
    std::unique_ptr<QQuickWindow> m_win;
    TestStubs m_stubs;
    bool m_print = false;
    QHash<int, double> m_queueOpen;
    double m_idle = 0;
    QList<Step> m_steps;

    QImage grab() { return m_win->grabWindow(); }

    // Runs `js` in the main window's own scope, where its ids are.
    QVariant eval(const QString &js) {
        QQmlExpression e(qmlContext(m_win.get()), m_win.get(), js);
        const QVariant v = e.evaluate();
        if (e.hasError()) qWarning() << js << e.error();
        return v;
    }

    double frame() {
        QElapsedTimer t;
        t.start();
        grab();
        return ms(t.nsecsElapsed());
    }

    // Lets queued work and image replies land, frame by frame, until nothing
    // is asked for any more and `done` holds (or 3 s pass). Each frame is
    // timed with the event processing before it, which is where animation
    // ticks and callLater work run.
    void run(Step &s, const std::function<bool()> &done, int minMs = 0) {
        QElapsedTimer all;
        all.start();
        int quiet = 0, lastCovers = -1;
        while (all.elapsed() < 3000) {
            QElapsedTimer t;
            t.start();
            QCoreApplication::processEvents();
            grab();
            const double f = ms(t.nsecsElapsed());
            ++s.frames;
            s.worst = std::max(s.worst, f);
            if (f > 16.0) ++s.slow;
            const int c = g_imageRequests;
            quiet = (c == lastCovers) ? quiet + 1 : 0;
            lastCovers = c;
            if (quiet >= 3 && done() && all.elapsed() >= minMs) break;
            QTest::qWait(1);
        }
        s.settled = ms(all.nsecsElapsed());
    }

    Step measure(const QString &what, const std::function<void()> &action,
                 const std::function<bool()> &done = [] { return true; }, int minMs = 0) {
        QCoreApplication::processEvents();
        grab();
        QSet<QQuickItem *> before;
        collect(m_win->contentItem(), before);
        g_imageRequests = 0;
        Step s;
        s.what = what;
        QElapsedTimer t;
        t.start();
        action();
        s.action = ms(t.nsecsElapsed());
        s.first = frame();
        QSet<QQuickItem *> after;
        collect(m_win->contentItem(), after);
        run(s, done, minMs);
        collect(m_win->contentItem(), after);
        for (QQuickItem *i : std::as_const(after)) if (!before.contains(i)) ++s.built;
        s.covers = g_imageRequests;
        m_steps << s;
        if (m_print)
            qInfo().noquote() << QStringLiteral("  %1 %2 %3 %4 %5 %6 %7 %8 %9")
                .arg(s.what, -34).arg(s.action, 8, 'f', 1).arg(s.first, 7, 'f', 1)
                .arg(s.total(), 7, 'f', 1).arg(s.worst, 7, 'f', 1)
                .arg(QStringLiteral("%1/%2").arg(s.slow).arg(s.frames), 7)
                .arg(s.built, 6).arg(s.covers, 6).arg(s.settled, 7, 'f', 0);
        return s;
    }

    void header(const QString &title) {
        if (!m_print) return;
        qInfo().noquote() << QStringLiteral("\n%1 (idle frame %2 ms)").arg(title).arg(m_idle, 0, 'f', 1);
        qInfo().noquote() << QStringLiteral("  %1 %2 %3 %4 %5 %6 %7 %8 %9")
            .arg(QStringLiteral("step"), -34).arg(QStringLiteral("action"), 8)
            .arg(QStringLiteral("frame"), 7).arg(QStringLiteral("total"), 7)
            .arg(QStringLiteral("worst"), 7).arg(QStringLiteral("slow"), 7)
            .arg(QStringLiteral("built"), 6).arg(QStringLiteral("covers"), 6)
            .arg(QStringLiteral("settle"), 7);
    }

    // A flick: `px` a frame, `n` frames, each timed with the work it caused.
    static QQuickItem *visibleNamed(QQuickItem *from, const QString &name) {
        if (!from || !from->isVisible()) return nullptr;
        if (from->objectName() == name) return from;
        for (QQuickItem *kid : from->childItems())
            if (QQuickItem *found = visibleNamed(kid, name)) return found;
        return nullptr;
    }

    void scroll(const QString &what, const QString &viewName, int px, int n) {
        scroll(what, visibleNamed(m_win->contentItem(), viewName), px, n);
    }
    void scroll(const QString &what, QQuickItem *view, int px, int n) {
        QVERIFY2(view, qPrintable(what));
        view->setProperty("contentY", view->property("originY"));
        QCoreApplication::processEvents();
        grab();
        QList<double> f;
        QSet<QQuickItem *> before;
        collect(m_win->contentItem(), before);
        g_imageRequests = 0;
        for (int i = 0; i < n; ++i) {
            QElapsedTimer t;
            t.start();
            const double maxY = view->property("originY").toDouble()
                                + view->property("contentHeight").toDouble()
                                - view->property("height").toDouble();
            view->setProperty("contentY", std::min(maxY, view->property("contentY").toDouble() + px));
            QCoreApplication::processEvents();
            grab();
            f << ms(t.nsecsElapsed());
        }
        QSet<QQuickItem *> after;
        collect(m_win->contentItem(), after);
        int built = 0;
        for (QQuickItem *i : std::as_const(after)) if (!before.contains(i)) ++built;
        std::sort(f.begin(), f.end());
        const int slow = int(std::count_if(f.begin(), f.end(), [](double v) { return v > 16.0; }));
        if (m_print)
            qInfo().noquote() << QStringLiteral("  %1 median %2  p95 %3  worst %4  slow %5/%6  built %7  covers %8")
                .arg(what, -34).arg(f[f.size() / 2], 5, 'f', 1).arg(f[f.size() * 95 / 100], 5, 'f', 1)
                .arg(f.last(), 5, 'f', 1).arg(slow).arg(n).arg(built).arg(int(g_imageRequests));
        view->setProperty("contentY", view->property("originY"));
        QCoreApplication::processEvents();
    }

    void navigate(const QString &page, const QString &params = QStringLiteral("{}")) {
        eval(QStringLiteral("navigate('%1', %2)").arg(page, params));
    }

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_ui_perf"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
        qputenv("HOME", m_dir.path().toUtf8());
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedKingdom));
        m_print = qEnvironmentVariableIntValue("TW_BENCH_PRINT") != 0;

        L = makeLibrary();
        m_pins = std::make_unique<PinStore>();
        m_pins->setUserId(kUid);
        m_library = std::make_unique<BenchLibrary>(L, m_pins.get());
        m_library->setUserId(kUid);
        m_library->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!m_library->loading() && !m_library->indexing(), 60000);

        // As the app collects: whole-heap, so a collection's pause is in the timings.
        Application::useWholeHeapQmlCollector();
        m_engine = std::make_unique<QQmlEngine>();
        m_stubs = installTestStubs(m_engine.get(), this);
        m_engine->rootContext()->setContextProperty(QStringLiteral("library"), m_library.get());
        m_engine->removeImageProvider(QStringLiteral("tidal"));
        m_engine->addImageProvider(QStringLiteral("tidal"), new CountingImages);

        StubBridge *b = m_stubs.bridge;
        QVariantList albums, artists, playlists, mixes;
        for (const Album &a : std::as_const(L.albums)) albums << TidalBridge::albumToMap(a);
        for (const Artist &a : std::as_const(L.artists)) artists << artistMap(a);
        for (const Playlist &p : std::as_const(L.playlists)) playlists << playlistMap(p);
        for (const Mix &m : std::as_const(L.mixes)) mixes << mixMap(m);
        b->setFavoriteAlbumsForTest(albums);
        b->setFavoriteArtistsForTest(artists);
        b->setUserPlaylistsForTest(playlists);
        b->setFavoriteTracksListForTest(tracksOf(L.likes));
        b->setHomeMixesForTest(mixes);
        b->setHomeFeedForTest(QStringLiteral("static"), feedOf(L, QStringLiteral("fy"), 10, 1));
        b->setHomeFeedForTest(QStringLiteral("editorial"), feedOf(L, QStringLiteral("sp"), 10, 2));
        // One album, one artist and one long playlist for the pages.
        const Album &album = L.albums.at(7);
        b->setAlbumForTest(TidalBridge::albumToMap(album), tracksOf(L.tracklists.value(album.id)));
        QVariantList artistAlbums;
        for (int i = 0; i < 60; ++i) artistAlbums << albums.at(i * 7);
        b->setArtistForTest(artistMap(L.artists.at(3)), tracksOf(L.likes.mid(0, 10)), artistAlbums);
        b->setPlaylistTracksForTest(tracksOf(L.likes));
        m_stubs.auth->setStateForTest(StubAuth::State::LoggedIn);

        // Loaded by its URL, as the app loads it, so its ids are in reach.
        QQmlComponent host(m_engine.get(), QUrl(QStringLiteral("qrc:/qt/qml/TidalWave/qml/Main.qml")));
        if (host.isError()) qWarning() << host.errors();
        QVERIFY(!host.isError());

        // Startup: the window built and its first frame, Home with its rows.
        QElapsedTimer t;
        t.start();
        std::unique_ptr<QObject> root(host.create());
        const double built = ms(t.nsecsElapsed());
        QVERIFY(qobject_cast<QQuickWindow *>(root.get()));
        m_win.reset(static_cast<QQuickWindow *>(root.release()));
        m_win->resize(1400, 900);
        m_win->show();
        t.restart();
        grab();
        const double first = ms(t.nsecsElapsed());
        QVERIFY(QTest::qWaitForWindowExposed(m_win.get(), 5000));
        QTRY_VERIFY_WITH_TIMEOUT(eval(QStringLiteral("homeLoader.item && homeLoader.item.feedRuns[0].length > 0")).toBool(), 10000);
        if (m_print)
            qInfo().noquote() << QStringLiteral("\nStartup: window built %1 ms, first frame %2 ms, %3 ms in all")
                .arg(built, 0, 'f', 1).arg(first, 0, 'f', 1).arg(built + first, 0, 'f', 1);

        for (int i = 0; i < 10; ++i) { QTest::qWait(10); grab(); }
        QList<double> idle;
        for (int i = 0; i < 9; ++i) idle << frame();
        std::sort(idle.begin(), idle.end());
        m_idle = idle[idle.size() / 2];
    }

    void cleanupTestCase() {
        m_win.reset();
        m_engine.reset();
    }

    // ── Home's two feeds ─────────────────────────────────────────────────
    void home_tabs() {
        navigate(QStringLiteral("home"));
        header(QStringLiteral("Home tabs"));
        const auto onStaff = [this] { return eval(QStringLiteral("homeLoader.item.onStaffPicks")).toBool(); };
        Step a = measure(QStringLiteral("For you -> Staff picks (first)"),
                         [this] { eval(QStringLiteral("homeLoader.item.showFeedTab(1)")); }, onStaff);
        Step b = measure(QStringLiteral("Staff picks -> For you"),
                         [this] { eval(QStringLiteral("homeLoader.item.showFeedTab(0)")); },
                         [&] { return !onStaff(); });
        Step c = measure(QStringLiteral("For you -> Staff picks"),
                         [this] { eval(QStringLiteral("homeLoader.item.showFeedTab(1)")); }, onStaff);
        Step d = measure(QStringLiteral("Staff picks -> For you"),
                         [this] { eval(QStringLiteral("homeLoader.item.showFeedTab(0)")); },
                         [&] { return !onStaff(); });
        Q_UNUSED(a);
        // Both feeds seen once, a switch shows what is there: nothing is
        // built again and no cover is asked for again.
        for (const Step &s : {b, c, d}) {
            QVERIFY2(s.built == 0, qPrintable(QStringLiteral("%1 built %2 items").arg(s.what).arg(s.built)));
            QVERIFY2(s.covers == 0, qPrintable(QStringLiteral("%1 asked for %2 covers").arg(s.what).arg(s.covers)));
        }
    }

    // ── Collection's five tabs ───────────────────────────────────────────
    void collection_tabs() {
        header(QStringLiteral("Collection tabs"));
        measure(QStringLiteral("Home -> Collection (first)"), [this] { navigate(QStringLiteral("collection")); });
        static const char *const names[] = {"tracks", "albums", "artists", "playlists", "mixes"};
        for (int round = 0; round < 2; ++round)
            for (int tab : {1, 2, 3, 4, 0}) {
                measure(QStringLiteral("-> %1%2").arg(QLatin1String(names[tab]),
                                                      round == 0 ? QStringLiteral(" (first)") : QString()),
                        [this, tab] { eval(QStringLiteral("collectionLoader.item.activeTab = %1").arg(tab)); });
            }
        measure(QStringLiteral("Collection -> Home"), [this] { navigate(QStringLiteral("home")); });
        measure(QStringLiteral("Home -> Collection"), [this] { navigate(QStringLiteral("collection")); });
    }

    // ── Search's result tabs ─────────────────────────────────────────────
    void search_tabs() {
        QVariantList tracks = tracksOf(L.likes.mid(0, 50)), albums, artists, playlists;
        for (int i = 0; i < 50; ++i) {
            albums << TidalBridge::albumToMap(L.albums.at(i * 3));
            artists << artistMap(L.artists.at(i * 3));
            playlists << playlistMap(L.playlists.at(i));
        }
        m_stubs.bridge->setSearchResultsForTest(tracks, albums, artists, playlists);
        header(QStringLiteral("Search tabs"));
        measure(QStringLiteral("Home -> Search"), [this] { navigate(QStringLiteral("search")); });
        measure(QStringLiteral("search \"the\""), [this] { eval(QStringLiteral("searchLoader.item.searchFor('the')")); });
        static const char *const names[] = {"all", "tracks", "albums", "artists", "playlists", "mixes"};
        for (int round = 0; round < 2; ++round)
            for (int tab : {1, 2, 3, 4, 5, 0})
                measure(QStringLiteral("-> %1%2").arg(QLatin1String(names[tab]),
                                                      round == 0 ? QStringLiteral(" (first)") : QString()),
                        [this, tab] { eval(QStringLiteral("searchLoader.item.activeTab = %1").arg(tab)); });
        navigate(QStringLiteral("home"));
    }

    // ── the queue panel ──────────────────────────────────────────────────
    void queue_panel_data() {
        QTest::addColumn<int>("size");
        QTest::newRow("500") << 500;
        QTest::newRow("6000") << 6000;
    }
    void queue_panel() {
        QFETCH(int, size);
        m_stubs.player->setQueueForTest(tracksOf(L.likes.mid(0, size)), size / 3);
        header(QStringLiteral("Queue panel, %1 tracks").arg(size));
        const auto openness = [this] { return eval(QStringLiteral("queuePanel.openness")).toDouble(); };
        auto *list = eval(QStringLiteral("queuePanel.queueList")).value<QObject *>();
        QVERIFY(list);
        for (int i = 0; i < 2; ++i) {
            QSignalSpy resets(list, SIGNAL(modelChanged()));
            const Step open = measure(QStringLiteral("open"), [this] { eval(QStringLiteral("queueOpen = true")); },
                                      [&] { return openness() >= 1; });
            m_queueOpen[size] = qMin(m_queueOpen.value(size, 1e9), open.action);
            // Each new count rebuilds every row in view, so opening must
            // give the list its count once.
            QCOMPARE(resets.count(), 1);
            measure(QStringLiteral("close"), [this] { eval(QStringLiteral("queueOpen = false")); },
                    [&] { return openness() <= 0; });
        }
        // Only the rows in view are made, so a long queue opens as fast as a
        // short one. Timed, so checked on request only.
        if (size == 6000 && qEnvironmentVariableIntValue("TW_BENCH_ASSERT"))
            QVERIFY2(m_queueOpen[6000] < m_queueOpen[500] + 30,
                     qPrintable(QStringLiteral("6000 rows open in %1 ms, 500 in %2")
                                .arg(m_queueOpen[6000]).arg(m_queueOpen[500])));
    }

    // ── pages, and back ──────────────────────────────────────────────────
    void pages() {
        navigate(QStringLiteral("home"));
        header(QStringLiteral("Pages"));
        const Album &album = L.albums.at(7);
        measure(QStringLiteral("Home -> album"),
                [&] { navigate(QStringLiteral("album"), QStringLiteral("{ albumId: %1 }").arg(album.id)); });
        measure(QStringLiteral("album -> back"), [this] { eval(QStringLiteral("goBack()")); });
        measure(QStringLiteral("Home -> playlist (6000)"),
                [&] { navigate(QStringLiteral("playlist"),
                               QStringLiteral("{ playlistUuid: 'pl-3', playlistTitle: 'Long' }")); },
                [this] { return eval(QStringLiteral("detailView && detailView.item && detailView.item.tracks.length > 0")).toBool(); });
        measure(QStringLiteral("playlist -> back"), [this] { eval(QStringLiteral("goBack()")); });
        measure(QStringLiteral("Home -> artist"),
                [&] { navigate(QStringLiteral("artist"), QStringLiteral("{ artistId: %1 }").arg(L.artists.at(3).id)); });
        measure(QStringLiteral("artist -> back"), [this] { eval(QStringLiteral("goBack()")); });
        m_stubs.player->setCurrentTrackForTest(TidalBridge::trackToMap(L.likes.at(5)));
        measure(QStringLiteral("Home -> Now playing"), [this] { navigate(QStringLiteral("nowplaying")); },
                [this] { return eval(QStringLiteral("nowPlayingness")).toDouble() >= 1; });
        measure(QStringLiteral("Now playing -> back"), [this] { eval(QStringLiteral("goBack()")); },
                [this] { return eval(QStringLiteral("nowPlayingness")).toDouble() <= 0.001; });
    }

    // What one delegate of each heavy kind is made of. Printed only.
    void anatomy() {
        if (!m_print) QSKIP("printed with TW_BENCH_PRINT=1");
        const auto show = [this](const QString &what, QQuickItem *view) {
            QVERIFY2(view, qPrintable(what));
            QQuickItem *d = nullptr;
            for (QQuickItem *kid : view->property("contentItem").value<QQuickItem *>()->childItems())
                if (kid->isVisible() && kid->height() > 20) { d = kid; break; }
            QVERIFY(d);
            QSet<QQuickItem *> all;
            collect(d, all);
            QHash<QString, int> by;
            for (QQuickItem *i : std::as_const(all)) ++by[QString::fromLatin1(i->metaObject()->className())];
            QStringList parts;
            for (auto it = by.cbegin(); it != by.cend(); ++it) parts << QStringLiteral("%1 %2").arg(it.value()).arg(it.key());
            parts.sort();
            qInfo().noquote() << QStringLiteral("%1: %2 items: %3").arg(what).arg(all.size()).arg(parts.join(QStringLiteral(", ")));
        };
        navigate(QStringLiteral("collection"));
        eval(QStringLiteral("collectionLoader.item.activeTab = 0"));
        QTest::qWait(300);
        show(QStringLiteral("track row"), visibleNamed(m_win->contentItem(), QStringLiteral("collectionTracksList")));
        eval(QStringLiteral("collectionLoader.item.activeTab = 1"));
        QTest::qWait(300);
        show(QStringLiteral("album card"), visibleNamed(m_win->contentItem(), QStringLiteral("collectionAlbumsGrid")));
        m_stubs.player->setQueueForTest(tracksOf(L.likes.mid(0, 50)), 10);
        eval(QStringLiteral("queueOpen = true"));
        QTest::qWait(600);
        show(QStringLiteral("queue row"), visibleNamed(m_win->contentItem(), QStringLiteral("queuePanelList")));
        eval(QStringLiteral("queueOpen = false"));
        QTest::qWait(600);
        navigate(QStringLiteral("home"));
    }

    // ── flicking long lists ──────────────────────────────────────────────
    void scrolling() {
        header(QStringLiteral("Scrolling, 60 px a frame"));
        navigate(QStringLiteral("collection"));
        eval(QStringLiteral("collectionLoader.item.activeTab = 0"));
        QTest::qWait(400);
        scroll(QStringLiteral("liked tracks"), QStringLiteral("collectionTracksList"), 60, 120);
        eval(QStringLiteral("collectionLoader.item.activeTab = 1"));
        QTest::qWait(400);
        scroll(QStringLiteral("saved albums"), QStringLiteral("collectionAlbumsGrid"), 60, 120);
        eval(QStringLiteral("collectionLoader.item.activeTab = 2"));
        QTest::qWait(400);
        scroll(QStringLiteral("followed artists"), QStringLiteral("collectionArtistsGrid"), 60, 120);
        navigate(QStringLiteral("playlist"), QStringLiteral("{ playlistUuid: 'pl-4', playlistTitle: 'Long' }"));
        QTest::qWait(600);
        scroll(QStringLiteral("playlist of 6000"), QStringLiteral("playlistTracksList"), 60, 120);
        navigate(QStringLiteral("home"));
        QTest::qWait(400);
        scroll(QStringLiteral("Home"), eval(QStringLiteral(
            "(function () { var p = homeLoader.item; for (var i = 0; i < p.children.length; i++)"
            " { var c = p.children[i]; if (c.contentItem && c.contentItem.contentY !== undefined)"
            " return c.contentItem } return null })()")).value<QQuickItem *>(), 60, 60);
        m_stubs.player->setQueueForTest(tracksOf(L.likes), 2000);
        eval(QStringLiteral("queueOpen = true"));
        QTest::qWait(600);
        scroll(QStringLiteral("queue of 6000"), QStringLiteral("queuePanelList"), 60, 120);
        eval(QStringLiteral("queueOpen = false"));
        QTest::qWait(600);
    }
};

QTEST_MAIN(TestUiPerf)
#include "tst_ui_perf.moc"
