pragma Singleton
import QtQuick

// A track row carried out of its list: onto a playlist in the sidebar, into
// the queue, or to another place in its own playlist. The row starts and ends
// it; the targets are DropAreas with these keys, and read `tracks` on a drop.
QtObject {
    id: drag

    readonly property var keys: ["application/x-tidalwave-tracks"]

    // The track maps being carried, and the row they came from.
    property var tracks: []
    property Item source: null
    // Where the row lives, for a target that must not take its own: "queue".
    property string origin: ""
    readonly property bool active: source !== null
    readonly property int count: tracks.length

    // What the preview says: the title, or how many for more than one.
    readonly property string label: {
        if (count === 1) {
            var t = tracks[0] ? tracks[0].title : ""
            return (typeof t === "string" && t.length > 0) ? t : qsTranslate("TrackRow", "Unknown track")
        }
        // The queue heading's words, translated there already.
        return qsTranslate("QueuePanel", "%Ln track(s)", "", count)
    }

    // The pointer, in the window's coordinates.
    property point scenePos: Qt.point(0, 0)
    // The preview sits below and right of the pointer, clear of the cursor,
    // while the drop is aimed at the pointer itself.
    readonly property point previewOffset: Qt.point(14, 14)

    property Item preview: null
    property var _ended: null
    // Flipped to make the preview move by a hair, so a list that scrolled
    // under a still pointer hands the drop to the row now there.
    property bool _jiggle: false

    // Starts carrying `list` from `row`, the pointer at `at`. ended(landed)
    // is called once, on the drop or when Escape or a lost grab cancels it.
    function begin(row, list, at, ended, origin) {
        if (drag.active) drag.cancel()
        var win = row ? row.Window.window : null
        if (!win || !list || list.length === 0) return false
        drag.tracks = list
        drag.origin = origin || ""
        drag.source = row
        drag._ended = ended || null
        drag.preview = drag._previewC.createObject(win.contentItem)
        drag.move(at)
        drag.preview.Drag.active = true
        return true
    }

    function move(at) {
        drag.scenePos = at
        if (!drag.preview) return
        drag.preview.x = at.x + drag.previewOffset.x + (drag._jiggle ? 0.5 : 0)
        drag.preview.y = at.y + drag.previewOffset.y
    }

    // The pointer is where it was, but what lies under it moved.
    function refresh() {
        drag._jiggle = !drag._jiggle
        drag.move(drag.scenePos)
    }

    // Lets go where the pointer is. True when a target took the tracks.
    function drop() {
        if (!drag.preview) return false
        var action = drag.preview.Drag.drop()
        drag._finish(action !== Qt.IgnoreAction)
        return action !== Qt.IgnoreAction
    }

    function cancel() {
        if (!drag.preview) return
        drag.preview.Drag.cancel()
        drag._finish(false)
    }

    function _finish(landed) {
        var ended = drag._ended
        var p = drag.preview
        drag._ended = null
        drag.preview = null
        drag.source = null
        drag.origin = ""
        drag.tracks = []
        // Hidden at once: destroy() waits for the event loop to come round.
        if (p) { p.visible = false; p.destroy() }
        if (ended) ended(landed)
    }

    property Component _previewC: Component {
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

            Drag.keys: drag.keys
            Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
            Drag.proposedAction: Qt.CopyAction
            Drag.hotSpot: Qt.point(-drag.previewOffset.x, -drag.previewOffset.y)

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
                    text: drag.label
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
                onActivated: drag.cancel()
            }
        }
    }
}
