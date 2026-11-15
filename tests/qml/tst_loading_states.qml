// Loading is not empty. An empty state ("Nothing saved yet", "No mixes",
// "No saved albums") may only show once its data has arrived and really is
// empty, and a count the page does not know yet is not shown as zero.
// The stubs hold each source in its loading state until the case lets go.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "LoadingStates"
    when: windowShown
    visible: true
    width: 1280
    height: 800

    readonly property int settleMs: 2000

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        bridge.resetForTest()
        bridge.setUserPlaylistsForTest([])
        bridge.setFavoriteAlbumsForTest([])
        bridge.setFavoriteArtistsForTest([])
        bridge.setFavoriteTracksListForTest([])
        library.setEntriesForTest([])
        library.setLoadingForTest(false)
        pins.setItemsForTest([])
    }

    function cleanup() {
        bridge.resetForTest()
        library.setLoadingForTest(false)
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function settle(item) {
        wait(1)
        frame(item)
    }

    // Every visible Text whose string contains `needle`. `visible` is the
    // effective value, so text inside a hidden parent is left out.
    function visibleTextsSaying(item, needle) {
        var out = []
        function walk(it) {
            var kids = it.children
            for (var i = 0; i < kids.length; ++i) {
                var c = kids[i]
                if (!c || typeof c.width !== "number" || c.visible === false) continue
                if (typeof c.text === "string" && c.text.indexOf(needle) >= 0) out.push(c)
                walk(c)
            }
        }
        walk(item)
        return out
    }

    function says(item, needle) { return visibleTextsSaying(item, needle).length > 0 }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: appHost;     Main { } }

    Component {
        id: pageHost
        Window {
            property alias pane: pane
            function navigate(page, params) {}
            function goBack() {}
            width: 1200
            height: 900
            Item { id: pane; anchors.fill: parent }
        }
    }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }

    function makeCollection(tab) {
        var holder = createTemporaryObject(holderC, testCase, { width: 1280, height: 760 })
        verify(holder, "the holder was not created")
        var page = createTemporaryObject(collectionC, holder, { activeTab: tab })
        verify(page, "the collection page was not created")
        settle(page)
        return page
    }

    // ── the sidebar ──────────────────────────────────────────────────────

    function test_the_sidebar_says_nothing_is_saved_only_once_it_knows() {
        library.setLoadingForTest(true)
        var win = createTemporaryObject(appHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        settle(win.contentItem)

        verify(!says(win.contentItem, "Nothing saved yet"),
               "the sidebar said \"Nothing saved yet\" while the library was loading")

        library.setLoadingForTest(false)
        settle(win.contentItem)
        verify(says(win.contentItem, "Nothing saved yet"),
               "an empty library never said so once it had loaded")
    }
}
