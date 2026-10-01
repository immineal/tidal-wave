import QtQuick
import QtQuick.Controls
import TidalWave

// The one context menu in the app. It has two faces: the track menu it started
// as, and the pin menu (P2) that sidebar rows, media cards and the four page
// hero headers open on a right-click. One menu rather than two so a right-click
// looks the same wherever it happens.
Menu {
    id: root
    property var trackData: null

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
    MenuItem {
        id: pinEntry
        objectName: "pinMenuItem"
        visible: root.pinMode && root.canPin
        height: visible ? implicitHeight : 0
        text: root.pinned ? qsTr("Unpin") : qsTr("Pin", "verb, pin to the sidebar")
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
    MenuItem {
        visible: !root.pinMode
        height: visible ? implicitHeight : 0
        text: qsTr("Add to queue")
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
