import QtQuick
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    width: 36; height: 36; radius: 18
    // Sits on cover art, which is neither light nor dark, so the wash is the
    // same in every theme.
    color: hov.hovered ? Theme.artScrimStrong : Theme.artScrim
    border.width: root.activeFocus ? 2 : 0
    border.color: Theme.accent
    z: 100

    activeFocusOnTab: true
    Keys.onReturnPressed: root.Window.window.goBack()
    Keys.onSpacePressed:  root.Window.window.goBack()

    Behavior on color { ColorAnimation { duration: Theme.dur(100) } }

    Text {
        anchors.centerIn: parent
        text: "←"
        color: Theme.onArt
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
