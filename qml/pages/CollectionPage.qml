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

    // ── the content area changing under the tabs and the sort pills ──────
    //
    // A tab switch and a re-sort both replace what the content area shows
    // outright, and until this they replaced it between two frames.
    //
    // A fade and not a reorder, deliberately. Every view below is modelled on
    // a JS array, and a ListView or GridView can only read a new array as a
    // model *reset* - probed on Qt 6.12: reordering a five-item array fires
    // `populate` once per row and `move` not at all - so there is no reorder
    // for the view to animate. Re-sorting also moves nearly every tile at
    // once, which is a different thing from one row changing tier in the
    // sidebar: the content is new, and arriving is what it should look like.
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
    // The four favourites tabs count what the bridge already holds; mixes used
    // to be fetched only on the way into their own tab, and the tab label reads
    // the same list the grid does. So the row of tabs said "Mixes (0)" to
    // everyone who had not been in there yet - including anyone arriving from
    // "View all" on the home row, which points straight at it. A tab that
    // reports itself empty is not a tab anyone opens, which is most of why the
    // two mixes at the end of that row could not be got at. Fetched on the way
    // in instead; the Loader only builds this page once the user is signed in,
    // and only ever builds it once.
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
    // Both are removals only, so `true` is passed for the current state at both
    // sites - a tile in this grid is in the library by definition. The grids
    // redraw off the bridge's own signals, so a refusal leaves the tile where it
    // is; without this it also left no word, and a tile that stays after
    // "Remove from library" reads as a click that missed.
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

                // ── the highlight, as one pill that travels ────────────────
                //
                // The accent fill used to belong to the chip: the one being
                // left faded back to the resting surface while the one arriving
                // faded up to the accent, so the highlight was briefly nowhere
                // and nothing ever crossed the gap between the two (QA: "not
                // just fade out in one place and then fade in in the other
                // place"). There is one pill now and it moves, the same way the
                // sidebar's bar moves between its three rows and on the same
                // 140ms, so the two read as one idea.
                //
                // Which chip it is leaving, which it is arriving at, and how far
                // along it is. Only `markT` is animated. The geometry is read
                // live off the two chips, which matters more here than in the
                // sidebar: these chips are text-width and their text carries a
                // count, so typing in the collection's search box rewrites all
                // five widths while nothing has been selected. An animated width
                // would spend 140ms per keystroke chasing a pill that is not
                // going anywhere; a lerp between two live boxes is simply right
                // in the frame the box changes.
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

                // The end it set off from - the destination itself when there is
                // nothing to set off from, which makes the lerp degenerate and
                // markT unobservable. That is the first placement, and it is
                // also a model rebuild.
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

                // Inside the row rather than on the page's root: an id is only
                // bound once the object exists, and activeTab can be handed to
                // the page as an initial property, i.e. before this row is here
                // to answer.
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
                    // pill is aimed again as the chips arrive as well as when
                    // the tab changes.
                    onItemAdded: function (index, item) { tabsRow.retarget(false) }
                    Rectangle {
                        id: collectionTab
                        required property string modelData
                        required property int    index
                        height: 34; width: tl.implicitWidth + 24; radius: Theme.radiusChip
                        // Every chip rests on the same surface now, including
                        // the current one: what marks it is the pill above,
                        // which is drawn here in pieces.
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

                        // This chip's slice of the pill.
                        //
                        // One Rectangle per chip rather than one pill over the
                        // row, because the row is a Flow and anything added to
                        // it is laid out by it. Each chip draws the whole pill
                        // and shows the part of it that falls inside this
                        // window, so the five slices add up to one pill.
                        //
                        // The window reaches 2px past the chip, which is half
                        // the row's 4px gap, so two neighbours' windows meet in
                        // the middle of the gap and the pill crosses it unbroken
                        // instead of being cut in two on the way over.
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
                            // The ink the resting surface takes, always. The
                            // accent's ink is the copy below, and which of the
                            // two is on screen at a given pixel is decided by
                            // where the pill is rather than by a clock.
                            color: Theme.textSec
                            // Not drawn at all where the copy covers every
                            // pixel of it, which is the resting state of the
                            // current chip. Two Texts in the same place blend
                            // at the glyphs' antialiased edge - the ink
                            // underneath is the resting ink on the accent fill,
                            // which is the ~2:1 pairing the comment below calls
                            // invisible, but it is only *nearly* invisible and
                            // the settled chip is where the eye lives. Measured
                            // against the fading chip's pixels: identical with
                            // this, up to 40/255 on the glyph edges without it.
                            visible: !collectionTab.labelFullyInked
                            // Not animatable - a font weight is not a number Qt
                            // interpolates - so it lands in the frame of the
                            // click.
                            font.pixelSize: 14; font.bold: root.activeTab === index
                        }

                        // The same label again in the ink the accent needs,
                        // clipped to exactly the part of the pill that is over
                        // this chip.
                        //
                        // This is what lets the fill travel at all. The two inks
                        // are luminance-inverted against the two fills on the
                        // three light palettes - dark ink on a light chip
                        // becomes white ink on a dark one - so a label cannot
                        // cross-fade between them (measured in 354d460: under
                        // 2:1 for 57ms of a 140ms fade, bottoming out at
                        // 1.01:1), and it cannot be stepped either when a hard
                        // fill edge is sweeping across it: whichever ink it
                        // steps to, half the glyphs are on the wrong fill for as
                        // long as the edge takes to cross them. Two copies, each
                        // clipped to its own fill, means every glyph pixel is on
                        // the fill its ink was chosen for in every frame of the
                        // travel - which is better than the single stepped frame
                        // the fade settled for, rather than a trade against it.
                        //
                        // The copy underneath shows through at the glyphs'
                        // antialiased edge, and that is the one thing that is
                        // free here: the ink showing through is the resting ink
                        // on the accent fill, i.e. exactly the pairing the
                        // measurement above calls invisible.
                        Item {
                            id: inkWindow
                            objectName: "collectionTabInk"
                            // The pill, in this chip's coordinates, clamped to
                            // the chip. Vertical as well as horizontal: the row
                            // wraps at narrow widths, and a pill travelling
                            // between two lines passes over the chips in
                            // between, where it covers a band and not a column.
                            //
                            // Not `top`/`bottom`: an Item has those as final
                            // members, and a property that shadows one takes
                            // the whole type out of the build with it.
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

        // The field gets its own row. On one row with the tabs and the sort
        // pills the header needed ~1083px against a 740px pane, so it
        // overflowed at every width the app actually runs at.
        //
        // "New playlist" shares that row rather than joining the tabs above
        // it, for the same reason. The tab row is already a Flow that has to
        // wrap at 640 to fit five labelled chips and three sort pills, so a
        // third group on it is a third thing competing for a width that has
        // already run out; this row holds one field that gives width back on
        // demand. It also puts the button directly over the grid it adds to,
        // and only on the tab where making one means anything.
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
                    anchors.centerIn: parent
                    cardSize: root.gridCardSize(albumsGrid.cellWidth)
                    title: modelData.title
                    subtitle: modelData.artists
                    coverUrl: modelData.coverUrl
                    mediaType: "album"
                    itemId: "" + modelData.id
                    // The tile's own menu does the whole job now: Pin, the
                    // two queue actions and this. There used to be a Menu
                    // declared under this card that covered the card's, which
                    // is why an album could not be pinned from Collection at
                    // all. "Go to album" went with it: that is what clicking
                    // the tile does.
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
                            // Declaring the source both fills "Playing from"
                            // and is what records the album as played (S4).
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
                    // As on the album grid: one menu, the tile's own, so Pin
                    // is reachable here too. An artist is not a tracklist, so
                    // this one offers Pin and nothing else above the rule.
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
                    // The second of the three places a cached playlist count is
                    // drawn, and so one of the three the reported bug reached.
                    // Named so a test can read the tile rather than the model.
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
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "playlist"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("No playlists yet"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Your saved playlists will appear here"); color: Theme.textSec; font.pixelSize: 13 }
                // An empty state that only describes the emptiness is a dead
                // end: an account with no playlists is exactly the account
                // that needs to make one, and until this there was nowhere in
                // the app to do it.
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
            opacity: root.contentIn
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "mix"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
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
                VectorIcon { Layout.alignment: Qt.AlignHCenter; name: "album"; width: 40; height: 40; color: Theme.textDim; strokeWidth: 1.5 }
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

    // Both "New playlist" buttons on this page open the one dialog; see
    // NewPlaylistDialog.qml.
    //
    // Nothing is reloaded on a success and the page does not navigate away.
    // TidalBridge appends the new playlist to the favourites cache the four
    // searchFavorite* calls read and emits favoritePlaylistsChanged, which the
    // Connections block at the top of this file already answers by rebuilding
    // the filtered lists - so the card appears in the grid the user is looking
    // at, and the Playlists tab's count goes up with it. Being thrown onto an
    // empty playlist page instead would take them off the list they were
    // curating.
    //
    // A Popup is not a visual child of the page once it reparents itself to
    // the window overlay, so the alias is a test's only handle on it.
    readonly property alias playlistDialog: newPlaylistDialog

    NewPlaylistDialog { id: newPlaylistDialog }

    LoadingOverlay { loading: root.loading }
}
