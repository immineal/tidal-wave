import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    // The width the collapsed sidebar hands back. Below the rail breakpoint the
    // pane gets wider as the window narrows, so a breakpoint subtracts this to
    // measure against a width that only shrinks with the window.
    readonly property int sidebarReclaim: {
        var w = Window.window ? Window.window.width : 0
        return (w > 0 && w < prefs.railBreak())
               ? Math.max(0, prefs.sidebarWidth - prefs.rail()) : 0
    }

    property string playlistUuid: ""
    property string playlistTitle: ""
    property string coverUrl: ""
    property string playlistDescription: ""
    property int    playlistDuration: 0
    property string playlistType: ""   // "USER" / "EDITORIAL"
    // Whether the user made it, as the header says. Another user's playlist
    // saved here is USER too, and only the creator may edit.
    property bool   playlistEditable: false
    // The bridge's TrackRows, which JS cannot read, or a JS array. Read
    // through trackModel, which also has their number in `length`.
    property var    tracks: []
    property bool   loading: false

    // What the last load was told, "" when it was served.
    property string loadError: ""

    // Nothing came back at all. The hero stays, since the caller's title and
    // artwork are still correct. Gated on what the server said: a playlist with
    // no songs in it is ordinary.
    readonly property bool loadFailed:
        loadError.length > 0 && !loading && trackModel.length === 0

    // The failure came with Tidal out of reach; see AlbumPage.loadOffline.
    property bool loadOffline: false

    // Try again, and the way back once Tidal answers again.
    function retryLoad() {
        if (root.playlistUuid.length === 0) return
        if (bridge.offline) bridge.retryConnection()
        loadPlaylist()
    }

    Connections {
        target: bridge
        function onOfflineChanged() {
            if (!bridge.offline && root.loadFailed && root.loadOffline) root.retryLoad()
        }
    }

    // The first reason is kept; see ArtistPage.noteLoadError().
    function noteLoadError(err) {
        if (root.loadError.length > 0) return
        root.loadError = err
        root.loadOffline = bridge.offline === true
    }

    // The words typed into the field over the list.
    property string trackFilter: ""

    // root.tracks as the bridge handed it, sorted by the headings and narrowed
    // by the field; a row becomes a JS object only once drawn. A row's `place`
    // is its index in root.tracks, which a removal names, twins apart.
    TrackListHeader.Sort { id: trackSort }
    readonly property alias trackRows: trackModel
    TrackModel {
        id: trackModel
        source: root.tracks
        sortKey: trackSort.key
        descending: trackSort.descending
        pattern: root.trackFilter
        // Case and accents do not count, and every word must be found.
        everyWord: true
    }

    // Records this playlist as the "playing from" source, then starts playback.
    function playFrom(list, i) {
        player.setPlaybackSource("playlist", root.playlistUuid, root.playlistTitle)
        player.playTracks(list, i)
    }

    onPlaylistUuidChanged: {
        root.trackFilter = ""
        if (playlistUuid.length > 0) loadPlaylist()
    }

    // An undo, or a change Tidal did not confirm, moved rows this page did
    // not move itself: the rows are read again.
    Connections {
        target: Edits
        function onPlaylistChanged(uuid) {
            if (uuid === root.playlistUuid && root.playlistUuid.length > 0) root.reloadTracks()
        }
    }

    // ── the one number on this page with no live source ──────────────────
    // The length arrives once with the header, so it is refreshed from the
    // bridge's cache when this playlist's contents change. Not on
    // favoritePlaylistsChanged, which also fires for paging and for plays.
    Connections {
        target: bridge
        function onPlaylistStatsRefreshed(uuid) {
            if (uuid !== root.playlistUuid || root.playlistUuid.length === 0) return
            var cached = bridge.getUserPlaylists()
            for (var i = 0; i < cached.length; i++) {
                if (cached[i].uuid !== root.playlistUuid) continue
                // Either the cache has a real length, or the playlist is empty
                // and zero is true. A row with tracks and no length has not
                // been filled in by the sign-in paging yet.
                if (cached[i].duration > 0 || cached[i].numTracks === 0)
                    root.playlistDuration = cached[i].duration

                // ── and the one case where the tracklist itself is behind ──
                // A song added to this playlist from a row on this page updates
                // no tracklist, so reload when the count and the list disagree.
                // The reload raises no signal, so this cannot loop.
                if (cached[i].numTracks !== trackModel.length)
                    root.reloadTracks()
                return
            }
        }
    }

    // What the hero's queue actions act on: every track on the playlist,
    // not the page of it that happens to be drawn. The menu can be opened
    // before fetchPlaylistTracks() has answered, so an empty page asks again.
    function allTracks(cb) {
        if (trackModel.length > 0) { cb(trackModel.list()); return }
        if (root.playlistUuid.length === 0) return
        bridge.fetchPlaylistTracks(root.playlistUuid, function (t, err) {
            if (!err && t.length > 0) cb(t)
        })
    }

    // The tracklist again, without the header request or the loading overlay:
    // the page is already correct apart from one row.
    function reloadTracks() {
        if (root.playlistUuid.length === 0) return
        var requested = root.playlistUuid
        bridge.fetchPlaylistTrackRows(requested, function (t, err) {
            // A reply for a playlist the user has already left says nothing
            // about the one on screen.
            if (requested !== root.playlistUuid) return
            // The reason is not kept: a failed top-up leaves a correct page,
            // and the error panel is for a page with nothing on it.
            if (err) return
            root.tracks = t
        })
    }

    // ── reordering by drag ───────────────────────────────────────────────
    // Only in the list's own order with every row shown, so a drop between
    // two rows means the same place on Tidal; and one move at a time.
    property bool moving: false
    readonly property bool canReorder: root.playlistEditable && trackSort.key === ""
        && root.trackFilter.trim().length === 0 && !root.moving && !root.loading
        && trackModel.length > 1
    readonly property int rowHeight: 52
    property int  dragFrom: -1
    property real dragRowY: 0
    property real dragPressY: 0
    property real dragOffset: 0
    property int  _currentBefore: -1
    readonly property bool dragging: root.dragFrom >= 0
    // The gap the drop aims at, 0 above the first row to n below the last,
    // nearest the dragged row's middle; and the row's place after the drop.
    readonly property int dropGap: !root.dragging ? -1
        : Math.max(0, Math.min(trackModel.length,
              Math.round((root.dragRowY + root.dragOffset + root.rowHeight / 2
                          - (root.dragRowY - root.dragFrom * root.rowHeight)) / root.rowHeight)))
    readonly property int dropTo: root.dropGap > root.dragFrom ? root.dropGap - 1 : root.dropGap

    function beginMove(row, index, pressY) {
        root._currentBefore = tracksList.currentIndex
        // Keeps the dragged row alive while the list scrolls under it.
        tracksList.currentIndex = index
        root.dragFrom = index
        root.dragRowY = row.y
        root.dragPressY = pressY
        root.dragOffset = 0
    }
    // y is the pointer in the dragged row, which already carries the offset.
    function followMove(y) {
        if (root.dragging) root.dragOffset += y - root.dragPressY
    }
    function cancelMove() {
        edgeScroll.stop()
        if (!root.dragging) return
        root.dragFrom = -1
        root.dragOffset = 0
        tracksList.currentIndex = root._currentBefore
    }
    function endMove() {
        if (!root.dragging) return
        var from = root.dragFrom, to = root.dropTo
        root.cancelMove()
        if (to < 0 || to === from || from >= trackModel.length) return
        var requested = root.playlistUuid
        var trackId = Number(trackModel.sourceAt(from).id)
        root.moving = true
        // The row moves on Tidal's word, as a removal leaves on it.
        Edits.movePlaylistItem(requested, root.playlistTitle, trackId, from, to,
                               function (ok, stale) {
            if (requested !== root.playlistUuid) return
            root.moving = false
            if (stale === true) { Qt.callLater(root.reloadAfterStaleMove); return }
            if (ok !== true || Number((trackModel.sourceAt(from) || {}).id) !== trackId) return
            root.tracks = trackModel.withMoved(from, to)
        })
    }
    onTracksChanged: if (root.dragging) root.cancelMove()
    onCanReorderChanged: if (!root.canReorder && root.dragging) root.cancelMove()

    // Scrolls while the dragged row is held near the top or the bottom; the
    // row stays under the pointer, so it travels with the list.
    Timer {
        id: edgeScroll
        interval: 16
        repeat: true
        running: root.dragging
        readonly property real band: 48
        onTriggered: {
            var y = root.dragRowY + root.dragOffset + root.dragPressY - tracksList.contentY
            var top = detailBar.height + 40, bottom = tracksList.height
            var step = y < top + band ? -Math.min(16, top + band - y)
                     : y > bottom - band ? Math.min(16, y - (bottom - band)) : 0
            if (step === 0) return
            var lo = tracksList.originY
            var hi = tracksList.originY + Math.max(0, tracksList.contentHeight - tracksList.height)
            var next = Math.max(lo, Math.min(hi, tracksList.contentY + step))
            root.dragOffset += next - tracksList.contentY
            tracksList.contentY = next
        }
    }

    readonly property string staleMoveText:
        qsTr("This playlist was changed somewhere else, so nothing was moved. It has been reloaded.")
    function reloadAfterStaleMove() {
        Toasts.show(root.staleMoveText)
        loadPlaylistHeader(root.playlistUuid)
        reloadTracks()
    }

    // A removal was refused because the playlist changed somewhere else since
    // this page read it. Nothing was removed; the page reads it again.
    readonly property string staleRemovalText:
        qsTr("This playlist was changed somewhere else, so nothing was removed. It has been reloaded.")
    function reloadAfterStaleRemoval() {
        Toasts.show(root.staleRemovalText)
        loadPlaylistHeader(root.playlistUuid)
        reloadTracks()
    }

    function loadPlaylist() {
        loading = true
        loadError = ""
        loadOffline = false
        playlistEditable = false
        // Which playlist these replies are about; see MixPage.loadMix().
        var requested = playlistUuid
        bridge.fetchPlaylistTrackRows(requested, function (t, err) {
            if (requested !== root.playlistUuid) return
            root.loading = false
            if (err) { root.noteLoadError(err); return }
            root.tracks = t
        })
        loadPlaylistHeader(requested)
    }

    // The hero's own request: the page can be opened with nothing but a uuid,
    // and the tracks endpoint answers tracks only. `editable` decides whether
    // the user may edit. Nothing else the reply leaves out overwrites the caller's.
    function loadPlaylistHeader(requested) {
        bridge.fetchPlaylist(requested, function (p, err) {
            // Superseded first, and on its own: a reply about a playlist
            // already left must change nothing on the one now open, including
            // whether it is reported as refused.
            if (requested !== root.playlistUuid) return
            if (err) { root.noteLoadError(err); return }
            // An answer with no body leaves what the caller passed.
            if (!p) return
            if (p.title)       root.playlistTitle       = p.title
            if (p.coverUrl)    root.coverUrl            = p.coverUrl
            if (p.description) root.playlistDescription = p.description
            if (p.duration)    root.playlistDuration    = p.duration
            if (p.type)        root.playlistType        = p.type
            root.playlistEditable = p.editable === true
        })
    }

    ListView {
        id: tracksList
        objectName: "playlistTracksList"
        anchors.fill: parent
        clip: true
        model: trackModel
        // As on Collection's tracks: rows leaving the view become the ones
        // coming in, rather than each made anew.
        reuseItems: true
        boundsBehavior: Flickable.StopAtBounds
        // The rows' 16 px inset: a vertical ListView puts its delegates at
        // x 0 whatever x they ask for, so the view's margins inset them. The
        // header and footer step back out to the view's edges.
        leftMargin: Theme.space4
        // Plus the scroll bar's lane, so the rows end as far from its inner
        // edge as they start from the left edge.
        rightMargin: Theme.space4 + Math.round(vbar.width - vbar.leftPadding)
        readonly property real rowWidth: width - leftMargin - rightMargin

        // The hero, then the column headings, which stay under the bar once
        // the hero has scrolled away. Over the rows, which pass beneath them.
        header: Item {
            // Out to the view's edges by a transform: Qt 6.6's ListView
            // resets a header's or footer's x to 0.
            transform: Translate { x: -tracksList.leftMargin }
            width: tracksList.width
            z: 2
            // A height from the start: a Column reports one only after its
            // first layout, and the view, scrolled to that, stays past the hero.
            height: hero.height + headings.height
            // For the bar, opaque by the time the headings reach it.
            readonly property real heroHeight: hero.height

            DetailHero {
                id: hero
                width: tracksList.width
                kind: qsTr("Playlist")
                title: root.playlistTitle
                artSource: root.coverUrl
                // Without a cover of its own, the tracks' covers; see DetailHero.
                artCovers: trackModel.leadCovers
                artIcon: "playlist"
                onPinRequested: (x, y) => {
                    var p = hero.mapToItem(root, x, y)
                    root.showHeroPinMenu(p.x, p.y)
                }

                Text {
                    visible: root.playlistDescription.length > 0
                    Layout.fillWidth: true
                    text: root.playlistDescription
                    color: Theme.textSec
                    font.pixelSize: Theme.fontMeta
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }

                Text {
                    text: {
                        // One complete sentence per case rather than glued
                        // fragments, so a translation can reorder it.
                        var n = trackModel.length
                        var d = root.playlistDuration
                        // The count is the tracklist's, still on its way.
                        if (root.loading && n === 0)
                            return d > 0 ? Theme.lengthText(d) : ""
                        return d > 0 ? qsTr("%Ln track(s) · %1", "", n).arg(Theme.lengthText(d))
                                     : qsTr("%Ln track(s)", "", n)
                    }
                    color: Theme.textSec
                    font.pixelSize: Theme.fontBody
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // Narrows the list to the tracks whose title, artists or album
                // hold every word typed. Play and Shuffle still take them all.
                SearchBar {
                    objectName: "playlistFilter"
                    visible: trackModel.length > 0
                    Layout.preferredWidth: 280
                    Layout.topMargin: Theme.space1
                    placeholder: qsTr("Find in this playlist…")
                    text: root.trackFilter
                    onTextEdited: (txt) => { root.trackFilter = txt }
                }

                actions: [
                    PillButton {
                        text: qsTr("Play", "verb, button label")
                        icon: "play"
                        accent: true
                        onClicked: {
                            if (trackModel.length > 0) {
                                bridge.markPlaylistPlayed(root.playlistUuid)
                                root.playFrom(trackModel.sortedRows(), 0)
                            }
                        }
                    },
                    PillButton {
                        text: qsTr("Shuffle")
                        icon: "shuffle"
                        accent: false
                        onClicked: {
                            if (trackModel.length > 0) {
                                bridge.markPlaylistPlayed(root.playlistUuid)
                                player.setShuffle(true)
                                root.playFrom(trackModel.sortedRows(), Math.floor(Math.random() * trackModel.length))
                            }
                        }
                    },
                    PillButton {
                        objectName: "playlistEditButton"
                        visible: root.playlistEditable
                        text: qsTr("Edit")
                        icon: "edit"
                        accent: false
                        onClicked: {
                            editTitleField.text         = root.playlistTitle
                            editDescField.text          = root.playlistDescription
                            editPlaylistPopup.errorText = ""
                            editPlaylistPopup.busy      = false
                            editPlaylistPopup.open()
                        }
                },
                DownloadAction {
                    kind: "playlist"
                    itemId: root.playlistUuid
                    folderName: root.playlistTitle
                    trackSource: root.allTracks
                },
                // The hero's menu, which right-click also opens: the queue
                // actions, Pin and Copy link.
                IconButton {
                    objectName: "heroMoreButton"
                    icon: "more"
                    label: qsTranslate("DetailHero", "More", "button that opens the page's menu")
                    size: 20
                    pad: Theme.space5
                    backed: true
                    onClicked: {
                        var p = mapToItem(root, 0, height)
                        root.showHeroPinMenu(p.x, p.y)
                    }
                    }
                ]
            }

            TrackListHeader {
                id: headings
                objectName: "playlistTracksHeader"
                y: hero.height
                pinIn: tracksList
                pinBelow: detailBar.height
                // Over the rows, inset as they are.
                x: tracksList.leftMargin
                width: tracksList.rowWidth
                sort: trackSort
                showAlbum: width - root.sidebarReclaim >= albumBreakpoint
                showAdded: width - root.sidebarReclaim >= addedBreakpoint
            }
        }

        delegate: TrackRow {
            id: playlistTrackRow
            objectName: "playlistTrackRow"
            width: tracksList.rowWidth
            // Against the width this row would have with the sidebar out, so
            // the column cannot reappear as the window narrows. See
            // root.sidebarReclaim.
            showAlbum:      width - root.sidebarReclaim >= albumBreakpoint
            showAdded:      width - root.sidebarReclaim >= addedBreakpoint
            // Its number on the playlist, filtered or sorted.
            trackNum:       place + 1
            title:          modelData.title
            artists:        modelData.artists
            albumTitle:     modelData.albumTitle
            durationStr:    modelData.durationStr
            coverUrl:       modelData.coverUrl80
            trackData:      modelData
            playlistUuid:   root.playlistEditable ? root.playlistUuid : ""
            // Its place on Tidal's list, which a sort does not move.
            trackItemIndex: place
            reorderable: root.canReorder
            z: reordering ? 2 : 0
            transform: Translate { y: playlistTrackRow.reordering ? root.dragOffset : 0 }
            onReorderStarted: (x, y) => root.beginMove(playlistTrackRow, index, y)
            onReorderMoved: (x, y) => root.followMove(y)
            onReorderEnded: root.endMove()
            onReorderCanceled: root.cancelMove()
            onPlayRequested: {
                bridge.markPlaylistPlayed(root.playlistUuid)
                root.playFrom(trackModel.shownRows(), index)
            }
            // The row leaves the page only on the server's word. The count
            // beside the title reads trackModel.length, and the bridge repairs
            // the cached counts drawn elsewhere.
            onRemoveFromPlaylistRequested: function(itemIndex) {
                var requested = root.playlistUuid
                var row = playlistTrackRow
                var trackId = Number(modelData.id)
                var named = root.playlistTitle
                var had = trackModel.countOf(trackId)
                // Edits confirms it with Tidal before it says so and offers Undo.
                Edits.removeFromPlaylist(requested, named, trackId, itemIndex, had,
                                         function(ok, stale, index) {
                    if (requested !== root.playlistUuid) return
                    if (stale === true) { Qt.callLater(root.reloadAfterStaleRemoval); return }
                    // Before the list is touched, which rebuilds the rows. An
                    // earlier splice may have destroyed this one already.
                    if (row) row.confirmRemovedFromPlaylist(ok === true)
                    if (ok === true && index >= 0 && index < trackModel.length) {
                        // The row the server took out, not itemIndex when an
                        // earlier removal landed in between.
                        root.tracks = trackModel.withRemoved(index)
                    }
                })
            }
        }

        // The footer, so the message sits directly beneath the header and
        // scrolls with it, as on MixPage.
        footer: Item {
            transform: Translate { x: -tracksList.leftMargin }
            width: tracksList.width
            height: root.loadFailed ? loadErrorState.implicitHeight + 2 * Theme.space12
                  : noMatches.visible ? noMatches.implicitHeight + 2 * Theme.space12 : 32

            // The filter left no rows: said in the list, as the collection
            // says it, with the way back.
            ColumnLayout {
                id: noMatches
                objectName: "playlistNoMatches"
                visible: !root.loadFailed && trackModel.length > 0
                         && root.trackFilter.trim().length > 0 && trackModel.count === 0
                anchors.centerIn: parent
                width: Math.min(parent.width - 96, 420)
                spacing: Theme.space2
                Text {
                    objectName: "playlistNoMatchesText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("No tracks match \"%1\"").arg(root.trackFilter.trim())
                    color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true
                }
                Text {
                    objectName: "playlistNoMatchesHint"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("Clear the field above to see every track again.")
                    color: Theme.textSec; font.pixelSize: Theme.fontMeta
                }
            }

            ErrorState {
                id: loadErrorState
                objectName: "playlistLoadError"
                visible: root.loadFailed
                anchors.centerIn: parent
                width: Math.min(parent.width - 96, 420)
                namePrefix: "playlistLoadError"
                icon: "playlist"
                offline: root.loadOffline
                title: qsTr("This playlist could not be loaded")
                // One long literal, since lupdate cannot read a concatenation.
                detail: qsTr("Tidal would not serve its tracks. Whoever made it may have deleted it or made it private, and a playlist saved before that stays in your collection either way.")
                onRetry: root.retryLoad()
            }
        }

        ScrollBar.vertical: ScrollBar {
            id: vbar
            objectName: "playlistScrollBar"
            active: true
            policy: ScrollBar.AsNeeded
            // A long list keeps a handle the pointer can find and grab.
            minimumSize: availableHeight > 0 ? Math.min(1, Theme.scrollHandleMin / availableHeight) : 0
        }
        WheelStep { view: tracksList }

        // Where the dragged row would land: a line in the gap.
        Rectangle {
            objectName: "playlistDropIndicator"
            visible: root.dragging && root.dropTo !== root.dragFrom
            x: tracksList.leftMargin + Theme.space2
            width: tracksList.rowWidth - 2 * Theme.space2
            height: 2
            color: Theme.accent
            y: root.dragRowY + (root.dropGap - root.dragFrom) * root.rowHeight - tracksList.contentY - 1
            z: 3
        }
    }

    DetailBar {
        id: detailBar
        objectName: "playlistStickyHeader"
        flickable: tracksList
        heroHeight: tracksList.headerItem ? tracksList.headerItem.heroHeight : 280
        title: root.playlistTitle
    }

    Skeleton { loading: root.loading; kind: "detail" }

    // The pin carries the labels and the artwork the page is showing, so the
    // sidebar row reads the same as the page it came from.
    readonly property alias pinMenu: heroPinMenu

    function showHeroPinMenu(x, y) {
        heroPinMenu.showPin(x, y, "playlist", root.playlistUuid,
                            root.playlistTitle, "", root.coverUrl)
    }

    ContextMenu {
        id: heroPinMenu
        objectName: "heroPinMenu"
        trackSource: root.allTracks
    }

    // ── Edit playlist ────────────────────────────────────────────────────
    // A test's handle on the dialog: a Popup reparents itself to the window
    // overlay, so it is not reachable by walking this page's children.
    readonly property alias editPopup: editPlaylistPopup

    // What the dialog does with what was typed. The page's own two properties
    // are written on the answer, and only on a success.
    function saveEdits() {
        if (editPlaylistPopup.busy) return

        var newTitle = editTitleField.text.trim()
        var newDesc  = editDescField.text.trim()
        // Reachable: the Save button is disabled for an empty name, but Return
        // in the field is not. Same wording as NewPlaylistDialog's.
        if (newTitle.length === 0) {
            editPlaylistPopup.errorText = qsTr("Enter a name for the playlist.")
            return
        }
        if (root.playlistUuid.length === 0) {
            editPlaylistPopup.errorText = qsTr("Could not save the changes.")
            return
        }

        // Which playlist this reply is about. The dialog can stay open across a
        // navigation, and the answer must not rename whatever page is showing.
        var requested = root.playlistUuid
        editPlaylistPopup.busy      = true
        editPlaylistPopup.errorText = ""
        bridge.editPlaylist(requested, newTitle, newDesc, function (ok) {
            editPlaylistPopup.busy = false
            if (ok !== true) {
                editPlaylistPopup.errorText = qsTr("Could not save the changes.")
                return
            }
            if (requested === root.playlistUuid) {
                root.playlistTitle       = newTitle
                root.playlistDescription = newDesc
            }
            editPlaylistPopup.close()
        })
    }

    Popup {
        id: editPlaylistPopup
        objectName: "editPlaylistPopup"
        anchors.centerIn: Overlay.overlay
        width: 400
        modal: true
        // Dims the app behind, as the queue panel does. Fusion's own is faint.
        Overlay.modal: Rectangle { color: Theme.scrim }
        focus: true
        // No way out of the dialog while a request is out, so the user can
        // always tell whether the rename took.
        closePolicy: editPlaylistPopup.busy
                     ? Popup.NoAutoClose
                     : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
        padding: Theme.space5
        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }

        // Mirrors NewPlaylistDialog: the field goes read-only and both buttons
        // go quiet while the request is out.
        property bool busy: false
        // A failure keeps the dialog up with the text still in it.
        property string errorText: ""

        onOpened: editTitleField.forceActiveFocus()

        Column {
            width: parent.width
            spacing: Theme.space4

            Text { text: qsTr("Edit playlist"); color: Theme.textPrimary; font.pixelSize: Theme.fontTitle; font.bold: true }

            Rectangle { width: parent.width; height: 1; color: Theme.border }

            Text { text: qsTr("Title"); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
            Rectangle {
                width: parent.width; height: 36; radius: Theme.radiusField
                // The field's own activeFocus: a FocusScope that is a child of
                // the TextInput never gains activeFocus with it.
                color: Theme.surface
                border.color: editTitleField.activeFocus ? Theme.accent : Theme.border
                TextInput {
                    id: editTitleField
                    objectName: "editPlaylistTitleField"
                    anchors.fill: parent; anchors.margins: Theme.space2
                    color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                    selectByMouse: true
                    selectionColor: Theme.textSelection
                    selectedTextColor: Theme.textSelectionInk
                    // The same cap the create dialog applies, so a title the
                    // server would refuse cannot be typed in either place.
                    maximumLength: 100
                    readOnly: editPlaylistPopup.busy
                    // Typing is the user answering the complaint.
                    onTextChanged: if (editPlaylistPopup.errorText.length > 0)
                                       editPlaylistPopup.errorText = ""
                    Keys.onReturnPressed: root.saveEdits()
                    Keys.onEnterPressed:  root.saveEdits()
                }
            }

            Text { text: qsTr("Description"); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
            Rectangle {
                width: parent.width; height: 72; radius: Theme.radiusField
                // See the title field for why this is not a FocusScope.
                color: Theme.surface
                border.color: editDescField.activeFocus ? Theme.accent : Theme.border
                TextEdit {
                    id: editDescField
                    objectName: "editPlaylistDescField"
                    anchors.fill: parent; anchors.margins: Theme.space2
                    color: Theme.textPrimary; font.pixelSize: Theme.fontBody
                    wrapMode: TextEdit.WordWrap
                    selectByMouse: true
                    selectionColor: Theme.textSelection
                    selectedTextColor: Theme.textSelectionInk
                    readOnly: editPlaylistPopup.busy
                    onTextChanged: if (editPlaylistPopup.errorText.length > 0)
                                       editPlaylistPopup.errorText = ""
                }
            }

            // Drawn only when something went wrong, and inside the dialog, so
            // the text in the two fields is kept.
            Text {
                objectName: "editPlaylistError"
                width: parent.width
                // No explicit height. A Column skips an invisible child, and
                // `height: visible ? implicitHeight : 0` on a wrapping Text is
                // a binding loop.
                visible: editPlaylistPopup.errorText.length > 0
                text: editPlaylistPopup.errorText
                color: Theme.redText
                font.pixelSize: Theme.fontMeta
                wrapMode: Text.WordWrap
            }

            RowLayout {
                width: parent.width
                spacing: Theme.space3
                // Away from Save, so it is not hit on the way there.
                PillButton {
                    objectName: "editPlaylistDelete"
                    text: qsTr("Delete", "verb, the button that deletes the playlist")
                    danger: true
                    enabled: !editPlaylistPopup.busy
                    opacity: enabled ? 1 : 0.45
                    Layout.preferredWidth:  implicitWidth
                    Layout.preferredHeight: implicitHeight
                    onClicked: {
                        editPlaylistPopup.close()
                        deletePlaylistDialog.askFor(root.playlistUuid, root.playlistTitle)
                    }
                }
                Item { Layout.fillWidth: true }
                PillButton {
                    objectName: "editPlaylistCancel"
                    text: qsTr("Cancel"); accent: false
                    // PillButton draws no disabled state of its own; see
                    // NewPlaylistDialog's pair.
                    enabled: !editPlaylistPopup.busy
                    opacity: enabled ? 1 : 0.45
                    Layout.preferredWidth:  implicitWidth
                    Layout.preferredHeight: implicitHeight
                    onClicked: editPlaylistPopup.close()
                }
                PillButton {
                    objectName: "editPlaylistSave"
                    text: editPlaylistPopup.busy
                          ? qsTr("Saving…")
                          : qsTr("Save", "verb, confirm the edits in this dialog")
                    accent: true
                    enabled: !editPlaylistPopup.busy
                             && editTitleField.text.trim().length > 0
                    opacity: enabled ? 1 : 0.45
                    Layout.preferredWidth:  implicitWidth
                    Layout.preferredHeight: implicitHeight
                    onClicked: root.saveEdits()
                }
            }
        }
    }

    // Main leaves the page once the bridge says the playlist is gone.
    readonly property alias deleteDialog: deletePlaylistDialog
    DeletePlaylistDialog { id: deletePlaylistDialog }
}
