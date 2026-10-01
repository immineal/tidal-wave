import QtQuick
import TidalWave

Item {
    property bool loading: false
    visible: loading

    anchors.fill: parent
    z: 100

    Rectangle { anchors.fill: parent; color: Theme.scrim }

    Rectangle {
        objectName: "loadingSpinner"
        anchors.centerIn: parent
        width: 48; height: 48; radius: 24
        color: Theme.surfaceHigh

        // A spinner says "still working", so reduced motion must not delete
        // it. One zero-length turn instead of endless ones parks the mark
        // back at the top and leaves a still dial on screen; the alternative,
        // a zero duration against Animation.Infinite, is a spin loop.
        RotationAnimator on rotation {
            from: 0; to: 360
            duration: Theme.dur(900)
            loops: Theme.reduceMotion ? 1 : Animation.Infinite
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
