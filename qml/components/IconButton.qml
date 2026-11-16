import QtQuick
import QtQuick.Controls
import TidalWave

// The one icon button: a glyph in a round target of at least 32px, with its
// label as the screen reader's name and the tool tip. Hover tints the disc
// behind the glyph, so an active glyph keeps its accent under the pointer.
// `backed` adds a disc at rest, for chrome that can sit over artwork.
Item {
    id: root

    // A VectorIcon name, never a character.
    property string icon
    property string label
    // The glyph's side, and the air around it. The target is the two
    // together and never drops below 32.
    property int    size: 18
    property int    pad: Theme.space3
    property color  iconColor: Theme.textSec
    // On: shuffle or repeat on, a liked track. Drawn in the accent.
    property bool   active: false
    // Whether `active` is a state a screen reader should announce.
    property bool   checkable: false
    property bool   backed: false
    property bool   showTip: true

    readonly property alias hovered: hov.hovered
    signal clicked()

    // Named so tests can assert the fade between them without a palette token.
    readonly property color restFill: root.backed
        ? Qt.rgba(Theme.surfaceHigh.r, Theme.surfaceHigh.g, Theme.surfaceHigh.b, 0.55)
        : "transparent"
    readonly property color hoveredFill: root.backed
        ? Qt.rgba(Theme.surfaceHigh.r, Theme.surfaceHigh.g, Theme.surfaceHigh.b, 0.90)
        : Theme.hoverFill

    implicitWidth:  Math.max(size + pad, 32)
    implicitHeight: implicitWidth

    activeFocusOnTab: true
    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed:  root.clicked()
    Accessible.role: Accessible.Button
    Accessible.name: root.label
    Accessible.checkable: root.checkable
    Accessible.checked: root.active
    Accessible.onPressAction: root.clicked()
    Accessible.onToggleAction: root.clicked()

    Rectangle {
        objectName: "iconButtonDisc"
        anchors.centerIn: parent
        width: Math.min(parent.width, parent.height)
        height: width
        radius: width / 2
        color: hov.hovered ? root.hoveredFill : root.restFill
        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }
        // The focus ring takes over the border, so focus never reads as hover.
        border.width: root.activeFocus ? 2 : (root.backed ? 1 : 0)
        border.color: root.activeFocus ? Theme.accent
                    : (hov.hovered ? Theme.textSec : Theme.border)
    }

    VectorIcon {
        objectName: "iconButtonGlyph"
        anchors.centerIn: parent
        name: root.icon
        width: root.size
        height: root.size
        color: root.active ? Theme.accentText
             : hov.hovered ? Theme.textPrimary
             : root.iconColor
    }

    HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
    // ReleaseWithinBounds: a DragThreshold TapHandler takes only a passive
    // grab, so whatever lies underneath would answer the same tap.
    TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: root.clicked() }

    ToolTip.visible: root.showTip && hov.hovered && root.label.length > 0
    ToolTip.text: root.label
    ToolTip.delay: Theme.tooltipDelay
}
