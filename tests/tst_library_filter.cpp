// What the Collection page's field matches on a large invented library, and
// what typing costs there and in the sidebar's finder, on the real bridge and
// index. TW_BENCH_PRINT=1 prints the timings; TW_BENCH_RUNS=n repeats them.

#include <QTest>
#include <QElapsedTimer>
#include <QPointer>
#include <QQmlComponent>
#include <QJsonArray>
#include <QJsonDocument>
#include <QQmlContext>
#include <QQmlExpression>
#include <QQmlEngine>
#include <QQuickAsyncImageProvider>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTimer>

#include <algorithm>
#include <atomic>
#include <functional>
#include <memory>

#include "TestStubs.h"
#include "api/LibraryIndex.h"
#include "api/TidalBridge.h"
#include "api/TidalClient.h"
#include "ui/Application.h"
#include "ui/PinStore.h"

using namespace Tidal;

namespace {

constexpr qint64 kUid = 4242;
constexpr int kAlbums = 1000, kArtists = 500, kPlaylists = 200, kMixes = 40;
constexpr int kTracksPerAlbum = 10, kLikedPerAlbum = 6;    // 6000 liked songs

// ── an invented library ─────────────────────────────────────────────────────
// Long titles, accents, mixed case and a sharp s, so folding and lower-casing
// have real work to do.
const QStringList kWords = {
    QStringLiteral("the"), QStringLiteral("The"), QStringLiteral("THE"), QStringLiteral("black"),
    QStringLiteral("Blue"), QStringLiteral("Böse"), QStringLiteral("Élan"), QStringLiteral("Straße"),
    QStringLiteral("Café"), QStringLiteral("Night"), QStringLiteral("Über"), QStringLiteral("Mañana"),
    QStringLiteral("Señor"), QStringLiteral("Ålborg"), QStringLiteral("Øre"), QStringLiteral("Zoë"),
    QStringLiteral("Sünde"), QStringLiteral("dark"), QStringLiteral("Side"), QStringLiteral("of"),
    QStringLiteral("Moon"), QStringLiteral("and"), QStringLiteral("Light"), QStringLiteral("Fire"),
    QStringLiteral("Wasser"), QStringLiteral("Lumière"), QStringLiteral("Noël"), QStringLiteral("Garçon"),
    QStringLiteral("Seele"), QStringLiteral("Herz"), QStringLiteral("Dämmerung"), QStringLiteral("Sterne"),
    QStringLiteral("Himmel"), QStringLiteral("Rêve"), QStringLiteral("Désir"), QStringLiteral("Ébène"),
    QStringLiteral("Kristall"), QStringLiteral("Glück"), QStringLiteral("Weiß"), QStringLiteral("Schön"),
    QStringLiteral("Hotel"), QStringLiteral("River"), QStringLiteral("Road"), QStringLiteral("Summer"),
    QStringLiteral("Winter"), QStringLiteral("Electric"), QStringLiteral("Golden"), QStringLiteral("Velvet"),
    QStringLiteral("Echo"), QStringLiteral("Mirror"), QStringLiteral("Ocean"), QStringLiteral("Storm"),
    QStringLiteral("blues"), QStringLiteral("BLUEBIRD"), QStringLiteral("Bluthochzeit"),
};
const QStringList kFirst = {
    QStringLiteral("Anna"), QStringLiteral("Björn"), QStringLiteral("Céline"), QStringLiteral("Dörte"),
    QStringLiteral("Émile"), QStringLiteral("Fátima"), QStringLiteral("Günther"), QStringLiteral("Hélène"),
    QStringLiteral("Ingrid"), QStringLiteral("José"), QStringLiteral("Kåre"), QStringLiteral("Léa"),
    QStringLiteral("Märta"), QStringLiteral("Noémie"), QStringLiteral("Øystein"), QStringLiteral("Renée"),
    QStringLiteral("Søren"), QStringLiteral("Thérèse"), QStringLiteral("Ümit"), QStringLiteral("Theo"),
};
const QStringList kLast = {
    QStringLiteral("Müller"), QStringLiteral("Ångström"), QStringLiteral("Dubois"), QStringLiteral("García"),
    QStringLiteral("Nørgaard"), QStringLiteral("Šimek"), QStringLiteral("Çelik"), QStringLiteral("Öztürk"),
    QStringLiteral("Brontë"), QStringLiteral("Lefèvre"), QStringLiteral("Navarro"), QStringLiteral("Schäfer"),
    QStringLiteral("Weiß"), QStringLiteral("Thompson"), QStringLiteral("Bluhm"), QStringLiteral("Bell"),
};
const QStringList kSuffixes = {
    QString(), QString(), QString(), QStringLiteral(" (Deluxe Edition)"),
    QStringLiteral(" (2011 Remaster)"), QStringLiteral(" - Live at the Royal Albert Hall"),
    QStringLiteral(" (Expanded 25th Anniversary Edition)"),
};

struct Rng {
    quint32 s = 12345;
    int operator()(int n) { s = s * 1664525u + 1013904223u; return int((s >> 8) % quint32(n)); }
};

QString words(Rng &r, int lo, int hi) {
    const int n = lo + r(hi - lo + 1);
    QStringList w;
    for (int i = 0; i < n; ++i) w << kWords[r(int(kWords.size()))];
    return w.join(QLatin1Char(' '));
}

struct Library {
    QList<Artist>   artists;
    QList<Album>    albums;      // newest saved first
    QList<Track>    likes;       // newest liked first
    QList<Playlist> playlists;
    QList<Mix>      mixes;
    QHash<qint64, QList<Track>> tracklists;
};

// Rows only the pinning cases look for: "quasar" and "quist" occur nowhere
// else. Spread through the lists, so the default order is tested too.
Artist pinArtist(qint64 id, const QString &name) {
    Artist a; a.id = id; a.name = name; a.picture = QStringLiteral("pinpic-%1").arg(id);
    return a;
}

void addPinRows(Library &L) {
    const Artist quist = pinArtist(290003, QStringLiteral("Nadia Quist"));
    const Artist band  = pinArtist(290000, QStringLiteral("Quasar Band"));
    const QList<Artist> artists = {
        band, pinArtist(290001, QStringLiteral("QUASAR BÄND")),
        pinArtist(290002, QStringLiteral("Quasar Bänd")), quist,
    };
    for (int k = 0; k < artists.size(); ++k) L.artists.insert(37 + k * 101, artists[k]);

    const QStringList titles = {
        QStringLiteral("Quasar Café"), QStringLiteral("QUASAR CAFE"),
        QStringLiteral("Quasar Café"), QStringLiteral("Quasarstraße"),
        QStringLiteral("QUASARSTRASSE"), QStringLiteral("Blue Hours"),
        QStringLiteral("Quasar  Doubles"), QStringLiteral("İstanbul Quasar"),
    };
    QList<Album> pins;
    for (int k = 0; k < titles.size(); ++k) {
        Album a;
        a.id = 390000 + k;
        a.title = titles[k];
        a.artists << (k == 5 ? band : quist);
        a.cover = QStringLiteral("pincov-%1").arg(k);
        a.numTracks = 1;
        a.releaseDate = QStringLiteral("2001-0%1-01").arg(k + 1);
        a.type = QStringLiteral("ALBUM");
        pins << a;
        L.albums.insert(3 + k * 97, a);
        Track t;
        t.id = 1900100 + k;
        t.title = QStringLiteral("Lied %1").arg(k);
        t.album = a;
        t.artists = a.artists;
        L.tracklists.insert(a.id, {t});
    }

    // Matched by title, by album and by artist.
    const QList<QPair<QString, int>> songs = {
        {QStringLiteral("Quasar Lied"), 5}, {QStringLiteral("Anderes"), 0},
        {QStringLiteral("Drittes"), 5},
    };
    for (int k = 0; k < songs.size(); ++k) {
        Track t;
        t.id = 1900000 + k;
        t.title = songs[k].first;
        t.album = k == 0 ? L.albums.at(500) : pins[songs[k].second];
        t.artists = k == 2 ? QList<Artist>{band} : QList<Artist>{L.artists.at(9)};
        t.duration = 200 + k;
        L.likes.insert(11 + k * 2400, t);
    }

    Playlist p;
    p.type = QStringLiteral("USER");
    p.numTracks = 3;
    p.uuid = QStringLiteral("pin-pl-0"); p.title = QStringLiteral("Quasar Abend");
    L.playlists.insert(10, p);
    p.uuid = QStringLiteral("pin-pl-1"); p.title = QStringLiteral("quasar abend");
    L.playlists.insert(150, p);

    Mix m;
    m.mixType = QStringLiteral("DISCOVERY_MIX");
    m.id = QStringLiteral("pin-mix-0"); m.title = QStringLiteral("Quasar Mix"); m.subTitle = QStringLiteral("Leute");
    L.mixes.insert(4, m);
    m.id = QStringLiteral("pin-mix-1"); m.title = QStringLiteral("Other Mix"); m.subTitle = QStringLiteral("Quasar Leute");
    L.mixes.insert(30, m);

    // Newest first, as the server lists them.
    const qint64 now = 1767225600000LL;
    for (int i = 0; i < L.albums.size(); ++i)    L.albums[i].addedAt    = now - qint64(i) * 3600000;
    for (int i = 0; i < L.artists.size(); ++i)   L.artists[i].addedAt   = now - qint64(i) * 3600000;
    for (int i = 0; i < L.likes.size(); ++i)     L.likes[i].addedAt     = now - qint64(i) * 60000;
    for (int i = 0; i < L.playlists.size(); ++i) L.playlists[i].addedAt = now - qint64(i) * 7200000;
}

Library makeLibrary() {
    Rng r;
    Library L;
    const qint64 now = 1767225600000LL;
    for (int i = 0; i < kArtists; ++i) {
        Artist a;
        a.id = 200000 + i;
        a.name = r(4) == 0 ? QStringLiteral("The ") + words(r, 1, 2)
                           : kFirst[r(int(kFirst.size()))] + QLatin1Char(' ') + kLast[r(int(kLast.size()))];
        a.picture = QStringLiteral("pic-%1").arg(i);
        a.addedAt = now - qint64(i) * 3600000;
        L.artists << a;
    }
    for (int i = 0; i < kAlbums; ++i) {
        Album a;
        a.id = 300000 + i;
        a.title = words(r, 2, 6) + kSuffixes[r(int(kSuffixes.size()))];
        a.artists << L.artists[r(kArtists)];
        if (r(5) == 0) a.artists << L.artists[r(kArtists)];
        a.cover = QStringLiteral("cov-%1").arg(i);
        a.numTracks = kTracksPerAlbum;
        a.releaseDate = QStringLiteral("%1-0%2-1%3").arg(1960 + r(65)).arg(1 + r(9)).arg(r(10));
        a.audioQuality = QStringLiteral("LOSSLESS");
        a.type = QStringLiteral("ALBUM");
        a.addedAt = now - qint64(i) * 3600000;
        L.albums << a;
        QList<Track> list;
        for (int k = 0; k < kTracksPerAlbum; ++k) {
            Track t;
            t.id = 1000000 + qint64(i) * 20 + k;
            t.title = words(r, 1, 5) + (r(6) == 0 ? QStringLiteral(" (Radio Edit)") : QString());
            t.album = a;
            t.artists = a.artists;
            t.duration = 120 + r(300);
            t.trackNumber = k + 1;
            t.audioQuality = QStringLiteral("LOSSLESS");
            t.isrc = QStringLiteral("XX%1").arg(t.id);
            list << t;
        }
        L.tracklists.insert(a.id, list);
    }
    // Likes spread over every album, newest first.
    for (int k = 0; k < kLikedPerAlbum; ++k)
        for (int i = 0; i < kAlbums; ++i) {
            Track t = L.tracklists.value(300000 + i).at(k);
            t.addedAt = now - qint64(L.likes.size()) * 60000;
            L.likes << t;
        }
    for (int i = 0; i < kPlaylists; ++i) {
        Playlist p;
        p.uuid = QStringLiteral("pl-%1").arg(i);
        p.title = words(r, 1, 5);
        p.numTracks = 5 + r(200);
        p.duration = p.numTracks * 200;
        p.image = QStringLiteral("img-%1").arg(i);
        p.type = QStringLiteral("USER");
        p.addedAt = now - qint64(i) * 7200000;
        L.playlists << p;
    }
    for (int i = 0; i < kMixes; ++i) {
        Mix m;
        m.id = QStringLiteral("mix-%1").arg(i);
        m.title = words(r, 1, 3) + QStringLiteral(" Mix");
        m.subTitle = L.artists[r(kArtists)].name + QStringLiteral(", ") + L.artists[r(kArtists)].name;
        m.cover = QStringLiteral("mixcov-%1").arg(i);
        m.mixType = QStringLiteral("DISCOVERY_MIX");
        L.mixes << m;
    }
    addPinRows(L);
    return L;
}

// TidalBridge's seam: the favourites answered from the invented library.
class BenchClient : public TidalClient {
public:
    explicit BenchClient(const Library &lib) : TidalClient(nullptr), L(lib) {}
    const Library &L;

    void fetchFavoriteTracksNewestFirst(TracksCallback cb, int limit, int offset) override {
        cb(L.likes.mid(offset, limit), QString());
    }
    void fetchFavoriteTracksByIndex(TracksCallback cb, int limit, int offset, bool) override {
        cb(L.likes.mid(offset, limit), QString());
    }
    void fetchFavoriteAlbums(AlbumsCallback cb, int limit, int offset) override {
        cb(L.albums.mid(offset, limit), QString());
    }
    void fetchFavoriteArtists(ArtistsCallback cb, int limit, int offset) override {
        cb(L.artists.mid(offset, limit), QString());
    }
    void fetchUserPlaylists(PlaylistsCallback cb, int limit, int offset) override {
        cb(L.playlists.mid(offset, limit), QString());
    }
    void fetchFavoritesHead(FavoriteKind kind, HeadCallback cb) override {
        FavoritesHead h;
        if (kind == FavoriteKind::Tracks) {
            h.total = int(L.likes.size());
            h.newest = QString::number(L.likes.first().id);
        } else if (kind == FavoriteKind::Albums) {
            h.total = int(L.albums.size());
            h.newest = QString::number(L.albums.first().id);
        } else if (kind == FavoriteKind::Artists) {
            h.total = int(L.artists.size());
            h.newest = QString::number(L.artists.first().id);
        }
        cb(h, QString());
    }
    void fetchFavoriteIds(FavoriteIdsCallback cb) override {
        FavoriteIds ids;
        for (const Track &t : L.likes) ids.tracks.insert(t.id);
        cb(ids, QString());
    }
    void fetchFavoriteMixes(MixesCallback cb) override { cb({}, QString()); }
    void fetchHomeMixes(MixesCallback cb) override { cb(L.mixes, QString()); }
    void fetchMixPage(const QString &, MixPageCallback cb) override { cb({}, {}, QStringLiteral("404")); }
    void fetchPlaylist(const QString &, std::function<void(Playlist, QString)> cb) override {
        cb({}, QStringLiteral("404"));
    }
    void fetchTrack(qint64, std::function<void(Track, QString)> cb) override {
        cb({}, QStringLiteral("404"));
    }
    void fetchStreamManifest(qint64, StreamCb) override {}
};

// LibraryIndex's seam, over the same library, tracklists included.
class BenchLibrary : public LibraryIndex {
public:
    BenchLibrary(const Library &lib, PinStore *pins) : LibraryIndex(nullptr, pins, nullptr), L(lib) {}
    const Library &L;

protected:
    void fetchPlaylistPage(int offset, int limit, PlaylistsCb cb) override { cb(L.playlists.mid(offset, limit), QString()); }
    void fetchAlbumPage(int offset, int limit, AlbumsCb cb) override { cb(L.albums.mid(offset, limit), QString()); }
    void fetchArtistPage(int offset, int limit, ArtistsCb cb) override { cb(L.artists.mid(offset, limit), QString()); }
    void fetchTrackPage(int offset, int limit, TracksCb cb) override { cb(L.likes.mid(offset, limit), QString()); }
    void fetchTrackIndexPage(int offset, int limit, TracksCb cb) override { cb(L.likes.mid(offset, limit), QString()); }
    void fetchMixList(MixesCb cb) override { cb(L.mixes, QString()); }
    void fetchAlbumTracklist(qint64 albumId, TracksCb cb) override { cb(L.tracklists.value(albumId), QString()); }
};

// Counts what the covers ask for. Answers asynchronously, as the app's
// provider does, with a tiny image.
std::atomic<int> g_imageRequests{0};

class CountingResponse : public QQuickImageResponse {
public:
    explicit CountingResponse(QSize s) : m_img(s.isValid() && !s.isEmpty() ? s : QSize(4, 4),
                                               QImage::Format_ARGB32_Premultiplied) {
        m_img.fill(Qt::gray);
        QMetaObject::invokeMethod(this, [this] { emit finished(); }, Qt::QueuedConnection);
    }
    QQuickTextureFactory *textureFactory() const override {
        return QQuickTextureFactory::textureFactoryForImage(m_img);
    }
private:
    QImage m_img;
};

class CountingImages : public QQuickAsyncImageProvider {
public:
    QQuickImageResponse *requestImageResponse(const QString &, const QSize &size) override {
        ++g_imageRequests;
        return new CountingResponse(size);
    }
};

QQuickItem *named(QQuickItem *from, const QString &name) {
    if (!from) return nullptr;
    if (from->objectName() == name) return from;
    for (QQuickItem *kid : from->childItems())
        if (QQuickItem *found = named(kid, name)) return found;
    return nullptr;
}

QQuickItem *textInputIn(QQuickItem *from) {
    if (!from) return nullptr;
    if (qstrcmp(from->metaObject()->className(), "QQuickTextInput") == 0) return from;
    for (QQuickItem *kid : from->childItems())
        if (QQuickItem *found = textInputIn(kid)) return found;
    return nullptr;
}

double ms(qint64 ns) { return double(ns) / 1e6; }

struct Sample {
    QString text;
    double handler = 0;      // the key event, with everything it ran
    double debounced = 0;    // the sidebar's deferred rebuild
    double frame = 0;        // polish, delegates and the drawn frame
    int rows = 0;            // what the view holds afterwards
    int created = 0;         // delegates that did not exist before the key
    int kept = 0;            // delegates from before the key still in place
    int images = 0;          // cover requests the key caused
    int rebuilt = 0;         // rows shown before and after, on a new delegate
    double total() const { return handler + debounced + frame; }
};

} // namespace

class TestLibraryFilter : public QObject {
    Q_OBJECT

    QTemporaryDir m_dir;
    Library L;
    std::unique_ptr<BenchClient>  m_client;
    std::unique_ptr<TidalBridge>  m_bridge;
    std::unique_ptr<PinStore>     m_pins;
    std::unique_ptr<BenchLibrary> m_library;
    std::unique_ptr<QQmlEngine>   m_engine;
    std::unique_ptr<QQuickWindow> m_win;
    QQuickItem *m_page = nullptr;
    QQuickItem *m_sidebar = nullptr;
    double m_idleFrame = 0;
    int m_runs = 1;
    bool m_print = false;

    QImage grab() { return m_win->grabWindow(); }

    void settle() {
        for (int i = 0; i < 5; ++i) { QTest::qWait(5); grab(); }
    }

    QObject *debounceTimer() {
        const auto all = m_sidebar->findChildren<QObject *>();
        for (QObject *o : all)
            if (qstrcmp(o->metaObject()->className(), "QQmlTimer") == 0
                && o->property("interval").toInt() == 120)
                return o;
        return nullptr;
    }

    void setText(QQuickItem *input, const QString &text) {
        input->setProperty("text", text);
        if (QObject *t = debounceTimer(); t && t->property("running").toBool()) {
            QMetaObject::invokeMethod(t, "stop");
            QMetaObject::invokeMethod(m_sidebar, "rebuildRows");
        }
        settle();
    }

    // The delegate of each row the view has one for, by the row's key.
    static QHash<QString, QPointer<QQuickItem>> delegatesByRow(QQuickItem *view, const QStringList &keys) {
        QHash<QString, QPointer<QQuickItem>> out;
        for (int i = 0; i < keys.size(); ++i) {
            QQuickItem *item = nullptr;
            QMetaObject::invokeMethod(view, "itemAtIndex", Q_RETURN_ARG(QQuickItem *, item), Q_ARG(int, i));
            if (item) out.insert(keys[i], item);
        }
        return out;
    }

    // Types `word` one character at a time into `input`, from empty. `keys`
    // names the rows the view shows, in order.
    QList<Sample> type(QQuickItem *input, QQuickItem *view, const QString &word,
                       const std::function<QStringList()> &keys) {
        setText(input, QString());
        input->forceActiveFocus();
        QList<Sample> out;
        for (int i = 0; i < word.size(); ++i) {
            Sample s;
            s.text = word.left(i + 1);
            QList<QPointer<QQuickItem>> before;
            for (QQuickItem *d : view->property("contentItem").value<QQuickItem *>()->childItems())
                before << d;
            const auto rowsBefore = delegatesByRow(view, keys());
            g_imageRequests = 0;

            QElapsedTimer t;
            t.start();
            const QChar c = word.at(i);
            if (c == QLatin1Char(' ')) QTest::keyClick(m_win.get(), Qt::Key_Space);
            else QTest::keyClick(m_win.get(), c.toLatin1());
            s.handler = ms(t.nsecsElapsed());
            if (QObject *timer = debounceTimer(); timer && timer->property("running").toBool()) {
                QMetaObject::invokeMethod(timer, "stop");
                t.restart();
                QMetaObject::invokeMethod(m_sidebar, "rebuildRows");
                s.debounced = ms(t.nsecsElapsed());
            }
            t.restart();
            grab();
            s.frame = std::max(0.0, ms(t.nsecsElapsed()) - m_idleFrame);
            // Image responses finish through the event loop.
            QCoreApplication::processEvents();
            s.images = g_imageRequests;

            const auto rowsAfter = delegatesByRow(view, keys());
            const auto after = view->property("contentItem").value<QQuickItem *>()->childItems();
            for (const QPointer<QQuickItem> &p : before)
                if (p && after.contains(p.data())) ++s.kept;
            for (QQuickItem *d : after) {
                bool old = false;
                for (const QPointer<QQuickItem> &p : before)
                    if (p.data() == d) { old = true; break; }
                if (!old) ++s.created;
            }
            s.rows = view->property("count").toInt();
            for (auto it = rowsAfter.cbegin(); it != rowsAfter.cend(); ++it) {
                const auto was = rowsBefore.constFind(it.key());
                if (was != rowsBefore.cend() && was.value().data() != it.value().data()) ++s.rebuilt;
            }
            out << s;
            if (input->property("text").toString() != s.text)
                qWarning() << "the field reads" << input->property("text").toString();
        }
        return out;
    }

    // The median of each keystroke over the runs.
    QList<Sample> bench(const QString &label, QQuickItem *input, QQuickItem *view, const QString &word,
                        const std::function<QStringList()> &keys) {
        QList<QList<Sample>> runs;
        for (int r = 0; r < m_runs; ++r) runs << type(input, view, word, keys);
        QList<Sample> med = runs.first();
        for (int k = 0; k < med.size(); ++k) {
            auto pick = [&](auto get) {
                QList<double> v;
                for (const auto &run : runs) v << get(run[k]);
                std::sort(v.begin(), v.end());
                return v[v.size() / 2];
            };
            med[k].handler   = pick([](const Sample &s) { return s.handler; });
            med[k].debounced = pick([](const Sample &s) { return s.debounced; });
            med[k].frame     = pick([](const Sample &s) { return s.frame; });
        }
        if (m_print) {
            qInfo().noquote() << QStringLiteral("\n%1 (idle frame %2 ms subtracted)").arg(label).arg(m_idleFrame, 0, 'f', 2);
            qInfo().noquote() << QStringLiteral("  %1 %2 %3 %4 %5 %6 %7 %8 %9 %10")
                .arg(QStringLiteral("typed"), -10).arg(QStringLiteral("handler"), 8)
                .arg(QStringLiteral("deferred"), 9).arg(QStringLiteral("frame"), 8)
                .arg(QStringLiteral("total"), 8).arg(QStringLiteral("rows"), 6)
                .arg(QStringLiteral("new"), 5).arg(QStringLiteral("kept"), 5)
                .arg(QStringLiteral("rebuilt"), 8).arg(QStringLiteral("covers"), 7);
            for (const Sample &s : med)
                qInfo().noquote() << QStringLiteral("  %1 %2 %3 %4 %5 %6 %7 %8 %9 %10")
                    .arg(QLatin1Char('"') + s.text + QLatin1Char('"'), -10)
                    .arg(s.handler, 8, 'f', 2).arg(s.debounced, 9, 'f', 2).arg(s.frame, 8, 'f', 2)
                    .arg(s.total(), 8, 'f', 2).arg(s.rows, 6).arg(s.created, 5).arg(s.kept, 5)
                    .arg(s.rebuilt, 8).arg(s.images, 7);
        }
        return med;
    }

    QQuickItem *collectionInput() {
        return textInputIn(named(m_page, QStringLiteral("collectionSearch")));
    }

    // Through the field, as typing would, without waiting for a frame.
    void filterTo(const QString &q) {
        collectionInput()->setProperty("text", q);
        QCoreApplication::processEvents();
    }

    static QVariantList listOf(const QVariant &v) {
        if (v.canConvert<QJSValue>()) return v.value<QJSValue>().toVariant().toList();
        return v.toList();
    }

    // Run with `scope`'s members in reach and the rows left in JS: converting
    // thousands of them to C++ is the slow part.
    QStringList idsByScript(int tab, const QString &rowsExpr, QObject *scope = nullptr) {
        const QString key = tab == 3 ? QStringLiteral("uuid") : QStringLiteral("id");
        if (!scope) scope = m_page;
        QQmlExpression e(qmlContext(m_page), scope,
                         QStringLiteral("(%1).map(function (x) { return '' + x.%2 }).join('\\n')")
                             .arg(rowsExpr, key));
        const QString joined = e.evaluate().toString();
        if (e.hasError()) qWarning() << e.error();
        return joined.isEmpty() ? QStringList() : joined.split(QLatin1Char('\n'));
    }

    QStringList shownIds(int tab) { return idsByScript(tab, QStringLiteral("shownItems()")); }

    // The bridge's own search, in the page's order.
    QStringList expectedIds(int tab, const QString &q, QObject *trackSort) {
        if (tab == 4) {
            const QString lq = q.toLower();
            QStringList out;
            for (const Mix &m : L.mixes)
                if (lq.isEmpty() || m.title.toLower().contains(lq) || m.subTitle.toLower().contains(lq))
                    out << m.id;
            return out;
        }
        const QString literal = QString::fromUtf8(
            QJsonDocument(QJsonArray{q}).toJson(QJsonDocument::Compact)).mid(1).chopped(1);
        static const char *const kinds[] = {"Tracks", "Albums", "Artists", "Playlists"};
        const QString found = QStringLiteral("bridge.searchFavorite%1(%2)")
                                  .arg(QLatin1String(kinds[tab]), literal);
        if (tab == 0) return idsByScript(tab, QStringLiteral("sorted(%1)").arg(found), trackSort);
        return idsByScript(tab, QStringLiteral("sortItems(%1, sortMode)").arg(found));
    }

    QQuickItem *openTab(int tab, const char *viewName) {
        m_page->setProperty("activeTab", tab);
        settle();
        QQuickItem *view = named(m_page, QString::fromLatin1(viewName));
        return view;
    }

private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName(QStringLiteral("tidal-wave-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_library_filter"));
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QVERIFY(m_dir.isValid());
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QStandardPaths::setTestModeEnabled(true);
        qputenv("HOME", m_dir.path().toUtf8());
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedKingdom));
        m_runs  = std::max(1, qEnvironmentVariableIntValue("TW_BENCH_RUNS"));
        m_print = qEnvironmentVariableIntValue("TW_BENCH_PRINT") != 0;

        L = makeLibrary();
        m_client = std::make_unique<BenchClient>(L);
        m_bridge = std::make_unique<TidalBridge>(m_client.get());
        m_client->setUserId(kUid);
        QTRY_VERIFY_WITH_TIMEOUT(!m_bridge->property("favoritesLoading").toBool(), 20000);
        QCOMPARE(m_bridge->searchFavoriteTracks(QString()).size(), L.likes.size());

        m_pins = std::make_unique<PinStore>();
        m_pins->setUserId(kUid);
        m_library = std::make_unique<BenchLibrary>(L, m_pins.get());
        m_library->setUserId(kUid);
        m_library->refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!m_library->loading() && !m_library->indexing(), 60000);
        QCOMPARE(m_library->indexedAlbumCount(), int(L.albums.size()));

        // As the app collects: whole-heap, so a collection's pause is in the timings.
        Application::useWholeHeapQmlCollector();
        m_engine = std::make_unique<QQmlEngine>();
        TestStubs stubs = installTestStubs(m_engine.get(), this);
        stubs.auth->setStateForTest(StubAuth::State::LoggedIn);
        stubs.app->setReducedMotionForTest(true);
        m_engine->rootContext()->setContextProperty(QStringLiteral("bridge"), m_bridge.get());
        m_engine->rootContext()->setContextProperty(QStringLiteral("library"), m_library.get());
        m_engine->removeImageProvider(QStringLiteral("tidal"));
        m_engine->addImageProvider(QStringLiteral("tidal"), new CountingImages);

        QQmlComponent host(m_engine.get());
        host.setData(QByteArrayLiteral(
            "import QtQuick\n"
            "import QtQuick.Layouts\n"
            "import TidalWave\n"
            "Window {\n"
            "    width: 1400; height: 900; visible: true\n"
            "    color: Theme.bg\n"
            "    RowLayout {\n"
            "        anchors.fill: parent; spacing: 0\n"
            "        SideBar {\n"
            "            objectName: \"benchSidebar\"; z: 2; hostWidth: 1400\n"
            "            currentPage: \"collection\"\n"
            "            Layout.preferredWidth: reservedWidth; Layout.fillHeight: true\n"
            "        }\n"
            "        CollectionPage {\n"
            "            objectName: \"benchCollection\"\n"
            "            Layout.fillWidth: true; Layout.fillHeight: true\n"
            "        }\n"
            "    }\n"
            "}\n"), QUrl(QStringLiteral("qrc:/tst_library_filter/host.qml")));
        if (host.isError()) qWarning() << host.errors();
        QVERIFY(!host.isError());
        std::unique_ptr<QObject> root(host.create());
        QVERIFY(qobject_cast<QQuickWindow *>(root.get()));
        m_win.reset(static_cast<QQuickWindow *>(root.release()));
        m_win->show();
        m_win->requestActivate();
        QVERIFY(QTest::qWaitForWindowActive(m_win.get(), 5000));
        m_page    = named(m_win->contentItem(), QStringLiteral("benchCollection"));
        m_sidebar = named(m_win->contentItem(), QStringLiteral("benchSidebar"));
        QVERIFY(m_page && m_sidebar);
        QTRY_VERIFY(m_page->property("mixesLoaded").toBool());
        settle();

        QElapsedTimer t;
        QList<double> idle;
        for (int i = 0; i < 9; ++i) { t.start(); grab(); idle << ms(t.nsecsElapsed()); }
        std::sort(idle.begin(), idle.end());
        m_idleFrame = idle[idle.size() / 2];
    }

    void cleanupTestCase() {
        m_win.reset();
        m_engine.reset();
    }

    // ── what the field matches, pinned ───────────────────────────────────
    // Lower case on both sides and a plain substring: no accent folding, no
    // trimming, and a decomposed letter is not its precomposed twin.
    void collection_matches_data() {
        QTest::addColumn<int>("tab");
        QTest::addColumn<QString>("query");
        QTest::addColumn<QStringList>("ids");
        const auto range = [](int from, int to, int skip = -1) {
            QStringList out;
            for (int i = from; i <= to; ++i) if (i != skip) out << QString::number(i);
            return out;
        };
        QTest::newRow("albums: title or artist") << 1 << QStringLiteral("quasar") << range(390000, 390007);
        QTest::newRow("albums: case only")  << 1 << QStringLiteral("QUASAR CAFÉ") << QStringList{QStringLiteral("390000")};
        QTest::newRow("albums: no folding") << 1 << QStringLiteral("quasar cafe")
                                            << QStringList{QStringLiteral("390001"), QStringLiteral("390002")};
        QTest::newRow("albums: sharp s")    << 1 << QStringLiteral("quasarstraße") << QStringList{QStringLiteral("390003")};
        QTest::newRow("albums: ss")         << 1 << QStringLiteral("QUASARSTRASSE") << QStringList{QStringLiteral("390004")};
        QTest::newRow("albums: artist")     << 1 << QStringLiteral("nadia quist") << range(390000, 390007, 390005);
        QTest::newRow("albums: band")       << 1 << QStringLiteral("quasar band") << QStringList{QStringLiteral("390005")};
        QTest::newRow("albums: two spaces") << 1 << QStringLiteral("quasar  d") << QStringList{QStringLiteral("390006")};
        QTest::newRow("albums: one space")  << 1 << QStringLiteral("quasar d") << QStringList{};
        QTest::newRow("albums: not trimmed") << 1 << QStringLiteral(" quasar") << QStringList{QStringLiteral("390007")};
        QTest::newRow("albums: dotted I")   << 1 << QStringLiteral("İSTANBUL") << QStringList{QStringLiteral("390007")};
        QTest::newRow("albums: dotless")    << 1 << QStringLiteral("istanbul quasar") << QStringList{};
        QTest::newRow("tracks: three fields") << 0 << QStringLiteral("quasar") << range(1900000, 1900002);
        QTest::newRow("tracks: title")      << 0 << QStringLiteral("quasar lied") << QStringList{QStringLiteral("1900000")};
        QTest::newRow("tracks: album")      << 0 << QStringLiteral("quasar café") << QStringList{QStringLiteral("1900001")};
        QTest::newRow("tracks: artist")     << 0 << QStringLiteral("QUASAR BAND") << QStringList{QStringLiteral("1900002")};
        QTest::newRow("tracks: no folding") << 0 << QStringLiteral("quasar cafe") << QStringList{};
        QTest::newRow("artists: name")      << 2 << QStringLiteral("quasar") << range(290000, 290002);
        QTest::newRow("artists: umlaut")    << 2 << QStringLiteral("quasar bänd") << QStringList{QStringLiteral("290001")};
        QTest::newRow("artists: decomposed") << 2 << QStringLiteral("quasar ba")
                                             << QStringList{QStringLiteral("290000"), QStringLiteral("290002")};
        QTest::newRow("artists: upper")     << 2 << QStringLiteral("QUIST") << QStringList{QStringLiteral("290003")};
        QTest::newRow("playlists: newest first") << 3 << QStringLiteral("Quasar abend")
                                                 << QStringList{QStringLiteral("pin-pl-0"), QStringLiteral("pin-pl-1")};
        QTest::newRow("playlists: none")    << 3 << QStringLiteral("abend q") << QStringList{};
        QTest::newRow("mixes: title or subtitle") << 4 << QStringLiteral("quasar")
                                                  << QStringList{QStringLiteral("pin-mix-0"), QStringLiteral("pin-mix-1")};
        QTest::newRow("mixes: subtitle")    << 4 << QStringLiteral("QUASAR LEUTE") << QStringList{QStringLiteral("pin-mix-1")};
        QTest::newRow("mixes: title")       << 4 << QStringLiteral("quasar mix") << QStringList{QStringLiteral("pin-mix-0")};
    }

    void collection_matches() {
        QFETCH(int, tab);
        QFETCH(QString, query);
        QFETCH(QStringList, ids);
        m_page->setProperty("sortMode", 0);
        m_page->setProperty("activeTab", tab);
        filterTo(query);
        QCOMPARE(shownIds(tab), ids);
        QCOMPARE(m_page->property("tabCount").toInt(), int(ids.size()));
        filterTo(QString());
    }

    // ── and on the whole library, what the bridge's own search finds ─────
    // In the page's order: its sort applied to the bridge's matches.
    void collection_agrees_with_the_bridge_data() {
        QTest::addColumn<int>("tab");
        QTest::addColumn<QVariantList>("orders");
        QTest::newRow("tracks")    << 0 << QVariantList{QString(), QStringLiteral("title")};
        QTest::newRow("albums")    << 1 << QVariantList{0, 1, 3};
        QTest::newRow("artists")   << 2 << QVariantList{0, 2};
        QTest::newRow("playlists") << 3 << QVariantList{0, 1};
        QTest::newRow("mixes")     << 4 << QVariantList{0};
    }

    void collection_agrees_with_the_bridge() {
        QFETCH(int, tab);
        QFETCH(QVariantList, orders);
        const QStringList queries = {
            QStringLiteral("t"), QStringLiteral("the "), QStringLiteral("the bl"),
            QStringLiteral("böse"), QStringLiteral("BÖSE"),
            QStringLiteral("é"), QStringLiteral("weiß"), QStringLiteral(" o"), QStringLiteral("zz"),
        };
        m_page->setProperty("activeTab", tab);
        QObject *trackSort = named(m_page, QStringLiteral("collectionTracksHeader"))
                                 ->property("sort").value<QObject *>();
        QVERIFY(trackSort);
        for (const QVariant &order : orders) {
            if (tab == 0) trackSort->setProperty("key", order.toString());
            else          m_page->setProperty("sortMode", order.toInt());
            for (const QString &q : queries) {
                filterTo(q);
                const QStringList want = expectedIds(tab, q, trackSort);
                const QStringList shown = shownIds(tab);
                QVERIFY2(shown == want,
                         qPrintable(QStringLiteral("tab %1, order %2, \"%3\": %4 rows shown, %5 expected")
                                        .arg(tab).arg(order.toString(), q)
                                        .arg(shown.size()).arg(want.size())));
                QCOMPARE(m_page->property("tabCount").toInt(), int(want.size()));
            }
        }
        trackSort->setProperty("key", QString());
        m_page->setProperty("sortMode", 0);
        filterTo(QString());
    }

    // Typed on one tab, every tab's count follows at once, and a tab opened
    // afterwards shows those rows.
    void other_tabs_follow_the_field() {
        static const char *const rows[] = {"trackRows", "albumRows", "artistRows", "playlistRows", "mixRows"};
        static const char *const views[] = {"collectionTracksList", "collectionAlbumsGrid", "collectionArtistsGrid",
                                            "collectionPlaylistsGrid", "collectionMixesGrid"};
        const QString q = QStringLiteral("the bl");
        const int want[] = {int(m_bridge->searchFavoriteTracks(q).size()), int(m_bridge->searchFavoriteAlbums(q).size()),
                            int(m_bridge->searchFavoriteArtists(q).size()),
                            int(m_bridge->searchFavoritePlaylists(q).size()), int(expectedIds(4, q, nullptr).size())};
        QObject *trackSort = named(m_page, QStringLiteral("collectionTracksHeader"))
                                 ->property("sort").value<QObject *>();
        m_page->setProperty("sortMode", 0);
        QVERIFY(openTab(1, views[1]));
        filterTo(q);
        for (int t = 0; t < 5; ++t)
            QCOMPARE(m_page->property(rows[t]).value<QObject *>()->property("count").toInt(), want[t]);
        for (int t : {0, 2, 3, 4}) {
            QQuickItem *view = openTab(t, views[t]);
            QVERIFY(view);
            QCOMPARE(view->property("count").toInt(), want[t]);
            QCOMPARE(shownIds(t), expectedIds(t, q, trackSort));
        }
        filterTo(QString());
    }

    // Where a keystroke's time goes before any QML runs: the bridge's own
    // searches, and handing their answer to JS. Printed only.
    void bridge_costs() {
        if (!m_print) QSKIP("timings are printed with TW_BENCH_PRINT=1");
        QJSEngine *js = m_engine.get();
        for (const QString &q : {QStringLiteral("t"), QStringLiteral("the blue")}) {
            QElapsedTimer t;
            const auto time = [&](const char *what, const std::function<QVariantList()> &run) {
                t.start();
                const QVariantList rows = run();
                const double search = ms(t.nsecsElapsed());
                t.restart();
                const QJSValue v = js->toScriptValue(rows);
                const double toJs = ms(t.nsecsElapsed());
                qInfo().noquote() << QStringLiteral("  %1 \"%2\": %3 rows, search %4 ms, to JS %5 ms")
                    .arg(QLatin1String(what)).arg(q).arg(rows.size()).arg(search, 0, 'f', 2).arg(toJs, 0, 'f', 2);
                Q_UNUSED(v);
            };
            time("tracks",    [&] { return m_bridge->searchFavoriteTracks(q); });
            time("albums",    [&] { return m_bridge->searchFavoriteAlbums(q); });
            time("artists",   [&] { return m_bridge->searchFavoriteArtists(q); });
            time("playlists", [&] { return m_bridge->searchFavoritePlaylists(q); });
            time("sidebar",   [&] { return m_library->search(q, {}); });
        }
    }

    void collection_data() {
        QTest::addColumn<int>("tab");
        QTest::addColumn<QString>("view");
        QTest::newRow("tracks")    << 0 << QStringLiteral("collectionTracksList");
        QTest::newRow("albums")    << 1 << QStringLiteral("collectionAlbumsGrid");
        QTest::newRow("artists")   << 2 << QStringLiteral("collectionArtistsGrid");
        QTest::newRow("playlists") << 3 << QStringLiteral("collectionPlaylistsGrid");
        QTest::newRow("mixes")     << 4 << QStringLiteral("collectionMixesGrid");
    }

    void collection() {
        QFETCH(int, tab);
        QFETCH(QString, view);
        QQuickItem *v = openTab(tab, view.toLatin1().constData());
        QVERIFY(v);
        QQuickItem *input = textInputIn(named(m_page, QStringLiteral("collectionSearch")));
        QVERIFY(input);
        const QList<Sample> keys =
            bench(QStringLiteral("Collection page, %1 tab").arg(QString::fromLatin1(QTest::currentDataTag())),
                  input, v, QStringLiteral("the blue"), [this, tab] { return shownIds(tab); });
        setText(input, QString());
        // A key narrows what is there; the cards and rows that stay are not made again.
        for (const Sample &s : keys)
            QVERIFY2(s.rebuilt == 0, qPrintable(QStringLiteral("\"%1\" made %2 delegates again for rows that stayed")
                                                     .arg(s.text).arg(s.rebuilt)));
        // The targets, for a quiet machine: 16 ms a key on a grid, 50 ms on the liked songs.
        if (qEnvironmentVariableIntValue("TW_BENCH_ASSERT")) {
            const double ceiling = tab == 0 ? 50 : 16;
            for (const Sample &s : keys)
                QVERIFY2(s.total() < ceiling, qPrintable(QStringLiteral("\"%1\" took %2 ms")
                                                             .arg(s.text).arg(s.total(), 0, 'f', 1)));
        }
    }

    void sidebar() {
        QQuickItem *v = named(m_sidebar, QStringLiteral("sidebarLibraryList"));
        QQuickItem *input = named(m_sidebar, QStringLiteral("finderInput"));
        QVERIFY(v && input);
        QVERIFY(debounceTimer());
        bench(QStringLiteral("Sidebar finder, every kind"), input, v, QStringLiteral("the blue"), [this] {
            QStringList out;
            for (const QVariant &r : listOf(m_sidebar->property("rows"))) {
                const QVariantMap m = r.toMap();
                out << m.value(QStringLiteral("kind")).toString() + QLatin1Char('/')
                       + m.value(QStringLiteral("id")).toString();
            }
            return out;
        });
        setText(input, QString());
    }
};

QTEST_MAIN(TestLibraryFilter)
#include "tst_library_filter.moc"
