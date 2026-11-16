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
    // The mixes the field lets through. Tidal has no search over them, so the
    // page filters its own list.
    readonly property var filteredMixes: {
        var q = searchPattern.toLowerCase()
        if (q.length === 0) return mixes
        return mixes.filter(function (m) {
            return (m.title || "").toLowerCase().indexOf(q) !== -1
                || (m.subtitle || "").toLowerCase().indexOf(q) !== -1
        })
    }
    property bool loading: bridge.favoritesLoading
    // The page asks for the mixes itself; an empty list before an answer is
    // not an account without mixes.
    property bool mixesLoading: false
    property bool mixesLoaded: false
    property bool mixesFailed: false

    // How many rows the open tab shows, and whether its list could be read at
    // all. A list that failed to load is not an empty library.
    readonly property int tabCount: [filteredTracks.length, filteredAlbums.length,
                                     filteredArtists.length, filteredPlaylists.length,
                                     filteredMixes.length][activeTab] || 0
    readonly property var kindNames: ["tracks", "albums", "artists", "playlists", "mixes"]
    readonly property bool tabUnavailable: activeTab === 4
        ? (mixesFailed && mixes.length === 0)
        : bridge.unloadedKinds.indexOf(kindNames[activeTab]) !== -1
    // Which empty state the open tab shows, if any: "" for none, "failed" when
    // the list did not load, "filter" when the field matches nothing, "empty"
    // for a library that has none of the kind.
    readonly property string emptyKind: {
        if (tabCount > 0 || tabWaiting) return ""
        if (activeTab === 4 ? !mixesLoaded && !mixesFailed : loading) return ""
        if (activeTab === 1 && bridge.albumsLoading) return ""
        if (activeTab === 2 && bridge.artistsLoading) return ""
        if (activeTab === 3 && bridge.playlistsLoading) return ""
        if (tabUnavailable) return "failed"
        if (searchPattern.length > 0) return "filter"
        return "empty"
    }

    // The open tab's list is still on its way and none of it is here yet.
    readonly property bool tabWaiting: {
        switch (activeTab) {
        case 1: return bridge.albumsLoading && filteredAlbums.length === 0
        case 2: return bridge.artistsLoading && filteredArtists.length === 0
        case 3: return bridge.playlistsLoading && filteredPlaylists.length === 0
        case 4: return mixesLoading && mixes.length === 0
        }
        return false
    }
    // 0=default, 1=A-Z, 2=Z-A. Default is the order the bridge hands over:
    // newest saved first, playlists by the later of last played and added.
    // It is not persisted, so it is 0 on every visit.
    property int  sortMode: 0
    // What Default means on the current tab, for the pill's tooltip.
    readonly property string defaultOrderHint: [
        qsTr("Default: most recently liked first"),
        qsTr("Default: most recently saved first"),
        qsTr("Default: most recently followed first"),
        qsTr("Default: most recently played or added first")
    ][activeTab] || ""

    // Grid metrics for the four grids, from the grid's width alone. A cell
    // holds half a gutter each side of its card, so the cells start half a
    // gutter left of the inset and the first card lines up with the title.
    readonly property int gridTargetCell: 184
    readonly property int gridMinCell: 150   // below this a cover plus two lines stops reading
    readonly property int gridGutter: Theme.space6     // breathing room in a cell, split either side of the card
    readonly property int gridEdge: Theme.space6       // the pane inset, matching the header above

    function gridSpace(w)   { return Math.max(0, w - 2 * gridEdge + gridGutter) }
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
    function gridLeft(w) { return gridEdge - gridGutter / 2 }
    // Chosen so that width - leftMargin - rightMargin is exactly columns *
    // cellWidth, the figure GridView divides by cellWidth to count its columns.
    function gridRight(w) {
        return Math.max(0, w - gridLeft(w) - gridColumns(w) * gridCell(w))
    }
    // The card inside a cell, never smaller than a pixel.
    function gridCardSize(cell) { return Math.max(1, cell - gridGutter) }

    // ── the content area changing under the tabs and the sort pills ──────
    // A tab switch and a re-sort both replace the content outright, so it fades
    // in. Every view is modelled on a JS array, which a view can only read as a
    // model reset, so there is no reorder to animate.
    property real contentIn: 1
    NumberAnimation {
        id: contentEntry
        target: root
        property: "contentIn"
        from: 0; to: 1
        duration: Theme.dur(Theme.motionMedium)
        easing.type: Easing.OutCubic
    }

    onActiveTabChanged: {
        updateFilteredContent()
        if (activeTab === 4 && mixes.length === 0) loadMixes()
        contentEntry.restart()
    }
    onSortModeChanged: contentEntry.restart()
    // Mixes are fetched on the way in, since the tab label counts the same list
    // the grid shows.
    Component.onCompleted: {
        updateFilteredContent()
        loadMixes()
    }

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
        function onOfflineChanged() { if (!bridge.offline && root.mixesFailed) root.loadMixes() }
        function onFavoriteTracksChanged() { root.updateFilteredContent() }
        function onFavoriteAlbumsChanged() { root.updateFilteredContent() }
        function onFavoriteArtistsChanged() { root.updateFilteredContent() }
        function onFavoritePlaylistsChanged() { root.updateFilteredContent() }
    }

    // The two grids' Remove rows, and what they say when the server refuses.
    // Both are removals only, so `true` is passed for the current state. The
    // grids redraw off the bridge's signals, so a refused tile stays put.
    readonly property alias favoriteAction: collectionFav
    ContextMenu.FavoriteAction { id: collectionFav }

    function updateFilteredContent() {
        filteredTracks    = bridge.searchFavoriteTracks(searchPattern)
        filteredAlbums    = bridge.searchFavoriteAlbums(searchPattern)
        filteredArtists   = bridge.searchFavoriteArtists(searchPattern)
        filteredPlaylists = bridge.searchFavoritePlaylists(searchPattern)
    }

    function loadMixes() {
        mixesLoading = true
        bridge.fetchHomeMixes(function(mixList, err) {
            mixesLoading = false
            if (err.length > 0) { mixesFailed = true; return }
            mixesFailed = false
            mixesLoaded = true
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
        Item { Layout.preferredHeight: Theme.space6 }
        Text {
            objectName: "collectionTitle"
            Layout.leftMargin: Theme.space6
            text: qsTr("Collection")
            color: Theme.textPrimary
            font.pixelSize: Theme.fontDisplay; font.bold: true
        }
        Item { Layout.preferredHeight: Theme.space4 }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space6
            Layout.rightMargin: Theme.space6
            spacing: Theme.space4

            // It wraps: five tab labels with counts are wider than the pane
            // at 640. The sort pills stay right.
            TabStrip {
                id: tabsRow
                namePrefix: "collection"
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                model: [qsTr("Tracks"), qsTr("Albums"), qsTr("Artists"), qsTr("Playlists"), qsTr("Mixes")]
                labelFor: function (index, name) {
                    var counts = [root.filteredTracks.length, root.filteredAlbums.length, root.filteredArtists.length, root.filteredPlaylists.length, root.filteredMixes.length]
                    // Tab name followed by how many items it holds
                    return qsTr("%1 (%2)").arg(name)
                                          .arg(counts[index].toLocaleString(Qt.locale(), 'f', 0))
                }
                currentIndex: root.activeTab
                onActivated: (index) => { root.activeTab = index }
            }

            // Plain words with a line under the chosen one: the tab strip
            // beside it already carries the row's one accent pill.
            Row {
                visible: root.activeTab < 4
                Layout.alignment: Qt.AlignVCenter
                spacing: Theme.space1
                Repeater {
                    model: [qsTr("Default"), qsTr("A→Z"), qsTr("Z→A")]
                    Rectangle {
                        required property string modelData
                        required property int    index
                        id: sortPill
                        objectName: index === 0 ? "collectionSortDefault" : "collectionSortPill"
                        readonly property string hint: index === 0 ? root.defaultOrderHint : ""
                        readonly property bool chosen: root.sortMode === index
                        // Sized for the bold label, so choosing one moves nothing.
                        height: 30; width: sortBoldWidth.implicitWidth + Theme.space4; radius: Theme.radiusMedium
                        color: sortHov.hovered && !chosen ? Theme.hoverFill : "transparent"
                        // One of three, so it reads as a radio button.
                        activeFocusOnTab: true
                        Keys.onReturnPressed: root.sortMode = index
                        Keys.onSpacePressed:  root.sortMode = index
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData
                        Accessible.description: hint
                        Accessible.checkable: true
                        Accessible.checked: root.sortMode === index
                        Accessible.onPressAction: root.sortMode = index
                        Accessible.onToggleAction: root.sortMode = index
                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusMedium
                            color: "transparent"
                            border.width: sortPill.activeFocus ? 2 : 0
                            border.color: Theme.accent
                        }
                        Text {
                            id: sortLbl; anchors.centerIn: parent
                            objectName: "collectionSortLabel"
                            text: modelData
                            color: sortPill.chosen ? Theme.textPrimary : Theme.textSec
                            font.pixelSize: Theme.fontMeta
                            font.bold: sortPill.chosen
                        }
                        Text {
                            id: sortBoldWidth
                            visible: false
                            text: modelData
                            font.pixelSize: Theme.fontMeta
                            font.bold: true
                        }
                        Rectangle {
                            objectName: "collectionSortUnderline"
                            visible: sortPill.chosen
                            anchors.horizontalCenter: sortLbl.horizontalCenter
                            anchors.top: sortLbl.bottom
                            anchors.topMargin: Theme.spaceHalf
                            width: sortLbl.implicitWidth
                            height: 2
                            radius: height / 2
                            color: Theme.accent
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.sortMode = index
                        }
                        HoverHandler { id: sortHov }
                        ToolTip.visible: hint.length > 0 && (sortHov.hovered || sortPill.activeFocus)
                        ToolTip.text: hint
                        ToolTip.delay: Theme.tooltipDelay
                    }
                }
            }
        }

        Item { Layout.preferredHeight: Theme.space3 }

        // The field gets its own row: with the tabs and the sort pills the
        // header overflows the pane. "New playlist" shares this row, directly
        // over the grid it adds to.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space6
            Layout.rightMargin: Theme.space6
            spacing: Theme.space3

            SearchBar {
                id: collectionSearch
                objectName: "collectionSearch"
                // A whole phrase per tab: German cannot take "Search saved " + a noun
                placeholder: [qsTr("Search saved tracks…"), qsTr("Search saved albums…"),
                              qsTr("Search saved artists…"), qsTr("Search saved playlists…"),
                              qsTr("Search mixes…")
                             ][root.activeTab] || qsTr("Search saved items…")
                Layout.fillWidth: true
                onTextEdited: (txt) => {
                    root.searchPattern = txt
                    root.updateFilteredContent()
                }
            }

            PillButton {
                objectName: "collectionNewPlaylistButton"
                // A Layout skips an invisible child outright, so the field
                // takes the whole row back on the other four tabs.
                visible: root.activeTab === 3
                text: qsTr("New playlist")
                icon: "plus"
                // Outlined, not filled: the filled pill on this page is Play,
                // and the grid below is a list of things to play.
                accent: false
                Layout.preferredWidth:  implicitWidth
                Layout.preferredHeight: 36
                onClicked: newPlaylistDialog.openEmpty()
            }
        }

        Item { id: viewsTop; Layout.preferredHeight: Theme.space4 }

        // Tracks Tab: virtualized ListView
        ListView {
            id: tracksList
            objectName: "collectionTracksList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 0
            opacity: root.contentIn
            clip: true
            property var sortedTracks: root.sortItems(root.filteredTracks, root.sortMode)
            // Bound on every tab, so a tab switch keeps the rows and the scroll.
            model: sortedTracks
            boundsBehavior: Flickable.StopAtBounds

            // The fields are passed as they came off the API. TrackRow takes
            // them as `var` and decides what a missing or mistyped one shows.
            delegate: TrackRow {
                width: tracksList.width - 32
                x: 16
                trackNum:    index + 1
                title:       modelData.title
                artists:     modelData.artists
                albumTitle:  modelData.albumTitle
                durationStr: modelData.durationStr
                coverUrl:    modelData.coverUrl80
                trackData:   modelData
                onPlayRequested: {
                    player.setPlaybackSource("collection", "tracks", qsTr("Liked tracks"))
                    // "Liked Songs" is not a kind the sidebar orders and
                    // markPlayed() drops it, so the track's album stands in.
                    // Recorded after the source so it is the newer of the two.
                    if (Number(modelData.albumId) > 0)
                        library.markPlayed("album", "" + modelData.albumId)
                    player.playTracks(tracksList.sortedTracks, index)
                }
            }

            ScrollBar.vertical: ScrollBar {
                objectName: "collectionTracksScrollBar"
                active: true
                policy: ScrollBar.AsNeeded
                // A long list keeps a handle the pointer can find and grab.
                minimumSize: availableHeight > 0 ? Math.min(1, Theme.scrollHandleMin / availableHeight) : 0
            }
        }

        // Tab 1: Albums Tab (virtualized GridView)
        GridView {
            id: albumsGrid
            objectName: "collectionAlbumsGrid"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 1
            opacity: root.contentIn
            clip: true
            property var sortedAlbums: root.sortItems(root.filteredAlbums, root.sortMode)
            model: sortedAlbums
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: Theme.space4
            // Flickable only moves to contentX = -leftMargin by itself when the
            // view can flick that way, and a vertical grid cannot. The inset
            // follows the pane width, so it is re-applied here.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: FocusScope {
                // A FocusScope, so the grid's focus on its current cell lands on
                // the card inside; the grid is one tab stop and the arrows walk it.
                id: albumDelegate
                width: albumsGrid.cellWidth
                height: albumsGrid.cellHeight
                required property var modelData
                required property int index

                MediaCard {
                    focus: true
                    tabStop: albumDelegate.GridView.isCurrentItem || albumDelegate.GridView.view.currentIndex < 0
                    onKeyboardOnChanged: if (keyboardOn) albumDelegate.GridView.view.positionViewAtIndex(index, GridView.Contain)
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(albumsGrid.cellWidth)
                    title: modelData.title
                    subtitle: modelData.artists
                    coverUrl: modelData.coverUrl
                    mediaType: "album"
                    itemId: "" + modelData.id
                    // The tile's own menu has Pin, the queue actions and this.
                    removeLabel: qsTr("Remove from collection")
                    // The tile is the anchor, not the grid: it is what was
                    // right-clicked. It survives a refusal, because the grid is
                    // only rebuilt when the removal lands.
                    onRemoveRequested: root.favoriteAction.toggleAlbum(albumDelegate.modelData.id, true,
                                                                      albumDelegate)
                    onClicked: navigateTo("album", { albumId: modelData.id })
                    onPlayClicked: {
                        bridge.fetchAlbumTracks(modelData.id, function(tracks, err) {
                            if (err || tracks.length === 0) return
                            // Declaring the source fills "Playing from" and
                            // records the album as played.
                            player.setPlaybackSource("album", "" + modelData.id,
                                                     modelData.title || "")
                            player.playTracks(tracks, 0)
                        })
                    }
                }

            }

            ScrollBar.vertical: ScrollBar {
                active: true
                policy: ScrollBar.AsNeeded
                // A long list keeps a handle the pointer can find and grab.
                minimumSize: availableHeight > 0 ? Math.min(1, Theme.scrollHandleMin / availableHeight) : 0
            }
        }

        // Tab 2: Artists Tab (virtualized GridView)
        GridView {
            id: artistsGrid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 2
            opacity: root.contentIn
            clip: true
            property var sortedArtists: root.sortItems(root.filteredArtists, root.sortMode)
            model: sortedArtists
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: Theme.space4
            // Flickable only moves to contentX = -leftMargin by itself when the
            // view can flick that way, and a vertical grid cannot. The inset
            // follows the pane width, so it is re-applied here.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: FocusScope {
                id: artistDelegate
                width: artistsGrid.cellWidth
                height: artistsGrid.cellHeight
                required property var modelData
                required property int index

                MediaCard {
                    focus: true
                    tabStop: artistDelegate.GridView.isCurrentItem || artistDelegate.GridView.view.currentIndex < 0
                    onKeyboardOnChanged: if (keyboardOn) artistDelegate.GridView.view.positionViewAtIndex(index, GridView.Contain)
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(artistsGrid.cellWidth)
                    title: modelData.name
                    subtitle: qsTr("Artist")
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "artist"
                    itemId: "" + modelData.id
                    // As on the album grid. An artist is not a tracklist, so
                    // the menu offers Pin and nothing else above the rule.
                    removeLabel: qsTr("Unfollow artist")
                    // As on the album grid above.
                    onRemoveRequested: root.favoriteAction.toggleArtist(artistDelegate.modelData.id, true,
                                                                       artistDelegate)
                    onClicked: navigateTo("artist", { artistId: modelData.id })
                }
            }

            ScrollBar.vertical: ScrollBar {
                active: true
                policy: ScrollBar.AsNeeded
                // A long list keeps a handle the pointer can find and grab.
                minimumSize: availableHeight > 0 ? Math.min(1, Theme.scrollHandleMin / availableHeight) : 0
            }
        }

        // Tab 3: Playlists Tab (virtualized GridView)
        GridView {
            id: playlistsGrid
            objectName: "collectionPlaylistsGrid"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 3 && root.filteredPlaylists.length > 0
            opacity: root.contentIn
            clip: true
            property var sortedPlaylists: root.sortItems(root.filteredPlaylists, root.sortMode)
            model: sortedPlaylists
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: Theme.space4
            // Flickable only moves to contentX = -leftMargin by itself when the
            // view can flick that way, and a vertical grid cannot. The inset
            // follows the pane width, so it is re-applied here.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: FocusScope {
                id: playlistsGridCell
                width: playlistsGrid.cellWidth
                height: playlistsGrid.cellHeight
                MediaCard {
                    focus: true
                    tabStop: playlistsGridCell.GridView.isCurrentItem || playlistsGridCell.GridView.view.currentIndex < 0
                    onKeyboardOnChanged: if (keyboardOn) playlistsGridCell.GridView.view.positionViewAtIndex(index, GridView.Contain)
                    objectName: "collectionPlaylistCard"
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(playlistsGrid.cellWidth)
                    title: modelData.title
                    subtitle: qsTr("%Ln track(s)", "", modelData.numTracks)
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
                // A long list keeps a handle the pointer can find and grab.
                minimumSize: availableHeight > 0 ? Math.min(1, Theme.scrollHandleMin / availableHeight) : 0
            }
        }

        // Empty state for playlists
        Item {
            visible: root.activeTab === 3 && root.emptyKind === "empty"
            opacity: root.contentIn
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.space3
                VectorIcon { objectName: "collectionEmptyPlaylistsIcon"; Layout.alignment: Qt.AlignHCenter; name: "playlist"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No playlists yet"); color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Your saved playlists will appear here"); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
                // An account with no playlists is the one that needs one.
                PillButton {
                    objectName: "collectionEmptyNewPlaylistButton"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Theme.space1
                    text: qsTr("New playlist")
                    icon: "plus"
                    accent: true
                    onClicked: newPlaylistDialog.openEmpty()
                }
            }
        }

        // Tab 4: Mixes (GridView)
        GridView {
            id: mixesGrid
            objectName: "collectionMixesGrid"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 4 && root.filteredMixes.length > 0
            opacity: root.contentIn
            clip: true
            model: root.filteredMixes
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: Theme.space4
            // Flickable only moves to contentX = -leftMargin by itself when the
            // view can flick that way, and a vertical grid cannot. The inset
            // follows the pane width, so it is re-applied here.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: FocusScope {
                id: mixesGridCell
                width: mixesGrid.cellWidth
                height: mixesGrid.cellHeight
                MediaCard {
                    focus: true
                    tabStop: mixesGridCell.GridView.isCurrentItem || mixesGridCell.GridView.view.currentIndex < 0
                    onKeyboardOnChanged: if (keyboardOn) mixesGridCell.GridView.view.positionViewAtIndex(index, GridView.Contain)
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(mixesGrid.cellWidth)
                    title: modelData.title
                    subtitle: modelData.subtitle || ""
                    coverUrl: modelData.coverUrl || ""
                    mediaType: "mix"
                    itemId: "" + modelData.id
                    onClicked: navigateTo("mix", { mixId: modelData.id, title: modelData.title, subtitle: modelData.subtitle, coverUrl: modelData.coverUrl, mixType: modelData.mixType || "" })
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
                // A long list keeps a handle the pointer can find and grab.
                minimumSize: availableHeight > 0 ? Math.min(1, Theme.scrollHandleMin / availableHeight) : 0
            }
        }

        // Empty state for mixes
        Item {
            visible: root.activeTab === 4 && root.emptyKind === "empty"
            opacity: root.contentIn
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.space3
                VectorIcon { objectName: "collectionEmptyMixesIcon"; Layout.alignment: Qt.AlignHCenter; name: "mix"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No mixes"); color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Your Tidal mixes will appear here"); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
            }
        }

        // Empty state for tracks
        Item {
            visible: root.activeTab === 0 && root.emptyKind === "empty"
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.space3
                VectorIcon { objectName: "collectionEmptyTracksIcon"; Layout.alignment: Qt.AlignHCenter; name: "heart"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No saved tracks"); color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Like tracks to see them here"); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
            }
        }

        // Empty state for albums
        Item {
            visible: root.activeTab === 1 && root.emptyKind === "empty"
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.space3
                VectorIcon { objectName: "collectionEmptyAlbumsIcon"; Layout.alignment: Qt.AlignHCenter; name: "album"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No saved albums"); color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Save albums to see them here"); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
            }
        }

        // The field matches nothing on this tab. Not the empty library's
        // copy: the library may hold plenty.
        Item {
            objectName: "collectionNoMatches"
            visible: root.emptyKind === "filter"
            opacity: root.contentIn
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 420)
                spacing: Theme.space3
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "search"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim }
                Text {
                    objectName: "collectionNoMatchesText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("Nothing matches \"%1\"").arg(root.searchPattern)
                    color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("Try other words, or clear the search to see everything.")
                    color: Theme.textSec; font.pixelSize: Theme.fontMeta
                }
            }
        }

        // The list never arrived: offline, or Tidal did not answer. The
        // connection notice above the page offers the retry.
        Item {
            objectName: "collectionUnavailable"
            visible: root.emptyKind === "failed"
            opacity: root.contentIn
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 420)
                spacing: Theme.space3
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: ["heart", "album", "artist", "playlist", "mix"][root.activeTab] || "heart"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim }
                Text {
                    objectName: "collectionUnavailableText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.activeTab === 4 ? qsTr("Mixes could not be loaded")
                                               : qsTr("Your collection could not be loaded")
                    color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("Tidal could not be reached. It loads again by itself once the connection is back.")
                    color: Theme.textSec; font.pixelSize: Theme.fontMeta
                }
                PillButton {
                    objectName: "collectionUnavailableRetry"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Theme.space1
                    text: qsTr("Try again")
                    accent: false
                    onClicked: {
                        if (root.activeTab === 4) root.loadMixes()
                        else bridge.retryConnection()
                    }
                }
            }
        }

        // Empty state for artists
        Item {
            visible: root.activeTab === 2 && root.emptyKind === "empty"
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.space3
                VectorIcon { objectName: "collectionEmptyArtistsIcon"; Layout.alignment: Qt.AlignHCenter; name: "artist"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No followed artists"); color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Follow artists to see them here"); color: Theme.textSec; font.pixelSize: Theme.fontMeta }
            }
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    // Both "New playlist" buttons open the one dialog. Nothing is reloaded on
    // success: the bridge emits favoritePlaylistsChanged and the lists rebuild.
    // The alias is a test's handle on a Popup, which reparents to the overlay.
    readonly property alias playlistDialog: newPlaylistDialog

    NewPlaylistDialog { id: newPlaylistDialog }

    // Below the tabs, chips and sort, which stay in reach while it loads.
    Skeleton { loading: root.loading || root.tabWaiting; kind: root.activeTab === 0 ? "rows" : "grid"; topInset: viewsTop.y }
}
