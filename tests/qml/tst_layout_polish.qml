// Layout polish: things that moved, overlapped or read badly in the running
// app, each pinned by the geometry a user would notice.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "LayoutPolish"
    when: windowShown

    function init() {
        app.setReducedMotionForTest(true)
        prefs.theme = "sea"
    }

    function cleanupTestCase() {
        prefs.theme = "sea"
        player.setAudioQualityForTest("HI_RES_LOSSLESS")
        player.setAudioFormatForTest("")
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function findByName(root, name) {
        if (!root) return null
        if (root.objectName === name) return root
        var kids = root.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function collectByName(root, name, out) {
        if (!root) return out
        if (root.objectName === name) out.push(root)
        var kids = root.children
        for (var i = 0; i < kids.length; ++i) collectByName(kids[i], name, out)
        return out
    }

    function frame(host) {
        host.update()
        verify(waitForRendering(host.contentItem), "the window drew no frame")
    }

    function settle(host) {
        wait(1)
        frame(host)
        wait(1)
    }

    function showHost(component, w, h) {
        var host = createTemporaryObject(component, testCase, { width: w, height: h })
        verify(host, "host window was not created")
        host.visible = true
        frame(host)
        return host
    }

    function track(title, i) {
        var n = i === undefined ? 0 : i
        return { id: 4711 + n, title: title, artists: "Ein Interpret",
                 artistList: [{ id: 3, name: "Ein Interpret" }], artistId: 3,
                 albumTitle: "Ein Album", albumId: 5, coverUrl: "", coverUrl80: "",
                 duration: 215, durationStr: "3:35", trackNumber: n + 1 }
    }

    function tracks(n) {
        var out = []
        for (var i = 0; i < n; ++i) out.push(track("Titel " + i, i))
        return out
    }

    function albums(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 900 + i, title: "Album " + i, artists: "Ein Interpret",
                       coverUrl: "", subtitle: "Ein Interpret" })
        return out
    }

    Component { id: plainHost; Window { property alias pane: pane; Item { id: pane; anchors.fill: parent } } }

    Component {
        id: playerBarHost
        Window {
            id: pbWin
            property alias bar: pb
            PlayerBar { id: pb; width: pbWin.width; anchors.bottom: parent.bottom }
        }
    }

    Component {
        id: npHost
        Window {
            id: npWin
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(m, e) {}
            function cancelSleepTimer() {}
            function formatSleepTime(s) { return "" + s }
            function navigate(page, params) {}
            function goBack() {}
            property bool fullScreen: false
            function toggleFullScreen() { fullScreen = !fullScreen }
            property alias page: np
            NowPlayingPage { id: np; anchors.fill: parent }
        }
    }

    function seedNowPlaying(title) {
        var q = tracks(6)
        q[0].title = title
        player.setQueueForTest(q, 0)
        player.setManualForTest([])
        player.setCurrentTrackForTest(q[0])
        player.setDurationForTest(215000)
        bridge.setLyricsForTest("Erste Zeile\nZweite Zeile\nDritte Zeile", false)
    }

    // ── 1. the player bar holds still when the first track starts ────────

    function barShape(bar) {
        function x(name) {
            var it = findByName(bar, name)
            verify(it, name + " was not found")
            return it.mapToItem(bar, 0, 0).x
        }
        var seek = findByName(bar, "playerBarSeekBar")
        verify(seek, "playerBarSeekBar was not found")
        var title = findByName(bar, "playerBarTitle")
        verify(title, "playerBarTitle was not found")
        return {
            play:    x("playerBarPlayButton"),
            shuffle: x("playerBarShuffle"),
            repeat:  x("playerBarRepeat"),
            seekX:   seek.mapToItem(bar, 0, 0).x,
            seekW:   seek.width,
            titleX:  title.mapToItem(bar, 0, 0).x,
            titleY:  title.mapToItem(bar, 0, 0).y,
            volume:  bar.volumeStack.mapToItem(bar, 0, 0).x,
            output:  x("playerBarOutputButton"),
            queue:   x("playerBarQueueButton"),
            leftW:   bar.trackInfoGroup.width
        }
    }

    function test_the_bar_does_not_move_when_a_track_starts_data() {
        return [ { tag: "640", w: 640 }, { tag: "960", w: 960 }, { tag: "1280", w: 1280 } ]
    }

    function test_the_bar_does_not_move_when_a_track_starts(row) {
        player.setCurrentTrackForTest({})
        player.setAudioQualityForTest("")
        player.setAudioFormatForTest("")
        player.setDurationForTest(0)
        player.setPositionForTest(0)
        var host = showHost(playerBarHost, row.w, 200)
        var bar = host.bar
        verify(!bar.hasTrack, "the bar started with a track")
        var idle = barShape(bar)

        player.setCurrentTrackForTest(track("A Song Whose Title Takes Its Time (Remastered Edition)"))
        player.setAudioQualityForTest("HI_RES_LOSSLESS")
        player.setAudioFormatForTest("24-bit / 96 kHz FLAC")
        player.setDurationForTest(215000)
        player.setPositionForTest(42000)
        frame(host)
        var playing = barShape(bar)

        for (var k in idle)
            verify(Math.abs(idle[k] - playing[k]) <= 0.5,
                   row.tag + ": " + k + " moved from " + idle[k].toFixed(1) + " to "
                   + playing[k].toFixed(1) + " when the track started")
    }

    // The heart follows the title, short or long, and never leaves the group.
    function test_the_heart_sits_beside_the_title_data() {
        return [ { tag: "short title, 1280", w: 1280, title: "Kurz" },
                 { tag: "long title, 1280",  w: 1280, title: "A Song Whose Title Takes Its Time (Remastered Edition)" },
                 { tag: "long title, 640",   w: 640,  title: "A Song Whose Title Takes Its Time (Remastered Edition)" } ]
    }

    function test_the_heart_sits_beside_the_title(row) {
        player.setCurrentTrackForTest(track(row.title))
        var host = showHost(playerBarHost, row.w, 200)
        var bar = host.bar
        var title = findByName(bar, "playerBarTitle")
        var heart = findByName(bar, "playerLikeButton")
        verify(title && heart && heart.visible, "the title or the heart is missing")
        var inkEnd = title.mapToItem(bar, Math.min(title.width, title.contentWidth), 0).x
        var heartInk = findByName(heart, "iconButtonGlyph").mapToItem(bar, 0, 0).x
        verify(heartInk - inkEnd >= 0 && heartInk - inkEnd <= Theme.space4,
               row.tag + ": the heart's glyph starts " + (heartInk - inkEnd).toFixed(1)
               + "px after the end of the title")
        var group = bar.trackInfoGroup
        var heartEnd = heart.mapToItem(group, heart.width, 0).x
        verify(heartEnd <= group.width + 0.5,
               row.tag + ": the heart ends at " + heartEnd.toFixed(1)
               + " in a " + group.width.toFixed(1) + "px group")
    }

    // ── 2. shuffle and repeat answer a click under the pointer ───────────

    function test_an_active_toggle_keeps_its_accent_under_the_pointer_data() {
        return [ { tag: "shuffle", name: "playerBarShuffle" },
                 { tag: "repeat",  name: "playerBarRepeat" } ]
    }

    function test_an_active_toggle_keeps_its_accent_under_the_pointer(row) {
        player.setCurrentTrackForTest(track("Titel"))
        player.setShuffle(true)
        player.setRepeatMode(1)
        var host = showHost(playerBarHost, 960, 200)
        var btn = findByName(host.bar, row.name)
        verify(btn && btn.active, row.tag + " is not on")
        mouseMove(btn, btn.width / 2, btn.height / 2)
        tryVerify(function () { return btn.hovered }, 1000, "the pointer never reached " + row.tag)
        settle(host)
        var glyph = findByName(btn, "iconButtonGlyph")
        var disc = findByName(btn, "iconButtonDisc")
        verify(Qt.colorEqual(glyph.color, Theme.accentText),
               row.tag + ": the glyph left the accent under the pointer: " + glyph.color)
        verify(Qt.colorEqual(disc.color, Theme.hoverFill),
               row.tag + ": the hover did not tint the disc: " + disc.color)
        player.setShuffle(false)
        player.setRepeatMode(0)
    }

    Component {
        id: glyphPair
        Window {
            color: "white"
            property alias plain: a
            property alias one: b
            Rectangle {
                id: pad; anchors.fill: parent; color: "white"
                VectorIcon { id: a; x: 4;  y: 4; width: 18; height: 18; name: "repeat";     color: "black" }
                VectorIcon { id: b; x: 34; y: 4; width: 18; height: 18; name: "repeat-one"; color: "black" }
            }
        }
    }

    // At the bar's 18px the mark that says "one" has to be more than a speck.
    function test_the_repeat_one_mark_reads_at_the_bar_size() {
        var host = showHost(glyphPair, 60, 30)
        settle(host)
        var a = grabImage(host.plain)
        var b = grabImage(host.one)
        var differ = 0
        for (var y = 0; y < 18; ++y)
            for (var x = 0; x < 18; ++x)
                if (Math.abs(a.pixel(x, y).r - b.pixel(x, y).r) > 0.5) differ++
        verify(differ >= 20,
               "repeat-one differs from repeat in only " + differ + " pixels at 18px")
    }

    // ── 3. card rows: arrows, drag, the wheel, cards that hold still ─────

    Component {
        id: sectionHost
        Window {
            id: sWin
            property alias section: sec
            property alias page: flick
            Flickable {
                id: flick
                anchors.fill: parent
                contentHeight: 2000
                flickableDirection: Flickable.VerticalFlick
                HorizontalSection {
                    id: sec
                    width: sWin.width
                    y: 40
                    title: "Neu"
                    mediaType: "album"
                }
            }
        }
    }

    // "Show all" ends on the row's right inset, where the cards are clipped
    // to, at every width. The cards keep their one size.
    function test_show_all_ends_on_the_row_edge_data() {
        var rows = []
        for (var w = 560; w <= 1700; w += 37) rows.push({ tag: "" + w, w: w })
        return rows
    }

    function test_show_all_ends_on_the_row_edge(row) {
        var host = showHost(sectionHost, row.w, 500)
        var sec = host.section
        sec.items = albums(14)
        settle(host)
        compare(sec.cardSize, 160, row.tag + ": the cards changed size")
        var label = findByName(sec, "viewAllChevron")
        verify(label, "the Show all chevron was not found")
        var labelEnd = label.mapToItem(sec, label.width, 0).x
        verify(Math.abs(labelEnd - (sec.width - sec.edgeInset)) <= 1,
               row.tag + ": Show all ends at " + labelEnd.toFixed(1)
               + " and the row at " + (sec.width - sec.edgeInset))
    }

    // Resizing the window moves no card: at the row's start each card keeps
    // its x and its width, and the last one is simply cut off.
    function test_cards_hold_still_while_the_window_resizes() {
        var host = showHost(sectionHost, 1400, 500)
        var sec = host.section
        sec.items = albums(14)
        settle(host)
        var list = findByName(sec, "sectionList")
        function cards() {
            var out = []
            for (var i = 0; i < 3; ++i) {
                var c = list.itemAtIndex(i)
                verify(c, "card " + i + " was not built")
                out.push({ x: c.mapToItem(sec, 0, 0).x, w: c.width })
            }
            return out
        }
        var first = cards()
        for (var w = 1400; w >= 600; w -= 53) {
            host.width = w
            settle(host)
            var now = cards()
            for (var i = 0; i < 3; ++i) {
                compare(now[i].x, first[i].x, "at " + w + "px card " + i + " moved")
                compare(now[i].w, first[i].w, "at " + w + "px card " + i + " resized")
            }
        }
    }

    // One half-transparent arrow over each overflowing edge, centred on the
    // covers. A click moves the row by exactly one card and its gap.
    function test_an_arrow_moves_the_row_by_one_card() {
        var host = showHost(sectionHost, 900, 500)
        var sec = host.section
        sec.items = albums(14)
        settle(host)
        var list = findByName(sec, "sectionList")
        var back = findByName(sec, "sectionScrollBack")
        var fwd = findByName(sec, "sectionScrollForward")
        verify(back && fwd, "the row has no arrows")
        verify(!back.visible && fwd.visible, "at the start only the right arrow should show")
        verify(fwd.backed, "the arrow has no see-through disc behind it")

        // Over the row's right edge, on the middle of the covers.
        var art = findByName(list.itemAtIndex(0), "cardArt")
        var artMid = art.mapToItem(sec, 0, art.height / 2).y
        var f = fwd.mapToItem(sec, 0, 0)
        verify(Math.abs(f.y + fwd.height / 2 - artMid) <= 1,
               "the arrow's centre is at " + (f.y + fwd.height / 2) + ", the covers' at " + artMid)
        verify(f.x + fwd.width <= sec.width + 0.5 && f.x + fwd.width >= sec.width - sec.edgeInset - 0.5,
               "the right arrow ends at " + (f.x + fwd.width) + " in a " + sec.width + "px row")
        verify(f.y >= list.mapToItem(sec, 0, 0).y, "the arrow sits above the row")

        var step = sec.cardSize + sec.listSpacing
        var rest = list.contentX
        mouseClick(fwd)
        tryVerify(function () { return Math.abs(list.contentX - rest - step) < 0.5 }, 2000,
                  "the right arrow moved the row by " + (list.contentX - rest) + ", not " + step)
        verify(back.visible, "the left arrow did not appear once scrolled")
        var b = back.mapToItem(sec, 0, 0)
        verify(b.x >= -0.5 && b.x <= sec.edgeInset + 0.5,
               "the left arrow starts at " + b.x)
        mouseClick(back)
        tryVerify(function () { return Math.abs(list.contentX - rest) < 0.5 }, 2000,
                  "the left arrow did not move the row back by one card")

        // By keyboard, with a tool tip naming it.
        verify(fwd.activeFocusOnTab, "the right arrow cannot be reached with Tab")
        compare(fwd.label, "Scroll forward")
        fwd.forceActiveFocus()
        keyClick(Qt.Key_Space)
        tryVerify(function () { return Math.abs(list.contentX - rest - step) < 0.5 }, 2000,
                  "Space on the right arrow moved the row by " + (list.contentX - rest))

        // At the end the right arrow goes.
        sec.scrollTo(sec.maxX)
        settle(host)
        verify(!fwd.visible && back.visible, "at the end only the left arrow should show")
        // A row that fits has neither.
        sec.items = albums(2)
        settle(host)
        verify(!back.visible && !fwd.visible, "the arrows show on a row that fits")
    }

    // Reduced motion: an arrow moves the row at once.
    function test_an_arrow_jumps_under_reduced_motion() {
        var host = showHost(sectionHost, 900, 500)
        var sec = host.section
        sec.items = albums(14)
        settle(host)
        var list = findByName(sec, "sectionList")
        var fwd = findByName(sec, "sectionScrollForward")
        var rest = list.contentX
        app.setReducedMotionForTest(true)
        mouseClick(fwd)
        var moved = list.contentX - rest
        app.setReducedMotionForTest(false)
        compare(moved, sec.cardSize + sec.listSpacing, "the row did not jump by one card")
    }

    function test_a_row_drags_sideways() {
        var host = showHost(sectionHost, 900, 500)
        var sec = host.section
        sec.items = albums(14)
        settle(host)
        var list = findByName(sec, "sectionList")
        var rest = list.contentX
        var y = list.height / 3
        mousePress(list, 600, y)
        for (var x = 580; x >= 200; x -= 20) mouseMove(list, x, y)
        mouseRelease(list, 200, y)
        tryVerify(function () { return !list.moving }, 3000)
        verify(list.contentX - rest > 100, "a drag moved the row only by " + (list.contentX - rest))
    }

    function test_the_wheel_data() {
        return [ { tag: "horizontal wheel moves the row", dx: -120, dy: 0, mods: Qt.NoModifier, row: true },
                 { tag: "shift and wheel moves the row",  dx: 0, dy: -120, mods: Qt.ShiftModifier, row: true },
                 { tag: "plain wheel moves the page",     dx: 0, dy: -120, mods: Qt.NoModifier, row: false } ]
    }

    function test_the_wheel(row) {
        var host = showHost(sectionHost, 900, 500)
        var sec = host.section
        sec.items = albums(14)
        settle(host)
        var list = findByName(sec, "sectionList")
        var rest = list.contentX
        mouseWheel(list, 300, list.height / 3, row.dx, row.dy, Qt.NoButton, row.mods)
        settle(host)
        if (row.row) {
            verify(list.contentX > rest, row.tag + ": the row stayed at " + list.contentX)
            compare(host.page.contentY, 0, row.tag + ": the page moved as well")
        } else {
            compare(list.contentX, rest, row.tag + ": the row moved")
            verify(host.page.contentY > 0, row.tag + ": the page did not scroll")
        }
    }

    // ── 4. Now Playing ───────────────────────────────────────────────────

    // What a reader keeps their place by: the text column and Up Next. The
    // slot itself grows into the panel, which is the point.
    function blocks(page) {
        var info = findByName(page, "nowPlayingInfoColumn")
        var upNext = findByName(page, "nowPlayingUpNextColumn")
        return {
            infoX: info.mapToItem(page, 0, 0).x, infoY: info.mapToItem(page, 0, 0).y,
            upNextX: upNext.mapToItem(page, 0, 0).x, upNextY: upNext.mapToItem(page, 0, 0).y
        }
    }

    function test_lyrics_open_in_place_data() {
        return [ { tag: "side by side", w: 1280, h: 900 },
                 { tag: "stacked",      w: 820,  h: 1100 } ]
    }

    function test_lyrics_open_in_place(row) {
        seedNowPlaying("Ein Titel")
        var host = showHost(npHost, row.w, row.h)
        var page = host.page
        settle(host)
        var before = blocks(page)
        page.showLyrics = true
        tryVerify(function () { return page.lyricsness === 1 }, 2000)
        settle(host)
        var after = blocks(page)
        for (var k in before)
            verify(Math.abs(before[k] - after[k]) <= 0.5,
                   row.tag + ": " + k + " moved from " + before[k].toFixed(1)
                   + " to " + after[k].toFixed(1) + " when the lyrics opened")
        var panel = findByName(page, "nowPlayingLyricsPanel")
        verify(panel.visible && panel.width >= 280 && panel.height >= 280,
               row.tag + ": the lyrics panel is " + panel.width + "x" + panel.height)
        // And it stays clear of the text column.
        var info = findByName(page, "nowPlayingInfoColumn")
        var pr = panel.mapToItem(page, 0, 0)
        var ir = info.mapToItem(page, 0, 0)
        var apart = pr.x + panel.width <= ir.x + 0.5 || pr.y + panel.height <= ir.y + 0.5
        verify(apart, row.tag + ": the lyrics panel overlaps the text column")
        page.showLyrics = false
    }

    function test_fullscreen_art_uses_the_room() {
        seedNowPlaying("Ein Titel")
        var host = showHost(npHost, 1920, 1080)
        host.fullScreen = true
        settle(host)
        var art = findByName(host.page, "nowPlayingArt")
        verify(art.width >= 640, "fullscreen at 1920x1080 draws the art at " + art.width + "px")
        var scroll = findByName(host.page, "nowPlayingScroll")
        verify(!scroll.interactive, "the bigger art made the fullscreen page scroll")
    }

    function test_a_long_title_takes_two_lines_before_it_elides() {
        seedNowPlaying("A Song Whose Title Takes Its Time Over Two Lines")
        var host = showHost(npHost, 1280, 900)
        settle(host)
        var title = findByName(host.page, "nowPlayingTitle")
        verify(title.implicitWidth > title.width, "the title fits on one line, nothing to test")
        compare(title.lineCount, 2, "the title is on " + title.lineCount + " line(s)")
        verify(!title.truncated, "the title elided although two lines hold it")
    }

    // ── 5. the album's sticky header is opaque ───────────────────────────

    Component {
        id: barHost
        Window {
            id: bw
            property alias bar: db
            property alias flick: f
            Flickable { id: f; anchors.fill: parent; contentHeight: 3000 }
            DetailBar { id: db; flickable: f; heroHeight: 280; title: "Ein Album" }
        }
    }

    function test_the_sticky_header_is_opaque_once_revealed() {
        var host = showHost(barHost, 800, 600)
        host.flick.contentY = 1200
        settle(host)
        compare(host.bar.reveal, 1, "the bar never revealed")
        compare(host.bar.color.a, 1, "the revealed bar lets the page show through")
    }

    // ── 6. every modal dims the app behind it ────────────────────────────

    function scrimsIn(host) {
        var out = []
        function walk(it) {
            if (!it) return
            if (it.visible && it.color !== undefined && it.width >= host.width - 1
                    && it.height >= host.height - 1 && Qt.colorEqual(it.color, Theme.scrim))
                out.push(it)
            for (var i = 0; i < it.children.length; ++i) walk(it.children[i])
        }
        walk(host.contentItem)
        return out
    }

    Component {
        id: settingsHost
        Window {
            property alias sidebar: sb
            SideBar { id: sb; hostWidth: parent.width; width: 220; height: parent.height }
        }
    }

    function test_settings_dims_the_app() {
        var host = showHost(settingsHost, 1100, 800)
        host.sidebar.openSettings()
        settle(host)
        verify(host.sidebar.settingsPanel.visible, "settings did not open")
        verify(scrimsIn(host).length > 0, "Settings opened without a scrim")
        host.sidebar.settingsPanel.close()
    }

    Component { id: newPlaylistC; NewPlaylistDialog { } }

    function test_new_playlist_dims_the_app() {
        var host = showHost(plainHost, 1100, 800)
        var dlg = createTemporaryObject(newPlaylistC, host.pane)
        dlg.openEmpty()
        settle(host)
        verify(dlg.visible, "the dialog did not open")
        verify(scrimsIn(host).length > 0, "New playlist opened without a scrim")
        dlg.close()
    }

    Component { id: playlistPageC; PlaylistPage { anchors.fill: parent } }

    function test_edit_playlist_dims_the_app() {
        var host = showHost(plainHost, 1100, 800)
        var page = createTemporaryObject(playlistPageC, host.pane)
        page.playlistUuid = "uuid-0"
        page.playlistTitle = "Eine Liste"
        page.playlistEditable = true
        settle(host)
        page.editPopup.open()
        settle(host)
        verify(page.editPopup.visible, "the edit dialog did not open")
        verify(scrimsIn(host).length > 0, "Edit playlist opened without a scrim")
        page.editPopup.close()
    }

    Component { id: trackRowC; TrackRow { width: 700; title: "Titel"; artists: "Ein Interpret" } }

    function test_add_to_playlist_dims_the_app() {
        bridge.setUserPlaylistsForTest([{ uuid: "u1", title: "Liste", numberOfTracks: 3, coverUrl: "" }])
        var host = showHost(plainHost, 1100, 800)
        var row = createTemporaryObject(trackRowC, host.pane, { trackData: track("Titel") })
        settle(host)
        row.openPicker()
        settle(host)
        verify(row.playlistPicker && row.playlistPicker.visible, "the picker did not open")
        verify(scrimsIn(host).length > 0, "Add to playlist opened without a scrim")
        row.playlistPicker.close()
    }

    Component { id: confirmC; ConfirmDialog { heading: "Sicher?"; confirmLabel: "Ja" } }

    function test_a_confirmation_dims_the_app() {
        var host = showHost(plainHost, 1100, 800)
        var dlg = createTemporaryObject(confirmC, host.pane)
        dlg.ask()
        settle(host)
        verify(scrimsIn(host).length > 0, "a confirmation opened without a scrim")
        dlg.close()
    }

    // ── 7. Collection ────────────────────────────────────────────────────

    Component { id: collectionC; CollectionPage { anchors.fill: parent } }

    function test_collection_grids_line_up_with_the_title_data() {
        var rows = []
        var w = [640, 740, 900, 1060, 1280]
        var tabs = [ { t: 1, grid: "collectionAlbumsGrid" },
                     { t: 3, grid: "collectionPlaylistsGrid" } ]
        for (var i = 0; i < w.length; ++i)
            for (var k = 0; k < tabs.length; ++k)
                rows.push({ tag: tabs[k].grid + " " + w[i], w: w[i], tab: tabs[k].t, grid: tabs[k].grid })
        return rows
    }

    function test_collection_grids_line_up_with_the_title(row) {
        var host = showHost(plainHost, row.w, 700)
        var page = createTemporaryObject(collectionC, host.pane)
        page.activeTab = row.tab
        page.filteredAlbums = albums(9)
        page.filteredPlaylists = albums(9)
        settle(host)
        var title = findByName(page, "collectionTitle")
        var search = findByName(page, "collectionSearch")
        var grid = findByName(page, row.grid)
        var first = findByName(grid.itemAtIndex(0), "cardArt")
        verify(title && search && first, "a part of the page was not found")
        var left = title.mapToItem(page, 0, 0).x
        compare(search.mapToItem(page, 0, 0).x, left, "the search field is off the title")
        var art = first.mapToItem(page, 0, 0).x
        verify(Math.abs(art - left) <= 0.5,
               row.tag + ": the first card starts at " + art.toFixed(1) + ", the title at " + left)
    }

    function test_the_active_tab_does_not_push_its_neighbours() {
        var host = showHost(plainHost, 1060, 700)
        var page = createTemporaryObject(collectionC, host.pane)
        page.activeTab = 0
        settle(host)
        var labels = collectByName(page, "collectionTabLabel", [])
        verify(labels.length === 5, "the five tab labels were not found")
        // The chips, not the labels: a label is centred in its chip, and the
        // bold one is wider than the regular one.
        var xs = labels.map(function (l) { return l.parent.mapToItem(page, 0, 0).x })
        page.activeTab = 2
        settle(host)
        // The chosen tab is bold, and the bold costs its neighbours nothing.
        verify(labels[2].font.bold && !labels[1].font.bold, "the chosen tab is not the bold one")
        for (var i = 0; i < labels.length; ++i)
            verify(Math.abs(labels[i].parent.mapToItem(page, 0, 0).x - xs[i]) <= 0.5,
                   "tab " + i + " moved when tab 2 was chosen")
    }

    function test_the_chosen_sort_chip_is_bold_and_moves_nothing() {
        var host = showHost(plainHost, 1060, 700)
        var page = createTemporaryObject(collectionC, host.pane)
        page.activeTab = 1
        page.sortMode = 0
        settle(host)
        var chips = [findByName(page, "collectionSortDefault")]
            .concat(collectByName(page, "collectionSortPill", []))
        // Five on the albums tab: Default, A to Z, Z to A, Artist and Year.
        verify(chips.length === 5 && chips[0], "the five sort chips were not found")
        var xs = chips.map(function (c) { return c.mapToItem(page, 0, 0).x })
        page.sortMode = 1
        settle(host)
        function label(c) {
            for (var k = 0; k < c.children.length; ++k)
                if (c.children[k].text !== undefined && c.children[k].visible) return c.children[k]
            return null
        }
        verify(label(chips[1]).font.bold && !label(chips[0]).font.bold,
               "the chosen sort chip is not the bold one")
        for (var i = 0; i < chips.length; ++i)
            verify(Math.abs(chips[i].mapToItem(page, 0, 0).x - xs[i]) <= 0.5,
                   "sort chip " + i + " moved when A to Z was chosen")
    }

    Component {
        id: oneRowC
        TrackRow { title: "Kurz"; artists: "Ein Interpret"; albumTitle: "The Beatles (Remastered 2009 Edition)" }
    }

    function test_the_album_column_takes_its_share_of_a_wide_row() {
        var host = showHost(plainHost, 1100, 200)
        var r = createTemporaryObject(oneRowC, host.pane, { width: 1000, trackData: track("Kurz") })
        settle(host)
        var album = findByName(r, "trackAlbumColumn")
        verify(album.visible, "the album column is hidden at 1000")
        verify(!album.truncated, "a short album title elides at " + album.width
               + "px in a 1000px row")
    }

    function test_a_four_digit_track_number_fits() {
        var host = showHost(plainHost, 1100, 200)
        var r = createTemporaryObject(oneRowC, host.pane, { width: 900, trackNum: 4388 })
        settle(host)
        var num = findByName(r, "trackRowNumber")
        verify(num.implicitWidth <= num.parent.width + 0.5,
               "the number needs " + num.implicitWidth.toFixed(1) + " in a "
               + num.parent.width + "px slot")
    }

    function test_a_long_list_keeps_a_grabbable_scroll_handle() {
        var host = showHost(plainHost, 900, 700)
        var page = createTemporaryObject(collectionC, host.pane)
        page.activeTab = 0
        page.filteredTracks = tracks(5000)
        settle(host)
        var bar = findByName(page, "collectionTracksScrollBar")
        verify(bar, "the tracks list has no named scroll bar")
        bar.active = true
        settle(host)
        verify(bar.contentItem.height >= Theme.scrollHandleMin - 0.5,
               "the handle is " + bar.contentItem.height.toFixed(1) + "px for 5000 rows")
    }

    // ── 8. the queue's drag handle ───────────────────────────────────────

    Component {
        id: queueHost
        Window {
            property alias panel: qp
            QueuePanel { id: qp; anchors.fill: parent }
        }
    }

    function seedQueue() {
        player.setQueueForTest(tracks(3), 0)
        player.setCurrentTrackForTest(track("Titel 0", 0))
        var manual = []
        for (var i = 0; i < 30; ++i) manual.push(track("Eigene " + i, 100 + i))
        player.setManualForTest(manual)
    }

    function manualRows(panel) {
        return collectByName(panel, "queueEntry", []).filter(function (e) {
            return e.isManual && e.visible
        })
    }

    function test_the_drag_handle_is_large_and_clear() {
        seedQueue()
        var host = showHost(queueHost, 900, 800)
        settle(host)
        var entry = manualRows(host.panel)[0]
        var grip = findByName(entry, "queueDragGrip")
        var area = findByName(entry, "queueDragArea")
        verify(grip && area, "the grip or its drag area was not found")
        verify(grip.width >= 20, "the grip is " + grip.width + "px")
        verify(area.width >= 28 && area.height >= 28,
               "the drag target is " + area.width + "x" + area.height)
        compare(grip.opacity, 1, "the grip is faded at rest")
        verify(Qt.colorEqual(grip.color, Theme.textSec), "the grip is drawn in " + grip.color)
        player.setManualForTest([])
    }

    function test_dragging_a_row_body_does_not_scroll_the_queue() {
        seedQueue()
        var host = showHost(queueHost, 900, 600)
        settle(host)
        var list = findByName(host.panel, "queuePanelList")
        list.contentY = 200
        settle(host)
        var y0 = list.contentY
        // A row well inside the viewport, so the whole drag lands on the list.
        var entry = manualRows(host.panel).filter(function (e) {
            var top = e.mapToItem(list, 0, 0).y
            return top > list.height / 2 && top < list.height - 2 * e.height
        })[0]
        verify(entry, "no manual row sits in the lower half of the list")
        var x = entry.width * 0.6, y = entry.height / 2
        mousePress(entry, x, y)
        for (var d = 10; d <= 150; d += 10) mouseMove(entry, x, y - d)
        mouseRelease(entry, x, y - 150)
        settle(host)
        compare(list.contentY, y0, "dragging a row's body scrolled the queue")
        player.setManualForTest([])
    }

    // The jump pill moves between the two edges and keeps its size: once
    // it stretched over the rows and took the clicks meant for them.
    function test_the_jump_pill_keeps_its_size_on_either_edge() {
        seedQueue()
        var host = showHost(queueHost, 900, 600)
        settle(host)
        var list = findByName(host.panel, "queuePanelList")
        var pill = findByName(host.panel, "queueJumpToCurrent")
        var h = pill.height
        list.contentY = list.contentHeight - list.height
        settle(host)
        list.contentY = 200
        settle(host)
        verify(pill.visible, "the pill is not shown with the current track scrolled away")
        compare(pill.height, h, "the pill is " + pill.height + "px tall after moving edges")
        player.setManualForTest([])
    }

    // ── 9. Settings ──────────────────────────────────────────────────────

    function settingsFlick(panel) {
        return findByName(panel.contentItem, "settingsScroll").contentItem
    }

    function test_settings_opens_at_the_top() {
        var host = showHost(settingsHost, 1100, 800)
        var panel = host.sidebar.settingsPanel
        host.sidebar.openSettings()
        settle(host)
        settingsFlick(panel).contentY = 600
        settle(host)
        panel.close()
        settle(host)
        host.sidebar.openSettings()
        settle(host)
        compare(settingsFlick(panel).contentY, 0, "Settings reopened where it was left")
        panel.close()
    }

    function test_a_wheel_notch_scrolls_settings_by_the_system_lines() {
        var host = showHost(settingsHost, 1100, 800)
        var panel = host.sidebar.settingsPanel
        host.sidebar.openSettings()
        settle(host)
        var sv = findByName(panel.contentItem, "settingsScroll")
        var flick = sv.contentItem
        mouseWheel(sv, sv.width / 2, sv.height / 2, 0, -120)
        wait(400)
        settle(host)
        // The system's lines per notch, each one Theme.wheelLine tall, as
        // other desktop apps scroll.
        var step = Qt.styleHints.wheelScrollLines * Theme.wheelLine
        verify(step > 0, "no wheel step to compare with")
        verify(Math.abs(flick.contentY - step) <= 1,
               "one notch moved Settings by " + flick.contentY.toFixed(1) + "px, where "
               + Qt.styleHints.wheelScrollLines + " lines are " + step + "px")
        panel.close()
    }

    function test_the_shortcut_list_is_in_columns() {
        var host = showHost(settingsHost, 1100, 900)
        var panel = host.sidebar.settingsPanel
        host.sidebar.openSettings()
        settle(host)
        var keys = collectByName(panel.contentItem, "settingsShortcutKey", [])
        var texts = collectByName(panel.contentItem, "settingsShortcutText", [])
        verify(keys.length > 5 && keys.length === texts.length, "the shortcut table was not found")
        var kx = keys[0].mapToItem(panel.contentItem, 0, 0).x
        var tx = texts[0].mapToItem(panel.contentItem, 0, 0).x
        for (var i = 1; i < keys.length; ++i) {
            compare(keys[i].mapToItem(panel.contentItem, 0, 0).x, kx, "key " + i + " is off the column")
            compare(texts[i].mapToItem(panel.contentItem, 0, 0).x, tx, "description " + i + " is off the column")
            verify(texts[i].mapToItem(panel.contentItem, 0, 0).x >= keys[i].mapToItem(panel.contentItem, keys[i].width, 0).x,
                   "description " + i + " overlaps its key")
        }
        panel.close()
    }

    function test_a_light_theme_keeps_the_pure_black_row() {
        var host = showHost(settingsHost, 1100, 900)
        var panel = host.sidebar.settingsPanel
        host.sidebar.openSettings()
        settle(host)
        var block = findByName(panel.contentItem, "settingsOledBlock")
        var kids = block.parent.children
        var next = null
        for (var i = 0; i < kids.length - 1; ++i) if (kids[i] === block) next = kids[i + 1]
        verify(next, "nothing follows the pure-black row")
        var y0 = next.mapToItem(panel.contentItem, 0, 0).y
        prefs.theme = "sky"
        settle(host)
        verify(block.visible, "a light theme hid the pure-black row")
        var toggle = findByName(panel.contentItem, "settingsOledToggle")
        verify(!toggle.enabled, "the switch can be used on a light theme")
        compare(next.mapToItem(panel.contentItem, 0, 0).y, y0, "the rows below moved")
        panel.close()
    }

    // ── 10. the album page ───────────────────────────────────────────────

    Component { id: albumC; AlbumPage { anchors.fill: parent } }

    // Every row names its artists, also where they are the album's.
    function test_every_album_track_names_its_artists() {
        var host = showHost(plainHost, 900, 1100)
        var page = createTemporaryObject(albumC, host.pane)
        page.albumId = 42
        page.albumData = { id: 42, title: "Ein Album", artists: "Ein Interpret",
                           artistId: 3, artistList: [{ id: 3, name: "Ein Interpret" }],
                           numTracks: 3, duration: 600, coverUrl: "" }
        var t = tracks(3)
        t[2].artists = "Ein Interpret, Ein Gast"
        t[2].artistList = [{ id: 3, name: "Ein Interpret" }, { id: 8, name: "Ein Gast" }]
        page.tracks = t
        settle(host)
        var lines = collectByName(page, "trackRowArtistLine", [])
        verify(lines.length === 3, "found " + lines.length + " artist lines")
        for (var i = 0; i < 3; ++i)
            verify(lines[i].visible, "track " + (i + 1) + " shows no artist line")
    }

    function test_saved_is_not_a_primary_action() {
        bridge.setAlbumFavoriteForTest(42, true)
        var host = showHost(plainHost, 900, 900)
        var page = createTemporaryObject(albumC, host.pane)
        page.albumId = 42
        page.albumData = { id: 42, title: "Ein Album", artists: "Ein Interpret", coverUrl: "" }
        page.tracks = tracks(2)
        settle(host)
        var pill = findByName(page, "albumSavePill")
        verify(page.isSaved, "the album is not saved")
        verify(!pill.accent, "Saved is drawn as a solid accent button")
        bridge.setAlbumFavoriteForTest(42, false)
    }

    // ── 11. search results ───────────────────────────────────────────────

    Component { id: searchC; SearchPage { anchors.fill: parent } }

    function test_search_rows_show_no_bare_percentage() {
        var t = tracks(4)
        for (var i = 0; i < t.length; ++i) t[i].popularity = 83
        bridge.setSearchResultsForTest(t, [], [], [])
        var host = showHost(plainHost, 1000, 800)
        var page = createTemporaryObject(searchC, host.pane)
        page.searchFor("titel")
        settle(host)
        wait(300)
        var rows = collectByName(page, "trackTitle", [])
        verify(rows.length > 0, "no track rows were shown")
        var bare = []
        function walk(it) {
            if (!it) return
            if (it.visible && typeof it.text === "string" && /^\s*\d+\s*%\s*$/.test(it.text))
                bare.push(it.text)
            for (var k = 0; k < it.children.length; ++k) walk(it.children[k])
        }
        walk(page)
        compare(bare.length, 0, "a bare percentage is shown: " + bare.join(", "))
    }

    // ── 12. one quality badge ────────────────────────────────────────────

    function test_both_places_use_one_badge_component() {
        player.setCurrentTrackForTest(track("Titel"))
        player.setAudioQualityForTest("LOSSLESS")
        var bar = showHost(playerBarHost, 960, 200)
        var np = showHost(npHost, 1280, 900)
        var a = findByName(bar.bar, "qualityBadge")
        var b = findByName(np.page, "qualityBadge")
        verify(a && b, "a badge is missing")
        verify(String(a).indexOf("QualityBadge") === 0, "the bar's badge is a " + a)
        verify(String(b).indexOf("QualityBadge") === 0, "Now Playing's badge is a " + b)
        compare(a.height, b.height, "the two badges are different heights")
        compare(findByName(a, "qualityBadgeText").font.pixelSize,
                findByName(b, "qualityBadgeText").font.pixelSize, "the two badges use different type")
    }
}
