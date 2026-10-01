import QtQuick
import TidalWave

// Shared pill-shaped action button (Play / Shuffle / etc.) used across
// Album, Artist, Playlist and Mix pages. Keyboard accessible (Tab to
// focus, Enter/Space to activate) with a visible focus ring.
Item {
    id: root

    property string text: ""
    // A VectorIcon name, never a character. This used to take a glyph and map
    // it back onto an icon name here, which meant every caller wrote a
    // character it did not render and this file kept the only copy of the
    // translation. Callers name the icon now.
    property string icon: ""
    property bool   accent: true

    // Sized to its label instead of the old fixed 120. German runs long on
    // exactly these words ("Shuffle" becomes "Zufallswiedergabe"), and at 120
    // the label was simply cut. The minimum keeps a short label from
    // collapsing to a stub, so a row of pills still reads as a row.
    readonly property int hPadding: 18
    readonly property int minWidth: 96

    signal clicked()

    implicitWidth: Math.max(minWidth, content.implicitWidth + 2 * hPadding)
    implicitHeight: 40
    activeFocusOnTab: true

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusChip
        // The hover was a cursor change and nothing else, so these read as
        // labels rather than buttons. An accent pill lifts toward its own
        // brighter shade; an outlined one fills, since darkening its border
        // alone is too quiet to notice.
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
