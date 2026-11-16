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

    function test_the_arrows_page_by_whole_cards() {
        var host = showHost(sectionHost, 900, 500)
        var sec = host.section
        sec.items = albums(14)
        settle(host)
        var list = findByName(sec, "sectionList")
        var back = findByName(sec, "sectionScrollBack")
        var fwd = findByName(sec, "sectionScrollForward")
        verify(back && fwd, "the row has no arrows")
        verify(!back.enabled && fwd.enabled, "at the start only forward should work")
        var step = sec.visibleCards * (sec.cardSize + sec.listSpacing)
        var rest = list.contentX
        mouseClick(fwd)
        tryVerify(function () { return Math.abs(list.contentX - rest - step) < 0.5 }, 2000,
                  "forward moved the row by " + (list.contentX - rest) + ", not " + step)
        verify(back.enabled, "back stayed off after a page forward")
        mouseClick(back)
        tryVerify(function () { return Math.abs(list.contentX - rest) < 0.5 }, 2000,
                  "back did not return to the start")
        // Without overflow there is nothing to page.
        sec.items = albums(2)
        settle(host)
        verify(!back.visible && !fwd.visible, "the arrows show on a row that fits")
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
