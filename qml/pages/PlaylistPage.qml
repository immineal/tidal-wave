import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

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

    function loadPlaylist() {
        loading = true
        bridge.fetchPlaylistTracks(playlistUuid, function(t, err) {
            loading = false
            if (!err) tracks = t
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
                    width: 180
                    height: 180
                    radius: Theme.radiusArt
                    color: Theme.accentWash
                    clip: true
                    Image {
                        id: playlistCover
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
                        name: "music"
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
                        Layout.fillWidth: true
                        spacing: 12

                        PillButton {
                            text: qsTr("Play", "verb, button label")
                            glyph: "▶"
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
                            glyph: "⇌"
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
                            visible: root.isUserPlaylist
                            text: qsTr("Edit")
                            glyph: "✎"
                            accent: false
                            onClicked: {
                                editTitleField.text   = root.playlistTitle
                                editDescField.text    = root.playlistDescription
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
    }

    // Edit playlist popup
    Popup {
        id: editPlaylistPopup
        anchors.centerIn: Overlay.overlay
        width: 400
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 20
        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }

        Column {
            width: parent.width
            spacing: 14

            Text { text: qsTr("Edit Playlist"); color: Theme.textPrimary; font.pixelSize: 16; font.bold: true }

            Rectangle { width: parent.width; height: 1; color: Theme.border }

            Text { text: qsTr("Title"); color: Theme.textSec; font.pixelSize: 12 }
            Rectangle {
                width: parent.width; height: 36; radius: Theme.radiusField
                color: Theme.surface; border.color: titleFocus.activeFocus ? Theme.accent : Theme.border
                TextInput {
                    id: editTitleField
                    anchors.fill: parent; anchors.margins: 8
                    color: Theme.textPrimary; font.pixelSize: 14
                    selectionColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                    FocusScope { id: titleFocus; anchors.fill: parent }
                }
            }

            Text { text: qsTr("Description"); color: Theme.textSec; font.pixelSize: 12 }
            Rectangle {
                width: parent.width; height: 72; radius: Theme.radiusField
                color: Theme.surface; border.color: descFocus.activeFocus ? Theme.accent : Theme.border
                TextEdit {
                    id: editDescField
                    anchors.fill: parent; anchors.margins: 8
                    color: Theme.textPrimary; font.pixelSize: 14
                    wrapMode: TextEdit.WordWrap
                    selectionColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                    FocusScope { id: descFocus; anchors.fill: parent }
                }
            }

            Row {
                spacing: 10; anchors.right: parent.right
                PillButton {
                    text: qsTr("Cancel"); accent: false
                    onClicked: editPlaylistPopup.close()
                }
                PillButton {
                    text: qsTr("Save", "verb, confirm the edits in this dialog"); accent: true
                    onClicked: {
                        var newTitle = editTitleField.text.trim()
                        if (newTitle.length > 0) root.playlistTitle = newTitle
                        root.playlistDescription = editDescField.text.trim()
                        editPlaylistPopup.close()
                    }
                }
            }
        }
    }
}
