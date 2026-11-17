// Collection's tab labels and Liked tracks' buttons. A tab whose list is
// still on its way says no count rather than "(0)", and Liked tracks has a
// Play beside Shuffle, as a playlist has. Every title is invented.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CollectionLiked"
    when: windowShown
    visible: true
    width: 1300
    height: 800

    Component { id: holderC; Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        player.setShuffle(false)
    }
    function cleanup() {
        bridge.setFavoriteTracksListForTest([])
        bridge.setKindLoadingForTest("tracks", false)
        bridge.setKindLoadingForTest("albums", false)
    }

    function tracks() {
        return [
            { id: 21, title: "Erstes", artists: "A", albumTitle: "X", albumId: 5, duration: 100 },
            { id: 22, title: "Zweites", artists: "A", albumTitle: "X", albumId: 5, duration: 100 },
            { id: 23, title: "Drittes", artists: "A", albumTitle: "X", albumId: 5, duration: 100 }
        ]
    }

    function makeCollection() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1280, height: 760 })
        var page = createTemporaryObject(collectionC, holder, {})
        verify(page)
        waitForRendering(page)
        return page
    }

    function tabLabels(page) {
        var out = []
        function walk(it) {
            if (!it) return
            if (it.objectName === "collectionTabLabel") out.push(it.text)
            for (var i = 0; i < it.children.length; i++) walk(it.children[i])
        }
        walk(page)
        return out
    }

    function test_a_loading_tab_says_no_count() {
        bridge.setKindLoadingForTest("tracks", true)
        bridge.setKindLoadingForTest("albums", true)
        var page = makeCollection()
        var labels = tabLabels(page)
        verify(labels.length >= 5, "no tab labels found: " + labels)
        compare(labels[0], "Tracks", "a list on its way reads as an empty one")
        compare(labels[1], "Albums")
        verify(labels[2].indexOf("(0)") > 0, "a loaded empty tab lost its count")
        bridge.setFavoriteTracksListForTest(tracks())
        bridge.setKindLoadingForTest("tracks", false)
        compare(tabLabels(page)[0], "Tracks (3)")
    }

    function test_rows_on_hand_are_counted_while_more_load() {
        bridge.setFavoriteTracksListForTest(tracks())
        bridge.setKindLoadingForTest("tracks", true)
        var page = makeCollection()
        compare(tabLabels(page)[0], "Tracks (3)")
    }

    function test_liked_tracks_has_play_beside_shuffle() {
        bridge.setFavoriteTracksListForTest(tracks())
        var page = makeCollection()
        var play = findChild(page, "collectionPlayButton")
        var shuffle = findChild(page, "collectionSurpriseButton")
        verify(play && play.visible, "Liked tracks has no Play")
        verify(play.accent, "Play is not the page's filled pill")
        verify(play.x < shuffle.x, "Play is not before Shuffle")
        mouseClick(play)
        compare(player.queueTracks.map(function (t) { return t.title }).join(","),
                "Erstes,Zweites,Drittes")
        compare(player.queueIndex, 0, "Play did not start at the top")
        compare(player.shuffle, false, "Play turned shuffle on")
        compare(player.sourceType, "collection")
    }

    function test_the_other_tabs_have_no_play() {
        var page = makeCollection()
        page.activeTab = 1
        var play = findChild(page, "collectionPlayButton")
        verify(!play || !play.visible, "an album grid offers to play the tab")
    }
}
