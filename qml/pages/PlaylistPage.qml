import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    // How much of this pane's width is only on loan. Below Prefs::railBreakpoint
    // the sidebar collapses to its 68px rail and hands the page back the ~150px
    // it had been using, so the pane gets *wider* as the window gets narrower:
    // the pane's width does not fall with the window's, it has a step in it.
    // Any column that switches on the pane therefore un-hides itself halfway
    // down a drag. The track rows' album column dropped out at an 892px window,
    // came back at 819 when the rail took over, and went again at 740, which is
    // the flicker the user saw. Subtracting the loan measures the breakpoint
    // against a width that only ever shrinks with the window, and across the
    // step it is the same number on both sides, so nothing jumps there either.
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

    function loadPlaylist() {
        loading = true
        // Which playlist these replies are about; see MixPage.loadMix().
        var requested = playlistUuid
        bridge.fetchPlaylistTracks(requested, function (t, err) {
            if (requested !== root.playlistUuid) return
            loading = false
            if (!err) tracks = t
        })
        loadPlaylistHeader(requested)
    }

    // The hero's own request, for the same reason MixPage makes one: this page
    // can be opened with nothing but a uuid, and the "Playing from" link in Now
    // Playing opens it with a uuid and an explicit empty cover.
    //
    // It is a second request where the mix's header came free, because
    // `playlists/<uuid>/tracks` answers tracks and nothing else - there is no
    // module beside them to read. And `type` is the field that makes it worth
    // a request of its own: it is not decoration, it is what decides whether
    // the user may edit a playlist they own. Opened from Now Playing it
    // arrived as "", which reads as EDITORIAL, so their own playlist opened
    // read-only.
    //
    // Nothing the reply leaves out overwrites what the caller passed, and a
    // reply that never comes overwrites nothing at all.
    function loadPlaylistHeader(requested) {
        bridge.fetchPlaylist(requested, function (p, err) {
            if (err || !p || requested !== root.playlistUuid) return
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
            // Grows with its content rather than sitting at a fixed 240: a
            // wrapped title, a three line description or a wrapped pill row
            // used to be cut off at the bottom edge.
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
                        // As on MixPage: the type's own glyph where there is
                        // neither a cover nor four tracks to collage.
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

                    // A Flow, so the pills wrap onto a second line instead of
                    // pushing the column past the hero's right edge. Three
                    // pills are 384px at the old fixed width, more than the
                    // 328px the column gets in a 640px pane.
                    Flow {
                        id: heroActions
                        Layout.fillWidth: true
                        spacing: 12
                        // The queue confirmation is drawn just above the row
                        // of actions it confirms. Assigned rather than bound:
                        // the hero lives in the list's header, and an id
                        // inside that component is out of reach from the page
                        // root, where the menu is.
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

            // P2: a right-click on the hero pins what the page is showing.
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
            onRemoveFromPlaylistRequested: function(itemIndex) {
                bridge.removeTrackFromPlaylist(root.playlistUuid, itemIndex, function(ok) {
                    if (ok) {
                        var arr = root.tracks.slice()
                        arr.splice(itemIndex, 1)
                        root.tracks = arr
                    }
                })
            }
        }

        footer: Item { height: 32; width: tracksList.width }

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

    // P2. The pin carries the labels and the artwork the page is showing, so
    // the sidebar row reads the same as the page it came from.
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
    //
    // A test's handle on the dialog; a Popup reparents itself to the window
    // overlay, so it is not reachable by walking this page's children.
    readonly property alias editPopup: editPlaylistPopup

    // What the dialog does with what was typed.
    //
    // It used to write the two fields straight into root.playlistTitle and
    // root.playlistDescription and stop - no call, no error, no sign that
    // anything was missing. Navigating away threw the rename away, and from
    // the user's seat that is data loss with a confirmation attached: the
    // dialog had accepted the edit and reported nothing wrong.
    //
    // So the page's own two properties are written on the *answer* and only
    // on a success. A page that renamed itself optimistically would be the
    // same lie one frame later.
    function saveEdits() {
        if (editPlaylistPopup.busy) return

        var newTitle = editTitleField.text.trim()
        var newDesc  = editDescField.text.trim()
        // Reachable: the Save button is dark for an empty name, but Return in
        // the field is not, and a key that silently does nothing reads as a
        // broken dialog. Same wording as NewPlaylistDialog's.
        if (newTitle.length === 0) {
            editPlaylistPopup.errorText = qsTr("Enter a name for the playlist.")
            return
        }
        if (root.playlistUuid.length === 0) {
            editPlaylistPopup.errorText = qsTr("Could not save the changes.")
            return
        }

        // Which playlist this reply is about; see loadPlaylist(). The dialog
        // can be left open across a navigation, and writing a name onto
        // whatever page is showing when the answer lands would rename the
        // wrong playlist in the interface.
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
        // A request is out: no way out of the dialog until it answers. Leaving
        // under a call that is still going to reply means the user cannot tell
        // whether the rename took, which is the state this whole dialog was in
        // before it had a call at all.
        closePolicy: editPlaylistPopup.busy
                     ? Popup.NoAutoClose
                     : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
        padding: 20
        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }

        // Mirrors NewPlaylistDialog: the field goes read-only and both buttons
        // go quiet while the POST is out...
        property bool busy: false
        // ...and a failure keeps the dialog up with the text still in it, so
        // the answer to a failed save is one click rather than retyping.
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
                // The field's own activeFocus, not a FocusScope parked inside
                // it. A FocusScope that is a *child* of the TextInput never
                // gains activeFocus when the TextInput does, so this border
                // never lit: the ring was unreachable rather than subtle.
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

            // Only ever drawn when something went wrong, and it keeps the
            // dialog up: a toast would lose the text that is still in the two
            // fields. Deliberately not a line that is always present - the
            // dialog is tall enough already.
            Text {
                objectName: "editPlaylistError"
                width: parent.width
                // No explicit height. A Column skips an invisible child
                // entirely, and `height: visible ? implicitHeight : 0` on a
                // wrapping Text is a binding loop - which tst_firstrun turns
                // into a failure, because it fails on any QML warning.
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
