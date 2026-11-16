import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import TidalWave

Rectangle {
    color: Theme.bg

    property string errorMessage: ""

    Connections {
        target: auth
        function onLoginFailed(reason) { errorMessage = reason }
        function onStateChanged(s) { if (s === 1) errorMessage = "" }
    }

    ColumnLayout {
        id: pageColumn
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 420)
        spacing: 0

        // Logo
        ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.space3

            AppMark {
                Layout.alignment: Qt.AlignHCenter
                width: 64
                height: 64
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Tidal Wave"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontDisplay
                font.bold: true
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Native desktop client for Tidal")
                color: Theme.textSec
                font.pixelSize: Theme.fontBody
            }
        }

        Item { height: Theme.space12 }

        Rectangle {
            objectName: "loginAuthCard"
            Layout.fillWidth: true
            radius: Theme.radiusLarge
            color: Theme.surface
            border.color: Theme.border
            border.width: 1
            // As tall as what the state shows, so a long error or longer
            // translations never clip. Implicit: the page's layout sizes it.
            implicitHeight: Math.max(100, cardContent.implicitHeight + 64)
            Behavior on implicitHeight { NumberAnimation { duration: Theme.dur(Theme.motionMedium) } }

            // The error's wrapped height, from a width the layouts don't set:
            // a layout drops a height that changes while it lays out.
            Text {
                id: errorMeasure
                visible: false
                width: pageColumn.width - 64
                text: errorMessage
                font.pixelSize: Theme.fontMeta
                wrapMode: Text.WordWrap
            }

            ColumnLayout {
                id: cardContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.space8
                spacing: Theme.space5

                // Restoring session state
                ColumnLayout {
                    visible: auth.state === 0 && auth.hasSavedCredentials
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.space4

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Restoring session…")
                        color: Theme.textSec
                        font.pixelSize: Theme.fontBody
                    }

                    BusyLine {
                        Layout.alignment: Qt.AlignHCenter
                        running: auth.state === 0 && auth.hasSavedCredentials
                    }
                }

                // Initial state
                ColumnLayout {
                    visible: auth.state === 0 && !auth.hasSavedCredentials
                    spacing: Theme.space4

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Log in with your Tidal account")
                        color: Theme.textSec
                        font.pixelSize: Theme.fontBody
                    }

                    Rectangle {
                        id: loginBtn
                        Layout.fillWidth: true
                        height: 48
                        radius: Theme.radiusMedium
                        color: Theme.accent
                        border.width: activeFocus ? 2 : 0
                        border.color: Theme.textPrimary
                        scale: loginHov.hovered ? 0.98 : 1
                        Behavior on scale { NumberAnimation { duration: Theme.dur(Theme.motionFast) } }

                        activeFocusOnTab: true
                        Keys.onReturnPressed: auth.startDeviceFlow()
                        Keys.onSpacePressed:  auth.startDeviceFlow()
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Log in with Tidal")
                        Accessible.onPressAction: auth.startDeviceFlow()

                        Text {
                            anchors.centerIn: parent
                            text: qsTr("Log in with Tidal")
                            color: Theme.accentInk
                            font.pixelSize: Theme.fontBody
                            font.bold: true
                        }
                        HoverHandler { id: loginHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler   { onTapped: auth.startDeviceFlow() }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Requires an active Tidal subscription")
                        color: Theme.textDim
                        font.pixelSize: Theme.fontMeta
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.fillWidth: true
                        Layout.preferredHeight: errorMeasure.implicitHeight
                        visible: errorMessage.length > 0
                        text: errorMessage
                        color: Theme.redText
                        font.pixelSize: Theme.fontMeta
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                // Device flow pending
                ColumnLayout {
                    visible: auth.state === 1
                    spacing: Theme.space4

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Open your browser and go to:")
                        color: Theme.textSec
                        font.pixelSize: Theme.fontBody
                    }

                    Rectangle {
                        id: verificationLink
                        Layout.fillWidth: true
                        height: 44
                        radius: Theme.radiusMedium
                        color: Theme.surfaceHigh
                        border.width: activeFocus ? 2 : 0
                        border.color: Theme.accent
                        activeFocusOnTab: true
                        Keys.onReturnPressed: app.openUrl(auth.verificationUrl)
                        Keys.onSpacePressed:  app.openUrl(auth.verificationUrl)
                        Accessible.role: Accessible.Link
                        Accessible.name: auth.verificationUrl || "tidal.com/link"
                        Accessible.onPressAction: app.openUrl(auth.verificationUrl)
                        Text {
                            anchors.centerIn: parent
                            text: auth.verificationUrl || "tidal.com/link"
                            color: Theme.accentText
                            font.pixelSize: Theme.fontBody
                            font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: app.openUrl(auth.verificationUrl)
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Enter this code:")
                        color: Theme.textSec
                        font.pixelSize: Theme.fontBody
                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        // Sized off the code, so the border keeps clear of it
                        // however wide the code and the font set it.
                        Layout.preferredWidth: Math.max(200, Math.ceil(codeText.contentWidth) + 2 * Theme.space6)
                        Layout.preferredHeight: Math.max(64, Math.ceil(codeText.contentHeight) + 2 * Theme.space3)
                        radius: Theme.radiusLarge
                        color: Theme.surfaceHigh
                        border.color: Theme.accent
                        border.width: 1
                        // Selectable, so the code can be copied into the browser.
                        TextEdit {
                            id: codeText
                            objectName: "loginDeviceCode"
                            anchors.centerIn: parent
                            text: auth.userCode || "…"
                            readOnly: true
                            selectByMouse: true
                            selectionColor: Theme.accent
                            selectedTextColor: Theme.accentInk
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontDisplay
                            font.bold: true
                        }
                    }

                    BusyLine {
                        Layout.alignment: Qt.AlignHCenter
                        running: auth.state === 1
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Waiting for you to log in…")
                        color: Theme.textDim
                        font.pixelSize: Theme.fontMeta
                    }

                    Text {
                        id: cancelText
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Cancel")
                        color: cancelText.activeFocus ? Theme.accentText : Theme.textSec
                        font.pixelSize: Theme.fontMeta
                        font.underline: cancelText.activeFocus
                        activeFocusOnTab: true
                        Keys.onReturnPressed: auth.cancelDeviceFlow()
                        Keys.onSpacePressed:  auth.cancelDeviceFlow()
                        Accessible.role: Accessible.Button
                        Accessible.name: cancelText.text
                        Accessible.onPressAction: auth.cancelDeviceFlow()
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -Theme.space2
                            cursorShape: Qt.PointingHandCursor
                            onClicked: auth.cancelDeviceFlow()
                        }
                    }
                }
            }
        }

        Item { height: Theme.space8 }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Tidal Wave is not affiliated with TIDAL Music AS")
            color: Theme.textDim
            font.pixelSize: Theme.fontMicro
        }
    }
}
