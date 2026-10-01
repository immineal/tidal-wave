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

    // ── a hover fill ─────────────────────────────────────────────────────

    function test_hover_fill_data() { return test_rail_expansion_data() }

    function test_hover_fill(row) {
        app.setReducedMotionForTest(row.reduced)

        var btn = createTemporaryObject(backButtonC, testCase, { x: 40, y: 40 })
        verify(btn, "the back button was not created")

        mouseMove(testCase, 600, 600)
        tryVerify(function () { return sameColor(btn.color, Theme.artScrim) },
                  settleMs, "the button never settled on its resting fill")

        mouseMove(testCase, 58, 58)
        oneFrame()

        if (row.reduced) {
            verify(sameColor(btn.color, Theme.artScrimStrong),
                   "reduced motion: the hover fill must be there on the next frame, got "
                   + btn.color)
        } else {
            verify(!sameColor(btn.color, Theme.artScrimStrong),
                   "without reduced motion the hover fill jumped instead of fading")
            tryVerify(function () { return sameColor(btn.color, Theme.artScrimStrong) },
                      settleMs, "the hover fade never finished")
        }

        mouseMove(testCase, 600, 600)
        tryVerify(function () { return sameColor(btn.color, Theme.artScrim) },
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
}
