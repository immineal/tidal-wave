import QtQuick
import TidalWave

// Shared pill-shaped action button (Play / Shuffle / etc.) used across
// Album, Artist, Playlist and Mix pages. Keyboard accessible (Tab to
// focus, Enter/Space to activate) with a visible focus ring.
Item {
    id: root

    property string text: ""
    // A VectorIcon name, never a character.
    property string icon: ""
    property bool   accent: true

    // Sized to its label, because German runs long on exactly these words.
    // The minimum keeps a short label from collapsing to a stub.
    readonly property int hPadding: 18
    readonly property int minWidth: 96

    signal clicked()

    implicitWidth: Math.max(minWidth, content.implicitWidth + 2 * hPadding)
    implicitHeight: 40
    activeFocusOnTab: true

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusChip
        // An accent pill lifts toward its own brighter shade on hover; an
        // outlined one fills, since darkening its border alone is too quiet.
        color: root.accent
               ? (hover.hovered ? Qt.lighter(Theme.accent, 1.18) : Theme.accent)
               : (hover.hovered ? Theme.surfaceHov : Theme.surfaceHigh)
        Behavior on color { ColorAnimation { duration: Theme.dur(110) } }
        border.width: root.activeFocus ? 2 : (root.accent ? 0 : 1)
        border.color: root.activeFocus ? Theme.accent
                    : (hover.hovered && !root.accent ? Theme.textSec : Theme.border)

        Row {
            id: content
            anchors.centerIn: parent
            spacing: 8
            VectorIcon {
                id: pillIcon
                name: root.icon
                color: root.accent ? Theme.accentInk : Theme.textPrimary
                width: 14
                height: 14
                strokeWidth: 1.8
                anchors.verticalCenter: parent.verticalCenter
                visible: root.icon !== ""
            }
            Text { objectName: "pillLabel"; text: root.text;  color: root.accent ? Theme.accentInk : Theme.textPrimary; font.pixelSize: 14; font.bold: root.accent; anchors.verticalCenter: parent.verticalCenter }
        }

        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: root.clicked() }
    }

    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed:  root.clicked()
}
