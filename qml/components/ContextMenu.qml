import QtQuick
import QtQuick.Controls
import TidalWave

// The one context menu in the app. It has two faces: the track menu it started
// as, and the pin menu (P2) that sidebar rows, media cards and the four page
// hero headers open on a right-click. One menu rather than two so a right-click
// looks the same wherever it happens.
//
// The two queue actions sit above both faces, because a card, a hero and a
// track row are all things a user queues, and only this file should know what
// the labels say or which player call each one makes.
Menu {
    id: root
    property var trackData: null

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

    // ── the pin face (P1, P2) ────────────────────────────────────────────

    // What the menu is currently offering to pin, as PinStore wants it.
    property string pinKind: ""
    property string pinId: ""
    property string pinTitle: ""
    property string pinSubtitle: ""
    property string pinImageUrl: ""
    property bool   pinMode: false

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
        trackData   = null
        pinMode     = true
        pinKind     = kind  ? "" + kind : ""
        pinId       = id    ? "" + id   : ""
        pinTitle    = title    || ""
        pinSubtitle = subtitle || ""
        pinImageUrl = imageUrl || ""
        refreshPinned()
        if (!canPin) return
        popup(x, y)
    }

    // The track face, unchanged.
    function show(x, y, track) {
        pinMode = false
        trackData = track
        popup(x, y)
    }

    // So a right-click handler can skip the menu entirely, and so the tests
    // can read the label without walking a popup's contents.
    readonly property alias pinItem: pinEntry

    background: Rectangle {
        implicitWidth: 200
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusPopup
    }

    // A hidden MenuItem still contributes its height to the menu, so every
    // item that switches between the two faces zeroes its height too.

    // Both faces offer these, and they come first: queueing is what a
    // right-click on a tile or a hero is most often for, and of the two,
    // playing next is the commoner intent.
    MenuItem {
        id: playNextEntry
        objectName: "playNextMenuItem"
        visible: root.trackSource !== null
        height: visible ? implicitHeight : 0
        text: qsTr("Play next", "verb, play this right after the current track")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
        onTriggered: root.playNext()
    }
    MenuItem {
        id: addToQueueEntry
        objectName: "addToQueueMenuItem"
        visible: root.trackSource !== null
        height: visible ? implicitHeight : 0
        text: qsTr("Add to queue", "verb, put this at the end of the queue")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
        onTriggered: root.addToQueue()
    }
    MenuSeparator {
        visible: root.trackSource !== null
        height: visible ? implicitHeight : 0
        contentItem: Rectangle { height: 1; color: Theme.border }
    }

    MenuItem {
        id: pinEntry
        objectName: "pinMenuItem"
        visible: root.pinMode && root.canPin
        height: visible ? implicitHeight : 0
        text: root.pinned ? qsTr("Unpin", "verb, remove from the pinned block") : qsTr("Pin", "verb, pin to the sidebar")
        contentItem: Row {
            spacing: 8
            leftPadding: 16
            VectorIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.pinned ? "pin-filled" : "pin"
                color: Theme.textPrimary
                width: 14; height: 14
                strokeWidth: 1.6
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pinEntry.text
                color: Theme.textPrimary
                font.pixelSize: 14
            }
        }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
        onTriggered: {
            if (root.pinned) pins.unpin(root.pinKind, root.pinId)
            else             pins.pin(root.pinKind, root.pinId, root.pinTitle,
                                      root.pinSubtitle, root.pinImageUrl)
        }
    }

    MenuItem {
        visible: !root.pinMode
        height: visible ? implicitHeight : 0
        text: qsTr("Play", "verb, menu item")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuSeparator {
        visible: !root.pinMode
        height: visible ? implicitHeight : 0
        contentItem: Rectangle { height: 1; color: Theme.border }
    }
    MenuItem {
        visible: !root.pinMode
        height: visible ? implicitHeight : 0
        text: qsTr("Like", "verb, add to favourites")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuItem {
        visible: !root.pinMode
        height: visible ? implicitHeight : 0
        text: qsTr("Go to album")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuItem {
        visible: !root.pinMode
        height: visible ? implicitHeight : 0
        text: qsTr("Go to artist")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
}
