import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// The one context menu in the app: the pin menu that sidebar rows, media
// cards and the page hero headers open on a right-click, with the two queue
// actions above it and Copy link under Pin. Only this file knows the labels and the player calls.
// It also owns ContextMenu.Entry, the row every Menu in the app is built
// from, and the fades and FavoriteAction that other hosts borrow.
Menu {
    id: root

    // ── how a menu arrives and leaves, once ─────────────────────────────
    // Opacity and nothing else. Qt 6.4 has a Popup/Layout polish loop when a
    // popup's geometry feeds back into its contents, and animating height,
    // scale or y would hand the positioner a moving target.
    component OpenFade : Transition {
        NumberAnimation {
            property: "opacity"
            from: 0; to: 1
            duration: Theme.dur(Theme.motionFast)
            easing.type: Easing.OutCubic
        }
    }
    component CloseFade : Transition {
        NumberAnimation {
            property: "opacity"
            from: 1; to: 0
            duration: Theme.dur(Theme.motionFast)
            easing.type: Easing.InCubic
        }
    }

    enter: OpenFade { }
    exit:  CloseFade { }

    // ── what a menu entry looks like, once ───────────────────────────────
    // Every entry carries an icon.
    component Entry : MenuItem {
        id: entry

        // An icon *name* out of VectorIcon's set, not a character. Not called
        // `icon`: AbstractButton already has an `icon` group property.
        property string iconName: ""
        // Destructive. Tints the label and the icon red.
        property bool danger: false

        leftPadding: Theme.space3
        rightPadding: Theme.space3

        // The menu decides the gutter: every row reserves it when any row has
        // an icon, so the labels line up. Its own icon is asked first because
        // menu.count is 0 while the menu is still being built.
        readonly property bool showsGutter: {
            if (entry.iconName !== "") return true
            var m = entry.menu
            if (!m) return false
            for (var i = 0; i < m.count; ++i) {
                var it = m.itemAt(i)
                if (it && it.visible && it.iconName !== undefined && it.iconName !== "")
                    return true
            }
            return false
        }

        readonly property color ink: !entry.enabled ? Theme.textDim
                                   : entry.danger   ? Theme.redText
                                                    : Theme.textPrimary

        contentItem: RowLayout {
            spacing: entry.showsGutter ? Theme.space2 : 0
            Item {
                Layout.preferredWidth:  entry.showsGutter ? 16 : 0
                Layout.preferredHeight: 16
                Layout.alignment: Qt.AlignVCenter
                VectorIcon {
                    anchors.fill: parent
                    visible: entry.iconName !== ""
                    name: entry.iconName
                    color: entry.ink
                }
            }
            Text {
                Layout.fillWidth: true
                text: entry.text
                color: entry.ink
                font.pixelSize: Theme.fontMeta
                verticalAlignment: Text.AlignVCenter
                // Past Theme.menuWidth's maximum the label elides. Its
                // implicitWidth is still the full label, which is what the menu
                // measures, so eliding here cannot feed back.
                elide: Text.ElideRight
            }
        }
        background: Rectangle {
            radius: Theme.radiusMedium
            color: entry.highlighted ? Theme.hoverFill : "transparent"
        }
    }

    // ── a rule between groups of entries ─────────────────────────────────
    // A hidden MenuSeparator still adds its height, so `shown` zeroes it.
    component Separator : MenuSeparator {
        property bool shown: true
        visible: shown
        height: shown ? implicitHeight : 0
        topPadding: Theme.space1
        bottomPadding: Theme.space1
        contentItem: Rectangle { implicitHeight: 1; color: Theme.border }
    }

    // ── queueing ───────────────────────────────────────────────────────
    // What the two queue items act on, as a function, because a tile or a hero
    // stands for a whole album or playlist whose tracks may not be fetched
    // yet. The callback may never run. Null offers neither action.
    property var trackSource: null

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

    // Says the queueing worked, so nobody clicks again and queues it twice.
    function _confirm(n, atFront) {
        Toasts.show(atFront ? qsTr("%Ln track(s) added to play next", "queue confirmation", n)
                            : qsTr("%Ln track(s) added to queue", "queue confirmation", n))
    }

    // ── a favourite the server can refuse ────────────────────────────────
    // The favourite call. It writes no state: the hearts read back through
    // the bridge, which changes its caches only on a yes. Edits says what
    // happened once Tidal shows it, with Undo.
    component FavoriteAction : QtObject {
        id: fav

        // What the last refusal said, or "" when the reply was a yes, so a
        // test can read it. Cleared when a call goes out.
        property string lastMessage: ""

        // The bool is the state now, which the press undoes. `anchor` is kept
        // for the callers. The write, its read-back, the notice and Undo are
        // Edits'; this keeps what a refusal said, for the tests.
        function toggleTrack(trackId, liked, anchor) {
            if (!(trackId > 0)) return
            fav._send("track", trackId, !liked)
        }

        function toggleAlbum(albumId, saved, anchor) {
            if (!(albumId > 0)) return
            fav._send("album", albumId, !saved)
        }

        function toggleArtist(artistId, following, anchor) {
            if (!(artistId > 0)) return
            fav._send("artist", artistId, !following)
        }

        // A mix id is a string of hex characters, so the guard is on length:
        // Number(id) > 0 is false for a real id. A track radio is a mix to
        // Tidal and to this call, so the words name the mix even on a page
        // whose heading reads "Radio".
        function toggleMix(mixId, saved, anchor) {
            if (!mixId || String(mixId).length === 0) return
            fav._send("mix", mixId, !saved)
        }

        function _send(kind, id, on) {
            fav.lastMessage = ""
            Edits.setFavorite(kind, id, on, function (ok, message) {
                if (ok !== true) fav.lastMessage = message
            })
        }

        // Only an explicit true counts as accepted. A reply that never arrived
        // leaves the argument undefined, and that must not read as success.
        function _refused(ok, message) {
            if (ok === true) return true
            fav.lastMessage = message
            Toasts.show(message)
            return false
        }
    }

    // Insets reset, not inherited. A style sets them for its drop shadow (the
    // native macOS style uses -32), and this menu draws its own background,
    // so inherited insets lay the panel out past the popup and clip entries.
    leftInset: 0; rightInset: 0; topInset: 0; bottomInset: 0

    // popupType and Popup.Item are Qt 6.8. Declared, the property makes this
    // type and every type using it unavailable on older Qt, so it is assigned
    // where it exists. `this.` matters: a bare unknown name throws.
    Component.onCompleted: {
        if (this.popupType !== undefined) this.popupType = Popup.Item
    }

    // Sized to its longest item; see Theme.menuWidth for why a styled Menu
    // does not do that by itself.
    implicitWidth: Theme.menuWidth(root)

    // Qt may let a menu hang `overlap` pixels past the window edge (Basic asks
    // for 1, for submenus). This menu has no submenus.
    overlap: 0
    padding: Theme.menuPadding

    // ── the pin face ─────────────────────────────────────────────────────

    // What the menu is currently offering to pin, as PinStore wants it.
    property string pinKind: ""
    property string pinId: ""
    property string pinTitle: ""
    property string pinSubtitle: ""
    property string pinImageUrl: ""

    // PinStore::isValidKind is the authority on what can be pinned. It is a
    // static, not an invokable, so the four kinds are repeated here. A kind
    // that fails gets no Pin item at all.
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

    // ── taking it away ───────────────────────────────────────────────────
    // The destructive entry. The host supplies the wording, because only it
    // knows what removing means. Empty means the row is not there.
    property string removeLabel: ""
    signal removeRequested()

    // Opens the menu on one thing. Nothing to offer, nothing to show.
    function showPin(x, y, kind, id, title, subtitle, imageUrl) {
        pinKind     = kind  ? "" + kind : ""
        pinId       = id    ? "" + id   : ""
        pinTitle    = title    || ""
        pinSubtitle = subtitle || ""
        pinImageUrl = imageUrl || ""
        refreshPinned()
        if (!canPin && trackSource === null && removeLabel.length === 0) return
        popup(x, y)
    }

    // So a right-click handler can skip the menu entirely, and so the tests
    // can read the label without walking a popup's contents.
    readonly property alias pinItem:      pinEntry
    readonly property alias copyLinkItem: copyLinkEntry
    readonly property alias removeItem:   removeEntry

    // The web link of what the menu is on, the short form TrackRow copies for
    // a track. Every kind that can be pinned has one.
    readonly property string linkUrl: canPin ? "https://tidal.com/" + pinKind + "/" + pinId : ""

    function copyLink() {
        if (root.linkUrl.length === 0) return
        bridge.copyToClipboard(root.linkUrl)
        Toasts.show(qsTr("Link copied"))
    }

    background: Rectangle {
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusLarge
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
        iconName: "next"
        onTriggered: root.playNext()
    }
    Entry {
        id: addToQueueEntry
        objectName: "addToQueueMenuItem"
        visible: root.trackSource !== null
        height: visible ? implicitHeight : 0
        text: qsTr("Add to queue", "verb, put this at the end of the queue")
        iconName: "queue"
        onTriggered: root.addToQueue()
    }
    Separator {
        shown: root.trackSource !== null && root.canPin
    }

    Entry {
        id: pinEntry
        objectName: "pinMenuItem"
        visible: root.canPin
        height: visible ? implicitHeight : 0
        text: root.pinned ? qsTr("Unpin", "verb, remove from the pinned block") : qsTr("Pin", "verb, pin to the sidebar")
        // The icon follows the label: the filled pin is the one that is
        // already stuck in, so it is the row that pulls it out.
        iconName: root.pinned ? "pin-filled" : "pin"
        onTriggered: {
            if (root.pinned) pins.unpin(root.pinKind, root.pinId)
            else             pins.pin(root.pinKind, root.pinId, root.pinTitle,
                                      root.pinSubtitle, root.pinImageUrl)
        }
    }
    Entry {
        id: copyLinkEntry
        objectName: "copyLinkMenuItem"
        visible: root.linkUrl.length > 0
        height: visible ? implicitHeight : 0
        text: qsTranslate("TrackRow", "Copy link")
        iconName: "copy"
        onTriggered: root.copyLink()
    }

    // Last, under a rule of its own: the one row where a misclick costs you
    // something should not sit against the row above it.
    Separator {
        shown: root.removeLabel.length > 0
               && (root.canPin || root.trackSource !== null)
    }
    Entry {
        id: removeEntry
        objectName: "removeMenuItem"
        visible: root.removeLabel.length > 0
        height: visible ? implicitHeight : 0
        text: root.removeLabel
        danger: true
        iconName: "trash"
        onTriggered: root.removeRequested()
    }
}
