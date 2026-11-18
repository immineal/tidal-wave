import QtQuick
import TidalWave

// The chip that follows the pointer while TrackDrag carries tracks. Kept out
// of the singleton, as ToastHost is out of Toasts: a root singleton that
// imports TidalWave makes a type cycle with Theme on Qt 6.4 to 6.7.
Rectangle {
    objectName: "trackDragPreview"
    // Over the page, the sidebar and the queue; under popups.
    z: 100000
    width: Math.min(280, previewRow.implicitWidth + 2 * Theme.space3)
    height: 32
    radius: Theme.radiusButton
    color: Theme.surfaceHigh
    border.width: 1
    border.color: Theme.accent
    opacity: 0.96

    Drag.keys: TrackDrag.keys
    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    Drag.proposedAction: Qt.CopyAction
    Drag.hotSpot: Qt.point(-TrackDrag.previewOffset.x, -TrackDrag.previewOffset.y)

    Row {
        id: previewRow
        x: Theme.space3
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space2
        VectorIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "track"
            width: 16; height: 16
            color: Theme.accentText
        }
        Text {
            objectName: "trackDragPreviewLabel"
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, 280 - 2 * Theme.space3 - 16 - Theme.space2)
            text: TrackDrag.label
            color: Theme.textPrimary
            font.pixelSize: Theme.fontMeta
            elide: Text.ElideRight
        }
    }

    // One Escape, the drag's: the window's own Escape stands down
    // while a drag is on (Main.qml).
    Shortcut {
        sequence: Shortcuts.sequence("escape")
        context: Qt.WindowShortcut
        onActivated: TrackDrag.cancel()
    }
}
