import QtQuick
import QtQuick.Controls
import TidalWave

Item {
    id: root

    // ── which way it runs ────────────────────────────────────────────────
    //
    // Horizontal is the shape this file started as and still the default, so
    // nothing that already instantiates it has to say anything. Vertical is
    // what the speaker reveals on hover, in both places the volume cluster
    // appears: "I want that hovered bar to be vertical not horizontal".
    //
    // One component with a mode rather than a second file, for one reason
    // that outweighs the `upright ?` ternaries below: the handle arithmetic
    // in this file is a bug fix - the knob used to hang half outside the
    // control at both ends, and the user met it sliced in two at max volume -
    // and a copy of it is a copy that the next fix lands on only half of.
    // tests/qml/tst_layout_player.qml measures that arithmetic through one
    // component; two files would need the cases written twice as well. It
    // also keeps CMakeLists.txt out of this, which matters while other work
    // is in that file.
    property int orientation: Qt.Horizontal
    readonly property bool upright: orientation === Qt.Vertical

    // Implicit and not a plain `height: 20`, which is what this carried
    // before. A Popup sizes itself from its content item's *implicit* size
    // and then forces the content to the result, so a slider with no implicit
    // height came out nothing tall and took its own hit area with it - which
    // is why PlayerBar's flyout used to have to restate both numbers at the
    // call site. An Item's height already falls back to its implicit height,
    // so every existing caller measures the same as it did.
    implicitWidth:  upright ? 20  : 90
    implicitHeight: upright ? 110 : 20

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
    readonly property real trackThickness: 3
    // The long axis, less the handle. Vertical asks the same question of the
    // height that horizontal asks of the width, and everything below is
    // written off this one number so the two modes cannot drift.
    readonly property real travel:
        Math.max(0, (upright ? root.height : root.width) - handleSize)

    // Arithmetic rather than anchors, because the two modes anchor to
    // different edges and an anchor bound to `undefined` half the time is a
    // worse thing to read than a ternary. The horizontal numbers are exactly
    // what `anchors { left; right; verticalCenter }` produced.
    Rectangle {
        id: track
        x: root.upright ? (root.width - root.trackThickness) / 2 : 0
        y: root.upright ? 0 : (root.height - root.trackThickness) / 2
        width:  root.upright ? root.trackThickness : root.width
        height: root.upright ? root.height : root.trackThickness
        radius: 2
        color: Theme.border

        // Fills up to the handle's centre, so the join never shows a gap or a
        // bar of fill sticking out past the knob at either end. Upright it
        // fills from the bottom: louder is higher, which is the only reading
        // a vertical volume control has ever had.
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
        // Maps the pointer to the handle's centre, matching the travel above:
        // pressing the extreme left or right still reaches 0 and 1 because of
        // the clamp, and a press lands the handle under the cursor rather than
        // half a handle-width away from it. Upright, the axis is inverted as
        // well as swapped - the top of the control is full volume.
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
