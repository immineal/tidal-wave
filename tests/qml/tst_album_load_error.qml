// An album the API refuses to serve.
//
// The report was "it loaded an empty album page", from a row in the sidebar.
// The cause is a saved album whose id the API no longer answers for: both
// `albums/<id>` and `albums/<id>/items` reply 404, because the edition that was
// favourited has since been delisted while the favourites endpoint goes on
// listing it. Reached from Search the same record opens, because search finds a
// live edition under a different id, and opening it that way does not repair
// the saved one. So the page is reached with a real id, asks for it, and is
// told no - which is a state the API will produce for any library that is a few
// years old, not a one-off.
//
// What it did with "no" was nothing: both callbacks in AlbumPage.loadAlbum()
// read `if (!err)` and dropped the reason, so `albumData` stayed {} and
// `tracks` stayed [] while `loading` went false - the page's empty initial
// state, with no spinner and no message. A dead record and a broken app look
// identical from there.
//
// `bridge` is the stub from tests/TestStubs.h, whose two album fetches could
// not fail at all until this file needed them to.

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "AlbumLoadError"
    when: windowShown
    width: 1000
    height: 800
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible - including the panel this file is about. Same reason
    // tst_hero_from_id.qml sets it.
    visible: true

    // Invented, like every fixture here: no id of the owner's is in this file.
    readonly property int deadAlbumId: 900000001
    readonly property int liveAlbumId: 900000002

    Component { id: holderC; Item { } }
    Component { id: albumC;  AlbumPage { anchors.fill: parent } }

    function makeHolder() {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = 960
        holder.height = 700
        return holder
    }

    function openAlbum(id) {
        var holder = makeHolder()
        var page = createTemporaryObject(albumC, holder, {})
        verify(page, "the album page was not created")
        page.albumId = id
        waitForRendering(page, 2000)
        wait(1)
        return page
    }

    function errorPanelOf(page) {
        var p = findChild(page, "albumLoadError")
        verify(p, "the album page has no load-failure panel at all")
        return p
    }

    function cleanup() {
        bridge.resetHeadersForTest()
    }

    // The bug, in the one shape the user met it in.
    function test_an_album_the_server_refuses_says_so() {
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = openAlbum(testCase.deadAlbumId)

        compare(bridge.lastAlbumFetchedForTest(), testCase.deadAlbumId,
                "the page did not ask for the album it was opened with")
        compare(bridge.lastAlbumTracksFetchedForTest(), testCase.deadAlbumId,
                "the page did not ask for that album's tracklist")
        compare(page.loading, false,
                "a refused album left the page loading for ever")

        // Asserted before the properties behind it, so a page that says
        // nothing fails on *that* and not on a missing property name.
        var panel = errorPanelOf(page)
        verify(panel.visible,
               "an album that cannot be loaded drew its empty initial state and said nothing")

        var heading = findChild(page, "albumLoadErrorText")
        verify(heading, "the failure panel has no heading")
        verify(heading.text.length > 0, "the failure panel says nothing")

        // Visible and sized, not merely visible. A direct child of a Layout
        // that sets `width`/`height` instead of Layout.preferredWidth/Height
        // is laid out at nothing, and an item of no size still answers
        // `visible: true` - so a panel that cannot be read would pass every
        // assertion above it.
        var detail = findChild(page, "albumLoadErrorDetail")
        verify(detail, "the failure panel has no second line")
        verify(heading.width > 100 && heading.height > 10,
               "the heading was laid out at no size: " + heading.width + "x" + heading.height)
        verify(detail.width > 100 && detail.height > 20,
               "the second line was laid out at no size: " + detail.width + "x" + detail.height)

        var list = findChild(page, "albumTracksList")
        verify(list, "the album page has no tracklist")
        compare(list.visible, false,
                "the blank hero stayed on screen underneath the failure")

        verify(page.loadError.length > 0,
               "the page threw away the reason the server gave")
        verify(page.loadFailed,
               "a page with no header, no tracks and a refusal did not call itself failed")
    }

    // The other side of it: a page that loaded must not accuse anyone.
    function test_an_album_that_loads_shows_no_failure() {
        bridge.setAlbumForTest({ title: "Abendrunde", artists: "Eine Band",
                                 coverUrl: "cdn/alb.jpg", numTracks: 1 },
                               [{ id: 7001, title: "Erstes Stück",
                                  artists: "Eine Band", albumTitle: "Abendrunde",
                                  durationStr: "3:21", coverUrl: "", coverUrl80: "",
                                  albumId: testCase.liveAlbumId, artistId: 3 }])

        var page = openAlbum(testCase.liveAlbumId)

        compare(page.loadError, "", "a successful load reported an error")
        verify(!page.loadFailed, "a loaded album called itself failed")
        compare(errorPanelOf(page).visible, false,
                "the failure panel covered an album that loaded")
        compare(findChild(page, "albumTracksList").visible, true,
                "the tracklist was hidden on an album that loaded")
    }

    // An empty answer is not a refusal. The panel is gated on what the server
    // said, not on the page being bare - otherwise an album still in flight,
    // or one that genuinely answers with nothing, is called dead.
    function test_an_empty_answer_without_an_error_is_not_a_failure() {
        var page = openAlbum(testCase.liveAlbumId)

        compare(page.loadError, "", "an answer with no error reported one")
        verify(!page.loadFailed,
               "an empty but successful answer was reported to the user as a refusal")
        compare(errorPanelOf(page).visible, false,
                "the failure panel was shown for an answer that carried no failure")
    }
}
