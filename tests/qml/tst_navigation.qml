// Navigation from the playback chrome: SPEC-0.4.0 N1 and N2.
//
// N1 — the Now Playing track title opens that track's album.
// N2 — every artist in the bottom player bar is its own link, so a two-artist
//      track sends you to whichever name you clicked. The cover, the separator
//      between two names and the empty space after them are not links: they
//      open Now Playing, the way the rest of the bar's left group does.
//
// Both hosts stand in for Main.qml, which owns the router: the page and the bar
// reach it as Window.window.navigate(page, params). The hosts record the calls
// instead of routing, so a test can say exactly where a click would have gone.
//
// The fixtures carry German titles on purpose. Track metadata is never
// translated (SPEC T3) but it is what has to fit, and German names are long.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Navigation"
    when: windowShown

    // ── fixtures ─────────────────────────────────────────────────────────

    readonly property int albumIdFixture: 7788

    // The shape TidalBridge::trackToMap() produces: the joined `artists`
    // string and the first `artistId` as before, plus `artistList` with one
    // {id, name} per artist.
    function trackWith(artists) {
        var names = []
        for (var i = 0; i < artists.length; i++) names.push(artists[i].name)
        return {
            id:          4242,
            title:       "Weit hinter dem Horizont",
            artists:     names.join(", "),
            artistId:    artists.length > 0 ? artists[0].id : 0,
            artistList:  artists,
            albumTitle:  "Nachtfahrt",
            albumId:     testCase.albumIdFixture,
            coverUrl:    "",
            coverUrl80:  "",
            duration:    215,
            durationStr: "3:35"
        }
    }

    function init() {
        player.setCurrentTrackForTest(trackWith([{ id: 11, name: "Erika Mustermann" }]))
        player.setAudioQualityForTest("LOSSLESS")
        player.setDurationForTest(215000)
        player.setPositionForTest(42000)
    }

    // ── helpers ──────────────────────────────────────────────────────────

    // Every visible descendant carrying this objectName, in tree order, which
    // for a Repeater inside a Row is left-to-right.
    function visibleNamed(item, objectName) {
        return collectNamed(item, objectName, [])
    }

    function collectNamed(item, objectName, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            if (c.objectName === objectName) out.push(c)
            collectNamed(c, objectName, out)
        }
        return out
    }

    function centerClick(item) {
        mouseClick(item, Math.round(item.width / 2), Math.round(item.height / 2))
    }

    function hover(item) {
        mouseMove(item, Math.round(item.width / 2), Math.round(item.height / 2))
        wait(0)
    }

    function rightEdgeIn(item, container) {
        return item.mapToItem(container, item.width, 0).x
    }

    // ── hosts ────────────────────────────────────────────────────────────

    Component {
        id: playerBarHost
        Window {
            id: pbWin
            width: 960; height: 200

            // Main.qml's surface, as far as the bar is concerned.
            property var navCalls: []
            property int nowPlayingOpens: 0
            property int queueOpens: 0
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}

            property alias bar: pb
            PlayerBar {
                id: pb
                width: pbWin.width
                anchors.bottom: parent.bottom
                onShowNowPlaying: pbWin.nowPlayingOpens++
                onShowQueue:      pbWin.queueOpens++
            }
        }
    }

    Component {
        id: nowPlayingHost
        Window {
            id: npWin
            width: 1280; height: 900

            // The sleep timer lives on the application window so it survives
            // navigation away from the page; the page reaches it through
            // Window.window. Mirror that surface, nothing more.
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) { sleepTimerActive = true }
            function cancelSleepTimer() { sleepTimerActive = false }
            function formatSleepTime(seconds) { return "0:30" }

            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}

            property alias page: np
            NowPlayingPage {
                id: np
                width: npWin.width
                height: npWin.height
            }
        }
    }

    function showHost(component, w, h) {
        var host = createTemporaryObject(component, testCase)
        verify(host, "host window was not created")
        host.width = w
        host.height = h
        host.visible = true
        waitForRendering(host.contentItem)
        return host
    }

    // ── N1: the Now Playing title opens the album ────────────────────────

    function test_now_playing_title_opens_its_album() {
        var host = showHost(nowPlayingHost, 1280, 900)
        var title = findChild(host.page, "nowPlayingTitle")
        verify(title, "the Now Playing track title was not found")
        compare(title.text, "Weit hinter dem Horizont")

        // Near the left edge: the hit target follows the words, not the column
        // the Text fills, so the far right of a short title is not the link.
        mouseClick(title, 6, Math.round(title.height / 2))
        compare(host.navCalls.length, 1, "clicking the title should navigate once")
        compare(host.navCalls[0].page, "album")
        compare(host.navCalls[0].params.albumId, testCase.albumIdFixture)
    }

    // A track with no album is not a dead link.
    function test_now_playing_title_without_album_does_nothing() {
        var t = trackWith([{ id: 11, name: "Erika Mustermann" }])
        t.albumId = 0
        player.setCurrentTrackForTest(t)
        var host = showHost(nowPlayingHost, 1280, 900)
        var title = findChild(host.page, "nowPlayingTitle")
        verify(title, "the Now Playing track title was not found")
        mouseClick(title, 6, Math.round(title.height / 2))
        compare(host.navCalls.length, 0, "a track with no album must not navigate")
    }

    // ── N2: one hover target per artist in the player bar ────────────────

    function test_player_bar_renders_one_target_per_artist() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(playerBarHost, 960, 200)
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 2, "each artist needs its own target")
        compare(names[0].text, "Erika Mustermann")
        compare(names[1].text, "Gastsängerin")
        // Separate items, laid out left to right without overlapping.
        verify(names[0] !== names[1], "the two names must be separate items")
        verify(rightEdgeIn(names[0], host.bar) <= names[1].mapToItem(host.bar, 0, 0).x + 0.5,
               "the two artist names overlap")
    }

    function test_player_bar_second_artist_opens_the_second_artist() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(playerBarHost, 960, 200)
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 2, "each artist needs its own target")

        centerClick(names[1])
        compare(host.navCalls.length, 1, "clicking an artist should navigate once")
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 22,
                "the second name must open the second artist, not the first")
        compare(host.nowPlayingOpens, 0, "an artist click is not a Now Playing click")
    }

    function test_player_bar_first_artist_opens_the_first_artist() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(playerBarHost, 960, 200)
        var names = visibleNamed(host.bar, "playerBarArtistName")
        centerClick(names[0])
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].params.artistId, 11)
    }

    function test_player_bar_hover_underlines_only_that_name() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(playerBarHost, 960, 200)
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 2)
        verify(!names[0].font.underline && !names[1].font.underline,
               "nothing is underlined before the pointer arrives")

        hover(names[1])
        verify(names[1].font.underline, "the hovered name should be underlined")
        verify(!names[0].font.underline, "only the hovered name should be underlined")

        hover(names[0])
        verify(names[0].font.underline, "the hovered name should be underlined")
        verify(!names[1].font.underline, "the underline should follow the pointer")
    }

    // ── what is deliberately not a link ──────────────────────────────────

    function test_player_bar_cover_still_opens_now_playing() {
        var host = showHost(playerBarHost, 960, 200)
        var cover = findChild(host.bar, "playerBarCover")
        verify(cover, "the player bar cover was not found")
        centerClick(cover)
        compare(host.nowPlayingOpens, 1, "the cover opens Now Playing")
        compare(host.navCalls.length, 0, "the cover is not an artist link")
    }

    // The ", " between two names belongs to neither of them.
    function test_player_bar_gap_between_names_opens_now_playing() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(playerBarHost, 960, 200)
        var seps = visibleNamed(host.bar, "playerBarArtistSeparator")
        compare(seps.length, 1, "two names means exactly one separator")
        verify(seps[0].width > 0, "the separator has to be clickable space")

        centerClick(seps[0])
        compare(host.navCalls.length, 0, "the separator is not an artist link")
        compare(host.nowPlayingOpens, 1, "the gap opens Now Playing")
    }

    // So does the empty space after the last name.
    function test_player_bar_space_after_the_names_opens_now_playing() {
        player.setCurrentTrackForTest(trackWith([{ id: 11, name: "Ada" }]))
        var host = showHost(playerBarHost, 960, 200)
        var line = findChild(host.bar, "playerBarArtistLine")
        verify(line, "the artist line was not found")
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 1)
        var after = rightEdgeIn(names[0], line)
        verify(line.width - after > 8, "fixture needs slack after the name")

        mouseClick(line, Math.round(line.width - 4), Math.round(line.height / 2))
        compare(host.navCalls.length, 0, "empty space is not an artist link")
        compare(host.nowPlayingOpens, 1, "empty space opens Now Playing")
    }

    // ── degenerate tracks ────────────────────────────────────────────────

    function test_player_bar_single_artist_still_works() {
        var host = showHost(playerBarHost, 960, 200)
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 1, "one artist, one target")
        compare(visibleNamed(host.bar, "playerBarArtistSeparator").length, 0,
                "a single artist needs no separator")
        centerClick(names[0])
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 11)
    }

    // Some endpoints hand back an artist with no id. It must not look or
    // behave like a link.
    function test_player_bar_artist_without_id_is_not_a_target() {
        player.setCurrentTrackForTest(trackWith([{ id: 0, name: "Unbekannt" }]))
        var host = showHost(playerBarHost, 960, 200)
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 1, "the name still shows, it just does not link")

        hover(names[0])
        verify(!names[0].font.underline, "an artist with no id must not look clickable")
        centerClick(names[0])
        compare(host.navCalls.length, 0, "an artist with no id must not navigate")
        compare(host.nowPlayingOpens, 1, "it falls through like the gaps do")
    }

    // Tracks whose map predates `artistList` (saved recently-played entries,
    // and anything built by hand) still have to show their artists.
    function test_player_bar_falls_back_to_the_joined_names() {
        player.setCurrentTrackForTest({
            id: 99, title: "Ohne Liste", artists: "Erika Mustermann, Gastsängerin",
            artistId: 11, albumId: 7788, albumTitle: "Nachtfahrt", coverUrl: "",
            duration: 100, durationStr: "1:40"
        })
        var host = showHost(playerBarHost, 960, 200)
        compare(visibleNamed(host.bar, "playerBarArtistName").length, 0,
                "no artist list means no per-artist targets")
        var joined = findChild(host.bar, "playerBarArtists")
        verify(joined, "the joined artists line was not found")
        verify(joined.visible, "the joined artists line should stand in")
        compare(joined.text, "Erika Mustermann, Gastsängerin")
    }

    // ── when it is tight ─────────────────────────────────────────────────

    // Long names must elide or drop out, never push past the line they sit in.
    // 640 is the narrow end of the supported range, where the bar is already
    // in its compact mode.
    function test_player_bar_long_names_stay_inside_the_line() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Rundfunk-Tanzorchester Ehrenfeld" },
            { id: 22, name: "Mitteldeutscher Kammerchor" },
            { id: 33, name: "Johanna von Hohenzollern-Sigmaringen" }
        ]))
        var host = showHost(playerBarHost, 640, 200)
        var line = findChild(host.bar, "playerBarArtistLine")
        verify(line, "the artist line was not found")
        var names = visibleNamed(host.bar, "playerBarArtistName")
        verify(names.length >= 1, "the first name must survive however tight it is")
        verify(names.length < 3 || names[names.length - 1].truncated,
               "three long names in a compact bar should have elided or dropped one")

        for (var i = 0; i < names.length; i++) {
            verify(rightEdgeIn(names[i], line) <= line.width + 0.5,
                   "\"" + names[i].text + "\" runs " +
                   (rightEdgeIn(names[i], line) - line.width).toFixed(1) +
                   "px past the artist line")
            verify(names[i].width >= 8,
                   "\"" + names[i].text + "\" was squeezed to " +
                   names[i].width.toFixed(1) + "px, which is not a hit target")
        }
    }

    // ── N2 in Now Playing as well ────────────────────────────────────────
    //
    // The user: "the singular artist link underline thing from the bar at the
    // bottom obviously also have that in the now playing window." Same
    // behaviour, same treatment -- textSec at rest, textPrimary and underlined
    // under the pointer -- at the page's own 18px, and with the page's keyboard
    // handling carried over per name rather than over the joined blob.

    function test_now_playing_renders_one_target_per_artist() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(nowPlayingHost, 1280, 900)
        var names = visibleNamed(host.page, "nowPlayingArtistName")
        compare(names.length, 2, "each artist needs its own target")
        compare(names[0].text, "Erika Mustermann")
        compare(names[1].text, "Gastsängerin")
        verify(names[0] !== names[1], "the two names must be separate items")
        verify(rightEdgeIn(names[0], host.page) <= names[1].mapToItem(host.page, 0, 0).x + 0.5,
               "the two artist names overlap")
        // The joined one-link version is what it replaces, so it must be gone.
        var joined = findChild(host.page, "nowPlayingArtists")
        verify(joined, "the joined fallback line was not found")
        verify(!joined.visible, "the joined line should stand down for the per-name row")
    }

    function test_now_playing_second_artist_opens_the_second_artist() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(nowPlayingHost, 1280, 900)
        var names = visibleNamed(host.page, "nowPlayingArtistName")
        compare(names.length, 2)
        centerClick(names[1])
        compare(host.navCalls.length, 1, "clicking an artist should navigate once")
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 22,
                "the second name must open the second artist, not the lead")
    }

    function test_now_playing_first_artist_opens_the_first_artist() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(nowPlayingHost, 1280, 900)
        var names = visibleNamed(host.page, "nowPlayingArtistName")
        centerClick(names[0])
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].params.artistId, 11)
    }

    function test_now_playing_hover_underlines_only_that_name() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(nowPlayingHost, 1280, 900)
        var names = visibleNamed(host.page, "nowPlayingArtistName")
        compare(names.length, 2)
        verify(!names[0].font.underline && !names[1].font.underline,
               "nothing is underlined before the pointer arrives")

        hover(names[1])
        verify(names[1].font.underline, "the hovered name should be underlined")
        verify(!names[0].font.underline, "only the hovered name should be underlined")

        hover(names[0])
        verify(names[0].font.underline, "the hovered name should be underlined")
        verify(!names[1].font.underline, "the underline should follow the pointer")
    }

    // The colour is the bar's, not the page's old accent. Now Playing is being
    // cleared of accent-coloured content so a cover-derived background can go
    // behind it, and this line was the first of that.
    function test_now_playing_artist_names_are_not_accent_coloured() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(nowPlayingHost, 1280, 900)
        var names = visibleNamed(host.page, "nowPlayingArtistName")
        compare(names.length, 2)
        for (var i = 0; i < names.length; i++) {
            compare(names[i].color.toString(), Theme.textSec.toString(),
                    "\"" + names[i].text + "\" is not the bar's resting colour")
            verify(names[i].color.toString() !== Theme.accent.toString(),
                   "artist names must not be accent-coloured in Now Playing")
        }
        var seps = visibleNamed(host.page, "nowPlayingArtistSeparator")
        compare(seps.length, 1)
        compare(seps[0].color.toString(), Theme.textSec.toString(),
                "the separator goes with the names")

        hover(names[1])
        compare(names[1].color.toString(), Theme.textPrimary.toString(),
                "hover brightens the name")
        compare(names[0].color.toString(), Theme.textSec.toString(), "and only that one")
    }

    // The page's keyboard handling came over per name: 18px and the focus ring
    // are the page's, but there is one tab stop per artist now, not one blob.
    function test_now_playing_each_artist_is_its_own_tab_stop() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(nowPlayingHost, 1280, 900)
        var names = visibleNamed(host.page, "nowPlayingArtistName")
        compare(names.length, 2)
        for (var i = 0; i < names.length; i++)
            verify(names[i].activeFocusOnTab,
                   "\"" + names[i].text + "\" is not reachable by tab")

        names[1].forceActiveFocus()
        verify(names[1].activeFocus, "the second name did not take focus")
        keyClick(Qt.Key_Return)
        compare(host.navCalls.length, 1, "Return on a focused name should navigate")
        compare(host.navCalls[0].params.artistId, 22)

        names[0].forceActiveFocus()
        keyClick(Qt.Key_Space)
        compare(host.navCalls.length, 2, "Space should work the same way")
        compare(host.navCalls[1].params.artistId, 11)
    }

    function test_now_playing_artist_without_id_is_not_a_target() {
        player.setCurrentTrackForTest(trackWith([{ id: 0, name: "Unbekannt" }]))
        var host = showHost(nowPlayingHost, 1280, 900)
        var names = visibleNamed(host.page, "nowPlayingArtistName")
        compare(names.length, 1, "the name still shows, it just does not link")
        verify(!names[0].activeFocusOnTab, "a dead credit is not a tab stop")
        hover(names[0])
        verify(!names[0].font.underline, "an artist with no id must not look clickable")
        centerClick(names[0])
        compare(host.navCalls.length, 0, "an artist with no id must not navigate")
    }

    // Tracks whose map predates `artistList` keep the one link they can have.
    function test_now_playing_falls_back_to_the_joined_names() {
        player.setCurrentTrackForTest({
            id: 99, title: "Ohne Liste", artists: "Erika Mustermann, Gastsängerin",
            artistId: 11, albumId: 7788, albumTitle: "Nachtfahrt", coverUrl: "",
            duration: 100, durationStr: "1:40"
        })
        var host = showHost(nowPlayingHost, 1280, 900)
        compare(visibleNamed(host.page, "nowPlayingArtistName").length, 0,
                "no artist list means no per-artist targets")
        var joined = findChild(host.page, "nowPlayingArtists")
        verify(joined && joined.visible, "the joined artists line should stand in")
        compare(joined.text, "Erika Mustermann, Gastsängerin")
        compare(joined.color.toString(), Theme.textSec.toString(),
                "the fallback takes the same colour")
        // Near the left edge: the hit target follows the words, not the column.
        mouseClick(joined, 6, Math.round(joined.height / 2))
        compare(host.navCalls.length, 1, "the fallback still opens the lead artist")
        compare(host.navCalls[0].params.artistId, 11)
    }

    // Long names must elide or drop out, never push past the line they sit in.
    // 640 is the narrow end of the supported range, where the page is stacked
    // and the text column is at its tightest.
    function test_now_playing_long_names_stay_inside_the_line() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Rundfunk-Tanzorchester Ehrenfeld" },
            { id: 22, name: "Mitteldeutscher Kammerchor" },
            { id: 33, name: "Johanna von Hohenzollern-Sigmaringen" }
        ]))
        var host = showHost(nowPlayingHost, 640, 600)
        // 640 is below the stack breakpoint and the host is born wide, so the
        // page is still re-forming; the measurements below are about the layout
        // it comes to rest in.
        tryVerify(function () {
            return host.page.stackness === (host.page.stackedLayout ? 1 : 0)
        }, 2000, "the page never settled at 640")
        var line = findChild(host.page, "nowPlayingArtistLine")
        verify(line, "the artist line was not found")
        var names = visibleNamed(host.page, "nowPlayingArtistName")
        verify(names.length >= 1, "the first name must survive however tight it is")
        verify(names.length < 3 || names[names.length - 1].truncated,
               "three long names in a narrow column should have elided or dropped one")
        for (var i = 0; i < names.length; i++) {
            verify(rightEdgeIn(names[i], line) <= line.width + 0.5,
                   "\"" + names[i].text + "\" runs "
                   + (rightEdgeIn(names[i], line) - line.width).toFixed(1)
                   + "px past the artist line")
            verify(names[i].width >= 8,
                   "\"" + names[i].text + "\" was squeezed to "
                   + names[i].width.toFixed(1) + "px, which is not a hit target")
        }
    }

    // The links have to keep working once the bar sheds its volume slider.
    function test_player_bar_links_work_in_compact_mode() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Ada" },
            { id: 22, name: "Bela" }
        ]))
        var host = showHost(playerBarHost, 640, 200)
        verify(host.bar.compactRight, "640 should be below the compact breakpoint")
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 2, "both names fit even at 640")
        centerClick(names[1])
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].params.artistId, 22)
    }
}
