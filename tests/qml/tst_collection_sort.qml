// The sort pills over the collection's first four tabs. A to Z and Z to A
// re-sort the tab's grid by title; Default is the order the bridge hands over,
// and its tooltip says what that order is on each tab.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CollectionSort"
    when: windowShown
    width: 1000
    height: 800
    // TestCase declares visible: false, and an invisible GridView makes no
    // delegates.
    visible: true

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }

    // Invented, and handed over in an order that is neither A to Z nor Z to A,
    // as the bridge's own recency order would be.
    function playlists() {
        return [
            { uuid: "p-m", title: "Mittagspause", description: "", coverUrl: "",
              numTracks: 3, duration: 600, type: "USER" },
            { uuid: "p-a", title: "Abendrot", description: "", coverUrl: "",
              numTracks: 5, duration: 900, type: "USER" },
            { uuid: "p-z", title: "Zugfahrt", description: "", coverUrl: "",
              numTracks: 8, duration: 1500, type: "USER" }
        ]
    }

    function init() {
        bridge.resetForTest()
        bridge.setUserPlaylistsForTest(playlists())
    }

    function cleanup() {
        bridge.setUserPlaylistsForTest([])
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function makeCollection(tab) {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = 1280
        holder.height = 760
        var page = createTemporaryObject(collectionC, holder, {})
        verify(page, "the collection page was not created")
        page.activeTab = tab
        frame(page)
        wait(1)
        return page
    }

    function titlesOf(grid) {
        var out = []
        for (var i = 0; i < grid.model.length; i++) out.push(grid.model[i].title)
        return out.join(",")
    }

    function test_the_playlist_grid_follows_the_sort_pills() {
        var page = makeCollection(3)
        var grid = findChild(page, "collectionPlaylistsGrid")
        verify(grid, "the playlists tab has no grid")

        compare(titlesOf(grid), "Mittagspause,Abendrot,Zugfahrt",
                "Default did not keep the order the library gave")
        page.sortMode = 1
        compare(titlesOf(grid), "Abendrot,Mittagspause,Zugfahrt",
                "A to Z left the playlists unsorted")
        page.sortMode = 2
        compare(titlesOf(grid), "Zugfahrt,Mittagspause,Abendrot",
                "Z to A left the playlists unsorted")
        page.sortMode = 0
        compare(titlesOf(grid), "Mittagspause,Abendrot,Zugfahrt",
                "Default did not bring the library's order back")
    }

    function test_default_says_what_order_it_is_data() {
        return [
            { tag: "tracks",    tab: 0 },
            { tag: "albums",    tab: 1 },
            { tag: "artists",   tab: 2 },
            { tag: "playlists", tab: 3 }
        ]
    }

    function test_default_says_what_order_it_is(data) {
        var page = makeCollection(data.tab)
        var pill = findChild(page, "collectionSortDefault")
        verify(pill, "there is no Default pill")
        verify(pill.hint.length > 0, "Default on the " + data.tag + " tab explains nothing")
        var others = []
        for (var t = 0; t < 4; t++) {
            if (t === data.tab) continue
            page.activeTab = t
            others.push(pill.hint)
        }
        page.activeTab = data.tab
        verify(others.indexOf(pill.hint) < 0,
               "Default on the " + data.tag + " tab reads like another tab's: " + pill.hint)
    }
}
