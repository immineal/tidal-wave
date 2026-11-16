import QtQuick
import TidalWave

// The one on/off switch; Qt Quick Controls' Switch brings a style of its own.
// With `rainbow` set, a checked track is a still picture of a glass rainbow,
// so nothing runs behind an open Popup.
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

    readonly property bool showingRainbow: rainbow && checked

    // tools/make-rainbow.py draws it at 1x, 2x and 3x, a picture because the
    // software renderer has no shaders. It reaches 4px past the track for the
    // glow, under the focus ring and the knob.
    Loader {
        active: tg.rainbow
        x: -4; y: -4
        width: tg.width + 8; height: tg.height + 8
        sourceComponent: Image {
            objectName: "toggleRainbow"
            visible: tg.showingRainbow
            source: "../../assets/toggle-rainbow.png"
            smooth: true
        }
    }

    Rectangle {
        id: track
        anchors.fill: parent
        radius: Theme.radiusFull
        // The picture paints its own soft edge, so no fill or resting border
        // may sit on it. Focus still draws its ring.
        color: tg.showingRainbow ? "transparent"
             : tg.checked ? Theme.accent : Theme.surface
        border.width: tg.showFocus ? 2 : (tg.showingRainbow ? 0 : 1)
        border.color: tg.showFocus ? Theme.accent
                    : tg.checked     ? Theme.accent : Theme.border

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
