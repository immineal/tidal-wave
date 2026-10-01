import QtQuick
import TidalWave

// Shared pill-shaped action button (Play / Shuffle / etc.) used across
// Album, Artist, Playlist and Mix pages. Keyboard accessible (Tab to
// focus, Enter/Space to activate) with a visible focus ring.
Item {
    id: root

    property string text: ""
    property string glyph: ""
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
        color: root.accent ? Theme.accent : Theme.surfaceHigh
        border.width: root.activeFocus ? 2 : (root.accent ? 0 : 1)
        border.color: root.activeFocus ? Theme.accent : Theme.border

        Row {
            id: content
            anchors.centerIn: parent
            spacing: 8
            VectorIcon {
                id: glyphIcon
                name: root.glyph === "▶" ? "play"
                    : root.glyph === "⇌" ? "shuffle"
                    : root.glyph === "♥" ? "heart-filled"
                    : root.glyph === "♡" ? "heart"
                    : root.glyph === "✎" ? "edit"
                    : root.glyph
                color: root.accent ? Theme.onAccent : Theme.textPrimary
                width: 14
                height: 14
                strokeWidth: 1.8
                anchors.verticalCenter: parent.verticalCenter
                visible: root.glyph !== ""
            }
            Text { objectName: "pillLabel"; text: root.text;  color: root.accent ? Theme.onAccent : Theme.textPrimary; font.pixelSize: 14; font.bold: root.accent; anchors.verticalCenter: parent.verticalCenter }
        }

        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: root.clicked() }
    }

    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed:  root.clicked()
}
