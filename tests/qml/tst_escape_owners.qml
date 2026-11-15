// One Escape does one thing. Whatever has the keyboard and is closable (a
// dialog, a menu, the output picker, a field with text in it) takes the key,
// and the window's own Escape (queue, fullscreen, back) never runs as well.
// Runs in the real Main.qml, since that is where the window's Escape lives.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "EscapeOwners"
    when: windowShown

    Component {
        id: appWindowHost
        Main {}
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        bridge.resetForTest()
        bridge.setMixPageForTest({ id: "mx-esc-1", title: "Eine Mischung",
                                   subtitle: "", coverUrl: "",
                                   mixType: "DISCOVERY_MIX" },
                                 makeTracks(3, 8100))
        bridge.setPlaylistTracksForTest(makeTracks(3, 8200))
        bridge.setPlaylistForTest({ uuid: "pl-esc-1", title: "Eine Liste",
                                    type: "USER", numTracks: 3, duration: 600 })
    }

    function makeTracks(n, base) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: base + i, title: "Stück " + (i + 1), artists: "Eine Band",
                       albumTitle: "Ein Album", durationStr: "3:21", duration: 201,
                       coverUrl: "", coverUrl80: "", albumId: 11, artistId: 3 })
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
        win.requestActivate()
        frame(win.contentItem)
        return win
    }

    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    function findByType(item, wanted) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            if (typeName(c) === wanted && c.visible) return c
            var found = findByType(c, wanted)
            if (found) return found
        }
        return null
    }

    function findNamed(item, name) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            if (c.objectName === name && c.visible) return c
            var found = findNamed(c, name)
            if (found) return found
        }
        return null
    }

    // The first track row of the page on screen, once the tracks are in.
    function firstRow(win) {
        var row = null
        tryVerify(function () {
            row = findByType(win.contentItem, "TrackRow")
            return row !== null
        }, 3000, "the page drew no track row")
        return row
    }

    function openPage(win, page, params) {
        win.navigate(page, params)
        compare(win.currentPage, page, "the window did not navigate to " + page)
    }

    // The popup closes, and the page and the queue stay as they were.
    function escapeClosesOnly(win, popup, page, what) {
        tryVerify(function () { return popup.opened }, 2000, what + " did not open")
        win.queueOpen = false
        keyClick(Qt.Key_Escape)
        compare(win.currentPage, page, "Escape on " + what + " also navigated back")
        tryVerify(function () { return !popup.visible }, 2000,
                  "Escape did not close " + what)
        // And the next Escape is the window's again.
        keyClick(Qt.Key_Escape)
        tryVerify(function () { return win.currentPage === "home" }, 2000,
                  "with " + what + " shut, Escape no longer went back")
    }

    // The case from the audit: the new-playlist dialog over a mix page.
    function test_escape_on_the_new_playlist_dialog_only_closes_it() {
        var win = showApp()
        openPage(win, "mix", { mixId: "mx-esc-1" })
        var row = firstRow(win)
        row.openNewPlaylist()
        escapeClosesOnly(win, row.newPlaylistPopup, "mix", "the New playlist dialog")
    }

    function test_escape_on_the_playlist_picker_only_closes_it() {
        var win = showApp()
        openPage(win, "mix", { mixId: "mx-esc-1" })
        var row = firstRow(win)
        row.openPicker()
        escapeClosesOnly(win, row.playlistPicker, "mix", "the Add to playlist picker")
    }

    function test_escape_on_a_track_menu_only_closes_it() {
        var win = showApp()
        openPage(win, "mix", { mixId: "mx-esc-1" })
        var row = firstRow(win)
        row.openMenu()
        escapeClosesOnly(win, row.rowMenu, "mix", "the track menu")
    }

    function test_escape_on_the_edit_playlist_dialog_only_closes_it() {
        var win = showApp()
        openPage(win, "playlist", { playlistUuid: "pl-esc-1", playlistType: "USER" })
        var page = findByType(win.contentItem, "PlaylistPage")
        verify(page, "the playlist page did not load")
        page.editPopup.open()
        escapeClosesOnly(win, page.editPopup, "playlist", "the Edit playlist dialog")
    }

    // A field with text in it clears on Escape, as LibraryFinder says. The
    // window's Escape outranked it, so the page went back instead.
    function test_escape_in_the_library_finder_clears_it_and_stays() {
        var win = showApp()
        openPage(win, "mix", { mixId: "mx-esc-1" })
        var input = findNamed(win.contentItem, "finderInput")
        verify(input, "the sidebar has no library finder")
        input.forceActiveFocus()
        keyClick(Qt.Key_A)
        keyClick(Qt.Key_B)
        compare(input.text, "ab", "typing did not reach the finder")

        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "mix", "Escape in the finder navigated back")
        compare(input.text, "", "Escape did not clear the finder")

        // An empty finder gives the keyboard up, and Escape after that is the
        // window's: back from the mix page.
        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "mix", "the Escape that left the finder also went back")
        verify(!input.activeFocus, "Escape in an empty finder kept the focus")
        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "home", "Escape after leaving the finder did not go back")
    }
}
