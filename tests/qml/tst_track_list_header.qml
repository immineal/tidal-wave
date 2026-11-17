// The column headings over a track list: each sits over its column at every
// width the rows support and goes when the column goes; a click sorts by it,
// ascending, then descending, then the list's own order; the keyboard reaches
// them; and the order shown is the order that plays. Every title is invented.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TrackListHeader"
    when: windowShown
    visible: true
    width: 1900
    height: 800

    Component { id: rowC;    TrackRow { } }
    Component { id: headerC; TrackListHeader { } }
    Component { id: sortC;   TrackListHeader.Sort { } }
    Component { id: holderC; Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: playlistC;   PlaylistPage   { anchors.fill: parent } }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
    }
    function cleanup() {
        bridge.setFavoriteTracksListForTest([])
        bridge.setPlaylistTracksForTest([])
        // Here as well as in the test, so a failed check does not leave
        // every later test in German.
        bridge.useCatalogueForTest("")
    }

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

    // Invented, in the order a list would hand them over.
    function tracks() {
        return [
            { id: 11, title: "Mittag", artists: "B", albumTitle: "Zweites", albumId: 2,
              duration: 300, addedAt: 3000, trackNumber: 2, coverUrl80: "" },
            { id: 12, title: "abend", artists: "A", albumTitle: "Erstes", albumId: 1,
              duration: 120, addedAt: 0, trackNumber: 1, coverUrl80: "" },
            { id: 13, title: "Zug", artists: "C", albumTitle: "Erstes", albumId: 1,
              duration: 120, addedAt: 1000, trackNumber: 3, coverUrl80: "" },
            { id: 14, title: "Bahn", artists: "C", albumTitle: "Zweites", albumId: 2,
              duration: 500, addedAt: 2000, trackNumber: 1, coverUrl80: "" }
        ]
    }
    function titles(list) { return list.map(function (t) { return t.title }).join(",") }

    // ── where the headings sit ───────────────────────────────────────────

    function test_headings_sit_over_their_columns_data() {
        var out = []
        var widths = [400, 520, 640, 760, 900, 1100, 1400, 1800]
        for (var i = 0; i < widths.length; ++i) {
            out.push({ tag: widths[i] + " with dates", w: widths[i], added: true })
            out.push({ tag: widths[i] + " without", w: widths[i], added: false })
        }
        return out
    }

    function test_headings_sit_over_their_columns(data) {
        var t = tracks()[0]
        var row = createTemporaryObject(rowC, testCase, {
            width: data.w, showAdded: data.added, trackData: t,
            title: t.title, artists: t.artists, albumTitle: t.albumTitle })
        var head = createTemporaryObject(headerC, testCase, {
            width: data.w, showAdded: data.added, y: 100 })
        verify(row && head)
        waitForRendering(head)

        function xIn(item, from) { return item.mapToItem(from, 0, 0).x }
        var cover = findByName(row, "trackRowCover")
        var titleHead = findByName(head, "trackListHeadingTitle")
        fuzzyCompare(xIn(titleHead, head), xIn(cover, row), 1, "the title heading is off its column")

        var album = findByName(row, "trackAlbumColumn")
        var albumHead = findByName(head, "trackListHeadingAlbum")
        compare(albumHead.visible, album.visible, "the album heading and its column disagree")
        if (album.visible) {
            fuzzyCompare(xIn(albumHead, head), xIn(album, row), 1, "the album heading is off its column")
            fuzzyCompare(albumHead.width, album.width, 1, "the album heading is not the column's width")
        }

        var added = findByName(row, "trackAddedColumn")
        var addedHead = findByName(head, "trackListHeadingAdded")
        compare(addedHead.visible, added.visible, "the date heading and its column disagree")
        if (added.visible)
            fuzzyCompare(xIn(addedHead, head), xIn(added, row), 1, "the date heading is off its column")

        var len = findByName(row, "trackDuration")
        var lenHead = findByName(head, "trackListHeadingLength")
        fuzzyCompare(xIn(lenHead, head) + lenHead.width, xIn(len, row) + len.width, 1,
                     "the length heading does not end where the lengths do")
    }

    // The date column is as wide as its heading needs in German, set bold
    // with its arrow, not only as wide as a date.
    function test_the_date_heading_fits_in_german() {
        verify(bridge.useCatalogueForTest("de"), "the German catalogue did not load")
        var sort = createTemporaryObject(sortC, testCase)
        var head = createTemporaryObject(headerC, testCase, { width: 1200, showAdded: true, sort: sort })
        waitForRendering(head)
        var cell = findByName(head, "trackListHeadingAdded")
        var label = findByName(cell, "trackListHeadingLabel")
        compare(label.text, "Hinzugefügt am")
        verify(!label.truncated, "the date heading is cut at rest")
        sort.cycle("added")
        waitForRendering(head)
        verify(!label.truncated, "the date heading is cut while it sorts")
    }

    // The date in the language picked in the app, whatever the system's
    // formats, and again after a switch while the row is on screen.
    function test_the_date_is_written_in_the_apps_language() {
        var t = { id: 21, title: "Mittag", artists: "B", albumTitle: "Zweites",
                  addedAt: new Date(2023, 7, 30).getTime() }
        var before = createTemporaryObject(rowC, testCase, { width: 1200, showAdded: true, trackData: t })
        verify(bridge.useCatalogueForTest("de"), "the German catalogue did not load")
        var after = createTemporaryObject(rowC, testCase, { width: 1200, showAdded: true, trackData: t, y: 60 })
        waitForRendering(after)
        compare(findByName(after, "trackAddedColumn").text, "30.08.23", "a new row")
        compare(findByName(before, "trackAddedColumn").text, "30.08.23", "a row from before the switch")
        bridge.useCatalogueForTest("")
        var back = findByName(before, "trackAddedColumn").text
        verify(back !== "30.08.23", "the German date stayed after the switch back")
        compare(back, findByName(after, "trackAddedColumn").text, "two rows disagree in English")
    }

    // A column the page turns off has no heading either.
    function test_a_page_without_albums_has_no_album_heading() {
        var head = createTemporaryObject(headerC, testCase, { width: 1200, showAlbum: false })
        verify(!findByName(head, "trackListHeadingAlbum").visible)
    }

    // ── what a click does ────────────────────────────────────────────────

    function test_a_heading_sorts_up_down_and_back() {
        var sort = createTemporaryObject(sortC, testCase)
        var list = tracks()
        compare(titles(sort.sorted(list)), "Mittag,abend,Zug,Bahn", "the list's own order is kept")
        sort.cycle("title")
        compare(titles(sort.sorted(list)), "abend,Bahn,Mittag,Zug", "first click: A to Z, any case")
        sort.cycle("title")
        compare(titles(sort.sorted(list)), "Zug,Mittag,Bahn,abend", "second click: Z to A")
        sort.cycle("title")
        compare(sort.key, "", "third click did not go back to the list's order")
        compare(titles(sort.sorted(list)), "Mittag,abend,Zug,Bahn")
    }

    function test_each_column_sorts_by_what_it_shows_data() {
        return [
            { tag: "album, then its track order", key: "album", want: "abend,Zug,Bahn,Mittag" },
            { tag: "length, ties in list order",  key: "duration", want: "abend,Zug,Mittag,Bahn" },
            { tag: "date added, undated last",     key: "added", want: "Zug,Bahn,Mittag,abend" }
        ]
    }
    function test_each_column_sorts_by_what_it_shows(data) {
        var sort = createTemporaryObject(sortC, testCase)
        sort.cycle(data.key)
        compare(titles(sort.sorted(tracks())), data.want)
    }

    function test_undated_rows_stay_last_descending() {
        var sort = createTemporaryObject(sortC, testCase)
        sort.cycle("added"); sort.cycle("added")
        compare(titles(sort.sorted(tracks())), "Mittag,Bahn,Zug,abend")
    }

    // Where each shown row sits in the list, for a list from C++ whose rows
    // are new objects on every read.
    function test_the_order_names_each_rows_place() {
        var sort = createTemporaryObject(sortC, testCase)
        compare(sort.order(tracks()).join(","), "0,1,2,3")
        sort.cycle("title")
        compare(sort.order(tracks()).join(","), "1,3,0,2")
    }

    function test_a_click_cycles_and_draws_the_arrow() {
        var sort = createTemporaryObject(sortC, testCase)
        var head = createTemporaryObject(headerC, testCase, { width: 1200, sort: sort })
        waitForRendering(head)
        var title = findByName(head, "trackListHeadingTitle")
        var arrow = findByName(title, "trackListSortArrow")
        verify(!arrow.visible, "an arrow before any sort")
        mouseClick(title, 10, title.height / 2)
        compare(sort.key, "title")
        compare(sort.descending, false)
        verify(arrow.visible, "the active column shows no arrow")
        compare(arrow.name, "chevron-up")
        mouseClick(title, 10, title.height / 2)
        compare(sort.descending, true)
        compare(arrow.name, "chevron-down")
        mouseClick(title, 10, title.height / 2)
        compare(sort.key, "")
        verify(!arrow.visible, "the arrow outlived the sort")
        compare(title.Accessible.role, Accessible.ColumnHeader)
    }

    function test_the_keyboard_reaches_and_sorts() {
        var sort = createTemporaryObject(sortC, testCase)
        var head = createTemporaryObject(headerC, testCase, { width: 1200, sort: sort })
        waitForRendering(head)
        var title = findByName(head, "trackListHeadingTitle")
        verify(title.activeFocusOnTab, "the title heading is no tab stop")
        title.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(sort.key, "title")
        keyClick(Qt.Key_Return)
        compare(sort.descending, true)
        var number = findByName(head, "trackListHeadingNumber")
        verify(!number.activeFocusOnTab, "the number heading sorts nothing and is a tab stop")
    }

    // ── Liked tracks ─────────────────────────────────────────────────────

    function makeCollection() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1280, height: 760 })
        bridge.setFavoriteTracksListForTest(tracks())
        var page = createTemporaryObject(collectionC, holder, {})
        verify(page)
        page.activeTab = 0
        waitForRendering(page)
        return page
    }

    function test_liked_tracks_sort_in_the_headings_and_play_in_that_order() {
        var page = makeCollection()
        var head = findByName(page, "collectionTracksHeader")
        verify(head && head.visible, "Liked tracks has no column headings")
        verify(findByName(head, "trackListHeadingAdded").visible,
               "Liked tracks has no date added heading")
        var pill = findByName(page, "collectionSortDefault")
        verify(!pill || !pill.visible, "the sort words are still over the track list")

        var list = findByName(page, "collectionTracksList")
        var title = findByName(head, "trackListHeadingTitle")
        mouseClick(title, 10, title.height / 2)
        compare(titles(list.model), "abend,Bahn,Mittag,Zug")
        tryVerify(function () { return list.itemAtIndex(1) !== null })
        list.itemAtIndex(1).playRequested()
        compare(titles(player.queueTracks), "abend,Bahn,Mittag,Zug", "the queue is not the order shown")
        compare(player.queueIndex, 1)
    }

    // ── a playlist ───────────────────────────────────────────────────────

    // A sort is the view's: rows still say where they are on Tidal's list,
    // which is what a removal names.
    function test_a_sorted_playlist_keeps_each_rows_place_on_tidal() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1280, height: 760 })
        bridge.setPlaylistTracksForTest(tracks())
        var page = createTemporaryObject(playlistC, holder, {})
        page.playlistUuid = "11111111-2222-3333-4444-555555555555"
        var list = null
        tryVerify(function () {
            list = findByName(page, "playlistTracksList")
            return list && list.count === 4
        }, 3000, "the playlist never filled")
        var head = findByName(page, "playlistTracksHeader")
        verify(head && head.visible, "the playlist has no column headings")
        var title = findByName(head, "trackListHeadingTitle")
        mouseClick(title, 10, title.height / 2)
        compare(titles(list.model), "abend,Bahn,Mittag,Zug")
        compare(titles(page.tracks), "Mittag,abend,Zug,Bahn", "the sort reordered the playlist itself")
        tryVerify(function () { return list.itemAtIndex(0) !== null })
        compare(list.itemAtIndex(0).trackItemIndex, 1, "a row lost its place on the playlist")
        list.itemAtIndex(0).playRequested()
        compare(titles(player.queueTracks), "abend,Bahn,Mittag,Zug", "the queue is not the order shown")
    }
}
