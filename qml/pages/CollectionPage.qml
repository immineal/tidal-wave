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

    // Grid metrics. The cell was a fixed 184, which against the 740px pane this
    // page gets at a 960px window left 3 cells and 140px of ragged gutter. The
    // cells now split the pane evenly: pick the column count that lands nearest
    // the 184 the cards were drawn at, then share the width out between them.
    readonly property int gridTargetCell: 184
    readonly property int gridMinCell: 150   // below this a cover plus two lines stops reading
    readonly property int gridGutter: 24     // breathing room inside a cell
    function gridColumns(avail) {
        var n = Math.max(1, Math.round(avail / gridTargetCell))
        while (n > 1 && avail / n < gridMinCell) n--
        return n
    }

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

        // A ColumnLayout reads Layout.preferredHeight, not a plain height, so
        // these spacers have to declare it or they collapse to nothing.
        Item { Layout.preferredHeight: 24 }
        Text {
            Layout.leftMargin: 24
            text: qsTr("My Collection")
            color: Theme.textPrimary
            font.pixelSize: 28; font.bold: true
        }
        Item { Layout.preferredHeight: 16 }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 24
            Layout.rightMargin: 24
            spacing: 16

            // A Flow, not a Row: five tab labels plus their counts come to ~526px
            // in English and more in German, which is already more than the
            // pane has at 640. They wrap to a second line instead of running
            // off the edge, and the sort pills stay on the right.
            Flow {
                id: tabsRow
                objectName: "collectionTabsRow"
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 4
                Repeater {
                    model: [qsTr("Tracks"), qsTr("Albums"), qsTr("Artists"), qsTr("Playlists"), qsTr("Mixes")]
                    Rectangle {
                        id: collectionTab
                        required property string modelData
                        required property int    index
                        height: 34; width: tl.implicitWidth + 24; radius: Theme.radiusChip
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
                                // Tab name followed by how many items it holds
                                return qsTr("%1 (%2)").arg(modelData)
                                                      .arg(counts[index].toLocaleString(Qt.locale(), 'f', 0))
                            }
                            color: root.activeTab === index ? Theme.onAccent : Theme.textSec
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

            Row {
                visible: root.activeTab < 4
                Layout.alignment: Qt.AlignVCenter
                spacing: 4
                Repeater {
                    model: [qsTr("Default"), qsTr("A→Z"), qsTr("Z→A")]
                    Rectangle {
                        required property string modelData
                        required property int    index
                        height: 30; width: sortLbl.implicitWidth + 16; radius: Theme.radiusChip
                        color: root.sortMode === index ? Theme.accent : Theme.surfaceHigh
                        Text {
                            id: sortLbl; anchors.centerIn: parent
                            text: modelData
                            color: root.sortMode === index ? Theme.onAccent : Theme.textSec
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
        }

        Item { Layout.preferredHeight: 10 }

        // The field gets its own row. On one row with the tabs and the sort
        // pills the header needed ~1083px against a 740px pane, so it
        // overflowed at every width the app actually runs at.
        SearchBar {
            id: collectionSearch
            objectName: "collectionSearch"
            // A whole phrase per tab: German cannot take "Search saved " + a noun
            placeholder: [qsTr("Search saved tracks…"), qsTr("Search saved albums…"),
                          qsTr("Search saved artists…"), qsTr("Search saved playlists…")
                         ][root.activeTab] || qsTr("Search saved items…")
            Layout.fillWidth: true
            Layout.leftMargin: 24
            Layout.rightMargin: 24
            Layout.preferredHeight: 36
            onTextEdited: (txt) => {
                root.searchPattern = txt
                root.updateFilteredContent()
            }
        }

        Item { Layout.preferredHeight: 16 }

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
                onPlayRequested: {
                    player.setPlaybackSource("collection", "tracks", qsTr("Liked Songs"))
                    player.playTracks(tracksList.sortedTracks, index)
                }
            }

            ScrollBar.vertical: ScrollBar {
                active: true
                policy: ScrollBar.AsNeeded
            }
        }

        // Tab 1: Albums Tab (virtualized GridView)
        GridView {
            id: albumsGrid
            objectName: "collectionAlbumsGrid"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 1
            clip: true
            property var sortedAlbums: root.sortItems(root.filteredAlbums, root.sortMode)
            model: root.activeTab === 1 ? sortedAlbums : []
            readonly property int availWidth: Math.max(0, width - leftMargin - rightMargin)
            readonly property int columns: root.gridColumns(availWidth)
            cellWidth: Math.floor(availWidth / columns)
            cellHeight: cellWidth + 48
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: albumDelegate
                width: albumsGrid.cellWidth
                height: albumsGrid.cellHeight
                required property var modelData
                required property int index

                MediaCard {
                    anchors.centerIn: parent
                    cardSize: albumsGrid.cellWidth - root.gridGutter
                    title: modelData.title
                    subtitle: modelData.artists
                    coverUrl: modelData.coverUrl
                    mediaType: "album"
                    itemId: "" + modelData.id
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
                    background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup; implicitWidth: 180 }
                    MenuItem {
                        text: qsTr("Remove from library")
                        contentItem: Text { text: parent.text; color: Theme.red; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                        onTriggered: bridge.removeAlbumFavorite(albumDelegate.modelData.id, function(ok) {})
                    }
                    MenuItem {
                        text: qsTr("Go to album")
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
            readonly property int availWidth: Math.max(0, width - leftMargin - rightMargin)
            readonly property int columns: root.gridColumns(availWidth)
            cellWidth: Math.floor(availWidth / columns)
            cellHeight: cellWidth + 48
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: artistDelegate
                width: artistsGrid.cellWidth
                height: artistsGrid.cellHeight
                required property var modelData
                required property int index

                MediaCard {
                    anchors.centerIn: parent
                    cardSize: artistsGrid.cellWidth - root.gridGutter
                    title: modelData.name
                    subtitle: qsTr("Artist")
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "artist"
                    itemId: "" + modelData.id
                    onClicked: navigateTo("artist", { artistId: modelData.id })
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: artistCtxMenu.popup()
                }
                Menu {
                    id: artistCtxMenu
                    background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup; implicitWidth: 180 }
                    MenuItem {
                        text: qsTr("Unfollow artist")
                        contentItem: Text { text: parent.text; color: Theme.red; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                        onTriggered: bridge.removeArtistFavorite(artistDelegate.modelData.id, function(ok) {})
                    }
                    MenuItem {
                        text: qsTr("Go to artist")
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
            readonly property int availWidth: Math.max(0, width - leftMargin - rightMargin)
            readonly property int columns: root.gridColumns(availWidth)
            cellWidth: Math.floor(availWidth / columns)
            cellHeight: cellWidth + 48
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                width: playlistsGrid.cellWidth
                height: playlistsGrid.cellHeight
                MediaCard {
                    anchors.centerIn: parent
                    cardSize: playlistsGrid.cellWidth - root.gridGutter
                    title: modelData.title
                    subtitle: qsTr("%n track(s)", "", modelData.numTracks)
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "playlist"
                    itemId: modelData.uuid || ""
                    onClicked: navigateTo("playlist", {
                        playlistUuid: modelData.uuid,
                        playlistTitle: modelData.title,
                        coverUrl: modelData.coverUrl || "",
                        playlistDescription: modelData.description || "",
                        playlistDuration: modelData.duration || 0,
                        playlistType: modelData.type || ""
                    })
                    onPlayClicked: {
                        bridge.markPlaylistPlayed(modelData.uuid)
                        bridge.fetchPlaylistTracks(modelData.uuid, function(tracks, err) {
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

        // Empty state for playlists
        Item {
            visible: root.activeTab === 3 && root.filteredPlaylists.length === 0 && !root.loading
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "music"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No playlists yet"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Your saved playlists will appear here"); color: Theme.textSec; font.pixelSize: 13 }
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
            readonly property int availWidth: Math.max(0, width - leftMargin - rightMargin)
            readonly property int columns: root.gridColumns(availWidth)
            cellWidth: Math.floor(availWidth / columns)
            cellHeight: cellWidth + 48
            leftMargin: 24
            rightMargin: 24
            topMargin: 16
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                width: mixesGrid.cellWidth
                height: mixesGrid.cellHeight
                MediaCard {
                    anchors.centerIn: parent
                    cardSize: mixesGrid.cellWidth - root.gridGutter
                    title: modelData.title
                    subtitle: modelData.subtitle || ""
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "mix"
                    itemId: "" + modelData.id
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
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No mixes"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Your Tidal mixes will appear here"); color: Theme.textSec; font.pixelSize: 13 }
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
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No saved tracks"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Like tracks to see them here"); color: Theme.textSec; font.pixelSize: 13 }
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
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No saved albums"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Save albums to see them here"); color: Theme.textSec; font.pixelSize: 13 }
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
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No followed artists"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Follow artists to see them here"); color: Theme.textSec; font.pixelSize: 13 }
            }
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
