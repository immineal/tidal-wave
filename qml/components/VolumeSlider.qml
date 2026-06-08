import QtQuick
import QtQuick.Controls
import TidalWave

Item {
    id: root
    height: 20
    property real value: 0.7
    signal moved(real v)

    Rectangle {
        id: track
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
        height: 3; radius: 2
        color: Theme.border

        Rectangle {
            width: root.value * track.width
            height: parent.height; radius: parent.radius
            color: Theme.textSec
        }

        Rectangle {
            x: root.value * track.width - 5
            anchors.verticalCenter: parent.verticalCenter
            width: 10; height: 10; radius: 5
            color: "white"
        }
    }

    MouseArea {
        anchors.fill: parent
        preventStealing: true
        onPressed: (mouse) => moved(Math.max(0, Math.min(1, mouse.x / width)))
        onPositionChanged: (mouse) => {
            if (pressed) {
                moved(Math.max(0, Math.min(1, mouse.x / width)))
            }
        }
        cursorShape: Qt.PointingHandCursor
    }
}
