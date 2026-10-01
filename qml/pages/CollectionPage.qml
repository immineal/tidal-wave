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
    // 0=default, 1=A-Z, 2=Z-A. Default is the order the library arrived in,
    // which is most recently saved first: the favourites endpoints are asked
    // for order=DATE. It is not persisted, so it is 0 on every visit.
    property int  sortMode: 0

    // Grid metrics, shared by the four grids below. A grid of width w is split
    //
    //     leftMargin | columns x cellWidth | rightMargin
    //
    // and every one of those four numbers comes out of w alone. That matters:
    // the previous pass measured the space for the cells as
    // `width - leftMargin - rightMargin`, which is the same arithmetic reading
    // back the margins it is there to decide. Whether those had been assigned
    // when the binding first ran decided how many columns were counted, and a
    // grid that counts its columns against the full width and then has 48px of
    // inset applied under it has one column more than it has room for. Nothing
    // depends on an assignment order any more.
    //
    // columns lands nearest the 184 the cards were drawn at, then backs off
    // while a cell would fall under gridMinCell. cellWidth is *floored*, so
    // columns * cellWidth is never wider than the space between the two edge
    // insets - that, and nothing else, is what guarantees the last column
    // cannot cross the viewport at any width.
    //
    // Flooring leaves a remainder of 0..columns-1 px over. It is split between
    // the two edge insets rather than left to pile up on the right, so the
    // gutter outside the first card and the gutter outside the last match to
    // within the odd pixel. The smallest either of them gets is gridEdge, and
    // the card sits a further gridGutter/2 inside its cell, so the overlaid
    // scrollbar never reaches the artwork.
    readonly property int gridTargetCell: 184
    readonly property int gridMinCell: 150   // below this a cover plus two lines stops reading
    readonly property int gridGutter: 24     // breathing room in a cell, split either side of the card
    readonly property int gridEdge: 24       // the pane inset, matching the header above

    function gridSpace(w)   { return Math.max(0, w - 2 * gridEdge) }
    function gridColumns(w) {
        var avail = gridSpace(w)
        var n = Math.max(1, Math.round(avail / gridTargetCell))
        while (n > 1 && avail / n < gridMinCell) n--
        return n
    }
    // At least 1: a pane too narrow to hold anything would otherwise hand
    // GridView a cellWidth of zero, which it divides by.
    function gridCell(w) {
        return Math.max(1, Math.floor(gridSpace(w) / gridColumns(w)))
    }
    function gridLeft(w) {
        return gridEdge + Math.floor((gridSpace(w) - gridColumns(w) * gridCell(w)) / 2)
    }
    // Chosen so that width - leftMargin - rightMargin is exactly
    // columns * cellWidth. That difference is the figure GridView itself
    // divides by cellWidth to decide how many columns to lay out, so it can
    // never arrive at one more than was budgeted for.
    function gridRight(w) {
        return Math.max(0, w - gridLeft(w) - gridColumns(w) * gridCell(w))
    }
    // The card inside a cell, never smaller than a pixel.
    function gridCardSize(cell) { return Math.max(1, cell - gridGutter) }

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
                            color: root.activeTab === index ? Theme.accentInk : Theme.textSec
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
                            color: root.sortMode === index ? Theme.accentInk : Theme.textSec
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

            // The fields are handed over as they came off the API. TrackRow
            // takes them as `var` and decides what a missing or wrongly typed
            // one shows, so a truncated response costs a fallback here and not
            // a warning per field per row.
            delegate: TrackRow {
                width: tracksList.width - 32
                x: 16
                trackNum:    index + 1
                title:       modelData.title
                artists:     modelData.artists
                albumTitle:  modelData.albumTitle
                durationStr: modelData.durationStr
                coverUrl:    modelData.coverUrl80
                // Both ids are undefined on a partial payload, and undefined
                // matches undefined, which lit every row up as playing.
                isPlaying:   Number(modelData.id) > 0
                             && player.currentTrack.id === modelData.id && player.playing
                trackData:   modelData
                onPlayRequested: {
                    player.setPlaybackSource("collection", "tracks", qsTr("Liked Songs"))
                    // S4: "Liked Songs" is not one of the four kinds the
                    // sidebar orders, and markPlayed() drops it, so the
                    // track's own album stands in as the thing that played.
                    // Recorded after the source so it is the newer of the two.
                    if (Number(modelData.albumId) > 0)
                        library.markPlayed("album", "" + modelData.albumId)
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
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: 16
            // Flickable parks its content at contentX = -leftMargin, but it
            // only moves there of its own accord when the view can flick that
            // way, and a vertical grid cannot. The inset here follows the pane
            // width, so without this a grid that has been resized keeps the
            // offset it was built with and the whole thing sits a few pixels
            // off: left gutter short by the remainder, right gutter long by it.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: albumDelegate
                width: albumsGrid.cellWidth
                height: albumsGrid.cellHeight
                required property var modelData
                required property int index

                MediaCard {
                    id: albumCard
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(albumsGrid.cellWidth)
                    title: modelData.title
                    subtitle: modelData.artists
                    coverUrl: modelData.coverUrl
                    mediaType: "album"
                    itemId: "" + modelData.id
                    onClicked: navigateTo("album", { albumId: modelData.id })
                    onPlayClicked: {
                        bridge.fetchAlbumTracks(modelData.id, function(tracks, err) {
                            if (err || tracks.length === 0) return
                            // Declaring the source both fills "Playing from"
                            // and is what records the album as played (S4).
                            player.setPlaybackSource("album", "" + modelData.id,
                                                     modelData.title || "")
                            player.playTracks(tracks, 0)
                        })
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: albumCtxMenu.popup()
                }
                // This menu covers the tile's own, so it repeats the two queue
                // actions rather than leaving them unreachable here. The work
                // is the card's either way, so both routes queue the same
                // tracks and confirm in the same place.
                Menu {
                    id: albumCtxMenu
                    background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup; implicitWidth: 180 }
                    MenuItem {
                        text: qsTr("Play next", "verb, play this right after the current track")
                        contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                        onTriggered: albumCard.playNext()
                    }
                    MenuItem {
                        text: qsTr("Add to queue", "verb, put this at the end of the queue")
                        contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                        onTriggered: albumCard.addToQueue()
                    }
                    MenuSeparator {
                        contentItem: Rectangle { height: 1; color: Theme.border }
                    }
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
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: 16
            // Flickable parks its content at contentX = -leftMargin, but it
            // only moves there of its own accord when the view can flick that
            // way, and a vertical grid cannot. The inset here follows the pane
            // width, so without this a grid that has been resized keeps the
            // offset it was built with and the whole thing sits a few pixels
            // off: left gutter short by the remainder, right gutter long by it.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: artistDelegate
                width: artistsGrid.cellWidth
                height: artistsGrid.cellHeight
                required property var modelData
                required property int index

                MediaCard {
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(artistsGrid.cellWidth)
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
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: 16
            // Flickable parks its content at contentX = -leftMargin, but it
            // only moves there of its own accord when the view can flick that
            // way, and a vertical grid cannot. The inset here follows the pane
            // width, so without this a grid that has been resized keeps the
            // offset it was built with and the whole thing sits a few pixels
            // off: left gutter short by the remainder, right gutter long by it.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                width: playlistsGrid.cellWidth
                height: playlistsGrid.cellHeight
                MediaCard {
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(playlistsGrid.cellWidth)
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
                            if (err || tracks.length === 0) return
                            player.setPlaybackSource("playlist", modelData.uuid || "",
                                                     modelData.title || "")
                            player.playTracks(tracks, 0)
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
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: 16
            // Flickable parks its content at contentX = -leftMargin, but it
            // only moves there of its own accord when the view can flick that
            // way, and a vertical grid cannot. The inset here follows the pane
            // width, so without this a grid that has been resized keeps the
            // offset it was built with and the whole thing sits a few pixels
            // off: left gutter short by the remainder, right gutter long by it.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                width: mixesGrid.cellWidth
                height: mixesGrid.cellHeight
                MediaCard {
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(mixesGrid.cellWidth)
                    title: modelData.title
                    subtitle: modelData.subtitle || ""
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "mix"
                    itemId: "" + modelData.id
                    onClicked: navigateTo("mix", { mixId: modelData.id, title: modelData.title, subtitle: modelData.subtitle, coverUrl: modelData.coverUrl })
                    onPlayClicked: {
                        bridge.fetchMixTracks(modelData.id, function(tracks, err) {
                            if (err || tracks.length === 0) return
                            player.setPlaybackSource("mix", "" + modelData.id,
                                                     modelData.title || "")
                            player.playTracks(tracks, 0)
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
