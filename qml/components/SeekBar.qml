import QtQuick
import QtQuick.Controls
import TidalWave

Item {
    id: root
    height: 20

    property real position: 0   // ms
    property real duration: 0   // ms
    signal seeked(real ms)

    property bool _dragging: false
    property real _dragValue: 0

    // Timestamps
    Row {
        anchors.fill: parent
        spacing: 0

        Text {
            width: 36
            text: msToStr(_dragging ? _dragValue : position)
            color: Theme.textDim
            font.pixelSize: 11
            horizontalAlignment: Text.AlignRight
            anchors.verticalCenter: parent.verticalCenter
        }

        Item {
            id: trackArea
            width: parent.width - 80
            height: parent.height

            Rectangle {
                id: track
                anchors { left: parent.left; right: parent.right; leftMargin: 8; rightMargin: 8; verticalCenter: parent.verticalCenter }
                height: 3
                radius: 2
                color: Theme.border

                Rectangle {
                    id: filled
                    width: duration > 0
                           ? (_dragging ? (_dragValue / duration) : (position / duration)) * (track.width)
                           : 0
                    height: parent.height
                    radius: parent.radius
                    color: hov.hovered || _dragging ? Theme.accent : Theme.textSec
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                // Scrubber dot
                Rectangle {
                    x: filled.width - width/2
                    anchors.verticalCenter: parent.verticalCenter
                    width:  hov.hovered || _dragging ? 12 : 0
                    height: hov.hovered || _dragging ? 12 : 0
                    radius: 6
                    color: "white"
                    Behavior on width  { NumberAnimation { duration: 100 } }
                    Behavior on height { NumberAnimation { duration: 100 } }
                }
            }

            HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }

            MouseArea {
                anchors.fill: parent
                preventStealing: true
                onPressed: (mouse) => { _dragging = true; _dragValue = posFromX(mouseX) }
                onReleased: (mouse) => { _dragging = false; seeked(_dragValue) }
                onPositionChanged: (mouse) => { if (_dragging) _dragValue = posFromX(mouseX) }

                function posFromX(x) {
                    var r = (x - 8) / (width - 16)
                    return Math.max(0, Math.min(1, r)) * duration
                }
            }
        }

        Text {
            width: 36
            text: msToStr(duration)
            color: Theme.textDim
            font.pixelSize: 11
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    function msToStr(ms) {
        var s = Math.floor(ms / 1000)
        var m = Math.floor(s / 60)
        s = s % 60
        return m + ":" + (s < 10 ? "0" : "") + s
    }
}
