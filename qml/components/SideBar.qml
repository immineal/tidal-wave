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
// the layout gives it (rail-wide while compact) and `panel` inside it is free
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

    // What the layout must reserve, which is *not* always what the panel draws:
    // that difference is the overlay, and only the overlay.
    //
    // This used to be `compact ? railWidth : expandedWidth`, which jumped to
    // the full width the instant `compact` went false while the panel spent
    // 170ms animating into that slot. For those frames the slot was wider than
    // the panel and the difference painted the page ground: a bar of empty page
    // where the sidebar was about to be (QA: "it reserves its space and for a
    // few milliseconds there's a black bar where it will expand to").
    //
    // Following `panelWidth` removes the gap by construction rather than by
    // suppressing the animation, and it means the page's left edge travels with
    // the sidebar instead of jumping ahead of it. The relayout that costs is
    // only ever during a breakpoint crossing, which is a window resize that is
    // relaying the page out anyway.
    //
    // The compact branch is the rail width and not `overlaying ? ...`, which
    // was the first attempt: `overlaying` goes false the instant the pointer
    // leaves the rail, while the panel still has 170ms of collapsing to do, so
    // the slot would have jumped out to the panel's full width and the page
    // would have flinched inwards and back on every un-hover. Below the
    // breakpoint the slot is the rail, always; the panel overflowing it is the
    // overlay, in both directions.
    //
    // It reads `expandedWidth` and animates, rather than reading `panelWidth`
    // and inheriting its animation, because that version was smooth in one
    // direction only (QA: "when the sidebar collapses because of window
    // resizing, the main content just teleports, but when it expands back out
    // again it animates smoothly"). Expanding, `compact` went false while
    // panelWidth was still the rail, so the slot picked up the rail width and
    // rode the panel out. Collapsing, `compact` went true and the slot fell
    // straight to railWidth from a panel that still had 170ms to travel - the
    // page jumped in one frame and the sidebar caught up with it afterwards.
    //
    // Both ends now animate on the same duration and easing, flipped by the
    // same `compact` in the same frame, so the two stay locked together during
    // a breakpoint crossing. They come apart only when they should: hovering
    // the rail re-targets the panel to full width while `compact` holds the
    // slot at the rail, which is exactly what makes the hover an overlay.
    property int reservedWidth: compact ? railWidth : expandedWidth
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
    // finishes; it just finishes in the frame it started.
    Behavior on panelWidth {
        enabled: !dragHandle.dragging
        NumberAnimation { duration: Theme.dur(170); easing.type: Easing.OutCubic }
    }

    // The slot does not animate until the window has said how wide it is.
    // `hostWidth` comes from Window.width, which the platform delivers on its
    // own schedule, so the first evaluation runs at 0 - and `compact` reads a
    // zero width as "not compact". The correction that lands a frame later is a
    // real binding change, not an initialisation, so without this gate every
    // narrow window would open by sliding the whole page across from the full
    // panel width down to the rail. It also broke two sidebar tests, which
    // measured the geometry before that phantom slide had finished.
    //
    // Qt.callLater rather than setting it inline: it runs after the bindings
    // this same change is about to re-evaluate, so the first, corrective jump
    // is still instant and only the moves after it travel.
    property bool slotSettled: false
    onHostWidthChanged: {
        if (hostWidth > 0 && !slotSettled)
            Qt.callLater(function () { root.slotSettled = true })
    }

    // Same curve and same duration as the panel's, deliberately: a breakpoint
    // crossing moves both, and two animations that differ by a frame or an
    // easing would show as the page ground tearing away from the sidebar's
    // edge. Dragging bypasses it for the reason above - a drag is a stream of
    // widths, and animating each one makes the page lag the pointer.
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
        // Filtered by the index rather than here. The `entries` property holds
        // the four browsable kinds and deliberately leaves songs out - there
        // are thousands of them and they would bury everything else - so
        // filtering it in QML could never answer the Tracks chip, which showed
        // "Nothing saved yet" while the same chip worked as soon as anything
        // was typed. entriesForKinds() knows about the track entries too.
        syncRows(library.entriesForKinds(finder.kinds || []))
    }

    // ── the same rows, as a model the view can animate ───────────────────
    //
    // `rows` is the array; `libModel` is what the ListView binds to. The two
    // hold the same entries in the same order, and the only reason there are
    // two is motion.
    //
    // A ListView over a JS array has no change set to work from: assigning a
    // new array is a model *reset*, which throws every delegate away and
    // builds it again. Probed on Qt 6.12 - reordering a five-item array fires
    // `populate` five times and `move`/`displaced` not once - so a row that
    // changes tier because it was pinned, played or liked teleports to its new
    // place. Feeding the same rows through a ListModel turns one pin into one
    // move() on the model, which the view *can* animate.
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

    // The smallest remove/move/insert list that turns `oldKeys` into
    // `newKeys`, or null when it would take more than `cap` of them.
    //
    // Planned against a copy of the keys before anything touches the model,
    // so the decision to give up and rebuild wholesale is made before the
    // first op rather than halfway through. Past the cap the rows have little
    // to do with each other anyway - a finder query replacing the whole list,
    // not a pin changing one row's tier - and walking them one at a time would
    // cost more than it could show.
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
    // is up. `null` when there are none.
    //
    // The library arrives in pages over several seconds, and a page landing
    // under a live drag is a refill and not a handful of moves: past the diff's
    // cap above, syncRows() gives up and rebuilds the model wholesale, which is
    // libModel.clear(). That releases every delegate, including the one holding
    // the pointer grab, and a broken grab is onCanceled - so the drag the user
    // is in the middle of ends with nothing said and nothing moved.
    //
    // Found under load and not before it. Unloaded, the released delegates are
    // still waiting on deleteLater when the drop arrives and the gesture
    // survives by luck, which is why the test for this passes either way on an
    // idle box; with eight spinners on twelve cores, and a drag already made in
    // the same process, it failed ten times out of ten. Held for the length of a
    // drag instead, which is well under a second, and applied the moment the
    // pointer comes up.
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

        // The plan is only as good as the keys being unique. Two rows that
        // answer to the same key - which a payload missing both kind and id
        // would do - collapse into one entry in the lookups above and leave the
        // model a different length from `rows`, which from then on would draw
        // one row's content under another row's index. Rebuilt outright
        // instead, which cannot be wrong even when the keys are.
        if (libModel.count !== next.length) {
            fillLibModel(next, newKeys)
            return
        }

        // Every rebuild hands over fresh objects, and a row that kept its key
        // can still have changed: `pinned` flips, a title or a cover url
        // arrives. So the rows that did not move are handed the new entry too.
        for (i = 0; i < next.length; ++i) libModel.setProperty(i, "entry", next[i])
    }

    // How long a row takes to travel to its new place.
    readonly property int libraryTravelMs: 170

    // How many rows have been asked to travel since the sidebar was built. A
    // ListView says nothing about its own transitions, and whether a reorder
    // was animated or merely redrawn is the thing the sidebar's tests are
    // about.
    //
    // It only ever goes up, deliberately. The first version of this was a
    // "still moving" flag, and a flag is a transient: tests/qml/tst_reduced_
    // motion.qml polls at 50ms, and on a machine running four test processes
    // at once a poll interval ran long enough for a 170ms travel to start and
    // finish between two of them - the reorder had animated and the test read
    // "it did not", four times out of four. A count cannot be stepped over.
    //
    // A counted-in/counted-out pair would not do either: a ViewTransition the
    // view *cancels*, which is what a second reorder arriving inside the first
    // one does, drops the rest of its animation, so a trailing ScriptAction
    // never runs. Probed on Qt 6.12: three reorders 40ms apart left such a
    // counter stuck at 10 with everything long since settled.
    property int libraryMoves: 0

    // One list in both shapes of the sidebar means one model, so a query or a
    // chip left behind would go on filtering a rail that has no finder on
    // screen to explain itself. Clearing it as the panel closes is also what
    // keeps the model still during the slide: a new model would throw the
    // delegates away, and the covers are supposed to travel, not be rebuilt.
    onExpandedChanged: if (!expanded) finder.reset()

    // ── the pinned block, and dragging inside it (P3, P4) ────────────────

    // The height of one library row, which is also the height of one slot in
    // the pinned block, so the drag can work in whole rows. Everything the
    // drag does -- which slot the pointer is over, how far down the block
    // still counts, where the drop indicator sits -- is expressed as a
    // multiple of this, so the three of them follow it rather than being
    // retuned every time the row changes height.
    readonly property int libRowHeight: 44

    // ── the cover, which is one cover in both shapes (S9, amended) ───────
    //
    // The rail used to draw its own 40px covers and the open sidebar its own
    // type glyphs, and the two swapped. One size, one item, one list now.
    //
    // It was 26, which left the corner type badge too small to read: a 13px
    // chip holding a 9px glyph, which is the whole reason the badge exists.
    // At 36 the badge is 18 and its glyph 12, which is legible, and the cover
    // still leaves 4px of air above and below inside the row -- the same
    // rhythm 26-in-34 had -- and still centres in the 68px rail with 16
    // either side.
    readonly property int coverSize: 36
    // Derived, so the next time the cover moves these move with it instead of
    // being three more numbers to find.
    readonly property int coverBadge:     Math.round(coverSize * 0.5)
    readonly property int coverBadgeIcon: Math.round(coverSize / 3)
    // How far the badge is held off the cover's right and bottom edges.
    //
    // Flush, it left a speck. A cover's corner is round and a badge's corner
    // is round by a different amount, so where the two met a crescent of the
    // cover showed past the badge and read as a stray pixel rather than as an
    // edge. Worse with artwork on it: an Image is clipped to its parent's
    // bounding box and never to its rounded outline, so the art reaches the
    // square corner the badge's arc has already curved away from.
    //
    // Holding the badge inside the corner sidesteps the whole question --
    // there is no join to get wrong, only a margin, and the same margin on
    // both sides reads as deliberate. Clipping the badge to the cover's shape
    // would not have worked: QQuickShape ignores an ancestor's clip in Qt
    // 6.12, which is the wall the finder's reveal hit, so the glyph inside
    // the badge would have gone on painting into the corner anyway.
    //
    // Derived like the rest of this block, with a floor of 2: below that the
    // margin stops being a margin and the speck comes back.
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
        // Read before the drag state is cleared, because clearing it releases
        // any rows held during the drag and `rows` is what that rewrites. These
        // two are the rows the gesture was made over, which is what it has to be
        // answered in.
        var a = root.rows[from]
        var b = root.rows[to]
        cancelPinDrag()
        if (!ok || from < 0 || to < 0 || from === to) return
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
                Layout.leftMargin: Math.round(14 + 2 * root.wideness)
                Layout.rightMargin: Math.round(14 + 2 * root.wideness)
            }
            Item { Layout.fillWidth: true; Layout.preferredHeight: 14 }

            // ── the finder: search field plus type chips (S5, S8) ────────
            //
            // The slot's *height* travels with the slide rather than switching
            // on at a threshold. The list underneath is now the same list the
            // rail shows, so a block that appeared above it at full height
            // would shove those covers down a step in the middle of a move
            // that is supposed to be smooth.
            //
            // The finder itself is laid out at the size it will settle at and
            // *scaled* into that slot, which is not the obvious way round.
            // Resizing it to the slot instead would leave its content hanging
            // out of it, and that content cannot be cut off: a Shape ignores
            // an ancestor's `clip`, and the magnifier and all five chips are
            // VectorIcons, i.e. Shapes. They would spill over the library list
            // below and past the panel's edge for the length of every slide.
            // Five chips also want 166px of finder, which is the whole reason
            // Prefs::minSidebarWidth is 190, and the panel passes through
            // every width under that on its way open. Scaling has nothing to
            // spill, and at rest both scales are 1, so the settled sidebar is
            // laid out exactly as it was.
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

            // ── the library list (S1, S2, S9) ────────────────────────────
            //
            // One list, in both shapes of the sidebar. It used to be two: a
            // strip of 40px covers for the rail and a list of type glyphs and
            // titles for the open sidebar, swapped at a threshold partway
            // through the slide. That swap is what the user saw - the covers
            // blinked out and the text blinked in, in the middle of an
            // animation whose whole point was continuity.
            //
            // Now the row reflows instead. The cover is the same item at the
            // same size throughout and only its x travels; the title, the
            // finder and the chips fade in around it. Nothing below switches
            // on `expanded`: it all lerps off `wideness`, which the panel's
            // own width animation drives, so there is one clock.
            ListView {
                id: libList
                objectName: "sidebarLibraryList"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                bottomMargin: 8
                model: libModel
                // This list draws no selection, but a ListView builds a
                // default highlight item regardless and then *smooth-resizes*
                // it toward the current row: an empty Item that paints
                // nothing, trails the panel's width by a few hundred
                // milliseconds and hangs out of a 68px rail the whole time it
                // is catching up. Left untracked it stays 0 wide and costs
                // nothing, which is what a highlight nobody draws should cost.
                highlightFollowsCurrentItem: false
                // A library can run to thousands of rows, so nothing outside
                // the viewport is kept alive.
                cacheBuffer: 240
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: LibraryRow { }

                // S4/P3: the list reorders under the user constantly - pinning
                // moves a row to the top, playing or liking something moves it
                // up a tier - and until these the new order simply appeared.
                //
                // Only y is animated, and only on `move` and `displaced`: the
                // row that was asked to move travels, and the rows it pushed
                // past travel with it. `add` fades instead, because a row
                // arriving has no previous place to travel from. There is no
                // `remove` transition on purpose: a removed row's delegate
                // would stay alive for the length of it, and the gap closing
                // under `displaced` already says the row is gone.
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
                // Not while the finder is filtering. A query replaces most of
                // the list on every keystroke, and a fade that restarts from
                // zero that often reads as the list flickering rather than as
                // rows arriving.
                add: Transition {
                    enabled: !root.searching
                    NumberAnimation {
                        property: "opacity"
                        from: 0; to: 1
                        duration: Theme.dur(140)
                        easing.type: Easing.OutCubic
                    }
                }

                // P4: where the dragged row will land. Declared inside the
                // list, which parents it to the content item, so it is
                // positioned in content coordinates and points between the
                // same two rows however far the list is scrolled. Only ever
                // live while the sidebar is open, which is the only state a
                // drag can start in.
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

        // ── footer: one row, which is the Settings button (S10) ────────
        //
        // The whole row opens Settings, with the account name as its second
        // line. It used to be an inert username with a gear button beside it,
        // which gave the row two meanings and only one of them a target.
        //
        // Deliberately no avatar. The person drawing is the `artist` glyph
        // now, so a person down here would read as an artist row; the avatar
        // was taken out once already and this keeps it out.
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

                // Treated as what it now is: a full-width row that does
                // something, like the nav rows above it.
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
                        // rail, and travelling between the two on the same
                        // `wideness` as every other icon in the sidebar. The
                        // row's own 8px of inset comes off the open position.
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
                            // qsTranslate rather than qsTr: this is the same
                            // word the Settings panel heads itself with, and
                            // a second entry in a finished catalogue would
                            // only be the same translation typed twice.
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

                    // In the rail the labels are not on screen, so this is
                    // the only place the row says what it is; the shortcut
                    // rides along, as it did on the gear.
                    ToolTip.visible: settingsHover.hovered
                    ToolTip.text: qsTr("Settings (Ctrl+,)")
                    ToolTip.delay: 450
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
        // Identity, now that a song has a glyph of its own: every kind the
        // library lists is also a name VectorIcon draws. It stays a function
        // because it is the one place that says so, and because the badges
        // are asserted against it in tests/qml/tst_sidebar.qml.
        return kind
    }

    // Opens one library row. `data` is the row as LibraryIndex handed it over.
    //
    // Opening is not playing. This used to call library.markPlayed() here, so
    // merely clicking a row floated it into the recently-played tier and the
    // top of the sidebar filled up with things the user had looked at and not
    // listened to. Recording a play is the player bar's job and only the player
    // bar's - it listens to player.sourceChanged, which fires when something
    // actually starts - so there is nothing to do here but navigate.
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

    // One row of the library list, in both shapes of the sidebar. The cover is
    // the whole of why this is one component and no longer two: it is the same
    // item at the same size in the rail and beside a title, and only its x
    // travels, so opening the sidebar moves it instead of destroying it and
    // building something else in its place.
    component LibraryRow : Item {
        id: rowItem
        objectName: "libraryRow"

        required property int index
        // The `entry` role of libModel, which holds the whole library row.
        // Kept under the old name as well: everything below, and the sidebar's
        // tests, read the row through `modelData`.
        required property var entry
        readonly property var modelData: entry

        readonly property string kind:   modelData.kind
        readonly property string itemId: modelData.id
        readonly property string title:  modelData.title
        readonly property bool   pinned: modelData.pinned === true
        readonly property bool   hasArt: (modelData.imageUrl || "").length > 0

        // The break between the pinned block and the rest (P3/P5). Search
        // results have no pinned block, so they have nothing to break.
        //
        // The row above is read out of `rows` rather than out of the model,
        // and guarded: a rebuild writes `rows` before it reorders the model,
        // so for the rest of that call a delegate can still be sitting on an
        // index the new rows do not reach.
        readonly property bool blockBreak: {
            if (root.searching || index <= 0 || pinned) return false
            var above = root.rows[index - 1]
            return above !== undefined && above.pinned === true
        }

        // P4. There is nothing to reorder in a block of one, and nothing
        // outside the block is draggable at all, which is half of why a
        // pinned row cannot end up in the list below. A 68px rail has no room
        // for a grip either, so the handle only exists once the labels do.
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
            // One rule doing what the rail's short dash and the open list's
            // full-width line used to do separately: it hugs the covers at the
            // rail and stretches across the row as the panel opens.
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

            // P2. Right button only, so the tap handler above keeps every
            // left-click; declared before the cover and the grip so a
            // right-click over either still opens the menu. Neither of those
            // takes mouse events, so the clicks fall through to here.
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
                // Named for the rail it used to belong to, which is the name
                // tests/qml/tst_pinning.qml still reaches for. It is every
                // row's cover now, in both shapes of the sidebar.
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
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    opacity: status === Image.Ready ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(140) } }
                }

                // The type, which the row no longer spells out beside the
                // title now that the cover has that place. One glyph either
                // way - a corner mark over artwork, the whole tile without it
                // - so a row costs exactly what it cost before. That matters:
                // the list is virtualised over libraries of thousands and the
                // spec stress-tests it.
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
                    // corner, so the glyph clears the cover's edge by the
                    // badge's own padding plus that inset. One item drawn in
                    // two places rather than two items, which is what keeps a
                    // row costing one glyph however long the library is.
                    readonly property int badgePad: Math.round((root.coverBadge - width) / 2)
                                                    + root.coverBadgeInset
                    x: rowItem.hasArt ? parent.width - width - badgePad
                                      : Math.round((parent.width - width) / 2)
                    y: rowItem.hasArt ? parent.height - height - badgePad
                                      : Math.round((parent.height - height) / 2)
                }

                // A pinned cover keeps its ring wherever the break above has
                // scrolled to, and in the rail it is the only thing left to
                // tell it apart in a strip of bare artwork.
                //
                // Drawn here, as the cover's last child, rather than as the
                // cover's own `border`: a Rectangle paints its border under
                // its own children, and the artwork fills the whole box, so
                // on every row that had a cover the ring was painted and then
                // covered over. It was only ever visible on rows with no art.
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

            // P4: the drag affordance. Drawn on every pinned row rather than
            // on hover alone, so the block says it can be reordered before
            // anyone goes looking.
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

                    // The same press, in the pinned block's own grid: whole
                    // rows down from the top of the list, which is what
                    // pinSlotAt() counts in and what the bounds below are
                    // measured against.
                    //
                    // The two are the same number at rest and not during a
                    // reorder. The move and displaced transitions on the list
                    // take libraryTravelMs to carry a row to its new place, and
                    // for that long a row's `index` is already the new one while
                    // its `y` is still the old one. Everything else here works
                    // in indices -- `pinDragFrom` is an index, pinSlotAt()
                    // returns one -- so taking the bounds from the drawn
                    // position alone mixed the two frames, and a drag begun
                    // inside that window was measured as travelling out of the
                    // block and abandoned on release. Which is every drag made
                    // in the moment after the last one: one drop starts the
                    // travel that breaks the next.
                    property real pressSlotY: 0

                    onPressed: function (mouse) {
                        var p = mapToItem(libList.contentItem, mouse.x, mouse.y)
                        dragArea.pressY = p.y
                        // Where in the row the press landed -- which is a
                        // reading off the row as *drawn*, and the only one of
                        // the two that is -- carried over to the slot the row's
                        // index says it occupies. Every pinned row is
                        // libRowHeight tall: only the first unpinned row carries
                        // the block break, and nothing outside the block is
                        // draggable.
                        dragArea.pressSlotY = rowItem.index * root.libRowHeight
                                              + (p.y - rowItem.y)
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
                        var slotY = dragArea.pressSlotY + root.pinDragOffset
                        root.pinDropValid  = slotY >= 0
                            && slotY < root.pinnedCount * root.libRowHeight
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

        // The highlight arriving, as one number the whole row reads. 140ms is
        // the sidebar's own short end - the rail slide and a row's travel are
        // 170 - because this is the smallest thing in the panel that moves and
        // it moves on every click.
        //
        // A number and not three Behaviors because of the indicator: it used to
        // be `visible: current`, and a visible flip has nothing to animate, so
        // the one part of the highlight that reads as a position had none. The
        // fills and the inks are Behaviors on their colours, at the same length,
        // so the row arrives as one thing.
        property real currentness: current ? 1 : 0
        Behavior on currentness {
            NumberAnimation { duration: Theme.dur(140); easing.type: Easing.OutCubic }
        }

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

            // Grows out of the row's middle and fades with it, rather than
            // being there or not. Height and opacity together: at the far end
            // of a fade alone a 3px bar is still a 3px bar, faintly, and the
            // eye reads it as a smudge rather than as something leaving.
            Rectangle {
                objectName: "navCurrentIndicator"
                visible: navItem.currentness > 0.001
                opacity: navItem.currentness
                width: 3
                height: Math.round(parent.height * 0.5 * navItem.currentness)
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
