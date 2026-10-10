import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg
    focus: true

    property string query: ""
    property var    tracks:    []
    property var    albums:    []
    property var    artists:   []
    property var    playlists: []
    property var    mixes:     []
    property bool   loading:   false
    property int    activeTab: 0
    property int    _searchGen: 0

    // The tabs, and the kinds, are the same five numbers everywhere in this
    // file: 1 tracks, 2 albums, 3 artists, 4 playlists, 5 mixes, with 0 for the
    // All tab. Index 0 of every per-kind array below is therefore unused.
    readonly property int kTracks:    1
    readonly property int kAlbums:    2
    readonly property int kArtists:   3
    readonly property int kPlaylists: 4
    readonly property int kMixes:     5

    // The query the five arrays and `errorText` describe, and the reason the
    // last reply failed (empty when it did not). Nothing may be said about a
    // query until a reply for that query has landed: see `replied`.
    property string repliedFor: ""
    property string errorText:  ""

    readonly property bool replied: query.length >= 2 && repliedFor === query

    // Hits of the kind the active tab shows, so the no-results strip speaks
    // about that tab and not about all five arrays.
    readonly property int tabHits:
        activeTab === 0 ? totalHits : rowsOf(activeTab).length

    readonly property int totalHits:
        tracks.length + albums.length + artists.length
        + playlists.length + mixes.length

    // ── paging ──────────────────────────────────────────────────────────
    // Per kind: _sent counts rows the server handed over and is the next offset
    // (duplicates are dropped on arrival), _total is what the reply said the
    // kind holds, _more is whether to ask again. Index 0 is unused.
    property var _sent:  [0, 0, 0, 0, 0, 0]
    property var _total: [0, 0, 0, 0, 0, 0]
    property var _more:  [false, false, false, false, false, false]
    // "kind:id" for every row already on screen, so a row the server repeats
    // across two pages is dropped. A plain object: nothing binds to it.
    property var _seen: ({})
    property bool loadingMore: false

    readonly property int pageSize: 20
    // How close to the bottom counts as the bottom: about four rows of tracks,
    // so the next page is on its way before the last of them is on screen.
    readonly property int loadMoreMargin: 240

    // ── which section leads ─────────────────────────────────────────────
    // The kind whose best hit matches the query most strongly leads the All
    // tab, and the rest keep their default order. Recomputed once per search,
    // from the reply, never on an append or a keystroke.
    property var sectionOrder: [1, 2, 3, 4, 5]

    readonly property int defaultTracksCap: 5
    // The leading section earns a few more rows. Only Tracks has a cap.
    readonly property int leadingTracksCap: 8
    readonly property int allTabTracksCap:
        sectionOrder.length > 0 && sectionOrder[0] === kTracks
            ? leadingTracksCap : defaultTracksCap

    // ── the scoring vocabulary ──────────────────────────────────────────
    // The same tiers, coverage ceiling and folding as src/api/LibraryIndex.cpp,
    // restated because these rows never enter it: change both together. Tiers
    // are 100 apart and the adjustments below cannot reach that.
    readonly property int tierExact:     400   // the name *is* the query
    readonly property int tierPrefix:    300   // the name starts with it
    readonly property int tierWordStart: 200   // a later word starts with it
    readonly property int tierMidWord:   100   // buried inside a word
    readonly property int coverageMax:    40   // how much of the name the query is
    // How far down its own kind the hit sits. One point a row so that the same
    // score at index 0 beats it at index 7, capped well under the 60 that
    // would let a deep hit fall out of its tier.
    readonly property int indexPenaltyMax: 20
    // The leader has to be a full tier clear of the runner-up or nothing moves,
    // which keeps the page steady for half-typed and ambiguous queries.
    readonly property int leadMargin: 100

    function releaseFocus() {
        searchBar.releaseFocus()
    }

    // Arriving at the page. The router gives the Loader active focus, but the
    // Loader, this page's root and the bar's input share one focus scope, so
    // the field has to be asked separately.
    function takeFocus() {
        searchBar.takeFocus()
    }

    // A tab switch replaces the whole column below, so it fades in. The
    // sections are Repeaters over JS arrays, with no change set to animate.
    property real resultsIn: 1
    NumberAnimation {
        id: resultsEntry
        target: root
        property: "resultsIn"
        from: 0; to: 1
        duration: Theme.dur(170)
        easing.type: Easing.OutCubic
    }
    onActiveTabChanged: {
        resultsEntry.restart()
        // The column still has the previous tab's height until it is laid out
        // again, so the bottom check waits for it to settle.
        bottomSettle.restart()
    }

    // ── recent searches ─────────────────────────────────────────────────
    // The queries this account has run, newest first, kept by TidalBridge in
    // QSettings. Nothing leaves the machine and nothing is logged.
    property var recents: []

    function reloadRecents() { root.recents = bridge.recentSearches() }

    Component.onCompleted: reloadRecents()

    Connections {
        target: bridge
        function onRecentSearchesChanged() { root.reloadRecents() }
    }

    function runRecent(q) {
        searchBar.text = q          // drives onTextEdited, which sets root.query
        searchDebounce.stop()       // a query the user picked needs no settling
        if (q.length < 2) return
        bridge.addRecentSearch(q)   // running it again makes it the newest
        doSearch(q)
    }

    // ── a query handed over by another page ──────────────────────────────
    // The router hands parameters over by assigning them, so a search to run
    // arrives as a property. `query` will not do: it is the field's echo and
    // nothing watches it. Cleared as taken, so the same term can run twice.
    property string requestedQuery: ""
    onRequestedQueryChanged: {
        if (requestedQuery.length === 0) return
        var q = requestedQuery
        requestedQuery = ""
        searchFor(q)
    }

    // runRecent() without the bookkeeping: the user did not type this one. The
    // field is filled first: the bar's onTextEdited is what writes `query`.
    function searchFor(q) {
        searchBar.text = q
        searchDebounce.stop()       // a query that was handed over needs no settling
        if (q.length < 2) return
        doSearch(q)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item { height: 16 }

        SearchBar {
            id: searchBar
            objectName: "searchPageBar"
            focus: true
            Layout.fillWidth: true
            Layout.leftMargin: 24
            Layout.rightMargin: 24
            height: 46
            placeholder: qsTr("Search tracks, albums, artists, playlists…")
            onTextEdited: (text) => {
                root.query = text
                if (text.length < 2) { clearResults(); return }
                searchDebounce.restart()
            }
            // Enter means this is the query, so it is remembered whatever the
            // reply turns out to be.
            onSubmitted: (text) => {
                if (text.length < 2) return
                bridge.addRecentSearch(text)
                searchDebounce.stop()
                root.doSearch(text)
            }
        }

        Item { height: 12 }

        // ── the tab bar, and its highlight as one pill that travels ──────
        // One pill that moves between the chips. A Row lays out every visible
        // child, so the pill is the row's sibling inside this host Item.
        Item {
            id: tabsHost
            objectName: "searchTabsHost"
            visible: root.query.length >= 2
            Layout.leftMargin: 24
            // The row is the whole of this item's size. A plain Item has no
            // implicit size of its own, and a ColumnLayout asks for one.
            implicitWidth:  searchTabsRow.implicitWidth
            implicitHeight: searchTabsRow.implicitHeight

            // Which chip the pill is leaving, which it is arriving at, and how
            // far along it is. Only `markT` is animated: the geometry is a lerp
            // between the two chips' live boxes, so a layout change is instant.
            property Item markFrom: null
            property Item markTo:   null
            property real markT:    1
            // The reset to 0 that starts a travel is the one write to markT
            // that must not animate, or the pill would run backwards to the
            // chip it is already on before setting off.
            property bool markResetting: false
            // The first placement is an initialisation, not a move. Without the
            // gate the pill would grow out of the row's left edge every time a
            // query brings the row back.
            property bool markSettled: false

            Behavior on markT {
                enabled: !tabsHost.markResetting
                NumberAnimation { duration: Theme.dur(140); easing.type: Easing.OutCubic }
            }

            // The end it set off from, or the destination itself when there is
            // none, which makes the lerp degenerate. That covers the first
            // placement and a model rebuild.
            readonly property Item markA: markFrom ? markFrom : markTo
            readonly property real markX: markTo ? markA.x + (markTo.x - markA.x) * markT : 0
            readonly property real markY: markTo ? markA.y + (markTo.y - markA.y) * markT : 0
            readonly property real markW: markTo ? markA.width  + (markTo.width  - markA.width)  * markT : 0
            readonly property real markH: markTo ? markA.height + (markTo.height - markA.height) * markT : 0

            function retarget(animate) {
                var next = searchTabsRepeater.itemAt(root.activeTab)
                if (next === null || next === tabsHost.markTo) return
                tabsHost.markFrom = (animate && tabsHost.markTo !== null) ? tabsHost.markTo : next
                tabsHost.markTo   = next
                tabsHost.markResetting = true
                tabsHost.markT = 0
                tabsHost.markResetting = false
                tabsHost.markT = 1
            }

            // `visible` in the condition as well as the gate: a tab changed
            // while the row is off screen must not start a travel that plays
            // when the row comes back.
            Connections {
                target: root
                function onActiveTabChanged() {
                    tabsHost.retarget(tabsHost.markSettled && tabsHost.visible)
                }
            }

            Component.onCompleted: {
                retarget(false)
                Qt.callLater(function () { tabsHost.markSettled = true })
            }

            // Behind the chips, which rest on nothing, so the pill reads as the
            // fill. Behind because a chip's hover tint is opaque; see the
            // chip's colour below.
            Rectangle {
                objectName: "searchTabPill"
                x: tabsHost.markX
                y: tabsHost.markY
                width:  tabsHost.markW
                height: tabsHost.markH
                radius: Theme.radiusChip
                color: Theme.accent
                visible: width > 0 && height > 0
            }

            Row {
                id: searchTabsRow
                objectName: "searchTabsRow"
                spacing: 4
                Repeater {
                    id: searchTabsRepeater
                    model: [qsTr("All"), qsTr("Tracks"), qsTr("Albums"),
                            qsTr("Artists"), qsTr("Playlists"), qsTr("Mixes")]
                    // itemAt() is a function call and not a dependency, so the
                    // pill is aimed again as the chips arrive. A language
                    // change rebuilds all six.
                    onItemAdded: function (index, item) { tabsHost.retarget(false) }
                    Rectangle {
                        id: searchTab
                        required property string modelData
                        required property int    index
                        height: 30; width: tabLabel.implicitWidth + 24; radius: Theme.radiusChip
                        // The pill behind the row marks the current chip. The
                        // hover tint drops out on any chip the pill is over:
                        // surfaceHov is opaque and would paint over it.
                        color: tabMA.containsMouse && !searchTab.pillOverlaps
                               ? Theme.surfaceHov : "transparent"
                        // The chip must not snap while the results fade.
                        Behavior on color { ColorAnimation { duration: Theme.dur(140) } }

                        // Whether any part of the pill is over this chip.
                        // Horizontal only: the row does not wrap.
                        readonly property bool pillOverlaps:
                               tabsHost.markW > 0
                            && tabsHost.markX < searchTab.x + searchTab.width
                            && tabsHost.markX + tabsHost.markW > searchTab.x

                        // Whether the accent's copy of the label covers every pixel
                        // the chip's own copy occupies.
                        readonly property bool labelFullyInked:
                               inkWindow.visible
                            && inkWindow.x <= tabLabel.x
                            && inkWindow.x + inkWindow.width  >= tabLabel.x + tabLabel.width
                            && inkWindow.y <= tabLabel.y
                            && inkWindow.y + inkWindow.height >= tabLabel.y + tabLabel.height

                        border.width: searchTab.activeFocus ? 2 : 0
                        border.color: Theme.accent
                        activeFocusOnTab: true
                        Keys.onReturnPressed: root.activeTab = index
                        Keys.onSpacePressed:  root.activeTab = index
                        Text {
                            id: tabLabel; objectName: "searchTabLabel"; anchors.centerIn: parent
                            text: modelData
                            // Always the ink of the bare row. The accent's ink
                            // is the copy below.
                            color: Theme.textSec
                            // Hidden where the copy covers every pixel of it:
                            // two Texts in one place blend at the glyphs'
                            // antialiased edge.
                            visible: !searchTab.labelFullyInked
                            font.pixelSize: 13
                        }

                        // The label again in the accent's ink, clipped to the
                        // pill, so every glyph pixel is on the fill its ink was
                        // chosen for. The two inks cannot cross-fade legibly.
                        Item {
                            id: inkWindow
                            objectName: "searchTabInk"
                            // The pill in this chip's coordinates, clamped so
                            // it is empty when the pill is elsewhere. Not
                            // `top`/`bottom`: Item has those as final members.
                            readonly property real coveredLeft:   Math.max(0, tabsHost.markX - searchTab.x)
                            readonly property real coveredRight:  Math.min(searchTab.width, tabsHost.markX + tabsHost.markW - searchTab.x)
                            readonly property real coveredTop:    Math.max(0, tabsHost.markY - searchTab.y)
                            readonly property real coveredBottom: Math.min(searchTab.height, tabsHost.markY + tabsHost.markH - searchTab.y)
                            x: coveredLeft
                            y: coveredTop
                            width:  Math.max(0, coveredRight - coveredLeft)
                            height: Math.max(0, coveredBottom - coveredTop)
                            clip: true
                            visible: width > 0 && height > 0
                            Text {
                                objectName: "searchTabInkLabel"
                                x: tabLabel.x - inkWindow.x
                                y: tabLabel.y - inkWindow.y
                                text: tabLabel.text
                                font: tabLabel.font
                                color: Theme.accentInk
                            }
                        }

                        MouseArea {
                            id: tabMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.activeTab = index
                        }
                    }
                }
            }
        }

        Item { height: 8 }

        // Empty state, outside the ScrollView so it centres in the page: the
        // last few queries when there are any, the illustration otherwise.
        Item {
            objectName: "searchEmptyState"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.query.length < 2

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 16
                visible: root.recents.length === 0
                VectorIcon {
                    Layout.alignment: Qt.AlignHCenter
                    name: "search"
                    color: Theme.textDim
                    width: 48
                    height: 48
                    strokeWidth: 2.0
                }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Search Tidal"); color: Theme.textPrimary; font.pixelSize: 22; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Find tracks, albums, artists and more"); color: Theme.textSec; font.pixelSize: 14 }
            }

            ColumnLayout {
                objectName: "searchRecents"
                anchors.centerIn: parent
                width: Math.min(420, parent.width - 48)
                spacing: 4
                visible: root.recents.length > 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 4
                    Text {
                        text: qsTr("Recent searches")
                        color: Theme.textPrimary
                        font.pixelSize: 15
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    Item {
                        id: clearAll
                        objectName: "searchRecentsClearAll"
                        implicitWidth: clearAllText.implicitWidth
                        implicitHeight: clearAllText.implicitHeight
                        activeFocusOnTab: true
                        Keys.onReturnPressed: bridge.clearRecentSearches()
                        Keys.onSpacePressed:  bridge.clearRecentSearches()
                        Text {
                            id: clearAllText
                            anchors.fill: parent
                            text: qsTr("Clear all")
                            color: clearAll.activeFocus || clearAllMA.containsMouse
                                   ? Theme.accent : Theme.textSec
                            font.pixelSize: 13
                            font.underline: clearAll.activeFocus
                        }
                        MouseArea {
                            id: clearAllMA
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: bridge.clearRecentSearches()
                        }
                    }
                }

                Repeater {
                    model: root.recents
                    Rectangle {
                        id: recentRow
                        objectName: "searchRecentRow"
                        required property string modelData
                        Layout.fillWidth: true
                        height: 34
                        radius: Theme.radiusChip
                        color: rowMA.containsMouse ? Theme.surfaceHov : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.dur(120) } }

                        MouseArea {
                            id: rowMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.runRecent(recentRow.modelData)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 8
                            spacing: 10
                            VectorIcon {
                                name: "clock"
                                color: Theme.textDim
                                width: 14; height: 14
                                strokeWidth: 1.8
                            }
                            Text {
                                Layout.fillWidth: true
                                text: recentRow.modelData
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                elide: Text.ElideRight
                            }
                            Item {
                                id: dropRecent
                                objectName: "searchRecentRemove"
                                implicitWidth: 14
                                implicitHeight: 14
                                Layout.alignment: Qt.AlignVCenter
                                activeFocusOnTab: true
                                Keys.onReturnPressed: bridge.removeRecentSearch(recentRow.modelData)
                                Keys.onSpacePressed:  bridge.removeRecentSearch(recentRow.modelData)
                                Rectangle {
                                    anchors.fill: parent; anchors.margins: -4
                                    radius: Theme.radiusButton; color: "transparent"
                                    border.width: dropRecent.activeFocus ? 2 : 0
                                    border.color: Theme.accent
                                }
                                VectorIcon {
                                    anchors.fill: parent
                                    name: "x"
                                    color: dropRecent.activeFocus || dropMA.containsMouse
                                           ? Theme.accent : Theme.textDim
                                    strokeWidth: 1.8
                                }
                                MouseArea {
                                    id: dropMA
                                    anchors.fill: parent
                                    anchors.margins: -5
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    // The row under this is clickable too, and
                                    // removing a query must not also run it.
                                    onClicked: (mouse) => {
                                        mouse.accepted = true
                                        bridge.removeRecentSearch(recentRow.modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        ScrollView {
            id: resultsScroll
            objectName: "searchScroll"
            Layout.fillWidth: true
            Layout.fillHeight: true
            rightPadding: 14
            contentWidth: availableWidth
            visible: root.query.length >= 2
            opacity: root.resultsIn

            ColumnLayout {
                objectName: "searchResults"
                width: parent.width
                spacing: 0

                // A failed search says so in one line of Theme.red text, as
                // LoginPage does for a failed sign-in.
                Item {
                    objectName: "searchErrorStrip"
                    Layout.fillWidth: true
                    height: 80
                    visible: root.replied && root.errorText.length > 0
                    Text {
                        objectName: "searchErrorLabel"
                        anchors.centerIn: parent
                        width: parent.width - 48
                        text: qsTr("Search failed: %1").arg(root.errorText)
                        color: Theme.red
                        font.pixelSize: 15
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                // No results indicator: only about a query that has an answer
                // of its own (see `replied`), and only about the kind the
                // active tab shows.
                Item {
                    objectName: "searchEmptyStrip"
                    Layout.fillWidth: true
                    height: 80
                    visible: root.replied && root.errorText.length === 0
                             && root.tabHits === 0 && !root.loading
                    Text {
                        objectName: "searchEmptyLabel"
                        anchors.centerIn: parent
                        // On a type tab whose kind came back empty while
                        // another did not, the line names the kind. When
                        // nothing matched anywhere it is about the search.
                        text: root.totalHits > 0
                            ? (root.activeTab === root.kTracks    ? qsTr("No tracks for \"%1\"").arg(root.query)
                             : root.activeTab === root.kAlbums    ? qsTr("No albums for \"%1\"").arg(root.query)
                             : root.activeTab === root.kArtists   ? qsTr("No artists for \"%1\"").arg(root.query)
                             : root.activeTab === root.kPlaylists ? qsTr("No playlists for \"%1\"").arg(root.query)
                             : root.activeTab === root.kMixes     ? qsTr("No mixes for \"%1\"").arg(root.query)
                             : qsTr("No results for \"%1\"").arg(root.query))
                            : qsTr("No results for \"%1\"").arg(root.query)
                        color: Theme.textSec
                        font.pixelSize: 15
                    }
                }

                // The five sections in the query's order: the Loaders stay put,
                // what they load changes. A Loader in a layout overwrites its
                // item's height, so each section publishes an implicitHeight.
                Repeater {
                    model: 5
                    Loader {
                        required property int index
                        readonly property int kind: root.sectionOrder[index]
                        Layout.fillWidth: true
                        sourceComponent: kind === root.kTracks ? tracksSectionC
                                                               : tileSectionC
                    }
                }

                // Where a page that is still arriving, and the end of a kind,
                // are said. Only on a type tab: the All tab is an overview and
                // does not page (see _maybeLoadMore).
                Item {
                    objectName: "searchPagingStrip"
                    Layout.fillWidth: true
                    height: visible ? 56 : 0
                    // "End of results" under three albums would be noise, so
                    // the end is only announced for a kind that paged.
                    visible: root.activeTab !== 0
                             && (root.loadingMore
                                 || (!root._more[root.activeTab]
                                     && root.tabHits >= root.pageSize))
                    Text {
                        objectName: "searchPagingLabel"
                        anchors.centerIn: parent
                        text: root.loadingMore ? qsTr("Loading more…")
                                               : qsTr("End of results")
                        color: Theme.textDim
                        font.pixelSize: 13
                    }
                }

                Item { height: 32 }
            }
        }
    }

    // The bottom of the results, watched. Outside the ScrollView, which takes
    // exactly one content item. A scroll is checked on the spot. A height
    // change waits for bottomSettle: appended rows arrive over several passes.
    Connections {
        target: resultsScroll.contentItem
        function onContentYChanged()      { root._maybeLoadMore() }
        function onContentHeightChanged() { bottomSettle.restart() }
    }

    Timer {
        id: bottomSettle
        interval: 60
        onTriggered: root._maybeLoadMore()
    }

    // ── the sections ────────────────────────────────────────────────────

    // Tracks: a vertical list, and the only section with a row cap.
    Component {
        id: tracksSectionC
        Item {
            id: tracksSec
            visible: (root.activeTab === 0 || root.activeTab === root.kTracks)
                     && root.tracks.length > 0
            implicitHeight: visible ? tracksCol.height : 0

            Column {
                id: tracksCol
                width: parent.width

                Item { width: 1; height: 16 }
                Text {
                    x: 24
                    text: root.sectionTitle(root.kTracks)
                    color: Theme.textPrimary; font.pixelSize: 18; font.bold: true
                }
                Item { width: 1; height: 8 }

                Repeater {
                    // Nothing is built for a section nobody is looking at: a
                    // type tab other than Tracks would otherwise still carry
                    // every TrackRow of the result set, invisibly.
                    model: !tracksSec.visible ? 0
                           : root.activeTab === 0
                             ? Math.min(root.tracks.length, root.allTabTracksCap)
                             : root.tracks.length
                    TrackRow {
                        required property int index
                        x: 16
                        width: tracksCol.width - 32
                        trackNum:       index + 1
                        title:          root.tracks[index].title
                        artists:        root.tracks[index].artists
                        albumTitle:     root.tracks[index].albumTitle
                        durationStr:    root.tracks[index].durationStr
                        coverUrl:       root.tracks[index].coverUrl80
                        isPlaying:      player.currentTrack.id === root.tracks[index].id && player.playing
                        trackData:      root.tracks[index]
                        showPopularity: true
                        // Declares "search" as the source so the player bar
                        // stops naming the previous one. markPlayed() drops it,
                        // so nothing is recorded as played.
                        onPlayRequested: {
                            player.setPlaybackSource("search", root.query, root.query)
                            player.playTracks(root.tracks, index)
                        }
                    }
                }
                Item { width: 1; height: 16 }
            }
        }
    }

    // Albums, artists, playlists and mixes: one tile section, told its kind by
    // the Loader holding it. A horizontal row on the All tab, and on the kind's
    // own tab a grid that grows downwards, since paging needs a bottom.
    Component {
        id: tileSectionC
        Item {
            id: tileSec
            readonly property int kind: parent ? parent.kind : 0
            readonly property var  tiles: root.tilesFor(kind)
            readonly property bool asGrid: root.activeTab === kind
            visible: (root.activeTab === 0 || root.activeTab === kind)
                     && tiles.length > 0
            implicitHeight: !visible ? 0 : (asGrid ? gridCol.height : rowHolder.height)

            // The All tab's summary row.
            Item {
                id: rowHolder
                width: parent.width
                height: visible ? section.height : 0
                visible: !tileSec.asGrid && tileSec.visible
                HorizontalSection {
                    id: section
                    width: parent.width
                    title: root.sectionTitle(tileSec.kind)
                    showViewAll: false
                    items: tileSec.tiles
                    mediaType: root.mediaTypeOf(tileSec.kind)
                    onItemClicked:     (i, item) => root.openTile(tileSec.kind, item)
                    onItemPlayClicked: (i, item) => root.playTile(tileSec.kind, item)
                }
            }

            // The kind's own tab: a wrapping grid.
            Column {
                id: gridCol
                width: parent.width
                visible: tileSec.asGrid && tileSec.visible

                Item { width: 1; height: 16 }
                Text {
                    x: 24
                    text: root.sectionTitle(tileSec.kind)
                    color: Theme.textPrimary; font.pixelSize: 18; font.bold: true
                }
                Item { width: 1; height: 12 }

                Flow {
                    x: 24
                    width: Math.max(0, gridCol.width - 48)
                    spacing: 16
                    Repeater {
                        model: tileSec.asGrid ? tileSec.tiles.length : 0
                        MediaCard {
                            required property int index
                            readonly property var tile: tileSec.tiles[index]
                            coverUrl:  tile ? (tile.coverUrl || "") : ""
                            title:     tile ? (tile.title    || "") : ""
                            subtitle:  tile ? (tile.subtitle || "") : ""
                            mediaType: root.mediaTypeOf(tileSec.kind)
                            itemId:    tile ? ("" + (tile.id || "")) : ""
                            cardSize:  160
                            onClicked:     root.openTile(tileSec.kind, tile)
                            onPlayClicked: root.playTile(tileSec.kind, tile)
                        }
                    }
                }
                Item { width: 1; height: 16 }
            }
        }
    }

    Timer {
        id: searchDebounce
        interval: 400
        onTriggered: {
            if (root.query.length >= 2) doSearch(root.query)
        }
    }

    // ── what each kind is, in one place ─────────────────────────────────

    function rowsOf(kind) {
        switch (kind) {
        case kTracks:    return tracks
        case kAlbums:    return albums
        case kArtists:   return artists
        case kPlaylists: return playlists
        case kMixes:     return mixes
        }
        return []
    }

    function _setRows(kind, rows) {
        switch (kind) {
        case kTracks:    tracks    = rows; return
        case kAlbums:    albums    = rows; return
        case kArtists:   artists   = rows; return
        case kPlaylists: playlists = rows; return
        case kMixes:     mixes     = rows; return
        }
    }

    function _rowsIn(results, kind) {
        switch (kind) {
        case kTracks:    return results.tracks    || []
        case kAlbums:    return results.albums    || []
        case kArtists:   return results.artists   || []
        case kPlaylists: return results.playlists || []
        case kMixes:     return results.mixes     || []
        }
        return []
    }

    function _totalIn(results, kind) {
        switch (kind) {
        case kTracks:    return results.totalTracks    || 0
        case kAlbums:    return results.totalAlbums    || 0
        case kArtists:   return results.totalArtists   || 0
        case kPlaylists: return results.totalPlaylists || 0
        case kMixes:     return results.totalMixes     || 0
        }
        return 0
    }

    // What identifies a row of this kind, for duplicate suppression. Playlists
    // are keyed by uuid, everything else by id; a mix's id is a string.
    function idOf(kind, row) {
        if (!row) return ""
        return kind === kPlaylists ? ("" + (row.uuid || "")) : ("" + (row.id || ""))
    }

    // The name a hit of this kind is scored on. Titles and names only, never a
    // track's artist, the same choice LibraryIndex::search makes.
    function nameOf(kind, row) {
        if (!row) return ""
        return kind === kArtists ? (row.name || "") : (row.title || "")
    }

    function sectionTitle(kind) {
        switch (kind) {
        case kTracks:    return qsTr("Tracks")
        case kAlbums:    return qsTr("Albums")
        case kArtists:   return qsTr("Artists")
        case kPlaylists: return qsTr("Playlists")
        case kMixes:     return qsTr("Mixes")
        }
        return ""
    }

    function mediaTypeOf(kind) {
        switch (kind) {
        case kAlbums:    return "album"
        case kArtists:   return "artist"
        case kPlaylists: return "playlist"
        case kMixes:     return "mix"
        }
        return "album"
    }

    // The tile shape HorizontalSection and MediaCard both read.
    function tilesFor(kind) {
        if (kind === kAlbums)
            return albums.map(function (a) {
                return { id: a.id, title: a.title, subtitle: a.artists,
                         coverUrl: a.coverUrl }
            })
        if (kind === kArtists)
            return artists.map(function (a) {
                return { id: a.id, title: a.name, subtitle: qsTr("Artist"),
                         coverUrl: a.coverUrl || "" }
            })
        if (kind === kPlaylists)
            return playlists.map(function (p) {
                return { id: p.uuid, title: p.title,
                         subtitle: qsTr("%n track(s)", "", p.numTracks),
                         coverUrl: p.coverUrl || "", playlistType: p.type || "" }
            })
        if (kind === kMixes)
            return mixes.map(function (m) {
                return { id: m.id, title: m.title, subtitle: m.subtitle || "",
                         coverUrl: m.coverUrl || "" }
            })
        return []
    }

    function openTile(kind, item) {
        if (!item) return
        if (kind === kAlbums)    { navigateTo("album",  { albumId: item.id }); return }
        if (kind === kArtists)   { navigateTo("artist", { artistId: item.id }); return }
        if (kind === kPlaylists) {
            navigateTo("playlist", { playlistUuid: item.id, playlistTitle: item.title,
                                     coverUrl: item.coverUrl,
                                     playlistType: item.playlistType || "" })
            return
        }
        if (kind === kMixes)
            navigateTo("mix", { mixId: item.id, title: item.title,
                                subtitle: item.subtitle, coverUrl: item.coverUrl,
                                mixType: item.mixType || "" })
    }

    // Declaring the source is what records the play. Inside the callback and
    // after the guard, so a failed or empty fetch records nothing. An artist
    // tile has no entry: no page in the app offers playing an artist.
    function playTile(kind, item) {
        if (!item) return
        if (kind === kAlbums) {
            bridge.fetchAlbumTracks(item.id, function (tracks, err) {
                if (err || tracks.length === 0) return
                player.setPlaybackSource("album", "" + item.id, item.title || "")
                player.playTracks(tracks, 0)
            })
            return
        }
        if (kind === kPlaylists) {
            bridge.fetchPlaylistTracks(item.id, function (tracks, err) {
                if (err || tracks.length === 0) return
                bridge.markPlaylistPlayed(item.id)
                player.setPlaybackSource("playlist", "" + item.id, item.title || "")
                player.playTracks(tracks, 0)
            })
            return
        }
        if (kind === kMixes) {
            bridge.fetchMixTracks(item.id, function (tracks, err) {
                if (err || tracks.length === 0) return
                player.setPlaybackSource("mix", "" + item.id, item.title || "")
                player.playTracks(tracks, 0)
            })
        }
    }

    // ── folding and scoring ─────────────────────────────────────────────

    // Case- and accent-insensitive, as LibraryIndex's fold() is: decompose,
    // drop combining marks, lower-case, spell the sharp s out. normalize() is
    // guarded for Qt 6.4, where without it the accents survive.
    function fold(s) {
        if (typeof s !== "string" || s.length === 0) return ""
        var d = (typeof s.normalize === "function") ? s.normalize("NFD") : s
        var out = ""
        for (var i = 0; i < d.length; ++i) {
            var c = d.charCodeAt(i)
            // The combining blocks NFD produces for Latin, Greek and Cyrillic.
            // LibraryIndex drops the Mark_* categories by name; QML cannot.
            if ((c >= 0x0300 && c <= 0x036f) || (c >= 0x1ab0 && c <= 0x1aff)
                || (c >= 0x1dc0 && c <= 0x1dff) || (c >= 0x20d0 && c <= 0x20f0)
                || (c >= 0xfe20 && c <= 0xfe2f)) continue
            out += d.charAt(i)
        }
        return out.toLowerCase().replace(/ß/g, "ss")
    }

    // QChar::isLetterOrNumber, as far as JS can tell: a digit, or a character
    // that has two cases. A caseless script reads as a word boundary, which can
    // promote a mid-word hit and never demotes a real one.
    function _isWordChar(c) {
        if (!c || c.length === 0) return false
        if (c >= "0" && c <= "9") return true
        return c.toLowerCase() !== c.toUpperCase()
    }

    // Where in the name the query landed. Both arguments are already folded.
    function matchScore(haystack, needle) {
        if (needle.length === 0 || haystack.length === 0) return 0
        var at = haystack.indexOf(needle)
        if (at < 0) return 0
        if (at === 0)
            return haystack.length === needle.length ? tierExact : tierPrefix
        return _isWordChar(haystack.charAt(at - 1)) ? tierMidWord : tierWordStart
    }

    // How much of the name the query accounts for. A short name matched in full
    // is a far stronger signal than a long one that happens to contain the same
    // letters. Integer arithmetic, so two names of the same length tie exactly.
    function coverageBonus(needleLen, nameLen) {
        if (nameLen <= 0) return 0
        return Math.floor(coverageMax * needleLen / nameLen)
    }

    // The best score any hit of this kind gets. `rows` is in the order the
    // server returned it, and a hit pays one point per row it sits below the
    // top so that the same match at index 0 beats it at index 7.
    function scoreKind(kind, rows, needle) {
        var best = 0
        for (var i = 0; i < rows.length; ++i) {
            var name = fold(nameOf(kind, rows[i]))
            var where = matchScore(name, needle)
            if (where === 0) continue
            var s = where + coverageBonus(needle.length, name.length)
                          - Math.min(i, indexPenaltyMax)
            if (s > best) best = s
        }
        return best
    }

    // The order the five sections go in for this query and this reply. The
    // best-scoring kind leads only if it is a full tier clear of the runner-up;
    // otherwise the default order stands.
    function orderFor(q, results) {
        var def = [kTracks, kAlbums, kArtists, kPlaylists, kMixes]
        var needle = fold(("" + q).trim())
        if (needle.length === 0) return def

        var best = -1, bestScore = -1, runnerUp = -1
        for (var i = 0; i < def.length; ++i) {
            var s = scoreKind(def[i], _rowsIn(results, def[i]), needle)
            if (s > bestScore) { runnerUp = bestScore; bestScore = s; best = def[i] }
            else if (s > runnerUp) { runnerUp = s }
        }
        if (bestScore <= 0) return def
        if (bestScore - runnerUp < leadMargin) return def

        var out = [best]
        for (var j = 0; j < def.length; ++j)
            if (def[j] !== best) out.push(def[j])
        return out
    }

    // ── running a search ────────────────────────────────────────────────

    function doSearch(q) {
        loading = true
        loadingMore = false
        var gen = ++root._searchGen
        bridge.search(q, function (results, err) {
            // Replies can arrive out of order, so only the most recently
            // dispatched request may update the UI. The page fetches below read
            // the same counter without bumping it.
            if (gen !== root._searchGen) return
            loading = false
            // Recording the replied query is what lets the two strips speak.
            root.repliedFor = q
            if (err.length > 0) {
                root.errorText = err
                // The arrays still hold the last successful query's hits, which
                // this query cannot claim.
                root._resetResults()
                return
            }
            root.errorText = ""
            root._resetResults()
            var sent = [0, 0, 0, 0, 0, 0]
            var total = [0, 0, 0, 0, 0, 0]
            var more = [false, false, false, false, false, false]
            for (var k = root.kTracks; k <= root.kMixes; ++k) {
                var page = root._rowsIn(results, k)
                root._setRows(k, root._fresh(k, page))
                sent[k]  = page.length
                total[k] = root._totalIn(results, k)
                more[k]  = root._hasMore(page.length, sent[k], total[k])
            }
            root._sent = sent; root._total = total; root._more = more
            // Ordered from the reply, once, so the sections cannot move under
            // an append or a keystroke.
            root.sectionOrder = root.orderFor(q, results)

            // Remembered only once it has found something: the page searches as
            // the user types, and prefixes and typos do not belong here.
            if (root.totalHits > 0) bridge.addRecentSearch(q)

            // A first page that does not fill the window is already showing
            // its last row. Once the column has settled, and not before.
            bottomSettle.restart()
        }, pageSize, 0)
    }

    // Whether a kind that has handed over `sent` of `total` rows, the last page
    // `pageLen` long, has anything left. A short page is the end whatever the
    // total says: a server that omits totalNumberOfItems reports 0.
    function _hasMore(pageLen, sent, total) {
        if (pageLen < pageSize) return false
        if (total > 0 && sent >= total) return false
        return true
    }

    // The first page of a kind: the rows, with the id of each remembered so a
    // later page repeating one is dropped.
    function _fresh(kind, page) {
        var out = []
        for (var i = 0; i < page.length; ++i) {
            var id = idOf(kind, page[i])
            var key = kind + ":" + id
            if (id.length > 0 && _seen[key]) continue
            if (id.length > 0) _seen[key] = true
            out.push(page[i])
        }
        return out
    }

    // One more page of `kind`, appended.
    function loadMore(kind) {
        if (kind < kTracks || kind > kMixes) return
        if (loading || loadingMore || !_more[kind]) return
        if (query.length < 2) return

        loadingMore = true
        var gen = root._searchGen
        var q = root.query
        // Where the page sits now. While the column's implicit height lags
        // behind its new children, contentY is clamped to the old maximum and
        // the view jumps up. Put back once the layout has settled.
        var flick = resultsScroll.contentItem
        var keepY = flick ? flick.contentY : 0

        bridge.search(q, function (results, err) {
            if (gen !== root._searchGen) return   // the query moved on
            root.loadingMore = false
            if (err.length > 0) {
                // The rows already on screen are still a true answer to this
                // query, so they stay; what stops is the asking, which would
                // otherwise retry on every pixel of scroll.
                root.errorText = err
                root._setMore(kind, false)
                return
            }
            var page = root._rowsIn(results, kind)
            var kept = root._fresh(kind, page)
            if (kept.length > 0)
                root._setRows(kind, root.rowsOf(kind).concat(kept))

            var sent = root._sent.slice()
            sent[kind] = sent[kind] + page.length
            root._sent = sent

            var total = root._total.slice()
            total[kind] = root._totalIn(results, kind)
            root._total = total

            root._setMore(kind, root._hasMore(page.length, sent[kind], total[kind]))
            root._restoreScroll(keepY)
        }, pageSize, _sent[kind])
    }

    function _setMore(kind, v) {
        var m = root._more.slice()
        m[kind] = v
        root._more = m
    }

    function _restoreScroll(y) {
        Qt.callLater(function () {
            var flick = resultsScroll.contentItem
            if (!flick) return
            var maxY = Math.max(0, flick.contentHeight - flick.height)
            var want = Math.min(y, maxY)
            if (Math.abs(flick.contentY - want) > 0.5) flick.contentY = want
        })
    }

    // The bottom has been reached, maybe. Only on a type tab: the All tab is a
    // summary of five kinds at once and there is no one kind for its bottom to
    // be the bottom of.
    function _maybeLoadMore() {
        if (activeTab === 0) return
        if (loading || loadingMore) return
        if (!_more[activeTab]) return
        if (!resultsScroll.visible) return
        var flick = resultsScroll.contentItem
        if (!flick || flick.height <= 0) return
        // A list that does not fill the viewport is already showing its last
        // row, so its bottom is reached by definition.
        if (flick.contentHeight <= flick.height) { loadMore(activeTab); return }
        if (flick.contentY + flick.height >= flick.contentHeight - loadMoreMargin)
            loadMore(activeTab)
    }

    function _resetResults() {
        tracks = []; albums = []; artists = []; playlists = []; mixes = []
        _seen = ({})
        _sent  = [0, 0, 0, 0, 0, 0]
        _total = [0, 0, 0, 0, 0, 0]
        _more  = [false, false, false, false, false, false]
    }

    function clearResults() {
        _resetResults()
        sectionOrder = [kTracks, kAlbums, kArtists, kPlaylists, kMixes]
        _searchGen++; loading = false; loadingMore = false
        // Back below the threshold: there is no query to have an answer about.
        repliedFor = ""; errorText = ""
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
