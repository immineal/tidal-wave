// The player's states that have nothing to play yet: a track still loading,
// and Now Playing with no track at all.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "PlayerStates"
    when: windowShown
    visible: true
    width: 400
    height: 300

    function makeTrack() {
        return {
            id: 2001, title: "Ein Titel", artists: "Eine Band",
            albumTitle: "Ein Album", albumId: 42, artistId: 7,
            coverUrl: "", coverUrl80: "", duration: 215
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        player.setCurrentTrackForTest(makeTrack())
        player.setQueueForTest([makeTrack()], 0)
        player.setLoadingForTest(false)
        player.setPlayingForTest(false)
    }

    function cleanup() {
        player.setLoadingForTest(false)
        app.setReducedMotionForTest(true)
    }

    Component {
        id: barHost
        Window {
            id: bw
            width: 1280; height: 200
            property alias bar: pb
            PlayerBar { id: pb; width: bw.width; anchors.bottom: parent.bottom }
        }
    }

    Component {
        id: npHost
        Window {
            id: nw
            width: 1280; height: 900
            property alias page: np
            function navigate(page, params) {}
            function goBack() {}
            property bool fullScreen: false
            function toggleFullScreen() {}
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) {}
            function cancelSleepTimer() {}
            function formatSleepTime(seconds) { return "" }
            NowPlayingPage { id: np; width: nw.width; height: nw.height }
        }
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function show(component) {
        var host = createTemporaryObject(component, testCase)
        verify(host, "host window was not created")
        host.visible = true
        frame(host.contentItem)
        return host
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    // Every glyph drawn inside an item, by name.
    function visibleGlyphs(item, out) {
        if (!item || item.visible === false) return out
        if (typeof item._pathFor === "function") out.push(item.name)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) visibleGlyphs(kids[i], out)
        return out
    }

    // ── a track that is still loading ────────────────────────────────────

    function checkLoadingDisc(host, discName, ringName) {
        var disc = findByName(host.contentItem, discName)
        verify(disc, "no play button called " + discName)

        player.setLoadingForTest(true)
        var ring = findByName(disc, ringName)
        verify(ring, "the play button has no loading ring")
        tryVerify(function () { return ring.visible }, 1000,
                  "the play button shows no ring while the track loads")
        compare(visibleGlyphs(disc, []).length, 0,
                "the loading disc still draws a glyph: " + visibleGlyphs(disc, []).join(", "))

        // It turns, and under reduced motion it stands still.
        app.setReducedMotionForTest(false)
        tryVerify(function () { return ring.turning }, 1000, "the ring does not turn")
        app.setReducedMotionForTest(true)
        tryVerify(function () { return !ring.turning }, 1000,
                  "the ring keeps turning under reduced motion")
        compare(ring.rotation, 0, "the still ring is left at an angle")

        player.setLoadingForTest(false)
        tryVerify(function () { return !ring.visible }, 1000,
                  "the ring stays after the track has loaded")
        compare(visibleGlyphs(disc, []).join(","), "play",
                "the loaded disc does not show the play glyph")
    }

    function test_the_bar_play_button_shows_a_ring_while_loading() {
        checkLoadingDisc(show(barHost), "playerBarPlayButton", "playerBarLoadingRing")
    }

    function test_now_playing_play_button_shows_a_ring_while_loading() {
        checkLoadingDisc(show(npHost), "nowPlayingPlayButton", "nowPlayingLoadingRing")
    }

    // ── Now Playing with nothing to play ─────────────────────────────────

    function test_empty_now_playing_says_so() {
        player.setCurrentTrackForTest({})
        player.setQueueForTest([], -1)
        var host = show(npHost)
        var page = host.page

        var title = findByName(page, "nowPlayingTitle")
        verify(title, "no title")
        compare(title.text, qsTranslate("PlayerBar", "No track playing"),
                "the empty page's title is not the bar's words for it")

        var hint = findByName(page, "nowPlayingEmptyHint")
        verify(hint && hint.visible && hint.text.length > 0,
               "the empty page does not say how to start")

        // Nothing that acts on a track is offered.
        var lyrics = findByName(page, "nowPlayingLyricsToggle")
        verify(lyrics && !lyrics.visible, "a Lyrics chip is offered with no track")
        var sleep = findByName(page, "nowPlayingSleepTimerButton")
        verify(sleep && !sleep.visible, "a sleep timer is offered with no track")

        // The cover box draws the placeholder glyph, not an empty square.
        var art = findByName(page, "nowPlayingArt")
        var ph = findByName(art, "coverPlaceholder")
        verify(ph && ph.visible, "the empty cover box draws nothing")

        // And a track coming in replaces all of it.
        player.setCurrentTrackForTest(makeTrack())
        tryCompare(title, "text", "Ein Titel")
        verify(!hint.visible, "the hint stays once a track is playing")
        verify(sleep.visible, "the sleep timer does not come back with a track")
    }
}
