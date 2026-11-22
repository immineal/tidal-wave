// The five store screenshots: the whole app window, 1280x800, on the store library.
//
// Main.qml itself is what gets drawn, so the sidebar, the pages and the player
// bar are laid out by the app and reached through its own navigate().

import QtQuick
import QtQuick.Controls
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
        if (shotTheme.length > 0) {
            var known = ThemePalette.available().some(function (t) { return t.name === shotTheme })
            verify(known, "no theme is called " + shotTheme)
            prefs.theme = shotTheme
        }
    }

    // store_home becomes store_home_clay when run.sh names a theme.
    function fileName(name) {
        return shotTheme.length > 0 ? name + "_" + shotTheme : name
    }

    function init() {
        // Every duration becomes zero, so no shot can land mid-animation.
        app.setReducedMotionForTest(true)

        bridge.resetForTest()
        auth.setUsernameForTest("Robin")
        cast.setDevicesForTest([{ id: "d1", name: "Living Room" }])

        play(D.heroAlbum, D.heroPlaying)
        player.setVolume(0.85)

        bridge.setFavoriteTracksListForTest(D.likedTracks())
        bridge.setFavoriteAlbumsForTest(D.albums())
        bridge.setFavoriteArtistsForTest(D.artists())
        bridge.setUserPlaylistsForTest(D.playlists())
        library.setEntriesForTest(D.libraryEntries())
        pins.setItemsForTest(D.pinItems())
        // What Home fetches as it mounts, from Tidal's answers' shapes.
        bridge.setHomeMixesForTest(D.mixes())
        bridge.setHomeFeedForTest("static", D.homeFeed())
        // Never drawn: a track with lyrics is what puts the Lyrics chip on
        // the cover. Not the song's words, which do not belong here.
        bridge.setLyricsForTest("[00:00.00]Lyrics", true)
    }

    // The album's track `index` in the player, its stream described as the
    // real Player describes it once the stream has said its format.
    function play(albumIndex, index) {
        var queue = D.albumTracks(albumIndex)
        var now = queue[index]
        player.setPlaybackSource("album", "" + D.album(albumIndex).id,
                                 D.album(albumIndex).title)
        player.setQueueForTest(queue, index)
        player.setCurrentTrackForTest(now)
        player.setAudioQualityForTest(D.streamQuality(albumIndex))
        player.setAudioFormatForTest(D.streamFormat(albumIndex))
        player.setDurationForTest(now.duration * 1000)
        player.setPlayingForTest(true)
        bridge.setTrackFavoriteForTest(now.id, true)
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

    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findNamed(kids[i], name)
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

    // These pages show their scrollbar on arrival, and it fades for good after
    // the first scroll. One wheel notch down and back is that state: the page
    // as it rests once it has been used.
    function scrollOnce(view) {
        var bar = view.ScrollBar.vertical
        var top = view.contentY
        mouseWheel(view, view.width / 2, view.height / 2, 0, -120)
        tryVerify(function () { return view.contentY > top }, 4000,
                  "the wheel did not move the page")
        mouseWheel(view, view.width / 2, view.height / 2, 0, 1200)
        tryVerify(function () {
            return !view.movingVertically && view.contentY === top
                   && !bar.active && bar.contentItem.opacity === 0
        }, 8000, "the page did not come back to rest at the top")
    }

    // Every item under `item` with that objectName.
    function findAllNamed(item, name, out) {
        out = out || []
        if (!item) return out
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) findAllNamed(kids[i], name, out)
        return out
    }

    // Whether the item is drawn: it and every parent visible.
    function shown(item) {
        if (!item) return false
        for (var it = item; it; it = it.parent)
            if (!it.visible || it.opacity === 0) return false
        return true
    }

    // ── what 0.5.0 shows ─────────────────────────────────────────────────
    // Each scene checks the features its picture is meant to show, so a scene
    // whose stub data stops feeding them fails instead of drawing an old UI.

    // The badges in the window: the stream's real format, never the tier alone.
    function checkBadges(win, withTier) {
        var texts = findAllNamed(win.contentItem, "qualityBadgeText").filter(shown)
        verify(texts.length > 0, "no quality badge is shown")
        for (var i = 0; i < texts.length; ++i) {
            verify(/\d+-bit \/ [\d.]+ kHz FLAC$/.test(texts[i].text),
                   "the quality badge says \"" + texts[i].text + "\", not the stream's format")
            if (withTier)
                verify(texts[i].text.indexOf(" · ") > 0,
                       "the quality badge has no tier in front: " + texts[i].text)
        }
        return texts
    }

    // The hero's colour came from its cover, not the accent wash.
    function checkHeroTint(page) {
        var gradient = findNamed(page, "heroGradient")
        verify(gradient && shown(gradient), "no hero gradient on the page")
        var hero = gradient.parent
        var tint = null
        for (var i = 0; i < hero.data.length; ++i)
            if (hero.data[i].objectName === "heroCoverTint") tint = hero.data[i]
        verify(tint, "the hero has no cover tint")
        tryVerify(function () { return tint.hasColor }, 4000,
                  "the hero never took its colour from the cover")
    }

    // `scrolled` is the view to put through scrollOnce(), where a page has one.
    function shoot(win, name, scrolled) {
        verify(shotOutDir.length > 0, "TW_SHOT_OUT was not set")
        dropBuffers(win.contentItem)
        waitForRendering(win.contentItem, 4000)
        if (scrolled) scrollOnce(scrolled)
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
        // The greeting follows the clock.
        page.greeting = page.greetingFor(15)
        // What the page does when the favourites change under it.
        page.refreshRows()
        verify(page.recentAlbums.length > 0, "the saved albums never reached the home page")
        compare(page.mixes.length, D.mixes().length)

        // Tidal's feed as two tabs on the greeting's line, the first chosen.
        var tabs = findNamed(page, "homeTabsRow")
        verify(tabs && shown(tabs), "Home shows no feed tabs")
        compare(tabs.model.length, 2)
        compare(tabs.model[0], "For you")
        compare(tabs.model[1], "Staff picks")
        compare(tabs.currentIndex, 0)
        verify(shown(findNamed(page, "homeContinue")), "Home does not show the playing track")
        // Recently played first, its cards above the player bar.
        var recent = findNamed(page, "homeRecentlyPlayed")
        verify(recent && shown(recent), "Home shows no Recently played row")
        verify(recent.items.length >= 8, "Recently played has " + recent.items.length + " cards")
        compare(recent.items[0].title, D.album(D.heroAlbum).title)
        var bottom = recent.mapToItem(win.contentItem, 0, recent.height).y
        var bar = findWith(win.contentItem, "showNowPlaying")
        verify(bar, "no player bar in the window")
        var barTop = bar.mapToItem(win.contentItem, 0, 0).y
        verify(bottom <= barTop, "Recently played ends at " + bottom + ", under the player bar at " + barTop)
        // Tidal's own rows, under the titles it gives them.
        verify(findNamed(page, "homeFeedRow_NEW_ALBUM_SUGGESTIONS"), "Home has none of Tidal's rows")
        checkBadges(win, false)
        shoot(win, fileName("store_home"))
    }

    function test_collection() {
        var win = open(65000)
        win.navigate("collection", { activeTab: 1 })
        var page = findWith(win.contentItem, "savedAlbums")
        verify(page, "no collection page in the window")
        compare(page.mixes.length, D.mixes().length)
        compare(page.savedAlbums.length, D.albums().length)
        var grid = findNamed(page, "collectionAlbumsGrid")
        verify(grid, "no album grid on the collection page")
        checkBadges(win, false)
        shoot(win, fileName("store_collection"), grid)
    }

    function test_album() {
        play(D.albumScene, D.albumScenePlaying)
        var win = open(87000)
        var id = D.album(D.albumScene).id
        bridge.setAlbumForTest(D.albumHeader(D.albumScene), D.albumTracks(D.albumScene))
        bridge.setAlbumFavoriteForTest(id, true)
        win.navigate("album", { albumId: id })
        var page = findWith(win.contentItem, "albumData")
        verify(page, "no album page in the window")
        compare(page.tracks.length, D.albumTracks(D.albumScene).length)
        var list = findNamed(page, "albumTracksList")
        verify(list, "no track list on the album page")
        checkHeroTint(page)
        verify(shown(findNamed(page, "albumTracksHeader")), "the album has no column headings")
        checkBadges(win, false)
        shoot(win, fileName("store_album"), list)
    }

    function test_nowplaying() {
        // A hi-res record, for the badge with its tier.
        play(D.hiResHero, 0)
        var win = open(104000)
        win.navigate("nowplaying")
        var page = findWith(win.contentItem, "stackBreakpoint")
        verify(page, "no Now Playing page in the window")
        compare(page.lyricsState, "ready")
        var badge = checkBadges(win, true)
        compare(badge.length, 1)
        compare(badge[0].text, "Max · " + D.streamFormat(D.hiResHero))
        shoot(win, fileName("store_nowplaying"))
    }

    function test_search() {
        var win = open(131000)
        bridge.setSearchResultsForTest(D.searchTracks(), D.searchAlbums(),
                                       D.searchArtists(), [])
        bridge.setSearchTopHitForTest(D.searchTopHit())
        win.navigate("search", { requestedQuery: D.searchQuery })
        var page = findWith(win.contentItem, "requestedQuery")
        verify(page, "no search page in the window")
        verify(page.replied, "the search never answered")
        compare(page.sectionOrder[0], page.kArtists)
        verify(shown(findNamed(page, "searchTopHit")), "the search shows no top result")
        checkBadges(win, false)
        // A focused field draws a caret, and a caret blinks.
        page.releaseFocus()
        // The query arrives selected. In the app leaving the field clears
        // that, but this window never had active focus to lose.
        var field = findWith(page, "persistentSelection")
        verify(field, "no text field on the search page")
        field.deselect()
        shoot(win, fileName("store_search"))
    }
}
