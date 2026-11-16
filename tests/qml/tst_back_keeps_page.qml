// Back returns to the page as it was left: the same page object, scrolled
// where it was, with nothing fetched again. A link followed forward opens a
// fresh page at the top. Main.qml keeps a few pages behind the current one
// and no more. The bridge stub is from tests/TestStubs.h.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "BackKeepsPage"
    when: windowShown

    readonly property int settleMs: 3000

    Component { id: appWindowHost; Main {} }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        bridge.resetHeadersForTest()
        bridge.setAlbumForTest({ id: 7001, title: "Eine lange Platte", artists: "Eine Band",
                                 artistId: 3, numTracks: 80, coverUrl: "" },
                               makeTracks(80, 81000))
    }

    function makeTracks(n, base) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: base + i, title: "Stück " + (i + 1), artists: "Eine Band",
                       albumTitle: "Eine lange Platte", durationStr: "3:21",
                       coverUrl: "", coverUrl80: "", albumId: 7001, artistId: 3,
                       trackNumber: i + 1, volumeNumber: 1 })
        return out
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function showApp() {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        frame(win.contentItem)
        return win
    }

    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    function allOfType(item, wanted, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            if (typeName(c) === wanted) out.push(c)
            allOfType(c, wanted, out)
        }
        return out
    }

    // The one on screen: the window may keep others hidden behind it.
    function shown(win, wanted) {
        var all = allOfType(win.contentItem, wanted, [])
        for (var i = 0; i < all.length; i++) {
            var ok = true
            for (var p = all[i]; p; p = p.parent) if (!p.visible) { ok = false; break }
            if (ok) return all[i]
        }
        return null
    }

    function openAlbum(win) {
        win.navigate("album", { albumId: 7001 })
        var page = null
        tryVerify(function () { page = shown(win, "AlbumPage"); return page !== null
                                && page.tracks.length === 80 }, settleMs,
                  "the album never loaded")
        frame(win.contentItem)
        var list = findChild(page, "albumTracksList")
        verify(list, "the album page has no track list")
        verify(list.contentHeight > list.height + 1000, "the fixture does not scroll")
        list.contentY = 1200
        frame(win.contentItem)
        return { page: page, list: list }
    }

    function test_back_from_a_link_shows_the_album_as_it_was() {
        var win = showApp()
        var a = openAlbum(win)
        var fetches = bridge.albumFetchesForTest()
        var trackFetches = bridge.albumTracksFetchesForTest()

        win.navigate("artist", { artistId: 3 })
        tryVerify(function () { return shown(win, "ArtistPage") !== null }, settleMs)
        win.goBack()
        tryVerify(function () { return win.currentPage === "album" }, settleMs)
        frame(win.contentItem)

        compare(shown(win, "AlbumPage"), a.page, "back built the album page again")
        compare(a.list.contentY, 1200, "back did not keep the scroll position")
        compare(bridge.albumFetchesForTest(), fetches, "back fetched the album again")
        compare(bridge.albumTracksFetchesForTest(), trackFetches,
                "back fetched the tracks again")
    }

    function test_back_from_now_playing_shows_the_album_as_it_was() {
        var win = showApp()
        var a = openAlbum(win)
        var fetches = bridge.albumFetchesForTest()

        win.navigate("nowplaying")
        tryVerify(function () { return win.currentPage === "nowplaying" }, settleMs)
        win.goBack()
        tryVerify(function () { return win.currentPage === "album" }, settleMs)
        frame(win.contentItem)

        compare(shown(win, "AlbumPage"), a.page, "back built the album page again")
        compare(a.list.contentY, 1200, "back did not keep the scroll position")
        compare(bridge.albumFetchesForTest(), fetches, "back fetched the album again")
    }

    // A link to the album already on screen is a reload, and one followed from
    // another page opens it new.
    function test_a_link_forward_opens_a_fresh_page_at_the_top() {
        var win = showApp()
        var a = openAlbum(win)
        win.navigate("artist", { artistId: 3 })
        tryVerify(function () { return shown(win, "ArtistPage") !== null }, settleMs)
        var fetches = bridge.albumFetchesForTest()
        win.navigate("album", { albumId: 7002 })
        tryVerify(function () { var p = shown(win, "AlbumPage"); return p && p.albumId === 7002 },
                  settleMs)
        var fresh = shown(win, "AlbumPage")
        verify(fresh !== a.page, "a different album reused the old page")
        compare(findChild(fresh, "albumTracksList").contentY,
                findChild(fresh, "albumTracksList").originY, "a new page did not start at the top")
        verify(bridge.albumFetchesForTest() > fetches, "a new album was not fetched")
    }

    function test_only_a_few_pages_are_kept_alive() {
        var win = showApp()
        for (var i = 0; i < 12; ++i)
            win.navigate(i % 2 ? "artist" : "album",
                         i % 2 ? { artistId: 100 + i } : { albumId: 200 + i })
        frame(win.contentItem)
        wait(50)
        var alive = allOfType(win.contentItem, "AlbumPage", []).length
                  + allOfType(win.contentItem, "ArtistPage", []).length
        verify(win.maxKeptPages > 0, "the window names no limit")
        verify(alive <= win.maxKeptPages + 1,
               alive + " pages alive, more than the " + win.maxKeptPages
               + " kept behind the current one")
        // Home and the eleven pages before the last.
        compare(win.navHistory.length, 12, "the history itself is not what is bounded")
    }

    // Going home empties the history, and the pages it kept go with it.
    function test_a_sidebar_destination_lets_the_kept_pages_go() {
        var win = showApp()
        openAlbum(win)
        win.navigate("artist", { artistId: 3 })
        win.navigate("home")
        tryVerify(function () {
            return allOfType(win.contentItem, "AlbumPage", []).length === 0
                && allOfType(win.contentItem, "ArtistPage", []).length === 0
        }, settleMs, "pages outlived the history that kept them")
    }
}
