import QtQuick
import TidalWave

// A wheel notch moves a long list by the system's lines per notch, as
// Settings does, instead of Flickable's flick, which covers about one row a
// notch and less when spun fast. A touchpad's pixel delta is taken as it is.
// Declared inside the Flickable it scrolls.
WheelHandler {
    id: step
    property Flickable view: null
    readonly property real notch: Qt.styleHints.wheelScrollLines * Theme.wheelLine

    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: (event) => {
        var f = step.view
        if (!f) { event.accepted = false; return }
        var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y
                                          : event.angleDelta.y / 120 * step.notch
        if (dy === 0) { event.accepted = false; return }
        var top = f.originY - f.topMargin
        var end = f.originY + Math.max(0, f.contentHeight + f.bottomMargin - f.height)
        f.contentY = Math.max(top, Math.min(end, f.contentY - dy))
    }
}
