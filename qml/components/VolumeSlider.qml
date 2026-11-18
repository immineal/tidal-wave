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

    // Keyboard and screen reader steps. The value interface reads
    // value/from/to/stepSize; moved() still carries every change.
    property real from: 0
    property real to: 1
    property real stepSize: 0.05
    property real pageStep: 4 * stepSize
    // Drags land on a step too: the sleep timer counts whole minutes.
    property bool snapToStep: false
    property string accessibleName: qsTr("Volume")
    readonly property real fraction:
        to > from ? Math.max(0, Math.min(1, (value - from) / (to - from))) : 0
    function clamped(v) {
        if (snapToStep && stepSize > 0) v = from + Math.round((v - from) / stepSize) * stepSize
        return Math.max(from, Math.min(to, v))
    }
    function stepBy(d) { moved(clamped(value + d)) }

    activeFocusOnTab: true
    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Right: case Qt.Key_Up:   stepBy(stepSize); break
        case Qt.Key_Left:  case Qt.Key_Down: stepBy(-stepSize); break
        case Qt.Key_PageUp:   stepBy(pageStep); break
        case Qt.Key_PageDown: stepBy(-pageStep); break
        case Qt.Key_Home: moved(from); break
        case Qt.Key_End:  moved(to); break
        default: return
        }
        event.accepted = true
    }
    Accessible.role: Accessible.Slider
    Accessible.name: root.accessibleName
    Accessible.onIncreaseAction: stepBy(stepSize)
    Accessible.onDecreaseAction: stepBy(-stepSize)

    Rectangle {
        anchors.fill: parent
        anchors.margins: -Theme.space1
        radius: Math.min(width, height) / 2
        color: "transparent"
        border.width: root.activeFocus ? 2 : 0
        border.color: Theme.accent
    }

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
        radius: root.trackThickness / 2
        color: Theme.border

        // Fills up to the handle's centre, so the join shows no gap and no fill
        // past the knob. Upright it fills from the bottom: louder is higher.
        Rectangle {
            objectName: "volumeSliderFill"
            readonly property real extent: root.fraction * root.travel + root.handleR
            width:  root.upright ? parent.width : extent
            height: root.upright ? extent : parent.height
            y: root.upright ? parent.height - height : 0
            radius: parent.radius
            color: Theme.textSec
        }

        Rectangle {
            objectName: "volumeSliderHandle"
            x: root.upright ? (parent.width - root.handleSize) / 2
                            : root.fraction * root.travel
            y: root.upright ? (1 - root.fraction) * root.travel
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
            var f = Math.max(0, Math.min(1, root.upright ? 1 - raw : raw))
            return root.clamped(root.from + f * (root.to - root.from))
        }
        function axisOf(mouse) { return root.upright ? mouse.y : mouse.x }
        // A notch of the wheel is a step, as an arrow key is.
        property real pendingWheel: 0
        onWheel: (wheel) => {
            pendingWheel += wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
            var n = pendingWheel > 0 ? Math.floor(pendingWheel / 120) : Math.ceil(pendingWheel / 120)
            if (n === 0) return
            pendingWheel -= n * 120
            root.stepBy(n * root.stepSize)
        }
        onPressed: (mouse) => moved(valueAt(axisOf(mouse)))
        onPositionChanged: (mouse) => { if (pressed) moved(valueAt(axisOf(mouse))) }
        cursorShape: Qt.PointingHandCursor
    }
}
