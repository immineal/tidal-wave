import QtQuick
import TidalWave

Item {
    property bool loading: false
    visible: loading

    anchors.fill: parent
    z: 100

    Rectangle { anchors.fill: parent; color: Theme.scrim }

    Rectangle {
        id: dial
        objectName: "loadingSpinner"
        anchors.centerIn: parent
        width: 48; height: 48; radius: 24
        color: Theme.surfaceHigh

        // Under reduced motion one zero-length turn leaves a still dial; a zero
        // duration against Animation.Infinite would be a spin loop. `dial`, not
        // `parent`: inside an animation `parent` is not the driven item.
        RotationAnimator {
            objectName: "loadingSpinnerRotation"
            target: dial
            from: 0; to: 360
            duration: Theme.dur(900)
            loops: Theme.reduceMotion ? 1 : Animation.Infinite
            running: dial.visible
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
