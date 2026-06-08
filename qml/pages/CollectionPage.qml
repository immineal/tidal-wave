import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property int activeTab: 0
    property string searchPattern: ""
    property var filteredTracks:    []
    property var filteredAlbums:    []
    property var filteredArtists:   []
    property var filteredPlaylists: []
    property bool loading:  false

    onActiveTabChanged: updateFilteredContent()
    Component.onCompleted: updateFilteredContent()

    Connections {
        target: bridge
        function onFavoriteTracksChanged() { root.updateFilteredContent() }
        function onFavoriteAlbumsChanged() { root.updateFilteredContent() }
        function onFavoriteArtistsChanged() { root.updateFilteredContent() }
        function onFavoritePlaylistsChanged() { root.updateFilteredContent() }
    }

    function updateFilteredContent() {
        filteredTracks    = bridge.searchFavoriteTracks(searchPattern)
        filteredAlbums    = bridge.searchFavoriteAlbums(searchPattern)
        filteredArtists   = bridge.searchFavoriteArtists(searchPattern)
        filteredPlaylists = bridge.searchFavoritePlaylists(searchPattern)
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

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 24
            Layout.rightMargin: 24
            spacing: 16

            Row {
                spacing: 4
                Repeater {
                    model: ["Tracks", "Albums", "Artists", "Playlists"]
                    Rectangle {
                        id: collectionTab
                        required property string modelData
                        required property int    index
                        height: 34; width: tl.implicitWidth + 24; radius: 17
                        color: root.activeTab === index ? Theme.accent : Theme.surfaceHigh
                        border.width: collectionTab.activeFocus ? 2 : 0
                        border.color: Theme.accent
                        activeFocusOnTab: true
                        Keys.onReturnPressed: { root.activeTab = index }
                        Keys.onSpacePressed:  { root.activeTab = index }
                        Text {
                            id: tl; anchors.centerIn: parent; text: modelData
                            color: root.activeTab === index ? "white" : Theme.textSec
                            font.pixelSize: 14; font.bold: root.activeTab === index
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.activeTab = index }
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            SearchBar {
                id: collectionSearch
                placeholder: "Search saved " + ["tracks", "albums", "artists", "playlists"][root.activeTab] + "…"
                Layout.preferredWidth: 220
                Layout.preferredHeight: 36
                onTextEdited: (txt) => {
                    root.searchPattern = txt
                    root.updateFilteredContent()
                }
            }
        }
        Item { height: 16 }

        // Tracks Tab: virtualized ListView
        ListView {
            id: tracksList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 0
            clip: true
            model: root.activeTab === 0 ? root.filteredTracks : []
            boundsBehavior: Flickable.StopAtBounds

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
                onPlayRequested: player.playTracks(root.filteredTracks, index)
            }

            ScrollBar.vertical: ScrollBar {
                active: true
                policy: ScrollBar.AsNeeded
            }
        }

        // Tab 1: Albums Tab (virtualized GridView)
        GridView {
            id: albumsGrid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 1
            clip: true
            model: root.activeTab === 1 ? root.filteredAlbums : []
            cellWidth: 184
            cellHeight: 232
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                width: 184
                height: 232
                MediaCard {
                    anchors.centerIn: parent
                    title: modelData.title
                    subtitle: modelData.artists
                    coverUrl: modelData.coverUrl
                    mediaType: "album"
                    onClicked: navigateTo("album", { albumId: modelData.id })
                    onPlayClicked: {
                        bridge.fetchAlbumTracks(modelData.id, function(tracks, err) {
                            if (!err && tracks.length > 0) player.playTracks(tracks, 0)
                        })
                    }
                }
            }

            ScrollBar.vertical: ScrollBar {
                active: true
                policy: ScrollBar.AsNeeded
            }
        }

        // Tab 2: Artists Tab (virtualized GridView)
        GridView {
            id: artistsGrid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 2
            clip: true
            model: root.activeTab === 2 ? root.filteredArtists : []
            cellWidth: 184
            cellHeight: 232
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                width: 184
                height: 232
                MediaCard {
                    anchors.centerIn: parent
                    title: modelData.name
                    subtitle: "Artist"
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "artist"
                    onClicked: navigateTo("artist", { artistId: modelData.id })
                }
            }

            ScrollBar.vertical: ScrollBar {
                active: true
                policy: ScrollBar.AsNeeded
            }
        }

        // Tab 3: Playlists Tab (virtualized GridView)
        GridView {
            id: playlistsGrid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 3 && root.filteredPlaylists.length > 0
            clip: true
            model: root.activeTab === 3 ? root.filteredPlaylists : []
            cellWidth: 184
            cellHeight: 232
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                width: 184
                height: 232
                MediaCard {
                    anchors.centerIn: parent
                    title: modelData.title
                    subtitle: modelData.numTracks === 1 ? "1 track" : modelData.numTracks + " tracks"
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "playlist"
                    onClicked: navigateTo("playlist", {
                        playlistUuid: modelData.uuid,
                        playlistTitle: modelData.title,
                        coverUrl: modelData.coverUrl || ""
                    })
                }
            }

            ScrollBar.vertical: ScrollBar {
                active: true
                policy: ScrollBar.AsNeeded
            }
        }

        // Empty state for playlists
        Item {
            visible: root.activeTab === 3 && root.filteredPlaylists.length === 0 && !root.loading
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "music"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: "No playlists yet"; color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: "Your saved playlists will appear here"; color: Theme.textSec; font.pixelSize: 13 }
            }
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
