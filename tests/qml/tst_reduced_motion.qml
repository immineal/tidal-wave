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
            // The page the sidebar is built on, for the cases about the first
            // placement: handed in at creation, because a page assigned
            // afterwards is a move and those cases are about what happens
            // before there has been one.
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

        // The other half of the contract, read off the animation rather than
        // timed. A clock is no use here: a zero-length turn and a 900ms one
        // have both finished by the time anything could look, so "it stopped"
        // is true either way and says nothing. The two numbers do say it —
        // reduced motion collapses the turn to zero length, and takes the
        // endless repeat with it, because a zero duration against
        // Animation.Infinite is a spin loop rather than a still dial.
        var rot = findInData(overlay, "loadingSpinnerRotation")
        verify(rot, "the spinner has no named rotation to check")
        compare(rot.duration, 0,
                "reduced motion left the spinner a turn to make")
        compare(rot.loops, 1,
                "a zero-length turn repeated forever is a spin loop, not stillness")
    }

    // Whether the spinner *turns* is what the case above cannot ask, and it
    // went unasserted for long enough that its `running` binding could sit
    // broken: a rotation that never stops is indistinguishable from a correct
    // one until you look at the frames, which this platform has none of (see
    // the note above). `running` is the honest proxy — with motion allowed it
    // is on exactly while the overlay is on screen, and off the moment it is
    // not, because an indefinite animation behind a hidden overlay runs for
    // the life of the app.
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
    // There was a 3px bar per row, each fading its own opacity and growing its
    // own height. That is three bars cross-fading: the highlight left one row
    // and appeared on another with nothing travelling between the two (QA: "the
    // highlighting bar can move up and not just fade out in one place and then
    // fade in in the other place"). There is one bar now, and it moves.
    //
    // So what is measured here is a position, and the reading that tells a
    // travel from a cross-fade is the one taken *between* the two rows: a
    // highlight that fades is only ever at one end or the other, whatever its
    // opacity is doing.

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
    //
    // Sampled in a loop and not read after a fixed wait: one reading can only
    // catch a travel it happens to land inside, and a 140ms one has about eight
    // frames on an idle box and fewer on a loaded one. Giving up the moment the
    // value is at the far end keeps a case that has already failed from costing
    // the whole loop.
    //
    // The ends are read at every sample rather than measured once up front,
    // which matters wherever they move: a tab chip loses its bold weight in the
    // frame it is deselected, so the chips after it all shift left, and against
    // the ends as they were before the click a pill that never moved at all
    // reads as being between them. Probed - with the travel cut to a single
    // frame, the version that measured the ends once passed.
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

        // One bar for the three rows. One per row is the cross-fade this case
        // exists to rule out, and it would answer everything below from
        // whichever row was asked.
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
            // Sampled rather than read once: "no intermediate position" is a
            // claim about every frame of the switch, and a single reading taken
            // after one of them says nothing about the others.
            for (var i = 0; i < 12; ++i) {
                verify(Math.abs(barCentre(bar) - toY) <= 1,
                       "reduced motion: sample " + i + " had the bar at "
                       + barCentre(bar).toFixed(1) + " and Search at " + toY.toFixed(1))
                wait(4)
            }
        } else {
            // Read in the turn of the write, before the Behavior's first tick -
            // see the note in the rail case above. Still on Home means it did
            // not jump; the sampling below is what says it moved.
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
        // where it is rather than travelling off to nowhere, which is the half
        // of this that a position alone cannot say.
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
        // to move, so the bar belongs on the row that was picked from the first
        // frame it is visible in - not sliding in from the row it left, which
        // is where a travel measured from the last target would start it.
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

    // The first placement is not a move. A bar that animates it starts at the
    // top of the panel and slides down to the row on every launch - and the
    // sidebar is hidden outright in fullscreen, so a travel started behind that
    // would come back halfway.
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

        // Sampled from before the first frame, because that is where a slide
        // would be. The early readings are taken before the column has laid
        // anything out, when every row is at 0 and the bar agrees with all of
        // them - which is why the check at the end is that the rows did get
        // laid out and the bar is on the right one.
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
    //
    // Search's chips used to do what Collection's did before e304a63: the one
    // being left faded back to nothing while the one arriving faded up to the
    // accent, so the highlight was briefly nowhere and nothing ever crossed the
    // gap between the two (QA: "the highlighting bar can move up and not just
    // fade out in one place and then fade in in the other place"). It is one
    // accent pill now and it moves between them - the same thing the sidebar's
    // bar does between its rows and Collection's pill does between its chips,
    // on the same 140ms, so the three read as one idea.
    //
    // The pill is one whole item here and not Collection's per-chip slices:
    // Search's chips are in a Row, which lays out every visible child it has,
    // so the pill cannot be *in* the row - but it can be the row's sibling,
    // which is what Collection's Flow left nowhere for. One item means the
    // crossing of the 4px gaps needs no arranging at all; it is asserted below
    // anyway, as the one pill every reading comes from.
    //
    // What the ink has to answer changes with the fill, and the answer is a
    // stronger one rather than a weaker one. A fading chip cannot fade its
    // label - the two inks are luminance-inverted against the two fills on the
    // three light palettes, dark ink on a bare row becoming white ink on an
    // accent chip - so the ink stepped at the fill's halfway point and took one
    // frame at 2.1:1, and the step is what this case used to assert. A
    // *travelling* fill cannot be answered by a step at all: whichever ink a
    // half-covered label picked, half of its glyphs would be on the wrong fill
    // for as long as the pill's edge took to cross them, which is far longer
    // than a frame. So the label is drawn twice, each copy clipped to its own
    // fill, and what is asserted below is that no accent ink is ever drawn
    // anywhere but on the accent, at every phase of a travel and not only at
    // its two ends.
    //
    // That subsumes the reading it replaces. "Every reading of the ink is one
    // of the two inks and never between them" is still checked, at every
    // sample and on both copies - the chip's own is the resting ink exactly,
    // the clipped copy is the accent's ink exactly - and the new half is the
    // one a step could never give: *which* of the two is on a given pixel is
    // decided by where the pill is rather than by a clock.

    function searchChipOf(tabs, i) { return tabs.children[i] }

    // The pill itself. Read off the item that is drawn and not off the host's
    // markX/markW, because a lag put between the host's numbers and the thing
    // on screen would not show in the host's numbers. Probed: a Behavior on
    // the pill's own x takes the reduced-motion sampling and the mid-travel
    // ink below red, and markX - which is a lerp of two chips' boxes, and
    // nothing a Behavior on the Rectangle can reach - says the same thing
    // throughout.
    function searchPillItem(tabs) { return findByName(tabs.parent, "searchTabPill") }

    // A chip's box in the pill's own coordinates, so the two are comparable.
    // mapToItem and not an assumption about where the row sits inside its host.
    function searchChipBox(pill, chip) {
        var p = chip.mapToItem(pill.parent, 0, 0)
        return { x: p.x, y: p.y, w: chip.width, h: chip.height }
    }

    // Is the pill exactly on this chip?
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

    // "" when every chip's accent-ink copy is inside the pill, every chip's own
    // label is still the resting ink, and no chip has gone back to painting an
    // accent fill of its own - or what was wrong with the first one that did.
    // The three are the same question asked of the three layers: the ink on
    // screen at any pixel is the one its fill was chosen for, and there is only
    // one fill.
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
        // row's sibling rather than one of the row's children, so nothing here
        // has been pushed along.
        var all    = searchChipOf(tabs, 0)
        var tracks = searchChipOf(tabs, 1)
        verify(all && tracks, "there are no chips to measure")
        compare(sPage.activeTab, 0, "the page did not open on the first tab")

        // One pill for the six chips. One per chip is the cross-fade this case
        // exists to rule out, and it would answer everything below from
        // whichever chip was asked.
        var pills = collectByName(sPage, "searchTabPill", [])
        compare(pills.length, 1, "the highlight is not one pill: found " + pills.length)
        var pill = pills[0]

        tryVerify(function () { return searchPillOn(pill, all) }, settleMs,
                  "the pill never settled on the first chip: " + searchPillSays(pill))
        // The chips carry no fill of their own any more - if one of them still
        // filled, everything below could pass with two highlights on screen.
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
            // Every sample, not one: "no intermediate position" is a claim
            // about all of them.
            for (var i = 0; i < 12; ++i) {
                verify(searchPillOn(pill, tracks),
                       "reduced motion: sample " + i + " - " + searchPillSays(pill)
                       + " and the chip is at " + searchChipBox(pill, tracks).x.toFixed(1)
                       + " " + tracks.width.toFixed(1) + " wide")
                wait(4)
            }
        } else {
            // Read in the turn of the write, before the Behavior's first tick -
            // see the note in the rail case above. Still on the old chip means
            // it did not jump; the sampling below is what says it moved.
            verify(Math.abs(pill.x - fromX) <= 1,
                   "the pill jumped to the new chip instead of setting off: "
                   + searchPillSays(pill))
            // Both ends re-read at every sample. Search's labels never go bold,
            // so its chips do not resize under the pill the way Collection's
            // do - but a reading against ends measured once is a question about
            // the ends, and this one is about the pill.
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

        // The ink again, this time sampled through a whole travel rather than
        // at its ends: a half-covered label is exactly the state a stepped ink
        // gets wrong, and it only exists in the middle. Four chips' worth, so
        // the pill is over a label that is neither end for most of it.
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

    // Opened on a tab that is not the first: the pill is there, not on its way
    // there. Same rule as the sidebar's bar and Collection's pill, and the one
    // a lerp between two live boxes gets wrong by sliding out of the row's left
    // edge on every query that brings the row back.
    //
    // The query and the tab are set in the turn the page was made in, and not
    // handed to createTemporaryObject as initial properties: a QVariantMap
    // arrives sorted, so `activeTab` would be applied before `query` and the
    // row would still be hidden when the tab changed - which is a different
    // guard, and the one the case below this is about. Here the row is on
    // screen and nothing has been rendered yet, which is the one placement
    // that is an initialisation rather than a move.
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

        // From before the first frame. The early readings are taken before the
        // Row has placed anything, when every chip is at 0 and the pill agrees
        // with all of them - so the end of this checks that they did get placed
        // and that the pill is on the right one.
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


    // A tab picked while the row is off screen - the query cleared, the page
    // on another of the shell's pages, the row simply not there - is where it
    // belongs the moment the row comes back, rather than crossing it on the
    // way in. The same guard the sidebar's bar has for fullscreen, which hides
    // the panel outright while the page behind it goes on changing.
    //
    // The tab and the query are set in one turn with nothing rendered between
    // them, because a travel started behind the hidden row has 140ms to finish
    // in: let a frame pass first and the bug walks straight through.
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
    //
    // Collection's chips used to do what Search's did: the one being left
    // faded back to the resting surface while the one arriving faded up to the
    // accent. Both halves of that are a highlight that is briefly nowhere, and
    // nothing ever crosses the gap between the two chips.
    //
    // It is one accent pill now and it moves between them, which is the same
    // thing the sidebar's bar does and on the same 140ms. Drawn as a slice
    // inside each chip rather than as the one item Search's row can afford,
    // because a Flow lays out anything added to it; the pair of cases below is
    // otherwise the pair above, asked of the other page.
    //
    // That changes what the ink has to answer, and makes it a stronger answer
    // rather than a weaker one. The fading chip could not fade its label - the
    // two inks are luminance-inverted against the two fills on the three light
    // palettes - so the ink stepped at the fill's halfway point and took one
    // frame at 2.1:1. A travelling fill cannot step at all: whichever ink a
    // half-covered label picked, half of its glyphs would be on the wrong fill
    // for as long as the pill's edge took to cross them, which is far longer
    // than a frame. So the label is drawn twice, each copy clipped to its own
    // fill, and what is asserted below is that no accent ink is ever drawn
    // anywhere but on the accent - at every phase of the travel, not just at
    // the two ends.

    function chipOf(tabs, i) { return tabs.children[i] }

    // The pill as it is actually drawn, in the row's coordinates.
    //
    // Read back out of a chip's slice and not off the row's own markX/markW:
    // every chip holds the whole pill and shows the part of it over itself, so
    // the slice is the thing on screen, and a lag put between the row's numbers
    // and the slice would not show in the row's numbers. The window the slice
    // sits in starts 2px outside the chip, which is where that 2 comes from.
    // Probed - against the version that read the row's numbers, a Behavior on
    // the slice's x passed every case here.
    function drawnPill(tabs) {
        var chip = chipOf(tabs, 0)
        if (!chip) return null
        var slice = findByName(chip, "collectionTabPillSlice")
        if (!slice) return null
        return { x: chip.x + slice.x - 2, y: chip.y + slice.y - 2,
                 w: slice.width, h: slice.height }
    }

    // Is the pill exactly on this chip? Both are in the row's coordinates.
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

    // "" when every chip's accent-ink copy is inside the pill and every chip's
    // own label is still the resting ink, or what was wrong with the first one
    // that was not. Both are the same question asked of the two layers: the ink
    // on screen at any pixel is the one its fill was chosen for.
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

        // The chips no longer carry the highlight themselves - if one of them
        // still filled, everything below could pass with two highlights on
        // screen at once.
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
            // Every sample, not one: "no intermediate position" is a claim
            // about all of them.
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

        // The ink again, this time sampled through a whole travel rather than
        // at its ends: a half-covered label is exactly the state a stepped ink
        // gets wrong, and it only exists in the middle.
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

    // Opened on a tab that is not the first: the pill is there, not on its way
    // there. Same rule as the sidebar's bar, and the one a lerp between two
    // live boxes gets wrong by sliding out of the row's left edge.
    function test_collection_tab_pill_starts_where_it_belongs() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 760 })
        var page = createTemporaryObject(collectionC, holder, { activeTab: 2 })
        verify(page, "CollectionPage was not created")

        var tabs = findByName(page, "collectionTabsRow")
        verify(tabs, "the collection tab row was not found")

        // From before the first frame. The early readings are taken before the
        // Flow has placed anything, when every chip is at 0 and the pill agrees
        // with all of them - so the end of this checks that they did get placed
        // and that the pill is on the right one.
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
