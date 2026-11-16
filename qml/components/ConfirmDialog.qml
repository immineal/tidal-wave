import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// A question before something that cannot be taken back: a heading, a line
// of text, Cancel and one red button (accent with `danger` off). The host
// works on `confirmed` and closes it, or sets errorText and leaves it open.
Popup {
    id: root
    objectName: "confirmDialog"

    property string heading: ""
    property string text: ""
    property string confirmLabel: ""
    // The red button's label while `busy`.
    property string busyLabel: confirmLabel
    property bool   danger: true
    // A second answer between Cancel and the main one, outlined.
    property string altLabel: ""

    // A request is out: both buttons go quiet and nothing closes the dialog,
    // so the answer never lands on a dialog the user has left.
    property bool busy: false
    property string errorText: ""

    signal confirmed()
    signal altConfirmed()

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
    // Wider than 400 only when the answers need it, as three German ones do.
    width: Math.min(Math.max(400, answers.implicitWidth + leftPadding + rightPadding),
                    (parent ? parent.width : 400) - 48)
    modal: true
    // Dims the app behind, as the queue panel does. Fusion's own is faint.
    Overlay.modal: Rectangle { color: Theme.scrim }
    focus: true
    closePolicy: root.busy
                 ? Popup.NoAutoClose
                 : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
    padding: Theme.space5

    background: Rectangle {
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusLarge
    }

    // Cancel takes the focus: Return on a dialog that just opened keeps things.
    onOpened: cancelButton.forceActiveFocus()

    contentItem: ColumnLayout {
        spacing: Theme.space3

        Text {
            objectName: "confirmDialogHeading"
            Layout.fillWidth: true
            text: root.heading
            color: Theme.textPrimary
            font.pixelSize: Theme.fontTitle
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
            font.pixelSize: Theme.fontMeta
            wrapMode: Text.WordWrap
        }

        Text {
            objectName: "confirmDialogError"
            Layout.fillWidth: true
            visible: root.errorText.length > 0
            text: root.errorText
            color: Theme.redText
            font.pixelSize: Theme.fontMeta
            wrapMode: Text.WordWrap
        }

        RowLayout {
            id: answers
            Layout.fillWidth: true
            Layout.topMargin: Theme.spaceHalf
            spacing: Theme.space3

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
                objectName: "confirmDialogAlt"
                visible: root.altLabel.length > 0
                text: root.altLabel
                accent: false
                enabled: !root.busy
                opacity: enabled ? 1 : 0.45
                Layout.preferredWidth:  implicitWidth
                Layout.preferredHeight: implicitHeight
                onClicked: if (!root.busy) root.altConfirmed()
            }

            PillButton {
                objectName: "confirmDialogConfirm"
                text: root.busy ? root.busyLabel : root.confirmLabel
                danger: root.danger
                enabled: !root.busy
                opacity: enabled ? 1 : 0.45
                Layout.preferredWidth:  implicitWidth
                Layout.preferredHeight: implicitHeight
                onClicked: root.confirm()
            }
        }
    }
}
