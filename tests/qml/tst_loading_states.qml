// Loading is not empty. An empty state ("Nothing saved yet", "No mixes",
// "No saved albums") may only show once its data has arrived and really is
// empty, and a count the page does not know yet is not shown as zero.
// The stubs hold each source in its loading state until the case lets go.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "LoadingStates"
    when: windowShown
    visible: true
    width: 1280
    height: 800

    readonly property int settleMs: 2000

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        bridge.resetForTest()
        bridge.setUserPlaylistsForTest([])
        bridge.setFavoriteAlbumsForTest([])
        bridge.setFavoriteArtistsForTest([])
        bridge.setFavoriteTracksListForTest([])
        library.setEntriesForTest([])
        library.setLoadingForTest(false)
        pins.setItemsForTest([])
    }

    function cleanup() {
        bridge.resetForTest()
        library.setLoadingForTest(false)
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function settle(item) {
        wait(1)
        frame(item)
    }

    // Every visible Text whose string contains `needle`. `visible` is the
    // effective value, so text inside a hidden parent is left out.
    function visibleTextsSaying(item, needle) {
        var out = []
        function walk(it) {
            var kids = it.children
            for (var i = 0; i < kids.length; ++i) {
                var c = kids[i]
                if (!c || typeof c.width !== "number" || c.visible === false) continue
                if (typeof c.text === "string" && c.text.indexOf(needle) >= 0) out.push(c)
                walk(c)
            }
        }
        walk(item)
        return out
    }

    function says(item, needle) { return visibleTextsSaying(item, needle).length > 0 }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: appHost;     Main { } }

    Component {
        id: pageHost
        Window {
            property alias pane: pane
            function navigate(page, params) {}
            function goBack() {}
            width: 1200
            height: 900
            Item { id: pane; anchors.fill: parent }
        }
    }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }

    function makeCollection(tab) {
        var holder = createTemporaryObject(holderC, testCase, { width: 1280, height: 760 })
        verify(holder, "the holder was not created")
        var page = createTemporaryObject(collectionC, holder, { activeTab: tab })
        verify(page, "the collection page was not created")
        settle(page)
        return page
    }

    // ── Collection: no empty state for a list still on its way ───────────

    // Mixes are fetched by the page itself, and nothing guarded their empty
    // state, so "No mixes" sat under the loading scrim.
    function test_no_mixes_is_not_claimed_while_the_mixes_load() {
        bridge.setDeferHomeMixesForTest(true)
        var page = makeCollection(4)
        verify(!says(page, "No mixes"),
               "Collection said \"No mixes\" while the mixes were still loading")
        var spinner = findByName(page, "loadingSpinner")
        verify(spinner && spinner.visible,
               "the page showed no loading state while the mixes loaded")

        bridge.flushHomeMixesForTest()
        settle(page)
        verify(!spinner.visible, "the loading state stayed after the mixes had loaded")
        verify(says(page, "No mixes"),
               "an account with no mixes never said so once they had loaded")
    }

    function test_no_empty_state_while_its_kind_loads_data() {
        return [
            { tag: "tracks",    tab: 0, kind: "tracks",    line: "No saved tracks" },
            { tag: "albums",    tab: 1, kind: "albums",    line: "No saved albums" },
            { tag: "artists",   tab: 2, kind: "artists",   line: "No followed artists" },
            { tag: "playlists", tab: 3, kind: "playlists", line: "No playlists yet" }
        ]
    }

    // The bridge loads the four lists apart, and the liked songs are not the
    // last to land: an empty album list after the songs is not yet an answer.
    function test_no_empty_state_while_its_kind_loads(row) {
        bridge.setKindLoadingForTest(row.kind, true)
        var page = makeCollection(row.tab)
        verify(!says(page, row.line),
               "Collection said \"" + row.line + "\" while that list was still loading")

        bridge.setKindLoadingForTest(row.kind, false)
        settle(page)
        verify(says(page, row.line),
               "an empty " + row.kind + " list never said so once it had loaded")
    }

    // ── the sidebar ──────────────────────────────────────────────────────

    function test_the_sidebar_says_nothing_is_saved_only_once_it_knows() {
        library.setLoadingForTest(true)
        var win = createTemporaryObject(appHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        settle(win.contentItem)

        verify(!says(win.contentItem, "Nothing saved yet"),
               "the sidebar said \"Nothing saved yet\" while the library was loading")

        library.setLoadingForTest(false)
        settle(win.contentItem)
        verify(says(win.contentItem, "Nothing saved yet"),
               "an empty library never said so once it had loaded")
    }

    // ── the playlist page's count ────────────────────────────────────────

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 9100 + i, title: "Stück " + (i + 1), artists: "Eine Band",
                       albumTitle: "Ein Album", durationStr: "3:21", duration: 201,
                       coverUrl: "", coverUrl80: "", albumId: 42, artistId: 7 })
        return out
    }

    // The header brings the length at once, the tracklist the count seconds
    // later. In between the page said "0 tracks · 93 hr 45 min".
    function test_the_playlist_shows_no_count_before_its_tracks_are_in() {
        bridge.setPlaylistTracksForTest(makeTracks(3))
        bridge.setPlaylistForTest({ uuid: "p-long", title: "Lang", description: "",
                                    numTracks: 3, duration: 337500, coverUrl: "",
                                    type: "USER" })
        bridge.setDeferTrackRepliesForTest(true)

        var host = createTemporaryObject(pageHost, testCase)
        host.visible = true
        var page = createTemporaryObject(playlistC, host.pane,
                                         { playlistUuid: "p-long", playlistTitle: "Lang",
                                           playlistType: "USER" })
        verify(page, "PlaylistPage did not load")
        settle(host.contentItem)
        verify(page.loading, "the tracklist was not held back, so this case proves nothing")

        // "track", not "tracks": the suite runs without the English plurals.
        verify(!says(host.contentItem, "0 track"),
               "the page claimed 0 tracks while its tracks were loading")
        verify(says(host.contentItem, "93 hr 45 min"),
               "the length the header brought was not shown while the tracks loaded")

        bridge.flushTrackRepliesForTest()
        settle(host.contentItem)
        verify(says(host.contentItem, "3 track") && says(host.contentItem, "93 hr 45 min"),
               "the count did not appear once the tracks were in")
    }
}
