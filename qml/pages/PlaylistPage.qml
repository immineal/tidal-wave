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
    property string playlistType: ""   // "USER" = editable, "" / "EDITORIAL" = read-only
    property var    tracks: []
    property bool   loading: false

    readonly property bool isUserPlaylist: playlistType === "USER"

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

    // "1 hr 4 min" / "52 min". Each case is a whole translatable string, so a
    // translation can reorder or re-unit it instead of inheriting English order.
    function durationText(seconds) {
        var loc  = Qt.locale()
        var hrs  = Math.floor(seconds / 3600)
        var mins = Math.floor((seconds % 3600) / 60)
        return hrs > 0
            ? qsTr("%1 hr %2 min").arg(hrs.toLocaleString(loc, 'f', 0)).arg(mins.toLocaleString(loc, 'f', 0))
            : qsTr("%1 min").arg(mins.toLocaleString(loc, 'f', 0))
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

    function loadPlaylist() {
        loading = true
        loadError = ""
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
    // and the tracks endpoint answers tracks only. `type` decides whether the
    // user may edit. Nothing the reply leaves out overwrites the caller's.
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
        })
    }

    ListView {
        id: tracksList
        anchors.fill: parent
        clip: true
        model: root.tracks
        boundsBehavior: Flickable.StopAtBounds

        header: Rectangle {
            width: tracksList.width
            // Grows with its content, so a wrapped title, description or pill
            // row is not cut off.
            implicitHeight: Math.max(240, heroRow.implicitHeight + 48)
            color: "transparent"

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0; color: Theme.accentTint }
                    GradientStop { position: 1; color: Theme.bg }
                }
            }

            RowLayout {
                id: heroRow
                anchors {
                    left: parent.left; right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: 64; rightMargin: 24
                }
                spacing: 24

                Rectangle {
                    objectName: "heroArt"
                    width: 180
                    height: 180
                    radius: Theme.radiusArt
                    color: Theme.accentWash
                    clip: true
                    Image {
                        id: playlistCover
                        objectName: "heroCover"
                        anchors.fill: parent
                        visible: root.coverUrl.length > 0
                        source: root.coverUrl.length > 0 ? "image://tidal/" + root.coverUrl : ""
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                        opacity: status === Image.Ready ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.dur(200) } }
                    }
                    Grid {
                        id: collageGrid
                        anchors.fill: parent
                        columns: 2
                        rows: 2
                        visible: root.coverUrl.length === 0 && root.tracks.length >= 4
                        Repeater {
                            model: root.tracks.slice(0, 4)
                            Image {
                                width: 90
                                height: 90
                                source: (modelData && modelData.coverUrl) ? "image://tidal/" + modelData.coverUrl : ""
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                                mipmap: true
                            }
                        }
                    }
                    VectorIcon {
                        visible: !playlistCover.visible && !collageGrid.visible
                        anchors.centerIn: parent
                        name: "playlist"
                        color: Theme.accent
                        width: 64
                        height: 64
                        strokeWidth: 1.5
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 8

                    Text {
                        text: qsTr("Playlist")
                        color: Theme.textSec
                        font.pixelSize: 12
                        font.bold: true
                        font.letterSpacing: 1
                    }

                    Text {
                        objectName: "heroTitle"
                        Layout.fillWidth: true
                        text: root.playlistTitle
                        color: Theme.textPrimary
                        font.pixelSize: 28
                        font.bold: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: root.playlistDescription.length > 0
                        Layout.fillWidth: true
                        text: root.playlistDescription
                        color: Theme.textSec
                        font.pixelSize: 13
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
                            return d > 0 ? qsTr("%n track(s) • %1", "", n).arg(root.durationText(d))
                                         : qsTr("%n track(s)", "", n)
                        }
                        color: Theme.textSec
                        font.pixelSize: 14
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }

                    // A Flow, so the pills wrap in a narrow pane.
                    Flow {
                        id: heroActions
                        Layout.fillWidth: true
                        spacing: 12
                        // The queue confirmation is drawn just above this row.
                        // Assigned, not bound: an id inside the list's header
                        // component is out of reach from the page root.
                        Component.onCompleted: if (heroPinMenu) heroPinMenu.confirmAnchor = heroActions

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
                        }

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
                        }

                        PillButton {
                            objectName: "playlistEditButton"
                            visible: root.isUserPlaylist
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
                    }
                }
            }

            // A right-click on the hero pins what the page is showing.
            MouseArea {
                objectName: "heroPinArea"
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: function (mouse) {
                    var p = mapToItem(root, mouse.x, mouse.y)
                    root.showHeroPinMenu(p.x, p.y)
                }
            }
        }

        delegate: TrackRow {
            id: playlistTrackRow
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
            isPlaying:      player.currentTrack.id === modelData.id && player.playing
            trackData:      modelData
            playlistUuid:   root.isUserPlaylist ? root.playlistUuid : ""
            trackItemIndex: index
            onPlayRequested: {
                bridge.markPlaylistPlayed(root.playlistUuid)
                root.playFrom(root.tracks, index)
            }
            // The row leaves the page only on the server's word. The count
            // beside the title reads root.tracks.length, and the bridge repairs
            // the cached counts drawn elsewhere.
            onRemoveFromPlaylistRequested: function(itemIndex) {
                bridge.removeTrackFromPlaylist(root.playlistUuid, itemIndex, function(ok) {
                    // Called before the list is touched: a successful removal
                    // takes this delegate's row out of the model.
                    playlistTrackRow.confirmRemovedFromPlaylist(ok === true)
                    if (ok) {
                        var arr = root.tracks.slice()
                        arr.splice(itemIndex, 1)
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
                spacing: 10

                VectorIcon {
                    Layout.alignment: Qt.AlignHCenter
                    // A Layout owns the size of its direct children, so a plain
                    // width would be overwritten.
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    name: "playlist"
                    color: Theme.textDim
                    strokeWidth: 1.5
                }

                Text {
                    objectName: "playlistLoadErrorText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("This playlist could not be loaded")
                    color: Theme.textPrimary
                    font.pixelSize: 18
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
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                }
            }
        }

        ScrollBar.vertical: ScrollBar {
            active: true
            policy: ScrollBar.AsNeeded
        }
    }

    // Back button sits in a fixed bar that doesn't overlap the track list
    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52; color: "transparent"
        BackButton { anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 } }
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
        padding: 20
        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }

        // Mirrors NewPlaylistDialog: the field goes read-only and both buttons
        // go quiet while the request is out.
        property bool busy: false
        // A failure keeps the dialog up with the text still in it.
        property string errorText: ""

        onOpened: editTitleField.forceActiveFocus()

        Column {
            width: parent.width
            spacing: 14

            Text { text: qsTr("Edit Playlist"); color: Theme.textPrimary; font.pixelSize: 16; font.bold: true }

            Rectangle { width: parent.width; height: 1; color: Theme.border }

            Text { text: qsTr("Title"); color: Theme.textSec; font.pixelSize: 12 }
            Rectangle {
                width: parent.width; height: 36; radius: Theme.radiusField
                // The field's own activeFocus: a FocusScope that is a child of
                // the TextInput never gains activeFocus with it.
                color: Theme.surface
                border.color: editTitleField.activeFocus ? Theme.accent : Theme.border
                TextInput {
                    id: editTitleField
                    objectName: "editPlaylistTitleField"
                    anchors.fill: parent; anchors.margins: 8
                    color: Theme.textPrimary; font.pixelSize: 14
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

            Text { text: qsTr("Description"); color: Theme.textSec; font.pixelSize: 12 }
            Rectangle {
                width: parent.width; height: 72; radius: Theme.radiusField
                // See the title field for why this is not a FocusScope.
                color: Theme.surface
                border.color: editDescField.activeFocus ? Theme.accent : Theme.border
                TextEdit {
                    id: editDescField
                    objectName: "editPlaylistDescField"
                    anchors.fill: parent; anchors.margins: 8
                    color: Theme.textPrimary; font.pixelSize: 14
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
                color: Theme.red
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            Row {
                spacing: 10; anchors.right: parent.right
                PillButton {
                    objectName: "editPlaylistCancel"
                    text: qsTr("Cancel"); accent: false
                    // PillButton draws no disabled state of its own; see
                    // NewPlaylistDialog's pair.
                    enabled: !editPlaylistPopup.busy
                    opacity: enabled ? 1 : 0.45
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
                    onClicked: root.saveEdits()
                }
            }
        }
    }
}
