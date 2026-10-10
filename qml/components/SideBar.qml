import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import TidalWave

// The sidebar in both of its shapes. Wide windows get the full sidebar; below
// Prefs::railBreakpoint it is a rail of icons, and hovering the rail brings the
// same sidebar back as an overlay on the page. Window width alone decides. The
// root is the slot the layout reserves, and `panel` inside it may grow past
// that slot, so the overlay does not reflow the page. Main.qml gives the root
// `z: 2` so it covers the page.
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

    // What the layout reserves. While compact that is the rail, whatever the
    // panel draws: the difference is the overlay. It has its own Behavior and
    // does not read panelWidth, so the page edge follows the panel both ways.
    property int reservedWidth: compact ? railWidth : expandedWidth
    readonly property int targetWidth:   expanded ? expandedWidth : railWidth
    property int panelWidth: targetWidth

    // How open the panel is, 0 at the rail and 1 at full width. Everything that
    // moves during the slide lerps off this; switching on `expanded` would snap
    // when the animation starts.
    readonly property real wideness: Math.max(0, Math.min(1,
        (panelWidth - railWidth) / Math.max(1, expandedWidth - railWidth)))
    // Content that only fits the full sidebar. Held back until the panel is a
    // quarter open so it fades in behind the leading edge rather than ahead
    // of it.
    readonly property bool showsWide: wideness > 0.25
    readonly property real wideOpacity: Math.max(0, (wideness - 0.25) / 0.75)

    // Theme.reduceMotion under the name the sidebar's own tests reach for.
    readonly property bool reduceMotion: Theme.reduceMotion

    // A drag is a stream of new widths, so animating it would make the border
    // lag the pointer. Reduced motion goes through the duration, not `enabled`,
    // so the slide still runs and finishes in the frame it started.
    Behavior on panelWidth {
        enabled: !dragHandle.dragging
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    // The slot does not animate until the window has said how wide it is: the
    // first evaluation runs at hostWidth 0, which reads as not compact. Set
    // through Qt.callLater, so the corrective jump itself is still instant.
    property bool slotSettled: false
    onHostWidthChanged: {
        if (hostWidth > 0 && !slotSettled)
            Qt.callLater(function () { root.slotSettled = true })
    }

    // Same curve and duration as the panel's: a breakpoint crossing moves both,
    // and any difference shows as page ground between the two edges.
    Behavior on reservedWidth {
        enabled: root.slotSettled && !dragHandle.dragging
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    function openSettings() { settingsPopup.open() }

    // ── the rows the library list shows ──────────────────────────────────

    readonly property bool searching: finder.query.trim().length > 0
    property var rows: []

    function rebuildRows() {
        if (searching) {
            syncRows(library.search(finder.query, finder.kinds))
            return
        }
        // Filtered by the index, not here: `entries` leaves songs out, so
        // filtering it in QML could never answer the Tracks chip.
        syncRows(library.entriesForKinds(finder.kinds || []))
    }

    // ── the same rows, as a model the view can animate ───────────────────
    // `rows` is the array; `libModel` holds the same entries for the ListView.
    // Assigning a new JS array is a model reset that rebuilds every delegate,
    // while a ListModel turns one pin into one move() the view can animate.
    ListModel {
        id: libModel
        // The rows are whole objects out of LibraryIndex. A static-role
        // ListModel would turn a nested value into a sub-model; a dynamic one
        // stores it as it is.
        dynamicRoles: true
    }

    // What makes two rebuilds' rows the same row. Both halves are strings
    // already, and no kind contains a slash.
    function rowKey(e) { return e ? e.kind + "/" + e.id : "" }

    // The smallest remove/move/insert list that turns `oldKeys` into `newKeys`,
    // or null when it would take more than `cap` of them. Planned on a copy of
    // the keys, so giving up happens before the first op touches the model.
    function rowPlan(oldKeys, newKeys, cap) {
        var ops = []
        var cur = oldKeys.slice()
        var want = {}
        var i
        for (i = 0; i < newKeys.length; ++i) want[newKeys[i]] = true

        // Gone, back to front, so the indices still to be looked at stay put.
        // A run of neighbours goes in one op.
        var j = cur.length - 1
        while (j >= 0) {
            if (want[cur[j]] === true) { j--; continue }
            var end = j
            while (j > 0 && want[cur[j - 1]] !== true) j--
            ops.push({ op: "remove", at: j, n: end - j + 1 })
            cur.splice(j, end - j + 1)
            if (ops.length > cap) return null
            j--
        }

        var pos = {}
        for (i = 0; i < cur.length; ++i) pos[cur[i]] = i
        for (var t = 0; t < newKeys.length; ++t) {
            if (t < cur.length && cur[t] === newKeys[t]) continue
            var from = pos[newKeys[t]]
            if (from === undefined) {
                ops.push({ op: "insert", at: t })
                cur.splice(t, 0, newKeys[t])
            } else {
                ops.push({ op: "move", from: from, at: t })
                cur.splice(t, 0, cur.splice(from, 1)[0])
            }
            for (i = t; i < cur.length; ++i) pos[cur[i]] = i
            if (ops.length > cap) return null
        }
        return ops
    }

    function fillLibModel(next, newKeys) {
        libModel.clear()
        for (var i = 0; i < next.length; ++i)
            libModel.append({ key: newKeys[i], entry: next[i] })
    }

    // Rows that arrived while a pin was being dragged, held until the pointer
    // is up; null when there are none. A refill past the diff's cap clears the
    // model, which releases the delegate holding the pointer grab.
    property var deferredRows: null

    function syncRows(next) {
        if (root.pinDragging) {
            root.deferredRows = next
            return
        }
        root.rows = next

        var i
        var oldKeys = []
        for (i = 0; i < libModel.count; ++i) oldKeys.push(libModel.get(i).key)
        var newKeys = []
        for (i = 0; i < next.length; ++i) newKeys.push(rowKey(next[i]))

        var plan = oldKeys.length === 0 ? null : rowPlan(oldKeys, newKeys, 32)
        if (plan === null) {
            fillLibModel(next, newKeys)
            return
        }

        for (i = 0; i < plan.length; ++i) {
            var op = plan[i]
            if (op.op === "remove")    libModel.remove(op.at, op.n)
            else if (op.op === "move") libModel.move(op.from, op.at, 1)
            else                       libModel.insert(op.at, { key: newKeys[op.at],
                                                                entry: next[op.at] })
        }

        // The plan is only as good as the keys being unique. Two rows with one
        // key leave the model a different length from `rows`, so it is rebuilt
        // outright.
        if (libModel.count !== next.length) {
            fillLibModel(next, newKeys)
            return
        }

        // Every rebuild hands over fresh objects, and a row that kept its key
        // can still have changed: `pinned` flips, a title or a cover url
        // arrives. So the rows that did not move are handed the new entry too.
        for (i = 0; i < next.length; ++i) libModel.setProperty(i, "entry", next[i])
    }

    readonly property int libraryTravelMs: 170

    // How many rows have been asked to travel, for the tests. It only goes up:
    // a poll can step over a flag, and a ViewTransition the view cancels never
    // runs a trailing ScriptAction, so an in/out pair would stick.
    property int libraryMoves: 0

    // One list in both shapes means one model, so a query left behind would go
    // on filtering a rail with no finder on screen. Clearing as the panel
    // closes also keeps the model still during the slide, so the covers travel.
    onExpandedChanged: if (!expanded) finder.reset()

    // ── the pinned block, and dragging inside it ─────────────────────────

    // The height of one library row and of one slot in the pinned block, so the
    // drag works in whole rows.
    readonly property int libRowHeight: 44

    // ── the cover, which is one cover in both shapes ─────────────────────
    // 36 makes the corner badge 18 and its glyph 12, which is legible, and
    // leaves 4px of air above and below the cover inside the row.
    readonly property int coverSize: 36
    readonly property int coverBadge:     Math.round(coverSize * 0.5)
    readonly property int coverBadgeIcon: Math.round(coverSize / 3)
    // How far the badge is held off the cover's right and bottom edges. Flush,
    // a crescent of cover shows past the badge's corner, and clipping cannot
    // fix it: a Shape ignores an ancestor's clip. Below 2 the speck returns.
    readonly property int coverBadgeInset: Math.max(2, Math.round(coverSize * 0.06))
    // The whole tile when there is no artwork to put a corner on.
    readonly property int coverPlainIcon: Math.round(coverSize * 0.56)
    // The row's own inset inside the panel, and where a row's content starts
    // once the sidebar is open. 16 is the sidebar's left inset throughout.
    readonly property int rowInset:  8
    readonly property int coverLeft: 16

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
    // Whether the row being dragged is still over the pinned block. A drag that
    // ends anywhere else is abandoned, not clamped: a pinned row must not land
    // in the ordinary list by a slip of the hand.
    property bool pinDropValid:  false
    readonly property bool pinDragging: pinDragFrom >= 0

    // The slot a row dragged by `offset` is over, never outside the block.
    function pinSlotAt(from, offset) {
        return Math.max(0, Math.min(root.pinnedCount - 1,
                                    from + Math.round(offset / root.libRowHeight)))
    }

    // Whether that row is over the block at all, which decides whether the drop
    // is taken. Any overlap counts. Asked of the row, as pinSlotAt() is, and in
    // the block's own grid: a row in travel is still drawn at its old place.
    function pinOverBlock(from, offset) {
        var top = from * root.libRowHeight + offset
        return top > -root.libRowHeight
            && top < root.pinnedCount * root.libRowHeight
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
        // Whatever the library did while the pointer was down.
        if (root.deferredRows !== null) {
            var held = root.deferredRows
            root.deferredRows = null
            syncRows(held)
        }
    }

    function endPinDrag() {
        var from = root.pinDragFrom
        var to   = root.pinDragTo
        var ok   = root.pinDropValid
        // Read before the drag state is cleared: clearing it releases any rows
        // held during the drag and rewrites `rows`.
        var a = root.rows[from]
        var b = root.rows[to]
        cancelPinDrag()
        if (!ok || from < 0 || to < 0 || from === to) return
        if (!a || !b) return
        // It is PinStore that is reordered, so the move is in its indices and
        // not the list's. LibraryIndex rebuilds off its `changed`.
        var fromPin = pins.indexOf(a.kind, a.id)
        var toPin   = pins.indexOf(b.kind, b.id)
        if (fromPin < 0 || toPin < 0 || fromPin === toPin) return
        pins.move(fromPin, toPin)
    }

    // ── the pin menu ─────────────────────────────────────────────────────

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

    Component.onCompleted: {
        rebuildRows()
        // The binding below may well have run before navHome existed, so the
        // first placement is made again from here, where the rows certainly do.
        retargetNav(false)
        Qt.callLater(function () { root.navSettled = true })
    }

    // ── the nav highlight, as one bar that travels ────────────────────────
    // One indicator for the three rows. Only `navT` is animated; the geometry
    // is read live off the two rows on every frame, so a layout change arrives
    // in the frame it happens.
    property Item navFrom: null
    property Item navTo:   null
    property real navT:    1
    // The reset to 0 that every travel starts with is the one write to navT
    // that must not animate, or the bar would run backwards to the row it is
    // already on before setting off.
    property bool navResetting: false
    Behavior on navT {
        enabled: !root.navResetting
        // The chips on Collection travel on the same 140, so the two read as
        // one.
        NumberAnimation { duration: Theme.dur(140); easing.type: Easing.OutCubic }
    }

    // Which of the three rows the page is, or null: an album, Settings or Now
    // Playing is none of them, and then the bar has nowhere to be.
    readonly property Item currentNavItem:
          currentPage === "home"       ? navHome
        : currentPage === "search"     ? navSearch
        : currentPage === "collection" ? navCollection
        : null

    // On screen at all, as one number, driving height as well as opacity: a
    // faint 3px bar reads as a smudge. Not readonly: a Behavior is a write
    // interceptor and cannot write through a read-only property.
    property real navPresence: currentNavItem !== null ? 1 : 0
    Behavior on navPresence {
        NumberAnimation { duration: Theme.dur(140); easing.type: Easing.OutCubic }
    }

    // Same gate as `slotSettled` above and for the same reason: the first
    // placement is an initialisation, not a move, and a bar that animates it
    // slides in from the top of the panel on every launch.
    property bool navSettled: false

    // Whether the bar was on a row when the page last changed. From a page that
    // is none of the three, the next row gets the bar in place, without travel.
    property bool navOnARow: false

    onCurrentNavItemChanged: {
        retargetNav(root.navSettled && root.visible && root.navOnARow)
        root.navOnARow = (root.currentNavItem !== null)
    }

    // `animate` false leaves navFrom at the destination, so nothing travels:
    // the first placement, any change while the sidebar is hidden (fullscreen),
    // and the row picked from a page that was on none.
    function retargetNav(animate) {
        var next = root.currentNavItem
        // Nothing is current: leave navTo where it is and let navPresence fade
        // the bar out on the row it was on, rather than parking it at the top.
        if (next === null || next === root.navTo) return
        root.navFrom = (animate && root.navTo !== null) ? root.navTo : next
        root.navTo   = next
        root.navResetting = true
        root.navT = 0
        root.navResetting = false
        root.navT = 1
    }

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

                AppMark {
                    id: mark
                    // 20 centres the 28px mark in the 68px rail and is also the
                    // sidebar's left inset, so it does not move between the two.
                    x: 20
                    width: 28
                    height: 28
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

            // Named, because the one indicator above asks a row where it is.
            // Three ids and not a Repeater: three pages with three glyphs make
            // a model of one-offs.
            SideNavItem {
                id: navHome
                icon: "home"
                label: qsTr("Home", "noun, the home page")
                page: "home"
                onActivated: root.navigate("home", {})
            }
            SideNavItem {
                id: navSearch
                icon: "search"
                label: qsTr("Search", "noun, the search page")
                page: "search"
                onActivated: root.navigate("search", {})
            }
            SideNavItem {
                id: navCollection
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
                Layout.leftMargin: Math.round(14 + 2 * root.wideness)
                Layout.rightMargin: Math.round(14 + 2 * root.wideness)
            }
            Item { Layout.fillWidth: true; Layout.preferredHeight: 14 }

            // ── the finder: search field plus type chips ─────────────────
            // The slot's height travels with the slide, so the list below does
            // not jump. The finder is scaled into the slot at its settled size:
            // resized, its icons would spill, as a Shape ignores `clip`.
            Item {
                id: finderSlot
                Layout.fillWidth: true
                Layout.leftMargin: 12
                Layout.rightMargin: 12
                Layout.preferredHeight: Math.round(finder.implicitHeight * root.wideness)

                LibraryFinder {
                    id: finder
                    objectName: "sidebarFinder"
                    // False at the rail, which also keeps a search field that
                    // is not on screen out of the tab order of a 68px strip.
                    visible: root.wideness > 0
                    opacity: root.wideOpacity
                    width: Math.max(1, root.expandedWidth - 24)
                    height: implicitHeight
                    transform: Scale {
                        origin.x: 0
                        origin.y: 0
                        xScale: finderSlot.width / finder.width
                        yScale: root.wideness
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                // 4 at the rail, 10 open: the gap grows with the finder rather
                // than appearing with it.
                Layout.preferredHeight: Math.round(4 + 6 * root.wideness)
            }

            // ── "New playlist" ────────────────────────────────────────────
            // At the head of the list it adds to and built like a library row:
            // same height and inset, a tile on the covers' centre line, a label
            // that fades in on `wideness`. At the rail it is a bare plus.
            Item {
                id: newPlaylistRow
                objectName: "sidebarNewPlaylist"
                Layout.fillWidth: true
                Layout.preferredHeight: root.libRowHeight
                activeFocusOnTab: true
                Keys.onReturnPressed: newPlaylistDialog.openEmpty()
                Keys.onSpacePressed:  newPlaylistDialog.openEmpty()

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin:  root.rowInset
                    anchors.rightMargin: root.rowInset
                    radius: Theme.radiusRow
                    color: newPlaylistHov.hovered ? Theme.surfaceHov : "transparent"
                    border.width: newPlaylistRow.activeFocus ? 2 : 0
                    border.color: Theme.accent

                    HoverHandler { id: newPlaylistHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler  { onTapped: newPlaylistDialog.openEmpty() }

                    // On the covers' centre line in both shapes, so nothing
                    // travels sideways. Outlined and smaller than a cover: a
                    // filled tile that size reads as a row without its picture.
                    Rectangle {
                        id: plusTile
                        objectName: "sidebarNewPlaylistTile"
                        width: 26
                        height: 26
                        x: Math.round(root.coverLeft + (root.coverSize - width) / 2)
                           - root.rowInset
                        anchors.verticalCenter: parent.verticalCenter
                        radius: Theme.radiusArt
                        color: "transparent"
                        border.width: 1
                        border.color: newPlaylistHov.hovered ? Theme.accent : Theme.border

                        VectorIcon {
                            anchors.centerIn: parent
                            name: "plus"
                            width: 13
                            height: 13
                            strokeWidth: 1.8
                            color: newPlaylistHov.hovered ? Theme.accent : Theme.textDim
                        }
                    }

                    Text {
                        objectName: "sidebarNewPlaylistLabel"
                        visible: root.showsWide
                        opacity: root.wideOpacity
                        anchors.left: plusTile.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("New playlist")
                        color: newPlaylistHov.hovered ? Theme.textPrimary : Theme.textSec
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }

                    // No tooltip: pointing at the rail already brings the full
                    // sidebar out, and the label arrives before a tooltip delay
                    // would arm.
                }
            }

            // ── the library list ─────────────────────────────────────────
            // One list in both shapes of the sidebar. The cover is the same
            // item at the same size and only its x travels. Nothing below
            // switches on `expanded`; it all lerps off `wideness`.
            ListView {
                id: libList
                objectName: "sidebarLibraryList"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                bottomMargin: 8
                model: libModel
                // This list draws no selection, but a ListView still builds a
                // highlight item and smooth-resizes it toward the current row,
                // hanging out of the rail meanwhile. Untracked it stays 0 wide.
                highlightFollowsCurrentItem: false
                // A library can run to thousands of rows, so nothing outside
                // the viewport is kept alive.
                cacheBuffer: 240
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: LibraryRow { }

                // Only y is animated, on `move` and `displaced`. `add` fades:
                // an arriving row has no previous place. No `remove`: it would
                // keep the delegate alive, and the closing gap says enough.
                move: Transition {
                    ScriptAction { script: root.libraryMoves++ }
                    NumberAnimation {
                        properties: "y"
                        duration: Theme.dur(root.libraryTravelMs)
                        easing.type: Easing.OutCubic
                    }
                }
                displaced: Transition {
                    ScriptAction { script: root.libraryMoves++ }
                    NumberAnimation {
                        properties: "y"
                        duration: Theme.dur(root.libraryTravelMs)
                        easing.type: Easing.OutCubic
                    }
                }
                // Not while the finder is filtering: a query replaces most of
                // the list on every keystroke, and a fade restarting that often
                // reads as flicker.
                add: Transition {
                    enabled: !root.searching
                    NumberAnimation {
                        property: "opacity"
                        from: 0; to: 1
                        duration: Theme.dur(140)
                        easing.type: Easing.OutCubic
                    }
                }

                // Where the dragged row will land. A child of the list is
                // parented to the content item, so this is positioned in
                // content coordinates however far the list is scrolled.
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
                    // There is no room to say any of this in a 68px rail, and
                    // an empty rail is self-explanatory.
                    visible: root.rows.length === 0 && root.showsWide
                    opacity: root.wideOpacity
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.searching ? qsTr("No matches") : qsTr("Nothing saved yet")
                    color: Theme.textDim
                    font.pixelSize: 12
                }
            }
        }

        // ── footer: one row, which is the Settings button ──────────────
        // The whole row opens Settings, with the account name as its second
        // line. No avatar: the person drawing is the `artist` glyph, so a
        // person here would read as an artist row.
        Rectangle {
            id: footer
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 56
            color: Theme.surfaceHigh

            Item {
                id: settingsRow
                objectName: "sidebarSettingsRow"
                anchors.fill: parent
                anchors.margins: 6

                activeFocusOnTab: true
                Keys.onReturnPressed: root.openSettings()
                Keys.onSpacePressed:  root.openSettings()

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 2
                    anchors.rightMargin: 2
                    radius: Theme.radiusRow
                    color: settingsHover.hovered ? Theme.hoverFill : "transparent"
                    border.width: settingsRow.activeFocus ? 2 : 0
                    border.color: Theme.accent

                    VectorIcon {
                        id: gearItem
                        objectName: "sidebarSettingsGear"
                        name: "settings"
                        color: settingsHover.hovered ? Theme.textPrimary : Theme.textSec
                        width: 18
                        height: 18
                        strokeWidth: 1.8
                        anchors.verticalCenter: parent.verticalCenter
                        // 16 from the panel edge once open, centred in the
                        // rail, travelling on `wideness`. The row's own 8px of
                        // inset comes off the open position.
                        readonly property real railX:
                            Math.round((root.railWidth - 16 - width) / 2)
                        x: Math.round(railX + (8 - railX) * root.wideness)
                    }

                    Column {
                        objectName: "sidebarSettingsLabels"
                        visible: root.showsWide
                        opacity: root.wideOpacity
                        anchors.left: gearItem.right
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            objectName: "sidebarSettingsLabel"
                            width: parent.width
                            // qsTranslate, not qsTr: this is the word the
                            // Settings panel heads itself with, so the
                            // catalogue holds it once.
                            text: qsTranslate("SettingsPanel", "Settings")
                            color: Theme.textPrimary
                            font.pixelSize: 14
                            elide: Text.ElideRight
                        }
                        Text {
                            id: acctNameText
                            objectName: "sidebarAccountName"
                            width: parent.width
                            // Auth::displayNameFrom already picks the
                            // username over the email address.
                            text: auth.username.length > 0 ? auth.username
                                                           : qsTr("My Account")
                            color: Theme.textSec
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                    }

                    HoverHandler { id: settingsHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler   { onTapped: root.openSettings() }

                    // In the rail the labels are not on screen, so this is the
                    // only place the row says what it is.
                    ToolTip.visible: settingsHover.hovered
                    ToolTip.text: qsTr("Settings (Ctrl+,)")
                    ToolTip.delay: 450
                }
            }
        }

        // ── the one nav indicator ─────────────────────────────────────
        // A child of the panel and not of a row: a bar that belongs to a row
        // can only appear and disappear with it. x is 0, the panel's left edge
        // in both shapes, so nothing here changes with the rail.
        Rectangle {
            id: navMark
            objectName: "navCurrentIndicator"
            x: 0
            width: 3
            radius: 2
            color: Theme.accent
            opacity: root.navPresence
            visible: opacity > 0.001

            // The two ends of the travel, in the panel's coordinates. `body.y`
            // and not mapFromItem(): a function call is read once, and this
            // must follow the rows. Half the row's inner box tall.
            readonly property real fromH: root.navFrom ? Math.round((root.navFrom.height - 4) * 0.5) : 0
            readonly property real toH:   root.navTo   ? Math.round((root.navTo.height   - 4) * 0.5) : 0
            readonly property real fromY: root.navFrom ? body.y + root.navFrom.y + root.navFrom.height / 2 : 0
            readonly property real toY:   root.navTo   ? body.y + root.navTo.y   + root.navTo.height   / 2 : 0

            height: Math.round((fromH + (toH - fromH) * root.navT) * root.navPresence)
            y: Math.round(fromY + (toY - fromY) * root.navT - height / 2)
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

    // ── the border is the resize handle ──────────────────────────────────

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
        // Identity: every kind the library lists is also a name VectorIcon
        // draws. Kept as a function because tests/qml/tst_sidebar.qml asserts
        // the badges against it.
        return kind
    }

    // Opens one library row. `data` is the row as LibraryIndex handed it over.
    // Opening is not playing: recording a play is the player bar's job, off
    // player.sourceChanged.
    function open(kind, id, data) {
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
                coverUrl: data.imageUrl || "",
                // Which kind of mix, so a saved track radio opens under the
                // heading "Radio" from the first frame instead of flipping from
                // "Mix" when the page's own request lands.
                mixType:  data.mixType || ""
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

    SettingsPanel { id: settingsPopup }

    // Nothing is done with the answer here: the bridge raises playlistCreated,
    // LibraryIndex adds the row and it arrives through `library.entries` like
    // every other. The alias is a test's only handle on the reparented Popup.
    readonly property alias playlistDialog: newPlaylistDialog

    NewPlaylistDialog { id: newPlaylistDialog }

    // ── inline components ────────────────────────────────────────────────

    // One row of the library list, in both shapes of the sidebar. The cover is
    // the same item at the same size in the rail and beside a title, and only
    // its x travels.
    component LibraryRow : Item {
        id: rowItem
        objectName: "libraryRow"

        required property int index
        // The `entry` role of libModel, which holds the whole library row.
        // Everything below, and the sidebar's tests, read it through
        // `modelData`.
        required property var entry
        readonly property var modelData: entry

        readonly property string kind:   modelData.kind
        readonly property string itemId: modelData.id
        readonly property string title:  modelData.title
        readonly property bool   pinned: modelData.pinned === true
        readonly property bool   hasArt: (modelData.imageUrl || "").length > 0

        // The break between the pinned block and the rest; search results have
        // no pinned block. The row above is read out of `rows` and guarded: a
        // rebuild writes `rows` before it reorders the model.
        readonly property bool blockBreak: {
            if (root.searching || index <= 0 || pinned) return false
            var above = root.rows[index - 1]
            return above !== undefined && above.pinned === true
        }

        // Nothing to reorder in a block of one, and nothing outside the block
        // is draggable. The rail has no room for a grip, so the handle exists
        // only once the labels do.
        readonly property bool draggable: pinned && !root.searching
                                          && root.pinnedCount > 1 && root.showsWide
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
            height: 1
            color: Theme.border
            // One rule for both shapes: it hugs the covers at the rail and
            // stretches across the row as the panel opens.
            readonly property real railW: root.coverSize + 2
            readonly property real railX: Math.round((root.railWidth - railW) / 2)
            x: Math.round(railX + (root.coverLeft - railX) * root.wideness)
            width: Math.max(1, Math.round(
                       railW + (rowItem.width - 2 * root.coverLeft - railW) * root.wideness))
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: root.rowInset
            anchors.rightMargin: root.rowInset
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

            // Right button only, so the tap handler above keeps every
            // left-click. Declared before the cover and the grip, so a
            // right-click over either falls through to here.
            MouseArea {
                objectName: "libraryRowMenuArea"
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: function (mouse) {
                    var p = mapToItem(root, mouse.x, mouse.y)
                    root.showPinMenu(p.x, p.y, rowItem.modelData)
                }
            }

            Rectangle {
                id: cover
                // Every row's cover, in both shapes of the sidebar. The name is
                // the one tests/qml/tst_pinning.qml reaches for.
                objectName: "railPinCover"
                // Centred in the rail, at the row's content inset once open.
                // Both are measured from the panel, so the row's own inset
                // comes back off again. Same item, same size, only the x.
                readonly property real railX: Math.round((root.railWidth - root.coverSize) / 2)
                                              - root.rowInset
                readonly property real wideX: root.coverLeft - root.rowInset
                x: Math.round(railX + (wideX - railX) * root.wideness)
                anchors.verticalCenter: parent.verticalCenter
                width: root.coverSize
                height: root.coverSize
                radius: Theme.radiusArt
                color: Theme.surfaceHigh
                clip: true

                Image {
                    objectName: "libraryRowArt"
                    anchors.fill: parent
                    // On whether the row *has* artwork, not on whether it has
                    // arrived: a tile that only appears once the network
                    // answers is another thing popping in.
                    visible: rowItem.hasArt
                    source: rowItem.hasArt ? "image://tidal/" + rowItem.modelData.imageUrl : ""
                    // Decoded at twice the box, not the 320 the URL serves.
                    // Both dimensions: width alone reaches the provider as
                    // 72x0. Safe on a crop as every URL in this list is square.
                    sourceSize: Qt.size(root.coverSize * 2, root.coverSize * 2)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    opacity: status === Image.Ready ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(140) } }
                }

                // The type. One glyph either way, a corner mark over artwork or
                // the whole tile without it, so a row costs one glyph in a
                // virtualised list of thousands.
                Rectangle {
                    objectName: "libraryRowTypeBadge"
                    visible: rowItem.hasArt
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin:  root.coverBadgeInset
                    anchors.bottomMargin: root.coverBadgeInset
                    width:  root.coverBadge
                    height: root.coverBadge
                    radius: Theme.radiusBadge
                    color: Theme.surface
                }

                VectorIcon {
                    objectName: "libraryRowIcon"
                    name: root.glyphFor(rowItem.kind)
                    width:  rowItem.hasArt ? root.coverBadgeIcon : root.coverPlainIcon
                    height: width
                    strokeWidth: rowItem.hasArt ? 1.5 : 1.6
                    color: rowItem.pinned ? Theme.accent : Theme.textDim
                    // Centred in the badge, which is itself held off the
                    // corner. One item drawn in two places, so a row costs one
                    // glyph.
                    readonly property int badgePad: Math.round((root.coverBadge - width) / 2)
                                                    + root.coverBadgeInset
                    x: rowItem.hasArt ? parent.width - width - badgePad
                                      : Math.round((parent.width - width) / 2)
                    y: rowItem.hasArt ? parent.height - height - badgePad
                                      : Math.round((parent.height - height) / 2)
                }

                // A pinned cover keeps its ring; in the rail nothing else tells
                // it apart. Drawn as the last child: a Rectangle paints its own
                // border under its children, and the art fills the box.
                Rectangle {
                    objectName: "libraryRowRing"
                    anchors.fill: parent
                    visible: rowHov.hovered || rowItem.pinned
                    color: "transparent"
                    radius: parent.radius
                    border.width: rowHov.hovered ? 2 : 1
                    border.color: Theme.accent
                    antialiasing: true
                }
            }

            Text {
                id: rowTitle
                objectName: "libraryRowTitle"
                visible: root.showsWide
                opacity: root.wideOpacity
                anchors.left: cover.right
                anchors.leftMargin: 10
                anchors.right: parent.right
                // The grip's space is reserved whether or not it is showing,
                // so the title does not jump when the pointer arrives.
                anchors.rightMargin: rowItem.draggable ? 28 : 10
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.title
                color: Theme.textSec
                font.pixelSize: 13
                elide: Text.ElideRight
            }

            // The drag affordance, drawn on every pinned row and not on hover
            // alone, so the block says it can be reordered.
            Item {
                id: grip
                objectName: "pinDragGrip"
                visible: rowItem.draggable
                opacity: root.wideOpacity
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
                    anchors.margins: -5          // 16 wide is a small target
                    enabled: rowItem.draggable
                    cursorShape: rowItem.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    // Otherwise the list reads the vertical drag as a flick
                    // and takes the grab away mid-reorder.
                    preventStealing: true

                    // Where the press landed, in the list's content
                    // coordinates, which do not move when the list scrolls.
                    property real pressY: 0

                    onPressed: function (mouse) {
                        dragArea.pressY = mapToItem(libList.contentItem,
                                                    mouse.x, mouse.y).y
                        root.beginPinDrag(rowItem.index)
                    }
                    onPositionChanged: function (mouse) {
                        if (!rowItem.dragging) return
                        // The event arrives in the handle's own moving
                        // coordinates; mapToItem puts the pointer back into the
                        // list's content space.
                        var p = mapToItem(libList.contentItem, mouse.x, mouse.y)
                        root.pinDragOffset = p.y - dragArea.pressY
                        root.pinDragTo     = root.pinSlotAt(rowItem.index, root.pinDragOffset)
                        // Confined to the pinned block: the row decides whether
                        // it is still over the block, the pointer whether it
                        // has left the sidebar sideways.
                        root.pinDropValid  =
                            root.pinOverBlock(rowItem.index, root.pinDragOffset)
                            && p.x >= 0 && p.x <= libList.width
                    }
                    onReleased: root.endPinDrag()
                    onCanceled: root.cancelPinDrag()
                }
            }

            // On every row, not only the truncated ones: in the rail the
            // title is not on screen at all, so this is the only place the
            // name is said.
            ToolTip.visible: rowHov.hovered && !rowItem.dragging
            ToolTip.text: subtitleOf.length > 0 ? rowItem.title + " · " + subtitleOf
                                                : rowItem.title
            ToolTip.delay: 450
            readonly property string subtitleOf: rowItem.modelData.subtitle || ""
        }
    }

    // A nav row. In the rail it is the icon alone, centred; expanded it gains
    // its label. Same item either way, so the switch is a slide, not a swap.
    component SideNavItem : Item {
        id: navItem
        objectName: "sideNavItem"
        property string icon: ""
        property string label: ""
        property string page: ""
        signal activated()

        readonly property bool current: root.currentPage === page

        // The row's fill and ink cross-fade on the bar's 140ms. They stay
        // per-row: the current fill is the hover fill, and one travelling fill
        // could not also be under the pointer. See navMark.
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
            Behavior on color { ColorAnimation { duration: Theme.dur(140) } }
            border.width: navItem.activeFocus ? 2 : 0
            border.color: Theme.accent

            NavIcon {
                id: navGlyph
                objectName: "navIcon"
                name: navItem.icon
                color: navItem.current ? Theme.accent : Theme.textSec
                Behavior on color { ColorAnimation { duration: Theme.dur(140) } }
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
                Behavior on color { ColorAnimation { duration: Theme.dur(140) } }
                font.pixelSize: 14
                // Not animatable: a font weight is not a number Qt interpolates.
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
