// The seek bar, the volume and the sleep timer's custom length, moved from
// the keyboard and read by a screen reader as sliders with a value.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "KeyboardSliders"
    when: windowShown

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        player.setCurrentTrackForTest({ id: 4242, title: "Weit hinter dem Horizont",
                                        artists: "Erika Mustermann", duration: 200 })
        player.setDurationForTest(200000)
        player.setPositionForTest(60000)
        player.setMuted(false)
        player.setVolume(0.5)
    }

    Component {
        id: plainHost
        Window { width: 1100; height: 700 }
    }
    Component { id: seekC;   SeekBar { width: 400 } }
    Component { id: volumeC; VolumeSlider { width: 120 } }
    Component { id: barC;    PlayerBar { width: 1100 } }
    Component {
        id: npHost
        Window {
            width: 1280; height: 900
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            property var  started: null
            function startSleepTimer(minutes, stopAtEnd) {
                started = { minutes: minutes, stopAtEnd: stopAtEnd }
                sleepTimerActive = true
            }
            function cancelSleepTimer() { sleepTimerActive = false }
            function formatSleepTime(seconds) { return "0:30" }
            property bool fullScreen: false
            function toggleFullScreen() { fullScreen = !fullScreen }
            function navigate(page, params) {}
            function goBack() {}
            property alias page: np
            NowPlayingPage { id: np; anchors.fill: parent }
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
        host.requestActivate()
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
        // data, so a Popup (an object, never an item child) is found too.
        var kids = item.data || item.children || []
        for (var i = 0; i < kids.length; ++i) {
            var hit = findNamed(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function test_seek_bar() {
        var host = show(plainHost)
        var bar = place(host, seekC, { position: 60000, duration: 200000 })
        var seeks = []
        bar.seeked.connect(function (ms) { seeks.push(ms) })

        verify(bar.activeFocusOnTab, "the seek bar is not a tab stop")
        compare(a11y.role(bar), Accessible.Slider)
        verify(a11y.name(bar).length > 0, "the seek bar has no name")
        compare(a11y.value(bar), 60)

        bar.forceActiveFocus()
        keyClick(Qt.Key_Right)
        compare(seeks, [70000])
        bar.position = 70000
        keyClick(Qt.Key_Left)
        compare(seeks[1], 60000)
        keyClick(Qt.Key_Home)
        compare(seeks[2], 0)

        verify(a11y.increase(bar), "the seek bar has no increase action")
        compare(seeks[3], 80000)
    }

    function test_volume_slider() {
        var host = show(plainHost)
        var vol = place(host, volumeC, { value: 0.5 })
        var moves = []
        vol.moved.connect(function (v) { moves.push(v) })

        verify(vol.activeFocusOnTab, "the volume slider is not a tab stop")
        compare(a11y.role(vol), Accessible.Slider)
        verify(a11y.name(vol).length > 0, "the volume slider has no name")
        compare(a11y.value(vol), 0.5)

        vol.forceActiveFocus()
        keyClick(Qt.Key_Up)
        fuzzyCompare(moves[0], 0.55, 1e-9)
        keyClick(Qt.Key_End)
        compare(moves[1], 1)
        verify(a11y.decrease(vol))
        fuzzyCompare(moves[2], 0.45, 1e-9)
    }

    // The flyout used to open on hover only: from the keyboard the speaker
    // brings it up and the arrows move it.
    function test_bar_volume_from_the_keyboard() {
        var host = show(plainHost)
        var bar = place(host, barC)
        var speaker = findNamed(bar, "playerBarVolumeButton")
        verify(speaker)
        speaker.forceActiveFocus()
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 1000,
                  "focus on the speaker does not show the volume")
        keyClick(Qt.Key_Up)
        fuzzyCompare(player.volume, 0.55, 1e-9)
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Down)
        fuzzyCompare(player.volume, 0.45, 1e-9)
        compare(a11y.role(bar.hoverVolumeSlider), Accessible.Slider)
    }

    function test_sleep_timer_from_the_keyboard() {
        var host = show(npHost)
        var pill = findNamed(host.page, "nowPlayingSleepTimerButton")
        verify(pill)
        verify(pill.activeFocusOnTab, "the sleep timer pill is not a tab stop")
        compare(a11y.role(pill), Accessible.Button)
        pill.forceActiveFocus()
        keyClick(Qt.Key_Return)
        var popup = findNamed(host.page, "nowPlayingSleepTimerPopup")
        tryVerify(function () { return popup.opened }, 1000, "Enter does not open the popup")

        var slider = findNamed(popup.contentItem, "nowPlayingSleepSlider")
        verify(slider, "no custom length slider")
        verify(slider.activeFocusOnTab, "the custom length is not a tab stop")
        compare(a11y.role(slider), Accessible.Slider)
        compare(a11y.value(slider), 20)
        slider.forceActiveFocus()
        keyClick(Qt.Key_Right)
        compare(slider.value, 21)
        keyClick(Qt.Key_PageUp)
        compare(slider.value, 31)
        keyClick(Qt.Key_Home)
        compare(slider.value, 1)
        verify(a11y.increase(slider))
        compare(slider.value, 2)

        var start = findNamed(popup.contentItem, "nowPlayingSleepTimerStart")
        start.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(host.started.minutes, 2)
    }
}
