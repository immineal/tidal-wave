// The window-wide keys in the real application window: Quit, Find, New
// playlist, the moved seek and volume keys, and Space on a focused control.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ShortcutKeys"
    when: windowShown

    Component { id: appWindowHost; Main {} }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        player.setCurrentTrackForTest({ id: 4242, title: "Weit hinter dem Horizont",
                                        artists: "Erika Mustermann", duration: 200 })
        player.setDurationForTest(200000)
        player.setPositionForTest(60000)
        player.setVolume(0.5)
        player.setMuted(false)
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

    function typeName(obj) { return obj.toString().split("(")[0].split("_QML")[0] }

    function findByType(item, wanted) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            if (typeName(c) === wanted) return c
            var found = findByType(c, wanted)
            if (found) return found
        }
        return null
    }

    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name && item.visible !== false) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findNamed(item.children[i], name)
            if (hit) return hit
        }
        return null
    }

    function test_ctrl_q_quits() {
        var win = showApp()
        var before = app.quitCountForTest()
        keyClick(Qt.Key_Q, Qt.ControlModifier)
        compare(app.quitCountForTest(), before + 1, "Ctrl+Q does not quit")
    }

    function test_find_focuses_the_search_field_data() {
        return [ { tag: "Ctrl+F", key: Qt.Key_F }, { tag: "Ctrl+L", key: Qt.Key_L } ]
    }
    function test_find_focuses_the_search_field(row) {
        var win = showApp()
        keyClick(row.key, Qt.ControlModifier)
        compare(win.currentPage, "search")
        tryVerify(function () { return win.isTypingContext(win.activeFocusItem) }, 1000,
                  row.tag + " leaves the keyboard outside the search field")
    }

    function test_ctrl_n_opens_a_new_playlist() {
        var win = showApp()
        var sidebar = findByType(win.contentItem, "SideBar")
        verify(sidebar)
        keyClick(Qt.Key_N, Qt.ControlModifier)
        tryVerify(function () { return sidebar.playlistDialog.opened }, 1000,
                  "Ctrl+N does not open the new playlist dialog")
        compare(win.currentPage, "home", "Ctrl+N still goes to Now Playing")
    }

    // Spotify's key for liking the playing track, with the same write,
    // read-back and notice as the heart.
    function test_alt_shift_b_likes_and_unlikes_the_playing_track() {
        bridge.setTrackFavoriteForTest(4242, false)
        bridge.resetFavoriteCallsForTest()
        var win = showApp()
        keyClick(Qt.Key_B, Qt.AltModifier | Qt.ShiftModifier)
        tryVerify(function () { return bridge.isTrackFavorite(4242) }, 1000,
                  "Alt+Shift+B does not like the playing track")
        compare(bridge.lastFavoriteCallForTest(), "addTrack:4242")
        tryVerify(function () { return Toasts.shown }, 1000, "the like said nothing")
        keyClick(Qt.Key_B, Qt.AltModifier | Qt.ShiftModifier)
        tryVerify(function () { return !bridge.isTrackFavorite(4242) }, 1000,
                  "a second Alt+Shift+B does not unlike it")
        tryVerify(function () { return Toasts.actionLabel.length > 0 }, 1000,
                  "the unlike offered no Undo")
    }

    function test_seek_and_volume_keys() {
        var win = showApp()
        keyClick(Qt.Key_Right, Qt.ShiftModifier)
        compare(player.position, 70000)
        keyClick(Qt.Key_Left, Qt.ShiftModifier)
        compare(player.position, 60000)
        keyClick(Qt.Key_Up, Qt.ControlModifier)
        fuzzyCompare(player.volume, 0.55, 1e-9)
        keyClick(Qt.Key_Down, Qt.ControlModifier)
        fuzzyCompare(player.volume, 0.5, 1e-9)
        // A bare arrow is the focused control's, not a seek.
        keyClick(Qt.Key_Right)
        compare(player.position, 60000)
    }

    // Space on a focused button presses it; with nothing focused it pauses.
    function test_space_presses_the_focused_button() {
        var win = showApp()
        var bar = findByType(win.contentItem, "PlayerBar")
        verify(bar)
        var shuffle = findNamed(bar, "playerBarShuffle")
        player.setShuffle(false)
        var playing = player.playing
        shuffle.forceActiveFocus()
        keyClick(Qt.Key_Space)
        verify(player.shuffle, "Space did not press the focused button")
        compare(player.playing, playing, "Space on a button also toggled playback")
        player.setShuffle(false)
    }
}
