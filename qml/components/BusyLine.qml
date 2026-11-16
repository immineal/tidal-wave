import QtQuick
import TidalWave

// A calm "still working" mark: a short accent segment gliding along a thin
// track. Under reduced motion the segment stands still in the middle.
Item {
    id: line
    objectName: "busyLine"

    property bool running: false
    readonly property alias segment: seg
    readonly property alias slide: slideAnim

    implicitWidth: 120
    implicitHeight: 3

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.surfaceHigh
        clip: true

        Rectangle {
            id: seg
            objectName: "busySegment"
            width: Math.round(line.width / 3)
            height: parent.height
            radius: height / 2
            color: Theme.accent
            x: Math.round((line.width - width) / 2)

            // Not an Animator: x moves on the GUI thread, so a test can read it.
            SequentialAnimation on x {
                id: slideAnim
                objectName: "busySlide"
                running: line.running && line.visible && !Theme.reduceMotion
                loops: Animation.Infinite
                NumberAnimation {
                    from: -seg.width; to: line.width
                    duration: Theme.dur(Theme.motionSlow * 4)
                    easing.type: Easing.InOutSine
                }
                onRunningChanged: if (!running) seg.x = Math.round((line.width - seg.width) / 2)
            }
        }
    }
}
