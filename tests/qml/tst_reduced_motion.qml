// X6, second half: every animation in the app respects the platform's
// reduced-motion preference.
//
// What is asserted here is behaviour, never source text. Counting
// `Behavior on` lines would pass the day someone adds the twenty-sixth
// animation and forgets, so each case below drives a real component and
// measures the property itself:
//
//   * with the preference on, the property is already on its target value in
//     the frame the change was made, and
//   * with it off, the very same property is still travelling a frame later
//     and only arrives afterwards.
//
// Instant, not absent: reduced motion collapses a duration to zero rather
// than switching the animation off, so a transition still starts and still
// finishes and anything waiting on the end of one keeps working. The spinner
// case guards the other half of that rule — an indefinite "still working"
// indicator must stop moving without disappearing.
//
// `app` is the stub from tests/TestStubs.h. app.setReducedMotionForTest() is
// the only way in, because the real Application reads the preference off the
// desktop once at startup and offers no setter.

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

    // Prefs::railWidth and the default sidebar width, repeated so a silent
    // change to either is a failure here rather than a tautology.
    readonly property int railWidth: 68
    readonly property int defaultSidebar: 220

    // The slowest animation any case below drives, plus room for a slow box.
    readonly property int settleMs: 2000

    function init() {
        app.setReducedMotionForTest(false)
        prefs.setSidebarWidthForTest(defaultSidebar)
        auth.setStateForTest(2)          // LoggedIn
        auth.setHasSavedCredentialsForTest(false)
        auth.setUsernameForTest("linus")
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

            RowLayout {
                anchors.fill: parent
                spacing: 0
                // The three lines Main.qml uses, so the rail overlays the
                // page here exactly as it does in the app.
                SideBar {
                    id: sb
                    z: 2
                    hostWidth: win.width
                    Layout.preferredWidth: sb.reservedWidth
                    Layout.fillHeight: true
                }
                Item { Layout.fillWidth: true; Layout.fillHeight: true }
            }
        }
    }

    // X3's two breakpoint layouts. Now Playing delegates its sleep timer to
    // Window.window, so it cannot be instantiated bare; this mirrors exactly
    // the surface Main.qml provides, as tst_layout_player.qml's host does.
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

    // The guard has to hold up in a host that never installed `app` at all —
    // an unqualified name that is not there throws a ReferenceError, and
    // tests/tst_firstrun.cpp fails the build on any QML warning. This builds
    // the same expression Theme uses against a global that is deliberately
    // not installed anywhere.
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

    // ── L4: the sidebar rail hover-expand ────────────────────────────────

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

        // And back. A collapse that is instant one way and animated the other
        // would be worse than either.
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

    // ── X3: the two layouts that rearrange at a breakpoint ───────────────
    //
    // Now Playing stacks its cover above its text below 1000px and the player
    // bar sheds its volume slider below 720. Both used to re-form between two
    // frames; both travel now, off one property with one Behavior, the same
    // shape as the sidebar's slide. So both have to answer the same question
    // this file asks of everything else: with the preference on, the layout is
    // the new layout in the frame the width changed -- not half way through the
    // move, and not left behind at the old one.

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

        // And back. A rearrangement that is instant one way and animated the
        // other would be worse than either.
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

    function test_player_bar_sheds_its_slider_data() { return test_rail_expansion_data() }

    function test_player_bar_sheds_its_slider(row) {
        app.setReducedMotionForTest(row.reduced)

        var host = showWindow(playerBarHostC, 760, 200)
        var bar = host.bar
        tryVerify(function () { return bar.volumeSlotRoom === bar.volumeSliderWidth },
                  settleMs, "the wide bar never settled with its slider")

        host.width = 700                 // below the breakpoint: the slider goes
        oneFrame()

        if (row.reduced) {
            compare(bar.volumeSlotRoom, 0,
                    "reduced motion: the slot must be closed on the next frame, not closing")
            verify(!bar.volumeSlot.visible,
                   "reduced motion left an empty slot on the bar")
            verify(bar.volumeInlineGone,
                   "reduced motion: the hover flyout is still waiting for the inline slider")
        } else {
            verify(bar.volumeSlotRoom > 0,
                   "without reduced motion the slot shut between two frames")
            tryVerify(function () { return bar.volumeSlotRoom === 0 }, settleMs,
                      "the slot never finished closing")
        }
        verify(!bar.volumeSlider.visible, "the narrow bar kept its inline slider")

        host.width = 760
        oneFrame()

        if (row.reduced) {
            compare(bar.volumeSlotRoom, bar.volumeSliderWidth,
                    "reduced motion: taking the slider back must be instant too")
        } else {
            verify(bar.volumeSlotRoom < bar.volumeSliderWidth,
                   "without reduced motion the slot sprang open between two frames")
            tryVerify(function () { return bar.volumeSlotRoom === bar.volumeSliderWidth },
                      settleMs, "the slot never finished opening")
        }
        verify(bar.volumeSlider.visible, "the wide bar did not get its slider back")
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

    // Navigating between pages is a Loader swap with no animation of its own,
    // so the one transition a page animates is the login card resizing as the
    // auth state moves on. 220px (signed out) to 400px (waiting for the
    // device code) is the tallest jump it makes.
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

    // A spinner or a pulse says "still working", so reduced motion must not
    // delete it: it stops moving and stands still, and it is still on screen.
    //
    // The login dots are the case measured here rather than the download
    // spinners, because a RotationAnimator is driven by the render thread and
    // the offscreen platform this suite runs under never advances one — its
    // `rotation` reads 0 forever whatever the preference says, so it can
    // neither pass nor fail honestly. The dots are an ordinary
    // SequentialAnimation on the GUI thread and answer truthfully. Both are
    // shaped the same way (`loops: Theme.reduceMotion ? 1 : Animation.Infinite`
    // against a zero duration), so this covers the idiom.

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
        // PendingDevice: "Waiting for you to log in…", with the pulsing dots.
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

    // The download spinners cannot have their rotation measured here (see
    // above), but the half that matters most is still checkable: reduced
    // motion must leave the busy mark on screen rather than remove it.
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
    }

    // The now-playing bars are the other indefinite indicator, and the only
    // one whose stillness has to stay *legible*: with the animation gone it
    // is all that distinguishes "this is playing" from the track waveform
    // next to it in the same row. tst_menus_and_glyphs asserts the shape it
    // parks at; this asserts that it parks at all, and that it really does
    // move when it is allowed to.
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
    //
    // The cases above are all one property easing to a new value. These five
    // are the other kind: something changes *place* or is replaced outright,
    // and the question is whether it arrives or is simply drawn there.

    Component { id: queuePanelC;   QueuePanel   { open: false } }
    Component { id: collectionC;   CollectionPage { anchors.fill: parent } }
    Component { id: searchC;       SearchPage   { anchors.fill: parent } }
    Component { id: trackRowC;     TrackRow     { } }

    // Now Playing's way in and out belongs to the window and not to the page -
    // what has to outlive the navigation is the Loader - so this one case needs
    // the real Main.qml, as tst_nowplaying_access.qml's window tests do.
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

    // S4/P3: pinning, playing or liking something moves a row to a different
    // tier, so the sidebar's library list reorders while it is being looked at.
    // It is the list in the app that reorders most often.
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

        // One frame: long enough for the view to take the change and start the
        // transition, far too short for a 170ms travel to finish.
        oneFrame()

        if (row.reduced) {
            compare(Math.round(moved.y), 0,
                    "reduced motion: the row must be at the top on the next frame, not slide")
        } else {
            verify(Math.round(moved.y) !== 0,
                   "the row was drawn at its new place before it had travelled there")
            tryVerify(function () { return Math.round(moved.y) === 0 }, settleMs,
                      "the row never arrived at the top")
        }

        // Asked of a count rather than of a "still moving" flag, and asked
        // after the waiting is over: a count cannot be stepped over by a slow
        // poll, so this says whether the reorder went through the view's move
        // transition however loaded the machine is. Reduced motion runs the
        // transition too, at zero length, so it holds either way.
        verify(sb.libraryMoves > movesBefore,
               "the list did not animate the reorder at all - the row teleported")
        tryVerify(function () { return Math.round(libraryRowFor(sb, "a1").y) === step },
                  settleMs, "the row that was pushed down never reached its place")
    }

    // L9: the queue overlay. It used to appear and disappear between two
    // frames; it slides in off the right edge instead, under the scrim fading
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
        // Measured off the list rather than off `openness`: the slide is a
        // transform, and this is the only reading that proves the transform is
        // wired to it.
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
    // so what is asserted is the fade and not a reorder.
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
    //
    // Three things said one thing: a fill, an ink and a 3px bar down the left
    // edge. All three changed between two frames, and the bar was `visible:
    // current`, which cannot animate at all - so the one part of the highlight
    // that reads as a position was the one part that could only blink.
    //
    // Measured off the indicator's height as well as off the row's number: the
    // number arriving is not the same as the bar arriving, and a bar that is
    // there or not is exactly what this case is about.

    function navItemFor(sb, page) {
        var items = collectByName(sb, "sideNavItem", [])
        for (var i = 0; i < items.length; ++i) if (items[i].page === page) return items[i]
        return null
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
        tryVerify(function () { return home.currentness === 1 && search.currentness === 0 },
                  settleMs, "the sidebar never settled on Home")

        var bar = findByName(search, "navCurrentIndicator")
        verify(bar, "the Search row has no current-indicator to measure")
        verify(!bar.visible, "an indicator on a row that is not current")

        sb.currentPage = "search"

        if (row.reduced) {
            oneFrame()
            compare(search.currentness, 1,
                    "reduced motion: the highlight must be on Search on the next frame, not travelling")
            compare(home.currentness, 0, "reduced motion: the old highlight is still leaving")
            verify(bar.visible && bar.height > 1,
                   "reduced motion: the indicator never came up")
        } else {
            // Read with nothing in between, and not after a frame. A Behavior
            // does not tick in the turn its property is written: measured over
            // twenty runs, the value had not moved once with nothing elapsed,
            // and had moved in three of twenty after a single wait(1). So a
            // reading taken a frame later is a question about the animation
            // driver's scheduling, and only a reading taken in the same turn is
            // a question about the thing being measured.
            verify(search.currentness < 1,
                   "without reduced motion the highlight jumped to Search instead of arriving")
            verify(home.currentness > 0, "the highlight it left snapped out instead of fading")
            // The indicator is the number and not a flag of its own: at every
            // phase of the travel it is as tall as the number says, and on
            // screen only while the number is. Asked at whatever phase this
            // turn caught, so there is no moment to miss - which `visible:
            // current` and a fixed height cannot satisfy at any phase but the
            // last one.
            compare(bar.visible, search.currentness > 0.001,
                    "the indicator is on screen without the highlight being there")
            compare(Math.round(bar.height),
                    Math.round(bar.parent.height * 0.5 * search.currentness),
                    "the indicator's height does not follow the highlight")
            tryVerify(function () { return search.currentness === 1 }, settleMs,
                      "the highlight never finished arriving")
            tryVerify(function () { return home.currentness === 0 }, settleMs,
                      "the old highlight never finished leaving")
        }
        compare(Math.round(bar.height), Math.round(bar.parent.height * 0.5),
                "the settled indicator is not half the row")

        // And away again, because the indicator leaving is the half that used to
        // be a blink in the other direction too.
        sb.currentPage = "collection"
        if (row.reduced) {
            oneFrame()
            compare(search.currentness, 0, "reduced motion: leaving must be instant too")
            verify(!bar.visible, "reduced motion left the indicator on a row that is not current")
        } else {
            verify(search.currentness > 0, "the highlight snapped off Search")
            verify(bar.visible, "the indicator vanished instead of leaving")
            tryVerify(function () { return !bar.visible }, settleMs,
                      "the indicator never finished leaving")
        }
    }

    // ── the tab chips on Collection and Search ───────────────────────────
    //
    // The content area already faded on a switch and the chip that switched it
    // did not, which is the wrong way round: the chip is what the eye is on when
    // it is clicked. The chip's own fill and ink travel now, a little shorter
    // than the content, so the chip answers and the page follows.
    //
    // The label's weight does not travel. A font weight is not a number Qt
    // interpolates, so `font.bold` lands in the frame of the click whatever this
    // says; the fill around it is what carries the change.
    //
    // Nor does the label's ink, and that one is deliberate rather than a
    // limitation. The two inks are luminance-inverted against the two fills on
    // the three light palettes - dark ink on a light chip becomes white ink on a
    // dark one - so fading both at once walks the label down to 1.01:1 and back,
    // under 2:1 for 57ms of a 140ms fade. The ink steps at the fill's halfway
    // point instead, which is asserted below: every reading of it is one of the
    // two inks and never between them.

    // Samples a chip's label ink until its fill has arrived, and returns the
    // first reading that is neither of the two inks, or "" if there was none.
    function inkBlendDuring(chip, label) {
        if (!label) return "no label to read"
        for (var i = 0; i < 60; ++i) {
            var c = String(label.color)
            if (c !== String(Theme.textSec) && c !== String(Theme.accentInk)) return c
            if (sameColor(chip.color, Theme.accent)) break
            wait(4)
        }
        return ""
    }

    function test_tab_chip_travels_data() { return test_rail_expansion_data() }

    function test_tab_chip_travels(row) {
        app.setReducedMotionForTest(row.reduced)

        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var page = createTemporaryObject(collectionC, holder)
        verify(page, "CollectionPage was not created")
        settle(holder)

        var tabs = findByName(page, "collectionTabsRow")
        verify(tabs, "the collection tab row was not found")
        var albums = tabs.children[1]
        verify(albums, "there is no Albums chip to measure")
        compare(page.activeTab, 0, "the page did not open on the first tab")
        tryVerify(function () { return sameColor(albums.color, Theme.surfaceHigh) },
                  settleMs, "the chip never settled on its resting fill")

        page.activeTab = 1

        if (row.reduced) {
            oneFrame()
            verify(sameColor(albums.color, Theme.accent),
                   "reduced motion: the chip must be filled on the next frame, got " + albums.color)
        } else {
            // Not there yet, read in the turn of the write - see the note in
            // the case above. What is deliberately *not* asked is whether the
            // fade has already moved off the resting fill: a Behavior holds the
            // old value until its first tick, so that is a question about the
            // scheduler and it answered yes in three runs of twenty. The pair
            // below covers both ways this can be wrong anyway - a chip that
            // snaps fails here, and a chip that never fades fails the wait.
            verify(!sameColor(albums.color, Theme.accent),
                   "without reduced motion the chip snapped to the accent instead of filling")
            // Sampled all the way through, because a faded ink would be a blend
            // in almost every one of these and a stepped one can never be in any
            // of them. Nothing here can miss a violation that lasts the whole
            // fade, and nothing here can invent one.
            var blended = inkBlendDuring(albums, findByName(albums, "collectionTabLabel"))
            compare(blended, "",
                    "the chip's label faded its ink instead of stepping: " + blended
                    + " is neither of the two inks, and on a light palette that path "
                    + "goes through an invisible label")
            tryVerify(function () { return sameColor(albums.color, Theme.accent) }, settleMs,
                      "the chip never finished filling")
        }

        // Search's row is the same change to the same kind of control, and is
        // the half that would quietly go unanimated: it is a second file.
        var sHolder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var sPage = createTemporaryObject(searchC, sHolder)
        verify(sPage, "SearchPage was not created")
        sPage.query = "te"                 // the tab row only exists with a query
        settle(sHolder)

        var sTabs = findByName(sPage, "searchTabsRow")
        verify(sTabs, "the search tab row was not found")
        var tracksChip = sTabs.children[1]
        verify(tracksChip, "there is no Tracks chip to measure")
        tryVerify(function () { return !sameColor(tracksChip.color, Theme.accent) },
                  settleMs, "the search chip never settled off the accent")

        sPage.activeTab = 1

        if (row.reduced) {
            oneFrame()
            verify(sameColor(tracksChip.color, Theme.accent),
                   "reduced motion: Search's chip must be filled on the next frame, got "
                   + tracksChip.color)
        } else {
            verify(!sameColor(tracksChip.color, Theme.accent),
                   "Search's chip snapped to the accent instead of filling")
            var sBlended = inkBlendDuring(tracksChip, findByName(tracksChip, "searchTabLabel"))
            compare(sBlended, "",
                    "Search's chip faded its label ink instead of stepping: " + sBlended)
            tryVerify(function () { return sameColor(tracksChip.color, Theme.accent) },
                      settleMs, "Search's chip never finished filling")
        }
    }

    // ── Now Playing rising out of the player bar ─────────────────────────
    //
    // It appeared and disappeared outright, both ways. It travels up out of the
    // bar that opened it and sinks back down into it, which is the direction the
    // bar's chevron already points.
    //
    // The number is read off the window and the position off the page, because
    // the number alone would pass with the transform unwired - the same pair the
    // queue panel's case reads.

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
        // off the page and not off the number: the slide is a transform, and this
        // is the only reading that proves the transform is wired to it.
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

        // And back down into the bar. The page has to outlive the navigation for
        // that, which is the whole reason this is hosted on the window.
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

    // The lyric being sung is kept in the middle of the panel. Every line
    // change used to write the scroll offset outright, so the words jumped.
    function test_lyrics_scroll_travels_data() { return test_rail_expansion_data() }

    function test_lyrics_scroll_travels(row) {
        app.setReducedMotionForTest(row.reduced)

        var host = showWindow(nowPlayingHostC, 1280, 1200)
        var page = host.page

        // The bridge stub answers fetchLyrics with nothing by design, so the
        // page's own lyrics state is written here instead. Same as
        // tests/qml/tst_layout_player.qml does it.
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

        // Twenty lines on: far enough that centring is clamped at neither end.
        //
        // Driven by hand rather than by waiting for the sync timer, which is
        // what calls this in the app. Waiting for the timer means waiting, and
        // a poll that runs long on a loaded machine can step over the whole
        // scroll and read the end of it as "it never moved". Nothing elapses
        // between the call below and the reading after it, so there is no
        // window to miss. That the timer calls it is tst_layout_player.qml's
        // business - it asserts the sung line ends up centred.
        // The position moves first so the sync timer agrees with the line
        // below. Left at zero it would decide line 0 was the one being sung and
        // scroll straight back on its next tick.
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
