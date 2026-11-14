// Lyrics from other sites on the Now Playing page: asked for only with a
// switch on and only when Tidal has no synced ones, credited to where they
// came from; and plain lyrics timed here, marked as such.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ExternalLyrics"
    when: windowShown

    function makeTrack(id) {
        return { id: id, title: "Harbour Lights", artists: "Paper Lanterns",
                 artistList: [{ id: 3, name: "Paper Lanterns" }],
                 albumTitle: "Night Ferry", albumId: 55, artistId: 3,
                 coverUrl: "", coverUrl80: "", duration: 201 }
    }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetLyricsForTest()
        prefs.lyricsLrclib = false
        prefs.lyricsOtherSites = false
        prefs.lyricsAutoSync = false
    }

    // Back to what a fresh install has.
    function cleanup() {
        bridge.resetLyricsForTest()
        prefs.lyricsLrclib = true
        prefs.lyricsOtherSites = false
        prefs.lyricsAutoSync = true
        app.setReducedMotionForTest(false)
    }

    Component {
        id: nowPlayingHost
        Window {
            width: 1280; height: 900
            property bool   sleepTimerActive: false
            property bool   sleepStopAtEndOfTrack: false
            property int    sleepTimeLeft: 0
            property bool   sleepIsFading: false
            property bool   sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) {}
            function cancelSleepTimer() {}
            function formatSleepTime(seconds) { return "" + seconds }
            function navigate(page, params) {}
            function goBack() {}
            property bool fullScreen: false
            function toggleFullScreen() {}
            property alias page: np
            NowPlayingPage { id: np; anchors.fill: parent }
        }
    }

    function openPage(trackId) {
        player.setCurrentTrackForTest(makeTrack(trackId))
        var host = createTemporaryObject(nowPlayingHost, testCase)
        host.show()
        verify(waitForRendering(host.contentItem))
        return host.page
    }

    function test_off_asks_nobody_else() {
        var page = openPage(501)
        compare(page.lyricsState, "unavailable")
        compare(bridge.findLyricsCallsForTest(), 0,
                "with the switches off, another site was asked for lyrics")
    }

    function test_tidal_synced_lyrics_win() {
        prefs.lyricsLrclib = true
        prefs.lyricsOtherSites = true
        bridge.setLyricsForTest("[00:01.00]one\n[00:02.00]two", true)
        var page = openPage(502)
        compare(page.lyricsState, "ready")
        compare(page.lyricsIsTimed, true)
        compare(bridge.findLyricsCallsForTest(), 0,
                "Tidal had synced lyrics and another site was still asked")
        compare(page.lyricsSource, "")
    }

    // Tidal's plain words show at once; synced ones from a site replace them.
    function test_tidal_plain_lyrics_give_way_to_synced() {
        prefs.lyricsLrclib = true
        bridge.setLyricsForTest("one\ntwo", false)
        bridge.setFoundLyricsForTest("[00:01.00]one\n[00:05.00]two", true, "LRCLIB", "https://lrclib.net/")
        var page = openPage(512)
        compare(bridge.findLyricsCallsForTest(), 1)
        compare(page.lyricsIsTimed, true)
        compare(page.lyricsData[1].ms, 5000)
        compare(page.lyricsSource, "LRCLIB")
    }

    function test_tidal_plain_lyrics_beat_plain_from_a_site() {
        prefs.lyricsLrclib = true
        bridge.setLyricsForTest("tidal one\ntidal two", false)
        bridge.setFoundLyricsForTest("site one", false, "Genius", "https://genius.com/x")
        var page = openPage(513)
        compare(bridge.findLyricsCallsForTest(), 1)
        compare(page.lyricsIsTimed, false)
        compare(page.lyricsData[0].text, "tidal one")
        compare(page.lyricsSource, "")
    }

    function test_found_elsewhere_and_credited() {
        prefs.lyricsLrclib = true
        bridge.setFoundLyricsForTest("first line\nsecond line", false, "Genius",
                                     "https://genius.com/Paper-lanterns-harbour-lights-lyrics")
        var page = openPage(503)
        compare(bridge.findLyricsCallsForTest(), 1)
        var asked = bridge.lastFindLyricsTrackForTest()
        compare(asked.id, 503)
        compare(asked.title, "Harbour Lights")
        compare(asked.albumTitle, "Night Ferry")
        compare(asked.duration, 201)
        compare(page.lyricsState, "ready")
        compare(page.lyricsData.length, 2)
        compare(page.lyricsIsTimed, false)

        page.showLyrics = true
        tryVerify(function () { return page.lyricsness === 1 }, 3000)
        var credit = findChild(page, "nowPlayingLyricsSource")
        verify(credit, "the lyrics carry no credit")
        verify(credit.visible, "the credit is hidden")
        verify(credit.text.indexOf("Genius") !== -1, "the credit says " + credit.text)
        compare(credit.sourceUrl, "https://genius.com/Paper-lanterns-harbour-lights-lyrics")
    }

    function test_timed_lyrics_from_elsewhere_are_timed() {
        prefs.lyricsLrclib = true
        bridge.setFoundLyricsForTest("[00:01.00]one\n[00:05.00]two", true, "LRCLIB",
                                     "https://lrclib.net/")
        var page = openPage(504)
        compare(page.lyricsState, "ready")
        compare(page.lyricsIsTimed, true)
        compare(page.lyricsData.length, 2)
        compare(page.lyricsData[1].ms, 5000)
    }

    function test_nothing_found_is_unavailable() {
        prefs.lyricsLrclib = true
        var page = openPage(505)
        compare(bridge.findLyricsCallsForTest(), 1)
        compare(page.lyricsState, "unavailable")
    }

    // A site that knows the song says it has no words: the panel says so,
    // rather than that there are no lyrics.
    function test_instrumental_is_said() {
        prefs.lyricsLrclib = true
        bridge.setFoundInstrumentalForTest(true)
        var page = openPage(509)
        compare(page.lyricsState, "instrumental")
        var chip = findChild(page, "nowPlayingLyricsToggle")
        verify(chip.visible, "the lyrics chip hid itself for an instrumental")
        page.showLyrics = true
        tryVerify(function () { return page.lyricsness === 1 }, 3000)
        var note = findChild(page, "nowPlayingLyricsInstrumental")
        verify(note, "there is no instrumental note")
        verify(note.visible, "the instrumental note is hidden")
        compare(note.text, "Instrumental")
        verify(!findChild(page, "nowPlayingLyricsSource").visible)
    }

    function manyLines(timed) {
        var out = []
        for (var i = 0; i < 60; i++) {
            var t = "Line " + i + " of an invented song"
            out.push(timed ? "[00:" + (i < 10 ? "0" : "") + i + ".00]" + t : t)
        }
        return out.join("\n")
    }

    function openPanel(page) {
        page.showLyrics = true
        tryVerify(function () { return page.lyricsness === 1 }, 3000)
        waitForRendering(page)
    }

    // Long plain lyrics get a bar to drag; dragging it is the user scrolling.
    function test_plain_lyrics_have_a_scroll_bar() {
        prefs.lyricsLrclib = true
        bridge.setFoundLyricsForTest(manyLines(false), false, "Genius", "https://genius.com/x")
        var page = openPage(510)
        openPanel(page)
        var bar = findChild(page, "nowPlayingLyricsScrollBar")
        verify(bar, "the lyrics panel has no scroll bar")
        verify(bar.visible, "plain lyrics show no scroll bar")
        compare(bar.policy, ScrollBar.AlwaysOn)
        verify(bar.height > 40, "the bar is " + bar.height + " px tall")
        var chips = findChild(page, "nowPlayingPanelChips")
        var barBottom = bar.mapToItem(page, 0, bar.height).y
        verify(barBottom <= chips.mapToItem(page, 0, 0).y + 1,
               "the bar runs down into the chips")

        var view = findChild(page, "nowPlayingLyricsView")
        var before = view.contentY
        var h = bar.contentItem
        mousePress(h, h.width / 2, 4)
        mouseMove(h, h.width / 2, 4 + bar.height / 2)
        mouseRelease(h, h.width / 2, 4 + bar.height / 2)
        verify(view.contentY > before + 50,
               "dragging the bar moved the lyrics from " + before + " to " + view.contentY)
        verify(page.userScrolled, "a dragged bar did not count as the user scrolling")
    }

    function test_timed_lyrics_have_none() {
        prefs.lyricsLrclib = true
        bridge.setFoundLyricsForTest(manyLines(true), true, "LRCLIB", "https://lrclib.net/")
        var page = openPage(511)
        openPanel(page)
        compare(page.lyricsIsTimed, true)
        var bar = findChild(page, "nowPlayingLyricsScrollBar")
        verify(bar, "the lyrics panel has no scroll bar")
        verify(!bar.visible, "synced lyrics, which follow the song, show a scroll bar")
    }

    function test_switching_on_looks_again_data() {
        return [{ tag: "lrclib", key: "lyricsLrclib" }, { tag: "other sites", key: "lyricsOtherSites" }]
    }

    function test_switching_on_looks_again(data) {
        var page = openPage(506)
        compare(page.lyricsState, "unavailable")
        bridge.setFoundLyricsForTest("now found", false, "Genius", "https://genius.com/x")
        prefs[data.key] = true
        compare(bridge.findLyricsCallsForTest(), 1)
        compare(page.lyricsState, "ready")
    }

    function test_credit_cleared_on_next_track() {
        prefs.lyricsLrclib = true
        bridge.setFoundLyricsForTest("words", false, "Genius", "https://genius.com/x")
        var page = openPage(507)
        compare(page.lyricsSource, "Genius")
        bridge.resetLyricsForTest()
        bridge.setLyricsForTest("tidal words", false)
        player.setCurrentTrackForTest(makeTrack(508))
        compare(page.lyricsState, "ready")
        compare(page.lyricsSource, "", "the next track kept the other site's credit")
    }

    // ── auto-sync ────────────────────────────────────────────────────────

    readonly property string autoLrc: "[00:01.00]one\n[00:04.00]two"

    function test_plain_lyrics_are_synced_here() {
        prefs.lyricsAutoSync = true
        bridge.setLyricsForTest("one\ntwo", false)
        bridge.setAutoSyncForTest(true, autoLrc)
        var page = openPage(520)
        compare(bridge.autoSyncCallsForTest(), 1)
        compare(bridge.lastAutoSyncTextForTest(), "one\ntwo")
        compare(page.lyricsIsTimed, true)
        compare(page.lyricsData[1].ms, 4000)
        verify(page.lyricsAutoSynced)
        openPanel(page)
        var note = findChild(page, "nowPlayingLyricsAutoSynced")
        verify(note, "auto-synced lyrics carry no note")
        verify(note.visible, "the auto-sync note is hidden")
        compare(note.text, "Synced automatically, may be off")
    }

    function test_unsure_timings_are_not_shown() {
        prefs.lyricsAutoSync = true
        bridge.setLyricsForTest("one\ntwo", false)
        bridge.setAutoSyncForTest(false, autoLrc)
        var page = openPage(521)
        compare(bridge.autoSyncCallsForTest(), 1)
        compare(page.lyricsIsTimed, false)
        verify(!page.lyricsAutoSynced)
        openPanel(page)
        verify(!findChild(page, "nowPlayingLyricsAutoSynced").visible)
    }

    function test_switched_off_nothing_is_synced() {
        bridge.setLyricsForTest("one\ntwo", false)
        bridge.setAutoSyncForTest(true, autoLrc)
        var page = openPage(522)
        compare(bridge.autoSyncCallsForTest(), 0)
        compare(page.lyricsIsTimed, false)
    }

    // Real timings from a site replace auto-synced ones, and auto-synced ones
    // that come late do not replace real ones.
    function test_real_timings_win_over_auto_sync() {
        prefs.lyricsAutoSync = true
        prefs.lyricsLrclib = true
        bridge.setLyricsForTest("one\ntwo", false)
        bridge.setAutoSyncForTest(true, autoLrc)
        bridge.setFoundLyricsForTest("[00:02.00]one\n[00:07.00]two", true, "LRCLIB", "https://lrclib.net/")
        var page = openPage(523)
        compare(page.lyricsData[1].ms, 7000)
        verify(!page.lyricsAutoSynced)
        compare(bridge.autoSyncCancelsForTest(), 1, "the auto-sync for plain lyrics now replaced went on")

        bridge.holdAutoSyncForTest(true)
        player.setCurrentTrackForTest(makeTrack(524))
        compare(page.lyricsData[1].ms, 7000)
        bridge.releaseAutoSyncForTest()
        compare(page.lyricsData[1].ms, 7000, "a late auto-sync replaced real timings")
        verify(!page.lyricsAutoSynced)
    }

    // Plain lyrics from a site are synced too, and the note sits beside the credit.
    function test_plain_from_a_site_is_synced() {
        prefs.lyricsAutoSync = true
        prefs.lyricsLrclib = true
        bridge.setFoundLyricsForTest("one\ntwo", false, "Genius", "https://genius.com/x")
        bridge.setAutoSyncForTest(true, autoLrc)
        var page = openPage(525)
        compare(bridge.lastAutoSyncTextForTest(), "one\ntwo")
        verify(page.lyricsAutoSynced)
        openPanel(page)
        var credit = findChild(page, "nowPlayingLyricsSource")
        var note = findChild(page, "nowPlayingLyricsAutoSynced")
        verify(credit.visible && note.visible)
        verify(note.x >= credit.x + credit.width, "the note overlaps the credit")
    }

    // An answer for the track before is dropped.
    function test_late_answer_for_another_track_is_dropped() {
        prefs.lyricsAutoSync = true
        bridge.setLyricsForTest("one\ntwo", false)
        bridge.setAutoSyncForTest(true, autoLrc)
        bridge.holdAutoSyncForTest(true)
        var page = openPage(526)
        bridge.setLyricsForTest("three\nfour", false)
        player.setCurrentTrackForTest(makeTrack(527))
        compare(bridge.autoSyncCallsForTest(), 2)
        bridge.releaseOldestAutoSyncForTest()        // 526's
        compare(page.lyricsData[0].text, "three")
        verify(!page.lyricsIsTimed, "526's timings landed on 527")
    }

    // An answer for an earlier load of the same track is dropped: here the
    // one asked for before auto-sync was switched off.
    function test_late_answer_after_switching_off_is_dropped() {
        prefs.lyricsAutoSync = true
        bridge.setLyricsForTest("one\ntwo", false)
        bridge.setAutoSyncForTest(true, autoLrc)
        bridge.holdAutoSyncForTest(true)
        var page = openPage(530)
        prefs.lyricsAutoSync = false
        compare(page.lyricsState, "ready")
        bridge.releaseAutoSyncForTest()
        verify(!page.lyricsIsTimed, "timings asked for before the switch went off were shown")
        verify(!page.lyricsAutoSynced)
    }

    function test_switching_auto_sync_off_takes_the_timings_away() {
        prefs.lyricsAutoSync = true
        bridge.setLyricsForTest("one\ntwo", false)
        bridge.setAutoSyncForTest(true, autoLrc)
        var page = openPage(528)
        verify(page.lyricsAutoSynced)
        prefs.lyricsAutoSync = false
        verify(!page.lyricsAutoSynced)
        compare(page.lyricsIsTimed, false)
        prefs.lyricsAutoSync = true
        verify(page.lyricsAutoSynced, "switched back on, the lyrics were not synced again")
    }

    // The next track is analysed ahead only while lyrics are on screen.
    function test_look_ahead_follows_the_panel() {
        prefs.lyricsAutoSync = true
        bridge.setLyricsForTest("one\ntwo", false)
        var page = openPage(529)
        verify(!bridge.lyricsLookAheadForTest())
        openPanel(page)
        verify(bridge.lyricsLookAheadForTest())
        prefs.lyricsAutoSync = false
        verify(!bridge.lyricsLookAheadForTest())
    }
}
