import QtQuick
import QtQuick.Controls
import QtQuick.Window

// Says what CastManager::error() reports, once, above the output button on
// screen: the control the cast is started and stopped from. Main.qml holds
// the one instance. It waits for the window, as LoadErrorTip does.
Item {
    id: tip
    objectName: "castErrorTip"

    // CastManager, which only exists on Linux. A property so a host can hand
    // in a double.
    property var castSource: (typeof cast !== "undefined") ? cast : null

    // Same dwell as LoadErrorTip, and for the same reason no Theme.dur().
    readonly property int dwellMs: 6000

    // Said but not yet on screen.
    property string pending: ""
    property bool shown: false

    // Captured while this sits in the window: the tip is moved into a
    // button, which a page can unload from under it.
    property var hostWindow: null
    Component.onCompleted: hostWindow = Window.window

    // sync() asks afresh: on Qt 6.4 the window's change signals come a turn
    // late, and the binding still says on screen just after a hide().
    function windowShows() {
        return !!hostWindow && hostWindow.visible
            && hostWindow.visibility !== Window.Hidden
            && hostWindow.visibility !== Window.Minimized
    }
    readonly property bool windowOnScreen: windowShows()
    readonly property bool onScreen: parent !== null && parent.visible && windowOnScreen

    // Placed over the button it is moved into, so the tip stands above that.
    x: 0
    y: 0
    width:  parent ? parent.width : 0
    height: parent ? parent.height : 0

    // The bar's button first; Now Playing names only its on-screen copy so.
    readonly property var anchorNames: ["playerBarOutputButton", "nowPlayingOutputButton"]

    function findNamed(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var found = findNamed(kids[i], name)
            if (found) return found
        }
        return null
    }

    function visibleAnchor() {
        if (!hostWindow) return null
        for (var i = 0; i < anchorNames.length; ++i) {
            var a = findNamed(hostWindow.contentItem, anchorNames[i])
            if (a && a.visible) return a
        }
        return null
    }

    function sync() {
        if (pending === "" || !windowShows()) return
        var a = visibleAnchor()
        if (!a) return
        tip.parent = a
        tip.shown = true
        tip.ToolTip.show(pending, dwellMs)
        pending = ""
    }

    // The tip is drawn over the window, so it is taken down with its button.
    onOnScreenChanged: {
        if (!onScreen && shown) {
            shown = false
            tip.ToolTip.hide()
        }
    }
    onWindowOnScreenChanged: sync()

    Connections {
        target: tip.castSource
        ignoreUnknownSignals: true
        function onError(msg) {
            tip.pending = msg
            tip.sync()
        }
    }

    // No button may be on screen yet, mid-way into Now Playing for one.
    Timer {
        interval: 300
        repeat: true
        running: tip.pending !== "" && tip.windowOnScreen
        onTriggered: tip.sync()
    }
}
