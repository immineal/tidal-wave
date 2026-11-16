// What a screen reader is told about the shared controls. Each one is read
// through QAccessible (the `a11y` probe tst_qml installs): it has to be there
// at all, say what it is, carry a name, and do its job on the press action
// a reader sends.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "AccessibleControls"
    when: windowShown

    function track() {
        return {
            id: 4242, title: "Weit hinter dem Horizont",
            artists: "Erika Mustermann", artistId: 11,
            artistList: [{ id: 11, name: "Erika Mustermann" }],
            albumTitle: "Nachtfahrt", albumId: 7788,
            coverUrl: "", coverUrl80: "", duration: 215, durationStr: "3:35"
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        player.setCurrentTrackForTest(track())
        player.setShuffle(false)
        player.setMuted(false)
    }

    // ── hosts ────────────────────────────────────────────────────────────

    Component {
        id: plainHost
        Window {
            id: w
            width: 1100; height: 700
            property int backs: 0
            property var navCalls: []
            function goBack() { backs++ }
            function navigate(page, params) { navCalls = navCalls.concat([page]) }
        }
    }

    Component { id: barC;      PlayerBar { } }
    Component { id: pillC;     PillButton { text: "Abspielen" } }
    Component { id: backC;     BackButton { } }
    Component { id: cardC;     MediaCard { title: "Nachtfahrt"; subtitle: "Erika Mustermann"; itemId: "7788" } }
    Component { id: rowC;      TrackRow { width: 800 } }
    Component { id: finderC;   LibraryFinder { width: 200 } }
    Component { id: npC;       NowPlayingPage { } }
    Component {
        id: npHost
        Window {
            width: 1280; height: 900
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) { sleepTimerActive = true }
            function cancelSleepTimer() { sleepTimerActive = false }
            function formatSleepTime(seconds) { return "0:30" }
            property bool fullScreen: false
            property int backs: 0
            function toggleFullScreen() { fullScreen = !fullScreen }
            function navigate(page, params) {}
            function goBack() { backs++ }
            property alias page: np
            NowPlayingPage { id: np; anchors.fill: parent }
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────

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

    function place(host, component, props) {
        var item = createTemporaryObject(component, host.contentItem, props || {})
        verify(item, "the control was not created")
        frame(host.contentItem)
        return item
    }

    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name && item.visible !== false) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findNamed(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function allNamed(item, name, out) {
        out = out || []
        if (!item) return out
        if (item.objectName === name && item.visible !== false) out.push(item)
        for (var i = 0; i < item.children.length; ++i) allNamed(item.children[i], name, out)
        return out
    }

    // A button a reader can find, name and press.
    function checkButton(item, what) {
        verify(item, what + " not found")
        verify(a11y.exposed(item), what + " is invisible to a screen reader")
        compare(a11y.role(item), Accessible.Button, what + " role")
        verify(a11y.name(item).length > 0, what + " has no name")
        verify(a11y.actions(item).indexOf("Press") >= 0,
               what + " offers no press action: " + a11y.actions(item))
    }

    // ── the player bar ───────────────────────────────────────────────────

    function test_player_bar_buttons() {
        var host = show(plainHost)
        var bar = place(host, barC, { width: 1100 })
        var names = ["playerBarShuffle", "playerBarPrevious", "playerBarPlayButton",
                     "playerBarNext", "playerBarRepeat", "playerBarVolumeButton",
                     "playerBarOutputButton", "playerBarNowPlayingButton",
                     "playerBarQueueButton", "playerLikeButton"]
        for (var i = 0; i < names.length; ++i)
            checkButton(findNamed(bar, names[i]), names[i])

        // The press does what a click does.
        var play = findNamed(bar, "playerBarPlayButton")
        var was = player.playing
        verify(a11y.press(play))
        compare(player.playing, !was)
        compare(a11y.name(play), was ? "Play" : "Pause")

        // Shuffle reads as a switch that is on or off.
        var shuffle = findNamed(bar, "playerBarShuffle")
        verify(a11y.checkable(shuffle), "shuffle is not checkable")
        verify(!a11y.checked(shuffle))
        verify(a11y.press(shuffle))
        verify(player.shuffle)
        verify(a11y.checked(shuffle), "shuffle does not read as on")

        var queueOpens = 0
        bar.showQueue.connect(function () { queueOpens++ })
        verify(a11y.press(findNamed(bar, "playerBarQueueButton")))
        compare(queueOpens, 1)
    }

    // ── the shared buttons ───────────────────────────────────────────────

    function test_pill_button() {
        var host = show(plainHost)
        var pill = place(host, pillC)
        checkButton(pill, "PillButton")
        compare(a11y.name(pill), "Abspielen")
        var clicks = 0
        pill.clicked.connect(function () { clicks++ })
        verify(a11y.press(pill))
        compare(clicks, 1)
    }

    function test_back_button() {
        var host = show(plainHost)
        var back = place(host, backC)
        checkButton(back, "BackButton")
        verify(a11y.press(back))
        compare(host.backs, 1)
    }

    function test_media_card() {
        var host = show(plainHost)
        var card = place(host, cardC)
        checkButton(card, "MediaCard")
        verify(a11y.name(card).indexOf("Nachtfahrt") >= 0, a11y.name(card))
        var opens = 0
        card.clicked.connect(function () { opens++ })
        verify(a11y.press(card))
        compare(opens, 1)
    }

    function test_track_row() {
        var host = show(plainHost)
        var t = track()
        var row = place(host, rowC, { title: t.title, artists: t.artists, trackData: t })
        verify(a11y.exposed(row), "a track row is invisible to a screen reader")
        compare(a11y.role(row), Accessible.ListItem)
        verify(a11y.name(row).indexOf(t.title) >= 0, a11y.name(row))
        verify(a11y.name(row).indexOf(t.artists) >= 0, a11y.name(row))
        var plays = 0
        row.playRequested.connect(function () { plays++ })
        player.setCurrentTrackForTest({ id: 1, title: "x" })
        verify(a11y.press(row), "a track row offers no press action: " + a11y.actions(row))
        compare(plays, 1)
    }

    function test_finder_chips() {
        var host = show(plainHost)
        var finder = place(host, finderC)
        var chips = allNamed(finder, "finderChip")
        compare(chips.length, 5)
        for (var i = 0; i < chips.length; ++i) {
            checkButton(chips[i], "finder chip " + i)
            verify(a11y.checkable(chips[i]), "finder chip " + i + " is not checkable")
        }
        compare(a11y.name(chips[0]), "Tracks")
        verify(a11y.press(chips[0]))
        compare(finder.kinds.length, 1)
        verify(a11y.checked(chips[0]), "a chip that is on does not say so")
    }

    // ── Now Playing ──────────────────────────────────────────────────────

    function test_now_playing_controls() {
        var host = show(npHost)
        var page = host.page
        var names = ["nowPlayingCollapse", "nowPlayingFullscreen", "nowPlayingShuffle",
                     "nowPlayingPrevious", "nowPlayingPlayButton", "nowPlayingNext",
                     "nowPlayingRepeat", "nowPlayingLikeButton", "nowPlayingMuteButton",
                     "nowPlayingDownloadButton", "nowPlayingCreditsToggle"]
        for (var i = 0; i < names.length; ++i)
            checkButton(findNamed(page, names[i]), names[i])

        var credits = findNamed(page, "nowPlayingCreditsToggle")
        verify(a11y.checkable(credits), "the Credits chip is not checkable")
        verify(credits.activeFocusOnTab, "the Credits chip is not a tab stop")

        verify(a11y.press(findNamed(page, "nowPlayingCollapse")))
        compare(host.backs, 1)

        var next = findNamed(page, "nowPlayingShuffle")
        verify(a11y.press(next))
        verify(player.shuffle)
    }
}
