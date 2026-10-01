import QtQuick
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    width: 36; height: 36; radius: 18

    // Where this actually sits decides the colour, and it sits in two places.
    // On Album, Playlist and Mix it is over a hero that is a tint of the page,
    // so it has to follow the theme: the old artScrim/artInk pair is black at
    // 35% with a white arrow, which on a light theme is a grey smudge at
    // 2.97:1 that barely separates from the hero behind it.
    // On Artist it is genuinely over cover art, which is neither light nor
    // dark. Rather than give the two cases different treatments - the pages
    // would have to agree which one they are - the disc is near-opaque ink
    // from the theme with the page's own ground as the arrow. Being near
    // opaque is what makes it work over artwork: whatever is underneath, the
    // composite lands within a few percent of textPrimary, so the arrow keeps
    // the full textPrimary-on-bg contrast either way.
    readonly property color ink: Theme.textPrimary

    // The two ends are named so tests/qml/tst_reduced_motion.qml can assert
    // the fade between them without naming a palette token. It used to
    // compare against Theme.artScrim directly, and the ends have now moved
    // once; whatever they become next, that test is about the animation.
    readonly property color restFill:    Qt.rgba(ink.r, ink.g, ink.b, 0.80)
    readonly property color hoveredFill: Qt.rgba(ink.r, ink.g, ink.b, 0.96)
    color: hov.hovered ? root.hoveredFill : root.restFill

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
        color: Theme.bg
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
