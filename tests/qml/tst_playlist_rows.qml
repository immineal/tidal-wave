// What a playlist's rows do while its headings sort them and its field
// narrows them: the numbers, what Play, Shuffle, a row and its menu play,
// what a removal takes, what a download gets, and where a reload leaves the
// list. Pinned before the rows moved to a C++ model, so the move keeps them.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "PlaylistRows"
    when: windowShown

    readonly property var names: ["Mittag", "abend", "Zug", "Bahn", "Café am Hafen", "Mittag"]

    function track(i) {
        return { id: 9400 + (i === 5 ? 0 : i), title: names[i], artists: i === 3 ? "Jürgen Beispiel" : "Erika Muster",
                 artistId: 11, artistList: [{ id: 11, name: "Erika Muster" }],
                 albumTitle: "Nachtfahrt", albumId: 7788, duration: 100 + 10 * i, durationStr: "1:40",
                 addedAt: 1000 * (i + 1), coverUrl: "cdn/" + (i % 3) + ".jpg", coverUrl80: "" }
    }
    function tracks() {
        var out = []
        for (var i = 0; i < names.length; ++i) out.push(track(i))
        return out
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        bridge.resetForTest()
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        player.setShuffle(false)
    }

    Component {
        id: hostC
        Window {
            width: 1280; height: 800
            function navigate(page, params) {}
            function goBack() {}
        }
    }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findByName(item.children[i], name)
            if (hit) return hit
        }
        return null
    }
    function findByText(item, text) {
        if (!item) return null
        if (item.text === text && item.clicked !== undefined) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findByText(item.children[i], text)
            if (hit) return hit
        }
        return null
    }

    function open() {
        var host = createTemporaryObject(hostC, testCase)
        host.visible = true
        bridge.setPlaylistTracksForTest(tracks())
        var page = createTemporaryObject(playlistC, host.contentItem,
                                         { playlistTitle: "Liste", playlistEditable: true })
        page.playlistUuid = "0c1d2e3f-aaaa-bbbb-cccc-000000000009"
        tryCompare(page, "loading", false)
        var list = findByName(page, "playlistTracksList")
        tryVerify(function () { return list.count === names.length }, 3000, "the playlist never filled")
        frame(host.contentItem)
        return { host: host, page: page, list: list }
    }

    // The rows drawn, top to bottom.
    function rows(s) {
        frame(s.host.contentItem)
        var out = []
        for (var i = 0; i < s.list.count; ++i) {
            var r = s.list.itemAtIndex(i)
            verify(r, "row " + i + " was not built")
            out.push(r)
        }
        return out
    }
    function titlesOf(list) {
        var out = []
        for (var i = 0; i < list.length; ++i) out.push(list[i].title)
        return out.join(",")
    }
    // The list's header holds the hero, then the headings.
    function hero(s) { return findByName(s.page, "playlistTracksHeader").parent.children[0] }
    function sortBy(s, key) {
        findByName(s.page, "playlistTracksHeader").sort.cycle(key)
        frame(s.host.contentItem)
    }
    function filterTo(s, text) {
        var field = findByName(s.page, "playlistFilter")
        field.text = text
        field.textEdited(text)
        frame(s.host.contentItem)
    }

    function test_rows_sorted_and_filtered_keep_their_place_on_the_playlist() {
        var s = open()
        sortBy(s, "title")
        filterTo(s, "g")
        var r = rows(s)
        compare(titlesOf(r), "Bahn,Mittag,Mittag,Zug")
        compare(r.map(function (x) { return x.trackNum }).join(","), "4,1,6,3")
        compare(r.map(function (x) { return x.trackItemIndex }).join(","), "3,0,5,2")
        // Every word in some field, in any order.
        filterTo(s, "hafen nacht")
        compare(titlesOf(rows(s)), "Café am Hafen")
        filterTo(s, "jurgen bahn")
        compare(titlesOf(rows(s)), "Bahn")
        filterTo(s, "  ")
        compare(rows(s).length, names.length, "spaces alone narrowed the list")
    }

    function test_descending_and_by_date_and_length() {
        var s = open()
        sortBy(s, "duration")
        compare(titlesOf(rows(s)), "Mittag,abend,Zug,Bahn,Café am Hafen,Mittag")
        sortBy(s, "duration")
        compare(titlesOf(rows(s)), "Mittag,Café am Hafen,Bahn,Zug,abend,Mittag")
        sortBy(s, "duration")
        sortBy(s, "added")
        sortBy(s, "added")
        compare(rows(s)[0].trackItemIndex, 5, "the newest is not first descending")
    }

    function test_play_and_shuffle_take_every_track_in_the_headings_order() {
        var s = open()
        sortBy(s, "title")
        filterTo(s, "zug")
        compare(rows(s).length, 1)
        findByText(hero(s), "Play").clicked()
        compare(titlesOf(player.queueTracks), "abend,Bahn,Café am Hafen,Mittag,Mittag,Zug",
                "Play did not take every track in the order of the headings")
        compare(player.queueIndex, 0)
        findByText(hero(s), "Shuffle").clicked()
        compare(player.queueCount, names.length, "Shuffle did not take every track")
        verify(player.shuffle)
    }

    function test_a_row_plays_the_rows_shown_from_itself() {
        var s = open()
        sortBy(s, "title")
        filterTo(s, "g")
        rows(s)[2].playRequested()
        compare(titlesOf(player.queueTracks), "Bahn,Mittag,Mittag,Zug")
        compare(player.queueIndex, 2)
        compare(player.sourceType, "playlist")
    }

    function test_a_rows_menu_queues_its_own_track() {
        var s = open()
        sortBy(s, "title")
        filterTo(s, "g")
        var row = rows(s)[0]
        row.openMenu()
        row.rowMenu.playNextItem.triggered()
        row.rowMenu.close()
        compare(titlesOf(player.queueManual), "Bahn", "the menu queued another row's track")
    }

    function test_a_removal_while_sorted_takes_that_row() {
        var s = open()
        sortBy(s, "title")
        var row = rows(s)[3]
        compare(row.title, "Mittag")
        compare(row.trackItemIndex, 0)
        row.removeFromPlaylistRequested(row.trackItemIndex)
        tryCompare(s.page.trackRows, "length", names.length - 1)
        compare(bridge.lastRemovedIndexForTest(), 0)
        compare(titlesOf(s.page.trackRows.list()), "abend,Zug,Bahn,Café am Hafen,Mittag", "the playlist lost another row")
        var r = rows(s)
        compare(titlesOf(r), "abend,Bahn,Café am Hafen,Mittag,Zug", "the rest are no longer sorted")
        compare(r.map(function (x) { return x.trackNum }).join(","), "1,3,4,5,2",
                "the rows after the removed one kept their old numbers")
    }

    function test_the_download_and_the_hero_take_the_whole_list() {
        var s = open()
        sortBy(s, "title")
        filterTo(s, "zug")
        var got = null
        s.page.allTracks(function (t) { got = t })
        verify(got)
        compare(titlesOf(got), names.join(","), "a download is not the playlist in its own order")
        compare(hero(s).distinctCovers.join(","),
                "cdn/0.jpg,cdn/1.jpg,cdn/2.jpg")
    }

    function test_the_count_and_the_no_match_line() {
        var s = open()
        filterTo(s, "zzz")
        compare(s.list.count, 0)
        verify(findByName(s.page, "playlistNoMatches").visible)
        filterTo(s, "")
        compare(s.list.count, names.length)
    }

    // A reload, as an undo sends, keeps the list where it was scrolled.
    function test_a_reload_keeps_the_rows_the_filter_and_the_order() {
        var s = open()
        sortBy(s, "title")
        filterTo(s, "g")
        Edits.playlistChanged(s.page.playlistUuid)
        frame(s.host.contentItem)
        compare(titlesOf(rows(s)), "Bahn,Mittag,Mittag,Zug")
        compare(findByName(s.page, "playlistFilter").text, "g")
    }
}
