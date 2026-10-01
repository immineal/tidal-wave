import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// The one context menu in the app. It is the pin menu (P2) that sidebar rows,
// media cards and the four page hero headers open on a right-click, with the
// two queue actions above it, because a card, a hero and a track row are all
// things a user queues, and only this file should know what the labels say or
// which player call each one makes.
//
// It also owns ContextMenu.Entry, the row every Menu in the app is built from
// (TrackRow, QueuePanel and CollectionPage all declare their own Menu but
// borrow the row), so there is exactly one answer to what a menu entry looks
// like, how wide it is allowed to get and which entries carry a mark.
Menu {
    id: root

    // ── what a menu entry looks like, once ───────────────────────────────
    //
    // Which entries get an icon: only the ones that take something away.
    //
    // The audit question was whether a mark tells you anything the label does
    // not. Next to "Play now", "Download", "Copy link" or "Go to artist" it
    // does not -- it draws the word again -- and a column of five thin
    // 16px marks turns into texture, which is exactly what stops people
    // reading the labels. The destructive entry is the one row where a
    // misclick costs you something, so it is the one row worth catching the
    // eye before the eye reaches the word. It already turns red; the bin is
    // the redundant encoding of that, for anyone the red does not reach.
    //
    // Entries that merely navigate do not qualify: "Go to album" says it, and
    // the separator above it already groups them.
    component Entry : MenuItem {
        id: entry

        // An icon *name* out of VectorIcon's set, not a character. Not called
        // `icon`: AbstractButton already has an `icon` group property.
        property string iconName: ""
        // Destructive. Tints the label and the mark, and is the only thing
        // that puts a mark on a row at all.
        property bool danger: false

        leftPadding: 12
        rightPadding: 12

        // The gutter is reserved on every row of a menu that has any mark in
        // it, so its labels start on one pixel instead of stepping in and out
        // around the marked row -- and on none of the rows of a menu that has
        // no mark, so an all-text menu is not mysteriously indented. The menu
        // answers that, not the row, which is why this walks its siblings.
        readonly property bool showsGutter: {
            var m = entry.menu
            if (!m) return entry.iconName !== ""
            for (var i = 0; i < m.count; ++i) {
                var it = m.itemAt(i)
                if (it && it.visible && it.iconName !== undefined && it.iconName !== "")
                    return true
            }
            return false
        }

        readonly property color ink: !entry.enabled ? Theme.textDim
                                   : entry.danger   ? Theme.red
                                                    : Theme.textPrimary

        contentItem: RowLayout {
            spacing: entry.showsGutter ? 10 : 0
            Item {
                Layout.preferredWidth:  entry.showsGutter ? 16 : 0
                Layout.preferredHeight: 16
                Layout.alignment: Qt.AlignVCenter
                VectorIcon {
                    anchors.fill: parent
                    visible: entry.iconName !== ""
                    name: entry.iconName
                    color: entry.ink
                    strokeWidth: 1.6
                }
            }
            Text {
                Layout.fillWidth: true
                text: entry.text
                color: entry.ink
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
                // The other half of Theme.menuWidth: past the maximum the
                // label gives way instead of the menu growing off-screen.
                // Its implicitWidth is still the full label, which is what
                // the menu measures, so eliding here cannot feed back.
                elide: Text.ElideRight
            }
        }
        background: Rectangle { color: entry.highlighted ? Theme.surfaceHov : "transparent" }
    }

    // ── queueing ───────────────────────────────────────────────────────
    //
    // What the two queue items act on, as a function rather than a list: a
    // tile and a hero both stand for a whole album or playlist whose tracks
    // may not have been fetched yet, and the point of these actions is that
    // they queue all of them and not the handful a page happens to be
    // showing. The host is handed a callback and answers when it can; it
    // answers never if the fetch fails, which is why nothing below assumes
    // the callback runs. A host with nothing to queue leaves it null and is
    // offered neither action.
    property var trackSource: null

    // The item the confirmation is drawn over. It draws *above* whatever it
    // is given, so a host passes the part of itself that has room above it:
    // a card passes itself, a page passes its hero's action row. Falls back
    // to the item the menu pops up on.
    property Item confirmAnchor: null

    // How long the confirmation stays readable. Not Theme.dur(): it is a
    // dwell time, not an animation, and dur() collapses to 0 under reduced
    // motion, which ToolTip reads as "never time out".
    readonly property int confirmMs: 2000

    // So a test can read the labels without walking a popup's contents.
    readonly property alias playNextItem:   playNextEntry
    readonly property alias addToQueueItem: addToQueueEntry

    function playNext()   { _queue(true) }
    function addToQueue() { _queue(false) }

    function _queue(atFront) {
        if (!root.trackSource) return
        root.trackSource(function (tracks) {
            if (!tracks || tracks.length === 0) return
            if (atFront) player.playNext(tracks)
            else         player.addToQueue(tracks)
            root._confirm(tracks.length, atFront)
        })
    }

    // Queueing used to be silent, so the only way to tell it had worked was
    // to open the queue - and the cheaper guess was to click again, which
    // queued the thing twice. The app's own tool tip says so instead: it
    // takes no focus, blocks nothing, and times out by itself.
    function _confirm(n, atFront) {
        var at = root.confirmAnchor || root.parent
        if (!at) return
        at.ToolTip.show(atFront ? qsTr("%n track(s) added to play next", "queue confirmation", n)
                                : qsTr("%n track(s) added to queue", "queue confirmation", n),
                        root.confirmMs)
    }

    // Drawn inside the window rather than as a native or a separate-window
    // popup: the menu is fully custom-styled below, and a native menu would
    // ignore every bit of that.
    popupType: Popup.Item

    // Sized to its longest item; see Theme.menuWidth for why a styled Menu
    // does not do that by itself.
    implicitWidth: Theme.menuWidth(root)

    // Qt keeps a menu inside its window by itself, but it is allowed to hang
    // `overlap` pixels past the edge while doing it (the Basic style asks for
    // 1, for submenus to sit on their parent). This menu has no submenus and
    // would rather not stick out at all.
    overlap: 0

    // ── the pin face (P1, P2) ────────────────────────────────────────────

    // What the menu is currently offering to pin, as PinStore wants it.
    property string pinKind: ""
    property string pinId: ""
    property string pinTitle: ""
    property string pinSubtitle: ""
    property string pinImageUrl: ""

    // PinStore::isValidKind is the authority on what can be pinned; it is a
    // static rather than an invokable, so the four kinds are repeated here.
    // Asking first means a song gets no Pin item at all, instead of one that
    // calls into PinStore for a row PinStore would silently drop.
    readonly property bool canPin: pinId.length > 0
        && (pinKind === "album" || pinKind === "playlist"
            || pinKind === "artist" || pinKind === "mix")

    // The label has to say what the click will do, so it follows the store
    // rather than whatever was true when the menu was last opened: the same
    // item can be pinned from a page while this menu sits on a sidebar row.
    property bool pinned: false
    function refreshPinned() {
        pinned = canPin && pins.isPinned(pinKind, pinId)
    }
    Connections {
        target: pins
        function onChanged() { root.refreshPinned() }
    }

    // Opens the menu on one pinnable thing. Nothing pinnable, nothing to show.
    function showPin(x, y, kind, id, title, subtitle, imageUrl) {
        pinKind     = kind  ? "" + kind : ""
        pinId       = id    ? "" + id   : ""
        pinTitle    = title    || ""
        pinSubtitle = subtitle || ""
        pinImageUrl = imageUrl || ""
        refreshPinned()
        if (!canPin) return
        popup(x, y)
    }

    // So a right-click handler can skip the menu entirely, and so the tests
    // can read the label without walking a popup's contents.
    readonly property alias pinItem: pinEntry

    background: Rectangle {
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusPopup
    }

    // A hidden MenuItem still contributes its height to the menu, so every
    // item that can be absent zeroes its height too.

    // Queueing comes first: it is what a right-click on a tile or a hero is
    // most often for, and of the two, playing next is the commoner intent.
    Entry {
        id: playNextEntry
        objectName: "playNextMenuItem"
        visible: root.trackSource !== null
        height: visible ? implicitHeight : 0
        text: qsTr("Play next", "verb, play this right after the current track")
        onTriggered: root.playNext()
    }
    Entry {
        id: addToQueueEntry
        objectName: "addToQueueMenuItem"
        visible: root.trackSource !== null
        height: visible ? implicitHeight : 0
        text: qsTr("Add to queue", "verb, put this at the end of the queue")
        onTriggered: root.addToQueue()
    }
    MenuSeparator {
        visible: root.trackSource !== null && root.canPin
        height: visible ? implicitHeight : 0
        contentItem: Rectangle { height: 1; color: Theme.border }
    }

    Entry {
        id: pinEntry
        objectName: "pinMenuItem"
        visible: root.canPin
        height: visible ? implicitHeight : 0
        // No mark. The pin/pin-filled pair that used to sit here said the
        // same thing as the label flipping between Pin and Unpin, and it was
        // the only mark in an otherwise plain menu.
        text: root.pinned ? qsTr("Unpin", "verb, remove from the pinned block") : qsTr("Pin", "verb, pin to the sidebar")
        onTriggered: {
            if (root.pinned) pins.unpin(root.pinKind, root.pinId)
            else             pins.pin(root.pinKind, root.pinId, root.pinTitle,
                                      root.pinSubtitle, root.pinImageUrl)
        }
    }
}
