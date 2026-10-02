// The cover-derived background on the fullscreen Now Playing page.
//
// The colour itself - what is pulled out of a sleeve, and the luminance clamp
// that keeps the page readable over it - is tests/tst_covercolor.cpp's job,
// where synthetic covers can be fed in and the result measured against every
// palette. What is left for here is the half that only exists in the QML: when
// the treatment is on at all, and that the page it replaces is still the page
// it was.
//
// That second half is the one worth having. The gradient has been
// Theme.accentSoft fading into Theme.bg since the page was written, and the
// agreement is that a docked page, or a user who turns the preference off,
// keeps exactly that. So the assertions below are mostly about the feature
// *not* happening.

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
        // The gradient eases between two colours, and every assertion here is
        // about where it lands rather than how it gets there. Reduced motion
        // collapses Theme.dur() to zero, so the property is on its target in
        // the frame it was written. Set explicitly because the stub carries
        // this preference across files in this suite.
        app.setReducedMotionForTest(true)
        prefs.coverGradient = true
        player.setCurrentTrackForTest(trackWithCover("resources.example/cover/640x640.jpg"))
    }

    // Both of those are on a stub that the whole tst_qml suite shares, so
    // they go back the way they were found rather than leaking into whichever
    // file runs next.
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

    // The page as it has always been. Not "something close to accentSoft":
    // the same colour, so a regression here is a failure and not a judgement
    // call about how different two blues are.
    function test_a_docked_page_paints_the_accent_gradient() {
        var host = showHost()
        compare(host.fullScreen, false)
        compare(tintOf(host.page).active, false,
                "the cover tint is live on a docked page")
        compare(host.page.gradientTop.toString(), Theme.accentSoft.toString(),
                "a docked page no longer paints Theme.accentSoft")
    }

    // Fullscreen, preference off: still the accent gradient. This is the one
    // the preference exists for.
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

    // On by default, and only fullscreen. Both halves in one test, because
    // the bug worth catching is the two coming apart.
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

    // The tint is keyed by the same string the cover Image is sourced from.
    // If these two ever part company the gradient would be derived from a
    // different record than the one on screen.
    function test_the_tint_follows_the_playing_track() {
        var host = showHost()
        host.fullScreen = true
        wait(0)
        compare(tintOf(host.page).coverId, "resources.example/cover/640x640.jpg")
        player.setCurrentTrackForTest(trackWithCover("resources.example/other/640x640.jpg"))
        wait(0)
        compare(tintOf(host.page).coverId, "resources.example/other/640x640.jpg")
    }

    // Nothing has been downloaded in this suite - the test image provider
    // hands back a transparent square - so there is no colour for any cover,
    // and the page has to fall back rather than paint a hole.
    function test_an_unknown_cover_still_paints_the_accent_gradient() {
        var host = showHost()
        host.fullScreen = true
        wait(0)
        compare(tintOf(host.page).hasColor, false,
                "a cover nobody has loaded reported a colour")
        compare(host.page.gradientTop.toString(), Theme.accentSoft.toString(),
                "an unknown cover left the page with no gradient")
    }

    // A track with no artwork at all. The id has to be empty rather than the
    // string "undefined", which is what a missing guard would produce.
    function test_a_track_with_no_cover_has_no_tint() {
        var host = showHost()
        host.fullScreen = true
        player.setCurrentTrackForTest(trackWithCover(""))
        wait(0)
        compare(tintOf(host.page).coverId, "")
        compare(tintOf(host.page).hasColor, false)
        compare(host.page.gradientTop.toString(), Theme.accentSoft.toString())
    }

    // The band the clamp works in is the palette's, so it has to be bound to
    // the two Theme tokens and not to a copy of them. (That the colour then
    // re-clamps when the palette moves is aThemeChangeReclampsTheSameCover()
    // in tests/tst_covercolor.cpp; switching theme here would leak into every
    // other file in this suite, which shares one prefs stub.)
    function test_the_tint_is_measured_against_the_live_palette() {
        var host = showHost()
        var tint = tintOf(host.page)
        compare(tint.bg.toString(), Theme.bg.toString())
        compare(tint.limit.toString(), Theme.surfaceHigh.toString())
    }
}
