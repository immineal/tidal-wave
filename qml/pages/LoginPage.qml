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
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 420)
        spacing: 0

        // Logo
        ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 12

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: 64
                height: 64
                radius: 16
                color: Theme.accent
                Text {
                    anchors.centerIn: parent
                    text: "≋"
                    color: "white"
                    font.pixelSize: 32
                    font.bold: true
                }
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "TIDAL WAVE"
                color: Theme.textPrimary
                font.pixelSize: 28
                font.bold: true
                font.letterSpacing: 3
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Native Linux Tidal Client"
                color: Theme.textSec
                font.pixelSize: 14
            }
        }

        Item { height: 48 }

        // Auth card
        Rectangle {
            Layout.fillWidth: true
            radius: Theme.radiusLg
            color: Theme.surface
            border.color: Theme.border
            border.width: 1
            height: auth.state === 0 ? (errorMessage.length > 0 ? 260 : 220) : auth.state === 1 ? 400 : 100
            Behavior on height { NumberAnimation { duration: 200 } }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 32
                spacing: 20

                // Initial state
                ColumnLayout {
                    visible: auth.state === 0
                    spacing: 16

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Sign in with your Tidal account"
                        color: Theme.textSec
                        font.pixelSize: 14
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: 48
                        radius: Theme.radius
                        color: Theme.accent
                        scale: loginHov.hovered ? 0.98 : 1
                        Behavior on scale { NumberAnimation { duration: 100 } }

                        Text {
                            anchors.centerIn: parent
                            text: "Log in with Tidal"
                            color: "white"
                            font.pixelSize: 15
                            font.bold: true
                        }
                        HoverHandler { id: loginHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler   { onTapped: auth.startDeviceFlow() }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Requires an active Tidal subscription"
                        color: Theme.textDim
                        font.pixelSize: 12
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.fillWidth: true
                        visible: errorMessage.length > 0
                        text: errorMessage
                        color: Theme.red
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                // Device flow pending
                ColumnLayout {
                    visible: auth.state === 1
                    spacing: 16

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Open your browser and go to:"
                        color: Theme.textSec
                        font.pixelSize: 14
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: 44
                        radius: Theme.radius
                        color: Theme.surfaceHigh
                        Text {
                            anchors.centerIn: parent
                            text: auth.verificationUrl || "tidal.com/link"
                            color: Theme.accent
                            font.pixelSize: 14
                            font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Qt.openUrlExternally(auth.verificationUrl)
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Enter this code:"
                        color: Theme.textSec
                        font.pixelSize: 14
                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        width: 200
                        height: 64
                        radius: Theme.radius
                        color: Theme.surfaceHigh
                        border.color: Theme.accent
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: auth.userCode || "…"
                            color: Theme.textPrimary
                            font.pixelSize: 28
                            font.bold: true
                            font.letterSpacing: 6
                        }
                    }

                    Row {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 6
                        Repeater {
                            model: 3
                            Rectangle {
                                required property int index
                                width: 6
                                height: 6
                                radius: 3
                                color: Theme.accent
                                opacity: 0.3
                                SequentialAnimation on opacity {
                                    loops: Animation.Infinite
                                    running: auth.state === 1
                                    PauseAnimation { duration: index * 200 }
                                    NumberAnimation { to: 1; duration: 400 }
                                    NumberAnimation { to: 0.3; duration: 400 }
                                }
                            }
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Waiting for you to log in…"
                        color: Theme.textDim
                        font.pixelSize: 13
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Cancel"
                        color: Theme.textSec
                        font.pixelSize: 13
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: auth.cancelDeviceFlow()
                        }
                    }
                }
            }
        }

        Item { height: 32 }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Tidal Wave is not affiliated with TIDAL Music AS"
            color: Theme.textDim
            font.pixelSize: 11
        }
    }
}
