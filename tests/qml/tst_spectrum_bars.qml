// The five now-playing bars, on the live path and back off it again.
//
// tests/tst_spectrum.cpp owns the DSP: what comes out of a buffer, in what
// formats, at what rate. What it cannot reach is the half the user actually
// sees - whether the bars take their heights from the analyser at all,
// whether they let go of them afterwards, and whether the preference being
// off really leaves the old behaviour untouched rather than merely looking
// like it does.
//
// So every case here is about the indicator and not about the spectrum:
//
//   * with nothing playing through the analyser the bars animate, exactly as
//     they did before this feature existed;
//   * driven, they line up with the levels - the lit band is the tall bar,
//     and a band at zero still draws something rather than vanishing;
//   * released, they go back to animating, and a paused indicator parks on
//     its resting skyline instead of staying frozen on the last spectrum;
//   * reduced motion outranks the spectrum, because a live spectrogram is
//     continuous movement and that preference is asking for less of it.
//
// Spectrum.setLevelsForTest()/stopForTest() are the only way in: the real
// path needs a QMediaPlayer, an audio device and a Tidal stream. They are
// also the reason cleanup() exists - the analyser is a process-wide
// singleton, so a case that left it driven would hand the next file in
// tst_qml five frozen bars.

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "SpectrumBars"
    when: windowShown
    visible: true
    width: 400
    height: 300

    // PlayingIndicator's own floor: a band at zero is still drawn, at this
    // fraction of the box. Repeated rather than read off the component, so
    // changing it there is a failure here instead of a tautology.
    readonly property real minFrac: 0.12

    // The Behavior on the live path, plus room for a slow box.
    readonly property int settleMs: 1500

    function init() {
        app.setReducedMotionForTest(false)
        Spectrum.stopForTest()
    }

    function cleanup() {
        Spectrum.stopForTest()
        app.setReducedMotionForTest(false)
    }

    Component {
        id: indicatorC
        Item {
            width: 80; height: 70
            property alias indicator: ind
            VectorIcon.PlayingIndicator {
                id: ind
                anchors.centerIn: parent
                // Deliberately large: the real sites draw this at 14-16px,
                // where a 12% floor is under two pixels and the assertions
                // below would be measuring rounding.
                width: 64; height: 56
            }
        }
    }

    // The five Rectangles, left to right. Walks rather than indexes, because
    // the Repeater sits inside a Row inside the indicator and the delegate's
    // own structure is not this file's business.
    function bars(ind) {
        var out = []
        function walk(item) {
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) {
                var c = kids[i]
                if (typeof c.radius === "number" && c.children.length === 0)
                    out.push(c)
                else
                    walk(c)
            }
        }
        walk(ind)
        return out
    }

    function heights(ind) {
        var bs = bars(ind)
        var out = []
        for (var i = 0; i < bs.length; ++i) out.push(bs[i].height)
        return out
    }

    // ── off ────────────────────────────────────────────────────────────────

    // The shipped state. Nothing is driving the analyser, so the indicator is
    // the same object it has always been: five bars on their own schedule.
    function test_untouched_when_nothing_is_driving_it() {
        var host = createTemporaryObject(indicatorC, testCase)
        verify(host)
        var ind = host.indicator

        verify(!Spectrum.active)
        verify(!ind.useSpectrum)
        compare(bars(ind).length, 5)

        // Moving, which is the whole of the old behaviour.
        var first = heights(ind)
        var moved = false
        tryVerify(function () {
            var now = heights(ind)
            for (var i = 0; i < now.length; ++i)
                if (Math.abs(now[i] - first[i]) > 0.5) moved = true
            return moved
        }, settleMs, "the bars never moved with the spectrum off")
    }

    // ── on ─────────────────────────────────────────────────────────────────

    // One band lit. The bar for that band goes to the top of the box and the
    // other four sit on the floor - which is a floor, not zero.
    function test_bars_follow_the_levels() {
        var host = createTemporaryObject(indicatorC, testCase)
        verify(host)
        var ind = host.indicator

        Spectrum.setLevelsForTest([0, 0, 1, 0, 0])
        verify(Spectrum.active)
        verify(ind.useSpectrum)

        var box = ind.height
        tryVerify(function () { return heights(ind)[2] > box * 0.9 }, settleMs,
                  "the lit band never reached the top of the box")

        var hs = heights(ind)
        for (var i = 0; i < hs.length; ++i) {
            if (i === 2) continue
            verify(hs[i] > 0,
                   "band " + i + " vanished instead of parking on the floor")
            fuzzyCompare(hs[i], box * minFrac, box * 0.03,
                         "band " + i + " is not on the floor")
        }
    }

    // Middling levels land in order, so the bars are a meter and not a row of
    // on/off lights.
    function test_bars_are_ordered_by_level() {
        var host = createTemporaryObject(indicatorC, testCase)
        verify(host)
        var ind = host.indicator

        Spectrum.setLevelsForTest([0.1, 0.3, 0.5, 0.7, 0.9])
        tryVerify(function () {
            var hs = heights(ind)
            for (var i = 1; i < hs.length; ++i)
                if (hs[i] <= hs[i - 1]) return false
            return true
        }, settleMs, "the bar heights do not increase with the levels")
    }

    // The animation has to be off while the spectrum drives, or the two write
    // the same property from both ends and the bars jitter.
    function test_the_animation_stands_down() {
        var host = createTemporaryObject(indicatorC, testCase)
        verify(host)
        var ind = host.indicator

        Spectrum.setLevelsForTest([0, 0, 1, 0, 0])
        tryVerify(function () { return heights(ind)[0] < ind.height * 0.2 },
                  settleMs, "the floor was never reached")

        // Held: nothing else is writing these.
        var before = heights(ind)
        wait(260)
        var after = heights(ind)
        for (var i = 0; i < before.length; ++i)
            fuzzyCompare(after[i], before[i], 0.5,
                         "band " + i + " moved while the levels were still")
    }

    // ── back off ───────────────────────────────────────────────────────────

    // Releasing the bars has to hand them back to their own animation rather
    // than leave them on the last spectrum.
    function test_bars_resume_animating_when_released() {
        var host = createTemporaryObject(indicatorC, testCase)
        verify(host)
        var ind = host.indicator

        Spectrum.setLevelsForTest([0, 0, 1, 0, 0])
        tryVerify(function () { return heights(ind)[2] > ind.height * 0.9 },
                  settleMs)

        Spectrum.stopForTest()
        verify(!ind.useSpectrum)

        var first = heights(ind)
        var moved = false
        tryVerify(function () {
            var now = heights(ind)
            for (var i = 0; i < now.length; ++i)
                if (Math.abs(now[i] - first[i]) > 0.5) moved = true
            return moved
        }, settleMs, "the bars stayed frozen on the last spectrum")
    }

    // A paused row has no animation to put the bars back, so the release has
    // to do it. Parked on the resting skyline, not on the floor and not on
    // whatever the spectrum last said.
    function test_a_paused_indicator_parks_on_release() {
        var host = createTemporaryObject(indicatorC, testCase)
        verify(host)
        var ind = host.indicator
        ind.animate = false

        Spectrum.setLevelsForTest([1, 1, 1, 1, 1])
        tryVerify(function () { return heights(ind)[0] > ind.height * 0.9 },
                  settleMs, "the driven bars never filled the box")

        Spectrum.stopForTest()
        tryVerify(function () {
            var hs = heights(ind)
            // The resting fractions written down in VectorIcon.qml.
            var rest = [0.45, 0.80, 0.30, 0.65, 0.50]
            for (var i = 0; i < hs.length; ++i)
                if (Math.abs(hs[i] - ind.height * rest[i]) > 1.0) return false
            return true
        }, settleMs, "a paused indicator did not park on its resting skyline")
    }

    // ── reduced motion ─────────────────────────────────────────────────────

    // A spectrogram is continuous movement. Whatever the analyser is doing,
    // the bars stand still when the desktop has asked them to.
    function test_reduced_motion_outranks_the_spectrum() {
        app.setReducedMotionForTest(true)
        var host = createTemporaryObject(indicatorC, testCase)
        verify(host)
        var ind = host.indicator

        Spectrum.setLevelsForTest([0, 0, 1, 0, 0])
        verify(Spectrum.active)
        verify(!ind.useSpectrum)

        // Parked on the resting skyline, which is what reduced motion has
        // always left behind here.
        var rest = [0.45, 0.80, 0.30, 0.65, 0.50]
        tryVerify(function () {
            var hs = heights(ind)
            for (var i = 0; i < hs.length; ++i)
                if (Math.abs(hs[i] - ind.height * rest[i]) > 1.0) return false
            return true
        }, settleMs, "reduced motion did not park the bars")
    }
}
