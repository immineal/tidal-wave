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
    property var mixes: []
    property bool loading:  false
    property int  sortMode: 0  // 0=default, 1=A-Z, 2=Z-A

    onActiveTabChanged: {
        updateFilteredContent()
        if (activeTab === 4 && mixes.length === 0) loadMixes()
    }
    Component.onCompleted: updateFilteredContent()

    function sortItems(items, mode) {
        if (mode === 0) return items
        var copy = items.slice()
        copy.sort(function(a, b) {
            var titleA = (a.title || a.name || "").toLowerCase()
            var titleB = (b.title || b.name || "").toLowerCase()
            return mode === 1 ? titleA.localeCompare(titleB) : titleB.localeCompare(titleA)
        })
        return copy
    }

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

    function loadMixes() {
        bridge.fetchHomeMixes(function(mixList, err) {
            if (err.length > 0) return
            var items = []
            for (var i = 0; i < mixList.length; i++) {
                items.push(mixList[i])
            }
            mixes = items
        })
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
                    model: ["Tracks", "Albums", "Artists", "Playlists", "Mixes"]
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
                            id: tl; anchors.centerIn: parent
                            text: {
                                var counts = [root.filteredTracks.length, root.filteredAlbums.length, root.filteredArtists.length, root.filteredPlaylists.length, root.mixes.length]
                                return modelData + " (" + counts[index] + ")"
                            }
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

            Row {
                visible: root.activeTab < 4
                spacing: 4
                Repeater {
                    model: ["Default", "A→Z", "Z→A"]
                    Rectangle {
                        required property string modelData
                        required property int    index
                        height: 30; width: sortLbl.implicitWidth + 16; radius: 15
                        color: root.sortMode === index ? Theme.accent : Theme.surfaceHigh
                        Text {
                            id: sortLbl; anchors.centerIn: parent
                            text: modelData
                            color: root.sortMode === index ? "white" : Theme.textSec
                            font.pixelSize: 13
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.sortMode = index
                        }
                    }
                }
            }

            Item { width: 4 }

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
            property var sortedTracks: root.sortItems(root.filteredTracks, root.sortMode)
            model: root.activeTab === 0 ? sortedTracks : []
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
                onPlayRequested: player.playTracks(tracksList.sortedTracks, index)
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
            property var sortedAlbums: root.sortItems(root.filteredAlbums, root.sortMode)
            model: root.activeTab === 1 ? sortedAlbums : []
            cellWidth: 184
            cellHeight: 232
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: albumDelegate
                width: 184
                height: 232
                required property var modelData
                required property int index

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

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: albumCtxMenu.popup()
                }
                Menu {
                    id: albumCtxMenu
                    background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: 8; implicitWidth: 180 }
                    MenuItem {
                        text: "Remove from library"
                        contentItem: Text { text: parent.text; color: Theme.red; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                        onTriggered: bridge.removeAlbumFavorite(albumDelegate.modelData.id, function(ok) {})
                    }
                    MenuItem {
                        text: "Go to album"
                        contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                        onTriggered: navigateTo("album", { albumId: albumDelegate.modelData.id })
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
            property var sortedArtists: root.sortItems(root.filteredArtists, root.sortMode)
            model: root.activeTab === 2 ? sortedArtists : []
            cellWidth: 184
            cellHeight: 232
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: artistDelegate
                width: 184
                height: 232
                required property var modelData
                required property int index

                MediaCard {
                    anchors.centerIn: parent
                    title: modelData.name
                    subtitle: "Artist"
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "artist"
                    onClicked: navigateTo("artist", { artistId: modelData.id })
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: artistCtxMenu.popup()
                }
                Menu {
                    id: artistCtxMenu
                    background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: 8; implicitWidth: 180 }
                    MenuItem {
                        text: "Unfollow artist"
                        contentItem: Text { text: parent.text; color: Theme.red; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                        onTriggered: bridge.removeArtistFavorite(artistDelegate.modelData.id, function(ok) {})
                    }
                    MenuItem {
                        text: "Go to artist"
                        contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                        onTriggered: navigateTo("artist", { artistId: artistDelegate.modelData.id })
                    }
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
                        coverUrl: modelData.coverUrl || "",
                        playlistDescription: modelData.description || "",
                        playlistDuration: modelData.duration || 0,
                        playlistType: modelData.type || ""
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

        // Tab 4: Mixes (GridView)
        GridView {
            id: mixesGrid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 4 && root.mixes.length > 0
            clip: true
            model: root.activeTab === 4 ? root.mixes : []
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
                    subtitle: modelData.subtitle || ""
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "mix"
                    onClicked: navigateTo("mix", { mixId: modelData.id, title: modelData.title, subtitle: modelData.subtitle, coverUrl: modelData.coverUrl })
                    onPlayClicked: {
                        bridge.fetchMixTracks(modelData.id, function(tracks, err) {
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

        // Empty state for mixes
        Item {
            visible: root.activeTab === 4 && root.mixes.length === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "music"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: "No mixes"; color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: "Your Tidal mixes will appear here"; color: Theme.textSec; font.pixelSize: 13 }
            }
        }

        // Empty state for tracks
        Item {
            visible: root.activeTab === 0 && root.filteredTracks.length === 0 && !root.loading
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "heart"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: "No saved tracks"; color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: "Like tracks to see them here"; color: Theme.textSec; font.pixelSize: 13 }
            }
        }

        // Empty state for albums
        Item {
            visible: root.activeTab === 1 && root.filteredAlbums.length === 0 && !root.loading
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "music"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: "No saved albums"; color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: "Save albums to see them here"; color: Theme.textSec; font.pixelSize: 13 }
            }
        }

        // Empty state for artists
        Item {
            visible: root.activeTab === 2 && root.filteredArtists.length === 0 && !root.loading
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "artist"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: "No followed artists"; color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: "Follow artists to see them here"; color: Theme.textSec; font.pixelSize: 13 }
            }
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
