import QtQuick
import QtQuick.Controls
import TidalWave

Item {
    id: root

    // ── which way it runs ────────────────────────────────────────────────
    // Horizontal by default; vertical is what the speaker reveals on hover.
    // One component with a mode, so the handle arithmetic below exists once
    // and tests/qml/tst_layout_player.qml measures it through one component.
    property int orientation: Qt.Horizontal
    readonly property bool upright: orientation === Qt.Vertical

    // Implicit, not a plain height: a Popup sizes itself from its content
    // item's implicit size and then forces the content to the result, so a
    // slider with no implicit height comes out nothing tall.
    implicitWidth:  upright ? 20  : 90
    implicitHeight: upright ? 110 : 20

    property real value: 0.7
    signal moved(real v)

    // The handle's centre travels between the two radii, not across the whole
    // track, so the handle never hangs outside the control at either end.
    readonly property real handleSize: 10
    readonly property real handleR: handleSize / 2
    readonly property real trackThickness: 3
    // The long axis, less the handle. Vertical asks the same question of the
    // height that horizontal asks of the width, and everything below is
    // written off this one number so the two modes cannot drift.
    readonly property real travel:
        Math.max(0, (upright ? root.height : root.width) - handleSize)

    // Arithmetic, not anchors: the two modes anchor to different edges, and
    // an anchor bound to `undefined` half the time reads worse than a ternary.
    Rectangle {
        id: track
        x: root.upright ? (root.width - root.trackThickness) / 2 : 0
        y: root.upright ? 0 : (root.height - root.trackThickness) / 2
        width:  root.upright ? root.trackThickness : root.width
        height: root.upright ? root.height : root.trackThickness
        radius: 2
        color: Theme.border

        // Fills up to the handle's centre, so the join shows no gap and no fill
        // past the knob. Upright it fills from the bottom: louder is higher.
        Rectangle {
            objectName: "volumeSliderFill"
            readonly property real extent: root.value * root.travel + root.handleR
            width:  root.upright ? parent.width : extent
            height: root.upright ? extent : parent.height
            y: root.upright ? parent.height - height : 0
            radius: parent.radius
            color: Theme.textSec
        }

        Rectangle {
            objectName: "volumeSliderHandle"
            x: root.upright ? (parent.width - root.handleSize) / 2
                            : root.value * root.travel
            y: root.upright ? (1 - root.value) * root.travel
                            : (parent.height - root.handleSize) / 2
            width: root.handleSize; height: root.handleSize
            radius: root.handleR
            color: Theme.textPrimary
        }
    }

    MouseArea {
        anchors.fill: parent
        preventStealing: true
        // Maps the pointer to the handle's centre, matching the travel above,
        // so a press lands the handle under the cursor and the clamp still
        // reaches 0 and 1. Upright, the axis is inverted as well as swapped.
        function valueAt(p) {
            var raw = (p - root.handleR) / Math.max(1, root.travel)
            return Math.max(0, Math.min(1, root.upright ? 1 - raw : raw))
        }
        function axisOf(mouse) { return root.upright ? mouse.y : mouse.x }
        onPressed: (mouse) => moved(valueAt(axisOf(mouse)))
        onPositionChanged: (mouse) => { if (pressed) moved(valueAt(axisOf(mouse))) }
        cursorShape: Qt.PointingHandCursor
    }
}
