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

        // A spinner says "still working", so reduced motion must not delete
        // it. One zero-length turn instead of endless ones parks the mark
        // back at the top and leaves a still dial on screen; the alternative,
        // a zero duration against Animation.Infinite, is a spin loop.
        //
        // `target: dial` rather than `on rotation`, and `dial.visible` rather
        // than `parent.visible`. Inside an animation `parent` is not the item
        // the animation drives: as a property value source it was null, the
        // binding threw on every instantiation, and `running` stayed on the
        // `true` a value source starts itself with - an endless rotation
        // behind a hidden overlay, for the life of every page that has one.
        // Naming the animator is also what lets a test ask whether the dial
        // turns at all, because an animator writes to the scene graph and
        // leaves `rotation` alone for as long as it is running.
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
