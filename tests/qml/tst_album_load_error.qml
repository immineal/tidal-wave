// An album the API refuses to serve: albums/<id> and albums/<id>/items both
// answer 404 for an edition that has been delisted while the favourites
// endpoint goes on listing it. The page has to say so, and offer to find the
// live edition and to remove the dead one from the library.
// The bridge stub is the one from tests/TestStubs.h.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "AlbumLoadError"
    when: windowShown
    width: 1000
    height: 800
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible, including the panel this file is about.
    visible: true

    // Invented, like every fixture here.
    readonly property int deadAlbumId: 900000001
    readonly property int liveAlbumId: 900000002

    // The title the favourites endpoint goes on answering with for the dead
    // id, and the only name the page has once both of its fetches are refused.
    readonly property string deadTitle: "Abendrunde am Deich"

    Component { id: holderC; Item { } }
    Component { id: albumC;  AlbumPage { anchors.fill: parent } }

    // A host with a router in it. The two buttons navigate through
    // Window.window.navigate(), which the harness's own window does not have.
    Component {
        id: winHostC
        Window {
            width: 960
            height: 700
            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}
            property alias page: hostedAlbum
            AlbumPage { id: hostedAlbum; anchors.fill: parent }
        }
    }

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
        // resetForTest() leaves the favourites lists alone, so the seeded row is
        // cleared here or it would outlive the case that seeded it.
        bridge.resetForTest()
        bridge.setFavoriteAlbumsForTest([])
    }

    function test_an_album_the_server_refuses_says_so() {
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = openAlbum(testCase.deadAlbumId)

        compare(bridge.lastAlbumFetchedForTest(), testCase.deadAlbumId,
                "the page did not ask for the album it was opened with")
        compare(bridge.lastAlbumTracksFetchedForTest(), testCase.deadAlbumId,
                "the page did not ask for that album's tracklist")
        compare(page.loading, false,
                "a refused album left the page loading for ever")

        // Asserted before the properties behind it, so a page that says nothing
        // fails here and never on a missing property name.
        var panel = errorPanelOf(page)
        verify(panel.visible,
               "an album that cannot be loaded drew its empty initial state and said nothing")

        var heading = findChild(page, "albumLoadErrorText")
        verify(heading, "the failure panel has no heading")
        verify(heading.text.length > 0, "the failure panel says nothing")

        // Sized as well as visible. A direct child of a Layout that sets width
        // and height in place of Layout.preferredWidth/Height is laid out at
        // nothing, and an item of no size still answers visible: true.
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
    // said, so an album still in flight, or one that answers with nothing, is
    // never called dead.
    function test_an_empty_answer_without_an_error_is_not_a_failure() {
        var page = openAlbum(testCase.liveAlbumId)

        compare(page.loadError, "", "an answer with no error reported one")
        verify(!page.loadFailed,
               "an empty but successful answer was reported to the user as a refusal")
        compare(errorPanelOf(page).visible, false,
                "the failure panel was shown for an answer that carried no failure")
    }

    // ── what the panel offers to do about it ────────────────────────────
    // The panel carries two buttons: the title handed to Search, where the
    // live edition turns up under another id, and the removal. The title comes
    // from the favourites row, which is the row Unsave deletes.

    // The library row the favourites endpoint goes on answering with, and the
    // flag isAlbumFavorite() reads. They are two caches in the real bridge too.
    function seedDeadFavourite() {
        bridge.setFavoriteAlbumsForTest([{ id: testCase.deadAlbumId,
                                           title: testCase.deadTitle,
                                           artists: "Eine Band", coverUrl: "" }])
        bridge.setAlbumFavoriteForTest(testCase.deadAlbumId, true)
    }

    function openRefusedAlbumInWindow() {
        bridge.setHeaderErrorForTest("server replied: Not Found")
        var win = createTemporaryObject(winHostC, testCase)
        verify(win, "the album page host window was not created")
        win.visible = true
        win.page.albumId = testCase.deadAlbumId
        waitForRendering(win.contentItem, 2000)
        wait(1)
        verify(win.page.loadFailed,
               "the fixture did not produce a refused album, so nothing below is about the panel")
        return win
    }

    function buttonOn(page, name, what) {
        var b = findChild(page, name)
        verify(b, "the failure panel has no " + what + " button")
        return b
    }

    function clickCenter(item) {
        mouseClick(item, Math.round(item.width / 2), Math.round(item.height / 2))
    }

    function test_a_refused_album_offers_a_way_to_find_the_live_edition() {
        seedDeadFavourite()
        var win = openRefusedAlbumInWindow()
        var find = buttonOn(win.page, "albumLoadErrorFind", "Find album")

        verify(find.visible, "an album that is gone offered no way to look for it")
        // Sized as well as visible, for the Layout reason given in the first case.
        verify(find.width > 60 && find.height > 20,
               "the Find album button was laid out at no size: "
               + find.width + "x" + find.height)

        clickCenter(find)

        compare(win.navCalls.length, 1, "pressing Find album went nowhere")
        compare(win.navCalls[0].page, "search",
                "Find album opened \"" + win.navCalls[0].page + "\"")
        compare(win.navCalls[0].params.requestedQuery, testCase.deadTitle,
                "Search was handed no title to run, so it opens empty and the user "
                + "has nothing to type: the page knows an id and nothing else, and "
                + "the title has to come off the favourites row still being listed")
    }

    function test_unsaving_a_dead_album_removes_it_and_says_so() {
        seedDeadFavourite()
        var win = openRefusedAlbumInWindow()
        var page = win.page
        var unsave = buttonOn(page, "albumLoadErrorUnsave", "Unsave")

        verify(unsave.visible, "a saved album that is gone offered no way to unsave it")
        verify(unsave.width > 60 && unsave.height > 20,
               "the Unsave button was laid out at no size: "
               + unsave.width + "x" + unsave.height)

        clickCenter(unsave)

        compare(bridge.lastFavoriteCallForTest(), "removeAlbum:" + testCase.deadAlbumId,
                "Unsave did not send a removal for this album")
        compare(bridge.favoriteCallsForTest(), 1, "Unsave sent more than the one call")

        var said = findChild(page, "albumLoadErrorUnsaveStatus")
        verify(said, "the panel has no line to report the removal on")
        tryVerify(function () { return said.visible && said.text.length > 0 }, 2000,
                  "the album was removed and the panel said nothing, which is "
                  + "indistinguishable from a press that did not land")
        verify(said.width > 100 && said.height > 10,
               "the confirmation was laid out at no size: "
               + said.width + "x" + said.height)
        verify(!unsave.visible,
               "Unsave is still on offer for an album that has already been unsaved")

        // The query is read out of the row the removal just deleted, so a live
        // binding would lose the title, and the button, as the removal lands.
        var find = buttonOn(page, "albumLoadErrorFind", "Find album")
        verify(find.visible, "unsaving the album took the search button with it")
        clickCenter(find)
        compare(win.navCalls.length, 1, "pressing Find album after the removal went nowhere")
        compare(win.navCalls[0].params.requestedQuery, testCase.deadTitle,
                "after the removal Find album carries no title to search for")

        compare(findChild(page, "albumLoadError").visible, true,
                "the failure panel went with the favourite, leaving the blank page "
                + "this whole file is about")
    }

    function test_a_refused_removal_is_not_reported_as_done() {
        seedDeadFavourite()
        bridge.setFavoriteOkForTest(false)
        var win = openRefusedAlbumInWindow()
        var page = win.page
        var unsave = buttonOn(page, "albumLoadErrorUnsave", "Unsave")

        clickCenter(unsave)

        compare(bridge.lastFavoriteCallForTest(), "removeAlbum:" + testCase.deadAlbumId,
                "Unsave did not send a removal for this album")
        var said = findChild(page, "albumLoadErrorUnsaveStatus")
        verify(said, "the panel has no line to report the refusal on")
        tryVerify(function () { return said.visible && said.text.length > 0 }, 2000,
                  "a removal the server refused said nothing at all")
        verify(!page.unsaveDone, "a refused removal was recorded as done")
        verify(unsave.visible, "a refused removal hid the one button that would retry it")
    }

    // ── while the DELETE is still out ───────────────────────────────────
    // Over a real network the answer to the press is a moment away. The stub
    // holds the reply, so the progress line, the disabled button and the guard
    // against a second press can be exercised.
    function test_a_removal_still_in_flight_says_so_and_takes_no_second_press() {
        seedDeadFavourite()
        bridge.setDeferFavoriteRepliesForTest(true)
        var win = openRefusedAlbumInWindow()
        var page = win.page
        var unsave = buttonOn(page, "albumLoadErrorUnsave", "Unsave")

        clickCenter(unsave)

        compare(bridge.pendingFavoriteRepliesForTest(), 1,
                "the removal was not left in flight, so nothing below is about a call "
                + "that is still out")
        compare(bridge.favoriteCallsForTest(), 1, "the press sent no removal")

        var said = findChild(page, "albumLoadErrorUnsaveStatus")
        verify(said, "the panel has no line to report the removal on")
        verify(said.visible && said.text.length > 0,
               "a removal that is still out said nothing, so the press is "
               + "indistinguishable from one that did not land")
        // A frame first: the line joins the column as it gains its text, and
        // until the layout is polished again it keeps its implicit width.
        waitForRendering(win.contentItem, 2000)
        verify(said.width > 100 && said.height > 10,
               "the progress line was laid out at no size: "
               + said.width + "x" + said.height)
        verify(unsave.visible,
               "the button left before the server had answered, so a refusal would "
               + "leave nothing to retry with")
        compare(unsave.enabled, false,
                "the button is still live while its own removal is out, so the pointer "
                + "can send a second one")

        // Both routes to a second removal, because they are two guards: enabled
        // closes the pointer path, and the function refuses on its own for a key,
        // a shortcut or a binding that fires twice.
        clickCenter(unsave)
        page.unsaveDeadAlbum()
        compare(bridge.favoriteCallsForTest(), 1,
                "pressing again while the first removal was still out sent a second one")

        bridge.flushFavoriteRepliesForTest()

        tryVerify(function () { return page.unsaveDone }, 2000,
                  "the reply came back accepted and the page never recorded it")
        verify(said.visible && said.text.length > 0,
               "the finished removal left the panel silent")
        verify(!unsave.visible,
               "Unsave is still on offer for an album that has been unsaved")
    }

    function test_an_album_that_is_not_in_the_library_offers_neither() {
        // Nothing seeded: a pinned row outlives the album leaving the library,
        // so the page is reachable with no favourites row behind it at all.
        var win = openRefusedAlbumInWindow()
        var page = win.page

        compare(buttonOn(page, "albumLoadErrorUnsave", "Unsave").visible, false,
                "an album that is not in the library offered to remove it from the library")
        compare(buttonOn(page, "albumLoadErrorFind", "Find album").visible, false,
                "the page offered to search for a title it does not have")
    }
}
