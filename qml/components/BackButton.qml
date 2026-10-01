import QtQuick
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    width: 36; height: 36; radius: 18

    // Where this sits decides the treatment, and it sits in two places. On
    // Album, Playlist and Mix it is over a hero that is a tint of the page. On
    // Artist it is genuinely over the artist photo.
    //
    // It used to be a near-opaque disc of theme ink, which survived both but
    // read as a bright blob on the dark themes. An outlined ghost is quiet on
    // a flat hero and still holds its edge over a photo, because the border
    // carries the shape when the fill alone would not.
    readonly property color ink: Theme.textPrimary

    // Named so tests/qml/tst_reduced_motion.qml can assert the fade between
    // them without naming a palette token. That test is about the animation,
    // and these ends have now moved twice.
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

    // Drawn, not set in a font. The arrow was "←", which renders differently
    // or not at all wherever the font behind it is missing; that is the same
    // trap the app mark was pulled out of.
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
