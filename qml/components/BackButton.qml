import QtQuick
import QtQuick.Window
import TidalWave

// The way back from a detail page: a backed IconButton, since it sits over a
// hero tint or an artist's photo. DetailBar carries it on every detail page.
IconButton {
    id: root
    icon: "chevron-left"
    backed: true
    pad: Theme.space5
    iconColor: Theme.textPrimary
    label: qsTr("Back", "button, returns to the previous page")
    z: 100
    // `Window.window` qualified through root: read from a handler, which is
    // not an Item, it resolves to null.
    onClicked: root.Window.window.goBack()
}
