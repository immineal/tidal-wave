import QtQuick
import QtQuick.Layouts
import TidalWave

Rectangle {
    id: root
    height: 40
    radius: Theme.radiusLarge
    color: Theme.surfaceHigh
    border.color: focused ? Theme.accent : "transparent"
    border.width: 1

    property alias text: input.text
    property bool  focused: input.activeFocus
    property string placeholder: qsTr("Search…")
    signal submitted(string text)
    signal textEdited(string text)

    function releaseFocus() {
        input.focus = false
    }

    // This is a Rectangle, not a FocusScope, so clearing input.focus leaves
    // the enclosing scope with no focus item. Only the input can put itself
    // back. The text comes up selected, so typing replaces the old query.
    function takeFocus() {
        input.forceActiveFocus()
        input.selectAll()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space3
        // Less while the 32px clear target is there, so its cross keeps
        // the place a 14px button had.
        anchors.rightMargin: clearBtn.visible ? Theme.space1 : Theme.space3
        spacing: Theme.space2
        VectorIcon {
            name: "search"
            color: Theme.textDim
            width: 16
            height: 16
        }
        Item {
            Layout.fillWidth: true
            height: input.implicitHeight
            TextInput {
                id: input
                anchors.fill: parent
                focus: true
                color: Theme.textPrimary
                font.pixelSize: Theme.fontBody
                verticalAlignment: TextInput.AlignVCenter
                Keys.onReturnPressed: root.submitted(text)
                onTextChanged: root.textEdited(text)
            }
            Text {
                anchors.fill: parent
                visible: input.text.length === 0
                text: root.placeholder
                color: Theme.textDim
                font.pixelSize: Theme.fontBody
                verticalAlignment: Text.AlignVCenter
            }
        }
        // A 32px target round the 14px cross.
        Item {
            id: clearBtn
            objectName: "searchClear"
            visible: input.text.length > 0
            Layout.preferredWidth: 32
            Layout.preferredHeight: 32
            Layout.alignment: Qt.AlignVCenter
            activeFocusOnTab: true
            Keys.onReturnPressed: input.text = ""
            Keys.onSpacePressed:  input.text = ""
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Clear search", "button, empties the search field")
            Accessible.onPressAction: input.text = ""
            Rectangle {
                anchors.centerIn: parent; width: 22; height: 22; radius: Theme.radiusMedium; color: "transparent"
                border.width: clearBtn.activeFocus ? 2 : 0
                border.color: Theme.accent
            }
            VectorIcon {
                anchors.centerIn: parent
                width: 14; height: 14
                name: "x"
                color: clearBtn.activeFocus ? Theme.accentText : Theme.textDim
            }
            MouseArea {
                anchors.fill: parent
                onClicked: input.text = ""
                cursorShape: Qt.PointingHandCursor
            }
        }
    }
}
