// X6: animations stay smooth, and a reduced-motion preference is respected
// where the platform exposes one.
//
// Read the numbers this prints with the caveat attached. Frame timing measured
// here is the throughput of whatever backend the run was given: offscreen
// renders with no presentation at all, Xvfb rasterises on the CPU through
// llvmpipe, and a nested compositor adds a copy. None of that predicts frame
// pacing on the developer's GPU. What it does catch is the thing worth
// catching in a test: an animation that produces no frames, one that produces
// far fewer than its neighbours, and a frame rate that collapses when the
// scene gets big. Anything beyond that needs a real display and a real
// present loop, and this file says so rather than asserting it is fine.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

import "StressLib.js" as S

TestCase {
    id: testCase
    name: "StressMotion"
    when: windowShown
    visible: true
    width: 1280
    height: 900

    readonly property real scale: S.scale()
    readonly property int bucketMs: 100
    readonly property int bucketsPerRun: Math.max(10, Math.round(30 * scale))

    SignalSpy { id: frameSpy; signalName: "frameSwapped" }

    Component {
        id: spinnerC
        Item {
            width: 200; height: 200
            Rectangle {
                id: box
                anchors.centerIn: parent
                width: 120; height: 120
                color: Theme.accent
                radius: Theme.r.card
                NumberAnimation on rotation {
                    running: true; loops: Animation.Infinite
                    from: 0; to: 360; duration: 2000
                }
                NumberAnimation on opacity {
                    running: true; loops: Animation.Infinite
                    from: 0.3; to: 1.0; duration: 700; easing.type: Easing.InOutQuad
                }
            }
        }
    }

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: loginC;      LoginPage      { anchors.fill: parent } }

    function findByName(item, name) {
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }
    // A real animated component for the reduced-motion probe. The login
    // card's height is the one animation in the app that can be driven
    // without a pointer: the auth state alone decides it. The sidebar's
    // slide would do as well, but it carries an asynchronous Loader that is
    // still incubating when the engine tears down.

    function window() {
        return testCase.Window.window
    }

    // Counts frames in `bucketMs` slices and returns the per-second rate of
    // each slice, so pacing can be looked at and not just the average.
    function sampleFps(buckets) {
        var win = window()
        frameSpy.target = win
        frameSpy.clear()

        var out = []
        for (var i = 0; i < buckets; ++i) {
            var before = frameSpy.count
            var t0 = Date.now()
            wait(bucketMs)
            var dt = Math.max(1, Date.now() - t0)
            out.push((frameSpy.count - before) * 1000.0 / dt)
        }
        frameSpy.target = null
        return out
    }

    function median(a) {
        var s = a.slice().sort(function (x, y) { return x - y })
        var n = s.length
        if (n === 0) return 0
        return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    function report(label, fps) {
        var med = median(fps)
        var lo = Math.min.apply(null, fps)
        var hi = Math.max.apply(null, fps)
        var starved = 0
        for (var i = 0; i < fps.length; ++i)
            if (fps[i] < med * 0.5) ++starved
        console.log("[stress] motion " + label + ": median " + med.toFixed(1)
                    + " fps, min " + lo.toFixed(1) + ", max " + hi.toFixed(1)
                    + ", " + starved + "/" + fps.length
                    + " slices under half the median")
        return { med: med, lo: lo, hi: hi, starved: starved }
    }

    function test_frame_timing_is_measurable_at_all() {
        var win = window()
        if (!win) { skip("the test case has no window, so nothing can be measured"); return }

        var holder = createTemporaryObject(holderC, testCase, { width: 400, height: 300 })
        var spinner = createTemporaryObject(spinnerC, holder, {})
        verify(spinner, "the spinner was not created")
        waitForRendering(holder, 10000)

        var fps = sampleFps(bucketsPerRun)
        var r = report("idle animation", fps)

        console.log("[stress] motion: platform \"" + Qt.platform.os
                    + "\", scene graph frames are what this counts; the number is"
                    + " backend throughput, not pacing on a real display")

        // The only honest hard assertion: the animation produced frames.
        verify(r.hi > 0,
               "no frame was ever swapped while an infinite animation ran, "
               + "so either the animation is not running or nothing is rendering")
    }

    // The same animation with a real page and a long list behind it. A sharp
    // drop against the idle number is the finding; the absolute value is not.
    function test_frame_timing_under_a_loaded_scene() {
        var win = window()
        if (!win) { skip("the test case has no window, so nothing can be measured"); return }

        var holder = createTemporaryObject(holderC, testCase, { width: 1200, height: 820 })
        var page = collectionC.createObject(holder, {})
        S.fill(page, { activeTab: 0 })
        S.fill(page, { filteredTracks: S.tracks(2000) })
        var spinner = createTemporaryObject(spinnerC, holder, {})
        waitForRendering(holder, 60000)

        var idle = report("loaded scene, list still", sampleFps(bucketsPerRun))

        // Now scroll the list under the animation: new delegates every frame.
        var view = null
        function find(item) {
            if (item.count === 2000 && item.contentY !== undefined) return item
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) {
                var hit = find(kids[i])
                if (hit) return hit
            }
            return null
        }
        view = find(page)
        if (!view) {
            console.log("[stress] motion: no 2000 item view was found, skipping the scroll pass")
            page.destroy()
            return
        }

        frameSpy.target = win
        frameSpy.clear()
        var scrollFps = []
        var maxY = Math.max(1, view.contentHeight - view.height)
        for (var i = 0; i < bucketsPerRun; ++i) {
            var before = frameSpy.count
            var t0 = Date.now()
            var deadline = t0 + bucketMs
            while (Date.now() < deadline) {
                view.contentY = (view.contentY + 37) % maxY
                wait(0)
            }
            var dt = Math.max(1, Date.now() - t0)
            scrollFps.push((frameSpy.count - before) * 1000.0 / dt)
        }
        frameSpy.target = null
        var scrolling = report("loaded scene, scrolling", scrollFps)

        if (idle.med > 0 && scrolling.med > 0)
            console.log("[stress] motion: scrolling costs "
                        + (100 * (1 - scrolling.med / idle.med)).toFixed(0)
                        + "% of the still frame rate")

        verify(scrolling.hi > 0, "scrolling a 2000 item list produced no frames at all")
        page.destroy()
    }

    // X6's second half, measured rather than guessed at.
    //
    // This used to read `prefs.reduceMotion`, which has never existed on
    // Prefs, so the probe reported "the app has no reduced-motion control"
    // whatever the app actually did — it could not have told the two apart.
    // The real property is Application::reducedMotion, reaching QML as
    // `app.reducedMotion`, and Theme.reduceMotion is where the QML side asks.
    // So the probe now drives the preference and watches a real animation.

    // Move the login card between its two heights and report how it got
    // there: instantly, or over the usual 200ms.
    function resizeCard(card, state, target) {
        auth.setStateForTest(state)
        wait(1)
        var afterOneFrame = card.height
        tryVerify(function () { return card.height === target },
                  5000, "the login card never reached " + target)
        return { afterOneFrame: afterOneFrame, settled: card.height }
    }

    function test_reduced_motion_preference() {
        var hints = Application.styleHints
        verify(hints, "QStyleHints is not reachable from QML")

        var names = []
        for (var k in hints) names.push(k)
        names.sort()

        var motionHints = []
        for (var i = 0; i < names.length; ++i) {
            var n = names[i].toLowerCase()
            if (n.indexOf("anim") >= 0 || n.indexOf("motion") >= 0 || n.indexOf("effect") >= 0)
                motionHints.push(names[i])
        }

        var hasControl = (typeof app !== "undefined" && app !== null
                          && app.reducedMotion !== undefined)

        console.log("[stress] motion: QStyleHints exposes " + names.length
                    + " hints; motion related: "
                    + (motionHints.length ? motionHints.join(", ") : "none"))
        console.log("[stress] motion: app.reducedMotion "
                    + (hasControl ? "exists, currently " + app.reducedMotion
                                  : "does not exist")
                    + "; Theme.reduceMotion reads " + Theme.reduceMotion)

        if (!hasControl) {
            console.log("[stress] motion: FINDING - the app exposes no reduced-motion "
                        + "control, so X6's second half is unimplemented")
            return
        }

        // 0 is LoggedOut, where the card is 220 high; 1 is PendingDevice, 400.
        // The stub starts with saved credentials, which is the 140px
        // "Restoring session" card instead.
        auth.setHasSavedCredentialsForTest(false)
        auth.setStateForTest(0)
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var page = createTemporaryObject(loginC, holder)
        verify(page, "LoginPage was not created")
        waitForRendering(holder, 10000)

        var card = findByName(page, "loginAuthCard")
        verify(card, "LoginPage has no auth card to measure")
        tryVerify(function () { return card.height === 220 },
                  5000, "the card never settled at its signed-out height")

        // Baseline: motion allowed, so the resize should take time.
        app.setReducedMotionForTest(false)
        var animated = resizeCard(card, 1, 400)
        var animatedTravelled = animated.afterOneFrame !== animated.settled
        resizeCard(card, 0, 220)

        // Now with the preference on. This half is deterministic: a
        // zero-length animation has written its target before the first frame.
        app.setReducedMotionForTest(true)
        compare(Theme.reduceMotion, true, "Theme ignored the preference")
        var reduced = resizeCard(card, 1, 400)
        app.setReducedMotionForTest(false)
        auth.setStateForTest(2)

        console.log("[stress] motion: the login card with motion allowed reached "
                    + animated.afterOneFrame + " after one frame and settled at "
                    + animated.settled + "; with reduced motion, "
                    + reduced.afterOneFrame + " then " + reduced.settled)

        compare(reduced.afterOneFrame, reduced.settled,
                "reduced motion is set and the login card still animated its height")

        // Not a hard failure: on a software rasteriser under load one turn of
        // the event loop can outlast a 170ms slide, which would make this
        // look instant when it is not. Worth saying out loud, not worth
        // failing a stress run over.
        if (!animatedTravelled)
            console.log("[stress] motion: NOTE - the resize looked instant even with "
                        + "motion allowed, so this box cannot tell the two apart; "
                        + "the reduced-motion half above is still meaningful")
    }
}
