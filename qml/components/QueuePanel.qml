import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
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
        NumberAnimation { duration: Theme.dur(150); easing.type: Easing.OutCubic }
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
        case "playedHeader":  return qsTr("Played")
        case "nowHeader":     return qsTr("Now Playing")
        case "manualHeader":  return qsTr("Next in queue")
        case "contextHeader": return contextHeading
        }
        return ""
    }

    // Names the source when it has a name, as an album, a playlist or a mix
    // does. A radio or a one-off play has nothing to name.
    readonly property string contextHeading:
        contextName.length > 0 ? qsTr("Next from: %1").arg(contextName)
                               : qsTr("Up Next")

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

    // ── dragging inside the manual queue ─────────────────────────────────
    // Same shape as the sidebar's pinned block (SideBar.qml): the live state
    // sits here, because the drop indicator belongs to the list.
    property int  dragFrom:   -1
    property int  dragTo:     -1
    property real dragOffset: 0
    // Content y of the first manual row, measured off the dragged delegate
    // at press time, because the view only estimates positions.
    property real dragTopY:   0
    // Whether the pointer is still inside the manual queue. A drag that ends
    // anywhere else is abandoned, not clamped: a queued track must not land
    // in the history or in the album by a slip of the hand.
    property bool dropValid:  false
    readonly property bool dragging: dragFrom >= 0

    function manualSlotAt(from, offset) {
        return Math.max(0, Math.min(manualCount - 1,
                                    from + Math.round(offset / rowHeight)))
    }

    function beginDrag(slot, rowY) {
        dragFrom   = slot
        dragTo     = slot
        dragOffset = 0
        dragTopY   = rowY - slot * rowHeight
        dropValid  = true
    }

    function cancelDrag() {
        dragFrom   = -1
        dragTo     = -1
        dragOffset = 0
        dropValid  = false
    }

    function endDrag() {
        var from = dragFrom
        var to   = dragTo
        var ok   = dropValid
        cancelDrag()
        if (!ok || from < 0 || to < 0 || from === to) return
        player.moveManual(from, to)
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
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    Text { text: qsTr("Queue", "noun, the play queue"); color: Theme.textPrimary; font.pixelSize: 16; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: qsTr("%n track(s)", "", root.totalCount); color: Theme.textSec; font.pixelSize: 12 }
                    Text {
                        visible: player.shuffle
                        text: qsTr("· Shuffled")
                        color: Theme.accent; font.pixelSize: 12
                    }
                    Item { width: 8 }
                    // Clears the manual queue and only that: the history and
                    // the album are not the user's list.
                    Text {
                        objectName: "queueClear"
                        text: qsTr("Clear", "verb, empties the play queue")
                        color: clearHov.hovered ? Theme.textPrimary : Theme.textSec
                        font.pixelSize: 12
                        visible: root.manualCount > 0
                        HoverHandler { id: clearHov }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: player.clearManual()
                        }
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
                        radius: 1
                        z: 3
                        color: Theme.accent
                        y: root.dragTopY
                           + (root.dragTo > root.dragFrom ? root.dragTo + 1 : root.dragTo)
                             * root.rowHeight - 1
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
                    font.pixelSize: 12
                }

                // Shown when the current track is off screen, on the edge it
                // went off, so it also says which way it is.
                Rectangle {
                    id: jumpPill
                    objectName: "queueJumpToCurrent"
                    visible: opacity > 0
                    opacity: (root.hasCurrent && !root.currentOnScreen) ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(140) } }

                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top:    root.currentAbove ? parent.top : undefined
                    anchors.bottom: root.currentAbove ? undefined : parent.bottom
                    anchors.topMargin: 10
                    anchors.bottomMargin: 10

                    width: jumpRow.implicitWidth + 24
                    height: 28
                    radius: Theme.radiusChip
                    color: jumpHov.hovered ? Theme.accentDim : Theme.accent

                    RowLayout {
                        id: jumpRow
                        anchors.centerIn: parent
                        spacing: 4
                        VectorIcon {
                            name: "chevron-left"
                            // The glyph points left; a quarter turn clockwise
                            // points it up.
                            rotation: root.currentAbove ? 90 : -90
                            color: Theme.accentInk
                            width: root.iconSize; height: root.iconSize
                            strokeWidth: 2
                        }
                        Text {
                            text: qsTr("Jump to current track")
                            color: Theme.accentInk
                            font.pixelSize: 12
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
        // The current row is where you already are, so there is nowhere for a
        // click on it to go.
        readonly property bool actionable: !isHeader && !isCurrent
        readonly property bool draggable:  isManual && root.manualCount > 1
        readonly property bool dragging:   isManual && root.dragFrom === slot

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

        activeFocusOnTab: actionable
        Keys.onReturnPressed: root.activate(kind, slot)
        Keys.onSpacePressed:  root.activate(kind, slot)

        // ── the section heading ──────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: entry.isHeader

            VectorIcon {
                id: headerIcon
                visible: entry.kind === "contextHeader"
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 1
                name: root.contextGlyph(root.contextType)
                width: root.iconSize; height: root.iconSize
                strokeWidth: 1.5
                color: Theme.textDim
            }

            Text {
                anchors.left: headerIcon.visible ? headerIcon.right : parent.left
                anchors.leftMargin: headerIcon.visible ? 6 : 14
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 1
                text: entry.headerText
                // The manual queue is the one the user built, so it is the one
                // the eye should land on; the rest are captions.
                color: entry.kind === "manualHeader" ? Theme.accent : Theme.textDim
                font.pixelSize: 11
                font.bold: true
                elide: Text.ElideRight
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 14
                anchors.rightMargin: 14
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
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            visible: !entry.isHeader
            radius: Theme.radiusRow
            color: entry.isCurrent ? Theme.accentSoft
                 : (entry.dragging || qHov.hovered) ? Theme.surfaceHov
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
                anchors.fill: parent
                enabled: !entry.isHeader
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: entry.actionable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: function (mouse) {
                    if (mouse.button === Qt.RightButton) {
                        if (entry.isManual) rowMenu.popup()
                        return
                    }
                    if (entry.actionable) root.activate(entry.kind, entry.slot)
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 8
                spacing: 8

                // The grip's column is reserved on every track row, so the
                // artwork keeps one straight edge across section boundaries.
                Item {
                    Layout.preferredWidth: 16
                    Layout.fillHeight: true

                    VectorIcon {
                        anchors.centerIn: parent
                        visible: entry.draggable
                        name: "grip"
                        width: root.iconSize; height: root.iconSize
                        strokeWidth: 1.5
                        color: entry.dragging ? Theme.accent : Theme.textDim
                        opacity: qHov.hovered || entry.dragging ? 1 : 0.45
                    }

                    MouseArea {
                        objectName: "queueDragArea"
                        anchors.fill: parent
                        // A deliberate bleed, so a 16px-wide grip is not a
                        // 16px-wide target. 4 is what the layout guard in
                        // tests/qml/tst_layout_player.qml allows for overhang.
                        anchors.margins: -4
                        visible: entry.draggable
                        enabled: entry.draggable
                        cursorShape: entry.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        // Otherwise the list reads the vertical drag as a flick
                        // and takes the grab away mid-reorder.
                        preventStealing: true

                        // Where the press landed, in the list's content
                        // coordinates, which do not move when the list scrolls.
                        property real pressY: 0

                        onPressed: function (mouse) {
                            pressY = mapToItem(list.contentItem, mouse.x, mouse.y).y
                            root.beginDrag(entry.slot, entry.y)
                        }
                        onPositionChanged: function (mouse) {
                            if (!entry.dragging) return
                            // The event arrives in the handle's own moving
                            // coordinates; mapToItem puts the pointer back into
                            // the list's content space.
                            var p = mapToItem(list.contentItem, mouse.x, mouse.y)
                            root.dragOffset = p.y - pressY
                            root.dragTo     = root.manualSlotAt(entry.slot, root.dragOffset)
                            // Confined to the manual queue, in both directions:
                            // the history above it, the context below it, and
                            // the page beside it.
                            root.dropValid = p.y >= root.dragTopY
                                && p.y < root.dragTopY + root.manualCount * root.rowHeight
                                && p.x >= 0 && p.x <= list.width
                        }
                        onReleased: root.endDrag()
                        onCanceled: root.cancelDrag()
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    radius: Theme.radiusArt
                    color: Theme.surfaceHigh
                    clip: true
                    Image {
                        objectName: "queueRowCover"
                        anchors.fill: parent
                        source: entry.coverText ? "image://tidal/" + entry.coverText : ""
                        // 36px box, doubled for a 2x screen. Both dimensions;
                        // see TrackRow's cover for why one is a trap.
                        sourceSize: Qt.size(72, 72)
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    // A truncated payload must still read as a row.
                    Text {
                        Layout.fillWidth: true
                        text: entry.titleText
                        color: entry.isCurrent ? Theme.accent : Theme.textPrimary
                        font.pixelSize: 13
                        font.bold: entry.isCurrent
                        elide: Text.ElideRight
                    }
                    // One hover target and one tab stop per artist. The row's
                    // click target is declared before this, so a name takes the
                    // left click and the rest of the line jumps to the track.
                    ArtistLinks {
                        Layout.fillWidth: true
                        namePrefix: "queue"
                        fontPixelSize: 11
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
                            strokeWidth: 1.8
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

            Menu {
                id: rowMenu
                // So a test can reach a per-delegate menu, which is not in
                // any item's children: a Popup is a QObject, not an Item.
                objectName: "queueRowMenu"
                // The same arrival as every other menu in the app; see
                // ContextMenu.qml for why it is opacity and nothing else.
                enter: ContextMenu.OpenFade { }
                exit:  ContextMenu.CloseFade { }
                // Insets reset, not inherited; see ContextMenu.qml.
                leftInset: 0; rightInset: 0; topInset: 0; bottomInset: 0

                // Assigned where it exists (Qt 6.8); see ContextMenu.qml.
                Component.onCompleted: {
                    if (this.popupType !== undefined) this.popupType = Popup.Item
                }
                implicitWidth: Theme.menuWidth(this)
                overlap: 0
                background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }
                ContextMenu.Entry {
                    text: qsTr("Remove from queue")
                    danger: true
                    iconName: "trash"
                    onTriggered: player.removeManual(entry.slot)
                }
            }
        }
    }
}
