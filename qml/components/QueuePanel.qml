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
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: player.queueCount
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: QueueDelegate {
                required property int index
                trackIndex: index
                width: ListView.view.width
            }
        }
    }

    component QueueDelegate : Item {
        property int trackIndex: 0

        height: 52

        property bool isCurrent: player.queueIndex === trackIndex
        property var  track:     player.queueTrackAt(trackIndex)

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            radius: 6
            color: isCurrent ? Qt.rgba(0, 0.698, 0.973, 0.08) : qHov.hovered ? Theme.surfaceHov : "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 12

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
            }

            HoverHandler { id: qHov }
            TapHandler   { onDoubleTapped: player.jumpToQueue(trackIndex) }
        }
    }
}
