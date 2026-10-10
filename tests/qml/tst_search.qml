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
        auth.setUsernameForTest("robin")
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

    // ════════════════════════════════════════════════════════════════════
    //  The four features that landed on this page after the defect fixes.
    // ════════════════════════════════════════════════════════════════════

    // ── helpers the new cases share ──────────────────────────────────────

    // The Flickable inside the results ScrollView: what "the bottom of the
    // page" means, and the thing paging is driven off.
    function scrollerIn(page) {
        var sv = findByName(page, "searchScroll")
        verify(sv, "the page has no results scroll view")
        verify(sv.contentItem, "the scroll view has no flickable")
        return sv.contentItem
    }

    function scrollToBottom(page) {
        var f = scrollerIn(page)
        f.contentY = Math.max(0, f.contentHeight - f.height)
        return f
    }

    // Types `q` and waits until a reply for it has landed.
    function search(win, q) {
        typeInto(win.page, q)
        tryVerify(function () { return win.page.repliedFor === q },
                  settleMs, "no reply for \"" + q + "\" ever landed")
    }

    function tracksWithTitles(titles) {
        var out = []
        for (var i = 0; i < titles.length; ++i)
            out.push({ id: 9100 + i, title: titles[i], artists: "Beispielkapelle",
                       artistId: 7001, artistList: [{ id: 7001, name: "Beispielkapelle" }],
                       albumTitle: "Erfundenes Album", albumId: 8001,
                       coverUrl: "", coverUrl80: "", duration: 200, durationStr: "3:20" })
        return out
    }

    function albumsWithTitles(titles) {
        var out = []
        for (var i = 0; i < titles.length; ++i)
            out.push({ id: 8100 + i, title: titles[i], artists: "Beispielkapelle", coverUrl: "" })
        return out
    }

    function artistsWithNames(names) {
        var out = []
        for (var i = 0; i < names.length; ++i)
            out.push({ id: 7100 + i, name: names[i], coverUrl: "" })
        return out
    }

    function playlistsWithTitles(titles) {
        var out = []
        for (var i = 0; i < titles.length; ++i)
            out.push({ uuid: "erfunden-pl-" + i, title: titles[i], numTracks: 9,
                       coverUrl: "", type: "EDITORIAL" })
        return out
    }

    function fakeMixes(n) {
        var out = []
        for (var i = 1; i <= n; ++i)
            out.push({ id: "erfundener-mix-" + i, title: "Erfundener Mix " + i,
                       subtitle: "placeholder", coverUrl: "", mixType: "DAILY_MIX" })
        return out
    }

    function mixesWithTitles(titles) {
        var out = []
        for (var i = 0; i < titles.length; ++i)
            out.push({ id: "erfundener-mix-" + i, title: titles[i],
                       subtitle: "placeholder", coverUrl: "", mixType: "ARTIST_MIX" })
        return out
    }

    // ════════════════════════════════════════════════════════════════════
    //  1. Load more as you scroll
    // ════════════════════════════════════════════════════════════════════
    //
    // Before this the page asked for 20 of each kind, sent no offset at all,
    // and the bridge dropped the four totals the server had already answered
    // with - so twenty was the catalogue, and nothing could even have known
    // otherwise.
    //
    // The stub pages: each canned list is sliced [offset, offset+limit) and
    // the five totals report the whole list, so a second request really does
    // come back with different rows. Without that every case below would go
    // green against page one arriving twice.

    function test_the_first_page_asks_from_the_top() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(45), [], [], [])
        search(win, query)

        compare(bridge.lastSearchOffsetForTest(), 0,
                "the first page of a fresh search is not offset 0")
        compare(win.page.tracks.length, 20,
                "the first page is not one page: the stub holds 45 tracks and "
                + "the page asked for 20")
    }

    function test_the_bottom_of_a_type_tab_asks_for_the_next_page() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(45), [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        var before = bridge.searchCountForTest()
        scrollToBottom(win.page)

        tryVerify(function () { return bridge.searchCountForTest() > before },
                  settleMs, "scrolling to the bottom of the Tracks tab asked for "
                  + "nothing: the page holds " + win.page.tracks.length
                  + " of 45 tracks and stopped there")
        compare(bridge.lastSearchOffsetForTest(), 20,
                "the next page was asked for from the wrong row")
        tryVerify(function () { return win.page.tracks.length === 40 },
                  settleMs, "the second page was asked for but never appended: "
                  + "the page still holds " + win.page.tracks.length)
        verify(saysSomethingContaining(win.page, "Erfundenes Lied 40"),
               "the appended rows are not on screen")
    }

    // The end has to be knowable, which is the half the dropped totals cost:
    // a last page that happens to be full looks exactly like a full page with
    // more behind it.
    function test_the_end_of_a_kind_stops_the_asking() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(45), [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        // Two more pages: 20 + 20 + 5.
        for (var round = 0; round < 6; ++round) {
            scrollToBottom(win.page)
            wait(60)
            if (win.page.tracks.length === 45) break
        }
        compare(win.page.tracks.length, 45,
                "paging never reached the end of the 45 canned tracks")

        var settled = bridge.searchCountForTest()
        scrollToBottom(win.page)
        wait(200)
        compare(bridge.searchCountForTest(), settled,
                "the page is still asking for more after the last row: every "
                + "pixel of scroll past the end is another request")
        verify(saysSomethingContaining(win.page, "End of results"),
               "nothing says the list has ended: " + visibleCopy(resultsArea(win.page)))
    }

    // The case the dropped totals cost outright: a last page that happens to
    // be exactly full. Nothing about the page itself says it is the last one -
    // only the total does.
    function test_a_last_page_that_is_exactly_full_is_still_the_last() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(40), [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        scrollToBottom(win.page)
        tryVerify(function () { return win.page.tracks.length === 40 },
                  settleMs, "the second page never arrived")
        wait(250)        // long enough for a third request to have gone out

        // Two requests and no more: the first page and the second. A third
        // would come back empty and end the run just as quietly, so counting
        // requests is the only way to see the difference - and the count is
        // taken from the start rather than from here, because the spurious
        // third request happens before anything a later snapshot could see.
        compare(bridge.searchCountForTest(), 2,
                "the page asked for a page of a kind it already has all 40 "
                + "rows of: a full last page is only distinguishable from a "
                + "full page with more behind it by the total the reply "
                + "carries, and the reply's totals are what the bridge used "
                + "to throw away")
        verify(!win.page._more[1], "the Tracks kind still thinks it has more")
    }

    // A short result set is not an end worth announcing.
    function test_a_single_short_page_says_nothing_about_an_end() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(3), [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        verify(!saysSomethingContaining(win.page, "End of results"),
               "three results were announced as the end of a list")
    }

    // Tidal repeats rows across pages whenever the result set shifts under a
    // query between two requests, and a repeated row drawn twice is the most
    // visible way a paged list can be wrong.
    function test_a_row_the_server_repeats_is_not_shown_twice() {
        var win = showPage()
        var tracks = fakeTracks(40)
        // The first row of page two is the first row of page one again.
        tracks[20] = tracks[0]
        bridge.setSearchResultsForTest(tracks, [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        scrollToBottom(win.page)
        tryVerify(function () { return win.page.tracks.length >= 39 },
                  settleMs, "the second page never arrived")
        compare(win.page.tracks.length, 39,
                "the row the server sent on both pages was appended a second time")

        var ids = {}
        for (var i = 0; i < win.page.tracks.length; ++i) {
            var id = "" + win.page.tracks[i].id
            compare(ids[id], undefined, "track id " + id + " is in the list twice")
            ids[id] = true
        }
    }

    // ...and the *offset* must still count what the server sent, not what
    // survived the dedup, or the dropped row is re-requested forever.
    function test_the_offset_counts_what_the_server_sent_not_what_was_kept() {
        var win = showPage()
        var tracks = fakeTracks(40)
        tracks[20] = tracks[0]
        bridge.setSearchResultsForTest(tracks, [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        scrollToBottom(win.page)
        tryVerify(function () { return bridge.lastSearchOffsetForTest() === 20 },
                  settleMs, "the second page was asked for from the wrong row")
        scrollToBottom(win.page)
        wait(150)
        verify(bridge.lastSearchOffsetForTest() !== 39,
               "the offset was taken from the deduplicated list, so the page "
               + "will keep asking for rows it has already dropped")
    }

    function test_the_scroll_position_survives_an_append() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(45), [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        var f = scrollToBottom(win.page)
        var before = f.contentY
        verify(before > 0, "the Tracks tab did not scroll at all, so this case "
                           + "could not see a jump either way")

        tryVerify(function () { return win.page.tracks.length === 40 },
                  settleMs, "the second page never arrived")
        waitForRendering(win.contentItem, settleMs)
        verify(f.contentY >= before - 1,
               "the view jumped back up on the append: it was at " + before
               + " and is at " + f.contentY)
    }

    // The All tab is a summary of five kinds at once; there is no one kind for
    // its bottom to be the bottom of, and a horizontal tile row has no bottom
    // at all - so it does not page.
    function test_the_all_tab_does_not_page() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(45), fakeAlbums(45), [], [])
        search(win, query)
        compare(win.page.activeTab, 0)

        var before = bridge.searchCountForTest()
        scrollToBottom(win.page)
        wait(250)
        compare(bridge.searchCountForTest(), before,
                "the All tab asked for another page; it is an overview and the "
                + "tile rows it shows do not scroll downwards")
    }

    // A page that is still in flight when the query changes describes a search
    // the user has left. It is dropped by the generation counter the defect
    // fixes already introduced - not by a second mechanism.
    function test_a_page_in_flight_is_dropped_when_the_query_changes() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(45), [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        bridge.setDeferSearchForTest(true)
        scrollToBottom(win.page)
        tryVerify(function () { return bridge.pendingSearchCountForTest() === 1 },
                  settleMs, "the next page was never asked for")

        // The user types on. The new query answers at once.
        bridge.setDeferSearchForTest(false)
        bridge.setSearchResultsForTest(fakeTracks(2), [], [], [])
        search(win, query + "er")
        compare(win.page.tracks.length, 2)

        // ...and the page of the *old* query finally comes back.
        bridge.flushSearchRepliesForTest()
        wait(50)
        compare(win.page.tracks.length, 2,
                "a page of the previous query was appended under the new one")
        compare(win.page.repliedFor, query + "er")
    }

    // Two whole searches in flight, answered out of order.
    function test_a_late_reply_for_an_abandoned_query_is_dropped() {
        var win = showPage()
        bridge.setDeferSearchForTest(true)
        bridge.setSearchResultsForTest(fakeTracks(7), [], [], [])
        typeInto(win.page, query)
        tryVerify(function () { return bridge.pendingSearchCountForTest() === 1 },
                  settleMs, "the first search was never dispatched")

        bridge.setSearchResultsForTest(fakeTracks(2), [], [], [])
        typeInto(win.page, query + "er")
        tryVerify(function () { return bridge.pendingSearchCountForTest() === 2 },
                  settleMs, "the second search was never dispatched")

        bridge.flushSearchRepliesForTest()   // oldest first
        wait(50)
        compare(win.page.tracks.length, 2,
                "the abandoned query's reply overwrote the current one's")
        compare(win.page.repliedFor, query + "er")
    }

    // A page that fails keeps what is already on screen: those rows are still
    // a true answer to this query. What stops is the asking.
    function test_a_failed_page_keeps_the_rows_and_stops_asking() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(45), [], [], [])
        search(win, query)
        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)

        bridge.setSearchErrorForTest("Connection closed")
        scrollToBottom(win.page)
        tryVerify(function () { return saysSomethingContaining(win.page, "Connection closed") },
                  settleMs, "a failed page said nothing: " + visibleCopy(win.page))
        compare(win.page.tracks.length, 20,
                "a failed page threw away the rows that had already arrived")

        var settled = bridge.searchCountForTest()
        scrollToBottom(win.page)
        wait(200)
        compare(bridge.searchCountForTest(), settled,
                "the page retries the failed page on every pixel of scroll")
    }

    // ════════════════════════════════════════════════════════════════════
    //  2. Recent searches, clearable
    // ════════════════════════════════════════════════════════════════════
    //
    // Nothing in this file is a query anyone really ran: the stub keeps the
    // list in memory and never touches QSettings, and the strings below are
    // invented. A test must not read - or append to - a person's search
    // history.

    function test_the_empty_state_lists_recent_searches() {
        var win = showPage()
        bridge.setRecentSearchesForTest(["grubenlampe", "beispielkapelle"])
        waitForRendering(win.contentItem, settleMs)

        verify(saysSomethingContaining(win.page, "Recent searches"),
               "the empty state does not offer the recent queries: "
               + visibleCopy(win.page))
        verify(saysSomethingContaining(win.page, "beispielkapelle"),
               "a remembered query is not listed")
        verify(!saysSomethingContaining(win.page, "Find tracks, albums"),
               "the static illustration is still up alongside the list")
    }

    // ...and the illustration is what is there before anything was searched.
    function test_the_illustration_stays_when_nothing_was_searched_yet() {
        var win = showPage()
        compare(bridge.recentSearches().length, 0)
        verify(saysSomethingContaining(win.page, "Search Tidal"),
               "a first-run empty state has nothing to list and must still say "
               + "something: " + visibleCopy(win.page))
    }

    function test_a_query_is_remembered_once_it_has_found_something() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(2), [], [], [])
        search(win, query)

        compare(bridge.recentSearches(), [query],
                "a search that found results was not remembered")
    }

    function test_a_query_that_found_nothing_is_not_remembered() {
        var win = showPage()
        search(win, query)          // the stub answers five empty lists
        compare(bridge.recentSearches().length, 0,
                "a query that matched nothing was put in the list; typing "
                + "mistakes would fill it")
    }

    // The page searches as you type, so a word typed with pauses in it is
    // several searches. It is one entry.
    function test_one_word_typed_with_pauses_leaves_one_entry() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(2), [], [], [])
        search(win, "gru")
        search(win, "grube")
        search(win, "grubenlampe")

        compare(bridge.recentSearches(), ["grubenlampe"],
                "every prefix of one search was remembered separately")
    }

    // ...but a different query does not swallow the one before it.
    function test_an_unrelated_query_does_not_replace_the_previous_one() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(2), [], [], [])
        search(win, "grubenlampe")
        search(win, "beispielkapelle")

        compare(bridge.recentSearches(), ["beispielkapelle", "grubenlampe"])
    }

    function test_the_list_is_capped() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(2), [], [], [])
        // Nine unrelated queries, so none of them collapses into another.
        var words = ["alpha", "bravo", "charlie", "delta", "echo",
                     "foxtrot", "golf", "hotel", "india"]
        for (var i = 0; i < words.length; ++i) search(win, words[i])

        compare(bridge.recentSearches().length, 8,
                "the list grew past its cap")
        compare(bridge.recentSearches()[0], "india")
        verify(bridge.recentSearches().indexOf("alpha") < 0,
               "the oldest query was not the one dropped")
    }

    function test_a_recent_search_can_be_removed_on_its_own() {
        var win = showPage()
        bridge.setRecentSearchesForTest(["grubenlampe", "beispielkapelle"])
        waitForRendering(win.contentItem, settleMs)

        var rows = findAllByName(win.page, "searchRecentRow")
        compare(rows.length, 2, "the two remembered queries are not two rows")
        var cross = findByName(rows[0], "searchRecentRemove")
        verify(cross, "a remembered query has no way to be removed")
        mouseClick(cross)
        waitForRendering(win.contentItem, settleMs)

        compare(bridge.recentSearches(), ["beispielkapelle"],
                "removing one row removed the wrong thing")
        // And it must not have run the query it just deleted.
        compare(bridge.searchCountForTest(), 0,
                "removing a remembered query also ran it")
    }

    function test_clear_all_empties_the_list() {
        var win = showPage()
        bridge.setRecentSearchesForTest(["grubenlampe", "beispielkapelle"])
        waitForRendering(win.contentItem, settleMs)

        var clear = findByName(win.page, "searchRecentsClearAll")
        verify(clear, "the list has no clear-all")
        mouseClick(clear)
        waitForRendering(win.contentItem, settleMs)

        compare(bridge.recentSearches().length, 0, "clear all left something behind")
        verify(saysSomethingContaining(win.page, "Search Tidal"),
               "with the list cleared the first-run empty state is what is left: "
               + visibleCopy(win.page))
    }

    function test_clicking_a_remembered_query_runs_it() {
        var win = showPage()
        bridge.setRecentSearchesForTest(["grubenlampe"])
        bridge.setSearchResultsForTest(fakeTracks(3), [], [], [])
        waitForRendering(win.contentItem, settleMs)

        var rows = findAllByName(win.page, "searchRecentRow")
        compare(rows.length, 1)
        mouseClick(rows[0])

        tryVerify(function () { return bridge.searchCountForTest() === 1 },
                  settleMs, "clicking a remembered query ran nothing")
        compare(bridge.lastSearchQueryForTest(), "grubenlampe")
        tryVerify(function () { return win.page.tracks.length === 3 },
                  settleMs, "the results of the remembered query never arrived")
    }

    // ════════════════════════════════════════════════════════════════════
    //  3. Mixes in search
    // ════════════════════════════════════════════════════════════════════
    //
    // The video filter itself is proved in tests/tst_mixes.cpp, against the
    // captured mixType values: a video mix is dropped in
    // TidalClient::parseSearchMixes and so never reaches QML at all. What is
    // here is the page's half - a sixth chip, a sixth section, a sixth tab.

    function test_there_is_a_mixes_chip() {
        var win = showPage()
        typeInto(win.page, query)
        waitForRendering(win.contentItem, settleMs)

        var tabs = findByName(win.page, "searchTabsRow")
        verify(tabs, "the tab row is missing")
        verify(saysSomethingContaining(tabs, "Mixes"),
               "there is no Mixes chip: " + visibleCopy(tabs))
    }

    function test_mixes_are_shown_among_the_results() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(2), [], [], [])
        bridge.setSearchMixesForTest(fakeMixes(3))
        search(win, query)

        compare(win.page.mixes.length, 3, "the mixes never reached the page")
        verify(saysSomethingContaining(resultsArea(win.page), "Erfundener Mix 1"),
               "the mixes section is not on screen: "
               + visibleCopy(resultsArea(win.page)))
    }

    function test_the_mixes_tab_with_no_mixes_is_not_a_blank_pane() {
        var win = showPage()
        bridge.setSearchResultsForTest(fakeTracks(3), [], [], [])
        search(win, query)

        win.page.activeTab = 5
        waitForRendering(win.contentItem, settleMs)
        verify(saysSomethingContaining(resultsArea(win.page), "No mixes for"),
               "the Mixes tab with no mixes of its own says nothing: "
               + visibleCopy(resultsArea(win.page)))
    }

    function test_the_mixes_tab_pages_like_the_others() {
        var win = showPage()
        bridge.setSearchResultsForTest([], [], [], [])
        bridge.setSearchMixesForTest(fakeMixes(45))
        search(win, query)
        compare(win.page.mixes.length, 20)

        win.page.activeTab = 5
        waitForRendering(win.contentItem, settleMs)
        scrollToBottom(win.page)
        tryVerify(function () { return win.page.mixes.length === 40 },
                  settleMs, "the Mixes tab did not page: it holds "
                  + win.page.mixes.length + " of 45")
    }

    // ════════════════════════════════════════════════════════════════════
    //  4. The section order follows the query
    // ════════════════════════════════════════════════════════════════════
    //
    // The rule, as agreed with the user and written down in HANDOFF.md under
    // "The rule, as agreed": fold the query the way LibraryIndex folds, score
    // each kind's best hit's *name* (exact 400, prefix 300, word-start 200,
    // mid-word 100, plus up to 40 for coverage, minus one point per row the
    // hit sits below the top), and let the best-scoring kind lead - but only
    // if it is a full tier (100) clear of the runner-up.
    //
    // ── about the names below ──────────────────────────────────────────
    //
    // The six worked examples are the specification: they were put to the user
    // in those words and the rule was chosen on them, so they are reproduced
    // verbatim rather than restated with placeholder names - a case built on
    // different names would not be the case that was agreed. The names are
    // public catalogue names out of HANDOFF.md. Nothing here comes from the
    // user's own library or search history, and every id is invented.

    // The catalogue the four "kendrick"-family cases share: one artist, their
    // songs, their albums, and the editorial playlist that names them. Held
    // fixed across those cases on purpose - the examples differ in the query,
    // not in what the server answered.
    function kendrickResults() {
        return {
            tracks:    tracksWithTitles(["Alright", "Money Trees", "Swimming Pools"]),
            albums:    albumsWithTitles(["To Pimp a Butterfly", "Section.80"]),
            artists:   artistsWithNames(["Kendrick Lamar"]),
            playlists: playlistsWithTitles(["This Is Kendrick Lamar", "Rap Caviar"]),
            mixes:     []
        }
    }

    function feed(r) {
        bridge.setSearchResultsForTest(r.tracks, r.albums, r.artists, r.playlists)
        bridge.setSearchMixesForTest(r.mixes)
    }

    // Section order, as the page decided it, named rather than numbered so a
    // failure message reads.
    readonly property var kindNames: ["", "Tracks", "Albums", "Artists",
                                      "Playlists", "Mixes"]

    function orderNames(page) {
        var out = []
        for (var i = 0; i < page.sectionOrder.length; ++i)
            out.push(kindNames[page.sectionOrder[i]])
        return out
    }

    function test_the_section_order_follows_the_query_data() {
        return [
            // `kendrick` -> Artists. A prefix hit at index 0 with high
            // coverage of "Kendrick Lamar" (300 + 22 = 322) against the
            // playlist that merely contains the name (200 + 14 = 214); no
            // track is *titled* "kendrick", so Tracks score nothing.
            { tag: "an artist's name",  q: "kendrick",   lead: "Artists" },
            // `alright` -> Tracks. An exact title: 400 + 40.
            { tag: "an exact title",    q: "alright",    lead: "Tracks" },
            // A full album title -> Albums, exact, for the same reason.
            { tag: "an exact album",    q: "to pimp a butterfly", lead: "Albums" },
            // `kendrick alright` -> default, and this is the case that proves
            // the rule: matching names only means no artist name matches the
            // whole query and no track is titled that, so every kind scores 0
            // and Tidal's own ranking is what the user sees.
            { tag: "two things at once", q: "kendrick alright", lead: "" }
        ]
    }

    function test_the_section_order_follows_the_query(row) {
        var win = showPage()
        feed(kendrickResults())
        search(win, row.q)

        var got = orderNames(win.page)
        if (row.lead === "") {
            compare(got, ["Tracks", "Albums", "Artists", "Playlists", "Mixes"],
                    "\"" + row.q + "\" moved the sections when no kind wins by a "
                    + "tier; the page must hold still")
        } else {
            compare(got[0], row.lead,
                    "\"" + row.q + "\" should lead with " + row.lead
                    + "; the order came out " + got.join(" -> "))
            // Only the leader moves. Everything else keeps its default order.
            var rest = got.slice(1)
            var expected = ["Tracks", "Albums", "Artists", "Playlists", "Mixes"]
                .filter(function (k) { return k !== row.lead })
            compare(rest, expected,
                    "the kinds behind the leader were reshuffled too")
        }
    }

    // `jazz` -> default: playlists, artists and tracks all have plausible hits
    // and none wins by a tier (317 / 316 / 310 / 210), so nothing moves.
    function test_an_ambiguous_query_leaves_the_order_alone() {
        var win = showPage()
        feed({
            tracks:    tracksWithTitles(["Jazz Hands"]),
            albums:    albumsWithTitles(["Jazz Essentials"]),
            artists:   artistsWithNames(["Jazzanova"]),
            playlists: playlistsWithTitles(["Late Night Jazz"]),
            mixes:     []
        })
        search(win, "jazz")

        compare(orderNames(win.page),
                ["Tracks", "Albums", "Artists", "Playlists", "Mixes"],
                "an ambiguous query reordered the page")
    }

    // `kend` -> default. The premise of the example is that a half-typed query
    // is not decisive yet, which is true the moment the shorter query pulls in
    // a competing short name: "Kendo" is 300 + 32 = 332 against the artist's
    // 300 + 11 = 311, a gap of 21.
    //
    // See the companion case below: against the *same* result set as
    // `kendrick`, this query does reorder.
    function test_a_half_typed_query_over_an_ambiguous_set_holds_still() {
        var win = showPage()
        feed({
            tracks:    tracksWithTitles(["Kendo", "Bend"]),
            albums:    albumsWithTitles(["Kendal Mint"]),
            artists:   artistsWithNames(["Kendrick Lamar"]),
            playlists: playlistsWithTitles(["This Is Kendrick Lamar"]),
            mixes:     []
        })
        search(win, "kend")

        compare(orderNames(win.page),
                ["Tracks", "Albums", "Artists", "Playlists", "Mixes"],
                "a half-typed query jumped the page around")
    }

    // ── where the agreed rule and the agreed example disagree ──────────
    //
    // The sixth worked example says `kend` -> default: "nothing decisive yet,
    // so the page does not jump while the user is still typing." Against a
    // genuinely ambiguous result set that is what happens, which is the case
    // above. Against the *same* result set as `kendrick` it is not: the rule
    // promotes Artists at four characters too.
    //
    // The arithmetic, which is the rule as agreed and not a deviation from it:
    //
    //   kendrick   artists "Kendrick Lamar"         300 + 22 = 322
    //              playlists "This Is Kendrick Lamar" 200 + 14 = 214   gap 108
    //   kend       artists                          300 + 11 = 311
    //              playlists                        200 +  7 = 207   gap 104
    //
    // Both clear the 100 threshold, and they clear it for a structural reason:
    // when the leader and the runner-up are in *adjacent* tiers the gap is
    // 100 + (leader coverage - runner-up coverage), so "a full tier clear"
    // comes down to "a higher tier, and at least as much coverage". The
    // shorter name has more coverage almost by definition, so an artist whose
    // name begins with the query beats a playlist that merely contains it from
    // the fourth character on.
    //
    // Recorded as the behaviour rather than quietly fixed: the threshold was
    // the user's own choice and the example was agreed with them, so the two
    // have to be put back to them together. If `kend` really must hold still
    // against this result set the threshold has to be more than one tier, and
    // that is a decision, not a bug fix.
    function test_a_half_typed_query_over_the_same_set_does_reorder() {
        var win = showPage()
        feed(kendrickResults())
        search(win, "kend")

        compare(orderNames(win.page)[0], "Artists",
                "this case records a known departure from the rule's own "
                + "example (`kend` -> default order). If the order is the "
                + "default now, the rule changed and this case is the one "
                + "to delete.")
        compare(win.page.scoreKind(3, win.page.artists, "kend"), 311)
        compare(win.page.scoreKind(4, win.page.playlists, "kend"), 207)
    }

    // The leading section earns a few more rows than it would in third place.
    // Tracks is the only section with a cap, so it is the whole of this.
    function test_the_leading_tracks_section_shows_more_rows() {
        var win = showPage()
        var titles = ["Alright"]
        for (var i = 2; i <= 12; ++i) titles.push("Erfundenes Lied " + i)

        feed({ tracks: tracksWithTitles(titles),
               albums: albumsWithTitles(["To Pimp a Butterfly"]),
               artists: artistsWithNames(["Kendrick Lamar"]),
               playlists: [], mixes: [] })

        search(win, "kendrick")           // Artists lead; Tracks are third
        compare(win.page.sectionOrder[0], 3)
        compare(win.page.allTabTracksCap, 5,
                "a section that is not leading shows its usual five rows")
        verify(!saysSomethingContaining(resultsArea(win.page), "Erfundenes Lied 7"),
               "a non-leading Tracks section is showing more than five rows")

        search(win, "alright")            // now Tracks lead
        compare(win.page.sectionOrder[0], 1)
        compare(win.page.allTabTracksCap, 8,
                "the leading Tracks section shows no more rows than it would "
                + "in third place")
        verify(saysSomethingContaining(resultsArea(win.page), "Erfundenes Lied 7"),
               "the leading Tracks section did not grow: "
               + visibleCopy(resultsArea(win.page)))
    }

    // The decision is only as good as the layout that carries it: a Loader
    // inside a layout overwrites a `height` binding on the item it holds, and
    // HorizontalSection binds exactly that - so a section can be in the right
    // slot and still be nought pixels tall.
    function test_the_leading_section_is_really_drawn_first() {
        var win = showPage()
        feed(kendrickResults())
        search(win, "kendrick")
        waitForRendering(win.contentItem, settleMs)

        var headings = headingOrder(win.page)
        compare(headings[0], "Artists",
                "the Artists section leads the order but is drawn at "
                + headings.indexOf("Artists") + ": the page reads "
                + headings.join(" -> "))
        verify(headings.length >= 4,
               "sections went missing from the page: " + headings.join(" -> "))
    }

    // The section headings, top to bottom, as they are actually painted.
    function headingOrder(page) {
        var area = resultsArea(page)
        var names = ["Tracks", "Albums", "Artists", "Playlists", "Mixes"]
        var found = []
        for (var i = 0; i < names.length; ++i) {
            var hits = visibleTextsSaying(area, names[i])
            for (var j = 0; j < hits.length; ++j) {
                if (hits[j].text !== names[i]) continue
                found.push({ name: names[i],
                             y: hits[j].mapToItem(area, 0, 0).y })
                break
            }
        }
        found.sort(function (a, b) { return a.y - b.y })
        return found.map(function (f) { return f.name })
    }

    // The order is decided from the reply and never touched again, so neither
    // an append nor a keystroke can move the page under the user.
    function test_an_append_does_not_reorder_the_page() {
        var win = showPage()
        var titles = ["Alright"]
        for (var i = 2; i <= 45; ++i) titles.push("Kendrick Erfundenes Lied " + i)
        feed({ tracks: tracksWithTitles(titles), albums: [],
               artists: artistsWithNames(["Kendrick Lamar"]),
               playlists: [], mixes: [] })
        search(win, "alright")
        compare(orderNames(win.page)[0], "Tracks")

        win.page.activeTab = 1
        waitForRendering(win.contentItem, settleMs)
        scrollToBottom(win.page)
        tryVerify(function () { return win.page.tracks.length === 40 },
                  settleMs, "the second page never arrived")

        compare(orderNames(win.page)[0], "Tracks",
                "a page of results reordered the sections under the user")
    }

    // And a query below the threshold puts the default back, rather than
    // leaving the last search's order standing over an empty page.
    function test_clearing_the_query_restores_the_default_order() {
        var win = showPage()
        feed(kendrickResults())
        search(win, "kendrick")
        compare(orderNames(win.page)[0], "Artists")

        typeInto(win.page, "k")
        compare(orderNames(win.page),
                ["Tracks", "Albums", "Artists", "Playlists", "Mixes"],
                "the previous query's order outlived the query")
    }

    // Folding, as LibraryIndex folds: the accents and the case come off, so
    // an ASCII keyboard reaches an accented name.
    function test_an_accented_name_is_reached_without_the_accent() {
        var win = showPage()
        feed({ tracks: tracksWithTitles(["Ein Lied"]),
               albums: [], artists: artistsWithNames(["Bjork Jóga"]),
               playlists: [], mixes: [] })
        search(win, "joga")

        compare(orderNames(win.page)[0], "Artists",
                "\"joga\" did not reach \"Jóga\": the fold is not stripping "
                + "accents the way LibraryIndex does")
    }

    // Two kinds that score the same are a tie, and a tie is a gap of zero, so
    // nothing moves. Two artists and two tracks with the same exact-match name
    // is the cleanest form of it.
    function test_a_tie_between_two_kinds_changes_nothing() {
        var win = showPage()
        feed({ tracks: tracksWithTitles(["Nebelwerk"]),
               albums: [], artists: artistsWithNames(["Nebelwerk"]),
               playlists: [], mixes: [] })
        search(win, "nebelwerk")

        compare(orderNames(win.page),
                ["Tracks", "Albums", "Artists", "Playlists", "Mixes"],
                "two kinds matching equally well still moved the page")
    }

    // The index penalty: the same match further down its own kind scores less,
    // which is what separates two kinds that would otherwise tie.
    function test_the_same_match_deeper_in_its_kind_scores_less() {
        var win = showPage()
        var deep = []
        for (var i = 0; i < 9; ++i) deep.push("Fuellstueck " + i)
        deep.push("Nebelwerk")        // index 9
        feed({ tracks: tracksWithTitles(["Nebelwerk"]),     // index 0
               albums: [], artists: artistsWithNames(deep),
               playlists: [], mixes: [] })
        search(win, "nebelwerk")

        // 440 against 440 - 9 = 431. Still not a tier, so the order holds; the
        // point is only that the two are no longer equal.
        compare(orderNames(win.page),
                ["Tracks", "Albums", "Artists", "Playlists", "Mixes"])
        compare(win.page.scoreKind(1, [{ title: "Nebelwerk" }], "nebelwerk"), 440)
        compare(win.page.scoreKind(3, deep.map(function (n) { return { name: n } }),
                                   "nebelwerk"), 431,
                "a hit nine rows down its own kind paid no index penalty")
    }

    // Names only, never a track's artist. This is what makes the rule general
    // rather than an artist hack, and the whole of why `kendrick alright`
    // comes out as the default order.
    function test_a_tracks_artist_is_never_scored() {
        var win = showPage()
        feed({ tracks: tracksWithTitles(["Ein Lied"]),   // artists: Beispielkapelle
               albums: [], artists: [], playlists: [], mixes: [] })
        search(win, "beispielkapelle")

        compare(orderNames(win.page),
                ["Tracks", "Albums", "Artists", "Playlists", "Mixes"],
                "Tracks led on a query that matches only the artist column, "
                + "which is the widening LibraryIndex refuses")
        compare(win.page.scoreKind(1, win.page.tracks, "beispielkapelle"), 0,
                "a track scored on something other than its title")
    }

    // ════════════════════════════════════════════════════════════════════
    //  5. The tab highlight is one pill, and it lands on the chip
    // ════════════════════════════════════════════════════════════════════
    //
    // Where the travelling highlight comes to rest is a layout question, and
    // it is asked here because tst_layout_pages' hero-page audit does not
    // reach SearchPage: its four pages are Album, Playlist, Mix and Artist,
    // plus Collection.
    //
    // Only where it comes to rest. init() above turns reduced motion on for
    // this whole file - "no fades to wait out" - so every duration under qml/
    // is zero here and nothing in this file can say anything about a travel.
    // That half, and the ink that goes with it, is in tst_reduced_motion.
    //
    // Every chip, because the six are six different widths - each its own
    // label plus padding - and the pill has to be each of them in turn: a
    // highlight aimed with an index times a constant is wrong on five of the
    // six, which is what the first width catches.
    //
    // And every chip at four pane widths, which is the cheap half. The chips
    // are text-width and the row neither wraps nor stretches, so the pane's
    // width does not enter the pill's geometry today and the sweep is the
    // assertion that it still does not - a chip given Layout.fillWidth, or a
    // row centred rather than left-aligned, would move the chips out from
    // under a pill aimed at anything but their live boxes.

    readonly property var tabWidths: [1280, 1100, 900, 740]

    function pillAndTabs(win) {
        var tabs = findByName(win.page, "searchTabsRow")
        verify(tabs, "the tab row was not found")
        var pills = findAllByName(win.page, "searchTabPill")
        compare(pills.length, 1, "the highlight is not one pill: found " + pills.length)
        return { tabs: tabs, pill: pills[0] }
    }

    // A chip's box in the pill's coordinates, so the two are comparable.
    function chipBoxIn(pill, chip) {
        var p = chip.mapToItem(pill.parent, 0, 0)
        return { x: p.x, y: p.y, w: chip.width, h: chip.height }
    }

    function pillSays(pill) {
        return "the pill is at " + pill.x.toFixed(1) + "," + pill.y.toFixed(1)
               + " " + pill.width.toFixed(1) + "x" + pill.height.toFixed(1)
    }

    function test_the_tab_pill_lands_on_the_chip() {
        for (var i = 0; i < tabWidths.length; ++i) {
            var w = tabWidths[i]
            var win = showPage()
            win.width = w
            typeInto(win.page, query)
            waitForRendering(win.contentItem, settleMs)

            var found = pillAndTabs(win)
            var tabs = found.tabs, pill = found.pill

            for (var tab = 0; tab < 6; ++tab) {
                win.page.activeTab = tab
                var chip = tabs.children[tab]
                verify(chip, "@" + w + ": chip " + tab + " was not built")

                // tryVerify, because the pill is still travelling when the tab
                // is set: this case is about where it stops. Exactly on the
                // chip and not within a pixel of it - a pill that stops a
                // fraction short leaves a sliver of the bare row down one edge
                // of the chip, and it is the ink check below that would then
                // fail by a pixel and read as a different bug.
                tryVerify(function () {
                    var c = chipBoxIn(pill, tabs.children[tab])
                    return Math.abs(pill.x - c.x) < 0.01 && Math.abs(pill.width  - c.w) < 0.01
                        && Math.abs(pill.y - c.y) < 0.01 && Math.abs(pill.height - c.h) < 0.01
                }, settleMs,
                "@" + w + ": " + pillSays(pill) + " with chip " + tab + " at "
                + chipBoxIn(pill, chip).x.toFixed(1) + "," + chipBoxIn(pill, chip).y.toFixed(1)
                + " " + chip.width.toFixed(1) + "x" + chip.height.toFixed(1))

                // The accent's ink copy covers the chip exactly when the pill
                // does, which is what keeps every glyph on the fill its ink
                // was chosen for; off the chip it is not drawn at all.
                var ink = findByName(chip, "searchTabInk")
                verify(ink, "@" + w + ": chip " + tab + " has no accent-ink copy")
                compare(Math.round(ink.width),  Math.round(chip.width),
                        "@" + w + ": the ink does not cover the chip the pill is on")
                compare(Math.round(ink.height), Math.round(chip.height),
                        "@" + w + ": the ink does not cover the chip the pill is on")

                var other = tabs.children[(tab + 3) % 6]
                var otherInk = findByName(other, "searchTabInk")
                verify(!otherInk.visible || otherInk.width < 1,
                       "@" + w + ": a chip the pill is nowhere near is drawing accent ink")
            }
        }
    }

    function sameColor(a, b) { return String(a) === String(b) }

    // The point in the window that is the middle of this chip, because a
    // synthesized move is delivered in window coordinates.
    function centreOf(win, item) {
        return item.mapToItem(win.contentItem, item.width / 2, item.height / 2)
    }

    // The hover tint loses to the highlight. That is what the chip's old
    // `activeTab === index ? accent : hover` said, and a travelling pill has to
    // say it again by other means: the pill is behind the row and surfaceHov is
    // opaque, so a tint drawn over it would paint the highlight out from under
    // the pointer - and the pointer is on the chip that was just clicked, which
    // makes this the most ordinary state the row has.
    function test_the_marked_chip_takes_no_hover_tint() {
        var win = showPage()
        typeInto(win.page, query)
        waitForRendering(win.contentItem, settleMs)

        var found = pillAndTabs(win)
        var tabs = found.tabs, pill = found.pill
        var marked = tabs.children[0]
        var far    = tabs.children[4]
        verify(marked && far, "the chips were not built")
        compare(win.page.activeTab, 0, "the page did not open on the first tab")

        // A chip the pill is nowhere near takes the tint, so the tint works at
        // all and the check below is about where it is refused.
        var f = centreOf(win, far)
        mouseMove(win.contentItem, f.x, f.y)
        tryVerify(function () { return sameColor(far.color, Theme.surfaceHov) }, settleMs,
                  "a chip under the pointer does not light up, got " + far.color)

        // The chip the pill is on refuses it.
        var m = centreOf(win, marked)
        mouseMove(win.contentItem, m.x, m.y)
        tryVerify(function () { return marked.color.a === 0 }, settleMs,
                  "the marked chip painted its hover tint over the highlight, got "
                  + marked.color)
        // ...with the pill still exactly on it, so there was a highlight there
        // to paint over.
        var c = chipBoxIn(pill, marked)
        verify(Math.abs(pill.x - c.x) < 0.01 && Math.abs(pill.width - c.w) < 0.01,
               "the pill is not on the chip under the pointer: " + pillSays(pill))
        tryVerify(function () { return far.color.a === 0 }, settleMs,
                  "the chip the pointer left kept its tint, got " + far.color)
    }

    // ── a query the page is handed rather than typed ────────────────────
    //
    // AlbumPage's failure panel sends the title of a delisted album here, so
    // the live edition can be found under whatever id it is listed as now.
    // Main.applyParams() can only *assign* - it walks the params object and
    // sets each name it finds on the page - so a page that is to run a search
    // on arrival has to be given a property, and a page that merely stored one
    // would land the user on an empty pane with the term in the box and nothing
    // asked for. Writing `query` does exactly that: it is the field's echo and
    // nothing watches it.
    function test_a_query_handed_to_the_page_is_actually_searched_for() {
        bridge.setSearchResultsForTest(fakeTracks(1), fakeAlbums(1), [], [])
        var win = showApp()

        win.navigate("search", { requestedQuery: query })

        tryVerify(function () { return bridge.lastSearchQueryForTest() === query },
                  settleMs,
                  "arriving at Search with a query to run asked the server for nothing; "
                  + "the last query it saw was \"" + bridge.lastSearchQueryForTest() + "\"")

        var bar = searchBarIn(win.contentItem)
        compare(bar.text, query,
                "the field does not hold the query that was run, so the user cannot "
                + "edit or even read what they are looking at")
        tryVerify(function () {
                      return saysSomethingContaining(win.contentItem, "Erfundenes Album 1")
                  }, settleMs,
                  "the results for the handed-over query never reached the page: "
                  + visibleCopy(win.contentItem))
    }

    // Every Item in the tree with this objectName, in tree order.
    function findAllByName(item, name) {
        return collectByName(item, name, [])
    }

    function collectByName(item, name, out) {
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) collectByName(kids[i], name, out)
        return out
    }
}
