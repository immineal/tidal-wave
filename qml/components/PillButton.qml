import QtQuick
import TidalWave

// The one text button: the detail pages' Play and Shuffle, every dialog's
// answers, the settings panel's actions. `compact` is the smaller size for a
// panel row. Tab focuses it, Enter or Space presses it.
Item {
    id: root

    property string text: ""
    // A VectorIcon name, never a character.
    property string icon: ""
    property bool   accent: true
    // For the one button of a dialog that destroys something: solid red.
    // With accent off it stays outlined and turns red only on hover.
    property bool   danger: false
    property bool   compact: false
    // Still clickable, drawn as "this will not do much right now".
    property bool   muted: false
    // The glyph's own ink, for a state the label does not carry. Undefined
    // follows the label.
    property var    iconColor: undefined
    readonly property bool solidDanger: danger && accent
    readonly property bool quietDanger: danger && !accent

    // Sized to its label, because German runs long on exactly these words.
    // The minimum keeps a short label from collapsing to a stub.
    readonly property int hPadding: compact ? Theme.space3 : Theme.space5
    readonly property int minWidth: compact ? 0 : 96

    signal clicked()

    implicitWidth: Math.max(minWidth, content.implicitWidth + 2 * hPadding)
    implicitHeight: compact ? 32 : 40
    opacity: muted ? 0.5 : 1
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: root.text
    Accessible.onPressAction: root.clicked()

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusChip
        // An accent pill lifts toward its own brighter shade on hover; an
        // outlined one fills, since darkening its border alone is too quiet.
        color: root.solidDanger
               ? (hover.hovered ? Qt.lighter(Theme.red, 1.12) : Theme.red)
               : root.quietDanger && hover.hovered ? Theme.red
               : root.accent
               ? (hover.hovered ? Qt.lighter(Theme.accent, 1.18) : Theme.accent)
               : (hover.hovered ? Qt.tint(Theme.surfaceHigh, Theme.hoverFill) : Theme.surfaceHigh)
        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }
        border.width: root.activeFocus ? 2 : (root.accent ? 0 : 1)
        border.color: root.activeFocus ? Theme.accent
                    : root.quietDanger && hover.hovered ? Theme.red
                    : (hover.hovered && !root.accent ? Theme.textSec : Theme.border)

        Row {
            id: content
            anchors.centerIn: parent
            spacing: Theme.space2
            VectorIcon {
                id: pillIcon
                name: root.icon
                color: root.iconColor !== undefined ? root.iconColor : pillText.color
                width: root.compact ? 13 : 14
                height: width
                anchors.verticalCenter: parent.verticalCenter
                visible: root.icon !== ""
            }
            Text {
                id: pillText
                objectName: "pillLabel"
                text: root.text
                color: root.solidDanger ? Theme.redInk
                     : root.quietDanger ? (hover.hovered ? Theme.redInk : Theme.redText)
                     : root.accent      ? Theme.accentInk : Theme.textPrimary
                font.pixelSize: root.compact ? Theme.fontMeta : Theme.fontBody
                font.bold: root.accent
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        // Exclusive on press: a passive grab in a scrolled Flickable inside a
        // modal Popup lets the press through to the page beneath.
        TapHandler   { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: root.clicked() }
    }

    Keys.onReturnPressed: root.clicked()
    Keys.onEnterPressed:  root.clicked()
    Keys.onSpacePressed:  root.clicked()
}
