import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// A question before something that cannot be taken back: a heading, a line
// of text, Cancel and one red button. The host does the work on `confirmed`
// and closes the dialog, or sets errorText and leaves it open.
Popup {
    id: root
    objectName: "confirmDialog"

    property string heading: ""
    property string text: ""
    property string confirmLabel: ""
    // The red button's label while `busy`.
    property string busyLabel: confirmLabel

    // A request is out: both buttons go quiet and nothing closes the dialog,
    // so the answer never lands on a dialog the user has left.
    property bool busy: false
    property string errorText: ""

    signal confirmed()

    function ask() {
        root.errorText = ""
        root.busy      = false
        root.open()
    }

    function confirm() {
        if (root.busy) return
        root.confirmed()
    }

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(400, (parent ? parent.width : 400) - 48)
    modal: true
    focus: true
    closePolicy: root.busy
                 ? Popup.NoAutoClose
                 : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
    padding: 20

    background: Rectangle {
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusPopup
    }

    // Cancel takes the focus: Return on a dialog that just opened keeps things.
    onOpened: cancelButton.forceActiveFocus()

    contentItem: ColumnLayout {
        spacing: 12

        Text {
            objectName: "confirmDialogHeading"
            Layout.fillWidth: true
            text: root.heading
            color: Theme.textPrimary
            font.pixelSize: 16
            font.bold: true
            wrapMode: Text.WordWrap
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.border
        }

        Text {
            objectName: "confirmDialogText"
            Layout.fillWidth: true
            text: root.text
            color: Theme.textSec
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }

        Text {
            objectName: "confirmDialogError"
            Layout.fillWidth: true
            visible: root.errorText.length > 0
            text: root.errorText
            color: Theme.redText
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 10

            Item { Layout.fillWidth: true }

            PillButton {
                id: cancelButton
                objectName: "confirmDialogCancel"
                text: qsTr("Cancel")
                accent: false
                enabled: !root.busy
                opacity: enabled ? 1 : 0.45
                Layout.preferredWidth:  implicitWidth
                Layout.preferredHeight: implicitHeight
                onClicked: root.close()
            }

            PillButton {
                objectName: "confirmDialogConfirm"
                text: root.busy ? root.busyLabel : root.confirmLabel
                danger: true
                enabled: !root.busy
                opacity: enabled ? 1 : 0.45
                Layout.preferredWidth:  implicitWidth
                Layout.preferredHeight: implicitHeight
                onClicked: root.confirm()
            }
        }
    }
}
