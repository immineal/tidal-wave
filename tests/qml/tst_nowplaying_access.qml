// Getting into Now Playing, and back out of it: the bar's up-arrow, the
// page's down-arrow and the fullscreen toggle. Three hosts: playerBarHost
// records where a click on the bar would go, nowPlayingHost gives the page the
// window surface it reaches through Window.window, and appWindowHost is the
// real Main.qml, which owns the window state and the Escape precedence.
// The left group's own behaviour is covered by tst_navigation.qml.

import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "NowPlayingAccess"
    when: windowShown

    // ── fixtures ─────────────────────────────────────────────────────────

    // The shape TidalBridge::trackToMap() produces. German names on purpose:
    // track metadata is never translated, and it is what has to fit.
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
            albumId:     7788,
            coverUrl:    "",
            coverUrl80:  "",
            duration:    215,
            durationStr: "3:35"
        }
    }

    function init() {
        // The two cases that cross a breakpoint measure a transition, so motion
        // has to be allowed. Another file in this suite turns the preference on
        // and the stub carries it across files.
        app.setReducedMotionForTest(false)
        player.setCurrentTrackForTest(trackWith([{ id: 11, name: "Erika Mustermann" }]))
        player.setAudioQualityForTest("LOSSLESS")
        player.setDurationForTest(215000)
        player.setPositionForTest(42000)
        auth.setStateForTest(2)   // LoggedIn: Main.qml gates its shortcuts on it
    }

    // The four test widths. 640 is the narrow end of the supported range.
    function widthRows() {
        return [
            { tag: "640",  w: 640  },
            { tag: "820",  w: 820  },
            { tag: "960",  w: 960  },
            { tag: "1280", w: 1280 }
        ]
    }

    // ── helpers ──────────────────────────────────────────────────────────

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

    // The QML type a visible item was built from, for finding something that
    // carries no objectName of its own.
    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    function findByType(item, wanted) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            if (typeName(c) === wanted) return c
            var found = findByType(c, wanted)
            if (found) return found
        }
        return null
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
            // Window.window. Mirror that surface, plus the fullscreen pair.
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) { sleepTimerActive = true }
            function cancelSleepTimer() { sleepTimerActive = false }
            function formatSleepTime(seconds) { return "0:30" }

            property var navCalls: []
            property int backCalls: 0
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() { backCalls++ }

            // Stands in for the real window state, which Main.qml owns.
            property bool fullScreen: false
            property int  fullScreenToggles: 0
            function toggleFullScreen() {
                fullScreen = !fullScreen
                fullScreenToggles++
            }

            property alias page: np
            NowPlayingPage {
                id: np
                width: npWin.width
                height: npWin.height
            }
        }
    }

    // The real application window. Nothing else can answer whether Escape
    // leaves fullscreen before it navigates back.
    Component {
        id: appWindowHost
        Main {}
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

    function showApp() {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        win.requestActivate()
        waitForRendering(win.contentItem)
        return win
    }

    // ── the way in: the player bar's Now Playing button ──────────────────

    function test_bar_button_is_present_and_inside_the_bar_data() { return widthRows() }

    function test_bar_button_is_present_and_inside_the_bar(row) {
        var host = showHost(playerBarHost, row.w, 200)
        var bar = host.bar
        var btn = bar.nowPlayingButton
        verify(btn, "the Now Playing button was not found")
        verify(btn.visible, "the Now Playing button must not need a hover to appear")

        var left  = btn.mapToItem(bar, 0, 0).x
        var right = rightEdgeIn(btn, bar)
        verify(left >= -0.5 && right <= bar.width + 0.5,
               "the Now Playing button sits at " + left.toFixed(1) + ".."
               + right.toFixed(1) + " in a " + bar.width + "px bar at " + row.tag)
        verify(btn.width >= 24 && btn.height >= 24,
               "the button is " + btn.width + "x" + btn.height + ", too small to aim at")

        // The button opens a view, so it sits with the queue button and outside
        // the track info group, whose declared widths stay as they are.
        var group = bar.trackInfoGroup
        compare(group.Layout.preferredWidth, 280,
                "the left group's preferred width moved")
        compare(group.Layout.minimumWidth, 200, "the left group's floor moved")
        var p = btn.parent
        while (p) {
            verify(p !== group,
                   "the Now Playing button is still inside the track info group at " + row.tag)
            p = p.parent
        }
    }

    function test_bar_button_sits_left_of_the_queue_button_data() { return widthRows() }

    function test_bar_button_sits_left_of_the_queue_button(row) {
        var host = showHost(playerBarHost, row.w, 200)
        var bar = host.bar
        var arrow = bar.nowPlayingButton
        var queue = bar.queueButton
        verify(arrow.visible && queue.visible, "both controls have to be on screen")

        var arrowRight = rightEdgeIn(arrow, bar)
        var queueLeft  = queue.mapToItem(bar, 0, 0).x
        verify(arrowRight <= queueLeft + 0.5,
               "the arrow ends at " + arrowRight.toFixed(1)
               + " but the queue button starts at " + queueLeft.toFixed(1)
               + " at " + row.tag)

        // Grouped: nothing of the bar's own may sit between them. The gap is the
        // right group's spacing.
        verify(queueLeft - arrowRight <= 12,
               "there are " + (queueLeft - arrowRight).toFixed(1)
               + "px between the arrow and the queue button at " + row.tag)
    }

    function test_bar_button_opens_now_playing() {
        var host = showHost(playerBarHost, 960, 200)
        centerClick(host.bar.nowPlayingButton)
        compare(host.nowPlayingOpens, 1, "the button should open Now Playing exactly once")
        compare(host.navCalls.length, 0, "the button is not a navigation link")
    }

    function test_bar_button_is_not_an_artist_link() {
        player.setCurrentTrackForTest(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" }
        ]))
        var host = showHost(playerBarHost, 640, 200)
        centerClick(host.bar.nowPlayingButton)
        compare(host.navCalls.length, 0)
        compare(host.nowPlayingOpens, 1)
    }

    // ── and while the chrome resizes ─────────────────────────────────────
    // Both controls sit in the bar's right-hand group, which keeps one width
    // at every window width. A resize must never take either off the bar or
    // pull them apart, measured every frame and clicked in the middle.

    function test_the_way_in_stays_grouped_while_the_bar_resizes() {
        var host = showHost(playerBarHost, 760, 200)
        var bar = host.bar

        host.width = 700
        // A Window's own width moves on assignment and the items inside it only
        // on the next turn, so a frame is waited for before measuring.
        waitForRendering(host.contentItem)
        for (var i = 0; i < 14; i++) {
            var arrow = bar.nowPlayingButton
            var queue = bar.queueButton
            verify(arrow.visible && queue.visible,
                   "sample " + i + ": a control went missing mid-resize")
            var arrowLeft  = arrow.mapToItem(bar, 0, 0).x
            var arrowRight = rightEdgeIn(arrow, bar)
            var queueLeft  = queue.mapToItem(bar, 0, 0).x
            verify(arrowLeft >= -0.5 && rightEdgeIn(queue, bar) <= bar.width + 0.5,
                   "sample " + i + ": the pair left the bar while it resized ("
                   + arrowLeft.toFixed(1) + ".." + rightEdgeIn(queue, bar).toFixed(1)
                   + " in " + bar.width + "px)")
            verify(arrowRight <= queueLeft + 0.5 && queueLeft - arrowRight <= 12,
                   "sample " + i + ": the arrow and the queue button came apart ("
                   + (queueLeft - arrowRight).toFixed(1) + "px) while the bar resized")
            // Mid-resize, with the window still settling, the button still
            // opens the page.
            if (i === 2) {
                centerClick(arrow)
                compare(host.nowPlayingOpens, 1,
                        "the button did not open Now Playing while the bar was moving")
            }
            wait(16)
        }
        compare(host.nowPlayingOpens, 1, "exactly one way in was taken")
        compare(host.navCalls.length, 0, "the button is not a navigation link")
    }

    // The same question of the page: it rearranges at 1000px, and the down
    // arrow is the way back out of it.
    function test_the_way_out_survives_the_page_restacking() {
        var host = showHost(nowPlayingHost, 1280, 900)
        var page = host.page
        tryVerify(function () { return page.stackness === 0 }, 2000,
                  "the page never settled side by side")

        var collapse = findChild(page, "nowPlayingCollapse")
        var fs = findChild(page, "nowPlayingFullscreen")
        verify(collapse && fs, "the page's own chrome was not found")

        host.width = 900
        var mid = 0
        var clicked = false
        for (var i = 0; i < 14; i++) {
            wait(16)
            verify(collapse.visible && fs.visible,
                   "sample " + i + ": the page's chrome went missing mid-restack")
            verify(collapse.mapToItem(page, 0, 0).x >= -0.5
                   && rightEdgeIn(fs, page) <= page.width + 0.5,
                   "sample " + i + ": the header left the page while it restacked")
            if (page.stackness > 0.001 && page.stackness < 0.999) {
                mid++
                if (mid === 2 && !clicked) {
                    clicked = true
                    centerClick(collapse)
                    compare(host.backCalls, 1,
                            "the way out did not work while the page was restacking")
                }
            }
        }
        verify(mid >= 3, "the page restacked without ever being between its two layouts")
        compare(host.backCalls, 1, "going back happened once and only once")
        compare(host.navCalls.length, 0, "going back is not a navigation of its own")
    }

    // ── the left group is untouched ──────────────────────────────────────

    function test_cover_still_opens_now_playing() {
        var host = showHost(playerBarHost, 960, 200)
        var cover = findChild(host.bar, "playerBarCover")
        verify(cover, "the player bar cover was not found")
        centerClick(cover)
        compare(host.nowPlayingOpens, 1, "the cover opens Now Playing")
        compare(host.navCalls.length, 0, "the cover is not an artist link")
    }

    function test_artist_name_opens_that_artist_and_not_now_playing() {
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
                "the second name must open the second artist")
        compare(host.nowPlayingOpens, 0, "an artist click is not a Now Playing click")
    }

    function test_gap_after_the_names_opens_now_playing() {
        player.setCurrentTrackForTest(trackWith([{ id: 11, name: "Ada" }]))
        var host = showHost(playerBarHost, 960, 200)
        var line = findChild(host.bar, "playerBarArtistLine")
        verify(line, "the artist line was not found")
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 1)
        verify(line.width - rightEdgeIn(names[0], line) > 8, "fixture needs slack after the name")

        mouseClick(line, Math.round(line.width - 4), Math.round(line.height / 2))
        compare(host.navCalls.length, 0, "empty space is not an artist link")
        compare(host.nowPlayingOpens, 1, "empty space opens Now Playing")
    }

    function test_hover_underlines_only_the_name_under_the_pointer() {
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

        // The button is not part of the artist line, so pointing at it must
        // not leave an underline behind.
        hover(host.bar.nowPlayingButton)
        verify(!names[0].font.underline && !names[1].font.underline,
               "the underline should have followed the pointer off the names")
    }

    // Some endpoints hand back artists with no id. Nothing in the group may
    // become a dead target because of it.
    function test_track_without_artist_ids_still_works() {
        player.setCurrentTrackForTest(trackWith([{ id: 0, name: "Unbekannt" }]))
        var host = showHost(playerBarHost, 960, 200)
        var names = visibleNamed(host.bar, "playerBarArtistName")
        compare(names.length, 1, "the name still shows, it just does not link")

        hover(names[0])
        verify(!names[0].font.underline, "an artist with no id must not look clickable")
        centerClick(names[0])
        compare(host.navCalls.length, 0, "an artist with no id must not navigate")
        compare(host.nowPlayingOpens, 1, "it falls through like the gaps do")

        centerClick(host.bar.nowPlayingButton)
        compare(host.nowPlayingOpens, 2, "the button works whatever the track carries")
    }

    // ── the way out: the page's own chrome ───────────────────────────────

    function test_now_playing_collapse_returns_data() { return widthRows() }

    function test_now_playing_collapse_returns(row) {
        var host = showHost(nowPlayingHost, row.w, 800)
        var collapse = findChild(host.page, "nowPlayingCollapse")
        verify(collapse, "the Now Playing collapse button was not found at " + row.tag)
        verify(collapse.visible, "the way out must be visible at " + row.tag)

        var right = rightEdgeIn(collapse, host.page)
        verify(collapse.mapToItem(host.page, 0, 0).x >= -0.5 && right <= host.page.width + 0.5,
               "the collapse button is outside the page at " + row.tag)

        centerClick(collapse)
        compare(host.backCalls, 1, "the down-arrow should go back exactly once")
        compare(host.navCalls.length, 0, "going back is not a navigation of its own")
    }

    function test_now_playing_fullscreen_button_asks_the_window() {
        var host = showHost(nowPlayingHost, 1280, 800)
        var fs = findChild(host.page, "nowPlayingFullscreen")
        verify(fs, "the fullscreen toggle was not found")

        centerClick(fs)
        compare(host.fullScreenToggles, 1, "the toggle should ask the window exactly once")
        compare(host.fullScreen, true)
        compare(host.backCalls, 0, "the fullscreen toggle is not the way out")

        // The same button comes back out.
        centerClick(fs)
        compare(host.fullScreenToggles, 2)
        compare(host.fullScreen, false)
    }

    // ── the window state: Main.qml ───────────────────────────────────────

    function test_fullscreen_toggle_sets_and_clears_window_visibility() {
        var win = showApp()
        win.navigate("nowplaying")
        compare(win.currentPage, "nowplaying")
        verify(!win.fullScreen, "the window must not start fullscreen")
        var before = win.visibility

        win.toggleFullScreen()
        tryVerify(function() { return win.visibility === Window.FullScreen }, 2000,
                  "the toggle did not take the window fullscreen")
        verify(win.fullScreen, "fullScreen should follow the window's visibility")

        win.toggleFullScreen()
        tryVerify(function() { return win.visibility === before }, 2000,
                  "leaving fullscreen did not restore the visibility it found")
        verify(!win.fullScreen)
    }

    // A maximised window has to come back maximised: restoring to a hardcoded
    // Windowed would quietly un-maximise it.
    function test_fullscreen_restores_a_maximised_window() {
        var win = showApp()
        win.visibility = Window.Maximized
        tryVerify(function() { return win.visibility === Window.Maximized }, 2000,
                  "the platform would not maximise the window")
        win.navigate("nowplaying")

        win.toggleFullScreen()
        tryVerify(function() { return win.visibility === Window.FullScreen }, 2000)
        win.toggleFullScreen()
        tryVerify(function() { return win.visibility === Window.Maximized }, 2000,
                  "the window came back from fullscreen un-maximised")
    }

    // The window manager has its own ways out of fullscreen, and Main.qml
    // only hears of them through the window's visibility. fullScreen is
    // assigned, never bound: on Qt 6.4 the binding reads stale within the turn.
    function test_the_window_manager_can_leave_fullscreen_too() {
        var win = showApp()
        win.navigate("nowplaying")
        win.toggleFullScreen()
        verify(win.fullScreen,
               "the window should be in fullscreen before anything moves it")

        // Not leaveFullScreen(): this is the window changing under the app.
        win.visibility = Window.Windowed
        tryVerify(function () { return !win.fullScreen }, 2000,
                  "fullScreen stayed set after the window left fullscreen on its own")

        win.visibility = Window.FullScreen
        tryVerify(function () { return win.fullScreen }, 2000,
                  "fullScreen stayed clear after the window went fullscreen on its own")
    }

    // Fullscreen is Now Playing's, so following a link out of the page brings
    // the window back with it.
    function test_navigating_away_leaves_fullscreen() {
        var win = showApp()
        win.navigate("nowplaying")
        win.toggleFullScreen()
        tryVerify(function() { return win.fullScreen }, 2000)

        win.navigate("home")
        tryVerify(function() { return !win.fullScreen }, 2000,
                  "navigating away from Now Playing should leave fullscreen")
    }

    function test_fullscreen_hides_the_sidebar() {
        var win = showApp()
        win.navigate("nowplaying")
        var sidebar = findByType(win.contentItem, "SideBar")
        verify(sidebar, "the sidebar was not found in the application window")
        verify(sidebar.visible, "the sidebar should be up before fullscreen")

        win.toggleFullScreen()
        tryVerify(function() { return !sidebar.visible }, 2000,
                  "fullscreen should hide the sidebar")

        win.toggleFullScreen()
        tryVerify(function() { return sidebar.visible }, 2000,
                  "leaving fullscreen should bring the sidebar back")
    }

    // Every way out of fullscreen is gated on being signed in, or on the page
    // that signing out takes away, so signing out has to do it for the user.
    function test_signing_out_leaves_fullscreen() {
        var win = showApp()
        win.navigate("nowplaying")
        win.toggleFullScreen()
        tryVerify(function() { return win.fullScreen }, 2000)

        auth.setStateForTest(0)   // LoggedOut
        tryVerify(function() { return !win.fullScreen }, 2000,
                  "signing out left a fullscreen window with no way back")
        auth.setStateForTest(2)
    }

    // Escape already navigates back application-wide. Fullscreen has to come
    // first, or the first Escape would both leave the page and leave the
    // window in a state the user never asked to keep.
    function test_escape_leaves_fullscreen_before_navigating_back() {
        var win = showApp()
        compare(win.currentPage, "home", "the app should start at home")
        win.navigate("nowplaying")
        win.toggleFullScreen()
        tryVerify(function() { return win.fullScreen }, 2000)

        keyClick(Qt.Key_Escape)
        tryVerify(function() { return !win.fullScreen }, 2000,
                  "the first Escape did not leave fullscreen")
        compare(win.currentPage, "nowplaying",
                "the first Escape navigated back as well as leaving fullscreen")

        keyClick(Qt.Key_Escape)
        tryVerify(function() { return win.currentPage === "home" }, 2000,
                  "the second Escape should navigate back")
    }

    // ── F11 is a toggle, so it puts the view back as well ────────────────
    // F11 opens Now Playing on its way into fullscreen, and leaving goes
    // back to the page fullscreen covered. getLoader() has an entry for the
    // playlist and none for radio, so the two take different branches.
    function test_fullscreen_from_another_page_collapses_now_playing_again_data() {
        return [
            { tag: "playlist", page: "playlist", type: "PlaylistPage",
              params: { playlistUuid: "spaetschicht-1", playlistTitle: "Spätschicht" },
              key: "playlistUuid", value: "spaetschicht-1" },
            { tag: "radio", page: "radio", type: "RadioPage",
              params: { trackId: 4242, radioTitle: "Weit hinter dem Horizont" },
              key: "trackId", value: 4242 }
        ]
    }

    function test_fullscreen_from_another_page_collapses_now_playing_again(row) {
        var win = showApp()
        win.navigate(row.page, row.params)
        compare(win.currentPage, row.page, "the fixture never reached the " + row.tag)

        win.toggleFullScreen()
        compare(win.currentPage, "nowplaying",
                "F11 should open Now Playing on the way into fullscreen")
        tryVerify(function () { return win.visibility === Window.FullScreen }, 2000,
                  "the toggle did not take the window fullscreen")

        win.toggleFullScreen()
        compare(win.currentPage, row.page,
                "leaving fullscreen left the user in a windowed Now Playing instead of"
                + " back in the " + row.tag + " F11 was pressed from")
        verify(!win.fullScreen, "the window stayed fullscreen")
        tryVerify(function () { return win.visibility !== Window.FullScreen }, 2000,
                  "the window stayed fullscreen")

        // That page, with the parameters it was opened with.
        tryVerify(function () {
            var item = findByType(win.contentItem, row.type)
            return item && item[row.key] === row.value
        }, 2000, "the user came back to a " + row.tag + ", but not the one they left")
    }

    // Both presses inside one turn. Deciding what to restore may not wait on
    // visibilityChanged, which arrives later on Qt 6.4.
    function test_two_presses_in_one_turn_still_land_back_on_the_playlist() {
        var win = showApp()
        win.navigate("playlist", { playlistUuid: "spaetschicht-2" })
        compare(win.currentPage, "playlist")

        win.toggleFullScreen()
        win.toggleFullScreen()
        compare(win.currentPage, "playlist",
                "two F11s in one turn left the user in Now Playing")
        tryVerify(function () { return win.visibility !== Window.FullScreen }, 2000,
                  "two F11s in one turn left the window fullscreen")
    }

    // Pressed from inside Now Playing, the toggle has no navigation to undo,
    // so it must not close the page.
    function test_fullscreen_from_now_playing_stays_in_now_playing() {
        var win = showApp()
        win.navigate("playlist", { playlistUuid: "spaetschicht-3" })
        win.navigate("nowplaying")
        compare(win.currentPage, "nowplaying", "the fixture never reached Now Playing")

        win.toggleFullScreen()
        tryVerify(function () { return win.visibility === Window.FullScreen }, 2000)
        win.toggleFullScreen()
        compare(win.currentPage, "nowplaying",
                "F11 pressed from inside Now Playing collapsed the page the user was on")
        tryVerify(function () { return win.visibility !== Window.FullScreen }, 2000)
    }

    // What comes back is this toggle's own navigation and nothing else. A
    // window that the window manager took fullscreen on another page has
    // nothing for F11 to put back.
    function test_leaving_fullscreen_does_not_navigate_off_another_page() {
        var win = showApp()
        win.navigate("playlist", { playlistUuid: "spaetschicht-4" })
        // Through the toggle once, so a stale recorded page exists by the time
        // the window goes fullscreen on its own.
        win.toggleFullScreen()
        win.toggleFullScreen()
        compare(win.currentPage, "playlist",
                "the fixture needs the toggle's own round trip to work first")

        win.visibility = Window.FullScreen
        tryVerify(function () { return win.fullScreen }, 2000,
                  "the window never went fullscreen on its own")
        compare(win.currentPage, "playlist",
                "the window manager's route in should not navigate anywhere")

        win.toggleFullScreen()
        compare(win.currentPage, "playlist",
                "F11 navigated away from the page it was pressed on")
        tryVerify(function () { return win.visibility !== Window.FullScreen }, 2000,
                  "F11 did not bring the window out of fullscreen")
    }

    // ── the chevron while the window is fullscreen ───────────────────────
    // The chevron is goBack() and nothing else. What leaves fullscreen is
    // navigate() in Main.qml, for any page other than Now Playing. Both ways
    // into fullscreen are covered, because they record different pages.

    // Now Playing slides up out of the player bar in the application window.
    // A synthesized click is delivered at a position, so both helpers below
    // wait for the page to arrive first.
    function arrivedNowPlaying(win) {
        tryVerify(function () { return win.nowPlayingness === 1 }, 2000,
                  "Now Playing never finished sliding up, so nothing on it can be aimed at")
        waitForRendering(win.contentItem, 2000)
    }

    function chevronIn(win) {
        arrivedNowPlaying(win)
        var c = findChild(win.contentItem, "nowPlayingCollapse")
        verify(c, "the Now Playing chevron was not found in the application window")
        verify(c.visible, "the chevron is not on screen, so the user cannot press it")
        return c
    }

    function fullscreenButtonIn(win) {
        arrivedNowPlaying(win)
        var b = findChild(win.contentItem, "nowPlayingFullscreen")
        verify(b, "the fullscreen button was not found in the application window")
        return b
    }

    function test_the_chevron_closes_a_fullscreen_opened_from_now_playing() {
        var win = showApp()
        win.navigate("album", { albumId: 4242 })
        win.navigate("nowplaying")
        compare(win.currentPage, "nowplaying", "the fixture never reached Now Playing")

        centerClick(fullscreenButtonIn(win))
        tryVerify(function () { return win.fullScreen }, 2000,
                  "the fullscreen button did not take the window fullscreen")
        compare(win.currentPage, "nowplaying",
                "the fullscreen button navigated somewhere of its own")

        centerClick(chevronIn(win))
        compare(win.currentPage, "album",
                "the chevron did not close Now Playing")
        tryVerify(function () { return !win.fullScreen }, 2000,
                  "the chevron closed Now Playing but left the window fullscreen, so the "
                  + "user is on the album page with no chrome and no sidebar")
        tryVerify(function () { return win.visibility !== Window.FullScreen }, 2000,
                  "the window itself stayed fullscreen after the chevron")
    }

    function test_the_chevron_closes_a_fullscreen_f11_opened() {
        var win = showApp()
        win.navigate("album", { albumId: 4242 })
        compare(win.currentPage, "album", "the fixture never reached the album page")

        win.toggleFullScreen()
        compare(win.currentPage, "nowplaying",
                "F11 should open Now Playing on the way into fullscreen")
        tryVerify(function () { return win.visibility === Window.FullScreen }, 2000,
                  "F11 did not take the window fullscreen")

        centerClick(chevronIn(win))
        compare(win.currentPage, "album",
                "the chevron did not close Now Playing")
        tryVerify(function () { return !win.fullScreen }, 2000,
                  "the chevron closed Now Playing but left the window fullscreen, so the "
                  + "user is on the album page with no chrome and no sidebar")
        tryVerify(function () { return win.visibility !== Window.FullScreen }, 2000,
                  "the window itself stayed fullscreen after the chevron")

        // That album, with the parameters it was opened with.
        tryVerify(function () {
            var item = findByType(win.contentItem, "AlbumPage")
            return item && item.albumId === 4242
        }, 2000, "the user came back to an album page, but not the one they left")
    }

    // The queue panel is an overlay on top of everything, so it is still the
    // innermost thing Escape closes.
    function test_escape_closes_the_queue_before_leaving_fullscreen() {
        var win = showApp()
        win.navigate("nowplaying")
        win.toggleFullScreen()
        tryVerify(function() { return win.fullScreen }, 2000)
        win.queueOpen = true

        keyClick(Qt.Key_Escape)
        tryVerify(function() { return !win.queueOpen }, 2000,
                  "Escape did not close the queue panel")
        verify(win.fullScreen, "Escape left fullscreen while the queue was still up")
    }
}
