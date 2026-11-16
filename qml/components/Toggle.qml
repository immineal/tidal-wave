import QtQuick
import TidalWave

// The one on/off switch; Qt Quick Controls' Switch brings a style of its own.
// With `rainbow` set, a checked track is a static rainbow gradient with no
// animation, so nothing runs behind an open Popup.
Item {
    id: tg
    property bool checked: false
    property bool rainbow: false
    // What a screen reader calls the switch: the title beside it.
    property string label: ""
    // A row that takes the keyboard for the switch lights its ring here.
    property bool showFocus: activeFocus
    signal toggled()

    implicitWidth: 38
    implicitHeight: 22
    activeFocusOnTab: true
    Keys.onReturnPressed: tg.toggled()
    Keys.onSpacePressed:  tg.toggled()
    Accessible.role: Accessible.CheckBox
    Accessible.name: tg.label
    Accessible.checkable: true
    Accessible.checked: tg.checked
    Accessible.onPressAction: tg.toggled()
    Accessible.onToggleAction: tg.toggled()

    // Seven stops a sixth of the wheel apart, so the first and last share a
    // hue and the strip joins with no seam. Lightness 0.55, not 0.5: the
    // knob on top is white, and a darker yellow reads as a smudge under it.
    function rainbowStop(i) {
        return Qt.hsla(i / 6, 0.9, 0.55, 1)
    }

    Rectangle {
        id: track
        anchors.fill: parent
        radius: Theme.radiusFull
        color: tg.checked ? Theme.accent : Theme.surface
        // The rainbow carries no resting border: a thin solid ring around a
        // gradient reads as a frame bolted onto it. Focus still draws its
        // ring.
        readonly property bool showingRainbow: tg.rainbow && tg.checked
        border.width: tg.showFocus ? 2 : (showingRainbow ? 0 : 1)
        border.color: tg.showFocus ? Theme.accent
                    : tg.checked     ? Theme.accent : Theme.border

        // Inside the border rather than over it, so the focus ring is still
        // a ring and not a rainbow with a gap in it.
        Rectangle {
            objectName: "toggleRainbow"
            visible: tg.rainbow && tg.checked
            anchors.fill: parent
            anchors.margins: track.border.width
            radius: Theme.radiusFull
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0;       color: tg.rainbowStop(0) }
                GradientStop { position: 1 / 6;   color: tg.rainbowStop(1) }
                GradientStop { position: 2 / 6;   color: tg.rainbowStop(2) }
                GradientStop { position: 3 / 6;   color: tg.rainbowStop(3) }
                GradientStop { position: 4 / 6;   color: tg.rainbowStop(4) }
                GradientStop { position: 5 / 6;   color: tg.rainbowStop(5) }
                GradientStop { position: 1;       color: tg.rainbowStop(6) }
            }
        }

        Rectangle {
            width: parent.height - 6
            height: width
            radius: Theme.radiusFull
            y: 3
            x: tg.checked ? parent.width - width - 3 : 3
            color: tg.checked ? Theme.accentInk : Theme.textSec
            Behavior on x {
                NumberAnimation { duration: Theme.dur(Theme.motionFast); easing.type: Easing.OutCubic }
            }
        }
    }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
    TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: tg.toggled() }
}
