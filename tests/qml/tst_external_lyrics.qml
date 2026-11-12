// Lyrics from other sites on the Now Playing page: asked for only with the
// switch on and only when Tidal has none, and credited to where they came from.

import QtQuick
import QtQuick.Window
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
        prefs.externalLyrics = false
    }

    function cleanup() {
        bridge.resetLyricsForTest()
        prefs.externalLyrics = false
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
                "with the switch off, another site was asked for lyrics")
    }

    function test_tidal_lyrics_win() {
        prefs.externalLyrics = true
        bridge.setLyricsForTest("one\ntwo", false)
        var page = openPage(502)
        compare(page.lyricsState, "ready")
        compare(bridge.findLyricsCallsForTest(), 0,
                "Tidal had lyrics and another site was still asked")
        compare(page.lyricsSource, "")
    }

    function test_found_elsewhere_and_credited() {
        prefs.externalLyrics = true
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
        prefs.externalLyrics = true
        bridge.setFoundLyricsForTest("[00:01.00]one\n[00:05.00]two", true, "LRCLIB",
                                     "https://lrclib.net/")
        var page = openPage(504)
        compare(page.lyricsState, "ready")
        compare(page.lyricsIsTimed, true)
        compare(page.lyricsData.length, 2)
        compare(page.lyricsData[1].ms, 5000)
    }

    function test_nothing_found_is_unavailable() {
        prefs.externalLyrics = true
        var page = openPage(505)
        compare(bridge.findLyricsCallsForTest(), 1)
        compare(page.lyricsState, "unavailable")
    }

    function test_switching_on_looks_again() {
        var page = openPage(506)
        compare(page.lyricsState, "unavailable")
        bridge.setFoundLyricsForTest("now found", false, "Genius", "https://genius.com/x")
        prefs.externalLyrics = true
        compare(bridge.findLyricsCallsForTest(), 1)
        compare(page.lyricsState, "ready")
    }

    function test_credit_cleared_on_next_track() {
        prefs.externalLyrics = true
        bridge.setFoundLyricsForTest("words", false, "Genius", "https://genius.com/x")
        var page = openPage(507)
        compare(page.lyricsSource, "Genius")
        bridge.resetLyricsForTest()
        bridge.setLyricsForTest("tidal words", false)
        player.setCurrentTrackForTest(makeTrack(508))
        compare(page.lyricsState, "ready")
        compare(page.lyricsSource, "", "the next track kept the other site's credit")
    }
}
