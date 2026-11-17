import QtQuick
import QtQuick.Templates as T
import TidalWave

// Every plain ScrollBar in the app: the stock bar's size and fade, the handle
// coloured like Settings' own bar. The stock one took the platform palette,
// which ignores the app's theme.
T.ScrollBar {
    id: control

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             implicitContentHeight + topPadding + bottomPadding)

    padding: Theme.spaceHalf
    visible: control.policy !== T.ScrollBar.AlwaysOff
    minimumSize: orientation === Qt.Horizontal ? height / width : width / height

    contentItem: Rectangle {
        implicitWidth: control.interactive ? 6 : 2
        implicitHeight: control.interactive ? 6 : 2

        radius: width / 2
        color: control.pressed || control.hovered ? Theme.textSec : Theme.textDim
        opacity: 0.0

        states: State {
            name: "active"
            when: control.policy === T.ScrollBar.AlwaysOn || (control.active && control.size < 1.0)
            PropertyChanges { target: control.contentItem; opacity: 1.0 }
        }

        transitions: Transition {
            from: "active"
            SequentialAnimation {
                PauseAnimation { duration: Theme.dur(Theme.motionSlow) }
                NumberAnimation {
                    target: control.contentItem; property: "opacity"; to: 0.0
                    duration: Theme.dur(Theme.motionMedium)
                }
            }
        }
    }
}
