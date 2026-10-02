// Escape, over the Settings panel, in the real application window.
//
// Everything else in tests/qml/ hosts a component inside a stand-in window of
// its own. That is cheap and it is usually right, but it cannot see this bug:
// the Escape shortcut lives in Main.qml, it is an application shortcut, and it
// is gated on `auth.state === 2`. Signed out the whole class is unreachable, so
// no stand-in host ever reached it either, and Escape over an open Settings
// panel shipped navigating the page behind instead of closing the panel. An
// application shortcut outranks an open Popup's own key handling, so the
// panel's closePolicy was dead and the user watched the page jump back.
//
// Hence the real Main.qml, and hence the stub auth put into its signed-in
// state first. tst_nowplaying_access.qml hosts the same window for the
// fullscreen/queue half of this shortcut's precedence; this file is the
// Settings half, which nothing covered.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "MainEscape"
    when: windowShown

    Component {
        id: appWindowHost
        Main {}
    }

    function init() {
        // tst_qml runs every file in this directory in one process against one
        // set of stubs, so nothing here may assume the state another file left
        // behind. All three of these gate the shortcut under test:
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)       // LoggedIn - the shortcut only exists here
        // ...and the update prompt disables Escape by design, so a file that
        // left an update on offer would make this one pass for the wrong
        // reason. Main.qml offers it once, on completion.
        updateCheck.clearForTest()
    }

    function showApp() {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        win.requestActivate()
        waitForRendering(win.contentItem, 2000)
        return win
    }

    // The QML type a visible item was built from, for finding something that
    // carries no objectName of its own. Same walker tst_nowplaying_access.qml
    // uses on this window.
    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

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

    function settingsPanelOf(win) {
        var sidebar = findByType(win.contentItem, "SideBar")
        verify(sidebar, "the application window has no sidebar")
        var panel = sidebar.settingsPanel
        verify(panel, "the sidebar exposes no settingsPanel")
        return { sidebar: sidebar, panel: panel }
    }

    function openSettingsOver(win, page) {
        win.navigate(page)
        tryVerify(function () { return win.currentPage === page }, 2000,
                  "the window did not navigate to " + page)
        var s = settingsPanelOf(win)
        s.sidebar.openSettings()
        tryVerify(function () { return s.panel.visible }, 2000,
                  "the Settings panel did not open")
        return s
    }

    // The bug, on a detail page because that is where Escape has somewhere to
    // navigate to. Before the gate existed the shortcut fired, consumed the
    // key, and goBack() ran: the panel stayed up and the page underneath it
    // changed out from under it.
    function test_escape_over_settings_closes_it_and_leaves_the_page_alone() {
        var win = showApp()
        compare(win.currentPage, "home", "the window should start at home")
        var s = openSettingsOver(win, "album")

        keyClick(Qt.Key_Escape)

        // The page first, and before any waiting: the shortcut fires inside
        // the key press, so if it is still live the navigation has already
        // happened by the time this line runs. Asserting it first also keeps
        // a failure honest about which half broke.
        compare(win.currentPage, "album",
                "Escape navigated the page behind the open Settings panel")
        tryVerify(function () { return !s.panel.visible }, 2000,
                  "Escape did not close the Settings panel")
    }

    // The queue panel is the other thing Escape closes, and it is closed here,
    // so Settings must not take its turn: one Escape, one thing undone.
    function test_escape_over_settings_does_not_also_close_the_queue() {
        var win = showApp()
        var s = openSettingsOver(win, "album")
        win.queueOpen = true

        keyClick(Qt.Key_Escape)

        verify(win.queueOpen,
               "Escape closed the queue underneath the Settings panel as well")
        tryVerify(function () { return !s.panel.visible }, 2000,
                  "Escape did not close the Settings panel")
        win.queueOpen = false
    }

    // And the gate is a gate, not a removal: with Settings shut, Escape still
    // navigates back the way it always did.
    function test_escape_still_navigates_back_once_settings_is_shut() {
        var win = showApp()
        var s = openSettingsOver(win, "album")
        s.panel.close()
        tryVerify(function () { return !s.panel.visible }, 2000,
                  "the Settings panel did not close")

        keyClick(Qt.Key_Escape)
        tryVerify(function () { return win.currentPage === "home" }, 2000,
                  "Escape stopped navigating back once Settings had been opened once")
    }
}
