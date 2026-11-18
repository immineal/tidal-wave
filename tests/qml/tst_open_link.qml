// A Tidal link handed over from the command line or the desktop opens its
// page in the real application window.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "OpenLink"
    when: windowShown

    Component {
        id: appWindowHost
        Main {}
    }

    function init() {
        // One process runs every file here, so the stubs' state is set again.
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
    }

    function shownDetail(win) {
        var v = win.detailView
        return v && v.visible && v.item ? v.item : null
    }

    function test_each_kind_opens_its_page_data() {
        return [
            { tag: "album",    kind: "album",    id: "4711", page: "album",    prop: "albumId",      want: 4711 },
            { tag: "artist",   kind: "artist",   id: "815",  page: "artist",   prop: "artistId",     want: 815 },
            { tag: "playlist", kind: "playlist", id: "0d5c0d1e-0000-4000-8000-000000000001",
              page: "playlist", prop: "playlistUuid", want: "0d5c0d1e-0000-4000-8000-000000000001" },
            { tag: "mix",      kind: "mix",      id: "00112233445566778899aabbccddee",
              page: "mix",      prop: "mixId",        want: "00112233445566778899aabbccddee" }
        ]
    }

    function test_each_kind_opens_its_page(data) {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the window did not build")
        win.show()
        tryCompare(win, "visible", true)

        app.openRequested(data.kind, data.id)
        tryCompare(win, "currentPage", data.page, 2000, "the link did not open its page")
        tryVerify(function () { return shownDetail(win) !== null }, 3000,
                  "no page is on screen for the link")
        compare(shownDetail(win)[data.prop], data.want,
                "the page opened for another " + data.kind)
    }

    function test_an_unknown_kind_changes_nothing() {
        var win = createTemporaryObject(appWindowHost, testCase)
        win.show()
        tryCompare(win, "visible", true)
        var before = win.currentPage
        app.openRequested("video", "42")
        wait(50)
        compare(win.currentPage, before, "a kind the app cannot show moved the window")
    }

    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findNamed(item.children[i], name)
            if (hit) return hit
        }
        return null
    }

    function showApp() {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the window did not build")
        win.show()
        tryCompare(win, "visible", true)
        return win
    }

    // ── a link dropped on the window ─────────────────────────────────────

    function test_a_dropped_link_opens_its_page() {
        var win = showApp()
        verify(win.takesDrop(["https://tidal.com/browse/album/4711"], ""),
               "the window turns a Tidal link away")
        win.openDropped(["https://tidal.com/browse/album/4711"], "")
        tryCompare(win, "currentPage", "album", 2000, "the dropped link did not open")
        compare(win._currentNavParams.albumId, 4711)
    }

    // Text dragged out of a browser's address bar arrives as text.
    function test_dropped_text_opens_its_page() {
        var win = showApp()
        win.openDropped([], "https://listen.tidal.com/artist/815")
        tryCompare(win, "currentPage", "artist", 2000)
    }

    function test_a_drop_that_is_no_link_is_turned_away() {
        var win = showApp()
        verify(!win.takesDrop(["file:///home/someone/song.flac"], ""),
               "the window takes a file it cannot open")
        verify(!win.takesDrop([], "just some words"), "the window takes plain words")
    }

    // ── a link pasted into Search ────────────────────────────────────────

    function test_a_link_pasted_into_search_opens_it() {
        var win = showApp()
        win.navigate("search")
        var bar = null
        tryVerify(function () { bar = findNamed(win.contentItem, "searchPageBar"); return bar !== null },
                  3000, "the search page has no field")
        bar.text = "https://tidal.com/browse/playlist/0d5c0d1e-0000-4000-8000-000000000001"
        bar.textEdited(bar.text)
        tryCompare(win, "currentPage", "playlist", 2000, "the pasted link was searched for")
        compare(bar.text, "", "the link was left in the field")
    }

    // A link typed one letter at a time is someone searching for it.
    function test_typing_is_still_a_search() {
        var win = showApp()
        win.navigate("search")
        var bar = null
        tryVerify(function () { bar = findNamed(win.contentItem, "searchPageBar"); return bar !== null }, 3000)
        bar.text = "tidal://album/"
        bar.textEdited(bar.text)
        bar.text = "tidal://album/1"
        bar.textEdited(bar.text)
        wait(50)
        compare(win.currentPage, "search")
    }
}
