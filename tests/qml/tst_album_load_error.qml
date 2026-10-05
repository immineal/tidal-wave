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
//
// The five cases after those are about what the panel offers to *do* with such
// a record - find the edition that replaced it, and get the dead one out of the
// library, including while that removal is still out - which is the other half
// of a page not looking broken.

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
    // item invisible - including the panel this file is about. Same reason
    // tst_hero_from_id.qml sets it.
    visible: true

    // Invented, like every fixture here: no id of the owner's is in this file.
    readonly property int deadAlbumId: 900000001
    readonly property int liveAlbumId: 900000002

    // The title the favourites endpoint goes on answering with for the dead id,
    // and the only name the page can put in front of the user once both of its
    // own fetches have been refused. Invented too.
    readonly property string deadTitle: "Abendrunde am Deich"

    Component { id: holderC; Item { } }
    Component { id: albumC;  AlbumPage { anchors.fill: parent } }

    // A host with a router in it. The two buttons below navigate, and the page
    // reaches the router as Window.window.navigate() - which the harness's own
    // window does not have, so a press inside the Item holder above would throw
    // instead of being recorded. Same stand-in tests/qml/tst_search.qml hosts
    // its page in.
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
        // resetForTest() takes the headers with it, plus the three favourite
        // maps, the refusal switch and the call log. It leaves the favourites
        // *lists* alone, so the seeded row below would otherwise outlive the
        // case that seeded it and name an album the next case never saved.
        bridge.resetForTest()
        bridge.setFavoriteAlbumsForTest([])
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

    // ── what the panel offers to do about it ────────────────────────────
    //
    // Saying "this album is gone" was the half that was missing; this is the
    // other half. A dead favourite is a record the user cannot open, cannot
    // play, and could not get rid of either: every route to "remove from the
    // library" in this app goes through a page that will not load, so the one
    // page that knows the album is dead was also the one page with nothing to
    // press. It carries two buttons now - the title handed to Search, where the
    // live edition turns up under another id, and the removal itself.
    //
    // The title cannot come from the album: both fetches for it were refused.
    // It comes from the favourites row that is still being listed - which is
    // the row Unsave deletes, so the two interact, and the second case below is
    // where that interaction is pinned down.

    // The library row the favourites endpoint goes on answering with, and the
    // flag isAlbumFavorite() reads. Both, because they are two caches in the
    // real bridge as well: the list is what a title is read out of and the flag
    // is what "this is saved" is asked of.
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
        // Sized, not merely visible, for the reason the two lines above it are
        // checked that way: a Layout child that sets width/height is laid out
        // at nothing and still answers visible true.
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

        // The query it carries is read out of the row the removal just deleted,
        // so this is the assertion a live binding fails: the button would lose
        // its title - and itself - at the very moment the removal landed.
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
    //
    // The press is the only move left on this page, and over a real network the
    // answer to it is a second or two away. That window did not exist in any
    // test until the stub could hold a reply: the callback ran before
    // mouseClick() returned, so the line that says it is working, the button
    // greying out and the guard against a second press were three pieces of
    // code nothing could execute - and a user who presses again because nothing
    // has happened yet is the ordinary case, not an odd one.
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
        // until the layout has been polished again it is still at the implicit
        // width it had while it was out of the layout - which is the width of
        // whatever string it happens to hold, not the width it is given.
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

        // Both routes to a second removal, because they are two separate
        // guards: `enabled` closes the pointer path, and the function refuses on
        // its own for everything else that can reach it (a key, a shortcut, a
        // binding that fires twice).
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
