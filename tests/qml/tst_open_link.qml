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
}
