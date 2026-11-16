// CollectionPage's field, its tabs and its empty states. A filter that matches
// nothing says so, and does not claim the library is empty. The Mixes tab
// filters too. A tab switch keeps each tab's rows and scroll. A list that
// never loaded says that, with a retry. The bridge stub is from tests/TestStubs.h.

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

    function test_a_filter_with_no_match_says_nothing_matches_data() {
        return [
            { tag: "tracks", tab: 0, empty: "No saved tracks" },
            { tag: "albums", tab: 1, empty: "No saved albums" },
            { tag: "artists", tab: 2, empty: "No followed artists" },
            { tag: "playlists", tab: 3, empty: "No playlists yet" },
        ]
    }

    function test_a_filter_with_no_match_says_nothing_matches(row) {
        bridge.setFavoriteTracksListForTest(makeTracks(3))
        bridge.setFavoriteAlbumsForTest([{ id: 5, title: "Ein Album", artists: "Eine Band", coverUrl: "" }])
        bridge.setFavoriteArtistsForTest([{ id: 3, name: "Eine Band", coverUrl: "" }])
        var page = makeCollection(row.tab)
        typeFilter(page, "xyzzy")
        verify(!anyVisibleText(page, row.empty),
               "a filter with no match claimed the " + row.tag + " are empty")
        var said = shownText(page, "collectionNoMatchesText")
        verify(said.indexOf("xyzzy") !== -1, "the page did not say nothing matches: '" + said + "'")
    }

    function test_the_mixes_tab_filters_its_grid_and_its_count() {
        bridge.setHomeMixesForTest([
            { id: "m1", title: "Morgenmix", subtitle: "Eine Band", coverUrl: "", mixType: "" },
            { id: "m2", title: "Abendmix",  subtitle: "Andere",    coverUrl: "", mixType: "" },
        ])
        var page = makeCollection(4)
        compare(page.filteredMixes.length, 2)
        typeFilter(page, "abend")
        compare(page.filteredMixes.length, 1, "the field did nothing on the Mixes tab")
        compare(findChild(page, "collectionMixesGrid").count, 1, "the grid was not filtered")
        var labels = []
        var row = findChild(page, "collectionTabsRow")
        verify(row)
        verify(row.children.length > 0)
        var found = false
        for (var i = 0; i < row.children.length; ++i) {
            var l = findChild(row.children[i], "collectionTabLabel")
            if (l && l.text.indexOf("Mixes") === 0) { found = true; compare(l.text, "Mixes (1)") }
        }
        verify(found, "no Mixes tab label")
        typeFilter(page, "xyzzy")
        verify(shownText(page, "collectionNoMatchesText").indexOf("xyzzy") !== -1,
               "the Mixes tab did not say nothing matches")
        verify(!anyVisibleText(page, "No mixes"), "a filter miss claimed there are no mixes")
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

    function test_a_list_that_never_loaded_is_not_called_empty() {
        bridge.setUnloadedKindsForTest(["tracks", "albums", "artists", "playlists"])
        var page = makeCollection(0)
        verify(!anyVisibleText(page, "No saved tracks"), "an unloaded library was called empty")
        compare(shownText(page, "collectionUnavailableText"), "Your collection could not be loaded")
        var retry = findChild(page, "collectionUnavailableRetry")
        verify(retry && retry.visible, "no retry")
        mouseClick(retry)
        compare(bridge.retryConnectionCallsForTest(), 1, "the retry asked nothing")
    }

    function test_mixes_that_failed_say_so_and_load_again_once_online() {
        bridge.setHomeMixesForTest([], "Host api.tidal.com not found")
        var page = makeCollection(4)
        verify(!anyVisibleText(page, "No mixes"), "failed mixes were called none")
        compare(shownText(page, "collectionUnavailableText"), "Mixes could not be loaded")
        bridge.setHomeMixesForTest([{ id: "m1", title: "Morgenmix", subtitle: "", coverUrl: "", mixType: "" }])
        bridge.setOfflineForTest(true)
        bridge.setOfflineForTest(false)
        frame(page)
        compare(page.mixes.length, 1, "the mixes did not load again once Tidal answered")
        compare(shownText(page, "collectionUnavailableText"), "")
    }
}
