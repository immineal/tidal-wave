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

    // The keyboard and a screen reader move it by the window's seek step.
    // The value interface reads value/from/to/stepSize, in seconds.
    property real stepMs: 10000
    readonly property real value: position / 1000
    readonly property real from: 0
    readonly property real to: duration / 1000
    readonly property real stepSize: stepMs / 1000

    function seekBy(ms) {
        if (duration > 0) seeked(Math.max(0, Math.min(duration, position + ms)))
    }

    activeFocusOnTab: true
    Keys.onPressed: (event) => {
        switch (event.key) {
        case Qt.Key_Right: case Qt.Key_Up:       seekBy(stepMs); break
        case Qt.Key_Left:  case Qt.Key_Down:     seekBy(-stepMs); break
        case Qt.Key_PageUp:                      seekBy(6 * stepMs); break
        case Qt.Key_PageDown:                    seekBy(-6 * stepMs); break
        case Qt.Key_Home: if (duration > 0) seeked(0); break
        case Qt.Key_End:  if (duration > 0) seeked(duration); break
        default: return
        }
        event.accepted = true
    }
    Accessible.role: Accessible.Slider
    Accessible.name: qsTr("Position in track", "slider, seeks in the playing track")
    Accessible.description: qsTr("%1 of %2", "elapsed of total time")
                                .arg(msToStr(position)).arg(msToStr(duration))
    Accessible.onIncreaseAction: seekBy(stepMs)
    Accessible.onDecreaseAction: seekBy(-stepMs)

    // Timestamps. Anchored, not in a Row whose middle child derives its width
    // from the Row: the positioning pass runs a frame behind a resize and puts
    // the duration label outside the bar for that frame.
    Text {
        id: elapsedLabel
        objectName: "seekBarElapsed"
        Component.onCompleted: Theme.tabularFigures(elapsedLabel)
        // As wide as the length: a track of an hour or more reads h:mm:ss.
        width: durationLabel.width
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: msToStr(_dragging ? _dragValue : position)
        color: Theme.textDim
        font.pixelSize: Theme.fontMicro
        horizontalAlignment: Text.AlignRight
    }

    Item {
        id: trackArea
        anchors.left: elapsedLabel.right
        anchors.right: durationLabel.left
        height: parent.height

        Rectangle {
            id: track
            anchors { left: parent.left; right: parent.right; leftMargin: Theme.space2; rightMargin: Theme.space2; verticalCenter: parent.verticalCenter }
            height: 3
            radius: height / 2
            color: Theme.border

            Rectangle {
                id: filled
                width: duration > 0
                       ? (_dragging ? (_dragValue / duration) : (position / duration)) * (track.width)
                       : 0
                height: parent.height
                radius: parent.radius
                color: hov.hovered || _dragging || root.activeFocus ? Theme.accent : Theme.textSec
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }
            }

            // Scrubber dot
            Rectangle {
                x: filled.width - width/2
                anchors.verticalCenter: parent.verticalCenter
                width:  hov.hovered || _dragging || root.activeFocus ? 12 : 0
                height: hov.hovered || _dragging || root.activeFocus ? 12 : 0
                radius: width / 2
                color: Theme.textPrimary
                Behavior on width  { NumberAnimation { duration: Theme.dur(Theme.motionFast) } }
                Behavior on height { NumberAnimation { duration: Theme.dur(Theme.motionFast) } }
            }
        }

        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }

        // The focus ring, round the bar rather than the timestamps.
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: "transparent"
            border.width: root.activeFocus ? 2 : 0
            border.color: Theme.accent
        }

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
        objectName: "seekBarTotal"
        Component.onCompleted: Theme.tabularFigures(durationLabel)
        width: Math.max(36, implicitWidth)
        anchors.right: parent.right
        anchors.rightMargin: Theme.space2
        anchors.verticalCenter: parent.verticalCenter
        text: msToStr(duration)
        color: Theme.textDim
        font.pixelSize: Theme.fontMicro
    }

    function msToStr(ms) { return Theme.clock(ms) }
}
