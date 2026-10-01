import QtQuick
import QtQuick.Controls
import TidalWave

Item {
    id: root
    height: 20
    property real value: 0.7
    signal moved(real v)

    // The handle's centre travels between the two radii rather than across the
    // whole track. It used to be `value * track.width - 5`, which put half the
    // handle outside the control at both ends - 5px past the right edge at full
    // volume, 5px before the left edge at zero. The player bar's volume slot
    // sets clip: true, so what the user saw at max volume was a handle sliced
    // down the middle. tst_layout_player.qml had even recorded the overhang as
    // "by design" and excluded it from its bounds check; it was not by design.
    readonly property real handleSize: 10
    readonly property real handleR: handleSize / 2
    readonly property real travel: Math.max(0, track.width - handleSize)

    Rectangle {
        id: track
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
        height: 3; radius: 2
        color: Theme.border

        // Fills up to the handle's centre, so the join never shows a gap or a
        // bar of fill sticking out past the knob at either end.
        Rectangle {
            objectName: "volumeSliderFill"
            width: root.value * root.travel + root.handleR
            height: parent.height; radius: parent.radius
            color: Theme.textSec
        }

        Rectangle {
            objectName: "volumeSliderHandle"
            x: root.value * root.travel
            anchors.verticalCenter: parent.verticalCenter
            width: root.handleSize; height: root.handleSize
            radius: root.handleR
            color: Theme.textPrimary
        }
    }

    MouseArea {
        anchors.fill: parent
        preventStealing: true
        // Maps the pointer to the handle's centre, matching the travel above:
        // pressing the extreme left or right still reaches 0 and 1 because of
        // the clamp, and a press lands the handle under the cursor rather than
        // half a handle-width away from it.
        function valueAt(x) {
            return Math.max(0, Math.min(1, (x - root.handleR)
                                            / Math.max(1, root.travel)))
        }
        onPressed: (mouse) => moved(valueAt(mouse.x))
        onPositionChanged: (mouse) => { if (pressed) moved(valueAt(mouse.x)) }
        cursorShape: Qt.PointingHandCursor
    }
}
