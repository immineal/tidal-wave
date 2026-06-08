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
    property var    tracks: []
    property bool   loading: false

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
                        text: root.tracks.length === 1 ? "1 track" : root.tracks.length + " tracks"
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
                    }
                }
            }
        }

        delegate: TrackRow {
            width: tracksList.width - 32
            x: 16
            trackNum:    index + 1
            title:       modelData.title
            artists:     modelData.artists
            albumTitle:  modelData.albumTitle
            durationStr: modelData.durationStr
            coverUrl:    modelData.coverUrl80
            isPlaying:   player.currentTrack.id === modelData.id && player.playing
            trackData:   modelData
            onPlayRequested: player.playTracks(root.tracks, index)
        }

        footer: Item { height: 32; width: tracksList.width }

        ScrollBar.vertical: ScrollBar {
            active: true
            policy: ScrollBar.AsNeeded
        }
    }

    BackButton { anchors { top: parent.top; left: parent.left; margins: 16 } }

    LoadingOverlay { loading: root.loading }
}
