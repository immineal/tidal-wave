// The album page numbers rows by the album's own track numbers, which start
// over on each disc, and heads each disc with "Disc n" when there is more
// than one. The bridge stub is the one from tests/TestStubs.h.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "AlbumDiscs"
    when: windowShown
    width: 1000
    height: 900
    visible: true

    Component { id: holderC; Item { } }
    Component { id: albumC;  AlbumPage { anchors.fill: parent } }

    // Invented, like every fixture here.
    readonly property int albumId: 900000101

    function makeTracks(discs) {
        var out = []
        var id = 82000
        for (var d = 0; d < discs.length; ++d)
            for (var n = 1; n <= discs[d]; ++n)
                out.push({ id: id++, title: "Stück " + (d + 1) + "-" + n, artists: "Eine Band",
                           albumTitle: "Zwei Scheiben", durationStr: "3:21", coverUrl: "",
                           coverUrl80: "", albumId: testCase.albumId, artistId: 3,
                           trackNumber: n, volumeNumber: d + 1 })
        return out
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function openAlbum(tracks) {
        bridge.setAlbumForTest({ id: testCase.albumId, title: "Zwei Scheiben", artists: "Eine Band",
                                 artistId: 3, numTracks: tracks.length, coverUrl: "" }, tracks)
        var holder = createTemporaryObject(holderC, testCase)
        holder.width = 960
        holder.height = 860
        var page = createTemporaryObject(albumC, holder, {})
        verify(page, "the album page was not created")
        page.albumId = testCase.albumId
        tryVerify(function () { return page.tracks.length === tracks.length }, 3000,
                  "the album never loaded")
        frame(page)
        return page
    }

    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    function rowsOf(item, out) {
        if (typeName(item) === "TrackRow") { out.push(item); return out }
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            if (typeName(kids[i]) === "TrackRow") out.push(kids[i])
            else rowsOf(kids[i], out)
        }
        return out
    }

    function shownHeaders(list) {
        var out = []
        for (var i = 0; i < list.count; ++i) {
            var d = list.itemAtIndex(i)
            if (!d) continue
            var h = findChild(d, "albumDiscHeader")
            if (h && h.visible) out.push({ index: i, text: h.text, height: h.height })
        }
        return out
    }

    function cleanup() {
        bridge.resetForTest()
    }

    function test_rows_carry_the_albums_own_track_numbers() {
        var page = openAlbum(makeTracks([3, 2]))
        var list = findChild(page, "albumTracksList")
        verify(list, "the album page has no track list")
        var nums = []
        for (var i = 0; i < list.count; ++i) {
            var d = list.itemAtIndex(i)
            verify(d, "row " + i + " is not drawn")
            var rows = rowsOf(d, [])
            compare(rows.length, 1, "delegate " + i + " holds " + rows.length + " track rows")
            nums.push(rows[0].trackNum)
        }
        compare(nums, [1, 2, 3, 1, 2], "the second disc did not start over at 1")
    }

    function test_each_disc_is_headed_when_there_are_two() {
        var page = openAlbum(makeTracks([3, 2]))
        var list = findChild(page, "albumTracksList")
        var heads = shownHeaders(list)
        compare(heads.length, 2, "expected one header per disc, got " + JSON.stringify(heads))
        compare(heads[0].index, 0)
        compare(heads[1].index, 3)
        compare(heads[0].text, qsTranslate("AlbumPage", "Disc %1", "heading over one disc's tracks on an album page").arg(1))
        compare(heads[1].text, qsTranslate("AlbumPage", "Disc %1", "heading over one disc's tracks on an album page").arg(2))
        verify(heads[1].height > 10, "the second header has no height: " + heads[1].height)
    }

    // A header's height followed its own text and looped on Qt 6.5 and
    // later whenever a disc began.
    function test_disc_headers_lay_out_without_a_binding_loop() {
        failOnWarning(/Binding loop detected/)
        var page = openAlbum(makeTracks([3, 2]))
        var list = findChild(page, "albumTracksList")
        compare(shownHeaders(list).length, 2)
        page.width = 700
        frame(page)
        page.width = 960
        frame(page)
    }

    function test_a_single_disc_album_has_no_header() {
        var page = openAlbum(makeTracks([5]))
        var list = findChild(page, "albumTracksList")
        compare(shownHeaders(list).length, 0, "a one-disc album drew a disc header")
        // Nor does a header take room while hidden.
        var d0 = list.itemAtIndex(0)
        var d1 = list.itemAtIndex(1)
        compare(d0.height, d1.height, "the first row is taller than the second")
    }
}
