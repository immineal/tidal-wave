// HomePage with Tidal's own rows: they stand in Tidal's order around Home's
// own rows, a feed that fails or comes back empty leaves only those, and the
// staff picks are a tab of their own. Every title and id here is invented.

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "HomeFeed"
    when: windowShown
    width: 1100
    height: 2400
    visible: true

    readonly property int rowGap: 32

    Component { id: holderC; Item { } }
    Component { id: homeC;   HomePage { anchors.fill: parent } }

    // ── data ────────────────────────────────────────────────────────────────

    function album(id, title) {
        return { kind: "album", id: id, title: title, artists: "Invented Artist", coverUrl: "" }
    }
    function playlist(uuid, title) {
        return { kind: "playlist", uuid: uuid, title: title, numTracks: 20, coverUrl: "", type: "EDITORIAL" }
    }
    function own(id, row) { return { id: id, title: id, ownRow: row, mediaType: "recent", items: [] } }
    function row(id, title, mediaType, items, context) {
        return { id: id, title: title, context: context || "", ownRow: "", mediaType: mediaType, items: items }
    }

    readonly property var tabs: [{ name: "For you", feed: "static" }, { name: "Staff Picks", feed: "editorial" }]

    function forYou() {
        return { tabs: tabs, modules: [
            own("DAILY_MIXES", "mixes"),
            own("CONTINUE_LISTEN_TO", "recent"),
            row("NEW_ALBUM_SUGGESTIONS", "Suggested new albums for you", "album",
                [album(1, "First New"), album(2, "Second New")]),
            row("BECAUSE_YOU_LISTENED_TO_ALBUM", "Because you listened to", "album",
                [album(3, "Kindred")], "Context Album"),
            own("YOUR_FAVORITE_ARTISTS", "artists"),
            row("SUGGESTED_ESSENTIAL_PLAYLISTS", "Essentials to explore", "playlist",
                [playlist("p-1", "Essentials One")]),
            own("MY_PLAYLISTS", "playlists"),
            row("POPULAR_PLAYLISTS", "Popular playlists on Tidal", "playlist",
                [playlist("p-2", "Big List")])
        ] }
    }
    function staffPicks() {
        return { tabs: tabs, modules: [
            row("STAFF_PICKS_PAGE_ALBUMS_WE_LOVE", "Albums with no skips", "album", [album(9, "Staff Album")])
        ] }
    }

    function makeMixes(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: "mix-" + i, title: "Mix " + i, subtitle: "", coverUrl: "" })
        return out
    }
    function makeAlbums(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 200 + i, title: "Saved " + i, artists: "Someone", coverUrl: "", type: "ALBUM" })
        return out
    }
    function makeArtists(n) {
        var out = []
        for (var i = 0; i < n; ++i) out.push({ id: 300 + i, name: "Artist " + i, coverUrl: "" })
        return out
    }
    function makePlaylists(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 400 + i, uuid: "uuid-" + i, title: "List " + i, coverUrl: "",
                       numTracks: 3, duration: 600, type: "USER" })
        return out
    }

    // ── harness ─────────────────────────────────────────────────────────────

    function init() {
        bridge.resetForTest()
        bridge.setFavoriteAlbumsForTest([])
        bridge.setFavoriteArtistsForTest([])
        bridge.setUserPlaylistsForTest([])
    }

    function settle(item) {
        wait(1)
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    // The library rows filled, the feeds as the case set them on the stub.
    function makeHome(library) {
        var holder = createTemporaryObject(holderC, testCase, { width: 1000, height: 2300 })
        var page = createTemporaryObject(homeC, holder, {})
        verify(page, "HomePage was not created")
        if (library) {
            page.mixes = makeMixes(3)
            bridge.setFavoriteAlbumsForTest(makeAlbums(3))
            bridge.setFavoriteArtistsForTest(makeArtists(3))
            bridge.setUserPlaylistsForTest(makePlaylists(3))
            tryVerify(function () { return page.playlists.length === 3 && page.artists.length === 3 }, 2000,
                      "the library rows never filled")
        }
        settle(holder)
        return page
    }

    function isRow(item) {
        return item.mediaType !== undefined && item.items !== undefined && item.cardSize !== undefined
    }
    function collectRows(item, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || !c.visible) continue
            if (isRow(c)) { out.push(c); continue }
            collectRows(c, out)
        }
        return out
    }
    function titles(page) {
        return collectRows(page, []).map(function (r) { return r.title })
    }
    function findByName(item, name) {
        if (item.objectName === name) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findByName(item.children[i], name)
            if (hit) return hit
        }
        return null
    }
    function headingTop(rowItem, page) {
        return rowItem.mapToItem(page, 0, 0).y
    }

    // ── cases ───────────────────────────────────────────────────────────────

    function test_tidals_rows_stand_in_tidals_order() {
        bridge.setHomeFeedForTest("static", forYou())
        var page = makeHome(true)
        compare(titles(page), [
            "My mixes",
            "Suggested new albums for you", "Because you listened to",
            "Favourite artists",
            "Essentials to explore",
            "Saved albums", "My playlists",
            "Popular playlists on Tidal"])

        var rows = collectRows(page, [])
        for (var i = 1; i < rows.length; ++i) {
            var gap = headingTop(rows[i], page) - rows[i - 1].mapToItem(page, 0, rows[i - 1].height).y
            verify(Math.abs(gap - rowGap) <= 0.5,
                   "the gap above \"" + rows[i].title + "\" is " + gap.toFixed(1))
        }
        compare(rows[2].subtitle, "Context Album", "the row does not name what it is about")
        verify(!rows[1].showViewAll, "a feed row offers a Show all with no page behind it")
        compare(bridge.homeFeedFetchesForTest(), ["static/en"])
    }

    function test_a_small_library_still_gets_rows() {
        bridge.setHomeFeedForTest("static", forYou())
        var page = makeHome(false)
        compare(titles(page), ["Suggested new albums for you", "Because you listened to",
                               "Essentials to explore", "Popular playlists on Tidal"])
    }

    // A feed that fails takes only its own rows with it.
    function test_a_failed_feed_leaves_the_library_rows() {
        bridge.setHomeFeedForTest("static", forYou(), "Host unreachable")
        var page = makeHome(true)
        compare(titles(page), ["My mixes", "Favourite artists", "Saved albums", "My playlists"])
        verify(!findByName(page, "homeTabsRow").visible, "tabs over a feed that never came")
    }

    // The copy on disk shows at once and stays when the fetch fails.
    function test_the_cached_feed_shows_when_the_fetch_fails() {
        bridge.setHomeFeedCacheForTest("static", forYou())
        bridge.setHomeFeedForTest("static", {}, "Host unreachable")
        var page = makeHome(false)
        compare(titles(page).length, 4, "the cached rows are not on the page: " + titles(page))
    }

    function test_an_empty_feed_shows_no_rows_and_no_tabs() {
        bridge.setHomeFeedForTest("static", { tabs: [], modules: [] })
        var page = makeHome(true)
        compare(titles(page), ["My mixes", "Favourite artists", "Saved albums", "My playlists"])
        verify(!findByName(page, "homeTabsRow").visible, "tabs over an empty feed")
    }

    function test_staff_picks_is_a_tab_of_its_own() {
        bridge.setHomeFeedForTest("static", forYou())
        bridge.setHomeFeedForTest("editorial", staffPicks())
        var page = makeHome(true)
        var strip = findByName(page, "homeTabsRow")
        verify(strip.visible, "no tabs over a feed that names two")
        compare(bridge.homeFeedFetchesForTest(), ["static/en"], "the staff picks were asked for unseen")

        strip.activated(1)
        settle(page)
        compare(bridge.homeFeedFetchesForTest(), ["static/en", "editorial/en"])
        compare(titles(page), ["Albums with no skips"])
        compare(strip.currentIndex, 1)

        strip.activated(0)
        settle(page)
        compare(titles(page).length, 8, "For you did not come back whole: " + titles(page))
    }

    // A failed staff picks feed leaves an empty tab, not a broken page.
    function test_a_failed_staff_picks_feed_shows_nothing_there() {
        bridge.setHomeFeedForTest("static", forYou())
        bridge.setHomeFeedForTest("editorial", {}, "Host unreachable")
        var page = makeHome(true)
        findByName(page, "homeTabsRow").activated(1)
        settle(page)
        compare(titles(page), [])
        findByName(page, "homeTabsRow").activated(0)
        settle(page)
        compare(titles(page).length, 8)
    }

    // The bridge cuts versions; the page asks it again when the setting moves.
    function test_the_version_preference_rereads_the_feed() {
        bridge.setHomeFeedForTest("static", forYou())
        var page = makeHome(false)
        var other = forYou()
        other.modules[2].items = [album(5, "The Other Version")]
        bridge.setHomeFeedCacheForTest("static", other)
        bridge.preferExplicit = !bridge.preferExplicit
        settle(page)
        var rows = collectRows(page, [])
        compare(rows[0].items.length, 1)
        compare(rows[0].items[0].title, "The Other Version")
        bridge.preferExplicit = !bridge.preferExplicit
    }
}
