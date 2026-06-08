import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property int activeTab: 0
    property var tracks:    []
    property var albums:    []
    property var artists:   []
    property var playlists: []
    property bool loading:  false

    onActiveTabChanged: loadTab(activeTab)
    Component.onCompleted: loadTab(activeTab)

    function loadTab(tab) {
        loading = true
        switch (tab) {
        case 0:
            bridge.fetchFavoriteTracks(function(t, err) {
                loading = false; if (!err) tracks = t }, 100, 0); break
        case 1:
            bridge.fetchFavoriteAlbums(function(a, err) {
                loading = false; if (!err) albums = a }, 100, 0); break
        case 2:
            bridge.fetchFavoriteArtists(function(a, err) {
                loading = false; if (!err) artists = a }, 100, 0); break
        case 3:
            // playlistsAndFavoritePlaylists rejects limit > 50 with HTTP 400
            bridge.fetchUserPlaylists(function(p, err) {
                loading = false; if (!err) playlists = p }, 50, 0); break
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item { height: 24 }
        Text {
            Layout.leftMargin: 24
            text: "My Collection"
            color: Theme.textPrimary
            font.pixelSize: 28; font.bold: true
        }
        Item { height: 16 }

        Row {
            Layout.leftMargin: 24
            spacing: 4
            Repeater {
                model: ["Tracks", "Albums", "Artists", "Playlists"]
                Rectangle {
                    required property string modelData
                    required property int    index
                    height: 34; width: tl.implicitWidth + 24; radius: 17
                    color: root.activeTab === index ? Theme.accent : Theme.surfaceHigh
                    Text {
                        id: tl; anchors.centerIn: parent; text: modelData
                        color: root.activeTab === index ? "white" : Theme.textSec
                        font.pixelSize: 14; font.bold: root.activeTab === index
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.activeTab = index; loadTab(index) }
                    }
                }
            }
        }
        Item { height: 16 }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            rightPadding: 14
            contentWidth: availableWidth

            ColumnLayout {
                width: parent.width
                spacing: 0

                // Tracks
                Repeater {
                    model: root.activeTab === 0 ? root.tracks.length : 0
                    TrackRow {
                        required property int index
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
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

                // Albums grid
                Flow {
                    Layout.fillWidth: true; Layout.leftMargin: 24; Layout.rightMargin: 24
                    visible: root.activeTab === 1
                    spacing: 16
                    Repeater {
                        model: root.activeTab === 1 ? root.albums.length : 0
                        MediaCard {
                            required property int index
                            title: root.albums[index].title
                            subtitle: root.albums[index].artists
                            coverUrl: root.albums[index].coverUrl
                            mediaType: "album"
                            onClicked: navigateTo("album", { albumId: root.albums[index].id })
                            onPlayClicked: {
                                bridge.fetchAlbumTracks(root.albums[index].id, function(tracks, err) {
                                    if (!err && tracks.length > 0) player.playTracks(tracks, 0)
                                })
                            }
                        }
                    }
                }

                // Artists grid
                Flow {
                    Layout.fillWidth: true; Layout.leftMargin: 24; Layout.rightMargin: 24
                    visible: root.activeTab === 2
                    spacing: 16
                    Repeater {
                        model: root.activeTab === 2 ? root.artists.length : 0
                        MediaCard {
                            required property int index
                            title: root.artists[index].name
                            subtitle: "Artist"
                            coverUrl: root.artists[index].coverUrl || ""
                            mediaType: "artist"
                            onClicked: navigateTo("artist", { artistId: root.artists[index].id })
                        }
                    }
                }

                // Playlists grid
                Flow {
                    Layout.fillWidth: true; Layout.leftMargin: 24; Layout.rightMargin: 24
                    visible: root.activeTab === 3 && root.playlists.length > 0
                    spacing: 16
                    Repeater {
                        model: root.activeTab === 3 ? root.playlists.length : 0
                        MediaCard {
                            required property int index
                            title: root.playlists[index].title
                            subtitle: root.playlists[index].numTracks === 1 ? "1 track" : root.playlists[index].numTracks + " tracks"
                            coverUrl: root.playlists[index].coverUrl || ""
                            mediaType: "playlist"
                            onClicked: navigateTo("playlist", {
                                playlistUuid: root.playlists[index].uuid,
                                playlistTitle: root.playlists[index].title,
                                coverUrl: root.playlists[index].coverUrl || ""
                            })
                        }
                    }
                }

                // Empty state for playlists
                Item {
                    visible: root.activeTab === 3 && root.playlists.length === 0 && !root.loading
                    Layout.fillWidth: true
                    height: 200
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 12
                        VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "music"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "No playlists yet"; color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "Your saved playlists will appear here"; color: Theme.textSec; font.pixelSize: 13 }
                    }
                }

                Item { height: 32 }
            }
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
