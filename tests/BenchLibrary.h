// SPDX-License-Identifier: GPL-3.0-or-later
// An invented library at a large account's size, and the seams that serve it:
// LibraryIndex's fetches, and a "tidal" image provider that counts requests.
// Shared by tst_library_filter and tst_ui_perf.

#pragma once

#include <QHash>
#include <QList>
#include <QQuickAsyncImageProvider>
#include <QStringList>

#include <atomic>

#include "api/LibraryIndex.h"
#include "api/Models.h"

namespace bench {

using namespace Tidal;

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

inline QString words(Rng &r, int lo, int hi) {
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
inline Artist pinArtist(qint64 id, const QString &name) {
    Artist a; a.id = id; a.name = name; a.picture = QStringLiteral("pinpic-%1").arg(id);
    return a;
}

inline void addPinRows(Library &L) {
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

inline Library makeLibrary() {
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
inline std::atomic<int> g_imageRequests{0};

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

} // namespace bench
