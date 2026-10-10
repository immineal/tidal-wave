import QtQuick
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    width: 36; height: 36; radius: 18

    // Sits over a flat hero tint on Album, Playlist and Mix and over the photo
    // on Artist. The border carries the shape where the fill alone would not.
    readonly property color ink: Theme.textPrimary

    // Named so tests/qml/tst_reduced_motion.qml can assert the fade between
    // them without naming a palette token.
    readonly property color restFill:
        Qt.rgba(Theme.surfaceHigh.r, Theme.surfaceHigh.g, Theme.surfaceHigh.b, 0.55)
    readonly property color hoveredFill:
        Qt.rgba(Theme.surfaceHigh.r, Theme.surfaceHigh.g, Theme.surfaceHigh.b, 0.90)
    color: hov.hovered ? root.hoveredFill : root.restFill

    // The focus ring takes over the border entirely, so a focused button is
    // never ambiguous against a merely hovered one.
    border.width: root.activeFocus ? 2 : 1
    border.color: root.activeFocus ? Theme.accent
                : (hov.hovered ? Theme.textSec : Theme.border)
    z: 100

    activeFocusOnTab: true
    Keys.onReturnPressed: root.Window.window.goBack()
    Keys.onSpacePressed:  root.Window.window.goBack()

    Behavior on color       { ColorAnimation { duration: Theme.dur(100) } }
    Behavior on border.color { ColorAnimation { duration: Theme.dur(100) } }

    // Drawn, so the arrow does not depend on a font that has the glyph.
    VectorIcon {
        anchors.centerIn: parent
        name: "chevron-left"
        color: root.ink
        width: 18; height: 18
        strokeWidth: 2
    }

    HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
    TapHandler   {
        // `Window.window` resolves to null when read from a handler attached
        // to a non-Item (TapHandler isn't a QQuickItem), so qualify it through
        // `root` to attach to a real Item instead.
        onTapped: root.Window.window.goBack()
    }
}
