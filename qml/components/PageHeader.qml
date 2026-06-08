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
            Behavior on color { ColorAnimation { duration: 100 } }
            activeFocusOnTab: true
            Keys.onReturnPressed: root.backClicked()
            Keys.onSpacePressed:  root.backClicked()
            Text {
                anchors.centerIn: parent
                text: "←"
                color: Theme.textSec
                font.pixelSize: 18
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
