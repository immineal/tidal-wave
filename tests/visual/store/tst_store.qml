// The five store screenshots: the whole app window, 1280x800, on invented data.
//
// Main.qml itself is what gets drawn, so the sidebar, the pages and the player
// bar are laid out by the app and reached through its own navigate().

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

import "StoreData.js" as D

TestCase {
    id: testCase
    name: "Store"
    when: windowShown
    visible: true
    width: 400
    height: 300

    Component { id: appC; Main { } }

    // ── fixtures ─────────────────────────────────────────────────────────

    function initTestCase() {
        // The design is drawn in Inter. A fallback face reflows every line,
        // and the pictures would still be written.
        verify(Qt.fontFamilies().indexOf("Inter") !== -1, "the Inter font is not installed")
    }

    function init() {
        // Every duration becomes zero, so no shot can land mid-animation.
        app.setReducedMotionForTest(true)

        bridge.resetForTest()
        auth.setUsernameForTest("Robin")
        cast.setDevicesForTest([{ id: "d1", name: "Living Room" }])

        var queue = D.albumTracks(D.heroAlbum)
        var now = queue[D.heroPlaying]
        player.setPlaybackSource("album", "" + D.album(D.heroAlbum).id,
                                 D.album(D.heroAlbum).title)
        player.setQueueForTest(queue, D.heroPlaying)
        player.setCurrentTrackForTest(now)
        player.setAudioQualityForTest("LOSSLESS")
        player.setDurationForTest(now.duration * 1000)
        player.setPlayingForTest(true)
        player.setVolume(0.85)

        bridge.setFavoriteTracksListForTest(D.likedTracks())
        bridge.setFavoriteAlbumsForTest(D.albums())
        bridge.setFavoriteArtistsForTest(D.artists())
        bridge.setUserPlaylistsForTest(D.playlists())
        bridge.setTrackFavoriteForTest(now.id, true)
        library.setEntriesForTest(D.libraryEntries())
        pins.setItemsForTest(D.pinItems())
    }

    function cleanup() {
        app.setReducedMotionForTest(false)
    }

    // ── helpers ──────────────────────────────────────────────────────────

    // Nothing between here and shoot() waits, so the first frame drawn is the
    // finished scene and no shot depends on how many frames came before it.
    // The corner placement keeps the window clear of the display's pointer.
    function open(positionMs) {
        player.setPositionForTest(positionMs)
        var win = appC.createObject(testCase, { x: 0, y: 0 })
        verify(win, "the app window was not created")
        return win
    }

    // The first item under `item` that declares `prop`: how a page is found
    // behind the Loader that owns it.
    function findWith(item, prop) {
        if (!item) return null
        if (item[prop] !== undefined) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findWith(kids[i], prop)
            if (hit) return hit
        }
        return null
    }

    // Image and Loader share the value: 2 is Loading on both.
    function stillLoading(item) {
        if (!item) return false
        if (item.status === 2) return true
        var kids = item.children
        for (var i = 0; i < kids.length; ++i)
            if (stillLoading(kids[i])) return true
        return false
    }

    // A view builds the rows beyond its viewport a few at a time, on a clock.
    // How many exist by the first frame decides the order glyphs enter the
    // cache, and the text pixels follow that order. So none are built.
    function dropBuffers(item) {
        if (!item) return
        if (item.cacheBuffer !== undefined) item.cacheBuffer = 0
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) dropBuffers(kids[i])
    }

    function shoot(win, name) {
        verify(shotOutDir.length > 0, "TW_SHOT_OUT was not set")
        dropBuffers(win.contentItem)
        waitForRendering(win.contentItem, 4000)
        // After the first frame, so it follows any enter event the display
        // server sent: parks the pointer where nothing reacts to it.
        mouseMove(win.contentItem, 110, 8)
        tryVerify(function () { return !stillLoading(win.contentItem) }, 8000,
                  "cover art was still loading")
        waitForRendering(win.contentItem, 4000)
        wait(500)
        compare(win.width, 1280)
        compare(win.height, 800)
        // Drawn at 2x and averaged down by the grabber; run.sh sets the scale.
        compare(win.Screen.devicePixelRatio, 2)
        verify(shotGrabber.save(win.contentItem, shotOutDir + "/" + name + ".png"),
               name + ".png was not written")
        win.destroy()
        wait(100)
    }

    // ── the scenes ───────────────────────────────────────────────────────

    function test_home() {
        var win = open(42000)
        var page = findWith(win.contentItem, "greeting")
        verify(page, "no home page in the window")
        // The stub bridge serves no mixes, and the greeting follows the clock.
        page.mixes = D.homeMixes()
        page.greeting = page.greetingFor(15)
        // What the page does when the favourites change under it.
        page.refreshRows()
        verify(page.recentAlbums.length > 0, "the saved albums never reached the home page")
        shoot(win, "store_home")
    }

    function test_collection() {
        var win = open(65000)
        win.navigate("collection", { activeTab: 1 })
        var page = findWith(win.contentItem, "filteredAlbums")
        verify(page, "no collection page in the window")
        page.mixes = D.mixes()
        compare(page.filteredAlbums.length, D.albums().length)
        shoot(win, "store_collection")
    }

    function test_album() {
        var win = open(87000)
        var id = D.album(D.heroAlbum).id
        bridge.setAlbumForTest(D.albumHeader(D.heroAlbum), D.albumTracks(D.heroAlbum))
        bridge.setAlbumFavoriteForTest(id, true)
        win.navigate("album", { albumId: id })
        var page = findWith(win.contentItem, "albumData")
        verify(page, "no album page in the window")
        compare(page.tracks.length, D.albumTracks(D.heroAlbum).length)
        shoot(win, "store_album")
    }

    function test_nowplaying() {
        var win = open(104000)
        win.navigate("nowplaying")
        var page = findWith(win.contentItem, "stackBreakpoint")
        verify(page, "no Now Playing page in the window")
        // The stub bridge serves no lyrics; this is the page once some arrived.
        page.lyricsData = D.heroLyrics
        page.lyricsState = "ready"
        shoot(win, "store_nowplaying")
    }

    function test_search() {
        var win = open(131000)
        bridge.setSearchResultsForTest(D.searchTracks(), D.searchAlbums(),
                                       D.searchArtists(), [])
        win.navigate("search", { requestedQuery: D.searchQuery })
        var page = findWith(win.contentItem, "requestedQuery")
        verify(page, "no search page in the window")
        verify(page.replied, "the search never answered")
        compare(page.sectionOrder[0], page.kArtists)
        // A focused field draws a caret, and a caret blinks.
        page.releaseFocus()
        shoot(win, "store_search")
    }
}
