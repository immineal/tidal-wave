import QtQuick
import QtQuick.Controls
import TidalWave

Item {
    id: root
    height: 20

    property real position: 0   // ms
    property real duration: 0   // ms
    signal seeked(real ms)

    property bool _dragging: false
    property real _dragValue: 0

    // Timestamps.
    //
    // Anchored, not a Row. The three of them sat in a `Row { spacing: 0 }` with
    // the middle one `width: parent.width - 80`, which is a positioner placing
    // children whose width is derived from the positioner's own width. The two
    // do not update together: when the bar is resized, the Row runs its
    // positioning pass against the width trackArea still has from the frame
    // before, so the right-hand timestamp is placed off the old width while the
    // Row already has the new one. Resting that is invisible, because nothing
    // moves. Across the Now Playing breakpoint it is not: the bar loses 484px
    // of width over 170ms and OutCubic spends a quarter of it on the first
    // frame, so the duration label was drawn 116px outside the bar for that
    // frame, well past the edge of the text column it sits in.
    //
    // Anchors have no such pass: the label hangs off the parent's right edge, so
    // it arrives with the new width rather than one frame after it. The resting
    // geometry is the one the Row gave - 0..36 for the elapsed time, 36..w-44
    // for the track, w-44..w-8 for the duration.
    Text {
        id: elapsedLabel
        width: 36
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: msToStr(_dragging ? _dragValue : position)
        color: Theme.textDim
        font.pixelSize: 11
        horizontalAlignment: Text.AlignRight
    }

    Item {
        id: trackArea
        anchors.left: elapsedLabel.right
        anchors.right: durationLabel.left
        height: parent.height

        Rectangle {
            id: track
            anchors { left: parent.left; right: parent.right; leftMargin: 8; rightMargin: 8; verticalCenter: parent.verticalCenter }
            height: 3
            radius: 2
            color: Theme.border

            Rectangle {
                id: filled
                width: duration > 0
                       ? (_dragging ? (_dragValue / duration) : (position / duration)) * (track.width)
                       : 0
                height: parent.height
                radius: parent.radius
                color: hov.hovered || _dragging ? Theme.accent : Theme.textSec
                Behavior on color { ColorAnimation { duration: Theme.dur(120) } }
            }

            // Scrubber dot
            Rectangle {
                x: filled.width - width/2
                anchors.verticalCenter: parent.verticalCenter
                width:  hov.hovered || _dragging ? 12 : 0
                height: hov.hovered || _dragging ? 12 : 0
                radius: 6
                color: Theme.textPrimary
                Behavior on width  { NumberAnimation { duration: Theme.dur(100) } }
                Behavior on height { NumberAnimation { duration: Theme.dur(100) } }
            }
        }

        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }

        MouseArea {
            anchors.fill: parent
            preventStealing: true
            onPressed: (mouse) => { _dragging = true; _dragValue = posFromX(mouse.x) }
            onReleased: (mouse) => { _dragging = false; seeked(_dragValue) }
            onPositionChanged: (mouse) => { if (_dragging) _dragValue = posFromX(mouse.x) }

            function posFromX(x) {
                var r = (x - 8) / (width - 16)
                return Math.max(0, Math.min(1, r)) * duration
            }
        }
    }

    Text {
        id: durationLabel
        width: 36
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: msToStr(duration)
        color: Theme.textDim
        font.pixelSize: 11
    }

    function msToStr(ms) {
        var s = Math.floor(ms / 1000)
        var m = Math.floor(s / 60)
        s = s % 60
        return m + ":" + (s < 10 ? "0" : "") + s
    }
}
