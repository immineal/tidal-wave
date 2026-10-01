import QtQuick
import QtQuick.Layouts
import TidalWave

Rectangle {
    id: root
    height: 52
    color: "transparent"

    property string title: ""
    property bool   showBack: true
    signal backClicked()

    RowLayout {
        anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
        spacing: 12

        Rectangle {
            id: backBtn
            visible: showBack
            width: 32; height: 32; radius: 16
            color: backHov.hovered ? Theme.surfaceHov : "transparent"
            border.width: activeFocus ? 2 : 0
            border.color: Theme.accent
            Behavior on color { ColorAnimation { duration: Theme.dur(100) } }
            activeFocusOnTab: true
            Keys.onReturnPressed: root.backClicked()
            Keys.onSpacePressed:  root.backClicked()
            // Drawn, not set in a font, for the reason BackButton gives: the
            // arrow was a character that renders differently or not at all
            // wherever the font behind it is missing.
            VectorIcon {
                anchors.centerIn: parent
                name: "chevron-left"
                color: Theme.textSec
                width: 16; height: 16
                strokeWidth: 2
            }
            HoverHandler { id: backHov; cursorShape: Qt.PointingHandCursor }
            TapHandler   { onTapped: root.backClicked() }
        }

        Text {
            text: root.title
            color: Theme.textPrimary
            font.pixelSize: 18
            font.bold: true
        }

        Item { Layout.fillWidth: true }
    }
}
