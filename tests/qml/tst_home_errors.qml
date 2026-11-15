// HomePage when a fetch fails. "My Mixes" never stands over nothing: a failed
// mixes row says it could not load and offers a retry. The other rows hide
// while empty. The bridge stub is from tests/TestStubs.h.

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "HomeErrors"
    when: windowShown
    width: 1100
    height: 1000
    visible: true

    Component { id: holderC; Item { } }
    Component { id: homeC;   HomePage { anchors.fill: parent } }

    function init() { bridge.resetForTest() }
    function cleanup() { bridge.resetForTest() }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function makeHome() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1000, height: 900 })
        var page = createTemporaryObject(homeC, holder, {})
        verify(page, "HomePage was not created")
        frame(holder)
        wait(1)
        return page
    }

    // Every visible text, for "is this heading on screen at all".
    function visibleTexts(item, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || !c.visible) continue
            if (typeof c.text === "string" && c.font !== undefined) out.push(c.text)
            visibleTexts(c, out)
        }
        return out
    }

    function mixes(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: "mix" + i, title: "Ein Mix " + i, subtitle: "", coverUrl: "", mixType: "" })
        return out
    }

    function test_failed_mixes_say_so_with_a_retry() {
        bridge.setHomeMixesForTest([], "Host api.tidal.com not found")
        var page = makeHome()
        var failed = findChild(page, "homeMixesFailed")
        verify(failed && failed.visible, "a failed mixes fetch said nothing")
        compare(visibleTexts(page, []).filter(function (t) { return t === "View all" }).length, 0,
                "View all stands over an empty row")

        bridge.setHomeMixesForTest(mixes(3))
        var before = bridge.homeMixesFetchesForTest()
        mouseClick(findChild(page, "homeMixesRetry"))
        compare(bridge.homeMixesFetchesForTest(), before + 1, "the retry asked nothing")
        frame(page)
        compare(page.mixes.length, 3)
        verify(!failed.visible, "the failure stayed up after the retry worked")
    }

    function test_no_mixes_and_no_error_shows_no_empty_row() {
        var page = makeHome()
        compare(visibleTexts(page, []).indexOf("My Mixes"), -1,
                "\"My Mixes\" stands over nothing")
    }

}
