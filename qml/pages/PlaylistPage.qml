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
    property var    tracks: []
    property bool   loading: false

    // What the last load was told, "" when it was served.
    property string loadError: ""

    // Nothing came back at all. The hero stays, since the caller's title and
    // artwork are still correct. Gated on what the server said: a playlist with
    // no songs in it is ordinary.
    readonly property bool loadFailed:
        loadError.length > 0 && !loading && tracks.length === 0

    // The first reason is kept; see ArtistPage.noteLoadError().
    function noteLoadError(err) {
        if (root.loadError.length === 0) root.loadError = err
    }

    // Records this playlist as the "playing from" source, then starts playback.
    function playFrom(list, i) {
        player.setPlaybackSource("playlist", root.playlistUuid, root.playlistTitle)
        player.playTracks(list, i)
    }

    onPlaylistUuidChanged: if (playlistUuid.length > 0) loadPlaylist()

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
                if (cached[i].numTracks !== root.tracks.length)
                    root.reloadTracks()
                return
            }
        }
    }

    // What the hero's queue actions act on: every track on the playlist,
    // not the page of it that happens to be drawn. The menu can be opened
    // before fetchPlaylistTracks() has answered, so an empty page asks again.
    function allTracks(cb) {
        if (root.tracks.length > 0) { cb(root.tracks); return }
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
        bridge.fetchPlaylistTracks(requested, function (t, err) {
            // A reply for a playlist the user has already left says nothing
            // about the one on screen.
            if (requested !== root.playlistUuid) return
            // The reason is not kept: a failed top-up leaves a correct page,
            // and the error panel is for a page with nothing on it.
            if (err) return
            root.tracks = t
        })
    }

    // A removal was refused because the playlist changed somewhere else since
    // this page read it. Nothing was removed; the page reads it again.
    readonly property string staleRemovalText:
        qsTr("This playlist was changed somewhere else, so nothing was removed. It has been reloaded.")
    function reloadAfterStaleRemoval() {
        tracksList.ToolTip.show(root.staleRemovalText, 5000)
        loadPlaylistHeader(root.playlistUuid)
        reloadTracks()
    }

    function loadPlaylist() {
        loading = true
        loadError = ""
        playlistEditable = false
        // Which playlist these replies are about; see MixPage.loadMix().
        var requested = playlistUuid
        bridge.fetchPlaylistTracks(requested, function (t, err) {
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
        anchors.fill: parent
        clip: true
        model: root.tracks
        boundsBehavior: Flickable.StopAtBounds

        header: DetailHero {
            id: hero
            width: tracksList.width
            kind: qsTr("Playlist")
            title: root.playlistTitle
            artSource: root.coverUrl
            // Without a cover of its own, the first four tracks' covers.
            artCovers: root.tracks.slice(0, 4).map(function (t) { return t ? t.coverUrl || "" : "" })
            artIcon: "playlist"
            onPinRequested: (x, y) => {
                var p = hero.mapToItem(root, x, y)
                root.showHeroPinMenu(p.x, p.y)
            }
            // The queue confirmation is drawn just above the action row.
            // Assigned, not bound: an id inside the list's header component is
            // out of reach from the page root.
            Component.onCompleted: if (heroPinMenu) heroPinMenu.confirmAnchor = hero.actionRow

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
                    var n = root.tracks.length
                    var d = root.playlistDuration
                    // The count is the tracklist's, still on its way.
                    if (root.loading && n === 0)
                        return d > 0 ? Theme.lengthText(d) : ""
                    return d > 0 ? qsTr("%Ln track(s) • %1", "", n).arg(Theme.lengthText(d))
                                 : qsTr("%Ln track(s)", "", n)
                }
                color: Theme.textSec
                font.pixelSize: Theme.fontBody
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            actions: [
                PillButton {
                    text: qsTr("Play", "verb, button label")
                    icon: "play"
                    accent: true
                    onClicked: {
                        if (root.tracks.length > 0) {
                            bridge.markPlaylistPlayed(root.playlistUuid)
                            root.playFrom(root.tracks, 0)
                        }
                    }
                },
                PillButton {
                    text: qsTr("Shuffle")
                    icon: "shuffle"
                    accent: false
                    onClicked: {
                        if (root.tracks.length > 0) {
                            bridge.markPlaylistPlayed(root.playlistUuid)
                            player.setShuffle(true)
                            root.playFrom(root.tracks, Math.floor(Math.random() * root.tracks.length))
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
                }
            ]
        }

        delegate: TrackRow {
            id: playlistTrackRow
            objectName: "playlistTrackRow"
            width: tracksList.width - 32
            x: 16
            // Against the width this row would have with the sidebar out, so
            // the column cannot reappear as the window narrows. See
            // root.sidebarReclaim.
            showAlbum:      width - root.sidebarReclaim >= albumBreakpoint
            trackNum:       index + 1
            title:          modelData.title
            artists:        modelData.artists
            albumTitle:     modelData.albumTitle
            durationStr:    modelData.durationStr
            coverUrl:       modelData.coverUrl80
            trackData:      modelData
            playlistUuid:   root.playlistEditable ? root.playlistUuid : ""
            trackItemIndex: index
            onPlayRequested: {
                bridge.markPlaylistPlayed(root.playlistUuid)
                root.playFrom(root.tracks, index)
            }
            // The row leaves the page only on the server's word. The count
            // beside the title reads root.tracks.length, and the bridge repairs
            // the cached counts drawn elsewhere.
            onRemoveFromPlaylistRequested: function(itemIndex) {
                var requested = root.playlistUuid
                var row = playlistTrackRow
                bridge.removeTrackFromPlaylist(requested, itemIndex, function(ok, stale, index) {
                    if (requested !== root.playlistUuid) return
                    if (stale === true) { Qt.callLater(root.reloadAfterStaleRemoval); return }
                    // Before the list is touched, which rebuilds the rows. An
                    // earlier splice may have destroyed this one already.
                    if (row) row.confirmRemovedFromPlaylist(ok === true)
                    if (ok === true && index >= 0 && index < root.tracks.length) {
                        // The row the server took out, not itemIndex when an
                        // earlier removal landed in between.
                        var arr = root.tracks.slice()
                        arr.splice(index, 1)
                        root.tracks = arr
                    }
                })
            }
        }

        // The footer, so the message sits directly beneath the header and
        // scrolls with it, as on MixPage.
        footer: Item {
            width: tracksList.width
            height: root.loadFailed ? 200 : 32

            ColumnLayout {
                objectName: "playlistLoadError"
                visible: root.loadFailed
                anchors.centerIn: parent
                width: Math.min(parent.width - 96, 420)
                spacing: Theme.space3

                VectorIcon {
                    Layout.alignment: Qt.AlignHCenter
                    // A Layout owns the size of its direct children, so a plain
                    // width would be overwritten.
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    name: "playlist"
                    color: Theme.textDim
                }

                Text {
                    objectName: "playlistLoadErrorText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("This playlist could not be loaded")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSection
                    font.bold: true
                    wrapMode: Text.WordWrap
                }

                // Not the server's own string; see AlbumPage's panel for why.
                // One long literal, since lupdate cannot read a concatenation.
                Text {
                    objectName: "playlistLoadErrorDetail"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Tidal would not serve its tracks. Whoever made it may have deleted it or made it private, and a playlist saved before that stays in your library either way.")
                    color: Theme.textSec
                    font.pixelSize: Theme.fontMeta
                    wrapMode: Text.WordWrap
                }
            }
        }

        ScrollBar.vertical: ScrollBar {
            active: true
            policy: ScrollBar.AsNeeded
        }
    }

    DetailBar {
        objectName: "playlistStickyHeader"
        flickable: tracksList
        heroHeight: tracksList.headerItem ? tracksList.headerItem.height : 280
        title: root.playlistTitle
    }

    LoadingOverlay { loading: root.loading }

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
        focus: true
        // No way out of the dialog while a request is out, so the user can
        // always tell whether the rename took.
        closePolicy: editPlaylistPopup.busy
                     ? Popup.NoAutoClose
                     : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
        padding: Theme.space5
        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusLarge }

        // Mirrors NewPlaylistDialog: the field goes read-only and both buttons
        // go quiet while the request is out.
        property bool busy: false
        // A failure keeps the dialog up with the text still in it.
        property string errorText: ""

        onOpened: editTitleField.forceActiveFocus()

        Column {
            width: parent.width
            spacing: Theme.space4

            Text { text: qsTr("Edit Playlist"); color: Theme.textPrimary; font.pixelSize: Theme.fontTitle; font.bold: true }

            Rectangle { width: parent.width; height: 1; color: Theme.border }

            Text { text: qsTr("Title"); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
            Rectangle {
                width: parent.width; height: 36; radius: Theme.radiusLarge
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
                    selectionColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
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
                width: parent.width; height: 72; radius: Theme.radiusLarge
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
                    selectionColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
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
