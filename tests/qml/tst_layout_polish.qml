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
