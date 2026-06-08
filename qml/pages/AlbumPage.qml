import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var albumId: 0
    property var albumData: ({})
    property var tracks: []
    property bool loading: false

    readonly property int effectiveArtistId: albumData.artistId > 0 ? albumData.artistId
        : (tracks.length > 0 && tracks[0].artistId > 0 ? tracks[0].artistId : 0)

    onAlbumIdChanged: if (albumId > 0) loadAlbum()

    function loadAlbum() {
        loading = true
        bridge.fetchAlbum(albumId, function(album, err) {
            if (!err) albumData = album
        })
        bridge.fetchAlbumTracks(albumId, function(t, err) {
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

            // Hero header
            Rectangle {
                Layout.fillWidth: true
                height: 280
                color: "transparent"
                clip: true

                Image {
                    anchors.fill: parent
                    source: albumData.coverUrl640 ? "image://tidal/" + albumData.coverUrl640 : ""
                    fillMode: Image.PreserveAspectCrop
                    opacity: 0.18
                    smooth: true
                }

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0; color: Qt.rgba(0.04,0.04,0.04,0.6) }
                        GradientStop { position: 1; color: Theme.bg }
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 24

                    Rectangle {
                        width: 200
                        height: 200
                        radius: Theme.radiusLg
                        color: Theme.surfaceHigh
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: albumData.coverUrl ? "image://tidal/" + albumData.coverUrl : ""
                            fillMode: Image.PreserveAspectCrop
                            smooth: true
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 8

                        Text {
                            text: "Album"
                            color: Theme.textDim
                            font.pixelSize: 12
                            font.bold: true
                            font.letterSpacing: 1
                        }

                        Text {
                            Layout.fillWidth: true
                            text: albumData.title || ""
                            color: Theme.textPrimary
                            font.pixelSize: 28
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            id: artistNameText
                            text: albumData.artists || ""
                            color: root.effectiveArtistId > 0 ? Theme.accent : Theme.textSec
                            font.pixelSize: 14
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: root.effectiveArtistId > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: if (root.effectiveArtistId > 0) root.navigateTo("artist", { artistId: root.effectiveArtistId })
                            }
                        }

                        Text {
                            text: (albumData.year || "") +
                                  (albumData.numTracks ? " • " + albumData.numTracks + (albumData.numTracks === 1 ? " track" : " tracks") : "") +
                                  (albumData.quality ? " • " + albumData.quality : "")
                            color: Theme.textSec
                            font.pixelSize: 13
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

            Item { height: 8 }

            // Column header
            Rectangle {
                Layout.fillWidth: true
                height: 32
                color: "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 28
                    anchors.rightMargin: 28
                    spacing: 12
                    Text { width: 24; text: "#"; color: Theme.textDim; font.pixelSize: 12 }
                    Text { Layout.fillWidth: true; text: "TITLE"; color: Theme.textDim; font.pixelSize: 12; font.letterSpacing: 0.5 }
                    Text { width: 40; text: "⏱"; color: Theme.textDim; font.pixelSize: 12; horizontalAlignment: Text.AlignRight }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
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
                    albumTitle:  root.albumData.title || ""
                    durationStr: root.tracks[index].durationStr
                    showAlbum:   false
                    showCover:   false
                    isPlaying:   player.currentTrack.id === root.tracks[index].id && player.playing
                    trackData:   root.tracks[index]
                    onPlayRequested: player.playTracks(root.tracks, index)
                }
            }

            Item { height: 32 }
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params || {})
    }

    LoadingOverlay { loading: root.loading }
}
