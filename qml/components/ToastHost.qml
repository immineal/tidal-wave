import QtQuick
import QtQuick.Layouts
import TidalWave

// Draws Toasts at the foot of the area it fills: a surface card with the
// message and its action. It takes no focus and blocks nothing but itself.
// The clock pauses while the pointer is on it, so Undo stays in reach.
Item {
    id: host
    objectName: "toastHost"

    // So a test can read what is drawn without walking the tree.
    readonly property alias card: card
    readonly property alias actionButton: actionButton

    // Counted in steps, so the hold can stay a binding: restart() on a
    // Timer would set `running` and drop it.
    property int shownFor: 0
    readonly property int step: 100
    Timer {
        interval: host.step
        repeat: true
        running: Toasts.shown && !cardHov.hovered && !actionButton.activeFocus
        onTriggered: {
            host.shownFor += host.step
            if (host.shownFor >= (Toasts.actionLabel.length > 0 ? Toasts.actionMs : Toasts.plainMs))
                Toasts.dismiss()
        }
    }
    Connections {
        target: Toasts
        function onSerialChanged() { host.shownFor = 0 }
    }

    Rectangle {
        id: card
        objectName: "toast"
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space6
        width: Math.min(row.implicitWidth + 2 * Theme.space4, host.width - 2 * Theme.space6)
        height: Math.max(44, row.implicitHeight + 2 * Theme.space2)
        radius: Theme.radiusLarge
        color: Theme.surfaceHigh
        border.color: Theme.border
        opacity: Toasts.shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.motionMedium) } }

        Accessible.role: Accessible.AlertMessage
        Accessible.name: Toasts.text

        HoverHandler { id: cardHov }

        RowLayout {
            id: row
            anchors.fill: parent
            anchors.leftMargin: Theme.space4
            anchors.rightMargin: Toasts.actionLabel.length > 0 ? Theme.space2 : Theme.space4
            spacing: Theme.space3

            Text {
                objectName: "toastText"
                Layout.fillWidth: true
                text: Toasts.text
                color: Theme.textPrimary
                font.pixelSize: Theme.fontBody
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            // Text in the accent, not a filled pill: the toast is a note, and
            // its one action should not shout over the page behind.
            Rectangle {
                id: actionButton
                objectName: "toastAction"
                visible: Toasts.actionLabel.length > 0
                Layout.preferredWidth: actionLabel.implicitWidth + 2 * Theme.space3
                Layout.preferredHeight: 32
                radius: Theme.radiusMedium
                color: actionHov.hovered ? Theme.hoverFill : "transparent"
                border.width: activeFocus ? 2 : 0
                border.color: Theme.accent
                activeFocusOnTab: visible
                Keys.onReturnPressed: Toasts.runAction()
                Keys.onEnterPressed:  Toasts.runAction()
                Keys.onSpacePressed:  Toasts.runAction()
                Accessible.role: Accessible.Button
                Accessible.name: Toasts.actionLabel
                Accessible.onPressAction: Toasts.runAction()

                Text {
                    id: actionLabel
                    anchors.centerIn: parent
                    text: Toasts.actionLabel
                    color: Theme.accentText
                    font.pixelSize: Theme.fontBody
                    font.bold: true
                }
                HoverHandler { id: actionHov; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: Toasts.runAction() }
            }
        }
    }
}
