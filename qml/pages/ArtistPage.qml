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
                    mipmap: true
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

                    PillButton {
                        text: "Play"
                        glyph: "▶"
                        accent: true
                        onClicked: if (topTracks.length > 0) player.playTracks(topTracks, 0)
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
                model: root.topTracks.slice(0, 5)
                TrackRow {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    trackNum:    index + 1
                    title:       modelData.title
                    artists:     modelData.artists
                    albumTitle:  modelData.albumTitle
                    durationStr: modelData.durationStr
                    coverUrl:    modelData.coverUrl80
                    isPlaying:   player.currentTrack.id === modelData.id && player.playing
                    trackData:   modelData
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
                    text: root.formatBio(artistData.bio || "")
                    color: Theme.textSec
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    lineHeight: 1.5
                    textFormat: Text.RichText
                    onLinkActivated: (link) => {
                        var parts = link.split(":")
                        if (parts.length === 2) {
                            var type = parts[0]
                            var id = Number(parts[1])
                            if (type === "artist") {
                                navigateTo("artist", { artistId: id })
                            } else if (type === "album") {
                                navigateTo("album", { albumId: id })
                            }
                        }
                    }
                }
            }

            Item { height: 32 }
        }
    }

    function formatBio(bio) {
        if (!bio) return ""
        var html = bio
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
        html = html.replace(/\[wimpLink\s+(artistId|albumId|playlistId|trackId)="([^"]+)"\](.*?)\[\/wimpLink\]/g, function(match, typeAttr, id, text) {
            var type = typeAttr.replace("Id", "")
            return "<a href='" + type + ":" + id + "' style='color: " + Theme.accent + "; text-decoration: none; font-weight: bold;'>" + text + "</a>"
        })
        return html.replace(/\n/g, "<br/>")
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    BackButton { anchors { top: parent.top; left: parent.left; margins: 16 } }

    LoadingOverlay { loading: root.loading }
}
