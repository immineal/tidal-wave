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
// (TrackRow and QueuePanel declare their own Menu but borrow the row), so
// there is exactly one answer to what a menu entry looks like and how wide it
// is allowed to get.
Menu {
    id: root

    // ── how a menu arrives and leaves, once ─────────────────────────────
    //
    // Opacity, and nothing else. Qt 6.4 has a Popup/Layout polish loop that
    // closes whenever a popup's own geometry feeds back into its contents
    // (commit 5c1125f, and the long comment on the output picker's popup in
    // PlayerBar.qml); a transition that animated height, scale or y would hand
    // the positioner a moving target again, and that loop printed 1992
    // warnings and hung a test run.
    //
    // Declared here and borrowed, the way Entry is: the two Menus in the app
    // that are not this one, TrackRow's and QueuePanel's, open the same way.
    component OpenFade : Transition {
        NumberAnimation {
            property: "opacity"
            from: 0; to: 1
            duration: Theme.dur(110)
            easing.type: Easing.OutCubic
        }
    }
    component CloseFade : Transition {
        NumberAnimation {
            property: "opacity"
            from: 1; to: 0
            duration: Theme.dur(90)
            easing.type: Easing.InCubic
        }
    }

    enter: OpenFade { }
    exit:  CloseFade { }

    // ── what a menu entry looks like, once ───────────────────────────────
    //
    // Every entry carries an icon.
    component Entry : MenuItem {
        id: entry

        // An icon *name* out of VectorIcon's set, not a character. Not called
        // `icon`: AbstractButton already has an `icon` group property.
        property string iconName: ""
        // Destructive. Tints the label and the icon red.
        property bool danger: false

        leftPadding: 12
        rightPadding: 12

        // The gutter is reserved on every row of a menu that has any icon in
        // it, so its labels start on one pixel instead of stepping in and out
        // around a row that has none -- and on none of the rows of a menu
        // with no icon at all, so an all-text menu is not mysteriously
        // indented. The menu answers that, not the row, which is why this
        // walks its siblings.
        //
        // Its own icon is asked first, and not only as a shortcut: the walk
        // reads `menu.count`, which is 0 while the menu is still being built,
        // and a row that answered "no gutter" there would sit half a column
        // left of the rest for as long as the binding stood.
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

    // Insets reset, not inherited. A Menu's insets exist for a style's drop
    // shadow, and the native macOS style sets all four to -32; this menu
    // replaces the background with its own Rectangle and never drew that
    // shadow, so the panel was laid out 32px past the popup on every side and
    // real entries were clipped at the window edge (a 207x56 popup drawing a
    // 271x120 background). Pinning the Basic style fixes it today, because
    // Basic's insets are 0; stating it here is what survives the next style
    // change, and it is a no-op wherever they already are 0.
    leftInset: 0; rightInset: 0; topInset: 0; bottomInset: 0

    // Set here rather than declaratively, and only where it exists.
    //
    // `popupType` and `Popup.Item` are both Qt 6.8. A declarative
    // `popupType: Popup.Item` is resolved when the file loads, so on
    // older Qt it does not merely warn - it makes this whole type
    // unavailable, and every type that uses it, all the way up. A real
    // Debian 12 build failed exactly that way: "Cannot assign to
    // non-existent property popupType", then "Type ContextMenu
    // unavailable", then "Type SideBar unavailable", and the app exited
    // with no window.
    //
    // Nothing is lost by leaving it unset on older Qt, because before
    // 6.8 an in-scene item was a menu's only form - the property was
    // added to allow native and separate-window popups, which arrived
    // with it. So this asks whether the property exists and sets it when
    // it does, which is the behaviour we want on both.
    //
    // `this.` is load-bearing. A *bare* identifier that names no property is
    // not undefined in QML's JS scope, it is a ReferenceError - and the error
    // aborts the whole handler rather than warning, at every instantiation,
    // which for a per-row menu is a stream of them. Qualifying the access
    // makes the miss a plain undefined. Worth knowing that this is invisible
    // on a current Qt, where the property exists and the bare form resolves
    // fine.
    Component.onCompleted: {
        if (this.popupType !== undefined) this.popupType = Popup.Item
    }

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

    // ── taking it away ───────────────────────────────────────────────────
    //
    // The destructive entry. The host supplies the wording, because only it
    // knows what removing means: an album leaves the library, an artist is
    // unfollowed. Empty means the host offers no such action and the row is
    // not there.
    //
    // Collection's album and artist grids are why this exists. Each used to
    // declare a Menu of its own over the top of the tile's, which covered the
    // tile's Pin entry: there was no way to pin an album or an artist from
    // Collection at all, only from its page or from the sidebar. Both of
    // those menus repeated Play next and Add to queue to work around it, and
    // the three copies were free to drift. There is one menu now.
    property string removeLabel: ""
    signal removeRequested()

    // Opens the menu on one thing. Nothing to offer, nothing to show.
    //
    // It used to ask only whether the thing was pinnable, which was the same
    // question while Pin was the only entry below the queue actions. It is
    // not any more: an unpinnable tile with a Remove entry has a menu worth
    // opening.
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
    readonly property alias pinItem:    pinEntry
    readonly property alias removeItem: removeEntry

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

    // Last, under a rule of its own: the one row where a misclick costs you
    // something should not sit against the row above it.
    MenuSeparator {
        visible: root.removeLabel.length > 0
                 && (root.canPin || root.trackSource !== null)
        height: visible ? implicitHeight : 0
        contentItem: Rectangle { height: 1; color: Theme.border }
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
