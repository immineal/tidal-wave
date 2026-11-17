import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

// The queue overlay: a scrim across the page with the panel pinned to its
// right, so no click lands on the page underneath. The queue is four
// sections in one ListView. The model is a row count, and the delegate
// works out its section from player.queueIndex and player.manualCount,
// which stay live on an advance; the three section lists do not, because
// the Player emits no queueChanged for a track simply ending.
Item {
    id: root

    // Raised by a click on the scrim. The host decides what dismissal means.
    signal dismissed()

    // ── opening and closing ──────────────────────────────────────────────
    // The host raises `open`; the panel outlives it by the length of the
    // slide. `visible` is what everything inside gates its bindings on.
    // Defaults to open, so a bare QueuePanel in a test is a panel.
    property bool open: true
    property real openness: open ? 1 : 0
    // A Behavior does not run on a binding's first evaluation, so a panel that
    // starts open is open in its first frame.
    Behavior on openness {
        NumberAnimation { duration: Theme.dur(Theme.motionMedium); easing.type: Easing.OutCubic }
    }
    visible: open || openness > 0.001

    // 340 is the design width. The 85% cap keeps the panel from eating a narrow
    // window whole: at the 640px minimum the content area is 420px, where a
    // fixed 340 would leave 80px of page showing.
    readonly property int panelWidth: Math.min(340, Math.round(width * 0.85))

    readonly property alias queueList: list

    // One height for every track row, which is what lets the drag work in
    // whole slots: a row of travel is a slot of travel.
    readonly property int rowHeight:    52
    readonly property int headerHeight: 30

    // VectorIcon draws into a fixed 24x24 Shape, so a smaller icon hangs past
    // its own bounds. 16 is the smallest size that stays inside the slack of
    // the layout guard in tests/qml/tst_layout_player.qml.
    readonly property int iconSize: 16
    readonly property int gripSize: 24
    readonly property int gripGlyph: 20

    // Empties what the user lined up, and offers it back: the rows are
    // copied first, and Undo puts them in front again in the same order.
    function clearQueue() {
        // Copied out: a list read off a property re-reads it on access, and
        // would be empty by the time Undo runs.
        var q = player.queueManual, saved = []
        for (var i = 0; i < q.length; i++) saved.push(q[i])
        if (saved.length === 0) return
        player.clearManual()
        Edits.recordLocal(qsTr("Queue cleared", "confirmation after emptying the play queue"),
                          function () { player.playNext(saved) },
                          qsTr("Queue put back", "after undoing a cleared queue"))
    }

    // ── the model ────────────────────────────────────────────────────────
    // One list and two boundaries, all gated on `visible` so a closed panel
    // holds no copy of the queue.
    readonly property var rows:        visible ? player.queueTracks : []
    readonly property int playIndex:   visible ? player.queueIndex  : -1
    readonly property int manualTotal: visible ? player.manualCount : 0
    readonly property string contextName: visible ? player.contextName : ""
    readonly property string contextType: visible ? player.contextType : ""

    readonly property int  totalCount: rows.length
    readonly property bool hasCurrent: playIndex >= 0 && playIndex < totalCount

    // Clamped against `rows` rather than trusted, because the two ints and the
    // list arrive on three different signals and a frame caught between them
    // must not index off the end.
    readonly property int playedCount:  Math.max(0, Math.min(playIndex, totalCount))
    readonly property int manualCount:  Math.max(0, Math.min(manualTotal,
                                                  totalCount - playIndex - 1))
    readonly property int contextCount: Math.max(0, totalCount - playedCount
                                                 - (hasCurrent ? 1 : 0) - manualCount)

    // ── flat index arithmetic ────────────────────────────────────────────
    // Rows and headers share one index space; a header of an empty section is
    // -1 and takes up no index, which is how an empty section disappears
    // entirely rather than leaving a stray heading behind.
    readonly property int playedHeaderAt:  playedCount > 0 ? 0 : -1
    readonly property int playedAt:        playedCount > 0 ? 1 : 0
    readonly property int afterPlayed:     playedAt + playedCount
    readonly property int nowHeaderAt:     hasCurrent ? afterPlayed : -1
    readonly property int currentAt:       hasCurrent ? afterPlayed + 1 : -1
    readonly property int afterCurrent:    afterPlayed + (hasCurrent ? 2 : 0)
    readonly property int manualHeaderAt:  manualCount > 0 ? afterCurrent : -1
    readonly property int manualAt:        afterCurrent + (manualCount > 0 ? 1 : 0)
    readonly property int afterManual:     manualAt + manualCount
    readonly property int contextHeaderAt: contextCount > 0 ? afterManual : -1
    readonly property int contextAt:       afterManual + (contextCount > 0 ? 1 : 0)
    readonly property int rowCount:        contextAt + contextCount

    // ── the keyboard ─────────────────────────────────────────────────────
    // The list is one tab stop: the row last walked to, else the playing one.
    property int keyRow: -1
    function isRow(i) { return i >= 0 && i < rowCount && kindOf(i).lastIndexOf("Header") < 0 }
    readonly property int tabRow: isRow(keyRow) ? keyRow
                                : hasCurrent ? currentAt
                                : isRow(0) ? 0 : (isRow(1) ? 1 : -1)
    // Up and Down step over the headings; Home and End go to the ends.
    function focusRow(from, step) {
        for (var i = from + step; i >= 0 && i < rowCount; i += step) {
            if (!isRow(i)) continue
            keyRow = i
            list.positionViewAtIndex(i, ListView.Contain)
            var it = list.itemAtIndex(i)
            if (it) it.forceActiveFocus(Qt.TabFocusReason)
            return true
        }
        return false
    }
    // Where the keyboard goes when the panel opens.
    function takeFocus() {
        var i = tabRow
        if (i >= 0) {
            list.positionViewAtIndex(i, ListView.Contain)
            var it = list.itemAtIndex(i)
            if (it) { it.forceActiveFocus(Qt.TabFocusReason); return }
        }
        closeBtn.forceActiveFocus(Qt.TabFocusReason)
    }

    // Tab goes round inside the open panel. Qt moves focus before any parent
    // sees the key, so a stop outside is caught here and sent to the far end.
    property Item _lastInside: null
    function holds(item) {
        for (var p = item; p; p = p.parent) if (p === panel) return true
        return false
    }
    function edgeStop(forward) {
        var first = panel.nextItemInFocusChain(true)
        if (!forward) {
            var last = first
            for (var n = 0, it = first; n < 200 && it && holds(it); ++n) {
                last = it
                it = it.nextItemInFocusChain(true)
                if (it === first) break
            }
            return last
        }
        return first
    }
    // Through the window object: tst_frame_gating bans the text "Window.active".
    readonly property Item keyboardItem: Window.window ? Window.window.activeFocusItem : null
    onKeyboardItemChanged: {
        var f = keyboardItem
        if (!f || !open) return
        if (holds(f)) { _lastInside = f; return }
        // A menu or dialog the panel opened lives in the overlay.
        for (var p = f; p; p = p.parent) if (p === Overlay.overlay) return
        if (!_lastInside) return
        var back = _lastInside.nextItemInFocusChain(false) === f
        var target = edgeStop(back ? false : true)
        _lastInside = null
        if (!target || !holds(target)) return
        target.forceActiveFocus(Qt.TabFocusReason)
        // Qt 6.4 finishes the Tab's own move after this handler and so undoes
        // the line above; once the key is through, the move is made again.
        Qt.callLater(function () {
            if (open && target.visible && !holds(keyboardItem)) target.forceActiveFocus(Qt.TabFocusReason)
        })
    }
    onOpenChanged: if (!open) _lastInside = null

    function kindOf(i) {
        if (i === playedHeaderAt)  return "playedHeader"
        if (i <  afterPlayed)      return "played"
        if (i === nowHeaderAt)     return "nowHeader"
        if (i === currentAt)       return "current"
        if (i === manualHeaderAt)  return "manualHeader"
        if (i <  afterManual)      return "manual"
        if (i === contextHeaderAt) return "contextHeader"
        return "context"
    }

    // Where in its own section a row sits. Headers have no slot.
    function slotOf(i, kind) {
        switch (kind) {
        case "played":  return i - playedAt
        case "manual":  return i - manualAt
        case "context": return i - contextAt
        }
        return -1
    }

    // Where a row sits in the one queue, which is where the flat list and the
    // sections meet.
    function queueIndexOf(kind, slot) {
        switch (kind) {
        case "played":  return slot
        case "current": return playIndex
        case "manual":  return playIndex + 1 + slot
        case "context": return playIndex + 1 + manualCount + slot
        }
        return -1
    }

    function trackAt(kind, slot) {
        var q = queueIndexOf(kind, slot)
        return (q >= 0 && q < rows.length) ? rows[q] : null
    }

    function headerLabelOf(kind) {
        switch (kind) {
        // Rows behind the cursor: played, or jumped over to get here.
        case "playedHeader":  return qsTr("Earlier in queue")
        case "nowHeader":     return qsTr("Now playing")
        case "manualHeader":  return qsTr("Next in queue")
        case "contextHeader": return contextHeading
        }
        return ""
    }

    // Names the source when it has a name, as an album, a playlist or a mix
    // does. A radio or a one-off play has nothing to name, and a search is
    // named as one.
    readonly property string contextHeading:
        contextName.length === 0   ? qsTr("Up next")
        : contextType === "search" ? qsTr("Next from: search “%1”",
                                          "the queue was started from the search results").arg(contextName)
                                   : qsTr("Next from: %1").arg(contextName)

    function contextGlyph(type) {
        switch (type) {
        case "album":      return "album"
        case "playlist":   return "playlist"
        case "mix":        return "mix"
        case "collection": return "library"
        case "radio":      return "waves"
        case "search":     return "search"
        }
        return "queue"
    }

    // Each section goes back to the player through its own call, so a row
    // never has to know its position in the flat queue.
    function activate(kind, slot) {
        switch (kind) {
        // The current track pauses or resumes, and never starts over.
        case "current": player.playPause();         break
        case "played":  player.jumpToPlayed(slot);  break
        case "manual":  player.jumpToManual(slot);  break
        case "context": player.jumpToContext(slot); break
        }
    }

    // ── finding your place ───────────────────────────────────────────────
    // Nothing here works in absolute content coordinates: a ListView with
    // mixed delegate heights only estimates where an unbuilt item sits. So
    // everything below is an index or a measurement off a real delegate.
    property bool currentOnScreen: true
    property bool currentAbove:    false

    function refreshCurrentPosition() {
        if (!hasCurrent || currentAt < 0) {
            currentOnScreen = true
            currentAbove    = false
            return
        }
        var it = list.itemAtIndex(currentAt)
        if (it) {
            currentOnScreen = it.y + it.height > list.contentY
                              && it.y < list.contentY + list.height
            currentAbove    = it.y < list.contentY
            return
        }
        // No delegate at all: past the cache buffer, so well off screen. Which
        // side it went off is an index comparison, not a distance.
        currentOnScreen = false
        var first = list.indexAt(1, list.contentY + 1)
        currentAbove = first >= 0 && currentAt < first
    }

    // Coalesced through callLater so it runs *after* the view has refilled:
    // the signals below all arrive before the new delegates exist.
    function scheduleCurrentPosition() { Qt.callLater(refreshCurrentPosition) }

    onCurrentAtChanged: scheduleCurrentPosition()

    // positionViewAtIndex is O(1) on a far index: the view drops what it has
    // and refills at the target, so nothing in between is ever built.
    function revealCurrent() {
        if (!visible || !hasCurrent || currentAt < 0 || currentAt >= list.count) return
        list.positionViewAtIndex(currentAt, ListView.Center)
        scheduleCurrentPosition()
    }

    // On open the rows do not exist yet, so the scroll waits for them. Only on
    // open: following every advance would yank the view back from wherever the
    // user was reading, which is what the jump pill is for.
    onVisibleChanged: if (visible) Qt.callLater(revealCurrent)

    // ── dragging what is still to come ───────────────────────────────────
    // A queued row or one of the context's, by its grip or its body, to any
    // gap in either section; dropped in the other section it joins that one.
    // The live state sits here, because the drop indicator belongs to the list.
    property string dragKind: ""
    property int  dragFrom:   -1
    property int  dragFlat:   -1
    property real dragOffset: 0
    // Content y of the dragged row and of the press, measured off the
    // delegate at press time, because the view only estimates positions.
    property real dragRowY:   0
    property real dragPressY: 0
    // The pointer in the list's own coordinates, for the edge scroll.
    property real dragViewX:  0
    property real dragViewY:  0
    // Where it lands: a section, a gap in it, and the row's slot after the move.
    property string dropKind: ""
    property int  dropGap:    -1
    property int  dragTo:     -1
    // Off the queue, over the history or the playing row, a drop is abandoned,
    // not clamped: a slip of the hand must not be an edit.
    property bool dropValid:  false
    readonly property bool dragging: dragFrom >= 0
    property int _currentBefore: -1

    readonly property int upcomingCount: manualCount + contextCount

    // Content y of the top of flat row i, worked out from the dragged row:
    // every track row is rowHeight tall and every heading headerHeight.
    function flatY(i) {
        var heads = [playedHeaderAt, nowHeaderAt, manualHeaderAt, contextHeaderAt]
        var a = Math.min(i, dragFlat), b = Math.max(i, dragFlat), short = 0
        for (var k = 0; k < heads.length; ++k)
            if (heads[k] >= a && heads[k] < b) short++
        var d = (b - a) * rowHeight - short * (rowHeight - headerHeight)
        return dragRowY + (i >= dragFlat ? d : -d)
    }

    function beginDrag(kind, slot, flat, rowY, pressY) {
        dragKind   = kind
        dragFrom   = slot
        dragFlat   = flat
        dragOffset = 0
        dragRowY   = rowY
        dragPressY = pressY
        // The current item outlives a scroll, so the dragged row keeps its
        // delegate, and with it the pointer grab, however far the list moves.
        _currentBefore = list.currentIndex
        list.currentIndex = flat
        aimDrop(dragRowY + rowHeight / 2, true)
    }

    // Aims the drop at the gap nearest the dragged row's middle.
    function aimDrop(centre, inside) {
        var kind = "", gap = -1
        var manualTop = manualHeaderAt >= 0 ? flatY(manualHeaderAt) : -1
        var contextTop = contextHeaderAt >= 0 ? flatY(contextHeaderAt) : -1
        var split = contextTop >= 0 ? contextTop + headerHeight / 2 : Infinity
        if (inside && manualTop >= 0 && centre >= manualTop && centre < split) {
            kind = "manual"
            gap = Math.floor((centre - flatY(manualAt)) / rowHeight + 0.5)
            gap = Math.max(0, Math.min(manualCount, gap))
        } else if (inside && contextTop >= 0 && centre >= Math.min(split, contextTop)
                   && (manualTop < 0 || centre >= split)) {
            kind = "context"
            gap = Math.floor((centre - flatY(contextAt)) / rowHeight + 0.5)
            gap = Math.max(0, Math.min(contextCount, gap))
        }
        dropKind  = kind
        dropGap   = gap
        dropValid = kind !== ""
        dragTo    = !dropValid ? -1 : (kind === dragKind && gap > dragFrom ? gap - 1 : gap)
    }

    // The pointer moved, or the list moved under it.
    function moveDrag(viewX, viewY) {
        if (!dragging) return
        dragViewX = viewX
        dragViewY = viewY
        dragOffset = list.contentY + viewY - dragPressY
        aimDrop(dragRowY + rowHeight / 2 + dragOffset, viewX >= 0 && viewX <= list.width)
    }

    function cancelDrag() {
        if (dragging && list.currentIndex === dragFlat && _currentBefore < list.count)
            list.currentIndex = _currentBefore
        dragKind   = ""
        dragFrom   = -1
        dragFlat   = -1
        dragOffset = 0
        dropKind   = ""
        dropGap    = -1
        dragTo     = -1
        dropValid  = false
    }

    function endDrag() {
        var kind = dragKind, from = dragFrom, toKind = dropKind, to = dragTo, ok = dropValid
        cancelDrag()
        if (!ok || from < 0 || to < 0 || (kind === toKind && from === to)) return
        if (kind === "manual" && toKind === "manual") player.moveManual(from, to)
        else player.moveQueueRow(kind, from, toKind, to)
    }

    // A track ending or the queue changing under a drag moves the rows it
    // was aimed at; the drag is dropped rather than landing a row off by one.
    onPlayIndexChanged: if (dragging) cancelDrag()
    onRowsChanged: if (dragging) cancelDrag()

    // Held near the top or bottom edge, the list scrolls under the row,
    // faster the closer the pointer is to the edge.
    readonly property int edgeBand: 48
    Timer {
        id: edgeScroll
        interval: 16
        repeat: true
        running: root.dragging
        onTriggered: {
            var y = root.dragViewY, step = 0
            if (y < root.edgeBand) step = -Math.ceil((root.edgeBand - y) / 4)
            else if (y > list.height - root.edgeBand)
                step = Math.ceil((y - (list.height - root.edgeBand)) / 4)
            if (step === 0) return
            var top = list.originY
            var end = top + Math.max(0, list.contentHeight - list.height)
            var to = Math.max(top, Math.min(end, list.contentY + step))
            if (to === list.contentY) return
            list.contentY = to
            root.moveDrag(root.dragViewX, root.dragViewY)
        }
    }

    // ── the row menu ─────────────────────────────────────────────────────
    // One for the panel, aimed at a row as it opens. What Spotify's queue row
    // offers, in the order the track rows' menu uses.
    readonly property alias rowMenu: rowMenu

    function openRowMenu(entry, fromKeyboard) {
        if (!entry || entry.isHeader || !entry.track) return
        rowMenu.kind  = entry.kind
        rowMenu.slot  = entry.slot
        rowMenu.flat  = entry.rowIndex
        rowMenu.track = entry.track
        if (fromKeyboard) rowMenu.popup(entry, 16, entry.height)
        else rowMenu.popup()
    }

    // A page the menu opens is shown, so the queue gets out of its way.
    function leaveFor(page, params) {
        var w = Window.window
        if (!w || typeof w.navigate !== "function") return
        w.navigate(page, params)
        root.dismissed()
    }

    MenuBase {
        id: rowMenu
        objectName: "queueRowMenu"

        property string kind: ""
        property int  slot: -1
        property int  flat: -1
        property var  track: null
        readonly property bool upcoming: kind === "manual" || kind === "context"

        readonly property real albumId: track && Number(track.albumId) > 0 ? Number(track.albumId) : 0
        // Every credit with a usable id, as TrackRow lists them.
        readonly property var credits: {
            var out = [], list = track && track.artistList ? track.artistList : []
            for (var i = 0; i < list.length; i++) {
                var id = Number(list[i].id)
                if (id > 0) out.push({ id: id, name: String(list[i].name) })
            }
            var lead = track ? Number(track.artistId) : 0
            if (out.length === 0 && lead > 0)
                out.push({ id: lead, name: typeof track.artists === "string" ? track.artists : "" })
            return out
        }

        readonly property alias playNextItem:      menuPlayNext
        readonly property alias addToPlaylistItem: menuAddToPlaylist
        readonly property alias goToAlbumItem:     menuGoToAlbum
        readonly property alias removeItem:        menuRemove

        onClosed: flat = -1

        // A row already coming up moves to the front; one already played is
        // queued again, as a track row's Play next does.
        function playNext() {
            if (kind === "manual") { if (slot > 0) player.moveManual(slot, 0) }
            else if (kind === "context") player.moveQueueRow("context", slot, "manual", 0)
            else if (track) {
                player.playNext([track])
                Toasts.show(qsTranslate("ContextMenu", "%Ln track(s) added to play next",
                                        "queue confirmation", 1))
            }
        }

        function remove() {
            if (kind === "manual") player.removeManual(slot)
            else if (kind === "context") player.removeFromQueue(root.queueIndexOf("context", slot))
        }

        // The row that opens the artists submenu, built from this delegate.
        delegate: ContextMenu.Entry {
            id: artistSubRow
            iconName: "artist"
            visible: rowMenu.credits.length > 1
            height: visible ? implicitHeight : 0
            rightPadding: Theme.space3 + Theme.space5
            arrow: VectorIcon {
                visible: artistSubRow.subMenu
                x: artistSubRow.width - width - 12
                y: (artistSubRow.height - height) / 2
                width: 14; height: 14
                name: "chevron-right"
                color: artistSubRow.ink
            }
        }

        ContextMenu.Entry {
            id: menuPlayNext
            visible: rowMenu.kind !== "current"
            height: visible ? implicitHeight : 0
            text: qsTranslate("TrackRow", "Play next", "verb, play this right after the current track")
            iconName: "next"
            onTriggered: rowMenu.playNext()
        }
        ContextMenu.Entry {
            id: menuAddToPlaylist
            text: qsTranslate("TrackRow", "Add to playlist")
            iconName: "plus"
            enabled: rowMenu.track !== null && Number(rowMenu.track.id) > 0
            onTriggered: Edits.pickPlaylist([rowMenu.track])
        }
        ContextMenu.Separator { }
        ContextMenu.Entry {
            id: menuGoToAlbum
            text: qsTranslate("TrackRow", "Go to album")
            iconName: "album"
            enabled: rowMenu.albumId > 0
            onTriggered: root.leaveFor("album", { albumId: rowMenu.albumId })
        }
        ContextMenu.Entry {
            text: qsTranslate("TrackRow", "Go to artist")
            iconName: "artist"
            visible: rowMenu.credits.length <= 1
            height: visible ? implicitHeight : 0
            enabled: rowMenu.credits.length === 1
            onTriggered: if (rowMenu.credits.length === 1)
                             root.leaveFor("artist", { artistId: rowMenu.credits[0].id })
        }
        MenuBase {
            id: artistSubMenu
            title: qsTranslate("TrackRow", "Go to artist")
            Instantiator {
                model: rowMenu.credits
                delegate: ContextMenu.Entry {
                    text: modelData.name
                    onTriggered: root.leaveFor("artist", { artistId: modelData.id })
                }
                onObjectAdded: (index, object) => artistSubMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => artistSubMenu.removeItem(object)
            }
        }
        ContextMenu.Separator { shown: rowMenu.upcoming }
        ContextMenu.Entry {
            id: menuRemove
            visible: rowMenu.upcoming
            height: visible ? implicitHeight : 0
            text: qsTr("Remove from queue")
            danger: true
            iconName: "trash"
            onTriggered: rowMenu.remove()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        opacity: root.openness
    }

    // Swallows anything that misses the panel, so no click reaches the page.
    // Disabled while the panel slides out: the scrim is still painted then,
    // and a click on it must reach the page.
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.AllButtons
        onClicked: root.dismissed()
        onWheel: (wheel) => wheel.accepted = true
    }

    Rectangle {
        id: panel
        anchors.top:    parent.top
        anchors.bottom: parent.bottom
        anchors.right:  parent.right
        width: root.panelWidth
        color: Theme.surface
        border.color: Theme.border

        // The slide. A transform, not an x offset, so the panel's geometry is
        // the same during the slide as at rest. The list inside measures itself
        // against it and tests/qml/tst_layout_player.qml checks it.
        transform: Translate { x: (1 - root.openness) * root.panelWidth }

        // Declared before the panel's content, so it only ever sees what the
        // content did not take. The panel is not the scrim: a click that lands
        // on it stays on it.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                height: 52
                color: "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space4
                    anchors.rightMargin: Theme.space4
                    Text { text: qsTr("Queue", "noun, the play queue"); color: Theme.textPrimary; font.pixelSize: Theme.fontTitle; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: qsTr("%Ln track(s)", "", root.totalCount); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
                    Text {
                        visible: player.shuffle
                        text: "· " + qsTr("Shuffled", "the queue is in shuffled order")
                        color: Theme.accentText; font.pixelSize: Theme.fontMeta
                    }
                    Item { width: Theme.space2 }
                    // Clears the manual queue and only that: the history and
                    // the album are not the user's list. The hit area is 32
                    // tall around the 12px word.
                    Item {
                        id: clearBtn
                        objectName: "queueClear"
                        visible: root.manualCount > 0
                        implicitWidth: Math.max(32, clearText.implicitWidth + 12)
                        implicitHeight: 32
                        activeFocusOnTab: true
                        Keys.onReturnPressed: root.clearQueue()
                        Keys.onSpacePressed:  root.clearQueue()
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Clear queue", "button, empties the play queue")
                        Accessible.onPressAction: root.clearQueue()
                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusMedium
                            color: clearHov.hovered ? Theme.hoverFill : "transparent"
                            border.width: clearBtn.activeFocus ? 2 : 0
                            border.color: Theme.accent
                        }
                        Text {
                            id: clearText
                            anchors.centerIn: parent
                            text: qsTr("Clear", "verb, empties the play queue")
                            color: clearHov.hovered || clearBtn.activeFocus ? Theme.textPrimary : Theme.textSec
                            font.pixelSize: Theme.fontMeta
                        }
                        HoverHandler { id: clearHov }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.clearQueue()
                        }
                    }
                    // The way out besides Escape and a click beside the panel.
                    Item {
                        id: closeBtn
                        objectName: "queueClose"
                        implicitWidth: 32
                        implicitHeight: 32
                        activeFocusOnTab: true
                        Keys.onReturnPressed: root.dismissed()
                        Keys.onSpacePressed:  root.dismissed()
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Close queue", "button, hides the play queue")
                        Accessible.onPressAction: root.dismissed()
                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusMedium
                            color: closeHov.hovered ? Theme.hoverFill : "transparent"
                            border.width: closeBtn.activeFocus ? 2 : 0
                            border.color: Theme.accent
                        }
                        VectorIcon {
                            anchors.centerIn: parent
                            name: "x"
                            width: 14; height: 14
                            color: closeHov.hovered || closeBtn.activeFocus ? Theme.textPrimary : Theme.textSec
                        }
                        HoverHandler { id: closeHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.dismissed() }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

            // The list and the jump affordance that floats over it. A plain
            // Item, because the affordance is anchored to the viewport rather
            // than laid out under it.
            Item {
                id: listArea
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: list
                    objectName: "queuePanelList"
                    anchors.fill: parent
                    clip: true
                    // The model is the row count, not the rows: the delegate
                    // reads its own entry out of the section arrays, so a
                    // 5000 track queue is never copied into one JS list.
                    model: root.rowCount
                    cacheBuffer: 240
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    // No drag to scroll: a press on a row's title or artist
                    // would otherwise hand the drag to the list. The wheel and
                    // the scroll bar scroll; the grip moves rows.
                    interactive: false
                    keyNavigationEnabled: true
                    WheelHandler {
                        target: null
                        onWheel: (event) => {
                            var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y
                            var top = list.originY
                            var end = top + Math.max(0, list.contentHeight - list.height)
                            list.contentY = Math.max(top, Math.min(end, list.contentY - dy))
                        }
                    }

                    delegate: QueueEntry {
                        required property int index
                        rowIndex: index
                        width: ListView.view ? ListView.view.width : 0
                    }

                    // Where the dragged row will land. A child of the list is
                    // parented to the content item, so this is positioned in
                    // content coordinates however far the list is scrolled.
                    Rectangle {
                        objectName: "queueDropIndicator"
                        visible: root.dragging && root.dropValid
                        x: 8
                        width: Math.max(0, list.width - 16)
                        height: 2
                        radius: height / 2
                        z: 3
                        color: Theme.accent
                        y: !root.dropValid ? 0
                           : root.flatY((root.dropKind === "manual" ? root.manualAt : root.contextAt)
                                        + root.dropGap) - 1
                    }

                    // Everything that moves the current track in or out of the
                    // viewport comes through one of these.
                    onContentYChanged:      root.scheduleCurrentPosition()
                    onContentHeightChanged: root.scheduleCurrentPosition()
                    onCountChanged:         root.scheduleCurrentPosition()
                    onHeightChanged:        root.scheduleCurrentPosition()
                }

                // Outside the list: a child of a ListView is parented to its
                // content item, which is zero-sized when there is nothing to
                // show, so centring in it would centre on a corner.
                Text {
                    anchors.centerIn: parent
                    width: parent.width - 32
                    visible: root.rowCount === 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("Nothing queued yet")
                    color: Theme.textDim
                    font.pixelSize: Theme.fontMeta
                }

                // Shown when the current track is off screen, on the edge it
                // went off, so it also says which way it is.
                Rectangle {
                    id: jumpPill
                    objectName: "queueJumpToCurrent"
                    visible: opacity > 0
                    opacity: (root.hasCurrent && !root.currentOnScreen) ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.motionMedium) } }

                    anchors.horizontalCenter: parent.horizontalCenter
                    // A y, not a top and a bottom anchor swapped by binding:
                    // for a moment both held, and the pill kept the stretched
                    // height over the rows, taking their clicks.
                    y: root.currentAbove ? Theme.space3 : parent.height - height - Theme.space3

                    width: jumpRow.implicitWidth + 24
                    height: 28
                    radius: Theme.radiusFull
                    color: jumpHov.hovered ? Theme.accentDim : Theme.accent

                    RowLayout {
                        id: jumpRow
                        anchors.centerIn: parent
                        spacing: Theme.space1
                        VectorIcon {
                            name: "chevron-left"
                            // The glyph points left; a quarter turn clockwise
                            // points it up.
                            rotation: root.currentAbove ? 90 : -90
                            color: Theme.accentInk
                            width: root.iconSize; height: root.iconSize
                        }
                        Text {
                            text: qsTr("Jump to current track")
                            color: Theme.accentInk
                            font.pixelSize: Theme.fontMeta
                        }
                    }

                    HoverHandler { id: jumpHov }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.revealCurrent()
                    }
                }
            }
        }
    }

    // ── one delegate for every kind of row ───────────────────────────────
    // Header and track share a delegate. A Loader would cost the loaded item
    // the sight of the delegate's own properties, and only the rows in the
    // viewport exist at once, so the unused half is one hidden Text.
    component QueueEntry : Item {
        id: entry

        property int rowIndex: 0

        readonly property string kind:     root.kindOf(rowIndex)
        readonly property bool   isHeader: kind.lastIndexOf("Header") > 0
        readonly property int    slot:     root.slotOf(rowIndex, kind)
        readonly property var    track:    root.trackAt(kind, slot)

        readonly property bool isCurrent: kind === "current"
        readonly property bool isPlayed:  kind === "played"
        readonly property bool isManual:  kind === "manual"
        readonly property bool actionable: !isHeader
        readonly property bool upcoming:   isManual || kind === "context"
        readonly property bool menuOpen:   rowMenu.visible && rowMenu.flat === rowIndex
        readonly property bool draggable:  upcoming && root.upcomingCount > 1
        readonly property bool dragging:   root.dragging && root.dragFlat === rowIndex

        // Starts a drag on this row from a press at (x, y) of `area`.
        function startDrag(area, x, y) {
            var p = area.mapToItem(list, x, y)
            root.beginDrag(kind, slot, rowIndex, entry.y, list.contentY + p.y)
            root.moveDrag(p.x, p.y)
        }
        function followDrag(area, x, y) {
            var p = area.mapToItem(list, x, y)
            root.moveDrag(p.x, p.y)
        }

        objectName: "queueEntry"
        height: isHeader ? root.headerHeight : root.rowHeight
        // The row being dragged travels over its neighbours, not under them.
        z: dragging ? 2 : 0

        readonly property string headerText: isHeader ? root.headerLabelOf(kind) : ""

        // Only a string is a title; a missing or wrongly typed field is not.
        function fieldOf(key) {
            var v = track ? track[key] : undefined
            return (typeof v === "string") ? v : ""
        }
        // The two fallbacks come out of TrackRow's context rather than being
        // declared again here: the same sentence in two contexts is the same
        // sentence translated twice, and free to drift.
        readonly property string titleText:
            isHeader ? "" : (fieldOf("title")   || qsTranslate("TrackRow", "Unknown track"))
        readonly property string artistsText:
            isHeader ? "" : (fieldOf("artists") || qsTranslate("TrackRow", "Unknown artist"))
        readonly property string coverText: fieldOf("coverUrl80")

        // fieldOf() answers with a string or nothing, so the artist list has
        // its own accessor. A queue restored from QSettings may lack the field,
        // and ArtistLinks then falls back to the joined string and the lead id.
        readonly property var artistList:
            (track && track.artistList && track.artistList.length > 0) ? track.artistList : []
        readonly property real leadArtistId: {
            var n = track ? Number(track.artistId) : 0
            return isFinite(n) ? n : 0
        }

        activeFocusOnTab: activeFocus || (actionable && rowIndex === root.tabRow)
        onActiveFocusChanged: if (activeFocus && actionable) root.keyRow = rowIndex
        // Space stays play/pause for the window, as on a track row.
        readonly property bool leavesSpaceToPlayer: true
        Keys.onReturnPressed: root.activate(kind, slot)
        Keys.onEnterPressed:  root.activate(kind, slot)
        Keys.onUpPressed:     root.focusRow(rowIndex, -1)
        Keys.onDownPressed:   root.focusRow(rowIndex, 1)
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Home) root.focusRow(-1, 1)
            else if (event.key === Qt.Key_End) root.focusRow(root.rowCount, -1)
            else if (event.key === Qt.Key_Menu
                     || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
                root.openRowMenu(entry, true)
            } else return
            event.accepted = true
        }
        Accessible.role: isHeader ? Accessible.StaticText : Accessible.ListItem
        Accessible.name: isHeader ? headerText
                                  : qsTranslate("TrackRow", "%1, %2",
                                                "track row for a screen reader: title, artists")
                                        .arg(titleText).arg(artistsText)
        Accessible.onPressAction: if (actionable) root.activate(kind, slot)

        // ── the section heading ──────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: entry.isHeader

            VectorIcon {
                id: headerIcon
                visible: entry.kind === "contextHeader"
                anchors.left: parent.left
                anchors.leftMargin: Theme.space4
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 1
                name: root.contextGlyph(root.contextType)
                width: root.iconSize; height: root.iconSize
                color: Theme.textDim
            }

            Text {
                anchors.left: headerIcon.visible ? headerIcon.right : parent.left
                anchors.leftMargin: headerIcon.visible ? Theme.space2 : Theme.space4
                anchors.right: parent.right
                anchors.rightMargin: Theme.space4
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 1
                text: entry.headerText
                // The manual queue is the one the user built, so it is the one
                // the eye should land on; the rest are captions.
                color: entry.kind === "manualHeader" ? Theme.accentText : Theme.textDim
                font.pixelSize: Theme.fontMicro
                font.bold: true
                elide: Text.ElideRight
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Theme.space4
                anchors.rightMargin: Theme.space4
                height: 1
                // Not above the first heading: there is nothing up there to
                // be separated from.
                visible: entry.rowIndex > 0
                color: Theme.border
            }
        }

        // ── a track ──────────────────────────────────────────────────────
        Rectangle {
            id: rowBg
            anchors.fill: parent
            anchors.leftMargin: Theme.space2
            anchors.rightMargin: Theme.space2
            anchors.topMargin: Theme.spaceHalf
            anchors.bottomMargin: Theme.spaceHalf
            visible: !entry.isHeader
            radius: Theme.radiusMedium
            // A dragged row is lifted: opaque, so the rows it passes stay under it.
            color: entry.dragging ? Theme.surfaceHigh
                 : entry.isCurrent ? Theme.accentSoft
                 : (qHov.hovered || entry.menuOpen) ? Theme.hoverFill
                 : "transparent"
            border.width: (entry.activeFocus || entry.dragging) ? 2 : 0
            border.color: Theme.accent
            // History reads as history. The whole row dims, not just the
            // text, so the section is obvious at a glance from the artwork.
            opacity: entry.isPlayed ? 0.55 : 1
            // The lift. A transform rather than a y offset, because the row's
            // y belongs to the ListView.
            transform: Translate { y: entry.dragging ? root.dragOffset : 0 }

            // Declared before the content, so the grip and the remove button
            // in front of it still get their own clicks.
            MouseArea {
                id: rowArea
                anchors.fill: parent
                enabled: !entry.isHeader
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: entry.actionable ? Qt.PointingHandCursor : Qt.ArrowCursor
                // A drag on a row is not a scroll: it moves the row, and the
                // wheel scrolls. A press that travelled is not a click either.
                preventStealing: true
                property point pressAt
                property bool travelled: false
                onPressed: function (mouse) { pressAt = Qt.point(mouse.x, mouse.y); travelled = false }
                onPositionChanged: function (mouse) {
                    if (entry.dragging) { entry.followDrag(rowArea, mouse.x, mouse.y); return }
                    if (Math.abs(mouse.x - pressAt.x) > Qt.styleHints.startDragDistance
                            || Math.abs(mouse.y - pressAt.y) > Qt.styleHints.startDragDistance)
                        travelled = true
                    // The body drags as the grip does, as in Spotify and Tidal.
                    if (travelled && entry.draggable && !root.dragging
                            && (mouse.buttons & Qt.LeftButton)) {
                        entry.startDrag(rowArea, pressAt.x, pressAt.y)
                        entry.followDrag(rowArea, mouse.x, mouse.y)
                    }
                }
                onReleased: if (entry.dragging) root.endDrag()
                onCanceled: if (entry.dragging) root.cancelDrag()
                onClicked: function (mouse) {
                    if (travelled) return
                    if (mouse.button === Qt.RightButton) {
                        root.openRowMenu(entry, false)
                        return
                    }
                    if (entry.actionable) root.activate(entry.kind, entry.slot)
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.space1
                anchors.rightMargin: Theme.space2
                spacing: Theme.space2

                // The grip's column is reserved on every track row, so the
                // artwork keeps one straight edge across section boundaries.
                Item {
                    Layout.preferredWidth: root.gripSize
                    Layout.fillHeight: true

                    // Full strength at rest: a faint grip read as decoration.
                    VectorIcon {
                        objectName: "queueDragGrip"
                        anchors.centerIn: parent
                        visible: entry.draggable
                        name: "grip"
                        width: root.gripGlyph; height: root.gripGlyph
                        color: entry.dragging ? Theme.accentText
                             : qHov.hovered ? Theme.textPrimary : Theme.textSec
                    }

                    MouseArea {
                        id: gripArea
                        objectName: "queueDragArea"
                        anchors.fill: parent
                        // A deliberate bleed, so the grip's target is wider
                        // than its column. 4 is what the layout guard in
                        // tests/qml/tst_layout_player.qml allows for overhang.
                        anchors.margins: -Theme.space1
                        visible: entry.draggable
                        enabled: entry.draggable
                        cursorShape: entry.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        // Otherwise the list reads the vertical drag as a flick
                        // and takes the grab away mid-reorder.
                        preventStealing: true

                        // The event arrives in the handle's own moving
                        // coordinates; the row maps it back into the list's.
                        onPressed: function (mouse) { entry.startDrag(gripArea, mouse.x, mouse.y) }
                        onPositionChanged: function (mouse) {
                            if (entry.dragging) entry.followDrag(gripArea, mouse.x, mouse.y)
                        }
                        onReleased: if (entry.dragging) root.endDrag()
                        onCanceled: if (entry.dragging) root.cancelDrag()
                    }
                }

                // 36px box, doubled for a 2x screen.
                CoverArt {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    imageName: "queueRowCover"
                    source: entry.coverText || ""
                    decodeSize: Qt.size(72, 72)
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spaceHalf
                    // A truncated payload must still read as a row.
                    Text {
                        Layout.fillWidth: true
                        text: entry.titleText
                        color: entry.isCurrent ? Theme.accentText : Theme.textPrimary
                        font.pixelSize: Theme.fontMeta
                        font.bold: entry.isCurrent
                        elide: Text.ElideRight
                    }
                    // One hover target and one tab stop per artist. The row's
                    // click target is declared before this, so a name takes the
                    // left click and the rest of the line jumps to the track.
                    ArtistLinks {
                        Layout.fillWidth: true
                        tabStops: false
                        namePrefix: "queue"
                        fontPixelSize: Theme.fontMicro
                        artistList: entry.artistList
                        joinedText: entry.artistsText
                        fallbackArtistId: entry.leadArtistId
                    }
                }

                // Says why the row is accented. The same indicator the track
                // rows show, so the queue and the lists agree on what playing
                // looks like.
                VectorIcon.PlayingIndicator {
                    objectName: "queuePlayingIndicator"
                    visible: entry.isCurrent
                    animate: player.playing
                    // Sized by its own implicit 16x14; the row only has to
                    // say where in the line it sits.
                    Layout.alignment: Qt.AlignVCenter
                }

                // Removing is for the manual queue only. The slot is reserved
                // on every row, like the grip's, so the titles do not reflow
                // under the pointer when the button appears.
                Item {
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24

                    Item {
                        objectName: "queueRemoveButton"
                        anchors.fill: parent
                        visible: entry.isManual && qHov.hovered
                        VectorIcon {
                            anchors.centerIn: parent
                            name: "x"
                            color: removeHov.hovered ? Theme.textPrimary : Theme.textSec
                            width: root.iconSize; height: root.iconSize
                        }
                        HoverHandler { id: removeHov }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: player.removeManual(entry.slot)
                        }
                    }
                }
            }

            HoverHandler { id: qHov }
        }
    }
}
