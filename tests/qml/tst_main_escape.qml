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
//
// And, from the second section down, where Escape *goes*: the window's back
// history lives in Main.qml too, and only the real window has it. See the
// comment above those tests for the bug that put them here.

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

    // ── Where back goes: out, one page at a time, and then nowhere ────────
    //
    // Reported as "I can press escape again and again and it just opens and
    // closes now playing". The history was one `previousPage` string and
    // goBack() was an ordinary navigate(), so going back recorded the page it
    // was leaving: back out of Now Playing wrote Now Playing into the slot, and
    // the next back walked straight into it again. Held down, Escape toggled
    // the page open and shut for as long as the key was held.
    //
    // Now Playing was only the loudest case - it is in detailPages, so Escape
    // keeps firing on it rather than falling through to doing nothing. Every
    // pair of detail pages had the same defect with a quieter symptom, which is
    // why the walk below is album -> artist with no Now Playing in it, and all
    // three ways back share goBack(), which is why all three drive it.

    function centerClick(item) {
        mouseClick(item, Math.round(item.width / 2), Math.round(item.height / 2))
    }

    // The back disc, where the page offers one. Album, Artist, Playlist and Mix
    // carry it; Now Playing has its own chevron, and the top-level destinations
    // have nothing at all - which is the half of the walk that proves back
    // stopped rather than turned round.
    function backButtonIn(win) {
        var b = findByType(win.contentItem, "BackButton")
        return (b && b.visible) ? b : null
    }

    // One back, driven the way the user drives it. False when the way under
    // test has nothing to press here, which only the button can be.
    function pressBack(win, way) {
        if (way === "escape") {
            keyClick(Qt.Key_Escape)
            return true
        }
        if (way === "altLeft") {
            // src/ui/Shortcuts.cpp binds "back" to Alt+Left, and
            // tst_shortcuts.cpp is what keeps that table and Main.qml's
            // bindings from drifting apart.
            keyClick(Qt.Key_Left, Qt.AltModifier)
            return true
        }
        // The button is aimed at by position, so it has to have arrived first.
        waitForRendering(win.contentItem, 2000)
        var b = backButtonIn(win)
        if (!b) return false
        centerClick(b)
        return true
    }

    function test_back_again_and_again_only_ever_walks_out_data() {
        return [
            { tag: "escape",      way: "escape" },
            { tag: "alt+left",    way: "altLeft" },
            { tag: "back button", way: "button" }
        ]
    }

    function test_back_again_and_again_only_ever_walks_out(row) {
        var win = showApp()
        compare(win.currentPage, "home", "the window should start at home")
        win.navigate("album", { albumId: 4242 })
        win.navigate("artist", { artistId: 11 })
        compare(win.currentPage, "artist", "the fixture never reached the artist page")

        // Six presses for two pages of history. The extra four are the point:
        // back at a top-level destination has nowhere to go, so the walk has to
        // stand still there instead of turning round.
        var trail = [win.currentPage]
        for (var i = 0; i < 6; i++) {
            // A way with nothing to press leaves the page where it is, which
            // the trail then has to show as another step of standing still.
            pressBack(win, row.way)
            trail.push(win.currentPage)
        }

        compare(trail.join(" -> "),
                "artist -> album -> home -> home -> home -> home -> home",
                "back did not walk out of the pages one at a time and then stop")
    }

    // The page the complaint named, by the route the complaint took: the player
    // bar opens Now Playing over whatever was on screen.
    function test_escape_out_of_now_playing_does_not_reopen_it() {
        var win = showApp()
        win.navigate("album", { albumId: 4242 })
        win.navigate("nowplaying")
        compare(win.currentPage, "nowplaying", "the fixture never reached Now Playing")

        var trail = [win.currentPage]
        for (var i = 0; i < 6; i++) {
            keyClick(Qt.Key_Escape)
            trail.push(win.currentPage)
        }

        compare(trail.join(" -> "),
                "nowplaying -> album -> home -> home -> home -> home -> home",
                "Escape opened and closed Now Playing instead of walking out of it")
    }

    // Following a link forward onto the page back would have returned to is
    // going back, and the window treats it as one: Now Playing's track title
    // opens the album the page rose from, so the album is where back was
    // already pointing. Recorded as a step it would make the next back a step
    // forward - the bug's own shape, one bounce deep.
    //
    // Only the entry on top is unwound like this; the test below this one is
    // the other half of that choice.
    function test_stepping_back_onto_the_page_behind_does_not_stack_it() {
        var win = showApp()
        win.navigate("album", { albumId: 4242 })
        win.navigate("nowplaying")
        win.navigate("album", { albumId: 4242 })   // the track title on the page
        compare(win.currentPage, "album", "the fixture never came back to the album")

        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "home",
                "Escape went back into the Now Playing the user had just stepped out of")
        compare(win.navHistory.length, 0,
                "the walk out of the album left history behind it")
    }

    // The other half: a page further down the stack is one the user has walked
    // away from since, so arriving at it again is a step forward like any
    // other. Unwinding to it instead would throw away everything above it -
    // here the mix, the playlist and the artist the user walked through on the
    // way - and back would then hand them a path they never took.
    //
    // Note where the album has to sit for this to be the case it says it is: a
    // link straight back to the page you just came from is the entry on top,
    // which the test above covers. Four pages are what it takes to get the
    // album far enough down to be a different question.
    function test_a_page_deeper_in_the_history_is_still_a_step_forward() {
        var win = showApp()
        win.navigate("album",    { albumId: 4242 })
        win.navigate("artist",   { artistId: 11 })
        win.navigate("playlist", { playlistUuid: "spaetschicht-5" })
        win.navigate("mix",      { mixId: "m-17" })
        win.navigate("album",    { albumId: 4242 })   // the mix's first track

        var trail = [win.currentPage]
        for (var i = 0; i < 6; i++) {
            keyClick(Qt.Key_Escape)
            trail.push(win.currentPage)
        }
        compare(trail.join(" -> "),
                "album -> mix -> playlist -> artist -> album -> home -> home",
                "back did not walk the path the user actually took")
    }

    // Another album is another page, params and all, even though the window
    // never leaves the album page type. Asking for the one already on screen is
    // a reload (see navigate()'s blank-and-restore) and not a step, and the
    // blank it goes through is not a page to come back to.
    function test_a_second_album_is_a_step_of_its_own() {
        var win = showApp()
        win.navigate("album", { albumId: 4242 })
        win.navigate("album", { albumId: 4243 })   // a link on that album's page
        win.navigate("album", { albumId: 4243 })   // the same link again: a reload

        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "album",
                "Escape skipped the album the user came from")
        tryVerify(function () {
            var page = findByType(win.contentItem, "AlbumPage")
            return page && page.albumId === 4242
        }, 2000, "back landed on an album page, but not the one the user came from")

        for (var i = 0; i < win.navHistory.length; i++)
            verify(win.navHistory[i].page !== "",
                   "the reload's blank page became a history entry")

        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "home", "the second Escape did not reach home")
        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "home", "Escape at home navigated somewhere")
    }

    // A chain of links never has to touch a top-level page, so the stack has a
    // ceiling and drops its oldest entry at it. An array that only ever grows
    // is a leak in a process that lives in the tray for days.
    function test_the_history_has_a_ceiling() {
        var win = showApp()
        var steps = win.maxNavHistory + 8
        for (var i = 0; i < steps; i++) {
            // Alternating, so every step is a page the user walked to and not
            // the same page reloaded.
            if (i % 2 === 0) win.navigate("album",  { albumId:  9000 + i })
            else             win.navigate("artist", { artistId: 9000 + i })
        }

        compare(win.navHistory.length, win.maxNavHistory,
                "the history grew past its own ceiling")
        // The oldest end is what gets dropped, so what back reaches first is
        // still the page the user was on a moment ago.
        var top = win.navHistory[win.navHistory.length - 1]
        compare(top.page, "album", "the newest entry is not the page just left")
        compare(top.params.albumId, 9000 + steps - 2,
                "the newest entry is an album, but not the one just left")

        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "album", "back did not step out of the last page")
        compare(win.navHistory.length, win.maxNavHistory - 1,
                "stepping back did not consume an entry")
    }

    // A session's pages belong to the session. Signing in lands on home, which
    // is the bottom of history, so the stack a signed-out window was holding
    // cannot be walked back into from the next sign-in.
    function test_signing_in_starts_with_no_history() {
        var win = showApp()
        win.navigate("album", { albumId: 4242 })
        win.navigate("artist", { artistId: 11 })

        auth.setStateForTest(0)        // LoggedOut
        auth.setStateForTest(2)        // ...and back in
        tryVerify(function () { return win.currentPage === "home" }, 2000,
                  "signing in did not land on home")
        compare(win.navHistory.length, 0,
                "a fresh session inherited the last one's history")

        keyClick(Qt.Key_Escape)
        compare(win.currentPage, "home", "Escape at home navigated somewhere")
    }
}
