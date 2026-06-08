import QtQuick
import QtQuick.Layouts
import TidalWave

Rectangle {
    id: root
    height: 40
    radius: Theme.radius
    color: Theme.surfaceHigh
    border.color: focused ? Theme.accent : "transparent"
    border.width: 1

    property alias text: input.text
    property bool  focused: input.activeFocus
    property string placeholder: "Search…"
    signal submitted(string text)
    signal textEdited(string text)

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 8
        VectorIcon {
            name: "search"
            color: Theme.textDim
            width: 16
            height: 16
            strokeWidth: 1.8
        }
        Item {
            Layout.fillWidth: true
            height: input.implicitHeight
            TextInput {
                id: input
                anchors.fill: parent
                color: Theme.textPrimary
                font.pixelSize: 14
                verticalAlignment: TextInput.AlignVCenter
                Keys.onReturnPressed: root.submitted(text)
                onTextChanged: root.textEdited(text)
            }
            Text {
                anchors.fill: parent
                visible: input.text.length === 0
                text: root.placeholder
                color: Theme.textDim
                font.pixelSize: 14
                verticalAlignment: Text.AlignVCenter
            }
        }
        Text {
            visible: input.text.length > 0
            text: "✕"
            color: Theme.textDim
            font.pixelSize: 13
            MouseArea {
                anchors.fill: parent
                onClicked: input.text = ""
                cursorShape: Qt.PointingHandCursor
            }
        }
    }
}
