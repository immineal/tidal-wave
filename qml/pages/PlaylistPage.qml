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

    ScrollView {
        anchors.fill: parent
        rightPadding: 14
        contentWidth: availableWidth

        ColumnLayout {
            width: parent.width
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
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
                                model: 4
                                Image {
                                    width: 90
                                    height: 90
                                    source: (root.tracks && root.tracks[index] && root.tracks[index].coverUrl) ? "image://tidal/" + root.tracks[index].coverUrl : ""
                                    fillMode: Image.PreserveAspectCrop
                                    smooth: true
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

                            Rectangle {
                                width: 120
                                height: 40
                                radius: 20
                                color: Theme.accent
                                Row {
                                    anchors.centerIn: parent
                                    spacing: 8
                                    Text { text: "▶"; color: "white"; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                                    Text { text: "Play"; color: "white"; font.pixelSize: 14; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
                                }
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: if (tracks.length > 0) player.playTracks(tracks, 0) }
                            }

                            Rectangle {
                                width: 120
                                height: 40
                                radius: 20
                                color: Theme.surfaceHigh
                                border.color: Theme.border
                                Row {
                                    anchors.centerIn: parent
                                    spacing: 8
                                    Text { text: "⇌"; color: Theme.textPrimary; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                                    Text { text: "Shuffle"; color: Theme.textPrimary; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                                }
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    onTapped: {
                                        if (tracks.length > 0) {
                                            player.setShuffle(true)
                                            player.playTracks(tracks, 0)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Repeater {
                model: root.tracks.length
                TrackRow {
                    required property int index
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    trackNum:    index + 1
                    title:       root.tracks[index].title
                    artists:     root.tracks[index].artists
                    albumTitle:  root.tracks[index].albumTitle
                    durationStr: root.tracks[index].durationStr
                    coverUrl:    root.tracks[index].coverUrl80
                    isPlaying:   player.currentTrack.id === root.tracks[index].id && player.playing
                    trackData:   root.tracks[index]
                    onPlayRequested: player.playTracks(root.tracks, index)
                }
            }

            Item { height: 32 }
        }
    }

    LoadingOverlay { loading: root.loading }
}
