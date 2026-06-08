import QtQuick
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    width: 36; height: 36; radius: 18
    color: hov.hovered ? Qt.rgba(0, 0, 0, 0.55) : Qt.rgba(0, 0, 0, 0.35)
    border.width: root.activeFocus ? 2 : 0
    border.color: Theme.accent
    z: 100

    activeFocusOnTab: true
    Keys.onReturnPressed: root.Window.window.goBack()
    Keys.onSpacePressed:  root.Window.window.goBack()

    Behavior on color { ColorAnimation { duration: 100 } }

    Text {
        anchors.centerIn: parent
        text: "←"
        color: Theme.textPrimary
        font.pixelSize: 18
    }

    HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
    TapHandler   {
        // `Window.window` resolves to null when read from a handler
        // attached to a non-Item (TapHandler isn't a QQuickItem), so
        // qualify it through `root` to attach to a real Item instead.
        onTapped: root.Window.window.goBack()
    }
}
