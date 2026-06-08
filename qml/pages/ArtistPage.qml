import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var artistId: 0
    property var artistData: ({})
    property var topTracks: []
    property var albums: []
    property bool loading: false

    onArtistIdChanged: if (artistId > 0) loadArtist()

    function loadArtist() {
        loading = true
        bridge.fetchArtistDetail(artistId, function(d, err) {
            if (!err) artistData = d
        })
        bridge.fetchArtistTopTracks(artistId, function(t, err) {
            if (!err) topTracks = t
        })
        bridge.fetchArtistAlbums(artistId, function(a, err) {
            loading = false
            if (!err) albums = a
        })
    }

    ScrollView {
        anchors.fill: parent
        rightPadding: 14
        contentWidth: availableWidth

        ColumnLayout {
            width: parent.width
            spacing: 0

            // Hero
            Rectangle {
                Layout.fillWidth: true
                height: 320
                color: "transparent"
                clip: true

                Image {
                    anchors.fill: parent
                    source: artistData.coverUrl750 ? "image://tidal/" + artistData.coverUrl750 : ""
                    fillMode: Image.PreserveAspectCrop
                    opacity: 0.4
                    smooth: true
                }

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.4; color: "transparent" }
                        GradientStop { position: 1; color: Theme.bg }
                    }
                }

                ColumnLayout {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.margins: 28
                    spacing: 8

                    Text {
                        text: artistData.name || ""
                        color: Theme.textPrimary
                        font.pixelSize: 36
                        font.bold: true
                        style: Text.Outline
                        styleColor: Qt.rgba(0, 0, 0, 0.5)
                    }

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
                        TapHandler {
                            onTapped: if (topTracks.length > 0) player.playTracks(topTracks, 0)
                        }
                    }
                }
            }

            Item { height: 8 }

            Text {
                visible: root.topTracks.length > 0
                Layout.leftMargin: 24
                text: "Popular"
                color: Theme.textPrimary
                font.pixelSize: 20
                font.bold: true
            }

            Item { height: 8; visible: root.topTracks.length > 0 }

            Repeater {
                model: Math.min(root.topTracks.length, 5)
                TrackRow {
                    required property int index
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    trackNum:    index + 1
                    title:       root.topTracks[index].title
                    artists:     root.topTracks[index].artists
                    albumTitle:  root.topTracks[index].albumTitle
                    durationStr: root.topTracks[index].durationStr
                    coverUrl:    root.topTracks[index].coverUrl80
                    isPlaying:   player.currentTrack.id === root.topTracks[index].id && player.playing
                    trackData:   root.topTracks[index]
                    onPlayRequested: player.playTracks(root.topTracks, index)
                }
            }

            HorizontalSection {
                Layout.fillWidth: true
                visible: root.albums.length > 0
                title: "Discography"
                mediaType: "album"
                items: root.albums.map(function(a) {
                    return { id: a.id, title: a.title, subtitle: a.year, coverUrl: a.coverUrl }
                })
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                onItemPlayClicked: function(i, item) {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (!err && tracks.length > 0) player.playTracks(tracks, 0)
                    })
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                visible: (artistData.bio || "").length > 0
                spacing: 8

                Item { height: 8 }

                Text {
                    text: "About"
                    color: Theme.textPrimary
                    font.pixelSize: 20
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: artistData.bio || ""
                    color: Theme.textSec
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    lineHeight: 1.5
                }
            }

            Item { height: 32 }
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
