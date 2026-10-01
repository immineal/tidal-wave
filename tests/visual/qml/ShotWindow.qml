// The window every scene is built inside.
//
// It is an ApplicationWindow, not a plain Window, for two reasons:
//
//   * SettingsPanel is a Popup that reparents itself to `Overlay.overlay` and
//     clamps its own width to the overlay's. A plain Window has no overlay, so
//     `parent` is null there and the panel comes up 416px wide at the top left
//     corner - a picture of the harness rather than of the app.
//   * Main.qml is an ApplicationWindow, so this is what the components are
//     written against.
//
// It also carries the surface Main.qml puts on the window and that pages reach
// through `Window.window`: navigation, back, and the whole sleep timer, which
// NowPlayingPage reads five properties and three functions of. Without them
// the page fills the log with "Unable to assign [undefined]" and
// "Property 'formatSleepTime' is not a function" before it draws anything.
// Mirrored here with no behaviour, the same way tests/stress/qml/NowPlayingHost.qml
// does it.
//
// Not named tst_*.qml, so QtQuickTest does not try to run it as a test case.

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import TidalWave

ApplicationWindow {
    id: host

    // The page ground, so a component shot sits on the same colour the app
    // would put behind it instead of on whatever the platform defaults to.
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
