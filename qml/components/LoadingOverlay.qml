import QtQuick
import TidalWave

Item {
    property bool loading: false
    visible: loading

    anchors.fill: parent
    z: 100

    Rectangle { anchors.fill: parent; color: Qt.rgba(0,0,0,0.4) }

    Rectangle {
        anchors.centerIn: parent
        width: 48; height: 48; radius: 24
        color: Theme.surfaceHigh

        RotationAnimator on rotation {
            from: 0; to: 360
            duration: 900
            loops: Animation.Infinite
            running: parent.visible
        }

        Rectangle {
            width: 4; height: 16; radius: 2
            anchors.top: parent.top
            anchors.topMargin: 6
            anchors.horizontalCenter: parent.horizontalCenter
            color: Theme.accent
        }
    }
}
