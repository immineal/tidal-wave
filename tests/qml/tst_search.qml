// The remote search page: what it says between the keystroke and the reply.
//
// Four defects, all of them the same shape - the page had two notions of state,
// "I have results" and "I have none", and told the user about the second one
// whenever it was not in the first:
//
//   D1  "No results for ab" for the whole 400ms the debounce was still
//       waiting, on every keystroke, before anything had been asked for.
//   D2  the field never had the keyboard at all. Arriving at the page gave the
//       *Loader* active focus, and leaving it cleared the only focus item in
//       that scope, so neither the first visit nor any later one put a cursor
//       in the field. (It was reported as a second-visit bug; the first visit
//       went red too.)
//   D3  a type tab whose own kind had no hits hid every section *and* the
//       no-results strip, so the pane was empty with no message in it.
//   D4  a failed search looked exactly like a successful one: the spinner went
//       away, the previous query's results stayed on screen under the new
//       text, and nothing said the request had failed.
//
// Nothing here looks for an objectName on the strip. The assertions ask what a
// person reading the page would see - is there a visible line of text saying
// this, right now - because D1 and D3 are both about a sentence appearing when
// it has no business appearing, and a test that found the strip by name would
// pass the day the sentence moved into a different Item.
//
// The fixtures are invented: `bridge.search` answers whatever
// setSearchResultsForTest() put there and the stub matches nothing itself, so
// the names below exist only to be recognisable in a failure message. None of
// it is a capture.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Search"
    when: windowShown
    visible: true
    width: 1280
    height: 800

    // The page's own debounce (SearchPage.qml's searchDebounce), repeated so a
    // change to it fails here rather than silently widening the window this
    // file is measuring.
    readonly property int debounceMs: 400
    readonly property int settleMs: 2000

    // Two characters is the threshold the page searches above.
    // A query that appears in none of the fixtures below, so a visible line of
    // text containing it can only be the page talking about the search.
    readonly property string query: "grubenlampe"
    readonly property string shortQuery: "g"

    function init() {
        app.setReducedMotionForTest(true)   // no fades to wait out
        auth.setStateForTest(2)             // LoggedIn
        auth.setUsernameForTest("linus")
        auth.setHasSavedCredentialsForTest(false)
        library.setEntriesForTest([])
        library.setTracksForTest([])
        pins.setItemsForTest([])
        bridge.resetForTest()               // clears the canned search reply too
        updateCheck.clearForTest()          // the prompt would eat the keyboard
    }

    function cleanup() {
        app.setReducedMotionForTest(false)
        bridge.resetForTest()
    }

    // ── fixtures ─────────────────────────────────────────────────────────

    function fakeTracks(n) {
        var out = []
        for (var i = 1; i <= n; ++i)
            out.push({
                id: 9000 + i,
                title: "Erfundenes Lied " + i,
                artists: "Beispielkapelle",
                artistId: 7001,
                artistList: [{ id: 7001, name: "Beispielkapelle" }],
                albumTitle: "Erfundenes Album",
                albumId: 8001,
                coverUrl: "",
                coverUrl80: "",
                duration: 200,
                durationStr: "3:20"
            })
        return out
    }

    function fakeAlbums(n) {
        var out = []
        for (var i = 1; i <= n; ++i)
            out.push({ id: 8000 + i, title: "Erfundenes Album " + i,
                       artists: "Beispielkapelle", coverUrl: "" })
        return out
    }

    function fakeArtists(n) {
        var out = []
        for (var i = 1; i <= n; ++i)
            out.push({ id: 7000 + i, name: "Beispielkapelle " + i, coverUrl: "" })
        return out
    }

    function fakePlaylists(n) {
        var out = []
        for (var i = 1; i <= n; ++i)
            out.push({ uuid: "erfunden-" + i, title: "Erfundene Playlist " + i,
                       numTracks: 4, coverUrl: "", type: "USER" })
        return out
    }

    // ── hosts ────────────────────────────────────────────────────────────

    Component {
        id: pageHost
        Window {
            id: pwin
            width: 1100; height: 760
            // Main.qml's surface, as far as the page is concerned: it reaches
            // the router as Window.window.navigate().
            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}

            property alias page: sp
            SearchPage { id: sp; anchors.fill: parent }
        }
    }

    // D2 is a bug in the handover between the router and the page, so it needs
    // the router: the Loader that drops the field's focus on the way out lives
    // in Main.qml, and no stand-in host has one. Same window tst_main_escape
    // and tst_nowplaying_access use.
    Component { id: appHost; Main { } }

    // ── helpers ──────────────────────────────────────────────────────────

    function showPage() {
        var win = createTemporaryObject(pageHost, testCase)
        verify(win, "the search page host was not created")
        win.visible = true
        waitForRendering(win.contentItem, settleMs)
        return win
    }

    function showApp() {
        var win = createTemporaryObject(appHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        win.requestActivate()
        waitForRendering(win.contentItem, settleMs)
        return win
    }

    // Typing, as the user does it: the bar's TextInput is what the page listens
    // to, so setting its text runs onTextEdited and restarts the debounce. Not
    // keyClick, because every case below one is about the page and not about
    // which item has the keyboard.
    function typeInto(page, text) {
        var bar = findByName(page, "searchPageBar")
        verify(bar, "the page has no search bar")
        bar.text = text
    }

    // Every *visible* Text in the tree whose string contains `needle`.
    // QQuickItem.visible is the effective value, so an item inside a hidden
    // section or a hidden ScrollView is already excluded.
    function visibleTextsSaying(item, needle) {
        return collectSaying(item, needle, [])
    }

    function collectSaying(item, needle, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            if (c.visible === false) continue
            if (typeof c.text === "string" && c.text.indexOf(needle) >= 0) out.push(c)
            collectSaying(c, needle, out)
        }
        return out
    }

    function saysSomethingContaining(item, needle) {
        return visibleTextsSaying(item, needle).length > 0
    }

    // The column under the tab row, which is where every answer about a query
    // is printed. Scanning the whole page for the query instead would find the
    // search field itself - it is a visible Text holding exactly that string -
    // and three cases below went green against it before this existed.
    function resultsArea(page) {
        var area = findByName(page, "searchResults")
        verify(area, "the page has no results column")
        return area
    }

    // What the page is telling the user right now, for a failure message.
    function visibleCopy(item) {
        var all = collectSaying(item, "", [])
        var out = []
        for (var i = 0; i < all.length; ++i)
            if (all[i].text.length > 0) out.push("\"" + all[i].text + "\"")
        return out.length === 0 ? "(nothing at all)" : out.join(", ")
    }

    // `focused` is the bar's own alias for its TextInput's activeFocus, which
    // is the thing D2 is about. By name, not by type: the Collection page has a
    // bar of its own and its Loader is live in this window too.
    function searchBarIn(item) {
        var bar = findByName(item, "searchPageBar")
        verify(bar, "no search bar in this window")
        return bar
    }

    function findByName(item, name) {
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    // The ways the page can report an empty outcome, so a case can assert that
    // it reports none of them. Returns the offending line, or "".
    readonly property var emptyPhrases: ["No results", "No tracks", "No albums",
                                         "No artists", "No playlists"]

    function emptyClaim(item) {
        for (var i = 0; i < emptyPhrases.length; ++i) {
            var hits = visibleTextsSaying(item, emptyPhrases[i])
            if (hits.length > 0) return hits[0].text
        }
        return ""
    }

    // Everything the page can say about the outcome of a search: the lines
    // above plus the one a failure prints. Returns the offending line, or "".
    function outcomeClaim(item) {
        var claim = emptyClaim(item)
        if (claim !== "") return claim
        var failed = visibleTextsSaying(item, "Search failed")
        return failed.length > 0 ? failed[0].text : ""
    }

    // ── D0 (the prerequisite): the stub is answering honestly ────────────
    //
    // Until this file existed, StubBridge::search dropped the query and the
    // limit and always resolved four empty lists, so every assertion about a
    // result ever reaching the page passed against nothing. If that regresses,
    // everything below it goes green for the wrong reason.

    function test_the_stub_reports_what_was_asked_and_answers_with_it() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(3), fakeAlbums(2),
                                      fakeArtists(1), fakePlaylists(1))
        typeInto(win.page, query)

        tryVerify(function () { return bridge.searchCountForTest() === 1 },
                  settleMs, "the page never dispatched a search")
        compare(bridge.lastSearchQueryForTest(), query,
                "the query the page sent is not the one that was typed")
        compare(bridge.lastSearchLimitForTest(), 20,
                "the page asks for 20 of each kind; the stub saw something else")

        tryVerify(function () { return win.page.tracks.length === 3 },
                  settleMs, "the canned tracks never reached the page")
        compare(win.page.albums.length, 2)
        compare(win.page.artists.length, 1)
        compare(win.page.playlists.length, 1)
    }

    // ── below the threshold ──────────────────────────────────────────────

    function test_one_character_searches_nothing_and_says_nothing() {
        var win = showPage()
        typeInto(win.page, shortQuery)
        wait(debounceMs + 200)

        compare(bridge.searchCountForTest(), 0,
                "one character dispatched a search")
        verify(saysSomethingContaining(win.page, "Search Tidal"),
               "below the threshold the page shows its empty state; it showed: "
               + visibleCopy(win.page))
        verify(!saysSomethingContaining(win.page, "No results"),
               "the page said \"No results\" for a query it never ran")
    }

    // ── D1: typed, but nothing has come back yet ─────────────────────────

    // Types `text` and holds the page to its silence for as long as the request
    // has not gone out.
    //
    // Polled, not slept through: the window closes on its own after the page's
    // 400ms debounce, and a case that slept a fraction of it would stop
    // asserting anything the first time a loaded box let the Timer fire early.
    // The first check below happens before any turn of the event loop, where
    // the Timer cannot have fired at all, and load widens the window rather
    // than narrowing it - so there is no machine on which this quietly passes
    // without having looked.
    function typeAndHoldToSilence(win, text, note) {
        var before = bridge.searchCountForTest()
        typeInto(win.page, text)

        var checks = 0
        while (bridge.searchCountForTest() === before && checks < 400) {
            var claim = outcomeClaim(resultsArea(win.page))
            compare(claim, "",
                    note + ": the page is already saying \"" + claim + "\" about a "
                    + "query it has not asked anything about yet")
            checks++
            wait(5)
        }
        verify(checks > 0,
               "the request went out before the pending window could be looked "
               + "at even once, so this case asserted nothing")
        compare(bridge.searchCountForTest(), before + 1,
                "the debounce never dispatched the search")
    }

    function test_nothing_is_claimed_while_the_debounce_is_still_waiting() {
        var win = showPage()
        typeAndHoldToSilence(win, query, "a fresh query, still being debounced")
    }

    // The same window, one keystroke later: a query that *has* been answered,
    // then extended. The old answer does not describe the new query.
    function test_a_further_keystroke_withdraws_the_previous_answer() {
        var win = showPage()
        typeInto(win.page, query)
        tryVerify(function () { return emptyClaim(resultsArea(win.page)) !== "" },
                  settleMs, "an empty reply never produced the no-results line")

        typeAndHoldToSilence(win, query + "x",
                             "a keystroke extending a query that had been answered")
    }

    // ── results ─────────────────────────────────────────────────────────

    function test_results_are_shown_and_nothing_claims_emptiness() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(3), fakeAlbums(2),
                                       fakeArtists(2), fakePlaylists(2))
        typeInto(win.page, query)

        tryVerify(function () { return saysSomethingContaining(win.page, "Erfundenes Lied 1") },
                  settleMs, "the tracks section never appeared")
        verify(saysSomethingContaining(win.page, "Erfundenes Album 1"),
               "the Albums section is missing: " + visibleCopy(win.page))
        verify(!saysSomethingContaining(win.page, "No results"),
               "the page claims no results while showing some")
    }

    // ── no results at all ───────────────────────────────────────────────

    function test_an_empty_reply_says_so_once_it_has_arrived() {
        var win = showPage()
        typeInto(win.page, query)

        tryVerify(function () { return bridge.searchCountForTest() === 1 },
                  settleMs, "the page never dispatched a search")
        tryVerify(function () { return saysSomethingContaining(win.page, "No results") },
                  settleMs, "an empty reply left the page silent: " + visibleCopy(win.page))
        verify(saysSomethingContaining(resultsArea(win.page), query),
               "the no-results line does not name the query it is about")
    }

    // ── D3: a type tab with no hits of its own kind ──────────────────────

    function test_a_tab_with_no_hits_of_its_kind_is_not_a_blank_pane_data() {
        return [
            { tag: "albums",    tab: 2 },
            { tag: "artists",   tab: 3 },
            { tag: "playlists", tab: 4 }
        ]
    }

    function test_a_tab_with_no_hits_of_its_kind_is_not_a_blank_pane(row) {
        var win = showPage()
        // Tracks matched; this tab's own kind did not.
        bridge.setSearchResultsForTest(fakeTracks(3), [], [], [])
        typeInto(win.page, query)
        tryVerify(function () { return win.page.tracks.length === 3 },
                  settleMs, "the canned tracks never reached the page")

        win.page.activeTab = row.tab
        wait(1)
        waitForRendering(win.contentItem, settleMs)

        verify(saysSomethingContaining(resultsArea(win.page), query),
               "the " + row.tag + " tab is a blank pane: every section is hidden "
               + "because this kind had no hits, and the no-results strip is "
               + "suppressed because another kind did. The results column is "
               + "showing: " + visibleCopy(resultsArea(win.page)))
        // ...and it must not claim there were no results when there were.
        verify(!saysSomethingContaining(win.page, "No results for"),
               "the " + row.tag + " tab says \"No results\" while " + row.tag
               + " were the only kind missing")
    }

    // The other half of that line: a type tab when the search found nothing
    // anywhere is about the search again. "No albums" would be true but it
    // would also suggest that another tab has something, and none has.
    function test_a_type_tab_with_nothing_anywhere_reports_the_search() {
        var win = showPage()
        typeInto(win.page, query)        // the stub answers four empty lists
        tryVerify(function () { return emptyClaim(resultsArea(win.page)) !== "" },
                  settleMs, "an empty reply never produced a line")

        win.page.activeTab = 2
        wait(1)
        waitForRendering(win.contentItem, settleMs)

        verify(saysSomethingContaining(resultsArea(win.page), "No results for"),
               "a tab with nothing anywhere reports the tab instead of the "
               + "search: " + visibleCopy(resultsArea(win.page)))
    }

    // The All tab in the same state is the control: tracks matched, so there is
    // nothing empty to report there.
    function test_the_all_tab_reports_nothing_empty_when_one_kind_matched() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(3), [], [], [])
        typeInto(win.page, query)
        tryVerify(function () { return win.page.tracks.length === 3 },
                  settleMs, "the canned tracks never reached the page")

        compare(win.page.activeTab, 0)
        compare(emptyClaim(win.page), "",
                "the All tab reported something empty while tracks matched")
    }

    // ── D4: a failed search ─────────────────────────────────────────────

    function test_a_failed_search_says_it_failed() {
        var win = showPage()
        bridge.setSearchErrorForTest("Host tidal.example is unreachable")
        typeInto(win.page, query)

        tryVerify(function () { return bridge.searchCountForTest() === 1 },
                  settleMs, "the page never dispatched a search")
        tryVerify(function () { return !win.page.loading }, settleMs,
                  "the page is still loading after the reply")
        verify(saysSomethingContaining(win.page, "Host tidal.example is unreachable"),
               "a failed search surfaced nothing at all - the page is showing: "
               + visibleCopy(win.page))
        verify(!saysSomethingContaining(win.page, "No results"),
               "a failed search was reported as an empty one: "
               + visibleCopy(win.page))
    }

    function test_a_failed_search_does_not_keep_the_previous_results() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(3), fakeAlbums(2), [], [])
        typeInto(win.page, query)
        tryVerify(function () { return saysSomethingContaining(win.page, "Erfundenes Lied 1") },
                  settleMs, "the first search never produced results")

        bridge.setSearchErrorForTest("Connection closed")
        typeInto(win.page, query + "er")
        tryVerify(function () { return bridge.searchCountForTest() === 2 },
                  settleMs, "the second search was never dispatched")
        tryVerify(function () { return !win.page.loading }, settleMs,
                  "the page is still loading after the reply")

        verify(!saysSomethingContaining(win.page, "Erfundenes Lied 1"),
               "the previous query's results stayed on screen under a query "
               + "whose search failed: " + visibleCopy(win.page))
        verify(saysSomethingContaining(win.page, "Connection closed"),
               "the failure was never surfaced: " + visibleCopy(win.page))
    }

    // A search that succeeds after one failed clears the failure.
    function test_a_successful_search_clears_an_earlier_failure() {
        var win = showPage()
        bridge.setSearchErrorForTest("Connection closed")
        typeInto(win.page, query)
        tryVerify(function () { return saysSomethingContaining(win.page, "Connection closed") },
                  settleMs, "the failure was never surfaced")

        bridge.setSearchResultsForTest(fakeTracks(2), [], [], [])   // clears the error
        // The failure is withdrawn the moment the query changes, not only once
        // the replacement answer lands: it described the query before this one.
        typeAndHoldToSilence(win, query + "er",
                             "a retry of a query whose search had failed")
        tryVerify(function () { return saysSomethingContaining(win.page, "Erfundenes Lied 1") },
                  settleMs, "the retry never produced results")
        verify(!saysSomethingContaining(win.page, "Connection closed"),
               "the old failure is still on screen: " + visibleCopy(win.page))
    }

    // ── D2: the field's focus across a visit ────────────────────────────

    function test_the_field_has_focus_on_the_first_visit() {
        var win = showApp()
        win.navigate("search")
        waitForRendering(win.contentItem, settleMs)

        var bar = searchBarIn(win.contentItem)
        tryVerify(function () { return bar.focused }, settleMs,
                  "the search field does not have focus on arriving at the page")
    }

    function test_the_field_still_has_focus_on_the_second_visit() {
        var win = showApp()
        win.navigate("search")
        waitForRendering(win.contentItem, settleMs)
        var bar = searchBarIn(win.contentItem)
        tryVerify(function () { return bar.focused }, settleMs,
                  "the search field does not have focus on the first visit")

        win.navigate("home")
        waitForRendering(win.contentItem, settleMs)
        verify(!bar.focused, "leaving the page did not release the field")

        win.navigate("search")
        waitForRendering(win.contentItem, settleMs)
        tryVerify(function () { return bar.focused }, settleMs,
                  "the search field lost focus for good: leaving the page clears "
                  + "the only focus item in the Loader's scope and nothing puts "
                  + "it back, so from the second visit on typing goes nowhere")
    }

    // The symptom as the user meets it, over the route they use: Ctrl+2, away,
    // Ctrl+2 again. What is asserted is where this window *would* send a
    // keystroke, using Main.qml's own predicate for it - the one the bare-key
    // shortcuts are gated on, so it is also the app's definition of "the field
    // has the keyboard".
    //
    // Not an actual letter: QuickTestEvent posts keys to the test harness's own
    // window and there is no way to aim one at this window instead. That is
    // also why the three Ctrl chords below work at all - they are
    // Qt.ApplicationShortcut and fire whichever window the event reached - and
    // why a bare letter would prove nothing either way.
    function test_the_window_would_send_typing_to_the_field_on_the_second_visit() {
        var win = showApp()
        keyClick(Qt.Key_2, Qt.ControlModifier)
        tryVerify(function () { return win.currentPage === "search" }, settleMs,
                  "Ctrl+2 did not navigate to the search page")
        waitForRendering(win.contentItem, settleMs)

        keyClick(Qt.Key_1, Qt.ControlModifier)
        tryVerify(function () { return win.currentPage === "home" }, settleMs,
                  "Ctrl+1 did not navigate home")
        keyClick(Qt.Key_2, Qt.ControlModifier)
        tryVerify(function () { return win.currentPage === "search" }, settleMs,
                  "Ctrl+2 did not navigate back to the search page")
        waitForRendering(win.contentItem, settleMs)

        tryVerify(function () { return win.isTypingContext(win.activeFocusItem) }, settleMs,
                  "after Ctrl+2 a second time the keyboard belongs to "
                  + win.activeFocusItem + ", which is not a text field: the page "
                  + "is up and typing goes nowhere")
    }
}
