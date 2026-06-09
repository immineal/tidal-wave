import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.surface
    border.color: Theme.border

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            height: 52
            color: "transparent"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                Text { text: "Queue"; color: Theme.textPrimary; font.pixelSize: 16; font.bold: true }
                Item { Layout.fillWidth: true }
                Text { text: player.queueCount + " tracks"; color: Theme.textSec; font.pixelSize: 12 }
                Item { width: 8 }
                Text {
                    text: "Clear"
                    color: clearHov.hovered ? Theme.textPrimary : Theme.textSec
                    font.pixelSize: 12
                    visible: player.queueCount > 0
                    HoverHandler { id: clearHov }
                    TapHandler { onTapped: player.clearQueue() }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        ListView {
            id: queueListView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: player.queueTracks
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: QueueDelegate {
                required property int     index
                required property var     modelData
                trackIndex: index
                track:      modelData
                width: queueListView.width
            }
        }
    }

    component QueueDelegate : Item {
        id: queueItem
        property int trackIndex: 0

        height: 52

        property bool isCurrent:  player.queueIndex === trackIndex
        property var  track:      null
        readonly property bool userQueued: track && track["_userQueued"] === true

        activeFocusOnTab: true
        Keys.onReturnPressed: player.jumpToQueue(trackIndex)
        Keys.onSpacePressed:  player.jumpToQueue(trackIndex)

        // Accent stripe for user-queued tracks
        Rectangle {
            visible: queueItem.userQueued && !queueItem.isCurrent
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 3; height: 28; radius: 2
            color: Theme.accent
            opacity: 0.7
        }

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            radius: 6
            color: isCurrent ? Qt.rgba(0, 0.698, 0.973, 0.08) : qHov.hovered ? Theme.surfaceHov : "transparent"
            border.width: queueItem.activeFocus ? 2 : 0
            border.color: Theme.accent

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 8
                spacing: 8

                // Up/Down reorder buttons
                Column {
                    spacing: 1
                    opacity: qHov.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    Repeater {
                        model: [{ glyph: "▲", delta: -1 }, { glyph: "▼", delta: 1 }]
                        Item {
                            required property var modelData
                            width: 18; height: 18
                            Text {
                                anchors.centerIn: parent
                                text: modelData.glyph
                                color: arrHov.hovered ? Theme.textPrimary : Theme.textDim
                                font.pixelSize: 9
                            }
                            HoverHandler { id: arrHov }
                            TapHandler {
                                onTapped: {
                                    var to = queueItem.trackIndex + modelData.delta
                                    if (to >= 0 && to < player.queueCount)
                                        player.moveQueueItem(queueItem.trackIndex, to)
                                }
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                        }
                    }
                }

                Rectangle {
                    width: 36
                    height: 36
                    radius: 4
                    color: Theme.surfaceHigh
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: track && track.coverUrl80 ? "image://tidal/" + track.coverUrl80 : ""
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        Layout.fillWidth: true
                        text: track ? track.title : ""
                        color: isCurrent ? Theme.accent : Theme.textPrimary
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: track ? track.artists : ""
                        color: Theme.textSec
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }

                // Remove button — visible on hover
                Item {
                    visible: qHov.hovered
                    width: 24; height: 24
                    VectorIcon {
                        anchors.centerIn: parent
                        name: "x"
                        color: removeHov.hovered ? Theme.textPrimary : Theme.textSec
                        width: 12; height: 12
                        strokeWidth: 2
                    }
                    HoverHandler { id: removeHov }
                    TapHandler {
                        onTapped: player.removeFromQueue(queueItem.trackIndex)
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                }
            }

            HoverHandler { id: qHov }
            TapHandler   { onDoubleTapped: player.jumpToQueue(trackIndex) }

            // Right-click context menu
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: queueContextMenu.popup()
            }
            Menu {
                id: queueContextMenu
                background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: 8; implicitWidth: 180 }
                MenuItem {
                    text: "Remove from queue"
                    contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                    onTriggered: player.removeFromQueue(queueItem.trackIndex)
                }
            }
        }
    }
}
