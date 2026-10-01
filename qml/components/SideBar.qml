import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import TidalWave

// The sidebar, in both of its shapes (SPEC sections 2 and L2-L4).
//
// Wide windows get the full sidebar; below Prefs::railBreakpoint it collapses to
// a 68px rail of icons, and hovering that rail brings the *same* sidebar back as
// an overlay on top of the page, the way compact mode works in Zen Browser and
// Firefox. There is deliberately no manual toggle: window width is the only
// thing that decides.
//
// The overlay is why this item is not the panel it draws. The root is the slot
// the layout gives it — rail-wide while compact — and `panel` inside it is free
// to grow past that slot and cover the page without the layout reflowing and
// shoving the page sideways. Main.qml gives the root `z: 2` so it covers the
// page rather than sliding under it.
Item {
    id: root

    property string currentPage: "home"
    signal navigate(string page, var params)

    // The *window* width decides compact mode. The sidebar's own width is the
    // thing that changes, so measuring itself would be circular. Main.qml binds
    // this; the fallback keeps the component usable on its own.
    property int hostWidth: Window.window ? Window.window.width : root.width

    readonly property bool compact: hostWidth > 0 && hostWidth < prefs.railBreak()
    readonly property int  railWidth: prefs.rail()
    // prefs clamps this too, but a settings file written by another build has
    // to not be able to hand the layout a nonsense width.
    readonly property int  expandedWidth: Math.max(prefs.minSidebar(),
                                          Math.min(prefs.maxSidebar(), prefs.sidebarWidth))

    // Typing keeps the overlay open after the pointer has wandered off it.
    readonly property bool hoverExpanded: compact && (panelHover.hovered || finder.focused)
    readonly property bool expanded:   !compact || hoverExpanded
    readonly property bool overlaying:  compact && hoverExpanded

    // What the layout must reserve, which is *not* what the panel draws: that
    // difference is the overlay.
    readonly property int reservedWidth: compact ? railWidth : expandedWidth
    readonly property int targetWidth:   expanded ? expandedWidth : railWidth
    property int panelWidth: targetWidth

    // How open the panel is, 0 at the rail and 1 at full width. Everything that
    // has to move during the slide lerps off this rather than switching on
    // `expanded`, which would snap the moment the animation started instead of
    // travelling with it.
    readonly property real wideness: Math.max(0, Math.min(1,
        (panelWidth - railWidth) / Math.max(1, expandedWidth - railWidth)))
    // Content that only fits the full sidebar. Held back until the panel is a
    // quarter open so it fades in behind the leading edge rather than ahead
    // of it.
    readonly property bool showsWide: wideness > 0.25
    readonly property real wideOpacity: Math.max(0, (wideness - 0.25) / 0.75)

    // X6. Qt exposes no cross-platform reduced-motion hint, so Application
    // reads what the desktop does expose; see Application::reducedMotion().
    // Theme.reduceMotion is where the rest of the app asks the same question;
    // this stays as the name the sidebar's own tests reach for.
    readonly property bool reduceMotion: Theme.reduceMotion

    // A drag is a continuous stream of new widths, so animating it would make
    // the border lag behind the pointer. Reduced motion goes through the
    // duration instead of through `enabled`, so the slide still runs and still
    // finishes — it just finishes in the frame it started.
    Behavior on panelWidth {
        enabled: !dragHandle.dragging
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    function openSettings() { settingsPopup.open() }

    // ── the rows the library list shows ──────────────────────────────────

    readonly property bool searching: finder.query.trim().length > 0
    property var rows: []

    function rebuildRows() {
        if (searching) {
            root.rows = library.search(finder.query, finder.kinds)
            return
        }
        var all = library.entries
        var kinds = finder.kinds
        if (!kinds || kinds.length === 0) {
            root.rows = all
            return
        }
        var out = []
        for (var i = 0; i < all.length; i++)
            if (kinds.indexOf(all[i].kind) >= 0) out.push(all[i])
        root.rows = out
    }

    // ── the pinned block, and dragging inside it (P3, P4) ────────────────

    // The height of one library row, which is also the height of one slot in
    // the pinned block, so the drag can work in whole rows.
    readonly property int libRowHeight: 34

    // The pinned rows are the leading run of the library list: the data layer
    // puts them first and flags each one, so counting the run is all there is
    // to it. A search result has no pinned block to count.
    readonly property int pinnedCount: {
        if (searching) return 0
        var n = 0
        while (n < rows.length && rows[n].pinned === true) n++
        return n
    }

    // Live drag state. It sits here rather than in the row because the drop
    // indicator belongs to the list, not to the row being dragged.
    property int  pinDragFrom:   -1
    property int  pinDragTo:     -1
    property real pinDragOffset: 0
    // Whether the pointer is still inside the pinned block. A drag that ends
    // anywhere else is abandoned rather than clamped: a pinned row must not
    // land in the ordinary library list below, and letting a drop out there
    // mean anything at all would turn a slip of the hand into an edit.
    property bool pinDropValid:  false
    readonly property bool pinDragging: pinDragFrom >= 0

    // The slot a row dragged by `offset` is over, never outside the block.
    function pinSlotAt(from, offset) {
        return Math.max(0, Math.min(root.pinnedCount - 1,
                                    from + Math.round(offset / root.libRowHeight)))
    }

    function beginPinDrag(index) {
        root.pinDragFrom   = index
        root.pinDragTo     = index
        root.pinDragOffset = 0
        root.pinDropValid  = true
    }

    function cancelPinDrag() {
        root.pinDragFrom   = -1
        root.pinDragTo     = -1
        root.pinDragOffset = 0
        root.pinDropValid  = false
    }

    function endPinDrag() {
        var from = root.pinDragFrom
        var to   = root.pinDragTo
        var ok   = root.pinDropValid
        cancelPinDrag()
        if (!ok || from < 0 || to < 0 || from === to) return

        var a = root.rows[from]
        var b = root.rows[to]
        if (!a || !b) return
        // Row index and pin index line up today, but it is PinStore that is
        // being reordered, so the move is expressed in its indices and not in
        // the list's. PinStore persists it; LibraryIndex rebuilds off its
        // `changed`, which is what reorders the rows on screen.
        var fromPin = pins.indexOf(a.kind, a.id)
        var toPin   = pins.indexOf(b.kind, b.id)
        if (fromPin < 0 || toPin < 0 || fromPin === toPin) return
        pins.move(fromPin, toPin)
    }

    // ── the pin menu (P2) ────────────────────────────────────────────────

    readonly property alias pinMenu: pinContextMenu

    // `data` is a library row or a pinned item from the rail; both carry
    // kind, id, title, subtitle and imageUrl. x and y are in root's
    // coordinates.
    function showPinMenu(x, y, data) {
        if (!data) return
        pinContextMenu.showPin(x, y, data.kind, data.id, data.title || "",
                               data.subtitle || "", data.imageUrl || "")
    }

    ContextMenu {
        id: pinContextMenu
        objectName: "sidebarPinMenu"
    }

    // Coalesces a burst of keystrokes into one pass over the index. 120ms is
    // below the point where the list feels like it is lagging the typing.
    Timer {
        id: filterTimer
        interval: 120
        onTriggered: root.rebuildRows()
    }

    Connections {
        target: finder
        function onQueryChanged() { filterTimer.restart() }
        function onKindsChanged() { filterTimer.restart() }
    }

    Connections {
        target: library
        // The whole library arrived, or a play reordered it. No debounce: this
        // is not keystroke-rate.
        function onEntriesChanged() { root.rebuildRows() }
    }

    Component.onCompleted: rebuildRows()

    // ── the panel ────────────────────────────────────────────────────────

    Rectangle {
        id: panel
        objectName: "sidebarPanel"
        width: root.panelWidth
        height: root.height
        color: Theme.surface
        // While the panel is narrower than its content, the content must not
        // spill out over the page.
        clip: true

        HoverHandler { id: panelHover }

        ColumnLayout {
            id: body
            anchors.top: parent.top
            anchors.bottom: footer.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 0

            Item { Layout.fillWidth: true; Layout.preferredHeight: 20 }

            // ── mark and wordmark ────────────────────────────────────────
            Item {
                id: logoItem
                objectName: "sidebarLogo"
                Layout.fillWidth: true
                Layout.preferredHeight: 28

                Rectangle {
                    id: mark
                    // 20 centres the 28px mark in the 68px rail and is also the
                    // sidebar's left inset, so it does not move between the two.
                    x: 20
                    width: 28
                    height: 28
                    radius: Theme.radiusBadge
                    color: Theme.accent
                    Text {
                        anchors.centerIn: parent
                        text: "≋"
                        color: Theme.accentInk
                        font.pixelSize: 16
                        font.bold: true
                    }
                }
                Text {
                    anchors.left: mark.right
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: mark.verticalCenter
                    visible: root.showsWide
                    opacity: root.wideOpacity
                    text: "Tidal Wave"
                    color: Theme.textPrimary
                    font.pixelSize: 14
                    font.bold: true
                    font.letterSpacing: 1
                    elide: Text.ElideRight
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 24 }

            SideNavItem {
                icon: "home"
                label: qsTr("Home", "noun, the home page")
                page: "home"
                onActivated: root.navigate("home", {})
            }
            SideNavItem {
                icon: "search"
                label: qsTr("Search", "noun, the search page")
                page: "search"
                onActivated: root.navigate("search", {})
            }
            SideNavItem {
                icon: "heart"
                label: qsTr("Collection")
                page: "collection"
                onActivated: root.navigate("collection", {})
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 16 }
            Rectangle {
                objectName: "sidebarNavDivider"
                color: Theme.border
                height: 1
                Layout.fillWidth: true
                Layout.leftMargin: root.expanded ? 16 : 14
                Layout.rightMargin: root.expanded ? 16 : 14
            }
            Item { Layout.fillWidth: true; Layout.preferredHeight: 14 }

            // ── the finder: search field plus type chips (S5, S8) ────────
            LibraryFinder {
                id: finder
                objectName: "sidebarFinder"
                visible: root.showsWide
                opacity: root.wideOpacity
                Layout.fillWidth: true
                Layout.leftMargin: 12
                Layout.rightMargin: 12
                Layout.preferredHeight: implicitHeight
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 10
                visible: root.showsWide
            }

            // ── the flat library list (S1, S2) ───────────────────────────
            ListView {
                id: libList
                objectName: "sidebarLibraryList"
                visible: root.showsWide
                opacity: root.wideOpacity
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                bottomMargin: 8
                model: root.rows
                // A library can run to thousands of rows, so nothing outside
                // the viewport is kept alive.
                cacheBuffer: 240
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: LibraryRow { }

                // P4: where the dragged row will land. Declared inside the
                // list, which parents it to the content item, so it is
                // positioned in content coordinates and points between the
                // same two rows however far the list is scrolled.
                Rectangle {
                    objectName: "pinDropIndicator"
                    visible: root.pinDragging && root.pinDropValid
                    x: 8
                    width: Math.max(0, libList.width - 16)
                    height: 2
                    radius: 1
                    z: 3
                    color: Theme.accent
                    y: (root.pinDragTo > root.pinDragFrom ? root.pinDragTo + 1 : root.pinDragTo)
                       * root.libRowHeight - 1
                }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 32
                    visible: root.rows.length === 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.searching ? qsTr("No matches") : qsTr("Nothing saved yet")
                    color: Theme.textDim
                    font.pixelSize: 12
                }
            }

            // ── the rail's pinned covers (S9) ────────────────────────────
            ListView {
                id: railPins
                objectName: "sidebarRailPins"
                visible: !root.showsWide
                opacity: 1 - root.wideness
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                topMargin: 4
                bottomMargin: 8
                spacing: 4
                model: pins.items
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                    id: pinDelegate
                    required property var modelData
                    width: ListView.view.width
                    height: 44

                    Rectangle {
                        objectName: "railPinCover"
                        anchors.centerIn: parent
                        width: 40
                        height: 40
                        radius: Theme.radiusArt
                        color: Theme.surfaceHigh
                        border.width: pinHov.hovered ? 1 : 0
                        border.color: Theme.accent
                        clip: true

                        Image {
                            anchors.fill: parent
                            source: (pinDelegate.modelData.imageUrl || "").length > 0
                                    ? "image://tidal/" + pinDelegate.modelData.imageUrl : ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: status === Image.Ready
                        }
                        VectorIcon {
                            anchors.centerIn: parent
                            width: 18
                            height: 18
                            visible: (pinDelegate.modelData.imageUrl || "").length === 0
                            name: root.glyphFor(pinDelegate.modelData.kind)
                            color: Theme.textDim
                        }

                        HoverHandler { id: pinHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: root.open(pinDelegate.modelData.kind,
                                                pinDelegate.modelData.id,
                                                pinDelegate.modelData)
                        }

                        // The rail carries the pinned covers and nothing else
                        // of the library, so the one thing a right-click here
                        // can mean is Unpin. Reordering stays in the full
                        // sidebar, which a hover brings back anyway (L4).
                        MouseArea {
                            objectName: "railPinMenuArea"
                            anchors.fill: parent
                            acceptedButtons: Qt.RightButton
                            onClicked: function (mouse) {
                                var p = mapToItem(root, mouse.x, mouse.y)
                                root.showPinMenu(p.x, p.y, pinDelegate.modelData)
                            }
                        }

                        ToolTip.visible: pinHov.hovered
                        ToolTip.text: pinDelegate.modelData.title || ""
                        ToolTip.delay: 450
                    }
                }
            }
        }

        // ── footer: the username and the gear, nothing else (S10) ────────
        Rectangle {
            id: footer
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 56
            color: Theme.surfaceHigh

            Text {
                id: acctNameText
                objectName: "sidebarAccountName"
                visible: root.showsWide
                opacity: root.wideOpacity
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.right: gearItem.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                // Auth::displayNameFrom already picks the username over the
                // email address; there is deliberately no avatar beside it.
                text: auth.username.length > 0 ? auth.username : qsTr("My Account")
                color: Theme.textPrimary
                font.pixelSize: 13
                elide: Text.ElideRight
                ToolTip.visible: acctNameHov.hovered && acctNameText.truncated
                ToolTip.text: acctNameText.text
                ToolTip.delay: 600
                HoverHandler { id: acctNameHov }
            }

            Item {
                id: gearItem
                objectName: "sidebarSettingsGear"
                width: 28
                height: 28
                // Right-aligned in the sidebar, centred in the rail, and it
                // travels between the two with the slide.
                readonly property real railX: Math.round((root.railWidth - width) / 2)
                readonly property real wideX: Math.max(0, panel.width - width - 16)
                x: Math.round(railX + (wideX - railX) * root.wideness)
                anchors.verticalCenter: parent.verticalCenter

                activeFocusOnTab: true
                Keys.onReturnPressed: root.openSettings()
                Keys.onSpacePressed:  root.openSettings()

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: Theme.radiusButton
                    color: "transparent"
                    border.width: gearItem.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.centerIn: parent
                    name: "settings"
                    color: settingsHover.hovered ? Theme.textPrimary : Theme.textSec
                    width: 18
                    height: 18
                    strokeWidth: 1.8
                    ToolTip.visible: settingsHover.hovered
                    ToolTip.text: qsTr("Settings (Ctrl+,)")
                    HoverHandler { id: settingsHover }
                }
                TapHandler {
                    cursorShape: Qt.PointingHandCursor
                    onTapped: root.openSettings()
                }
            }
        }
    }

    // A soft edge where the overlay meets the page, so the sidebar reads as
    // floating above it. A gradient strip rather than MultiEffect: no extra QML
    // module to package, and it costs nothing under software rendering.
    Rectangle {
        id: panelShadow
        x: panel.width
        width: 14
        height: root.height
        visible: root.overlaying || root.panelWidth > root.reservedWidth
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, Theme.scrim.a * 0.55) }
            GradientStop { position: 1.0; color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0) }
        }
    }

    // ── L3: the border is the resize handle ──────────────────────────────

    MouseArea {
        id: dragHandle
        objectName: "sidebarDragHandle"
        // Straddles the border so there is grabbable width on both sides of it.
        x: panel.width - 3
        width: 6
        height: root.height
        // Nothing to resize in the rail, and in the overlay the width on screen
        // is not the width being stored.
        visible: !root.compact
        enabled: !root.compact
        hoverEnabled: true
        cursorShape: Qt.SplitHCursor

        property bool dragging: false
        // Scene coordinates, because the handle itself travels with the edge it
        // is dragging: measuring in local coordinates would chase its own tail.
        property real originScene: 0
        property int  originWidth: 0

        onPressed: function (mouse) {
            dragging = true
            originScene = mapToItem(null, mouse.x, mouse.y).x
            originWidth = root.expandedWidth
        }
        onPositionChanged: function (mouse) {
            if (!dragging) return
            // Always measured from where the press started, so running past a
            // clamp does not bank width that comes back on the way home.
            prefs.sidebarWidth = Math.round(
                originWidth + (mapToItem(null, mouse.x, mouse.y).x - originScene))
        }
        onReleased: dragging = false
        onCanceled: dragging = false

        // The border itself, drawn by the handle so the two cannot drift apart.
        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 3
            width: 1
            height: parent.height
            color: dragHandle.containsMouse || dragHandle.dragging ? Theme.accent : Theme.border
        }
    }

    // ── navigation helpers ───────────────────────────────────────────────

    function glyphFor(kind) {
        // VectorIcon has no "track" glyph; a song is a note.
        return kind === "track" ? "music" : kind
    }

    // Opens one library row. `data` is the row as LibraryIndex handed it over.
    function open(kind, id, data) {
        library.markPlayed(kind, id)
        switch (kind) {
        case "playlist":
            // The row carries the playlist's Tidal type, which is what
            // PlaylistPage reads to decide whether the playlist is editable.
            // Anything that is not "USER" opens read-only.
            root.navigate("playlist", {
                playlistUuid:  id,
                playlistTitle: data.title || "",
                coverUrl:      data.imageUrl || "",
                playlistType:  data.type || ""
            })
            break
        case "album":
            root.navigate("album", { albumId: parseInt(id) })
            break
        case "artist":
            root.navigate("artist", { artistId: parseInt(id) })
            break
        case "mix":
            root.navigate("mix", {
                mixId:    id,
                title:    data.title || "",
                subtitle: data.subtitle || "",
                coverUrl: data.imageUrl || ""
            })
            break
        case "track":
            // A song opens the album it came from, which is the only page a
            // single track has.
            if (data.albumId) root.navigate("album", { albumId: parseInt(data.albumId) })
            break
        }
    }

    // The settings popup, exposed so tests/qml/tst_layout_player.qml and
    // tst_sidebar.qml can measure it. Nothing else reads it.
    readonly property alias settingsPanel: settingsPopup

    // Its own file since it grew a picker for every 0.4.0 feature that had
    // none; this file was already the longest in qml/.
    SettingsPanel { id: settingsPopup }

    // ── inline components ────────────────────────────────────────────────

    // One row of the flat library list. The type icon is what tells a playlist
    // from an album from an artist from a mix now that they share one list.
    component LibraryRow : Item {
        id: rowItem
        objectName: "libraryRow"

        required property int index
        required property var modelData

        readonly property string kind:   modelData.kind
        readonly property string itemId: modelData.id
        readonly property string title:  modelData.title
        readonly property bool   pinned: modelData.pinned === true
        // S7: a row the search pulled in because of a neighbouring hit, rather
        // than because the user typed its name.
        readonly property bool   derived: modelData.expanded === true

        // The break between the pinned block and the rest (P3/P5). Search
        // results have no pinned block, so they have nothing to break.
        readonly property bool blockBreak: !root.searching && index > 0 && !pinned
                                           && root.rows[index - 1].pinned === true

        // P4. There is nothing to reorder in a block of one, and nothing
        // outside the block is draggable at all, which is half of why a
        // pinned row cannot end up in the list below.
        readonly property bool draggable: pinned && !root.searching && root.pinnedCount > 1
        readonly property bool dragging:  root.pinDragging && root.pinDragFrom === index

        width: ListView.view ? ListView.view.width : 0
        height: root.libRowHeight + (blockBreak ? 11 : 0)
        // The row being dragged travels over its neighbours, not under them.
        z: dragging ? 2 : 0

        activeFocusOnTab: true
        Keys.onReturnPressed: root.open(kind, itemId, modelData)
        Keys.onSpacePressed:  root.open(kind, itemId, modelData)

        Rectangle {
            objectName: "pinnedBlockBreak"
            property int rowIndex: rowItem.index
            visible: rowItem.blockBreak
            anchors.top: parent.top
            anchors.topMargin: 5
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: parent.right
            anchors.rightMargin: 16
            height: 1
            color: Theme.border
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            height: root.libRowHeight
            radius: Theme.radiusRow
            color: rowItem.dragging || rowHov.hovered ? Theme.surfaceHov : "transparent"
            border.width: rowItem.activeFocus || rowItem.dragging ? 2 : 0
            border.color: Theme.accent
            // The lift. A transform rather than a y offset, because the row's
            // y belongs to the ListView.
            transform: Translate { y: rowItem.dragging ? root.pinDragOffset : 0 }

            HoverHandler { id: rowHov; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.open(rowItem.kind, rowItem.itemId, rowItem.modelData) }

            // P2. Right button only, so the tap handler above keeps every
            // left-click; declared before the grip so a right-click over the
            // grip still opens the menu.
            MouseArea {
                objectName: "libraryRowMenuArea"
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: function (mouse) {
                    var p = mapToItem(root, mouse.x, mouse.y)
                    root.showPinMenu(p.x, p.y, rowItem.modelData)
                }
            }

            VectorIcon {
                id: rowIcon
                objectName: "libraryRowIcon"
                anchors.left: parent.left
                anchors.leftMargin: 8 + (rowItem.derived ? 12 : 0)
                anchors.verticalCenter: parent.verticalCenter
                name: root.glyphFor(rowItem.kind)
                width: 15
                height: 15
                strokeWidth: 1.5
                color: rowItem.pinned ? Theme.accent : Theme.textDim
            }

            Text {
                id: rowTitle
                objectName: "libraryRowTitle"
                anchors.left: rowIcon.right
                anchors.leftMargin: 10
                anchors.right: parent.right
                // The grip's space is reserved whether or not it is showing,
                // so the title does not jump when the pointer arrives.
                anchors.rightMargin: rowItem.draggable ? 28 : 10
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.title
                color: rowItem.derived ? Theme.textDim : Theme.textSec
                font.pixelSize: 13
                elide: Text.ElideRight
            }

            // P4: the drag affordance. Drawn on every pinned row rather than
            // on hover alone, so the block says it can be reordered before
            // anyone goes looking.
            Item {
                id: grip
                objectName: "pinDragGrip"
                visible: rowItem.draggable
                width: 16
                height: parent.height
                anchors.right: parent.right
                anchors.rightMargin: 6

                VectorIcon {
                    anchors.centerIn: parent
                    name: "grip"
                    width: 12
                    height: 12
                    strokeWidth: 1.5
                    color: rowItem.dragging ? Theme.accent : Theme.textDim
                    opacity: rowHov.hovered || rowItem.dragging ? 1 : 0.45
                }

                MouseArea {
                    id: dragArea
                    objectName: "pinDragArea"
                    anchors.fill: parent
                    anchors.margins: -5          // 16x34 is a small target
                    enabled: rowItem.draggable
                    cursorShape: rowItem.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    // Otherwise the list reads the vertical drag as a flick
                    // and takes the grab away mid-reorder.
                    preventStealing: true

                    // Where the press landed, in the list's content
                    // coordinates, which do not move when the list scrolls.
                    property real pressY: 0

                    onPressed: function (mouse) {
                        dragArea.pressY = mapToItem(libList.contentItem, mouse.x, mouse.y).y
                        root.beginPinDrag(rowItem.index)
                    }
                    onPositionChanged: function (mouse) {
                        if (!rowItem.dragging) return
                        // The row travels with the pointer, but the event
                        // arrives in the handle's own moving coordinates and
                        // mapToItem puts it back, so this is the pointer
                        // itself, in the list's content space.
                        var p = mapToItem(libList.contentItem, mouse.x, mouse.y)
                        root.pinDragOffset = p.y - dragArea.pressY
                        root.pinDragTo     = root.pinSlotAt(rowItem.index, root.pinDragOffset)
                        // Confined to the pinned block, in both directions:
                        // the list below it and the page beside it.
                        root.pinDropValid  = p.y >= 0
                            && p.y < root.pinnedCount * root.libRowHeight
                            && p.x >= 0 && p.x <= libList.width
                    }
                    onReleased: root.endPinDrag()
                    onCanceled: root.cancelPinDrag()
                }
            }

            ToolTip.visible: rowHov.hovered && !rowItem.dragging
                             && (rowTitle.truncated || subtitleOf.length > 0)
            ToolTip.text: subtitleOf.length > 0 ? rowItem.title + " · " + subtitleOf
                                                : rowItem.title
            ToolTip.delay: 600
            readonly property string subtitleOf: rowItem.modelData.subtitle || ""
        }
    }

    // A nav row. In the rail it is the icon alone, centred; expanded it gains
    // its label. Same item either way, so the switch is a slide, not a swap.
    component SideNavItem : Item {
        id: navItem
        property string icon: ""
        property string label: ""
        property string page: ""
        signal activated()

        readonly property bool current: root.currentPage === page

        Layout.fillWidth: true
        Layout.preferredHeight: 44

        activeFocusOnTab: true
        Keys.onReturnPressed: activated()
        Keys.onSpacePressed:  activated()

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            radius: Theme.radiusRow
            color: navItem.current
                   ? Theme.surfaceHov
                   : sideHov.hovered ? Theme.hoverFill : "transparent"
            border.width: navItem.activeFocus ? 2 : 0
            border.color: Theme.accent

            Rectangle {
                visible: navItem.current
                width: 3
                height: parent.height * 0.5
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: -8
                radius: 2
                color: Theme.accent
            }

            NavIcon {
                id: navGlyph
                objectName: "navIcon"
                name: navItem.icon
                color: navItem.current ? Theme.accent : Theme.textSec
                anchors.verticalCenter: parent.verticalCenter
                // 16 from the panel edge in the sidebar (8 here, inside the
                // row's 8px inset), centred in the rail, and travelling
                // between the two with the slide.
                readonly property real railX: Math.round((root.railWidth - 16 - width) / 2)
                x: Math.round(railX + (8 - railX) * root.wideness)
            }

            Text {
                objectName: "navLabel"
                visible: root.showsWide
                opacity: root.wideOpacity
                anchors.left: navGlyph.right
                anchors.leftMargin: 12
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: navItem.label
                color: navItem.current ? Theme.textPrimary : Theme.textSec
                font.pixelSize: 14
                font.bold: navItem.current
                elide: Text.ElideRight
            }

            HoverHandler { id: sideHov; cursorShape: Qt.PointingHandCursor }
            TapHandler   { onTapped: navItem.activated() }

            ToolTip.visible: sideHov.hovered && !root.showsWide
            ToolTip.text: navItem.label
            ToolTip.delay: 450
        }
    }
}
