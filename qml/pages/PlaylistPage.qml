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
            height: 240
            color: "transparent"

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(0,0.698,0.973,0.15) }
                    GradientStop { position: 1; color: Theme.bg }
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.margins: 24
                anchors.leftMargin: 64
                spacing: 24

                Rectangle {
                    width: 180
                    height: 180
                    radius: Theme.radiusLg
                    color: Qt.rgba(0,0.698,0.973,0.2)
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
                        Behavior on opacity { NumberAnimation { duration: 200 } }
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
                        text: "Playlist"
                        color: Theme.textDim
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
                            var parts = [root.tracks.length === 1 ? "1 track" : root.tracks.length + " tracks"]
                            var d = root.playlistDuration
                            if (d > 0) {
                                var hrs = Math.floor(d / 3600)
                                var mins = Math.floor((d % 3600) / 60)
                                parts.push(hrs > 0 ? hrs + " hr " + mins + " min" : mins + " min")
                            }
                            return parts.join(" • ")
                        }
                        color: Theme.textSec
                        font.pixelSize: 14
                    }

                    Row {
                        spacing: 12

                        PillButton {
                            text: "Play"
                            glyph: "▶"
                            accent: true
                            onClicked: if (root.tracks.length > 0) player.playTracks(root.tracks, 0)
                        }

                        PillButton {
                            text: "Shuffle"
                            glyph: "⇌"
                            accent: false
                            onClicked: {
                                if (root.tracks.length > 0) {
                                    player.setShuffle(true)
                                    player.playTracks(root.tracks, Math.floor(Math.random() * root.tracks.length))
                                }
                            }
                        }

                        PillButton {
                            visible: root.isUserPlaylist
                            text: "Edit"
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
            onPlayRequested: player.playTracks(root.tracks, index)
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

    // Edit playlist popup
    Popup {
        id: editPlaylistPopup
        anchors.centerIn: Overlay.overlay
        width: 400
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 20
        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: 12 }

        Column {
            width: parent.width
            spacing: 14

            Text { text: "Edit Playlist"; color: Theme.textPrimary; font.pixelSize: 16; font.bold: true }

            Rectangle { width: parent.width; height: 1; color: Theme.border }

            Text { text: "Title"; color: Theme.textSec; font.pixelSize: 12 }
            Rectangle {
                width: parent.width; height: 36; radius: 6
                color: Theme.surface; border.color: titleFocus.activeFocus ? Theme.accent : Theme.border
                TextInput {
                    id: editTitleField
                    anchors.fill: parent; anchors.margins: 8
                    color: Theme.textPrimary; font.pixelSize: 14
                    selectionColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                    FocusScope { id: titleFocus; anchors.fill: parent }
                }
            }

            Text { text: "Description"; color: Theme.textSec; font.pixelSize: 12 }
            Rectangle {
                width: parent.width; height: 72; radius: 6
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
                    text: "Cancel"; accent: false
                    onClicked: editPlaylistPopup.close()
                }
                PillButton {
                    text: "Save"; accent: true
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
