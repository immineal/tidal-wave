import QtQuick
import QtQuick.Shapes
import TidalWave

// A three-quarter ring that turns while something loads. Under reduced
// motion it stands still, which still reads as "working".
Item {
    id: ring
    objectName: "busyRing"

    property bool  running: false
    property color color: Theme.accent
    property real  thickness: 2.5
    // A test reads this; the Animator itself runs off the GUI thread.
    readonly property bool turning: spin.running

    implicitWidth: 24
    implicitHeight: 24

    Shape {
        anchors.fill: parent
        antialiasing: true
        ShapePath {
            fillColor: "transparent"
            strokeColor: ring.color
            strokeWidth: ring.thickness
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: ring.width / 2
                centerY: ring.height / 2
                radiusX: (ring.width - ring.thickness) / 2
                radiusY: (ring.height - ring.thickness) / 2
                startAngle: -90
                sweepAngle: 270
            }
        }
    }

    RotationAnimator {
        id: spin
        target: ring
        from: 0; to: 360
        duration: Theme.dur(Theme.motionSlow * 2)
        loops: Animation.Infinite
        running: ring.running && ring.visible && !Theme.reduceMotion
        onRunningChanged: if (!running) ring.rotation = 0
    }
}
