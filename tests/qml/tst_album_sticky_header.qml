// AlbumPage's sticky header: the bar with the album's title that comes in
// when the hero has scrolled away. Its list starts at originY, which is minus
// the height of the hero. The stub bridge is the one from tests/TestStubs.h.
// Every id, title and name is invented.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "AlbumStickyHeader"
    when: windowShown
    width: 1000
    height: 760
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible.
    visible: true

    readonly property int albumId: 900500001

    Component { id: holderC; Item { } }
    Component { id: albumC;  AlbumPage { anchors.fill: parent } }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function settle(item) {
        frame(item)
        wait(1)
    }

    function product(id, explicit_, modes, tags) {
        return { id: id, title: "Nebelhorn", artists: "Ilka Vandersee", artistId: 900500900,
                 coverUrl: "cover-" + id, coverUrl640: "cover-" + id, year: "2032",
                 releaseDate: "2032-05-07", numTracks: 12, duration: 2640, type: "ALBUM",
                 quality: modes[0] === "DOLBY_ATMOS" ? "LOW" : "LOSSLESS",
                 explicit_: explicit_, audioModes: modes, mediaTags: tags }
    }

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 900510001 + i, title: "Signal " + (i + 1), artists: "Ilka Vandersee",
                       artistId: 900500900, duration: 220, durationStr: "3:40" })
        return out
    }

    // A page of `n` tracks, `height` high, with an Other versions row or none.
    function openAlbum(n, height, withVersions) {
        if (withVersions)
            bridge.setOtherVersionsForTest([
                product(900500002, false, ["STEREO"], ["LOSSLESS", "HIRES_LOSSLESS"]),
                product(900500003, true,  ["DOLBY_ATMOS"], ["DOLBY_ATMOS"]) ])
        bridge.setAlbumForTest(product(testCase.albumId, true, ["STEREO"],
                                       ["LOSSLESS", "HIRES_LOSSLESS"]), makeTracks(n))
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = 960
        holder.height = height
        var page = createTemporaryObject(albumC, holder, {})
        verify(page, "the album page was not created")
        page.albumId = testCase.albumId
        settle(page)
        var list = findChild(page, "albumTracksList")
        tryCompare(list, "count", n)
        if (withVersions)
            tryVerify(function () { return findChild(page, "albumOtherVersions").visible },
                      2000, "the Other versions row did not come")
        settle(page)
        // The stub answers before the first layout, which leaves the list
        // below its hero.
        list.positionViewAtBeginning()
        settle(page)
        return page
    }

    function parts(page) {
        var list = findChild(page, "albumTracksList")
        verify(list, "the album page has no track list")
        var bar = findChild(page, "albumStickyHeader")
        verify(bar, "the album page has no sticky header to look at")
        return { list: list, bar: bar }
    }

    // Where the first row begins on the page: the lower edge of the hero.
    function rowsStartAt(page, list) {
        return list.headerItem.mapToItem(page, 0, list.headerItem.height).y
    }

    function scrollTo(page, list, scrolled) {
        list.contentY = list.originY + scrolled
        settle(page)
    }

    function cleanup() {
        bridge.resetForTest()
        bridge.resetOtherVersionsForTest()
        player.playTracks([], 0)
        player.setPlaybackSource("", "", "")
    }

    function test_the_header_is_hidden_at_the_top_of_the_page() {
        var page = openAlbum(12, 700, true)
        var p = parts(page)
        compare(p.list.contentY, p.list.originY, "the page did not open at its top")
        compare(p.bar.reveal, 0, "the header shows over the hero at the top of the page")
    }

    // A record of twelve tracks with other versions ends a little after its
    // hero has left. The header is whole there.
    function test_the_header_is_whole_at_the_end_of_a_page_whose_hero_has_left() {
        var page = openAlbum(12, 700, true)
        var p = parts(page)
        p.list.positionViewAtEnd()
        settle(page)
        verify(p.list.atYEnd, "the list is not at its end after being sent there")
        verify(rowsStartAt(page, p.list) <= p.bar.height,
               "the fixture does not scroll its hero away: rows start at "
               + rowsStartAt(page, p.list))
        compare(p.bar.reveal, 1, "rows lie under a header that is not whole")
    }

    // Wherever the page rests, a row under the bar means the bar is whole, and
    // the bar comes in over the hero alone.
    function test_no_row_lies_under_a_header_that_is_not_whole_data() {
        return [ { tag: "twelve tracks and versions", n: 12, versions: true },
                 { tag: "thirty tracks",              n: 30, versions: false } ]
    }
    function test_no_row_lies_under_a_header_that_is_not_whole(data) {
        var page = openAlbum(data.n, 700, data.versions)
        var p = parts(page)
        var most = p.list.contentHeight - p.list.height
        verify(most > p.list.headerItem.height, "the fixture does not scroll past its hero")
        var cameIn = false
        for (var scrolled = 0; scrolled <= most; scrolled += 12) {
            scrollTo(page, p.list, scrolled)
            var start = rowsStartAt(page, p.list)
            if (start < p.bar.height)
                compare(p.bar.reveal, 1, "a row lies under a header that is not whole, "
                        + scrolled + " px into the page (rows start at " + start + ")")
            if (p.bar.reveal > 0 && p.bar.reveal < 1) cameIn = true
        }
        verify(cameIn, "the header never faded in; it jumped")
    }

    // A hero that is taller (a title that wraps) moves the place with it.
    function test_the_header_waits_for_the_whole_hero() {
        var page = openAlbum(30, 700, false)
        var p = parts(page)
        var hero = p.list.headerItem.height
        scrollTo(page, p.list, hero - p.bar.height - 100)
        compare(p.bar.reveal, 0, "the header shows while a good part of the hero is on the page")
        scrollTo(page, p.list, hero - p.bar.height)
        compare(p.bar.reveal, 1, "the header is not whole when the first row reaches it")
    }
}
