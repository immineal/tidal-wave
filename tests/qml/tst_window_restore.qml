// A restart opens on the page the window showed when it was left, and the
// window keeps telling the app which page that is.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "WindowRestore"
    when: windowShown

    Component { id: appHost; Main {} }

    // The page to open comes from the app, which read it once at start;
    // what the window remembers goes to prefs.
    function init() {
        app.setReducedMotionForTest(true)
        app.setStartPageForTest("")
        prefs.lastPage = ""
        auth.setStateForTest(2)
    }

    function cleanup() {
        app.setStartPageForTest("")
        auth.setStateForTest(2)
    }

    function showApp() {
        var win = createTemporaryObject(appHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        return win
    }

    function remembered() {
        var s = prefs.lastPage
        return s.length > 0 ? JSON.parse(s) : null
    }

    function test_a_signed_in_start_opens_the_last_page() {
        app.setStartPageForTest(JSON.stringify({ page: "album", params: { albumId: 42 } }))
        var win = showApp()
        tryCompare(win, "currentPage", "album")
        compare(win._currentNavParams.albumId, 42, "the album page did not get its id back")
    }

    function test_a_sign_in_after_start_opens_the_last_page() {
        auth.setStateForTest(0)
        app.setStartPageForTest(JSON.stringify({ page: "collection", params: {} }))
        var win = showApp()
        auth.setStateForTest(2)
        tryCompare(win, "currentPage", "collection")
        // Only once: the next sign-in is a new session and starts at Home.
        auth.setStateForTest(0)
        auth.setStateForTest(2)
        tryCompare(win, "currentPage", "home")
    }

    function test_nothing_saved_opens_home() {
        var win = showApp()
        compare(win.currentPage, "home")
    }

    function test_each_page_is_remembered_but_not_now_playing() {
        var win = showApp()
        win.navigate("collection")
        compare(remembered().page, "collection")
        win.navigate("artist", { artistId: 7 })
        compare(remembered().page, "artist")
        compare(remembered().params.artistId, 7)
        win.navigate("nowplaying")
        compare(remembered().page, "artist", "Now Playing was remembered as the page to open")
    }

    // A search is not run again on the next start.
    function test_a_search_is_remembered_without_its_query() {
        var win = showApp()
        win.navigate("search", { requestedQuery: "ein lied" })
        compare(remembered().page, "search")
        verify(remembered().params.requestedQuery === undefined, "the query was saved to run again")
    }

    // A saved page from a build that no longer has it opens Home.
    function test_a_page_that_is_gone_opens_home() {
        app.setStartPageForTest(JSON.stringify({ page: "videos", params: {} }))
        var win = showApp()
        wait(50)
        compare(win.currentPage, "home")
        app.setStartPageForTest("not json")
        var again = showApp()
        wait(50)
        compare(again.currentPage, "home")
    }
}
