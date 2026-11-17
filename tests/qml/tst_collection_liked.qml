// Collection's tab labels and Liked tracks' buttons. A tab whose list is
// still on its way says no count rather than "(0)", and Liked tracks has
// Shuffle and no Play. Every title is invented.

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

    // Shuffle alone, with no Play beside it.
    function test_liked_tracks_offers_shuffle_and_no_play() {
        bridge.setFavoriteTracksListForTest(tracks())
        var page = makeCollection()
        var play = findChild(page, "collectionPlayButton")
        verify(!play || !play.visible, "Liked tracks offers a Play beside Shuffle")
        var shuffle = findChild(page, "collectionSurpriseButton")
        verify(shuffle && shuffle.visible, "Liked tracks has no Shuffle")
        compare(shuffle.text, qsTranslate("AlbumPage", "Shuffle"))
        mouseClick(shuffle)
        compare(player.queueTracks.length, 3, "Shuffle did not play the liked tracks")
        compare(player.shuffle, true, "Shuffle did not turn shuffle on")
        compare(player.sourceType, "collection")
    }
}
