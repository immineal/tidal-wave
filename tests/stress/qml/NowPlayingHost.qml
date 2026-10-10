// A window to host NowPlayingPage in, outside Main.qml. NowPlayingPage reads
// the sleep timer off `Window.window`: five properties and three functions
// that Main.qml's ApplicationWindow declares and the QtQuickTest view does
// not. This stands in with the same surface and no behaviour.
// Not named tst_*.qml, so QtQuickTest does not run it as a test case.

import QtQuick
import QtQuick.Window
import TidalWave

Window {
    id: host
    width: 1200
    height: 820
    visible: true
    color: "black"

    // Mirrors the sleep timer surface Main.qml exposes on the window.
    property bool sleepTimerActive: false
    property bool sleepStopAtEndOfTrack: false
    property int  sleepTimeLeft: 0
    property bool sleepIsFading: false
    property bool sleepFadeOut: true

    function startSleepTimer(minutes, stopAtEnd) {
        sleepTimerActive = true
        sleepStopAtEndOfTrack = stopAtEnd === true
        sleepTimeLeft = minutes * 60
    }
    function cancelSleepTimer() {
        sleepTimerActive = false
        sleepTimeLeft = 0
    }
    function formatSleepTime(seconds) {
        var s = Math.max(0, Math.floor(seconds))
        var m = Math.floor(s / 60)
        var r = s % 60
        return m + ":" + (r < 10 ? "0" : "") + r
    }

    readonly property alias page: np

    NowPlayingPage {
        id: np
        anchors.fill: parent
    }
}
