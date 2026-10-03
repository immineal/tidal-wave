// Song credits, the rights line and the date a record came out.
//
// The user: "currently there is no way to see song credits or exact copyright
// information or the actual date that something came out." All three are in the
// API and none of them reached the screen - the album page showed four digits of
// the release date and nothing showed the rest.
//
// What this file measures is the content and the four states around it. The
// credits panel's geometry - the slot it shares with the lyrics, and what
// fullscreen does to it - is tests/qml/tst_layout_player.qml's business.
//
// No fixture here carries anything out of the user's own library: the names
// below are invented and the identifiers are not real codes.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Credits"
    when: windowShown

    readonly property int settleMs: 3000

    function makeTrack(i) {
        return {
            id:          2000 + i,
            title:       "A Song With A Reasonably Long Title " + i,
            artists:     "An Invented Band",
            albumTitle:  "An Invented Record",
            albumId:     900 + i,
            artistId:    77,
            coverUrl:    "",
            coverUrl80:  "",
            duration:    215
        }
    }

    function init() {
        app.setReducedMotionForTest(false)
        player.setQueueForTest([makeTrack(0), makeTrack(1)], 0)
        player.setManualForTest([])
        player.setCurrentTrackForTest(makeTrack(0))
        player.setDurationForTest(215000)
        player.setPositionForTest(42000)
        bridge.resetTrackCreditsFetchCountForTest()
    }

    // NowPlayingPage delegates its sleep timer to Window.window, so it cannot be
    // instantiated bare. The same surface tst_layout_player.qml and
    // tst_reduced_motion.qml mirror, and nothing more.
    Component {
        id: nowPlayingHost
        Window {
            id: npWin
            width: 1280; height: 1000
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) { sleepTimerActive = true }
            function cancelSleepTimer() { sleepTimerActive = false }
            function formatSleepTime(seconds) { return "0:30" }
            function navigate(page, params) {}
            function goBack() {}
            property bool fullScreen: false
            function toggleFullScreen() { fullScreen = !fullScreen }
            property alias page: np
            NowPlayingPage { id: np; width: npWin.width; height: npWin.height }
        }
    }

    Component {
        id: albumHost
        Window {
            id: abWin
            width: 1000; height: 800
            function navigate(page, params) {}
            function goBack() {}
            property alias page: ap
            AlbumPage { id: ap; width: abWin.width; height: abWin.height }
        }
    }

    function showHost(component, w, h) {
        var host = createTemporaryObject(component, testCase,
                                        { width: w, height: h })
        verify(host, "host window was not created")
        host.visible = true
        waitForRendering(host.contentItem)
        return host
    }

    function settlePage(page) {
        tryVerify(function () {
            return page.creditsness === (page.showCredits ? 1 : 0)
                && page.lyricsness  === (page.showLyrics  ? 1 : 0)
        }, settleMs, "the page never settled")
    }

    // The shape the bridge answers with, invented end to end. "Bass guitar" and
    // "Mastering Engineer" are the label's own words for the role, which is why
    // they arrive in English and are not translated: they are data about the
    // recording, like the names beside them.
    function fakeCredits() {
        return {
            groups: [
                { type: "Producer",
                  contributors: [{ id: 1, name: "Pat Invented" },
                                 { id: 2, name: "Jo Fictional" }] },
                { type: "Bass guitar",
                  contributors: [{ id: 3, name: "Sam Notreal" }] },
                { type: "Mastering Engineer",
                  contributors: [{ id: 4, name: "Kim Madeup" }] }
            ],
            copyright:   "(P) 2017 An Invented Label Ltd.",
            isrc:        "ZZ0000000001",
            releaseDate: "2017-09-22",
            upc:         "000000000001",
            state:       "ready"
        }
    }

    // Written onto the page rather than answered by the bridge, the way
    // tst_layout_player.qml gives the page lyrics: the stub answers
    // fetchTrackCredits emptily by design, which is what the empty case below
    // measures.
    function giveCredits(page) {
        page.applyCredits(fakeCredits())
    }

    function openCredits(host) {
        var page = host.page
        page.showCredits = true
        settlePage(page)
        waitForRendering(host.contentItem)
        return page
    }

    // Every Text in the panel, flattened, so a case can ask whether a string
    // reached the screen without knowing where in the tree it ended up.
    function visibleTexts(item, out) {
        if (!item) return out
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false) continue
            if (typeof c.text === "string" && c.text.length > 0)
                out.push(c.text)
            visibleTexts(c, out)
        }
        return out
    }

    function hasTextContaining(item, needle) {
        var all = visibleTexts(item, [])
        for (var i = 0; i < all.length; i++)
            if (all[i].indexOf(needle) >= 0) return true
        return false
    }

    function shownTexts(item) {
        return visibleTexts(item, []).join(" | ")
    }

    // ── what the panel shows ─────────────────────────────────────────────

    function test_credits_show_the_names_the_date_and_the_small_print() {
        var host = showHost(nowPlayingHost, 1280, 1000)
        var page = host.page
        giveCredits(page)
        openCredits(host)

        var panel = findChild(page, "nowPlayingCreditsPanel")
        verify(panel && panel.visible, "the credits panel did not open")
        compare(page.creditsState, "ready")

        // Every role, with the people under it.
        var roles = ["Producer", "Bass guitar", "Mastering Engineer"]
        for (var i = 0; i < roles.length; i++)
            verify(hasTextContaining(panel, roles[i]),
                   "the panel does not name the " + roles[i]
                   + " group. It shows: " + shownTexts(panel))
        var names = ["Pat Invented", "Jo Fictional", "Sam Notreal", "Kim Madeup"]
        for (var j = 0; j < names.length; j++)
            verify(hasTextContaining(panel, names[j]),
                   "the panel does not credit " + names[j]
                   + ". It shows: " + shownTexts(panel))

        // The rights line verbatim, not reworded and not reformatted.
        verify(hasTextContaining(panel, "(P) 2017 An Invented Label Ltd."),
               "the rights line is not on the panel. It shows: " + shownTexts(panel))

        // The date in full. Not asserted as a literal string, because the page
        // writes it in the reader's own locale: what matters is that the day and
        // the month are there and not only the year, which is all the album page
        // used to show.
        var dateText = ""
        var all = visibleTexts(panel, [])
        for (var k = 0; k < all.length; k++)
            if (all[k].indexOf("2017") >= 0 && all[k].indexOf("(P)") < 0)
                dateText = all[k]
        verify(dateText.length > 0,
               "nothing on the panel says when the record came out. It shows: "
               + shownTexts(panel))
        verify(dateText.indexOf("22") >= 0,
               "the release date reads \"" + dateText
               + "\", which does not carry the day of the month")
        verify(dateText !== "2017" && dateText.length > 8,
               "the release date reads \"" + dateText + "\", which is the year again")
        // And without the day of the week, which is noise on a release date.
        // 2017-09-22 was a Friday; Qt numbers Sunday 7, so JS's 5 is Qt's 5.
        var weekday = Qt.locale().dayName(5, Locale.LongFormat)
        verify(dateText.indexOf(weekday) < 0,
               "the release date reads \"" + dateText + "\", which names the "
               + "day of the week")

        // The two identifiers are there, and they are the quietest thing on the
        // panel: smaller than the names they sit under, which is what "reference
        // data, not headline content" has to mean in pixels.
        verify(hasTextContaining(panel, "ZZ0000000001"),
               "the ISRC is not on the panel. It shows: " + shownTexts(panel))
        verify(hasTextContaining(panel, "000000000001"),
               "the UPC is not on the panel. It shows: " + shownTexts(panel))

        var idSize = -1, nameSize = -1
        function sizes(item) {
            var kids = item.children
            for (var i = 0; i < kids.length; i++) {
                var c = kids[i]
                if (!c || c.visible === false) continue
                if (typeof c.text === "string" && c.font) {
                    if (c.text.indexOf("ZZ0000000001") >= 0) idSize = c.font.pixelSize
                    if (c.text.indexOf("Pat Invented") >= 0) nameSize = c.font.pixelSize
                }
                sizes(c)
            }
        }
        sizes(panel)
        verify(idSize > 0 && nameSize > 0,
               "the identifier line or the name line was not measured")
        verify(idSize < nameSize,
               "the identifiers are set at " + idSize + "px against " + nameSize
               + "px for the names, so they are not the quieter of the two")

        // Nothing in the panel sticks out of it.
        verify(panel.width > 0 && panel.height > 0, "the panel has no size")
        var view = findChild(page, "nowPlayingCreditsView")
        verify(view && view.visible, "the credits list is not showing")
        verify(view.width <= panel.width + 0.5 && view.height <= panel.height + 0.5,
               "the credits list is " + view.width.toFixed(1) + "x"
               + view.height.toFixed(1) + " in a panel " + panel.width.toFixed(1)
               + "x" + panel.height.toFixed(1))
        // ...and it keeps content room at the bottom for the chips over it, the
        // same way the lyric list does.
        verify(view.bottomMargin >= 30,
               "the credits list reserves no content room at the bottom ("
               + view.bottomMargin + "), so its last line cannot clear the chips")
    }

    // A track with no credits at all. The bridge stub answers fetchTrackCredits
    // with an empty result and no error, which is exactly this case.
    function test_credits_with_nothing_to_show_say_so() {
        var host = showHost(nowPlayingHost, 1280, 1000)
        var page = host.page
        var chip = findChild(page, "nowPlayingCreditsToggle")
        verify(chip && chip.visible, "the credits chip was not found")

        mouseClick(chip, Math.round(chip.width / 2), Math.round(chip.height / 2))
        tryVerify(function () { return page.creditsState === "unavailable" },
                  settleMs,
                  "the empty answer did not land on \"unavailable\", it is in \""
                  + page.creditsState + "\"")
        settlePage(page)
        waitForRendering(host.contentItem)

        var panel = findChild(page, "nowPlayingCreditsPanel")
        verify(panel && panel.visible, "the credits panel did not open")
        verify(hasTextContaining(panel, "No credits available"),
               "the panel says nothing about having nothing. It shows: "
               + shownTexts(panel))
        var view = findChild(page, "nowPlayingCreditsView")
        verify(view && !view.visible,
               "the credits list is still showing with nothing in it")
    }

    // In flight. Not the same message as the empty case, and not the empty
    // message as well as its own.
    function test_credits_in_flight_say_so() {
        var host = showHost(nowPlayingHost, 1280, 1000)
        var page = host.page
        page.creditsState = "loading"
        openCredits(host)

        var panel = findChild(page, "nowPlayingCreditsPanel")
        verify(panel && panel.visible, "the credits panel did not open")
        verify(hasTextContaining(panel, "Loading credits"),
               "the panel does not say it is loading. It shows: "
               + shownTexts(panel))
        verify(!hasTextContaining(panel, "No credits available"),
               "the panel says the credits are missing while it is still "
               + "fetching them. It shows: " + shownTexts(panel))

        // And the chip says so too, rather than offering a tab that answers
        // nothing yet.
        var chip = findChild(page, "nowPlayingCreditsToggle")
        verify(hasTextContaining(chip, "Loading"),
               "the chip does not say the credits are loading")
    }

    // A failed fetch lands on the same one message as an empty one, because from
    // the panel's side "we asked and there is nothing to show" is one fact. What
    // it must not do is get stuck in "loading" with a spinner that never stops.
    function test_a_failed_fetch_does_not_spin_forever() {
        var host = showHost(nowPlayingHost, 1280, 1000)
        var page = host.page
        // The page's own callback path, driven with the error argument the bridge
        // passes on a failure. Going through loadCredits() would reach the stub,
        // which cannot fail on request.
        page.creditsState = "loading"
        page.applyCredits({ groups: [], copyright: "", isrc: "",
                            releaseDate: "", upc: "", state: "unavailable" })
        openCredits(host)

        compare(page.creditsState, "unavailable")
        var panel = findChild(page, "nowPlayingCreditsPanel")
        verify(hasTextContaining(panel, "No credits available"),
               "a failed fetch leaves the panel saying nothing. It shows: "
               + shownTexts(panel))
        verify(!hasTextContaining(panel, "Loading credits"),
               "the panel is still loading after the fetch came back")
    }

    // ── caching ──────────────────────────────────────────────────────────

    // Flipping between the two tabs must not go back to the network: three
    // requests go into one answer.
    function test_credits_are_fetched_once_per_track() {
        var host = showHost(nowPlayingHost, 1280, 1000)
        var page = host.page
        compare(bridge.trackCreditsFetchCountForTest(), 0,
                "something fetched credits before the tab was opened")

        page.showCredits = true
        page.loadCredits()
        tryVerify(function () { return page.creditsState !== "loading" }, settleMs,
                  "the first fetch never came back")
        compare(bridge.trackCreditsFetchCountForTest(), 1,
                "opening the tab should ask exactly once")

        // Away to the lyrics and back again.
        page.showLyrics = true
        settlePage(page)
        page.showCredits = true
        page.loadCredits()
        settlePage(page)
        compare(bridge.trackCreditsFetchCountForTest(), 1,
                "flipping between the two tabs went back to the network")

        // A different track is a different answer, so that one is fetched.
        player.setCurrentTrackForTest(makeTrack(1))
        tryVerify(function () { return page.creditsState !== "loading" }, settleMs,
                  "the second fetch never came back")
        compare(bridge.trackCreditsFetchCountForTest(), 2,
                "a new track did not get its own credits")

        // ...and going back to the first track is cached, not refetched.
        player.setCurrentTrackForTest(makeTrack(0))
        tryVerify(function () { return page.creditsState !== "loading" }, settleMs,
                  "coming back to the first track never settled")
        compare(bridge.trackCreditsFetchCountForTest(), 2,
                "coming back to a track already fetched asked again")
    }

    // The two panels are tabs over one slot, and the invariant is the page's and
    // not the chips': anything that opens one closes the other.
    function test_the_two_panels_are_one_slot() {
        var host = showHost(nowPlayingHost, 1280, 1000)
        var page = host.page
        page.lyricsState = "ready"
        page.lyricsData  = [{ ms: 0, text: "A line" }]

        page.showLyrics = true
        settlePage(page)
        verify(page.showLyrics && !page.showCredits, "the lyrics did not open")

        page.showCredits = true
        settlePage(page)
        verify(page.showCredits, "the credits did not open")
        verify(!page.showLyrics,
               "both panels are open at once over one slot")

        page.showLyrics = true
        settlePage(page)
        verify(page.showLyrics, "the lyrics did not come back")
        verify(!page.showCredits, "the credits stayed open under the lyrics")

        // Closing the open one leaves the artwork, not an empty panel.
        page.showLyrics = false
        settlePage(page)
        compare(page.panelness, 0, "the slot is still a panel with neither open")
        var art = findChild(page, "nowPlayingArt")
        verify(art && art.visible, "the artwork did not come back")
    }

    // Moving to another track drops what was on screen and keeps the cache.
    //
    // Two halves, and they fail for different reasons. With the tab open the
    // page has to go and ask again; with it shut there is nothing to ask for,
    // and what matters is that the state does not carry over - otherwise
    // opening the tab on the next track shows the last track's credits with no
    // fetch in sight, which is the worst of the three states to be wrong in.
    function test_a_track_change_clears_what_is_on_screen() {
        var host = showHost(nowPlayingHost, 1280, 1000)
        var page = host.page
        giveCredits(page)
        openCredits(host)
        verify(hasTextContaining(findChild(page, "nowPlayingCreditsPanel"),
                                 "Pat Invented"),
               "the fixture never reached the panel")

        player.setCurrentTrackForTest(makeTrack(1))
        tryVerify(function () { return page.creditsState !== "loading" }, settleMs,
                  "the new track's credits never settled")
        waitForRendering(host.contentItem)
        verify(!hasTextContaining(findChild(page, "nowPlayingCreditsPanel"),
                                  "Pat Invented"),
               "the previous track's credits are still on the panel")
    }

    function test_a_track_change_clears_the_shut_tab_too() {
        var host = showHost(nowPlayingHost, 1280, 1000)
        var page = host.page
        giveCredits(page)
        compare(page.creditsState, "ready")

        // The tab is shut, so nothing refetches and nothing redraws: only the
        // clear stands between this and the next track showing these names.
        verify(!page.showCredits, "this half is about the tab being shut")
        player.setCurrentTrackForTest(makeTrack(1))
        compare(page.creditsState, "none",
                "the credits state carried over to the next track")
        compare(page.creditsGroups.length, 0,
                "the previous track's credit groups carried over")
        compare(page.creditsCopyright, "",
                "the previous track's rights line carried over")
        compare(page.creditsReleaseDate, "",
                "the previous track's release date carried over")

        // And opening the tab now shows the new track's answer, not the old one.
        openCredits(host)
        tryVerify(function () { return page.creditsState !== "loading" }, settleMs,
                  "the new track's credits never settled")
        waitForRendering(host.contentItem)
        verify(!hasTextContaining(findChild(page, "nowPlayingCreditsPanel"),
                                  "Pat Invented"),
               "the previous track's credits came back when the tab reopened")
    }

    // ── the album page ───────────────────────────────────────────────────

    // The hero printed `albumData.year`, which is the first four characters of a
    // date the response has carried in full all along.
    function test_the_album_hero_shows_the_whole_release_date() {
        var host = showHost(albumHost, 1000, 800)
        var page = host.page
        page.albumData = {
            id: 901, title: "An Invented Record", artists: "An Invented Band",
            artistId: 77, coverUrl: "", coverUrl640: "",
            releaseDate: "2017-09-22", year: "2017",
            numTracks: 11, duration: 2400, quality: "LOSSLESS",
            copyright: "(P) 2017 An Invented Label Ltd.", upc: "000000000001"
        }
        waitForRendering(host.contentItem)

        var facts = ""
        var all = visibleTexts(page, [])
        for (var i = 0; i < all.length; i++)
            if (all[i].indexOf("2017") >= 0 && all[i].indexOf("(P)") < 0)
                facts = all[i]
        verify(facts.length > 0,
               "the hero says nothing about when the record came out. It shows: "
               + shownTexts(page))
        verify(facts.indexOf("22") >= 0,
               "the hero's facts line reads \"" + facts
               + "\", which does not carry the day of the month")
        var weekday = Qt.locale().dayName(5, Locale.LongFormat)
        verify(facts.indexOf(weekday) < 0,
               "the hero's facts line reads \"" + facts
               + "\", which names the day of the week")
        // The rest of the line is still there: this replaced the year, it did not
        // replace the line.
        verify(facts.indexOf("•") >= 0,
               "the hero's facts line reads \"" + facts
               + "\", which has lost the rest of the facts")
    }

    function test_the_album_hero_shows_the_rights_line() {
        var host = showHost(albumHost, 1000, 800)
        var page = host.page
        page.albumData = {
            id: 901, title: "An Invented Record", artists: "An Invented Band",
            artistId: 77, coverUrl: "", coverUrl640: "",
            releaseDate: "2017-09-22", year: "2017",
            numTracks: 11, duration: 2400, quality: "LOSSLESS",
            copyright: "(P) 2017 An Invented Label Ltd.", upc: "000000000001"
        }
        waitForRendering(host.contentItem)

        var line = findChild(page, "albumCopyright")
        verify(line, "the album hero has no rights line")
        verify(line.visible, "the album hero's rights line is hidden")
        compare(line.text, "(P) 2017 An Invented Label Ltd.",
                "the rights line was reworded")

        // And an album whose response carried none reserves no row for it.
        page.albumData = {
            id: 902, title: "Another Invented Record", artists: "An Invented Band",
            artistId: 77, coverUrl: "", coverUrl640: "",
            releaseDate: "2019-01-04", year: "2019",
            numTracks: 9, duration: 1800, quality: "LOSSLESS"
        }
        waitForRendering(host.contentItem)
        verify(!line.visible,
               "the rights line is still showing with nothing in it")
    }

    // A response that only ever had the year stays the year rather than becoming
    // a guessed-at date.
    function test_a_year_only_release_date_stays_the_year() {
        var host = showHost(albumHost, 1000, 800)
        var page = host.page
        compare(page.releaseText("2017-09-22").indexOf("2017") >= 0, true)
        compare(page.releaseText("2017-09-22").indexOf("22") >= 0, true)
        compare(page.releaseText("2017-09-22")
                    .indexOf(Qt.locale().dayName(5, Locale.LongFormat)) < 0, true)
        compare(page.releaseText("1998"), "1998")
        compare(page.releaseText(""), "")
        compare(page.releaseText("not a date"), "not a date")
    }
}
