// CollectionPage's tabs. A tab switch keeps each tab's rows and scroll. The
// bridge stub is from tests/TestStubs.h.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CollectionFilter"
    when: windowShown
    width: 1000
    height: 800
    visible: true

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function init() {
        bridge.resetForTest()
        bridge.setFavoriteTracksListForTest([])
        bridge.setFavoriteAlbumsForTest([])
        bridge.setFavoriteArtistsForTest([])
    }

    function cleanup() {
        bridge.resetForTest()
        bridge.setFavoriteTracksListForTest([])
    }

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 61000 + i, title: "Lied " + (i + 1), artists: "Eine Band",
                       albumTitle: "Ein Album", durationStr: "3:21", coverUrl: "",
                       coverUrl80: "", albumId: 11, artistId: 3 })
        return out
    }

    function makeCollection(tab) {
        var holder = createTemporaryObject(holderC, testCase)
        holder.width = 1280
        holder.height = 760
        var page = createTemporaryObject(collectionC, holder, {})
        verify(page, "the collection page was not created")
        page.activeTab = tab
        frame(page)
        wait(1)
        return page
    }

    function typeFilter(page, text) {
        page.searchPattern = text
        page.updateFilteredContent()
        frame(page)
        wait(1)
    }

    function shownText(page, objName) {
        var t = findChild(page, objName)
        return t && t.visible ? t.text : ""
    }

    function anyVisibleText(item, wanted) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || !c.visible) continue
            if (typeof c.text === "string" && c.text === wanted) return true
            if (anyVisibleText(c, wanted)) return true
        }
        return false
    }




    function test_a_tab_switch_keeps_the_scroll_position() {
        bridge.setFavoriteTracksListForTest(makeTracks(300))
        var page = makeCollection(0)
        var list = findChild(page, "collectionTracksList")
        verify(list.contentHeight > list.height + 3000, "the fixture does not scroll")
        list.contentY = 3000
        frame(page)
        page.activeTab = 1
        frame(page)
        page.activeTab = 0
        frame(page)
        compare(list.contentY, 3000, "coming back to Tracks started at the top")
        compare(list.count, 300)
    }


}
