#pragma once
//
// Test doubles for the QML context properties the app installs at runtime
// (see Application::run(): prefs, auth, bridge, player, downloader, cast, app,
// pins, library).
//
// Why: every page under qml/pages/ reaches straight into those globals in
// bindings and in Component.onCompleted, so instantiating a page against a bare
// QQmlEngine dies on "auth is not defined" / "TypeError: Cannot call method of
// undefined" long before the test gets to assert anything. These stubs expose
// the same property/invokable/signal surface as the real objects, with no
// network, no Tidal session, no QMediaPlayer and no D-Bus.
//
// Shapes matter, not values: the QML callback convention is
// function(data, errorString), and call sites do things like
// `if (err.length > 0) return` and `tracks.length > 0`. So callbacks fire
// synchronously with an *empty array* (or an empty object where the real bridge
// returns a map) plus an *empty string* error — never undefined, which would
// throw inside the page's own handler.
//
// Everything is header-only and listed in tests/CMakeLists.txt so AUTOMOC picks
// it up; both tst_core and tst_qml use it.
//
// Beyond the mirrored API, members marked "test hook" are extras that exist only
// here, so a test can drive state the real objects only reach via the network
// (e.g. player.setCurrentTrackForTest(...), auth.setStateForTest(...)).
//

#include <QHash>
#include <QImage>
#include <QJSEngine>
#include <QJSValue>
#include <QJSValueList>
#include <QObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickImageProvider>
#include <QSet>
#include <QString>
#include <utility>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include "api/TidalBridge.h"   // withRecentSearch / kRecentSearchCap
#include "ui/Application.h"
#include "ui/ThemePalette.h"

// ─── shared plumbing ────────────────────────────────────────────────────────

// Base for stubs that hand results back through a QJSValue callback.
class StubCallbackObject : public QObject {
    Q_OBJECT
public:
    explicit StubCallbackObject(QObject *parent = nullptr) : QObject(parent) {}

    // The engine the stub was installed into; needed to build JS arrays/objects.
    void setJsEngine(QJSEngine *engine) { m_jsEngine = engine; }
    QJSEngine *jsEngine() const { return m_jsEngine; }

protected:
    QJSValue emptyArray() const {
        return m_jsEngine ? m_jsEngine->newArray(0) : QJSValue();
    }
    QJSValue emptyObject() const {
        return m_jsEngine ? m_jsEngine->newObject() : QJSValue();
    }
    QJSValue noError() const { return QJSValue(QString()); }

    // function(data, errorString) — the bridge's universal callback shape.
    void resolve(QJSValue &cb, const QJSValue &data) const {
        if (!cb.isCallable()) return;
        QJSValueList args;
        args << data << noError();
        cb.call(args);
    }
    // function(success) — used by the favourite/playlist mutators.
    void resolveOk(QJSValue &cb, bool ok = true) const {
        if (!cb.isCallable()) return;
        QJSValueList args;
        args << QJSValue(ok);
        cb.call(args);
    }

private:
    QJSEngine *m_jsEngine = nullptr;
};

// ─── auth ───────────────────────────────────────────────────────────────────

// Mirrors Auth (src/api/Auth.h). Starts logged in, because that is the state
// every page except LoginPage assumes.
class StubAuth : public QObject {
    Q_OBJECT
    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString userCode READ userCode NOTIFY userCodeChanged)
    Q_PROPERTY(QString verificationUrl READ verificationUrl NOTIFY userCodeChanged)
    Q_PROPERTY(QString username READ username NOTIFY usernameChanged)
    Q_PROPERTY(bool hasSavedCredentials READ hasSavedCredentials NOTIFY hasSavedCredentialsChanged)
public:
    // Same order/values as Auth::State, so `auth.state === 2` in QML still means
    // LoggedIn (SideBar.qml compares against plain ints).
    enum class State { LoggedOut, PendingDevice, LoggedIn };
    Q_ENUM(State)

    explicit StubAuth(QObject *parent = nullptr) : QObject(parent) {}

    State   state() const { return m_state; }
    QString userCode() const { return m_userCode; }
    QString verificationUrl() const { return m_verificationUrl; }
    QString username() const { return m_username; }
    bool    hasSavedCredentials() const { return m_hasSavedCredentials; }

    Q_INVOKABLE void startDeviceFlow() { setStateForTest(State::PendingDevice); }
    Q_INVOKABLE void cancelDeviceFlow() { setStateForTest(State::LoggedOut); }
    Q_INVOKABLE void logout() {
        m_username.clear();
        emit usernameChanged();
        setStateForTest(State::LoggedOut);
    }

    // test hooks
    Q_INVOKABLE void setStateForTest(State s) {
        if (m_state == s) return;
        m_state = s;
        emit stateChanged(m_state);
    }
    Q_INVOKABLE void setUsernameForTest(const QString &name) {
        m_username = name;
        emit usernameChanged();
    }
    Q_INVOKABLE void setDeviceCodeForTest(const QString &code, const QString &url) {
        m_userCode = code;
        m_verificationUrl = url;
        emit userCodeChanged();
    }
    Q_INVOKABLE void setHasSavedCredentialsForTest(bool has) {
        m_hasSavedCredentials = has;
        emit hasSavedCredentialsChanged();
    }
    Q_INVOKABLE void emitLoginSucceededForTest() { emit loginSucceeded(); }
    Q_INVOKABLE void emitLoginFailedForTest(const QString &reason) { emit loginFailed(reason); }
    Q_INVOKABLE void emitSessionExpiredForTest() { emit sessionExpired(); }

signals:
    void stateChanged(State state);
    void userCodeChanged();
    void usernameChanged();
    void loginSucceeded();
    void loginFailed(const QString &reason);
    void sessionExpired();
    void hasSavedCredentialsChanged();

private:
    State   m_state = State::LoggedIn;
    QString m_userCode;
    QString m_verificationUrl;
    QString m_username = QStringLiteral("test-user");
    bool    m_hasSavedCredentials = true;
};

// ─── bridge ─────────────────────────────────────────────────────────────────

// Mirrors TidalBridge (src/api/TidalBridge.h). Every fetch answers immediately
// with an empty result and no error, so pages finish their loading state instead
// of spinning forever.
class StubBridge : public StubCallbackObject {
    Q_OBJECT
    Q_PROPERTY(QString preferredQuality READ preferredQuality WRITE setPreferredQuality NOTIFY preferredQualityChanged)
public:
    explicit StubBridge(QObject *parent = nullptr) : StubCallbackObject(parent) {}

    QString preferredQuality() const { return m_preferredQuality; }
    void setPreferredQuality(const QString &q) {
        if (m_preferredQuality == q) return;
        m_preferredQuality = q;
        emit preferredQualityChanged();
    }

    // Home / mixes
    Q_INVOKABLE void fetchHomeMixes(QJSValue cb) { resolve(cb, emptyArray()); }
    Q_INVOKABLE void fetchMixTracks(const QString &mixId, QJSValue cb) {
        Q_UNUSED(mixId); resolve(cb, emptyArray());
    }

    // function(mix, tracks, error) — the one `pages/mix` reply, both halves of
    // it. Empty until setMixPageForTest() says otherwise, like every other
    // fetch here, so a page that opens with nothing still finishes loading.
    //
    // The id is recorded rather than ignored: a page opened by id alone has to
    // ask for *that* mix, and nothing else in the stub would notice if it
    // asked for the wrong one.
    Q_INVOKABLE void fetchMixPage(const QString &mixId, QJSValue cb) {
        m_lastMixPageId = mixId;
        m_mixPageFetches++;
        if (!cb.isCallable()) return;
        QJSEngine *e = jsEngine();
        QJSValueList args;
        args << (e ? e->toScriptValue(m_mixHeader) : emptyObject())
             << (e ? e->toScriptValue(m_mixTracks) : emptyArray())
             << QJSValue(m_headerError);
        deliver(cb, args);
    }

    // Favourites / playlists (paged in the real bridge; defaults kept identical)
    Q_INVOKABLE void fetchFavoriteTracks(QJSValue cb, int limit = 50, int offset = 0) {
        Q_UNUSED(limit); Q_UNUSED(offset); resolve(cb, emptyArray());
    }
    Q_INVOKABLE void fetchFavoriteAlbums(QJSValue cb, int limit = 50, int offset = 0) {
        Q_UNUSED(limit); Q_UNUSED(offset); resolve(cb, emptyArray());
    }
    Q_INVOKABLE void fetchFavoriteArtists(QJSValue cb, int limit = 50, int offset = 0) {
        Q_UNUSED(limit); Q_UNUSED(offset); resolve(cb, emptyArray());
    }
    Q_INVOKABLE void fetchUserPlaylists(QJSValue cb, int limit = 50, int offset = 0) {
        Q_UNUSED(limit); Q_UNUSED(offset);
        // Counted: the sidebar used to call this with limit 30, which is the
        // reported "new playlists don't show up" bug (SPEC S3). It reads
        // library.entries now, so tst_sidebar asserts the count stays at zero.
        m_userPlaylistFetches++;
        resolve(cb, emptyArray());
    }

    // Detail pages — these return maps, not lists.
    Q_INVOKABLE void fetchAlbumTracks(qlonglong albumId, QJSValue cb) {
        Q_UNUSED(albumId); resolve(cb, emptyArray());
    }
    Q_INVOKABLE void fetchPlaylistTracks(const QString &uuid, QJSValue cb) {
        Q_UNUSED(uuid); resolve(cb, emptyArray());
    }
    // The playlist itself: {uuid, title, description, numTracks, duration,
    // coverUrl, type}. PlaylistPage's hero reads it, and `type` is the one
    // field that is not cosmetic — it decides whether the playlist is editable.
    Q_INVOKABLE void fetchPlaylist(const QString &uuid, QJSValue cb) {
        m_lastPlaylistFetched = uuid;
        m_playlistFetches++;
        if (!cb.isCallable()) return;
        QJSEngine *e = jsEngine();
        QJSValueList args;
        args << (e ? e->toScriptValue(m_playlist) : emptyObject())
             << QJSValue(m_headerError);
        deliver(cb, args);
    }
    Q_INVOKABLE void fetchAlbum(qlonglong albumId, QJSValue cb) {
        Q_UNUSED(albumId); resolve(cb, emptyObject());
    }
    Q_INVOKABLE void fetchArtistDetail(qlonglong artistId, QJSValue cb) {
        Q_UNUSED(artistId); resolve(cb, emptyObject());
    }
    Q_INVOKABLE void fetchArtistAlbums(qlonglong artistId, QJSValue cb) {
        Q_UNUSED(artistId); resolve(cb, emptyArray());
    }
    Q_INVOKABLE void fetchArtistTopTracks(qlonglong artistId, QJSValue cb) {
        Q_UNUSED(artistId); resolve(cb, emptyArray());
    }

    // Search answers with the real result shape: {tracks, albums, artists, playlists}.
    //
    // The four lists are whatever setSearchResultsForTest() put there, empty
    // until a test says otherwise. They used to be the only answer this could
    // ever give: the query and the limit went straight to Q_UNUSED and all four
    // lists were built empty, so no test had ever seen a non-empty remote
    // search result. That blinded the whole results page at once - "no
    // results", a type tab with no hits of its own kind, a failed request - and
    // every assertion about any of it would have passed against nothing.
    //
    // The query is still ignored. What is under test is what the page does with
    // a reply; how Tidal matches text is not this stub's business, and a stub
    // that guessed at it would be asserting its own guess.
    //
    // The *offset* is not ignored, and this is the one place the stub models
    // the server rather than just answering: each canned list is sliced
    // [offset, offset+limit) and the five totals report the whole list. Without
    // that a paging test could only ever see page one again, and "append as the
    // bottom is reached" would go green against a page that never moved.
    Q_INVOKABLE void search(const QString &q, QJSValue cb, int limit = 20, int offset = 0) {
        m_lastSearchQuery  = q;
        m_lastSearchLimit  = limit;
        m_lastSearchOffset = offset;
        m_searchCount++;
        if (!cb.isCallable()) return;
        // The real bridge builds the map from a default-constructed
        // SearchResults on the error path, so the shape is there either way and
        // the lists are empty - mirrored here, because a page that reads
        // results.tracks before checking err must fail the same way in a test
        // as it would in the app.
        QJSValueList args;
        args << searchPayload(m_searchError.isEmpty(), limit, offset)
             << QJSValue(m_searchError);
        // Held back when a test wants two requests in flight at once. Every
        // other reply in this file is synchronous, which is enough for a page
        // that only ever has one request out - but the search page now has a
        // generation guard and a paging cursor, and neither can be looked at
        // unless a reply can be made to arrive after the query it was for has
        // been replaced.
        if (m_deferSearch) { m_pendingSearches.append({cb, args}); return; }
        cb.call(args);
    }

    // Hold search replies until flushSearchRepliesForTest(). The canned payload
    // is built at call time, so what was in the stub when the request went out
    // is what comes back - exactly like a server that already answered.
    Q_INVOKABLE void setDeferSearchForTest(bool on) { m_deferSearch = on; }
    Q_INVOKABLE int  pendingSearchCountForTest() const { return int(m_pendingSearches.size()); }
    Q_INVOKABLE void flushSearchRepliesForTest() {
        auto pending = m_pendingSearches;
        m_pendingSearches.clear();
        for (auto &p : pending) p.first.call(p.second);
    }

    // ── recent searches ─────────────────────────────────────────────────
    //
    // In memory, never on disk: these are the queries a person typed, and a
    // test run must not append to - or read - the real account's list. The
    // ordering rule itself is the app's own withRecentSearch() out of
    // TidalBridge.h and not a second copy, so a test that asserts on it is
    // asserting the shipping rule.
    Q_INVOKABLE QStringList recentSearches() const { return m_recentSearches; }
    Q_INVOKABLE void addRecentSearch(const QString &q) {
        const QStringList after = withRecentSearch(m_recentSearches, q);
        if (after == m_recentSearches) return;
        m_recentSearches = after;
        emit recentSearchesChanged();
    }
    Q_INVOKABLE void removeRecentSearch(const QString &q) {
        if (m_recentSearches.removeIf([&q](const QString &e) {
                return e.compare(q, Qt::CaseInsensitive) == 0; }) == 0) return;
        emit recentSearchesChanged();
    }
    Q_INVOKABLE void clearRecentSearches() {
        if (m_recentSearches.isEmpty()) return;
        m_recentSearches.clear();
        emit recentSearchesChanged();
    }
    // Test hook: seed the list without going through the add rule.
    Q_INVOKABLE void setRecentSearchesForTest(const QStringList &queries) {
        m_recentSearches = queries;
        emit recentSearchesChanged();
    }

    Q_INVOKABLE void copyToClipboard(const QString &text) { m_lastClipboardText = text; }

    // Favourite state — nothing is favourited unless a test says so.
    Q_INVOKABLE bool isTrackFavorite(qlonglong trackId) const { return m_favoriteTracks.value(trackId, false); }
    Q_INVOKABLE void addTrackFavorite(qlonglong trackId, QJSValue cb) {
        m_favoriteTracks[trackId] = true;
        emit favoriteTracksChanged();
        resolveOk(cb);
    }
    Q_INVOKABLE void removeTrackFavorite(qlonglong trackId, QJSValue cb) {
        m_favoriteTracks[trackId] = false;
        emit favoriteTracksChanged();
        resolveOk(cb);
    }

    Q_INVOKABLE bool isAlbumFavorite(qlonglong albumId) const { return m_favoriteAlbums.value(albumId, false); }
    Q_INVOKABLE void addAlbumFavorite(qlonglong albumId, QJSValue cb) {
        m_favoriteAlbums[albumId] = true;
        emit favoriteAlbumsChanged();
        resolveOk(cb);
    }
    Q_INVOKABLE void removeAlbumFavorite(qlonglong albumId, QJSValue cb) {
        m_favoriteAlbums[albumId] = false;
        emit favoriteAlbumsChanged();
        resolveOk(cb);
    }

    Q_INVOKABLE bool isArtistFavorite(qlonglong artistId) const { return m_favoriteArtists.value(artistId, false); }
    Q_INVOKABLE void addArtistFavorite(qlonglong artistId, QJSValue cb) {
        m_favoriteArtists[artistId] = true;
        emit favoriteArtistsChanged();
        resolveOk(cb);
    }
    Q_INVOKABLE void removeArtistFavorite(qlonglong artistId, QJSValue cb) {
        m_favoriteArtists[artistId] = false;
        emit favoriteArtistsChanged();
        resolveOk(cb);
    }

    // Playlist management

    // ── createPlaylist, as TidalBridge::createPlaylist behaves ───────────
    //
    // This used to answer `{}` with no error for every input, which is the
    // shape of stub the Tracks filter comment above warns about: a dialog that
    // called it went green whatever it did with the answer, and the half of
    // the feature that matters - the new playlist reaching the sidebar and the
    // Collection grid without a refresh - could not be tested at all, because
    // nothing here moved when a playlist was made.
    //
    // So it mirrors the real one, including the order of the two effects and
    // the guard around them. On a success the playlist joins the favourites
    // cache that getUserPlaylists() and searchFavoritePlaylists() answer from
    // and favoritePlaylistsChanged goes out (which is what CollectionPage
    // listens to), and *separately* playlistCreated carries the row itself to
    // LibraryIndex - the sidebar keeps its own second copy of the library, and
    // installTestStubs() connects the two exactly as Application::run() does.
    // Both are inside the guard in the real bridge: a POST that failed, or one
    // that answered with no uuid, must not leave a phantom row behind.
    Q_INVOKABLE void createPlaylist(const QString &title, QJSValue cb) {
        m_createCalls++;
        m_lastCreatedTitle = title;
        if (m_deferCreates) { m_pendingCreates.append({cb, title}); return; }
        deliverCreate(cb, title);
    }
    // Recorded, not ignored: "make a playlist from the picker and the song
    // goes into it" is the whole point of that row, and a stub that threw the
    // arguments away would let a version that created an empty playlist and
    // dropped the track pass.
    Q_INVOKABLE void addTracksToPlaylist(const QString &uuid, qlonglong trackId, QJSValue cb) {
        m_lastAddedPlaylist = uuid;
        m_lastAddedTrackId  = trackId;
        m_addToPlaylistCalls++;
        resolveOk(cb, m_addToPlaylistOk);
    }
    Q_INVOKABLE void removeTrackFromPlaylist(const QString &uuid, int itemIndex, QJSValue cb) {
        Q_UNUSED(uuid); Q_UNUSED(itemIndex); resolveOk(cb);
    }
    Q_INVOKABLE QVariantList getUserPlaylists() const { return m_userPlaylists; }
    Q_INVOKABLE void markPlaylistPlayed(const QString &uuid) { m_lastPlaylistPlayed = uuid; }

    // Track features
    Q_INVOKABLE void fetchTrackRadio(qlonglong trackId, QJSValue cb) {
        Q_UNUSED(trackId); resolve(cb, emptyArray());
    }
    // NowPlayingPage reads .text and .timed off the result.
    Q_INVOKABLE void fetchLyrics(qlonglong trackId, QJSValue cb) {
        Q_UNUSED(trackId);
        QJSValue res = emptyObject();
        if (res.isObject()) {
            res.setProperty(QStringLiteral("text"), QJSValue(QString()));
            res.setProperty(QStringLiteral("timed"), QJSValue(false));
        }
        resolve(cb, res);
    }
    // NowPlayingPage reads .groups, .copyright, .isrc, .releaseDate and .upc
    // off the result. Answered empty, like fetchLyrics above, so the credits
    // panel lands on its "unavailable" state without a network: the page's own
    // credits state is writable, which is how a test gets a filled panel.
    //
    // Counted, because the page caches per track id and "flipping between the
    // panels does not refetch" is only a claim if something is counting.
    Q_INVOKABLE void fetchTrackCredits(qlonglong trackId, QJSValue cb) {
        Q_UNUSED(trackId);
        m_trackCreditsFetches++;
        QJSValue res = emptyObject();
        if (res.isObject()) {
            res.setProperty(QStringLiteral("groups"), emptyArray());
            res.setProperty(QStringLiteral("copyright"), QJSValue(QString()));
            res.setProperty(QStringLiteral("isrc"), QJSValue(QString()));
            res.setProperty(QStringLiteral("releaseDate"), QJSValue(QString()));
            res.setProperty(QStringLiteral("upc"), QJSValue(QString()));
        }
        resolve(cb, res);
    }
    Q_INVOKABLE void fetchRecentlyPlayed(QJSValue cb) { resolve(cb, emptyArray()); }

    // Local (already-loaded) filters used by CollectionPage's search field and by
    // HomePage's refresh, which reads this in-memory copy rather than going back
    // to the network. All four answer from lists a test can fill (see the hooks
    // below); the query itself is ignored, because the real filter is a
    // substring match and every caller under test passes "", which there means
    // "the whole cache".
    //
    // Tracks used to be the exception: this returned {} for every input, with
    // no backing list and no setter, while the comment above claimed all of
    // them were fillable. A stub that answers emptily for every input makes
    // every assertion about it pass without testing anything, which is how the
    // empty quality badge survived a full visual suite. Any test of the Tracks
    // filter went green against nothing.
    Q_INVOKABLE QVariantList searchFavoriteTracks(const QString &query) const { Q_UNUSED(query); return m_favoriteTrackList; }
    Q_INVOKABLE QVariantList searchFavoriteAlbums(const QString &query) const { Q_UNUSED(query); return m_favoriteAlbumList; }
    Q_INVOKABLE QVariantList searchFavoriteArtists(const QString &query) const { Q_UNUSED(query); return m_favoriteArtistList; }
    // The real bridge filters the same playlist cache getUserPlaylists() answers
    // from, so this one does too: a second list here could disagree with that
    // one, and a page that reads both would then see a library that cannot
    // exist. setUserPlaylistsForTest() therefore fills both.
    Q_INVOKABLE QVariantList searchFavoritePlaylists(const QString &query) const { Q_UNUSED(query); return m_userPlaylists; }

    // ── what the next createPlaylist() answers ──────────────────────────
    //
    // Three outcomes, because the dialog has three paths through its callback
    // and only one of them is a success:
    //   * nothing set: the server makes it and hands back a uuid;
    //   * an error string: the POST failed and the dialog must say so;
    //   * an empty uuid with no error: the reply parsed to nothing, which the
    //     real bridge refuses to treat as a win.
    Q_INVOKABLE void setCreatePlaylistErrorForTest(const QString &err) {
        m_createError = err;
    }
    // Pass "" for the reply-that-carried-nothing case; anything else is the
    // uuid the created playlist comes back with.
    Q_INVOKABLE void setCreatePlaylistUuidForTest(const QString &uuid) {
        m_createUuid    = uuid;
        m_createUuidSet = true;
    }
    // Hold the reply so a test can look at the dialog while the call is still
    // out — the in-flight state has no other way in, and it is the one state
    // a synchronous stub would otherwise make unreachable.
    Q_INVOKABLE void setDeferCreatePlaylistForTest(bool on) { m_deferCreates = on; }
    Q_INVOKABLE int  pendingCreatePlaylistsForTest() const {
        return int(m_pendingCreates.size());
    }
    Q_INVOKABLE void flushCreatePlaylistsForTest() {
        QList<std::pair<QJSValue, QString>> pending;
        pending.swap(m_pendingCreates);
        for (auto &p : pending) deliverCreate(p.first, p.second);
    }
    // The title as the dialog sent it, which is how a test sees that the name
    // was trimmed and capped before it left.
    Q_INVOKABLE QString lastCreatedTitleForTest() const { return m_lastCreatedTitle; }
    Q_INVOKABLE int     createPlaylistCallsForTest() const { return m_createCalls; }
    // Whether the add succeeds. The real call answers a plain bool and every
    // caller in the app used to throw it away, so the failing branch has to be
    // reachable or "it says so when it worked" is a claim about one case only.
    Q_INVOKABLE void      setAddToPlaylistOkForTest(bool ok) { m_addToPlaylistOk = ok; }
    Q_INVOKABLE QString   lastAddedPlaylistForTest() const { return m_lastAddedPlaylist; }
    Q_INVOKABLE qlonglong lastAddedTrackIdForTest() const { return m_lastAddedTrackId; }
    Q_INVOKABLE int       addToPlaylistCallsForTest() const { return m_addToPlaylistCalls; }
    Q_INVOKABLE void    resetCreatePlaylistForTest() {
        m_createError.clear();
        m_createUuid.clear();
        m_createUuidSet = false;
        m_deferCreates  = false;
        m_pendingCreates.clear();
        m_lastCreatedTitle.clear();
        m_createCalls = 0;
        m_lastAddedPlaylist.clear();
        m_lastAddedTrackId   = 0;
        m_addToPlaylistCalls = 0;
        m_addToPlaylistOk    = true;
    }

    // test hooks
    Q_INVOKABLE void setUserPlaylistsForTest(const QVariantList &playlists) {
        m_userPlaylists = playlists;
        emit favoritePlaylistsChanged();
    }
    // What fetchMixPage() answers: the MIX_HEADER half and the TRACK_LIST half,
    // settable apart, because the response that started all of this had one and
    // not the other.
    Q_INVOKABLE void setMixPageForTest(const QVariantMap &header,
                                       const QVariantList &tracks) {
        m_mixHeader = header;
        m_mixTracks = tracks;
    }
    // What fetchPlaylist() answers.
    Q_INVOKABLE void setPlaylistForTest(const QVariantMap &playlist) {
        m_playlist = playlist;
    }
    // Non-empty makes both header fetches fail with this reason. A page that
    // was handed a title by its caller has to keep it when the fetch that would
    // have confirmed it never answers.
    Q_INVOKABLE void setHeaderErrorForTest(const QString &err) { m_headerError = err; }
    // Holds the two header replies instead of answering them, so a test can
    // let a second page open before the first one's reply lands. Everything
    // else here answers synchronously, which makes the one race these pages
    // actually have - a reply arriving for the mix the user has already
    // navigated away from, into the same reused page item - impossible to
    // reach. The payload is frozen when the call is made, so each held reply
    // carries what the fetch would really have answered.
    Q_INVOKABLE void setDeferHeaderRepliesForTest(bool on) { m_deferHeaders = on; }
    Q_INVOKABLE int  pendingHeaderRepliesForTest() const { return int(m_pendingHeaders.size()); }
    // In the order they were asked, which is the order that makes the first
    // reply the stale one.
    Q_INVOKABLE void flushHeaderRepliesForTest() {
        QList<std::pair<QJSValue, QJSValueList>> pending;
        pending.swap(m_pendingHeaders);
        for (auto &p : pending)
            if (p.first.isCallable()) p.first.call(p.second);
    }
    Q_INVOKABLE QString lastMixPageIdForTest() const { return m_lastMixPageId; }
    Q_INVOKABLE QString lastPlaylistFetchedForTest() const { return m_lastPlaylistFetched; }
    Q_INVOKABLE int     mixPageFetchCountForTest() const { return m_mixPageFetches; }
    Q_INVOKABLE int     playlistFetchCountForTest() const { return m_playlistFetches; }
    Q_INVOKABLE void    resetHeadersForTest() {
        m_mixHeader.clear();
        m_mixTracks.clear();
        m_playlist.clear();
        m_headerError.clear();
        m_lastMixPageId.clear();
        m_lastPlaylistFetched.clear();
        m_mixPageFetches = 0;
        m_playlistFetches = 0;
        m_deferHeaders = false;
        m_pendingHeaders.clear();
    }

    Q_INVOKABLE void setTrackFavoriteForTest(qlonglong trackId, bool fav) {
        m_favoriteTracks[trackId] = fav;
        emit favoriteTracksChanged();
    }

    // The canned remote search reply. Four lists because the page reads four
    // and reacts differently to each: a result set with tracks and no albums is
    // exactly what makes the Albums tab say something rather than nothing.
    //
    // Mixes are the sixth kind and come through their own hook below rather
    // than a fifth argument here, so the twenty-odd existing call sites keep
    // meaning "these four and no mixes".
    Q_INVOKABLE void setSearchResultsForTest(const QVariantList &tracks,
                                            const QVariantList &albums,
                                            const QVariantList &artists,
                                            const QVariantList &playlists) {
        m_searchTracks    = tracks;
        m_searchAlbums    = albums;
        m_searchArtists   = artists;
        m_searchPlaylists = playlists;
        m_searchError.clear();   // a filled reply is a successful one
    }
    // The mixes the catalogue answers with. The *video* filter is not modelled
    // here and must not be: TidalClient::parseSearchMixes drops a video mix
    // before the bridge ever sees one, so by the time a reply reaches QML the
    // list is already clean. tests/tst_mixes.cpp is where that filter is
    // proved, against the captured mixType values.
    Q_INVOKABLE void setSearchMixesForTest(const QVariantList &mixes) {
        m_searchMixes = mixes;
        m_searchError.clear();
    }
    // Non-empty makes every later search fail with this reason, the way a lost
    // network does: errorString() reaches the callback and nothing else does.
    Q_INVOKABLE void setSearchErrorForTest(const QString &err) { m_searchError = err; }
    Q_INVOKABLE QString lastSearchQueryForTest() const { return m_lastSearchQuery; }
    Q_INVOKABLE int     lastSearchLimitForTest() const { return m_lastSearchLimit; }
    Q_INVOKABLE int     lastSearchOffsetForTest() const { return m_lastSearchOffset; }
    Q_INVOKABLE int     searchCountForTest() const { return m_searchCount; }
    Q_INVOKABLE void    resetSearchForTest() {
        m_searchTracks.clear();
        m_searchAlbums.clear();
        m_searchArtists.clear();
        m_searchPlaylists.clear();
        m_searchMixes.clear();
        m_searchError.clear();
        m_lastSearchQuery.clear();
        m_lastSearchLimit = 0;
        m_lastSearchOffset = -1;
        m_searchCount = 0;
        m_recentSearches.clear();
        m_deferSearch = false;
        m_pendingSearches.clear();
    }

    Q_INVOKABLE QString lastClipboardTextForTest() const { return m_lastClipboardText; }
    Q_INVOKABLE QString lastPlaylistPlayedForTest() const { return m_lastPlaylistPlayed; }
    Q_INVOKABLE int  userPlaylistFetchCountForTest() const { return m_userPlaylistFetches; }
    Q_INVOKABLE int  trackCreditsFetchCountForTest() const { return m_trackCreditsFetches; }
    Q_INVOKABLE void resetTrackCreditsFetchCountForTest() { m_trackCreditsFetches = 0; }
    Q_INVOKABLE void resetForTest() {
        m_userPlaylistFetches = 0;
        m_trackCreditsFetches = 0;
        m_lastClipboardText.clear();
        m_lastPlaylistPlayed.clear();
        resetSearchForTest();
        resetHeadersForTest();
        resetCreatePlaylistForTest();
    }

    // The favourites cache the three searches above read. Setting it emits the
    // same signal the real bridge emits when a save or a removal lands, so one
    // call is a whole "the user just saved an album" event: that is what drives
    // HomePage's refresh in tst_home_rows.qml, where the row used to keep what
    // it was built with until the app was restarted. Playlists already have
    // setUserPlaylistsForTest() above, which emits favoritePlaylistsChanged.
    Q_INVOKABLE void setFavoriteAlbumsForTest(const QVariantList &albums) {
        m_favoriteAlbumList = albums;
        emit favoriteAlbumsChanged();
    }
    Q_INVOKABLE void setFavoriteArtistsForTest(const QVariantList &artists) {
        m_favoriteArtistList = artists;
        emit favoriteArtistsChanged();
    }
    Q_INVOKABLE void setFavoriteTracksListForTest(const QVariantList &tracks) {
        m_favoriteTrackList = tracks;
        emit favoriteTracksChanged();
    }

signals:
    void preferredQualityChanged();
    void favoriteTracksChanged();
    void favoriteAlbumsChanged();
    void favoriteArtistsChanged();
    void favoritePlaylistsChanged();
    void recentSearchesChanged();
    // The one row the user just made, carried to the sidebar's own copy of the
    // library. Mirrors TidalBridge::playlistCreated; installTestStubs() hands
    // it to StubLibrary::addPlaylist the way Application::run() hands the real
    // one to LibraryIndex::addPlaylist. A QVariantMap and not a Tidal::Playlist
    // because that is what the stub library deals in.
    void playlistCreated(const QVariantMap &playlist);

private:
    QString m_preferredQuality = QStringLiteral("LOSSLESS");
    QVariantList m_userPlaylists;
    QHash<qlonglong, bool> m_favoriteTracks;
    QHash<qlonglong, bool> m_favoriteAlbums;
    QHash<qlonglong, bool> m_favoriteArtists;
    // The favourite *objects*, as opposed to the id -> bool maps above, which
    // only answer isAlbumFavorite()/isArtistFavorite().
    QVariantList m_favoriteAlbumList;
    QVariantList m_favoriteArtistList;
    QVariantList m_favoriteTrackList;
    QString m_lastClipboardText;
    QString m_lastPlaylistPlayed;
    // The canned hero replies and what was asked for them.
    QVariantMap  m_mixHeader;
    QVariantList m_mixTracks;
    QVariantMap  m_playlist;
    QString      m_headerError;
    QString      m_lastMixPageId;
    QString      m_lastPlaylistFetched;
    int          m_mixPageFetches = 0;
    int          m_playlistFetches = 0;
    bool         m_deferHeaders = false;
    QList<std::pair<QJSValue, QJSValueList>> m_pendingHeaders;

    // Answer now, or hold the reply for flushHeaderRepliesForTest().
    void deliver(QJSValue &cb, const QJSValueList &args) {
        if (m_deferHeaders) { m_pendingHeaders.append({cb, args}); return; }
        cb.call(args);
    }

    // The body of a createPlaylist reply, run either inline or when a held one
    // is released. Built here rather than at call time because the two effects
    // below are what the *server answering* does, and a test that holds a
    // reply is asking for exactly that gap.
    void deliverCreate(QJSValue &cb, const QString &title) {
        QVariantMap p;
        const QString uuid = m_createUuidSet
                                 ? m_createUuid
                                 : QStringLiteral("uuid-created-%1").arg(m_createCalls);
        // The same guard the real bridge applies, and for the same reason: a
        // failed POST, or one whose reply parsed to nothing, must not leave a
        // row in either list.
        if (m_createError.isEmpty() && !uuid.isEmpty()) {
            p.insert(QStringLiteral("uuid"), uuid);
            p.insert(QStringLiteral("title"), title);
            p.insert(QStringLiteral("description"), QString());
            p.insert(QStringLiteral("numTracks"), 0);
            p.insert(QStringLiteral("duration"), 0);
            p.insert(QStringLiteral("coverUrl"), QString());
            p.insert(QStringLiteral("type"), QStringLiteral("USER"));

            bool exists = false;
            for (const QVariant &v : std::as_const(m_userPlaylists))
                if (v.toMap().value(QStringLiteral("uuid")).toString() == uuid) exists = true;
            if (!exists) {
                m_userPlaylists.append(p);
                emit favoritePlaylistsChanged();
            }
            // Outside the dedup, as in the real bridge: the sidebar keeps its
            // own list and dedups for itself.
            emit playlistCreated(p);
        }
        if (!cb.isCallable()) return;
        QJSEngine *e = jsEngine();
        QJSValueList args;
        args << (e ? e->toScriptValue(p) : emptyObject()) << QJSValue(m_createError);
        cb.call(args);
    }

    QString m_createError;
    QString m_createUuid;
    bool    m_createUuidSet = false;
    bool    m_deferCreates  = false;
    QString m_lastCreatedTitle;
    int     m_createCalls = 0;
    QList<std::pair<QJSValue, QString>> m_pendingCreates;
    QString   m_lastAddedPlaylist;
    qlonglong m_lastAddedTrackId   = 0;
    int       m_addToPlaylistCalls = 0;
    bool      m_addToPlaylistOk    = true;
    int     m_userPlaylistFetches = 0;
    int     m_trackCreditsFetches = 0;
    // The canned search reply and what was asked of it.
    QVariantList m_searchTracks;
    QVariantList m_searchAlbums;
    QVariantList m_searchArtists;
    QVariantList m_searchPlaylists;
    QVariantList m_searchMixes;
    QString      m_searchError;
    QString      m_lastSearchQuery;
    int          m_lastSearchLimit = 0;
    int          m_lastSearchOffset = -1;
    int          m_searchCount = 0;
    QStringList  m_recentSearches;
    bool         m_deferSearch = false;
    QList<std::pair<QJSValue, QJSValueList>> m_pendingSearches;

    // {tracks, albums, artists, playlists, mixes} plus the five totals;
    // `filled` false gives the same map with five empty lists and five zeroes,
    // which is what the real bridge sends on an error.
    //
    // Each list is the slice the caller asked for. The total is the length of
    // the whole canned list, which is what lets the page see that there is
    // more behind a full page and nothing behind a short one.
    QJSValue searchPayload(bool filled, int limit, int offset) const {
        QJSEngine *e = jsEngine();
        QJSValue res = e ? e->newObject() : QJSValue();
        if (!res.isObject() || !e) return res;
        const auto page = [&](const QVariantList &l) {
            if (!filled) return e->newArray(0);
            if (offset >= l.size() || limit <= 0) return e->newArray(0);
            return e->toScriptValue(l.mid(offset, limit));
        };
        const auto total = [&](const QVariantList &l) {
            return QJSValue(filled ? int(l.size()) : 0);
        };
        res.setProperty(QStringLiteral("tracks"),    page(m_searchTracks));
        res.setProperty(QStringLiteral("albums"),    page(m_searchAlbums));
        res.setProperty(QStringLiteral("artists"),   page(m_searchArtists));
        res.setProperty(QStringLiteral("playlists"), page(m_searchPlaylists));
        res.setProperty(QStringLiteral("mixes"),     page(m_searchMixes));
        res.setProperty(QStringLiteral("totalTracks"),    total(m_searchTracks));
        res.setProperty(QStringLiteral("totalAlbums"),    total(m_searchAlbums));
        res.setProperty(QStringLiteral("totalArtists"),   total(m_searchArtists));
        res.setProperty(QStringLiteral("totalPlaylists"), total(m_searchPlaylists));
        res.setProperty(QStringLiteral("totalMixes"),     total(m_searchMixes));
        return res;
    }
};

// ─── player ─────────────────────────────────────────────────────────────────

// Mirrors Player (src/player/Player.h) without QMediaPlayer. Transport calls
// only move the stub's own state and emit, so PlayerBar/SeekBar/QueuePanel
// bindings react the way they would against the real player.
class StubPlayer : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
    Q_PROPERTY(QVariantMap currentTrack READ currentTrackMap NOTIFY currentTrackChanged)
    Q_PROPERTY(bool shuffle READ shuffle WRITE setShuffle NOTIFY shuffleChanged)
    Q_PROPERTY(int repeatMode READ repeatMode WRITE setRepeatMode NOTIFY repeatModeChanged)
    Q_PROPERTY(QString audioQuality READ audioQuality NOTIFY currentTrackChanged)
    Q_PROPERTY(int queueCount READ queueCount NOTIFY queueChanged)
    Q_PROPERTY(int queueIndex READ queueIndex NOTIFY currentIndexChanged)
    Q_PROPERTY(QVariantList queueTracks READ queueTracks NOTIFY queueChanged)
    Q_PROPERTY(QVariantList recentlyPlayed READ recentlyPlayed NOTIFY recentlyPlayedChanged)
    Q_PROPERTY(QString sourceType READ sourceType NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceId READ sourceId NOTIFY sourceChanged)
    Q_PROPERTY(QString sourceName READ sourceName NOTIFY sourceChanged)

    // ── the reworked queue (0.4.0) ──────────────────────────────────────
    //
    // One list in play order, exactly as Player holds it: what has played, the
    // track playing, the `m_manualCount` rows the user queued by hand, then
    // the rest of the context. The three slices are views onto that list, not
    // lists of their own.
    //
    // The signalling matters as much as the shape. An *advance* moves the
    // index and shortens the manual run; it does not say the queue changed,
    // because it did not, and because republishing 5000 rows per track is the
    // regression tests/tst_queue_perf.cpp exists to keep out. advanceForTest()
    // below reproduces exactly that, so a view bound to the slices instead of
    // to queueTracks + queueIndex + manualCount is caught here.
    Q_PROPERTY(QVariantList queuePlayed  READ queuePlayed  NOTIFY queueChanged)
    Q_PROPERTY(QVariantList queueManual  READ queueManual  NOTIFY queueChanged)
    Q_PROPERTY(QVariantList queueContext READ queueContext NOTIFY queueChanged)
    Q_PROPERTY(QString contextName READ contextName NOTIFY queueChanged)
    Q_PROPERTY(QString contextType READ contextType NOTIFY queueChanged)
    Q_PROPERTY(int manualCount READ manualCount NOTIFY manualCountChanged)
    // test hook: the calls the view made, in order, so a test can assert the
    // call and its arguments and not only the state they left behind.
    Q_PROPERTY(QStringList queueCalls READ queueCalls NOTIFY queueCallsChanged)
public:
    explicit StubPlayer(QObject *parent = nullptr) : QObject(parent) {}

    bool         playing() const { return m_playing; }
    bool         loading() const { return m_loading; }
    qint64       position() const { return m_position; }
    qint64       duration() const { return m_duration; }
    double       volume() const { return m_volume; }
    bool         muted() const { return m_muted; }
    QVariantMap  currentTrackMap() const { return m_currentTrack; }
    bool         shuffle() const { return m_shuffle; }
    int          repeatMode() const { return m_repeatMode; }
    QString      audioQuality() const { return m_audioQuality; }
    int          queueCount() const { return int(m_queue.size()); }
    int          queueIndex() const { return m_index; }
    QVariantList queueTracks() const { return m_queue; }
    QVariantList recentlyPlayed() const { return m_recentlyPlayed; }
    QString      sourceType() const { return m_sourceType; }
    QString      sourceId() const { return m_sourceId; }
    QString      sourceName() const { return m_sourceName; }

    // Mirrors Player::qualityLabel exactly, rather than returning nothing.
    //
    // It used to return {} for every input, and that quietly blinded everything
    // that looks at the quality badge: both badges are gated on
    // `player.audioQuality.length > 0`, so with a quality set they were visible
    // and *empty*, and every visual shot and every QML assertion about them was
    // looking at a coloured box with no word in it. A stub that answers nothing
    // is worse than no stub, because the test still passes.
    Q_INVOKABLE QString qualityLabel(const QString &code) const {
        if (code == QStringLiteral("HI_RES_LOSSLESS")) return QStringLiteral("Max");
        if (code == QStringLiteral("LOSSLESS"))        return QStringLiteral("Lossless");
        if (code == QStringLiteral("HIGH"))            return QStringLiteral("High");
        if (code == QStringLiteral("LOW"))             return QStringLiteral("Low");
        return code;   // Player echoes a code it does not know; so does this.
    }

    Q_INVOKABLE void setPlaybackSource(const QString &type, const QString &id, const QString &name) {
        m_sourceType = type;
        m_sourceId   = id;
        m_sourceName = name;
        emit sourceChanged();
    }

    Q_INVOKABLE void playTracks(const QVariantList &tracks, int startIndex = 0) {
        m_queue = tracks;
        m_index = tracks.isEmpty() ? -1 : qBound(0, startIndex, int(tracks.size()) - 1);
        m_currentTrack = m_index < 0 ? QVariantMap() : tracks.at(m_index).toMap();
        setManualCount(0);
        emit queueChanged();
        emit currentIndexChanged(m_index);
        emit currentTrackChanged();
        setPlayingForTest(m_index >= 0);
    }
    Q_INVOKABLE void appendQueue(const QVariantList &tracks) {
        m_queue += tracks;
        emit queueChanged();
    }
    Q_INVOKABLE void jumpToQueue(int index) {
        if (index < 0 || index >= m_queue.size()) return;
        m_index = index;
        m_currentTrack = m_queue.at(index).toMap();
        emit queueChanged();
        emit currentIndexChanged(m_index);
        emit currentTrackChanged();
    }
    Q_INVOKABLE void clearQueue() {
        m_queue.clear();
        m_index = -1;
        setManualCount(0);
        emit queueChanged();
        emit currentIndexChanged(m_index);
    }
    Q_INVOKABLE void removeFromQueue(int index) {
        if (index < 0 || index >= m_queue.size()) return;
        m_queue.removeAt(index);
        if (m_index >= m_queue.size()) m_index = int(m_queue.size()) - 1;
        emit queueChanged();
        emit currentIndexChanged(m_index);
    }
    Q_INVOKABLE void moveQueueItem(int from, int to) {
        if (from < 0 || from >= m_queue.size() || to < 0 || to >= m_queue.size()) return;
        m_queue.move(from, to);
        emit queueChanged();
    }

    Q_INVOKABLE void playPause() { setPlayingForTest(!m_playing); }
    Q_INVOKABLE void next() { jumpToQueue(m_index + 1); }
    Q_INVOKABLE void previous() { jumpToQueue(m_index - 1); }
    Q_INVOKABLE void seek(qint64 ms) {
        m_position = ms;
        emit positionChanged(m_position);
    }
    Q_INVOKABLE void setVolume(double v) {
        if (qFuzzyCompare(m_volume, v)) return;
        m_volume = v;
        emit volumeChanged(m_volume);
    }
    Q_INVOKABLE void setMuted(bool m) {
        if (m_muted == m) return;
        m_muted = m;
        emit mutedChanged(m_muted);
    }
    Q_INVOKABLE void setShuffle(bool s) {
        if (m_shuffle == s) return;
        m_shuffle = s;
        emit shuffleChanged(m_shuffle);
    }
    Q_INVOKABLE void setRepeatMode(int m) {
        if (m_repeatMode == m) return;
        m_repeatMode = m;
        emit repeatModeChanged(m_repeatMode);
    }

    Q_INVOKABLE QVariantMap queueTrackAt(int index) const {
        if (index < 0 || index >= m_queue.size()) return {};
        return m_queue.at(index).toMap();
    }
    Q_INVOKABLE QVariantList upcomingTracks(int max = -1) const {
        QVariantList out;
        for (int i = m_index + 1; i >= 0 && i < m_queue.size(); ++i) {
            if (max >= 0 && out.size() >= max) break;
            out << m_queue.at(i);
        }
        return out;
    }
    Q_INVOKABLE QVariantList playbackOrderTracks() const { return m_queue; }

    // ── the reworked queue (0.4.0) ──────────────────────────────────────

    int manualCount() const { return m_manualCount; }

    QVariantList queuePlayed() const {
        QVariantList out;
        const int end = qMax(0, qMin(m_index, int(m_queue.size())));
        for (int i = 0; i < end; ++i) out << m_queue.at(i);
        return out;
    }
    QVariantList queueManual() const {
        QVariantList out;
        for (int i = 0; i < m_manualCount; ++i) {
            const int at = m_index + 1 + i;
            if (at >= 0 && at < m_queue.size()) out << m_queue.at(at);
        }
        return out;
    }
    QVariantList queueContext() const {
        QVariantList out;
        for (int i = qMax(0, m_index + 1 + m_manualCount); i < m_queue.size(); ++i)
            out << m_queue.at(i);
        return out;
    }
    QString contextName() const { return m_sourceName; }
    QString contextType() const { return m_sourceType; }
    QStringList queueCalls() const { return m_queueCalls; }

    Q_INVOKABLE void playNext(const QVariantList &tracks) {
        note(QStringLiteral("playNext %1").arg(tracks.size()));
        insertManual(tracks, 0);
    }
    Q_INVOKABLE void addToQueue(const QVariantList &tracks) {
        note(QStringLiteral("addToQueue %1").arg(tracks.size()));
        insertManual(tracks, m_manualCount);
    }
    Q_INVOKABLE void removeManual(int index) {
        note(QStringLiteral("removeManual %1").arg(index));
        if (index < 0 || index >= m_manualCount) return;
        m_queue.removeAt(m_index + 1 + index);
        setManualCount(m_manualCount - 1);
        emit queueChanged();
    }
    Q_INVOKABLE void moveManual(int from, int to) {
        note(QStringLiteral("moveManual %1 %2").arg(from).arg(to));
        if (from < 0 || from >= m_manualCount ||
            to   < 0 || to   >= m_manualCount || from == to) return;
        m_queue.move(m_index + 1 + from, m_index + 1 + to);
        emit queueChanged();
    }
    Q_INVOKABLE void clearManual() {
        note(QStringLiteral("clearManual"));
        if (m_manualCount <= 0) return;
        for (int i = 0; i < m_manualCount; ++i) m_queue.removeAt(m_index + 1);
        setManualCount(0);
        emit queueChanged();
    }
    // Playing a manual row consumes it and everything queued ahead of it.
    Q_INVOKABLE void jumpToManual(int index) {
        note(QStringLiteral("jumpToManual %1").arg(index));
        if (index < 0 || index >= m_manualCount) return;
        const int start = m_index + 1;
        for (int i = 0; i < index; ++i) m_queue.removeAt(start);
        setManualCount(m_manualCount - index - 1);
        m_index = start;
        m_currentTrack = m_queue.at(m_index).toMap();
        emit queueChanged();
        emit currentIndexChanged(m_index);
        emit currentTrackChanged();
    }
    Q_INVOKABLE void jumpToContext(int index) {
        note(QStringLiteral("jumpToContext %1").arg(index));
        if (index < 0) return;
        jumpToQueue(m_index + m_manualCount + 1 + index);
    }
    Q_INVOKABLE void jumpToPlayed(int index) {
        note(QStringLiteral("jumpToPlayed %1").arg(index));
        if (index < 0 || index >= qMax(0, m_index)) return;
        jumpToQueue(index);
    }

    // Replaces whatever manual run is there, in place, where the real Player
    // keeps it: immediately after the current track.
    Q_INVOKABLE void setManualForTest(const QVariantList &tracks) {
        for (int i = 0; i < m_manualCount && m_index + 1 < m_queue.size(); ++i)
            m_queue.removeAt(m_index + 1);
        const int base = qBound(0, m_index + 1, int(m_queue.size()));
        for (int i = 0; i < tracks.size(); ++i) {
            QVariantMap t = tracks.at(i).toMap();
            t[QStringLiteral("_userQueued")] = true;
            m_queue.insert(base + i, t);
        }
        setManualCount(int(tracks.size()));
        emit queueChanged();
    }
    // A track ending, reported the way the real Player reports it: the index
    // moves, the manual run shortens, and *nothing* says the queue changed,
    // because nothing about the queue did.
    Q_INVOKABLE void advanceForTest() {
        if (m_index + 1 >= m_queue.size()) return;
        if (m_manualCount > 0) setManualCount(m_manualCount - 1);
        m_index += 1;
        m_currentTrack = m_queue.at(m_index).toMap();
        emit currentIndexChanged(m_index);
        emit currentTrackChanged();
    }
    Q_INVOKABLE void resetQueueCallsForTest() {
        m_queueCalls.clear();
        emit queueCallsChanged();
    }

    // test hooks
    Q_INVOKABLE void setCurrentTrackForTest(const QVariantMap &track) {
        m_currentTrack = track;
        emit currentTrackChanged();
    }
    Q_INVOKABLE void setPlayingForTest(bool playing) {
        if (m_playing == playing) return;
        m_playing = playing;
        emit playingChanged(m_playing);
    }
    Q_INVOKABLE void setLoadingForTest(bool loading) {
        if (m_loading == loading) return;
        m_loading = loading;
        emit loadingChanged(m_loading);
    }
    Q_INVOKABLE void setDurationForTest(qint64 ms) {
        m_duration = ms;
        emit durationChanged(m_duration);
    }
    Q_INVOKABLE void setPositionForTest(qint64 ms) { seek(ms); }
    Q_INVOKABLE void setAudioQualityForTest(const QString &q) {
        m_audioQuality = q;
        emit currentTrackChanged();
    }
    Q_INVOKABLE void setQueueForTest(const QVariantList &tracks, int index = -1) {
        m_queue = tracks;
        m_index = index;
        setManualCount(0);          // a brand new queue has no manual run in it
        emit queueChanged();
        emit currentIndexChanged(m_index);
    }
    Q_INVOKABLE void setRecentlyPlayedForTest(const QVariantList &tracks) {
        m_recentlyPlayed = tracks;
        emit recentlyPlayedChanged();
    }
    Q_INVOKABLE void emitErrorForTest(const QString &msg) { emit error(msg); }

signals:
    void playingChanged(bool playing);
    void loadingChanged(bool loading);
    void positionChanged(qint64 ms);
    void durationChanged(qint64 ms);
    void volumeChanged(double v);
    void mutedChanged(bool m);
    void currentTrackChanged();
    void shuffleChanged(bool s);
    void repeatModeChanged(int m);
    void queueChanged();
    void recentlyPlayedChanged();
    void currentIndexChanged(int index);
    void manualCountChanged(int count);
    void queueCallsChanged();
    void sourceChanged();
    void castTrackChanged();
    void error(const QString &msg);

private:
    bool         m_playing = false;
    bool         m_loading = false;
    qint64       m_position = 0;
    qint64       m_duration = 0;
    double       m_volume = 0.7;   // same default as Player, so VolumeSlider looks real
    bool         m_muted = false;
    QVariantMap  m_currentTrack;
    bool         m_shuffle = false;
    int          m_repeatMode = 0;
    QString      m_audioQuality;
    QVariantList m_queue;
    QVariantList m_recentlyPlayed;
    int          m_index = -1;
    QString      m_sourceType;
    QString      m_sourceId;
    QString      m_sourceName;
    int          m_manualCount = 0;
    QStringList  m_queueCalls;

    void setManualCount(int n) {
        if (m_manualCount == n) return;
        m_manualCount = n;
        emit manualCountChanged(m_manualCount);
    }

    void insertManual(const QVariantList &tracks, int at) {
        if (tracks.isEmpty()) return;
        const int base = qBound(0, m_index + 1 + qBound(0, at, m_manualCount),
                                int(m_queue.size()));
        for (int i = 0; i < tracks.size(); ++i) {
            QVariantMap t = tracks.at(i).toMap();
            // Legacy marker, kept because the old panel styled rows by it.
            t[QStringLiteral("_userQueued")] = true;
            m_queue.insert(base + i, t);
        }
        setManualCount(m_manualCount + int(tracks.size()));
        emit queueChanged();
    }

    void note(const QString &call) {
        m_queueCalls << call;
        emit queueCallsChanged();
    }
};

// ─── cast ───────────────────────────────────────────────────────────────────

// Mirrors CastManager (src/cast/CastManager.h). Note: the real class also names
// an invokable `disconnect()`, which hides QObject::disconnect — kept identical
// so QML calling cast.disconnect() behaves the same.
class StubCast : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QString deviceName READ deviceName NOTIFY connectedChanged)
public:
    explicit StubCast(QObject *parent = nullptr) : QObject(parent) {}

    QVariantList devices() const { return m_devices; }
    bool         connected() const { return m_connected; }
    QString      deviceName() const { return m_deviceName; }

    Q_INVOKABLE void startScan() { m_scanCount++; }
    Q_INVOKABLE void connectToDevice(const QString &id) {
        m_lastConnectId = id;
        m_connected = true;
        m_deviceName = id;
        emit connectedChanged();
    }
    Q_INVOKABLE void disconnect() {
        m_connected = false;
        m_deviceName.clear();
        emit connectedChanged();
    }

    // test hooks
    Q_INVOKABLE void setDevicesForTest(const QVariantList &devices) {
        m_devices = devices;
        emit devicesChanged();
    }
    Q_INVOKABLE int scanCountForTest() const { return m_scanCount; }
    Q_INVOKABLE QString lastConnectIdForTest() const { return m_lastConnectId; }
    Q_INVOKABLE void emitErrorForTest(const QString &msg) { emit error(msg); }

signals:
    void devicesChanged();
    void connectedChanged();
    void error(const QString &msg);

private:
    QVariantList m_devices;
    bool    m_connected = false;
    QString m_deviceName;
    int     m_scanCount = 0;
    QString m_lastConnectId;
};

// ─── app ────────────────────────────────────────────────────────────────────

// Mirrors the QML-visible part of Application (src/ui/Application.h): the
// reallyQuit property plus quit()/openUrl(). No tray icon, no QML engine, and
// quit() does not touch QCoreApplication — a test quitting the app would kill
// the test run.
class StubApp : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool reallyQuit READ reallyQuit NOTIFY reallyQuitChanged)
    Q_PROPERTY(bool reducedMotion READ reducedMotion NOTIFY reducedMotionChanged)
public:
    explicit StubApp(QObject *parent = nullptr) : QObject(parent) {}

    bool reallyQuit() const { return m_reallyQuit; }
    bool reducedMotion() const { return m_reducedMotion; }

    // The Settings "Interface size" slider takes its range from the real
    // Application, which clamps the top end by what the screen can hold. The
    // stub answers with the same constants and a fixed ceiling: a test has no
    // screen, and a ceiling that moved with the test machine's monitor would
    // make the slider's range untestable.
    Q_INVOKABLE double minScaleFactor() const     { return 1.0; }
    Q_INVOKABLE double maxUsableScaleFactor() const { return 3.0; }
    Q_INVOKABLE double scaleFactorStep() const    { return 0.25; }

    // The three scale facts the Settings panel asks about. Settable, because
    // what the panel does with them is the thing under test: an environment
    // override has to disable the slider, and an automatically derived factor
    // has to explain itself.
    bool   m_scaleEnvOverride = false;
    bool   m_scaleWasAutomatic = false;
    double m_activeScale = 1.0;
    Q_INVOKABLE bool   scaleIsEnvironmentOverridden() const { return m_scaleEnvOverride; }
    Q_INVOKABLE bool   scaleWasChosenAutomatically() const  { return m_scaleWasAutomatic; }
    Q_INVOKABLE double activeScaleFactor() const            { return m_activeScale; }
    Q_INVOKABLE void setScaleFactsForTest(bool envOverride, bool automatic, double active) {
        m_scaleEnvOverride = envOverride;
        m_scaleWasAutomatic = automatic;
        m_activeScale = active;
    }

    Q_INVOKABLE void quit() {
        m_quitCount++;
        if (m_reallyQuit) return;
        m_reallyQuit = true;
        emit reallyQuitChanged();
    }
    Q_INVOKABLE void openUrl(const QString &url) {
        if (url.isEmpty()) return;
        m_openedUrls << url;
    }

    // test hooks
    Q_INVOKABLE int quitCountForTest() const { return m_quitCount; }
    Q_INVOKABLE QStringList openedUrlsForTest() const { return m_openedUrls; }
    Q_INVOKABLE QString lastOpenedUrlForTest() const {
        return m_openedUrls.isEmpty() ? QString() : m_openedUrls.last();
    }
    Q_INVOKABLE void setReducedMotionForTest(bool on) {
        if (m_reducedMotion == on) return;
        m_reducedMotion = on;
        emit reducedMotionChanged();
    }
    Q_INVOKABLE void resetForTest() {
        m_quitCount = 0;
        m_openedUrls.clear();
        setReducedMotionForTest(false);
        if (m_reallyQuit) {
            m_reallyQuit = false;
            emit reallyQuitChanged();
        }
    }

signals:
    void reallyQuitChanged();
    void reducedMotionChanged();

private:
    bool        m_reallyQuit = false;
    bool        m_reducedMotion = false;
    int         m_quitCount = 0;
    QStringList m_openedUrls;
};

// ─── downloader ─────────────────────────────────────────────────────────────

// Mirrors Downloader (src/player/Downloader.h). downloadTrack() would otherwise
// open a native save dialog and shell out to ffmpeg, so here it only records the
// track and emits downloadStarted/downloadFinished.
class StubDownloader : public QObject {
    Q_OBJECT
public:
    explicit StubDownloader(QObject *parent = nullptr) : QObject(parent) {}

    Q_INVOKABLE void downloadTrack(const QVariantMap &track) {
        m_lastTrack = track;
        const qlonglong id = track.value(QStringLiteral("id")).toLongLong();
        m_active.insert(id);
        emit downloadStarted(id);
    }
    Q_INVOKABLE bool isDownloading(qlonglong id) const { return m_active.contains(id); }
    Q_INVOKABLE void cancelDownload(qlonglong id) { m_active.remove(id); }

    // test hooks — QML cannot emit C++ signals, so tests drive the download
    // lifecycle (TrackRow/NowPlayingPage listen for all three) from here.
    Q_INVOKABLE void emitDownloadStartedForTest(qlonglong id) {
        m_active.insert(id);
        emit downloadStarted(id);
    }
    Q_INVOKABLE void emitDownloadFinishedForTest(qlonglong id, const QString &path) {
        m_active.remove(id);
        emit downloadFinished(id, path);
    }
    Q_INVOKABLE void emitDownloadErrorForTest(qlonglong id, const QString &msg) {
        m_active.remove(id);
        emit downloadError(id, msg);
    }
    Q_INVOKABLE QVariantMap lastTrackForTest() const { return m_lastTrack; }

signals:
    void downloadStarted(qlonglong id);
    void downloadFinished(qlonglong id, const QString &path);
    void downloadError(qlonglong id, const QString &msg);

private:
    QSet<qlonglong> m_active;
    QVariantMap     m_lastTrack;
};

// ─── image provider ─────────────────────────────────────────────────────────

// The app registers TidalImageProvider for "image://tidal/..." URLs, and that
// one really hits the network. This returns a blank image synchronously instead,
// so tests stay offline and no page logs "Invalid image provider".
class StubImageProvider : public QQuickImageProvider {
public:
    StubImageProvider() : QQuickImageProvider(QQuickImageProvider::Image) {}

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override {
        Q_UNUSED(id);
        const QSize s(requestedSize.width()  > 0 ? requestedSize.width()  : 1,
                      requestedSize.height() > 0 ? requestedSize.height() : 1);
        QImage img(s, QImage::Format_ARGB32_Premultiplied);
        img.fill(Qt::transparent);
        if (size) *size = s;
        return img;
    }
};

// ─── prefs ──────────────────────────────────────────────────────────────────

// Mirrors Prefs (src/ui/Prefs.h) in memory. Without this the sidebar logged
// "ReferenceError: prefs is not defined" in every QML test and then laid itself
// out against undefined widths.
//
// In memory on purpose: the real Prefs writes through QSettings, which in a test
// binary means a file under the user's own config directory, and a persistence
// test that depends on one is a test that fails differently on every machine.
// Prefs' own round-tripping is covered by tst_prefs; what the QML has to get
// right is that it writes the dragged width here at all, and reads it back when
// a fresh sidebar is built.
class StubPrefs : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString theme READ theme WRITE setTheme NOTIFY themeChanged)
    Q_PROPERTY(bool oledBlack READ oledBlack WRITE setOledBlack NOTIFY oledBlackChanged)
    Q_PROPERTY(bool tintedGreys READ tintedGreys WRITE setTintedGreys NOTIFY tintedGreysChanged)
    // 0 is Auto, exactly as in the real Prefs - not "unset".
    Q_PROPERTY(double uiScale READ uiScale WRITE setUiScale NOTIFY uiScaleChanged)
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
    Q_PROPERTY(int sidebarWidth READ sidebarWidth WRITE setSidebarWidth NOTIFY sidebarWidthChanged)
    Q_PROPERTY(QString audioDevice READ audioDevice WRITE setAudioDevice NOTIFY audioDeviceChanged)
    Q_PROPERTY(bool softwareRendering READ softwareRendering WRITE setSoftwareRendering NOTIFY softwareRenderingChanged)
    Q_PROPERTY(bool quitOnClose READ quitOnClose WRITE setQuitOnClose NOTIFY quitOnCloseChanged)
    // The fullscreen Now Playing background pulled out of the cover art.
    // Defaulted on here, as in the real Prefs: a QML test that says nothing
    // about it measures the state a fresh install is in.
    Q_PROPERTY(bool coverGradient READ coverGradient WRITE setCoverGradient NOTIFY coverGradientChanged)
    // The now-playing bars show a spectrum of what is playing instead of
    // their own animation. Off, like the real preference, and like it the
    // property is read by name rather than by type - SpectrumAnalyzer
    // connects to whatever notifying "spectrumBars" its source carries, so
    // this stub is a complete substitute for Prefs as far as it is
    // concerned.
    Q_PROPERTY(bool spectrumBars READ spectrumBars WRITE setSpectrumBars NOTIFY spectrumBarsChanged)
public:
    explicit StubPrefs(QObject *parent = nullptr) : QObject(parent) {}

    // Same numbers as Prefs::minSidebarWidth and friends. Kept as literals
    // rather than pulled from Prefs so a change there shows up as a failing
    // assertion here instead of quietly agreeing with itself.
    static constexpr int kMinSidebar    = 190;
    static constexpr int kMaxSidebar    = 420;
    static constexpr int kRailBreak     = 820;
    static constexpr int kRail          = 68;

    QString theme() const        { return m_theme; }
    bool    oledBlack() const    { return m_oledBlack; }
    bool    tintedGreys() const  { return m_tintedGreys; }
    double  uiScale() const      { return m_uiScale; }
    void    setUiScale(double v) {
        if (qFuzzyCompare(v + 1.0, m_uiScale + 1.0)) return;
        m_uiScale = v;
        emit uiScaleChanged();
    }
    QString language() const     { return m_language; }
    int     sidebarWidth() const { return m_sidebarWidth; }
    QString audioDevice() const  { return m_audioDevice; }
    bool    softwareRendering() const { return m_softwareRendering; }
    bool    quitOnClose() const       { return m_quitOnClose; }
    bool    coverGradient() const     { return m_coverGradient; }
    bool    spectrumBars() const      { return m_spectrumBars; }

    void setTheme(const QString &v) {
        if (v.isEmpty() || v == m_theme) return;
        m_theme = v;
        emit themeChanged();
    }
    void setOledBlack(bool v) {
        if (v == m_oledBlack) return;
        m_oledBlack = v;
        emit oledBlackChanged();
    }
    void setTintedGreys(bool v) {
        if (v == m_tintedGreys) return;
        m_tintedGreys = v;
        emit tintedGreysChanged();
    }
    void setLanguage(const QString &v) {
        if (v == m_language) return;
        m_language = v;
        emit languageChanged();
    }
    void setSidebarWidth(int v) {
        const int clamped = qBound(kMinSidebar, v, kMaxSidebar);
        if (clamped == m_sidebarWidth) return;
        m_sidebarWidth = clamped;
        emit sidebarWidthChanged();
    }
    void setAudioDevice(const QString &v) {
        if (v == m_audioDevice) return;
        m_audioDevice = v;
        emit audioDeviceChanged();
    }
    void setSoftwareRendering(bool v) {
        if (v == m_softwareRendering) return;
        m_softwareRendering = v;
        emit softwareRenderingChanged();
    }
    void setQuitOnClose(bool v) {
        if (v == m_quitOnClose) return;
        m_quitOnClose = v;
        emit quitOnCloseChanged();
    }
    void setCoverGradient(bool v) {
        if (v == m_coverGradient) return;
        m_coverGradient = v;
        emit coverGradientChanged();
    }
    void setSpectrumBars(bool v) {
        if (v == m_spectrumBars) return;
        m_spectrumBars = v;
        emit spectrumBarsChanged();
    }

    Q_INVOKABLE int minSidebar() const   { return kMinSidebar; }
    Q_INVOKABLE int maxSidebar() const   { return kMaxSidebar; }
    Q_INVOKABLE int railBreak() const    { return kRailBreak; }
    Q_INVOKABLE int rail() const         { return kRail; }

    Q_INVOKABLE QString appVersion() const { return m_version; }

    // test hooks
    Q_INVOKABLE void setSidebarWidthForTest(int v) { setSidebarWidth(v); }
    Q_INVOKABLE void setAppVersionForTest(const QString &v) { m_version = v; }

signals:
    void themeChanged();
    void oledBlackChanged();
    void tintedGreysChanged();
    void uiScaleChanged();
    void languageChanged();
    void sidebarWidthChanged();
    void audioDeviceChanged();
    void softwareRenderingChanged();
    void quitOnCloseChanged();
    void coverGradientChanged();
    void spectrumBarsChanged();

private:
    QString m_theme    = QStringLiteral("sea");
    // Off, unlike the real Prefs, so a QML test that says nothing about it
    // measures the palette as written in the table rather than the pulled
    // down one. The tests that care about the transform set it themselves.
    bool    m_oledBlack = false;
    // Off, as in the real Prefs: the six palettes share one grey ramp per mode
    // until a test asks for the tinted grounds. A QML test that says nothing
    // about it therefore measures the state a fresh install is in.
    bool    m_tintedGreys = false;
    double  m_uiScale = 0.0;
    QString m_language = QStringLiteral("system");
    int     m_sidebarWidth = 220;
    QString m_audioDevice;
    bool    m_softwareRendering = false;
    bool    m_quitOnClose = false;
    bool    m_coverGradient = true;
    bool    m_spectrumBars = false;
    QString m_version = QStringLiteral("0.4.0");
};

// ─── pins ───────────────────────────────────────────────────────────────────

// Mirrors PinStore (src/ui/PinStore.h) in memory. A pin is
// {kind, id, title, subtitle, imageUrl}; order is whatever the test sets.
class StubPins : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList items READ items NOTIFY changed)
public:
    explicit StubPins(QObject *parent = nullptr) : QObject(parent) {}

    QVariantList items() const { return m_items; }

    Q_INVOKABLE int indexOf(const QString &kind, const QString &id) const {
        for (int i = 0; i < m_items.size(); ++i) {
            const QVariantMap m = m_items.at(i).toMap();
            if (m.value(QStringLiteral("kind")).toString() == kind
                && m.value(QStringLiteral("id")).toString() == id)
                return i;
        }
        return -1;
    }
    Q_INVOKABLE bool isPinned(const QString &kind, const QString &id) const {
        return indexOf(kind, id) >= 0;
    }
    Q_INVOKABLE void pin(const QString &kind, const QString &id, const QString &title,
                         const QString &subtitle, const QString &imageUrl) {
        if (isPinned(kind, id)) return;
        QVariantMap m;
        m[QStringLiteral("kind")]     = kind;
        m[QStringLiteral("id")]       = id;
        m[QStringLiteral("title")]    = title;
        m[QStringLiteral("subtitle")] = subtitle;
        m[QStringLiteral("imageUrl")] = imageUrl;
        m_items.append(m);
        emit changed();
    }
    Q_INVOKABLE void unpin(const QString &kind, const QString &id) {
        const int i = indexOf(kind, id);
        if (i < 0) return;
        m_items.removeAt(i);
        emit changed();
    }
    Q_INVOKABLE void toggle(const QString &kind, const QString &id, const QString &title,
                            const QString &subtitle, const QString &imageUrl) {
        if (isPinned(kind, id)) unpin(kind, id);
        else                    pin(kind, id, title, subtitle, imageUrl);
    }
    Q_INVOKABLE void move(int from, int to) {
        if (from < 0 || to < 0 || from >= m_items.size() || to >= m_items.size()) return;
        m_items.move(from, to);
        emit changed();
    }

    // test hooks
    Q_INVOKABLE void setItemsForTest(const QVariantList &items) {
        m_items = items;
        emit changed();
    }

signals:
    void changed();

private:
    QVariantList m_items;
};

// ─── library ────────────────────────────────────────────────────────────────

// Mirrors LibraryIndex (src/api/LibraryIndex.h). The real one pages the whole
// account in over the network and then indexes saved tracklists in the
// background; here the rows are set by hand.
//
// search() is a plain case-insensitive substring match over the entries plus the
// song index, filtered by `kinds`. It is not the real scoring (tst_library owns
// that) — it only has to answer the way the real one does so the QML above it
// can be tested: entries for the library list, songs for the search only.
class StubLibrary : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList entries READ entries NOTIFY entriesChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool indexing READ indexing NOTIFY indexingChanged)
public:
    explicit StubLibrary(QObject *parent = nullptr) : QObject(parent) {}

    QVariantList entries() const { return m_entries; }
    bool loading() const  { return m_loading; }
    bool indexing() const { return m_indexing; }

    Q_INVOKABLE void refresh() { m_refreshes++; }
    Q_INVOKABLE void markPlayed(const QString &kind, const QString &id) {
        m_lastPlayed = kind + QLatin1Char(':') + id;
    }
    // The song half of the same thing - see LibraryIndex::markTrackPlayed. It
    // has to exist here or PlayerBar throws a TypeError on every track change
    // in a QML test.
    Q_INVOKABLE void markTrackPlayed(const QString &id) {
        m_lastTrackPlayed = id;
    }
    Q_INVOKABLE void cancelIndexing() { m_indexing = false; emit indexingChanged(); }
    Q_INVOKABLE int  indexedAlbumCount() const { return 0; }

    Q_INVOKABLE QVariantList search(const QString &query, const QStringList &kinds) const {
        auto *self = const_cast<StubLibrary *>(this);
        self->m_lastQuery = query;
        self->m_lastKinds = kinds;
        self->m_searches++;

        const QString needle = query.trimmed().toCaseFolded();
        QVariantList out;
        if (needle.isEmpty()) return out;

        const auto scan = [&](const QVariantList &src) {
            for (const QVariant &v : src) {
                const QVariantMap m = v.toMap();
                if (!kinds.isEmpty() && !kinds.contains(m.value(QStringLiteral("kind")).toString()))
                    continue;
                if (m.value(QStringLiteral("title")).toString().toCaseFolded().contains(needle))
                    out.append(m);
            }
        };
        scan(m_entries);
        scan(m_tracks);
        return out;
    }

    // The browse-by-kind path, mirroring LibraryIndex::entriesForKinds: the
    // `entries` property holds the browsable kinds and leaves songs out, so a
    // caller that filters `entries` in QML can never find a track. That was a
    // real bug - the finder's Tracks chip said "Nothing saved yet" with nothing
    // typed, while the same chip worked as soon as anything was - so the stub
    // has to have the same two sources as the real thing or a test could not
    // tell the difference.
    Q_INVOKABLE QVariantList entriesForKinds(const QStringList &kinds) const {
        if (kinds.isEmpty()) return m_entries;
        QVariantList out;
        const auto take = [&](const QVariantList &src) {
            for (const QVariant &v : src) {
                const QVariantMap m = v.toMap();
                if (kinds.contains(m.value(QStringLiteral("kind")).toString()))
                    out.append(m);
            }
        };
        take(m_entries);
        take(m_tracks);
        return out;
    }

    // The one row the user just made, mirroring LibraryIndex::addPlaylist.
    //
    // installTestStubs() connects StubBridge::playlistCreated to this, the way
    // Application::run() connects the real pair. The sidebar is a *second*
    // copy of the account's library - TidalBridge keeps the first - so without
    // the hand-across a created playlist would reach the Collection page and
    // not the sidebar, which is half of what the New-playlist dialog has to
    // be shown to do.
    //
    // Inserted at the head of the unpinned block rather than appended,
    // because that is where the real index puts it: addPlaylist() stamps the
    // row as of now and rebuild() orders the unpinned tier newest first.
    // Appending here would let a sidebar that quietly dropped the stamp still
    // look right in a test.
    void addPlaylist(const QVariantMap &p) {
        const QString uuid = p.value(QStringLiteral("uuid")).toString();
        if (uuid.isEmpty()) return;
        for (const QVariant &v : std::as_const(m_entries)) {
            const QVariantMap m = v.toMap();
            if (m.value(QStringLiteral("kind")).toString() == QLatin1String("playlist")
                && m.value(QStringLiteral("id")).toString() == uuid)
                return;
        }
        QVariantMap row;
        row.insert(QStringLiteral("kind"),       QStringLiteral("playlist"));
        row.insert(QStringLiteral("id"),         uuid);
        row.insert(QStringLiteral("title"),      p.value(QStringLiteral("title")).toString());
        row.insert(QStringLiteral("subtitle"),   QString());
        row.insert(QStringLiteral("imageUrl"),   p.value(QStringLiteral("coverUrl")).toString());
        row.insert(QStringLiteral("pinned"),     false);
        row.insert(QStringLiteral("trackCount"), p.value(QStringLiteral("numTracks")).toInt());

        int at = 0;
        while (at < m_entries.size()
               && m_entries.at(at).toMap().value(QStringLiteral("pinned")).toBool())
            ++at;
        m_entries.insert(at, row);
        emit entriesChanged();
    }

    // test hooks
    Q_INVOKABLE void setEntriesForTest(const QVariantList &rows) {
        m_entries = rows;
        emit entriesChanged();
    }
    Q_INVOKABLE void setTracksForTest(const QVariantList &rows) { m_tracks = rows; }
    Q_INVOKABLE void setLoadingForTest(bool v)  { m_loading = v;  emit loadingChanged(); }
    Q_INVOKABLE void setIndexingForTest(bool v) { m_indexing = v; emit indexingChanged(); }
    Q_INVOKABLE QString     lastQueryForTest() const { return m_lastQuery; }
    Q_INVOKABLE QStringList lastKindsForTest() const { return m_lastKinds; }
    Q_INVOKABLE QString     lastPlayedForTest() const { return m_lastPlayed; }
    Q_INVOKABLE QString     lastTrackPlayedForTest() const { return m_lastTrackPlayed; }
    Q_INVOKABLE int         refreshCountForTest() const { return m_refreshes; }
    Q_INVOKABLE int         searchCountForTest() const { return m_searches; }
    Q_INVOKABLE void resetCallsForTest() {
        m_lastQuery.clear();
        m_lastKinds.clear();
        m_lastPlayed.clear();
        m_lastTrackPlayed.clear();
        m_refreshes = 0;
        m_searches  = 0;
    }

signals:
    void entriesChanged();
    void loadingChanged();
    void indexingChanged();

private:
    QVariantList m_entries;
    QVariantList m_tracks;
    bool         m_loading  = false;
    bool         m_indexing = false;
    QString      m_lastQuery;
    QStringList  m_lastKinds;
    QString      m_lastPlayed;
    QString      m_lastTrackPlayed;
    int          m_refreshes = 0;
    int          m_searches  = 0;
};

// ─── installation ───────────────────────────────────────────────────────────

// Handles to the installed stubs, so a C++ test can poke state directly.
// ─── update check ───────────────────────────────────────────────────────────

// Mirrors UpdateCheck (src/ui/UpdateCheck.h) with no network. Registered as
// "updateCheck", not "update": QQuickItem and QQuickWindow both already have
// an update() slot, so the shorter name is shadowed inside any Item.
//
// Defaults to "enabled, nothing available", which is what a launch with no
// newer release looks like, so no test sees a prompt it did not ask for.
class StubUpdateCheck : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY updateChanged)
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY updateChanged)
    Q_PROPERTY(QString releaseUrl READ releaseUrl NOTIFY updateChanged)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
public:
    explicit StubUpdateCheck(QObject *parent = nullptr) : QObject(parent) {}

    bool    updateAvailable() const { return m_available; }
    QString latestVersion() const   { return m_latest; }
    QString releaseUrl() const      { return m_url; }
    bool    enabled() const         { return m_enabled; }

    void setEnabled(bool v) {
        if (v == m_enabled) return;
        m_enabled = v;
        emit enabledChanged();
    }

    Q_INVOKABLE void checkNow()         { ++checkNowCalls; }
    Q_INVOKABLE void skipThisVersion()  { ++skipCalls;  clearForTest(); }
    Q_INVOKABLE void remindLater()      { ++laterCalls; clearForTest(); }

    // test hooks
    Q_INVOKABLE void offerForTest(const QString &version, const QString &url) {
        m_available = true;
        m_latest = version;
        m_url = url;
        emit updateChanged();
    }
    Q_INVOKABLE void clearForTest() {
        if (!m_available) return;
        m_available = false;
        m_latest.clear();
        m_url.clear();
        emit updateChanged();
    }

    int checkNowCalls = 0;
    int skipCalls = 0;
    int laterCalls = 0;

signals:
    void updateChanged();
    void enabledChanged();

private:
    bool    m_available = false;
    QString m_latest;
    QString m_url;
    bool    m_enabled = true;
};

struct TestStubs {
    StubAuth       *auth = nullptr;
    StubBridge     *bridge = nullptr;
    StubPlayer     *player = nullptr;
    StubCast       *cast = nullptr;
    StubApp        *app = nullptr;
    StubDownloader *downloader = nullptr;
    StubPrefs      *prefs = nullptr;
    StubPins       *pins = nullptr;
    StubLibrary    *library = nullptr;
    StubUpdateCheck *updateCheck = nullptr;
};

// Registers the context properties under exactly the names
// Application::run() uses, plus the offline "tidal" image provider. `owner` gets
// ownership of the stubs (pass the test/setup object); defaults to the engine.
inline TestStubs installTestStubs(QQmlEngine *engine, QObject *owner = nullptr) {
    QObject *parent = owner ? owner : static_cast<QObject *>(engine);

    // The same call Application::run() makes on its own engine, and for the same
    // reason: on Qt 6.4 "qrc:/qt/qml" is not a default import path, so without it
    // `import TidalWave` resolves only the C++ types and every .qml file in the
    // module - Theme included - is undefined. A test engine is not given one for
    // free the way the app's is by sitting next to its build tree, so every
    // engine a test builds goes through here. See Application.cpp for the whole
    // story.
    Application::addEmbeddedQmlImportPath(engine);
    // ...and the same style the app pins, for the same anti-drift reason. On a
    // platform where the app pins nothing this is a no-op.
    Application::applyQuickControlsStyle();

    TestStubs s;
    s.auth       = new StubAuth(parent);
    s.bridge     = new StubBridge(parent);
    s.player     = new StubPlayer(parent);
    s.cast       = new StubCast(parent);
    s.app        = new StubApp(parent);
    s.downloader = new StubDownloader(parent);
    s.prefs      = new StubPrefs(parent);
    s.updateCheck = new StubUpdateCheck(parent);
    s.pins       = new StubPins(parent);
    s.library    = new StubLibrary(parent);

    // The bridge builds JS arrays/objects for its callbacks.
    s.bridge->setJsEngine(engine);

    QQmlContext *ctx = engine->rootContext();
    ctx->setContextProperty(QStringLiteral("auth"), s.auth);
    ctx->setContextProperty(QStringLiteral("bridge"), s.bridge);
    ctx->setContextProperty(QStringLiteral("player"), s.player);
    ctx->setContextProperty(QStringLiteral("downloader"), s.downloader);
    ctx->setContextProperty(QStringLiteral("cast"), s.cast);
    ctx->setContextProperty(QStringLiteral("app"), s.app);
    ctx->setContextProperty(QStringLiteral("prefs"), s.prefs);
    ctx->setContextProperty(QStringLiteral("updateCheck"), s.updateCheck);
    // Theme.qml binds to the ThemePalette singleton, which Application wires
    // to Prefs at startup. Without the same wiring here every QML test paints
    // in the default palette and a broken theme switch looks like a pass.
    ThemePalette::instance()->setThemeSource(s.prefs);
    ctx->setContextProperty(QStringLiteral("pins"), s.pins);
    ctx->setContextProperty(QStringLiteral("library"), s.library);

    // The sidebar keeps its own copy of the library, so the one row the user
    // just made has to be handed across. Application::run() makes exactly this
    // connection between the real TidalBridge and LibraryIndex; without it a
    // QML test of the New-playlist dialog would be driving a sidebar wired up
    // differently from the shipping one, and the half of the feature that is
    // "it appears without a refresh" would be untestable.
    QObject::connect(s.bridge, &StubBridge::playlistCreated,
                     s.library, &StubLibrary::addPlaylist);

    if (!engine->imageProvider(QStringLiteral("tidal")))
        engine->addImageProvider(QStringLiteral("tidal"), new StubImageProvider());

    return s;
}
