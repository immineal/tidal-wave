import QtQuick
import TidalWave

// Shared pill-shaped action button (Play / Shuffle / etc.) used across
// Album, Artist, Playlist and Mix pages — keyboard accessible (Tab to
// focus, Enter/Space to activate) with a visible focus ring.
Item {
    id: root

    property string text: ""
    property string glyph: ""
    property bool   accent: true

    signal clicked()

    width: 120
    height: 40
    activeFocusOnTab: true

    Rectangle {
        anchors.fill: parent
        radius: 20
        color: root.accent ? Theme.accent : Theme.surfaceHigh
        border.width: root.activeFocus ? 2 : (root.accent ? 0 : 1)
        border.color: root.activeFocus ? Theme.accent : Theme.border

        Row {
            anchors.centerIn: parent
            spacing: 8
            VectorIcon {
                id: glyphIcon
                name: root.glyph === "▶" ? "play" : (root.glyph === "⇌" ? "shuffle" : root.glyph)
                color: root.accent ? "white" : Theme.textPrimary
                width: 14
                height: 14
                strokeWidth: 1.8
                anchors.verticalCenter: parent.verticalCenter
                visible: root.glyph !== ""
            }
            Text { text: root.text;  color: root.accent ? "white" : Theme.textPrimary; font.pixelSize: 14; font.bold: root.accent; anchors.verticalCenter: parent.verticalCenter }
        }

        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: root.clicked() }
    }

    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed:  root.clicked()
}
