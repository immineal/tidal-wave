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
