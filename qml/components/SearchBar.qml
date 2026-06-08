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

    function releaseFocus() {
        input.focus = false
    }

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
        Item {
            id: clearBtn
            visible: input.text.length > 0
            width: 14
            height: 14
            Layout.alignment: Qt.AlignVCenter
            activeFocusOnTab: true
            Keys.onReturnPressed: input.text = ""
            Keys.onSpacePressed:  input.text = ""
            Rectangle {
                anchors.fill: parent; anchors.margins: -4; radius: 4; color: "transparent"
                border.width: clearBtn.activeFocus ? 2 : 0
                border.color: Theme.accent
            }
            VectorIcon {
                anchors.fill: parent
                name: "x"
                color: clearBtn.activeFocus ? Theme.accent : Theme.textDim
                strokeWidth: 1.8
            }
            MouseArea {
                anchors.fill: parent
                onClicked: input.text = ""
                cursorShape: Qt.PointingHandCursor
            }
        }
    }
}
