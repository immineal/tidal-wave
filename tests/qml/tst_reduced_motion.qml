// Every animation in the app respects the platform's reduced-motion
// preference. Each case drives a real component and measures the property:
// with the preference on it is on its target in the frame of the change, with
// it off it is still travelling a frame later. Reduced motion collapses a
// duration to zero and keeps the animation, so a transition still finishes.
// app.setReducedMotionForTest() on the stub is the only way in.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ReducedMotion"
    when: windowShown
    // TestCase declares visible: false, which would make every child report
    // visible == false and stop a synthesized mouse event ever arriving.
    visible: true
    width: 1280
    height: 800

    // Prefs::railWidth and the default sidebar width, repeated so a change
    // to either fails here.
    readonly property int railWidth: 68
    readonly property int defaultSidebar: 220

    // The slowest animation any case below drives, plus room for a slow
    // machine.
    readonly property int settleMs: 2000

    function init() {
        app.setReducedMotionForTest(false)
        prefs.setSidebarWidthForTest(defaultSidebar)
        auth.setStateForTest(2)          // LoggedIn
        auth.setHasSavedCredentialsForTest(false)
        auth.setUsernameForTest("robin")
        library.setEntriesForTest([])
        library.setTracksForTest([])
        pins.setItemsForTest([])
        bridge.resetForTest()
    }

    function cleanup() {
        app.setReducedMotionForTest(false)
        auth.setStateForTest(2)
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function settle(item) {
        wait(1)
        waitForRendering(item, settleMs)
    }

    // One turn of the scene: long enough for a zero-duration animation to
    // have written its target, far too short for a 100-200ms one to finish.
    function oneFrame() { wait(1) }

    function findByName(item, name) {
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    // An animation is not a visual child, so it is reachable through `data`
    // and not through `children`. The spinner's rotation is the one case below
    // that has to be found this way.
    function findInData(item, name) {
        if (item.objectName === name) return item
        var kids = item.data
        for (var i = 0; i < kids.length; ++i) {
            var hit = findInData(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function sameColor(a, b) { return String(a) === String(b) }

    // ── fixtures ─────────────────────────────────────────────────────────

    Component { id: holderC; Item { } }

    Component {
        id: shellHost
        Window {
            id: win
            width: 640
            height: 700
            color: "black"
            property alias sidebar: sb
            // The page the sidebar is built on, handed in at creation: a page
            // assigned afterwards is a move, and the first-placement cases are
            // about what happens before any move.
            property string startPage: "home"

            RowLayout {
                anchors.fill: parent
                spacing: 0
                // The three lines Main.qml uses, so the rail overlays the
                // page here exactly as it does in the app.
                SideBar {
                    id: sb
                    z: 2
                    currentPage: win.startPage
                    hostWidth: win.width
                    Layout.preferredWidth: sb.reservedWidth
                    Layout.fillHeight: true
                }
                Item { Layout.fillWidth: true; Layout.fillHeight: true }
            }
        }
    }

    // Now Playing delegates its sleep timer to Window.window, so it cannot
    // be instantiated bare. This mirrors the surface Main.qml provides.
    Component {
        id: nowPlayingHostC
        Window {
            id: npWin
            width: 1280; height: 900
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) { sleepTimerActive = true }
            function cancelSleepTimer() { sleepTimerActive = false }
            function formatSleepTime(seconds) { return "0:30" }
            function navigate(page, params) {}
            function goBack() {}
            property alias page: np
            NowPlayingPage { id: np; width: npWin.width; height: npWin.height }
        }
    }

    Component {
        id: playerBarHostC
        Window {
            id: pbWin
            width: 960; height: 200
            property alias bar: pb
            PlayerBar { id: pb; width: pbWin.width; anchors.bottom: parent.bottom }
        }
    }

    function showWindow(component, w, h) {
        var host = createTemporaryObject(component, testCase)
        verify(host, "the host window was not created")
        host.width = w
        host.height = h
        host.visible = true
        waitForRendering(host.contentItem, settleMs)
        return host
    }

    Component { id: backButtonC;     BackButton     { } }
    Component { id: loginC;          LoginPage      { anchors.fill: parent } }
    Component { id: loadingOverlayC; LoadingOverlay { } }

    // ── the mechanism itself ─────────────────────────────────────────────

    // Theme is the single switch; everything below only works because every
    // duration in qml/ is routed through it.
    function test_theme_is_the_one_switch() {
        compare(Theme.reduceMotion, false, "reduced motion is on with nothing asking for it")
        compare(Theme.dur(170), 170, "a normal duration was shortened for no reason")
        compare(Theme.dur(0), 0)

        app.setReducedMotionForTest(true)
        compare(Theme.reduceMotion, true, "Theme did not notice the preference changing")
        compare(Theme.dur(170), 0, "a duration survived reduced motion")
        compare(Theme.dur(900), 0)

        app.setReducedMotionForTest(false)
        compare(Theme.reduceMotion, false, "Theme did not notice the preference going away")
        compare(Theme.dur(170), 170)
    }

    // The guard has to hold in a host that never installed app: an
    // unqualified name that is not there throws a ReferenceError. This builds
    // the expression Theme uses against a global that is installed nowhere.
    function test_the_guard_survives_a_missing_global() {
        failOnWarning(/ReferenceError/)
        failOnWarning(/is not defined/)

        var probe = Qt.createQmlObject(
            'import QtQuick\n' +
            'QtObject {\n' +
            '    readonly property bool reduceMotion:\n' +
            '        (typeof neverInstalledGlobal !== "undefined")\n' +
            '        && neverInstalledGlobal !== null\n' +
            '        && neverInstalledGlobal.reducedMotion === true\n' +
            '    function dur(ms) { return reduceMotion ? 0 : ms }\n' +
            '}\n', testCase)

        verify(probe, "the guard expression would not even compile")
        compare(probe.reduceMotion, false,
                "with no app to ask, the app must assume motion is wanted")
        compare(probe.dur(170), 170, "a missing app silently killed every animation")
        probe.destroy()
    }

    // A null `app` is the other shape the guard has to survive: present in
    // the context, but holding nothing.
    function test_the_guard_survives_a_null_app() {
        var probe = Qt.createQmlObject(
            'import QtQuick\n' +
            'QtObject {\n' +
            '    property var app: null\n' +
            '    readonly property bool reduceMotion:\n' +
            '        (typeof app !== "undefined") && app !== null\n' +
            '        && app.reducedMotion === true\n' +
            '}\n', testCase)
        verify(probe)
        compare(probe.reduceMotion, false, "a null app was dereferenced")
        probe.destroy()
    }

    // ── the sidebar rail hover-expand ────────────────────────────────────

    function test_rail_expansion_data() {
        return [
            { tag: "reduced",  reduced: true  },
            { tag: "animated", reduced: false }
        ]
    }

    function test_rail_expansion(row) {
        app.setReducedMotionForTest(row.reduced)

        var host = createTemporaryObject(shellHost, testCase)
        verify(host, "the sidebar host window was not created")
        host.visible = true
        waitForRendering(host.contentItem, settleMs)

        var sb = host.sidebar
        compare(sb.reduceMotion, row.reduced,
                "the sidebar is not reading the shared preference")
        verify(sb.compact, "640px should have collapsed the sidebar to the rail")

        // Park the pointer on the page: a freshly shown window inherits
        // wherever the last synthesized event left it, often inside the rail.
        mouseMove(host.contentItem, 600, 690)
        tryVerify(function () { return sb.panelWidth === railWidth },
                  settleMs, "the rail never settled before the test began")

        mouseMove(host.contentItem, railWidth / 2, 300)
        oneFrame()

        if (row.reduced) {
            compare(sb.panelWidth, defaultSidebar,
                    "reduced motion: the rail must be open on the next frame, not slide")
        } else {
            verify(sb.panelWidth < defaultSidebar,
                   "without reduced motion the rail jumped open instead of sliding")
            tryVerify(function () { return sb.panelWidth === defaultSidebar },
                      settleMs, "the slide never finished")
        }

        // And back: the collapse follows the same rule.
        mouseMove(host.contentItem, 600, 300)
        oneFrame()

        if (row.reduced) {
            compare(sb.panelWidth, railWidth,
                    "reduced motion: the collapse must be instant too")
        } else {
            verify(sb.panelWidth > railWidth,
                   "without reduced motion the rail snapped shut instead of sliding")
            tryVerify(function () { return sb.panelWidth === railWidth },
                      settleMs, "the collapse never finished")
        }
    }

    // ── the layout that rearranges at a breakpoint ───────────────────────
    // Now Playing stacks its cover above its text below 1000px, travelling
    // off one property with one Behavior. With the preference on, the layout
    // is the new layout in the frame the width changed.

    function test_now_playing_restack_data() { return test_rail_expansion_data() }

    function test_now_playing_restack(row) {
        app.setReducedMotionForTest(row.reduced)

        var host = showWindow(nowPlayingHostC, 1280, 900)
        var page = host.page
        tryVerify(function () { return page.stackness === 0 }, settleMs,
                  "the page never settled side by side before the test began")
        verify(!page.stacked, "1280 should have put the cover beside the text")

        host.width = 900                 // below the breakpoint: it stacks
        oneFrame()

        if (row.reduced) {
            compare(page.stackness, 1,
                    "reduced motion: the page must be stacked on the next frame, not travelling")
            // The clock arriving is not the same as the layout arriving, so the
            // geometry is checked too: stacked, the text column starts a cover
            // and a gap down the page.
            compare(page.infoY, Math.round(page.coverSize + page.stackGap),
                    "reduced motion: the clock finished but the layout did not")
        } else {
            verify(page.stackness < 1,
                   "without reduced motion the page snapped into the stacked layout")
            tryVerify(function () { return page.stackness === 1 }, settleMs,
                      "the restack never finished")
        }
        compare(page.infoY, Math.round(page.coverSize + page.stackGap),
                "the settled page is not stacked")

        // And back: going back follows the same rule.
        host.width = 1280
        oneFrame()

        if (row.reduced) {
            compare(page.stackness, 0,
                    "reduced motion: going back must be instant too")
        } else {
            verify(page.stackness > 0,
                   "without reduced motion the page snapped back side by side")
            tryVerify(function () { return page.stackness === 0 }, settleMs,
                      "the page never came back side by side")
        }
        compare(page.infoY, Math.round((page.sideBodyHeight - page.infoHeight) / 2),
                "the page did not settle back on its side-by-side layout")
    }

    // The only motion the volume has in the bar is the flyout's opacity
    // fade, which reduced motion has to make instant.
    function test_player_bar_volume_flyout_fade_data() { return test_rail_expansion_data() }

    function test_player_bar_volume_flyout_fade(row) {
        app.setReducedMotionForTest(row.reduced)

        var host = showWindow(playerBarHostC, 960, 200)
        var bar = host.bar
        verify(!bar.hoverVolumePopup.visible, "the flyout is up before anyone pointed at it")

        var btn = bar.volumeButton
        var p = btn.mapToItem(host.contentItem, btn.width / 2, btn.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, settleMs,
                  "the flyout did not open on hover")
        oneFrame()

        if (row.reduced) {
            compare(bar.hoverVolumePopup.opacity, 1,
                    "reduced motion: the flyout must be fully drawn on the frame it opens")
        } else {
            tryVerify(function () { return bar.hoverVolumePopup.opacity === 1 }, settleMs,
                      "the flyout never finished fading in")
        }
        // The slider inside it is a real control either way.
        verify(bar.hoverVolumeSlider.visible && bar.hoverVolumeSlider.height >= 60,
               "the flyout is " + bar.hoverVolumeSlider.height.toFixed(1)
               + "px tall, which is not a slider to aim at")
    }

    // ── a hover fill ─────────────────────────────────────────────────────

    function test_hover_fill_data() { return test_rail_expansion_data() }

    function test_hover_fill(row) {
        app.setReducedMotionForTest(row.reduced)

        var btn = createTemporaryObject(backButtonC, testCase, { x: 40, y: 40 })
        verify(btn, "the back button was not created")

        mouseMove(testCase, 600, 600)
        tryVerify(function () { return sameColor(btn.color, btn.restFill) },
                  settleMs, "the button never settled on its resting fill")

        mouseMove(testCase, 58, 58)
        oneFrame()

        if (row.reduced) {
            verify(sameColor(btn.color, btn.hoveredFill),
                   "reduced motion: the hover fill must be there on the next frame, got "
                   + btn.color)
        } else {
            verify(!sameColor(btn.color, btn.hoveredFill),
                   "without reduced motion the hover fill jumped instead of fading")
            tryVerify(function () { return sameColor(btn.color, btn.hoveredFill) },
                      settleMs, "the hover fade never finished")
        }

        mouseMove(testCase, 600, 600)
        tryVerify(function () { return sameColor(btn.color, btn.restFill) },
                  settleMs, "the fill never returned to rest")
    }

    // ── a page transition ────────────────────────────────────────────────

    // Navigating between pages is a Loader swap with no animation of its
    // own. The one transition a page animates is the login card resizing as
    // the auth state moves on, 220px to 400px at its tallest jump.
    function test_page_transition_data() { return test_rail_expansion_data() }

    function test_page_transition(row) {
        app.setReducedMotionForTest(row.reduced)
        // Settle the card at its signed-out height before measuring.
        auth.setStateForTest(0)

        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var page = createTemporaryObject(loginC, holder)
        verify(page, "LoginPage was not created")
        settle(holder)

        var card = findByName(page, "loginAuthCard")
        verify(card, "LoginPage has no auth card to measure")
        tryVerify(function () { return card.height === 220 },
                  settleMs, "the card never settled at its signed-out height")

        auth.setStateForTest(1)          // PendingDevice: the card grows to 400
        oneFrame()

        if (row.reduced) {
            compare(card.height, 400,
                    "reduced motion: the card must be at its new height on the next frame")
        } else {
            verify(card.height < 400,
                   "without reduced motion the card jumped instead of growing")
            tryVerify(function () { return card.height === 400 },
                      settleMs, "the card never reached its new height")
        }
    }

    // ── an indefinite "still working" indicator ──────────────────────────

    // A spinner or a pulse must stand still under reduced motion and stay on
    // screen. The login dots are measured: a RotationAnimator is driven by the
    // render thread, which the offscreen platform never advances.

    function visibleDots(page) {
        var out = []
        function walk(item) {
            if (item.visible === false) return
            if (item.objectName === "loginPulseDot") out.push(item)
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) walk(kids[i])
        }
        walk(page)
        return out
    }

    function test_indefinite_indicator_data() { return test_rail_expansion_data() }

    function test_indefinite_indicator(row) {
        app.setReducedMotionForTest(row.reduced)
        // PendingDevice: the waiting state, with the pulsing dots.
        auth.setStateForTest(1)

        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var page = createTemporaryObject(loginC, holder)
        verify(page, "LoginPage was not created")
        settle(holder)

        var dots = visibleDots(page)
        compare(dots.length, 3, "the waiting indicator is not three dots any more")

        var dot = dots[0]
        verify(dot.visible, "reduced motion removed the busy indicator")
        verify(dot.opacity > 0,
               "the indicator is invisible, which is the same as not being there")

        if (row.reduced) {
            // Run once at zero length, which parks the dot fully lit.
            compare(dot.opacity, 1,
                    "reduced motion left the indicator at a half-faded resting value")
            wait(300)
            compare(dot.opacity, 1, "the indicator is still pulsing under reduced motion")
            wait(300)
            compare(dot.opacity, 1, "the indicator is still pulsing under reduced motion")
        } else {
            // One full cycle is 800ms, so a change is due well inside that.
            var at = dot.opacity
            tryVerify(function () { return dot.opacity !== at },
                      settleMs, "the indicator never pulsed with motion allowed")
        }
    }

    // The spinners' rotation cannot be measured here (see above), but
    // reduced motion must leave the busy mark on screen.
    function test_the_busy_spinner_is_still_on_screen() {
        app.setReducedMotionForTest(true)

        var holder = createTemporaryObject(holderC, testCase, { width: 400, height: 300 })
        var overlay = createTemporaryObject(loadingOverlayC, holder, { loading: true })
        verify(overlay, "the loading overlay was not created")
        settle(holder)

        var spinner = findByName(overlay, "loadingSpinner")
        verify(spinner, "the overlay has no spinner")
        verify(overlay.visible && spinner.visible,
               "reduced motion removed the busy indicator instead of stilling it")
        verify(spinner.width > 0 && spinner.height > 0,
               "the spinner was collapsed to nothing")

        // Read off the animation, since a clock cannot tell a zero-length turn
        // from a finished one. Reduced motion sets the duration to zero and the
        // loops to one: zero duration with Animation.Infinite is a spin loop.
        var rot = findInData(overlay, "loadingSpinnerRotation")
        verify(rot, "the spinner has no named rotation to check")
        compare(rot.duration, 0,
                "reduced motion left the spinner a turn to make")
        compare(rot.loops, 1,
                "a zero-length turn repeated forever is a spin loop, not stillness")
    }

    // Whether the spinner turns cannot be seen on this platform, so running
    // is the proxy: on exactly while the overlay is on screen. An indefinite
    // animation behind a hidden overlay would run for the life of the app.
    function test_the_busy_spinner_runs_only_while_it_is_on_screen() {
        app.setReducedMotionForTest(false)

        var holder = createTemporaryObject(holderC, testCase, { width: 400, height: 300 })
        var overlay = createTemporaryObject(loadingOverlayC, holder, { loading: false })
        verify(overlay, "the loading overlay was not created")
        settle(holder)

        var rot = findInData(overlay, "loadingSpinnerRotation")
        verify(rot, "the spinner has no named rotation to check")

        verify(!rot.running,
               "the spinner is rotating while the overlay is hidden")

        overlay.loading = true
        settle(holder)
        verify(rot.running,
               "the overlay is on screen and its spinner is not rotating")

        overlay.loading = false
        settle(holder)
        verify(!rot.running,
               "the spinner kept rotating after the overlay was hidden")
    }

    // The now-playing bars are the other indefinite indicator. Parked, they
    // are all that tells a playing row from the track waveform beside it.
    // tst_menus_and_glyphs asserts the parked shape; this asserts the parking.
    Component {
        id: playingIndicatorC
        Item {
            width: 40; height: 40
            property alias indicator: ind
            VectorIcon.PlayingIndicator {
                id: ind
                anchors.centerIn: parent
                width: 16; height: 14
            }
        }
    }

    function tallestBar(ind) {
        var best = 0
        function walk(item) {
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) {
                var c = kids[i]
                if (typeof c.radius === "number" && c.children.length === 0)
                    best = Math.max(best, c.height)
                else
                    walk(c)
            }
        }
        walk(ind)
        return best
    }

    function test_playing_indicator_data() { return test_rail_expansion_data() }

    function test_playing_indicator(row) {
        app.setReducedMotionForTest(row.reduced)

        var holder = createTemporaryObject(holderC, testCase, { width: 200, height: 200 })
        var probe = createTemporaryObject(playingIndicatorC, holder)
        verify(probe, "the indicator probe was not created")
        settle(holder)

        var ind = probe.indicator
        verify(ind.visible, "reduced motion removed the playing indicator")
        var at = tallestBar(ind)
        verify(at > 1, "the indicator collapsed to nothing, which says the row is not playing")

        if (row.reduced) {
            // Parked: three waits across more than a full cycle, and the
            // figure has not moved.
            wait(300)
            compare(tallestBar(ind), at, "the bars are still moving under reduced motion")
            wait(300)
            compare(tallestBar(ind), at, "the bars are still moving under reduced motion")
        } else {
            tryVerify(function () { return tallestBar(ind) !== at },
                      settleMs, "the bars never moved with motion allowed")
        }
    }

    // ── things that rearrange ────────────────────────────────────────────
    // The cases above are one property easing to a new value. In these,
    // something changes place or is replaced outright.

    Component { id: queuePanelC;   QueuePanel   { open: false } }
    Component { id: collectionC;   CollectionPage { anchors.fill: parent } }
    Component { id: searchC;       SearchPage   { anchors.fill: parent } }
    Component { id: trackRowC;     TrackRow     { } }

    // Now Playing's way in and out belongs to the window: the Loader has to
    // outlive the navigation, so that case needs the real Main.qml.
    Component { id: appHostC; Main { } }

    function collectByName(item, name, out) {
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) collectByName(kids[i], name, out)
        return out
    }

    function libraryRowFor(sb, id) {
        var rows = collectByName(sb, "libraryRow", [])
        for (var i = 0; i < rows.length; ++i)
            if (rows[i].itemId === id) return rows[i]
        return null
    }

    // Three plain library rows, in one of the two orders LibraryIndex hands
    // over: the second order is what a play produces, which moves the thing
    // that was just played to the front.
    function libraryRows(playedSecond) {
        var a = { kind: "album",  id: "a1", title: "Aquarium",   subtitle: "", imageUrl: "" }
        var b = { kind: "album",  id: "b2", title: "Blue Lines", subtitle: "", imageUrl: "" }
        var c = { kind: "artist", id: "c3", title: "Caribou",    subtitle: "", imageUrl: "" }
        return playedSecond ? [b, a, c] : [a, b, c]
    }

    // Pinning, playing or liking something moves a row to a different tier,
    // so the sidebar's library list reorders while it is being looked at.
    function test_library_reorder_travels_data() { return test_rail_expansion_data() }

    function test_library_reorder_travels(row) {
        app.setReducedMotionForTest(row.reduced)
        library.setEntriesForTest(libraryRows(false))

        var host = createTemporaryObject(shellHost, testCase)
        verify(host, "the sidebar host window was not created")
        host.width = 1280
        host.visible = true
        waitForRendering(host.contentItem, settleMs)

        var sb = host.sidebar
        verify(!sb.compact, "1280px must give the full sidebar, not the rail")
        tryVerify(function () { return sb.rows.length === 3 }, settleMs,
                  "the three fixture rows never reached the list")

        var moved = libraryRowFor(sb, "b2")
        verify(moved, "the row that is about to move was never drawn")
        var step = sb.libRowHeight
        tryVerify(function () { return Math.round(moved.y) === step }, settleMs,
                  "the fixture never settled with the row in the middle")

        // The reorder itself: the second row becomes the first.
        var movesBefore = sb.libraryMoves
        library.setEntriesForTest(libraryRows(true))
        tryVerify(function () { return sb.rows[0].id === "b2" }, settleMs,
                  "the model never took the new order")

        // The view takes the change on its next frame, which is 8 to 17ms away
        // on Qt 6.4 and 1ms on 6.12. Stepped in 1ms turns, so the row is read
        // as the transition starts and a 170ms travel has had no time to end.
        for (var turn = 0; sb.libraryMoves === movesBefore && turn < settleMs; ++turn)
            wait(1)

        if (row.reduced) {
            compare(Math.round(moved.y), 0,
                    "reduced motion: the row must be at the top on the next frame, not slide")
        } else {
            verify(Math.round(moved.y) !== 0,
                   "the row was drawn at its new place before it had travelled there")
            tryVerify(function () { return Math.round(moved.y) === 0 }, settleMs,
                      "the row never arrived at the top")
        }

        // Asked of a count, after the waiting is over: a slow poll cannot step
        // over a count. Reduced motion runs the move transition too, at zero
        // length, so this holds either way.
        verify(sb.libraryMoves > movesBefore,
               "the list did not animate the reorder at all - the row teleported")
        tryVerify(function () { return Math.round(libraryRowFor(sb, "a1").y) === step },
                  settleMs, "the row that was pushed down never reached its place")
    }

    // The queue overlay slides in off the right edge, under the scrim fading
    // up with it.
    function test_queue_panel_slides_data() { return test_rail_expansion_data() }

    function test_queue_panel_slides(row) {
        app.setReducedMotionForTest(row.reduced)

        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var qp = createTemporaryObject(queuePanelC, holder,
                                       { width: 900, height: 700 })
        verify(qp, "the queue panel was not created")
        settle(holder)

        compare(qp.openness, 0, "a closed panel is not closed")
        verify(!qp.visible, "a closed panel is still on screen")

        var list = findByName(qp, "queuePanelList")
        verify(list, "the panel has no list to measure")
        // Measured off the list: the slide is a transform, and only this reading
        // proves the transform is wired to openness.
        function inset() { return list.mapToItem(qp, 0, 0).x }

        qp.open = true
        verify(qp.visible, "the panel did not come on screen at all")

        if (row.reduced) {
            oneFrame()
            compare(qp.openness, 1,
                    "reduced motion: the panel must be open on the next frame, not slide")
            compare(Math.round(inset()), Math.round(qp.width - qp.panelWidth),
                    "reduced motion: the panel is still off to the right")
        } else {
            // Read with nothing in between: `openness` is driven by a Behavior,
            // which the write above has already started, so there is no frame
            // to wait for and no window for the slide to finish inside.
            verify(qp.openness < 1, "the panel jumped to open instead of sliding in")
            verify(inset() > qp.width - qp.panelWidth + 1,
                   "the panel was drawn at its resting place before it had slid in")
            tryVerify(function () { return qp.openness === 1 }, settleMs,
                      "the slide never finished")
            compare(Math.round(inset()), Math.round(qp.width - qp.panelWidth),
                    "the panel did not come to rest against the right edge")
        }

        qp.open = false
        if (row.reduced) {
            oneFrame()
            compare(qp.openness, 0, "reduced motion: the panel must be gone on the next frame")
            verify(!qp.visible, "reduced motion left the closed panel on screen")
        } else {
            verify(qp.visible, "the panel vanished instead of sliding out")
            verify(qp.openness > 0, "the panel jumped shut instead of sliding out")
            tryVerify(function () { return !qp.visible }, settleMs,
                      "the panel never finished leaving")
        }
    }

    // Every Menu in the app arrives the same way, which is why the transition
    // is declared once in ContextMenu.qml. TrackRow's menu is one of the two
    // that borrow it, so proving it here proves the sharing as well.
    function test_menus_fade_in_data() { return test_rail_expansion_data() }

    function test_menus_fade_in(row) {
        app.setReducedMotionForTest(row.reduced)

        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var tr = createTemporaryObject(trackRowC, holder,
                                       { width: 600, title: "Teardrop",
                                         artists: "Massive Attack" })
        verify(tr, "the track row was not created")
        settle(holder)

        tr.openMenu()
        var menu = tr.rowMenu
        verify(menu, "the row never built its menu")
        tryVerify(function () { return menu.visible }, settleMs, "the menu never opened")

        if (row.reduced) {
            compare(menu.opacity, 1,
                    "reduced motion: the menu must be fully there on the frame it opens")
        } else {
            verify(menu.opacity < 1, "the menu appeared at full opacity instead of fading in")
            tryVerify(function () { return menu.opacity === 1 }, settleMs,
                      "the menu never finished fading in")
        }

        menu.close()
        tryVerify(function () { return !menu.visible }, settleMs, "the menu never closed")
    }

    // A tab switch and a re-sort both replace the whole content area. The
    // views are modelled on JS arrays, which a view can only read as a reset,
    // so the fade is what is asserted.
    function test_collection_content_fades_in_data() { return test_rail_expansion_data() }

    function test_collection_content_fades_in(row) {
        app.setReducedMotionForTest(row.reduced)
        bridge.setFavoriteAlbumsForTest([
            { id: 1, title: "Aquarium",   artists: "Aqua Band",      coverUrl: "" },
            { id: 2, title: "Blue Lines", artists: "Massive Attack", coverUrl: "" }
        ])

        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var page = createTemporaryObject(collectionC, holder)
        verify(page, "CollectionPage was not created")
        settle(holder)

        compare(page.activeTab, 0, "the page did not open on the first tab")
        tryVerify(function () { return page.contentIn === 1 }, settleMs,
                  "the content never settled before the switch")

        var grid = findByName(page, "collectionAlbumsGrid")
        verify(grid, "the albums grid was not found")

        page.activeTab = 1
        oneFrame()
        verify(grid.visible, "the albums tab did not come up")

        if (row.reduced) {
            compare(page.contentIn, 1,
                    "reduced motion: the new tab must be fully there on the next frame")
            compare(grid.opacity, 1, "reduced motion left the grid half faded")
        } else {
            verify(page.contentIn < 1, "the new tab appeared outright instead of fading in")
            verify(grid.opacity < 1, "the grid is not following the page's fade")
            tryVerify(function () { return page.contentIn === 1 }, settleMs,
                      "the fade never finished")
            compare(grid.opacity, 1, "the grid did not come up to full opacity")
        }

        // A re-sort is the same change to the same content area.
        page.sortMode = 1
        oneFrame()
        if (row.reduced)
            compare(page.contentIn, 1, "reduced motion: a re-sort must land on the next frame")
        else
            verify(page.contentIn < 1, "a re-sort replaced the grid without a word")
    }

    // ── the sidebar's Home / Search / Collection highlight ───────────────
    // One bar serves the three rows, and it moves between them. The reading
    // that tells a travel from a cross-fade is the one taken between the two
    // rows: a highlight that fades is only ever at one end or the other.

    function navItemFor(sb, page) {
        var items = collectByName(sb, "sideNavItem", [])
        for (var i = 0; i < items.length; ++i) if (items[i].page === page) return items[i]
        return null
    }

    // The bar's centre and a row's centre, in the bar's own parent so the two
    // are comparable. Centres rather than tops, because the bar is half the
    // height of a row and its height is part of what travels.
    function barCentre(bar)       { return bar.y + bar.height / 2 }
    function rowCentre(bar, item) { return item.mapToItem(bar.parent, 0, 0).y + item.height / 2 }

    // True once the value has been seen strictly between its two ends.
    // Sampled in a loop, and the ends are read at every sample: a tab chip
    // changes width when it is deselected, which moves the chips after it.
    function sawBetween(read, readA, readB) {
        for (var i = 0; i < 200; ++i) {
            var v = read(), a = readA(), b = readB()
            if (v > Math.min(a, b) + 1 && v < Math.max(a, b) - 1) return true
            if (i > 2 && Math.abs(v - b) <= 1) return false
            wait(1)
        }
        return false
    }

    function test_nav_highlight_travels_data() { return test_rail_expansion_data() }

    function test_nav_highlight_travels(row) {
        app.setReducedMotionForTest(row.reduced)

        var host = createTemporaryObject(shellHost, testCase)
        verify(host, "the sidebar host window was not created")
        host.width = 1280
        host.visible = true
        waitForRendering(host.contentItem, settleMs)

        var sb = host.sidebar
        verify(!sb.compact, "1280px must give the full sidebar, not the rail")
        sb.currentPage = "home"
        var home   = navItemFor(sb, "home")
        var search = navItemFor(sb, "search")
        verify(home && search, "the nav rows were not found")

        // One bar for the three rows. One per row could only cross-fade.
        var bars = collectByName(sb, "navCurrentIndicator", [])
        compare(bars.length, 1, "the highlight is not one indicator: found " + bars.length)
        var bar = bars[0]

        tryVerify(function () { return Math.abs(barCentre(bar) - rowCentre(bar, home)) <= 1 },
                  settleMs, "the bar never settled on Home")
        compare(Math.round(bar.height), Math.round((home.height - 4) * 0.5),
                "the settled bar is not half the row's inner box")

        var fromY = rowCentre(bar, home)
        var toY   = rowCentre(bar, search)
        verify(Math.abs(toY - fromY) > 8,
               "the two rows are in the same place, so there is nothing to travel")

        sb.currentPage = "search"

        if (row.reduced) {
            // Sampled: no intermediate position is a claim about every frame of
            // the switch.
            for (var i = 0; i < 12; ++i) {
                verify(Math.abs(barCentre(bar) - toY) <= 1,
                       "reduced motion: sample " + i + " had the bar at "
                       + barCentre(bar).toFixed(1) + " and Search at " + toY.toFixed(1))
                wait(4)
            }
        } else {
            // Read in the turn of the write, before the Behavior's first tick.
            // Still on Home means it did not jump. The sampling below shows it
            // moved.
            verify(Math.abs(barCentre(bar) - fromY) <= 1,
                   "the bar jumped to Search instead of setting off from Home")
            verify(sawBetween(function () { return barCentre(bar) },
                              function () { return rowCentre(bar, home) },
                              function () { return rowCentre(bar, search) }),
                   "the bar was never between the two rows: it left one and "
                   + "arrived at the other without travelling")
            tryVerify(function () { return Math.abs(barCentre(bar) - toY) <= 1 },
                      settleMs, "the bar never finished arriving on Search")
        }
        compare(Math.round(bar.height), Math.round((search.height - 4) * 0.5),
                "the arrived bar is not half the row's inner box")

        // And away: an album is none of the three rows. The bar leaves from
        // where it is and does not travel.
        sb.currentPage = "album"
        if (row.reduced) {
            oneFrame()
            verify(!bar.visible, "reduced motion left the bar on a row that is not current")
        } else {
            verify(bar.visible, "the bar vanished instead of leaving")
            for (var j = 0; j < 8 && bar.visible; ++j) {
                verify(Math.abs(barCentre(bar) - toY) <= 1,
                       "the bar slid off the row while it was leaving it, to "
                       + barCentre(bar).toFixed(1))
                wait(4)
            }
            tryVerify(function () { return !bar.visible }, settleMs,
                      "the bar never finished leaving")
        }

        // And back. From a page that was on no row there is nothing on screen
        // to move, so the bar is on the picked row from the first frame it is
        // visible in.
        sb.currentPage = "collection"
        var coll = navItemFor(sb, "collection")
        verify(coll, "the Collection row was not found")
        for (var k = 0; k < 12; ++k) {
            verify(Math.abs(barCentre(bar) - rowCentre(bar, coll)) <= 1,
                   "sample " + k + ": the bar travelled back from a page that had "
                   + "no row, from " + barCentre(bar).toFixed(1) + " with the row at "
                   + rowCentre(bar, coll).toFixed(1))
            wait(4)
        }
        tryVerify(function () { return bar.visible }, settleMs,
                  "the bar never came back")
    }

    // The first placement is not a move, so the bar must not slide down from
    // the top of the panel. The sidebar is also hidden in fullscreen, and a
    // travel started behind that would come back halfway.
    function test_nav_highlight_starts_where_it_belongs() {
        var host = createTemporaryObject(shellHost, testCase, { startPage: "collection" })
        verify(host, "the sidebar host window was not created")
        host.width = 1280
        host.visible = true

        var sb = host.sidebar
        var bar = findByName(sb, "navCurrentIndicator")
        verify(bar, "there is no nav indicator")
        var coll = navItemFor(sb, "collection")
        var home = navItemFor(sb, "home")
        verify(coll && home, "the nav rows were not found")

        // Sampled from before the first frame, where a slide would be. Before
        // layout every row is at 0 and the bar agrees with all of them, so the
        // end checks that the rows did get laid out.
        for (var i = 0; i < 40; ++i) {
            verify(Math.abs(barCentre(bar) - rowCentre(bar, coll)) <= 1,
                   "sample " + i + ": the bar slid into place - it was at "
                   + barCentre(bar).toFixed(1) + " with the row at "
                   + rowCentre(bar, coll).toFixed(1))
            wait(4)
        }
        waitForRendering(host.contentItem, settleMs)
        verify(Math.abs(barCentre(bar) - rowCentre(bar, coll)) <= 1,
               "the bar is not on Collection")
        verify(Math.abs(rowCentre(bar, coll) - rowCentre(bar, home)) > 8,
               "the rows were never laid out, so this case proved nothing")
    }

    // ── Search's tabs: one pill, travelling ──────────────────────────────
    // One accent pill moves between the chips, as the row's sibling: a Row
    // lays out every visible child. Each label is drawn twice, clipped to its
    // own fill, so accent ink is only ever drawn on the accent, mid-travel too.

    function searchChipOf(tabs, i) { return tabs.children[i] }

    // The pill itself, read off the item that is drawn: a lag between the
    // host's markX/markW and the thing on screen would not show in the host's
    // numbers.
    function searchPillItem(tabs) { return findByName(tabs.parent, "searchTabPill") }

    // A chip's box in the pill's own coordinates, so the two are comparable.
    function searchChipBox(pill, chip) {
        var p = chip.mapToItem(pill.parent, 0, 0)
        return { x: p.x, y: p.y, w: chip.width, h: chip.height }
    }

    // Whether the pill is exactly on this chip.
    function searchPillOn(pill, chip) {
        if (!pill || !chip) return false
        var c = searchChipBox(pill, chip)
        return pill.visible
            && Math.abs(pill.x - c.x) <= 1 && Math.abs(pill.width  - c.w) <= 1
            && Math.abs(pill.y - c.y) <= 1 && Math.abs(pill.height - c.h) <= 1
    }

    function searchPillSays(pill) {
        if (!pill) return "there is no pill"
        return "the pill is at " + pill.x.toFixed(1) + "," + pill.y.toFixed(1)
               + " " + pill.width.toFixed(1) + "x" + pill.height.toFixed(1)
               + (pill.visible ? "" : " (not drawn)")
    }

    // Empty when every chip's accent-ink copy is inside the pill, every
    // chip's own label is the resting ink, and no chip paints an accent fill
    // of its own. Otherwise what was wrong with the first one.
    function searchInkIsOnTheAccent(tabs, pill) {
        if (!pill) return "there is no pill to compare the ink against"
        for (var i = 0; i < 6; ++i) {
            var chip = searchChipOf(tabs, i)
            if (!chip) return "chip " + i + " is missing"
            if (sameColor(chip.color, Theme.accent))
                return "chip " + i + " is filled with the accent itself, "
                       + "so there are two highlights on screen"
            var own = findByName(chip, "searchTabLabel")
            if (!own) return "chip " + i + " has no label"
            if (!sameColor(own.color, Theme.textSec))
                return "chip " + i + "'s own label is " + own.color + ", not the resting ink"
            var ink = findByName(chip, "searchTabInk")
            if (!ink) return "chip " + i + " has no accent-ink copy"
            var inkLabel = findByName(ink, "searchTabInkLabel")
            if (!inkLabel) return "chip " + i + "'s accent copy has no label"
            if (!sameColor(inkLabel.color, Theme.accentInk))
                return "chip " + i + "'s accent copy is " + inkLabel.color + ", not the accent's ink"
            if (!ink.visible || ink.width <= 0 || ink.height <= 0) continue
            var o = chip.mapToItem(pill.parent, ink.x, ink.y)
            var x0 = o.x, x1 = o.x + ink.width
            var y0 = o.y, y1 = o.y + ink.height
            if (x0 < pill.x - 0.5 || x1 > pill.x + pill.width + 0.5
                || y0 < pill.y - 0.5 || y1 > pill.y + pill.height + 0.5)
                return "chip " + i + "'s accent ink covers " + x0.toFixed(1) + ".." + x1.toFixed(1)
                       + " x " + y0.toFixed(1) + ".." + y1.toFixed(1) + " while " + searchPillSays(pill)
        }
        return ""
    }

    function test_search_tab_pill_travels_data() { return test_rail_expansion_data() }

    function test_search_tab_pill_travels(row) {
        app.setReducedMotionForTest(row.reduced)

        var sHolder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var sPage = createTemporaryObject(searchC, sHolder)
        verify(sPage, "SearchPage was not created")
        sPage.query = "te"                 // the tab row only exists with a query
        settle(sHolder)

        var tabs = findByName(sPage, "searchTabsRow")
        verify(tabs, "the search tab row was not found")
        // children[1] is the Tracks chip: a Repeater's delegates stack before
        // the Repeater itself in its parent's children, and the pill is the
        // row's sibling.
        var all    = searchChipOf(tabs, 0)
        var tracks = searchChipOf(tabs, 1)
        verify(all && tracks, "there are no chips to measure")
        compare(sPage.activeTab, 0, "the page did not open on the first tab")

        // One pill for the six chips. One per chip could only cross-fade.
        var pills = collectByName(sPage, "searchTabPill", [])
        compare(pills.length, 1, "the highlight is not one pill: found " + pills.length)
        var pill = pills[0]

        tryVerify(function () { return searchPillOn(pill, all) }, settleMs,
                  "the pill never settled on the first chip: " + searchPillSays(pill))
        // The chips carry no fill of their own. If one did, everything below
        // could pass with two highlights on screen.
        compare(all.color.a, 0,
                "the current chip is filled as well as marked, got " + all.color)
        compare(tracks.color.a, 0,
                "a chip that is not current is painting something, got " + tracks.color)
        compare(searchInkIsOnTheAccent(tabs, pill), "",
                "the ink is not where the accent is at rest")

        var fromX = searchChipBox(pill, all).x
        var toX   = searchChipBox(pill, tracks).x
        verify(toX - fromX > 8, "the two chips are in the same place; nothing to travel")

        sPage.activeTab = 1

        if (row.reduced) {
            // Every sample: no intermediate position is a claim about all of
            // them.
            for (var i = 0; i < 12; ++i) {
                verify(searchPillOn(pill, tracks),
                       "reduced motion: sample " + i + " - " + searchPillSays(pill)
                       + " and the chip is at " + searchChipBox(pill, tracks).x.toFixed(1)
                       + " " + tracks.width.toFixed(1) + " wide")
                wait(4)
            }
        } else {
            // Read in the turn of the write, before the Behavior's first tick.
            // Still on the old chip means it did not jump. The sampling below
            // shows it moved.
            verify(Math.abs(pill.x - fromX) <= 1,
                   "the pill jumped to the new chip instead of setting off: "
                   + searchPillSays(pill))
            // Both ends are re-read at every sample, so the reading is about the
            // pill and never about ends measured once.
            verify(sawBetween(function () { return pill.x },
                              function () { return searchChipBox(pill, all).x },
                              function () { return searchChipBox(pill, tracks).x }),
                   "the pill was never between the two chips: the highlight left "
                   + "one and appeared on the other without travelling")
            tryVerify(function () { return searchPillOn(pill, tracks) }, settleMs,
                      "the pill never finished arriving: " + searchPillSays(pill))
        }
        compare(searchInkIsOnTheAccent(tabs, pill), "",
                "the ink is not where the accent is after the travel")

        // The ink again, sampled through a whole travel: a half-covered label
        // only exists in the middle. Four chips' worth, so the pill is over a
        // label that is neither end for most of it.
        sPage.activeTab = 5
        var last = searchChipOf(tabs, 5)
        verify(last, "there is no Mixes chip")
        for (var j = 0; j < 60; ++j) {
            var wrong = searchInkIsOnTheAccent(tabs, pill)
            compare(wrong, "", "during the travel, " + wrong)
            if (searchPillOn(pill, last)) break
            wait(4)
        }
        tryVerify(function () { return searchPillOn(pill, last) }, settleMs,
                  "the pill never reached the last chip: " + searchPillSays(pill))
    }

    // Opened on a tab that is not the first: the pill is there, with no
    // travel. The query and the tab are set after creation, because initial
    // properties arrive sorted and activeTab would be applied before query.
    function test_search_tab_pill_starts_where_it_belongs() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var page = createTemporaryObject(searchC, holder)
        verify(page, "SearchPage was not created")
        page.query = "te"
        page.activeTab = 2

        var tabs = findByName(page, "searchTabsRow")
        verify(tabs, "the search tab row was not found")
        var pill = searchPillItem(tabs)
        verify(pill, "there is no pill")

        // From before the first frame. Before the Row has placed anything every
        // chip is at 0 and the pill agrees with all of them, so the end checks
        // that they did get placed.
        for (var i = 0; i < 40; ++i) {
            var chip = searchChipOf(tabs, 2)
            verify(chip, "the Albums chip was not built")
            verify(searchPillOn(pill, chip),
                   "sample " + i + ": the pill slid into place - " + searchPillSays(pill)
                   + " with the chip at " + searchChipBox(pill, chip).x.toFixed(1)
                   + " " + chip.width.toFixed(1) + " wide")
            wait(4)
        }
        settle(holder)
        verify(searchPillOn(pill, searchChipOf(tabs, 2)), "the pill is not on the third chip")
        verify(searchChipBox(pill, searchChipOf(tabs, 2)).x > 8,
               "the chips were never laid out, so this proved nothing")
    }


    // A tab picked while the row is off screen is where it belongs the
    // moment the row comes back. The tab and the query are set in one turn
    // with nothing rendered between them.
    function test_search_tab_pill_does_not_cross_a_hidden_row() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var page = createTemporaryObject(searchC, holder)
        verify(page, "SearchPage was not created")
        page.query = "te"
        settle(holder)

        var tabs = findByName(page, "searchTabsRow")
        verify(tabs, "the search tab row was not found")
        var pill = searchPillItem(tabs)
        verify(pill, "there is no pill")
        tryVerify(function () { return searchPillOn(pill, searchChipOf(tabs, 0)) }, settleMs,
                  "the pill never settled on the first chip: " + searchPillSays(pill))

        page.query = ""                  // the row goes away with the query
        settle(holder)
        verify(!tabs.visible, "the row is still on screen, so this proves nothing")

        page.activeTab = 4
        page.query = "te"                // and comes back, in the same turn

        for (var i = 0; i < 40; ++i) {
            var chip = searchChipOf(tabs, 4)
            verify(chip, "the Playlists chip was not built")
            verify(searchPillOn(pill, chip),
                   "sample " + i + ": the pill crossed the row on the way in - "
                   + searchPillSays(pill) + " with the chip at "
                   + searchChipBox(pill, chip).x.toFixed(1)
                   + " " + chip.width.toFixed(1) + " wide")
            wait(4)
        }
        settle(holder)
        verify(searchChipBox(pill, searchChipOf(tabs, 4)).x > 8,
               "the chips were never laid out, so this proved nothing")
    }

    // ── Collection's tabs: one pill, travelling ──────────────────────────
    // One accent pill moves between the chips, drawn as a slice inside each
    // chip, because a Flow lays out anything added to it. The label is drawn
    // twice, each copy clipped to its own fill, as on the Search page.

    function chipOf(tabs, i) { return tabs.children[i] }

    // The pill as it is drawn, in the row's coordinates. Read out of a
    // chip's slice: every chip holds the whole pill and shows the part over
    // itself, in a window that starts 2px outside the chip.
    function drawnPill(tabs) {
        var chip = chipOf(tabs, 0)
        if (!chip) return null
        var slice = findByName(chip, "collectionTabPillSlice")
        if (!slice) return null
        return { x: chip.x + slice.x - 2, y: chip.y + slice.y - 2,
                 w: slice.width, h: slice.height }
    }

    // Whether the pill is exactly on this chip. Both are in the row's
    // coordinates.
    function pillOn(tabs, chip) {
        var p = drawnPill(tabs)
        if (!p) return false
        return Math.abs(p.x - chip.x) <= 1 && Math.abs(p.w - chip.width)  <= 1
            && Math.abs(p.y - chip.y) <= 1 && Math.abs(p.h - chip.height) <= 1
    }

    function pillSays(tabs) {
        var p = drawnPill(tabs)
        if (!p) return "there is no pill"
        return "the pill is at " + p.x.toFixed(1) + "," + p.y.toFixed(1)
               + " " + p.w.toFixed(1) + "x" + p.h.toFixed(1)
    }

    // Every chip draws the same pill, or the name of the first that does not.
    function slicesAgree(tabs) {
        var p = drawnPill(tabs)
        for (var i = 1; i < 5; ++i) {
            var chip = chipOf(tabs, i)
            var slice = findByName(chip, "collectionTabPillSlice")
            if (!slice) return "chip " + i + " has no slice"
            if (Math.abs(chip.x + slice.x - 2 - p.x) > 0.01
                || Math.abs(slice.width - p.w) > 0.01)
                return "chip " + i + " draws the pill at " + (chip.x + slice.x - 2).toFixed(1)
                       + " " + slice.width.toFixed(1) + " wide, while " + pillSays(tabs)
        }
        return ""
    }

    // Empty when every chip's accent-ink copy is inside the pill and every
    // chip's own label is the resting ink. Otherwise what was wrong with the
    // first one.
    function inkIsOnTheAccent(tabs) {
        var pill = drawnPill(tabs)
        if (!pill) return "there is no pill to compare the ink against"
        for (var i = 0; i < 5; ++i) {
            var chip = chipOf(tabs, i)
            if (!chip) return "chip " + i + " is missing"
            var own = findByName(chip, "collectionTabLabel")
            if (!own) return "chip " + i + " has no label"
            if (!sameColor(own.color, Theme.textSec))
                return "chip " + i + "'s own label is " + own.color + ", not the resting ink"
            var ink = findByName(chip, "collectionTabInk")
            if (!ink) return "chip " + i + " has no accent-ink copy"
            if (!ink.visible || ink.width <= 0 || ink.height <= 0) continue
            var x0 = chip.x + ink.x, x1 = x0 + ink.width
            var y0 = chip.y + ink.y, y1 = y0 + ink.height
            if (x0 < pill.x - 0.5 || x1 > pill.x + pill.w + 0.5
                || y0 < pill.y - 0.5 || y1 > pill.y + pill.h + 0.5)
                return "chip " + i + "'s accent ink covers " + x0.toFixed(1) + ".." + x1.toFixed(1)
                       + " x " + y0.toFixed(1) + ".." + y1.toFixed(1) + " while " + pillSays(tabs)
        }
        return ""
    }

    function test_collection_tab_pill_travels_data() { return test_rail_expansion_data() }

    function test_collection_tab_pill_travels(row) {
        app.setReducedMotionForTest(row.reduced)

        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var page = createTemporaryObject(collectionC, holder)
        verify(page, "CollectionPage was not created")
        settle(holder)

        var tabs = findByName(page, "collectionTabsRow")
        verify(tabs, "the collection tab row was not found")
        var tracks = chipOf(tabs, 0)
        var albums = chipOf(tabs, 1)
        verify(tracks && albums, "there are no chips to measure")
        compare(page.activeTab, 0, "the page did not open on the first tab")

        // The chips do not carry the highlight themselves. If one filled,
        // everything below could pass with two highlights on screen.
        tryVerify(function () { return pillOn(tabs, tracks) }, settleMs,
                  "the pill never settled on the first chip: " + pillSays(tabs))
        verify(sameColor(tracks.color, Theme.surfaceHigh),
               "the current chip is filled as well as marked, got " + tracks.color)
        verify(sameColor(albums.color, Theme.surfaceHigh),
               "a chip that is not current is not on the resting fill, got " + albums.color)
        compare(inkIsOnTheAccent(tabs), "", "the ink is not where the accent is at rest")
        compare(slicesAgree(tabs), "", "the chips do not draw one pill between them")

        var fromX = tracks.x
        var toX   = albums.x
        verify(toX - fromX > 8, "the two chips are in the same place; nothing to travel")

        page.activeTab = 1

        if (row.reduced) {
            // Every sample: no intermediate position is a claim about all of
            // them.
            for (var i = 0; i < 12; ++i) {
                verify(pillOn(tabs, albums),
                       "reduced motion: sample " + i + " - " + pillSays(tabs)
                       + " and the chip is at " + albums.x.toFixed(1)
                       + " " + albums.width.toFixed(1) + " wide")
                wait(4)
            }
        } else {
            // Read in the turn of the write, before the Behavior's first tick.
            verify(Math.abs(drawnPill(tabs).x - fromX) <= 1,
                   "the pill jumped to the new chip instead of setting off: " + pillSays(tabs))
            verify(sawBetween(function () { return drawnPill(tabs).x },
                              function () { return tracks.x },
                              function () { return albums.x }),
                   "the pill was never between the two chips: the highlight left "
                   + "one and appeared on the other without travelling")
            tryVerify(function () { return pillOn(tabs, albums) }, settleMs,
                      "the pill never finished arriving: " + pillSays(tabs))
        }
        compare(inkIsOnTheAccent(tabs), "", "the ink is not where the accent is after the travel")
        compare(slicesAgree(tabs), "", "the chips do not draw one pill between them")

        // The ink again, sampled through a whole travel: a half-covered label
        // only exists in the middle.
        page.activeTab = 4
        for (var j = 0; j < 60; ++j) {
            var wrong = inkIsOnTheAccent(tabs)
            compare(wrong, "", "during the travel, " + wrong)
            if (pillOn(tabs, chipOf(tabs, 4))) break
            wait(4)
        }
        tryVerify(function () { return pillOn(tabs, chipOf(tabs, 4)) }, settleMs,
                  "the pill never reached the last chip: " + pillSays(tabs))
    }

    // Opened on a tab that is not the first: the pill is there, with no
    // travel.
    function test_collection_tab_pill_starts_where_it_belongs() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var page = createTemporaryObject(collectionC, holder, { activeTab: 2 })
        verify(page, "CollectionPage was not created")

        var tabs = findByName(page, "collectionTabsRow")
        verify(tabs, "the collection tab row was not found")

        // From before the first frame. Before the Flow has placed anything every
        // chip is at 0 and the pill agrees with all of them, so the end checks
        // that they did get placed.
        for (var i = 0; i < 40; ++i) {
            var chip = chipOf(tabs, 2)
            verify(chip, "the Artists chip was not built")
            verify(pillOn(tabs, chip),
                   "sample " + i + ": the pill slid into place - " + pillSays(tabs)
                   + " with the chip at " + chip.x.toFixed(1)
                   + " " + chip.width.toFixed(1) + " wide")
            wait(4)
        }
        settle(holder)
        verify(pillOn(tabs, chipOf(tabs, 2)), "the pill is not on the third chip")
        verify(chipOf(tabs, 2).x > 8, "the chips were never laid out, so this proved nothing")
    }

    // ── Now Playing rising out of the player bar ─────────────────────────
    // The page travels up out of the bar that opened it and sinks back down
    // into it. The number is read off the window and the position off the
    // page, because the number alone would pass with the transform unwired.

    function test_now_playing_rises_from_the_player_bar_data() {
        return test_rail_expansion_data()
    }

    function nowPlayingIn(win) {
        var hit = null
        function walk(item) {
            if (hit) return
            if (item.hasOwnProperty("lyricsness") && item.hasOwnProperty("stackness")) {
                hit = item
                return
            }
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) walk(kids[i])
        }
        walk(win.contentItem)
        return hit
    }

    function test_now_playing_rises_from_the_player_bar(row) {
        app.setReducedMotionForTest(row.reduced)

        var win = createTemporaryObject(appHostC, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 900
        win.visible = true
        waitForRendering(win.contentItem, settleMs)

        compare(win.currentPage, "home", "the window did not start on Home")
        compare(win.nowPlayingness, 0, "Now Playing is up with nothing asking for it")
        verify(!nowPlayingIn(win), "Now Playing is built before anyone asked for it")

        win.navigate("nowplaying")
        var page = nowPlayingIn(win)
        verify(page, "navigating to Now Playing did not build the page")

        // How far down the page is drawn from where it comes to rest. Measured
        // off the page, which shows that the transform is wired.
        function drop() { return page.mapToItem(win.contentItem, 0, 0).y }

        if (row.reduced) {
            oneFrame()
            compare(win.nowPlayingness, 1,
                    "reduced motion: the page must be up on the next frame, not rising")
            compare(Math.round(drop()), 0,
                    "reduced motion: the page is still down at the player bar")
        } else {
            // Read with nothing in between: the Behavior has already started, so
            // there is no frame to wait for and no window for the slide to finish
            // inside.
            verify(win.nowPlayingness < 1, "the page jumped up instead of rising")
            verify(drop() > 1, "the page was drawn at its resting place before it had risen")
            tryVerify(function () { return win.nowPlayingness === 1 }, settleMs,
                      "the rise never finished")
            compare(Math.round(drop()), 0, "the page did not come to rest filling the area")
        }

        // And back down into the bar. The page has to outlive the navigation
        // for that.
        win.goBack()
        compare(win.currentPage, "home", "going back did not leave Now Playing")

        if (row.reduced) {
            oneFrame()
            compare(win.nowPlayingness, 0,
                    "reduced motion: the page must be gone on the next frame")
            verify(!nowPlayingIn(win), "reduced motion left the closed page built")
        } else {
            verify(nowPlayingIn(win) === page,
                   "the page was thrown away instead of sinking back into the bar")
            verify(win.nowPlayingness > 0, "the page vanished instead of sinking")
            tryVerify(function () { return win.nowPlayingness === 0 }, settleMs,
                      "the page never finished sinking")
            tryVerify(function () { return !nowPlayingIn(win) }, settleMs,
                      "the page was never freed after it left")
        }
    }

    // The lyric being sung is kept in the middle of the panel, and a line
    // change scrolls to it.
    function test_lyrics_scroll_travels_data() { return test_rail_expansion_data() }

    function test_lyrics_scroll_travels(row) {
        app.setReducedMotionForTest(row.reduced)

        var host = showWindow(nowPlayingHostC, 1280, 1200)
        var page = host.page

        // The bridge stub answers fetchLyrics with nothing by design, so the
        // page's own lyrics state is written here.
        var lines = []
        for (var i = 0; i < 40; ++i)
            lines.push({ ms: i * 5000,
                         text: "Line " + i + " of a lyric long enough to want a measure" })
        page.lyricsIsTimed = true
        page.lyricsData    = lines
        page.lyricsState   = "ready"
        page.userScrolled  = false
        page.currentLyricLine = 0
        player.setPositionForTest(0)
        page.showLyrics = true
        tryVerify(function () { return page.lyricsness === 1 }, settleMs,
                  "the lyrics panel never opened")
        waitForRendering(host.contentItem, settleMs)

        var view = findByName(page, "nowPlayingLyricsView")
        verify(view, "the lyric list was not found")

        // How far the sung line is from the middle of the panel.
        function offCentre() {
            var it = view.itemAtIndex(page.currentLyricLine)
            if (!it) return 1e6
            return Math.abs(it.mapToItem(view, 0, it.height / 2).y - view.height / 2)
        }

        // Twenty lines on, so centring is clamped at neither end. Driven by hand:
        // waiting for the sync timer could step over the whole scroll. The
        // position moves first, or the timer would scroll back to line 0.
        player.setPositionForTest(20 * 5000)
        page.currentLyricLine = 20
        page.centreLyricLine(20, true)

        if (row.reduced) {
            oneFrame()
            verify(offCentre() <= 8,
                   "reduced motion: the sung line must be centred on the next frame, off by "
                   + offCentre().toFixed(1) + "px")
        } else {
            verify(offCentre() > 8,
                   "the lyrics jumped to the new line instead of scrolling to it")
            tryVerify(function () { return offCentre() <= 8 }, settleMs,
                      "the scroll never brought the sung line to the middle: off by "
                      + offCentre().toFixed(1) + "px")
        }
    }
}
