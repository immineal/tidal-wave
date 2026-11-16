import QtQuick
import TidalWave

// The one on/off switch; Qt Quick Controls' Switch brings a style of its own.
Item {
    id: tg
    property bool checked: false
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

    Rectangle {
        id: track
        anchors.fill: parent
        radius: Theme.radiusFull
        color: tg.checked ? Theme.accent : Theme.surface
        border.width: tg.showFocus ? 2 : 1
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
