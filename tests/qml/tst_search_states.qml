// SearchPage: each filter chip starts at its top. The bridge stub is from
// tests/TestStubs.h.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "SearchStates"
    when: windowShown
    visible: true
    width: 1280
    height: 800

    readonly property int settleMs: 2000

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
    }

    function cleanup() {
        app.setReducedMotionForTest(false)
        bridge.resetForTest()
    }

    function fakeTracks(n) {
        var out = []
        for (var i = 1; i <= n; ++i)
            out.push({ id: 9000 + i, title: "Erfundenes Lied " + i, artists: "Beispielkapelle",
                       artistId: 7001, artistList: [{ id: 7001, name: "Beispielkapelle" }],
                       albumTitle: "Erfundenes Album", albumId: 8001, coverUrl: "",
                       coverUrl80: "", duration: 200, durationStr: "3:20" })
        return out
    }

    function fakeAlbums(n) {
        var out = []
        for (var i = 1; i <= n; ++i)
            out.push({ id: 8000 + i, title: "Erfundenes Album " + i,
                       artists: "Beispielkapelle", coverUrl: "" })
        return out
    }

    Component {
        id: pageHost
        Window {
            width: 1100; height: 760
            function navigate(page, params) {}
            function goBack() {}
            property alias page: sp
            SearchPage { id: sp; anchors.fill: parent }
        }
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function showPage() {
        var win = createTemporaryObject(pageHost, testCase)
        verify(win, "the search page host was not created")
        win.visible = true
        frame(win.contentItem)
        return win
    }

    function search(win, q) {
        findChild(win.page, "searchPageBar").text = q
        tryVerify(function () { return win.page.repliedFor === q }, settleMs,
                  "no reply for \"" + q + "\" ever landed")
        frame(win.contentItem)
    }

    function test_each_chip_starts_at_the_top() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(20), fakeAlbums(20), [], [])
        search(win, "erfunden")
        win.page.activeTab = 1
        frame(win.contentItem)
        var flick = findChild(win.page, "searchScroll").contentItem
        verify(flick.contentHeight > flick.height + 300, "the fixture does not scroll")
        flick.contentY = 300
        frame(win.contentItem)
        win.page.activeTab = 2
        frame(win.contentItem)
        compare(flick.contentY, 0, "the Albums chip opened at the Tracks chip's scroll")
    }

}
