// The cover-derived background on the fullscreen Now Playing page.
// The colour and its luminance clamp are tested in tests/tst_covercolor.cpp.
// This file covers the QML half: when the treatment is on, and that a docked
// page or a user with the preference off keeps the accent gradient.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CoverGradient"
    when: windowShown

    function trackWithCover(cover) {
        return {
            id:          4242,
            title:       "Weit hinter dem Horizont",
            artists:     "Erika Mustermann",
            artistId:    11,
            artistList:  [{ id: 11, name: "Erika Mustermann" }],
            albumTitle:  "Nachtfahrt",
            albumId:     7788,
            coverUrl:    cover,
            coverUrl80:  cover,
            duration:    215,
            durationStr: "3:35"
        }
    }

    function init() {
        // Reduced motion puts the gradient on its target in the frame it is
        // written. Set explicitly because the stub carries this preference
        // across files in this suite.
        app.setReducedMotionForTest(true)
        prefs.coverGradient = true
        player.setCurrentTrackForTest(trackWithCover("resources.example/cover/640x640.jpg"))
    }

    // Both are on a stub the whole tst_qml suite shares, so they are put back.
    function cleanup() {
        prefs.coverGradient = true
        app.setReducedMotionForTest(false)
    }

    // Main.qml's surface, as far as this page is concerned: the fullscreen
    // pair plus the sleep timer it delegates.
    Component {
        id: pageHost
        Window {
            id: win
            width: 1280; height: 900

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
            NowPlayingPage {
                id: np
                width: win.width
                height: win.height
            }
        }
    }

    function showHost() {
        var host = createTemporaryObject(pageHost, testCase)
        verify(host, "host window was not created")
        host.visible = true
        waitForRendering(host.contentItem)
        return host
    }

    function tintOf(page) {
        var t = findChild(page, "nowPlayingCoverTint")
        verify(t, "NowPlayingPage has no CoverTint called nowPlayingCoverTint")
        return t
    }

    // ── when the treatment is off ────────────────────────────────────────

    // Compared as the exact colour, so a near miss is a failure.
    function test_a_docked_page_paints_the_accent_gradient() {
        var host = showHost()
        compare(host.fullScreen, false)
        compare(tintOf(host.page).active, false,
                "the cover tint is live on a docked page")
        compare(host.page.gradientTop.toString(), Theme.accentSoft.toString(),
                "a docked page no longer paints Theme.accentSoft")
    }

    function test_the_preference_off_paints_the_accent_gradient() {
        var host = showHost()
        prefs.coverGradient = false
        host.fullScreen = true
        wait(0)
        compare(tintOf(host.page).active, false,
                "the preference is off and the cover tint is live anyway")
        compare(host.page.gradientTop.toString(), Theme.accentSoft.toString(),
                "the preference is off and the page is not painting the accent")
    }

    // ── when it is on ────────────────────────────────────────────────────

    // On by default, and only fullscreen. One test, so the two cannot come
    // apart.
    function test_fullscreen_turns_the_cover_tint_on_by_default() {
        var host = showHost()
        compare(prefs.coverGradient, true, "the preference does not default to on")
        compare(tintOf(host.page).active, false)
        host.fullScreen = true
        wait(0)
        compare(tintOf(host.page).active, true,
                "fullscreen did not turn the cover tint on")
        host.fullScreen = false
        wait(0)
        compare(tintOf(host.page).active, false,
                "leaving fullscreen did not turn the cover tint off")
        compare(host.page.gradientTop.toString(), Theme.accentSoft.toString(),
                "leaving fullscreen did not put the accent gradient back")
    }

    // The tint is keyed by the string the cover Image is sourced from, so the
    // gradient comes from the record on screen.
    function test_the_tint_follows_the_playing_track() {
        var host = showHost()
        host.fullScreen = true
        wait(0)
        compare(tintOf(host.page).coverId, "resources.example/cover/640x640.jpg")
        player.setCurrentTrackForTest(trackWithCover("resources.example/other/640x640.jpg"))
        wait(0)
        compare(tintOf(host.page).coverId, "resources.example/other/640x640.jpg")
    }

    // The test image provider hands back a transparent square, so no cover
    // has a colour and the page falls back to the accent.
    function test_an_unknown_cover_still_paints_the_accent_gradient() {
        var host = showHost()
        host.fullScreen = true
        wait(0)
        compare(tintOf(host.page).hasColor, false,
                "a cover nobody has loaded reported a colour")
        compare(host.page.gradientTop.toString(), Theme.accentSoft.toString(),
                "an unknown cover left the page with no gradient")
    }

    // A track with no artwork. The id must be empty: a missing guard would
    // produce the string undefined.
    function test_a_track_with_no_cover_has_no_tint() {
        var host = showHost()
        host.fullScreen = true
        player.setCurrentTrackForTest(trackWithCover(""))
        wait(0)
        compare(tintOf(host.page).coverId, "")
        compare(tintOf(host.page).hasColor, false)
        compare(host.page.gradientTop.toString(), Theme.accentSoft.toString())
    }

    // The clamp's band is bound to the two Theme tokens, never to a copy.
    // Switching theme here would leak into every other file in this suite;
    // tests/tst_covercolor.cpp covers the re-clamp on a palette change.
    function test_the_tint_is_measured_against_the_live_palette() {
        var host = showHost()
        var tint = tintOf(host.page)
        compare(tint.bg.toString(), Theme.bg.toString())
        compare(tint.limit.toString(), Theme.surfaceHigh.toString())
    }
}
