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

    // Grid metrics for the four grids below, all derived from the grid's width
    // alone. cellWidth is floored, so the columns never cross the viewport, and
    // the remainder is split between the two edge insets.
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
        duration: Theme.dur(170)
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

            // A Flow, not a Row: five tab labels with counts are wider than the
            // pane at 640, so they wrap. The sort pills stay right.
            Flow {
                id: tabsRow
                objectName: "collectionTabsRow"
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 4

                // ── the highlight, as one pill that travels ────────────────
                // One pill that moves between the chips. Only `markT` is
                // animated: the geometry is read live off the two chips, whose
                // widths change with every count.
                property Item markFrom: null
                property Item markTo:   null
                property real markT:    1
                // The reset to 0 that starts a travel is the one write to markT
                // that must not animate, or the pill would run backwards to the
                // chip it is already on before setting off.
                property bool markResetting: false
                // The first placement is an initialisation, not a move. Without
                // the gate the pill would grow out of the row's left edge on
                // every visit to the page.
                property bool markSettled: false

                Behavior on markT {
                    enabled: !tabsRow.markResetting
                    NumberAnimation { duration: Theme.dur(140); easing.type: Easing.OutCubic }
                }

                // The end it set off from, or the destination itself when there
                // is none, which makes the lerp degenerate. That covers the
                // first placement and a model rebuild.
                readonly property Item markA: markFrom ? markFrom : markTo
                readonly property real markX: markTo ? markA.x + (markTo.x - markA.x) * markT : 0
                readonly property real markY: markTo ? markA.y + (markTo.y - markA.y) * markT : 0
                readonly property real markW: markTo ? markA.width  + (markTo.width  - markA.width)  * markT : 0
                readonly property real markH: markTo ? markA.height + (markTo.height - markA.height) * markT : 0

                function retarget(animate) {
                    var next = tabsRepeater.itemAt(root.activeTab)
                    if (next === null || next === tabsRow.markTo) return
                    tabsRow.markFrom = (animate && tabsRow.markTo !== null) ? tabsRow.markTo : next
                    tabsRow.markTo   = next
                    tabsRow.markResetting = true
                    tabsRow.markT = 0
                    tabsRow.markResetting = false
                    tabsRow.markT = 1
                }

                // Inside the row, not on the page's root: activeTab can arrive
                // as an initial property, before this row exists.
                Connections {
                    target: root
                    function onActiveTabChanged() { tabsRow.retarget(tabsRow.markSettled) }
                }

                Component.onCompleted: {
                    retarget(false)
                    Qt.callLater(function () { tabsRow.markSettled = true })
                }

                Repeater {
                    id: tabsRepeater
                    model: [qsTr("Tracks"), qsTr("Albums"), qsTr("Artists"), qsTr("Playlists"), qsTr("Mixes")]
                    // itemAt() is a function call and not a dependency, so the
                    // pill is aimed again as the chips arrive.
                    onItemAdded: function (index, item) { tabsRow.retarget(false) }
                    Rectangle {
                        id: collectionTab
                        required property string modelData
                        required property int    index
                        height: 34; width: tl.implicitWidth + 24; radius: Theme.radiusChip
                        // Every chip rests on the same surface, including the
                        // current one. The pill marks it, drawn here in slices.
                        color: Theme.surfaceHigh
                        border.width: collectionTab.activeFocus ? 2 : 0
                        border.color: Theme.accent
                        activeFocusOnTab: true
                        Keys.onReturnPressed: { root.activeTab = index }
                        Keys.onSpacePressed:  { root.activeTab = index }

                        // Whether the accent's copy of the label covers every
                        // pixel the chip's own copy occupies.
                        readonly property bool labelFullyInked:
                               inkWindow.visible
                            && inkWindow.x <= tl.x
                            && inkWindow.x + inkWindow.width  >= tl.x + tl.width
                            && inkWindow.y <= tl.y
                            && inkWindow.y + inkWindow.height >= tl.y + tl.height

                        // This chip's slice of the pill: a Flow lays out
                        // anything added to it. The clip reaches 2px past the
                        // chip, half the row's gap, so the slices meet.
                        Item {
                            anchors.fill: parent
                            anchors.margins: -2
                            clip: true
                            Rectangle {
                                objectName: "collectionTabPillSlice"
                                x: tabsRow.markX - collectionTab.x + 2
                                y: tabsRow.markY - collectionTab.y + 2
                                width:  tabsRow.markW
                                height: tabsRow.markH
                                radius: Theme.radiusChip
                                color: Theme.accent
                            }
                        }

                        Text {
                            id: tl; objectName: "collectionTabLabel"; anchors.centerIn: parent
                            text: {
                                var counts = [root.filteredTracks.length, root.filteredAlbums.length, root.filteredArtists.length, root.filteredPlaylists.length, root.mixes.length]
                                // Tab name followed by how many items it holds
                                return qsTr("%1 (%2)").arg(modelData)
                                                      .arg(counts[index].toLocaleString(Qt.locale(), 'f', 0))
                            }
                            // Always the ink of the resting surface. The
                            // accent's ink is the copy below.
                            color: Theme.textSec
                            // Hidden where the copy covers every pixel of it:
                            // two Texts in one place blend at the glyphs'
                            // antialiased edge.
                            visible: !collectionTab.labelFullyInked
                            // A font weight does not interpolate, so it lands
                            // in the frame of the click.
                            font.pixelSize: 14; font.bold: root.activeTab === index
                        }

                        // The label again in the accent's ink, clipped to the
                        // pill, so every glyph pixel is on the fill its ink was
                        // chosen for. The two inks cannot cross-fade legibly.
                        Item {
                            id: inkWindow
                            objectName: "collectionTabInk"
                            // The pill in this chip's coordinates, clamped on
                            // both axes since the row wraps. Not
                            // `top`/`bottom`: Item has those as final members.
                            readonly property real coveredLeft:   Math.max(0, tabsRow.markX - collectionTab.x)
                            readonly property real coveredRight:  Math.min(collectionTab.width, tabsRow.markX + tabsRow.markW - collectionTab.x)
                            readonly property real coveredTop:    Math.max(0, tabsRow.markY - collectionTab.y)
                            readonly property real coveredBottom: Math.min(collectionTab.height, tabsRow.markY + tabsRow.markH - collectionTab.y)
                            x: coveredLeft
                            y: coveredTop
                            width:  Math.max(0, coveredRight - coveredLeft)
                            height: Math.max(0, coveredBottom - coveredTop)
                            clip: true
                            visible: width > 0 && height > 0
                            Text {
                                objectName: "collectionTabInkLabel"
                                x: tl.x - inkWindow.x
                                y: tl.y - inkWindow.y
                                text: tl.text
                                font: tl.font
                                color: Theme.accentInk
                            }
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

        // The field gets its own row: with the tabs and the sort pills the
        // header overflows the pane. "New playlist" shares this row, directly
        // over the grid it adds to.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 24
            Layout.rightMargin: 24
            spacing: 12

            SearchBar {
                id: collectionSearch
                objectName: "collectionSearch"
                // A whole phrase per tab: German cannot take "Search saved " + a noun
                placeholder: [qsTr("Search saved tracks…"), qsTr("Search saved albums…"),
                              qsTr("Search saved artists…"), qsTr("Search saved playlists…")
                             ][root.activeTab] || qsTr("Search saved items…")
                Layout.fillWidth: true
                Layout.preferredHeight: 36
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

        Item { Layout.preferredHeight: 16 }

        // Tracks Tab: virtualized ListView
        ListView {
            id: tracksList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 0
            opacity: root.contentIn
            clip: true
            property var sortedTracks: root.sortItems(root.filteredTracks, root.sortMode)
            model: root.activeTab === 0 ? sortedTracks : []
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
                // Both ids are undefined on a partial payload, and undefined
                // equals undefined, which would mark every row as playing.
                isPlaying:   Number(modelData.id) > 0
                             && player.currentTrack.id === modelData.id && player.playing
                trackData:   modelData
                onPlayRequested: {
                    player.setPlaybackSource("collection", "tracks", qsTr("Liked Songs"))
                    // "Liked Songs" is not a kind the sidebar orders and
                    // markPlayed() drops it, so the track's album stands in.
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
            opacity: root.contentIn
            clip: true
            property var sortedAlbums: root.sortItems(root.filteredAlbums, root.sortMode)
            model: root.activeTab === 1 ? sortedAlbums : []
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: 16
            // Flickable only moves to contentX = -leftMargin by itself when the
            // view can flick that way, and a vertical grid cannot. The inset
            // follows the pane width, so it is re-applied here.
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
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(albumsGrid.cellWidth)
                    title: modelData.title
                    subtitle: modelData.artists
                    coverUrl: modelData.coverUrl
                    mediaType: "album"
                    itemId: "" + modelData.id
                    // The tile's own menu has Pin, the queue actions and this.
                    removeLabel: qsTr("Remove from library")
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
            model: root.activeTab === 2 ? sortedArtists : []
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: 16
            // Flickable only moves to contentX = -leftMargin by itself when the
            // view can flick that way, and a vertical grid cannot. The inset
            // follows the pane width, so it is re-applied here.
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
            }
        }

        // Tab 3: Playlists Tab (virtualized GridView)
        GridView {
            id: playlistsGrid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 3 && root.filteredPlaylists.length > 0
            opacity: root.contentIn
            clip: true
            model: root.activeTab === 3 ? root.filteredPlaylists : []
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: 16
            // Flickable only moves to contentX = -leftMargin by itself when the
            // view can flick that way, and a vertical grid cannot. The inset
            // follows the pane width, so it is re-applied here.
            onLeftMarginChanged: contentX = -leftMargin
            Component.onCompleted: contentX = -leftMargin
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                width: playlistsGrid.cellWidth
                height: playlistsGrid.cellHeight
                MediaCard {
                    objectName: "collectionPlaylistCard"
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
            opacity: root.contentIn
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { objectName: "collectionEmptyPlaylistsIcon"; Layout.alignment: Qt.AlignHCenter; name: "playlist"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No playlists yet"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Your saved playlists will appear here"); color: Theme.textSec; font.pixelSize: 13 }
                // An account with no playlists is the one that needs one.
                PillButton {
                    objectName: "collectionEmptyNewPlaylistButton"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 4
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
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.activeTab === 4 && root.mixes.length > 0
            opacity: root.contentIn
            clip: true
            model: root.activeTab === 4 ? root.mixes : []
            readonly property int columns: root.gridColumns(width)
            cellWidth: root.gridCell(width)
            cellHeight: cellWidth + 48
            leftMargin: root.gridLeft(width)
            rightMargin: root.gridRight(width)
            topMargin: 16
            // Flickable only moves to contentX = -leftMargin by itself when the
            // view can flick that way, and a vertical grid cannot. The inset
            // follows the pane width, so it is re-applied here.
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
            }
        }

        // Empty state for mixes
        Item {
            visible: root.activeTab === 4 && root.mixes.length === 0
            opacity: root.contentIn
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { objectName: "collectionEmptyMixesIcon"; Layout.alignment: Qt.AlignHCenter; name: "mix"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim; strokeWidth: 1.5 }
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
                VectorIcon { objectName: "collectionEmptyTracksIcon"; Layout.alignment: Qt.AlignHCenter; name: "heart"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim; strokeWidth: 1.5 }
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
                VectorIcon { objectName: "collectionEmptyAlbumsIcon"; Layout.alignment: Qt.AlignHCenter; name: "album"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim; strokeWidth: 1.5 }
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
                VectorIcon { objectName: "collectionEmptyArtistsIcon"; Layout.alignment: Qt.AlignHCenter; name: "artist"; Layout.preferredWidth: 40; Layout.preferredHeight: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No followed artists"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Follow artists to see them here"); color: Theme.textSec; font.pixelSize: 13 }
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

    LoadingOverlay { loading: root.loading }
}
