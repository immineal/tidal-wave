// The window every scene is built inside. An ApplicationWindow, as Main.qml
// is: SettingsPanel is a Popup that reparents itself to `Overlay.overlay`,
// which a plain Window does not have. It also carries the surface pages reach
// through `Window.window`: navigation, back and the sleep timer, mirrored with
// no behaviour. Not named tst_*.qml, so QtQuickTest does not run it.

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import TidalWave

ApplicationWindow {
    id: host

    // The page ground, so a component shot sits on the colour the app would
    // put behind it.
    color: Theme.bg

    // Where a scene puts its content. Declared rather than using the default
    // property so a scene can also add a Popup, which is not an Item.
    default property alias content: contentHolder.data

    // ── Main.qml's navigation surface ────────────────────────────────────
    property string lastPage: ""
    function navigate(page, params) { host.lastPage = page }
    function goBack() { host.lastPage = "back" }

    // ── Main.qml's sleep timer surface ───────────────────────────────────
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

    Item {
        id: contentHolder
        anchors.fill: parent
    }
}
