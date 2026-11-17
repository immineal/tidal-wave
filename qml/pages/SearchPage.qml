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
    // The server's own best match, {kind, item}, or null. Set from the first
    // page only and cleared with the rest.
    property var    topHit:    null
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
    // Whether that failure came with Tidal out of reach. Taken when the reply
    // lands: the bridge marks itself offline before it answers.
    property bool   errorOffline: false
    // A later page that failed: which kind, and whether Tidal was out of
    // reach. Said at the foot of that kind's list, where the listener is.
    property int    moreFailedKind: -1
    property bool   moreFailedOffline: false

    readonly property bool replied: query.length >= 2 && repliedFor === query

    // A new query typed over an answered one keeps that answer up until it
    // runs. Only an emptied field goes back to the recent searches.
    readonly property bool showsResults:
        query.length >= 2 || (query.length > 0 && repliedFor.length > 0)

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
        duration: Theme.dur(Theme.motionMedium)
        easing.type: Easing.OutCubic
    }
    // Each chip starts at its top: the column below is a different list.
    onActiveTabChanged: {
        resultsEntry.restart()
        if (resultsScroll.contentItem) resultsScroll.contentItem.contentY = 0
        root._checkBottomAfterLayout()
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

        Item { height: Theme.space4 }

        SearchBar {
            id: searchBar
            objectName: "searchPageBar"
            focus: true
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space6
            Layout.rightMargin: Theme.space6
            placeholder: qsTr("Search tracks, albums, artists, playlists…")
            onTextEdited: (text) => {
                // A link pasted in whole opens its page. Typed a letter at a
                // time, it is a search like any other.
                var before = root.query
                if (text.length > before.length + 1 && app.isTidalLink(text)) {
                    searchBar.text = ""
                    root.query = ""
                    clearResults()
                    app.openLink(text)
                    return
                }
                root.query = text
                if (text.length === 0) { clearResults(); return }
                if (text.length < 2) { root.holdResults(); return }
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

        Item { height: Theme.space3 }

        // ── the tab bar ──────────────────────────────────────────────────
        TabStrip {
            id: searchTabs
            namePrefix: "search"
            visible: root.showsResults
            // A tab changed while the row is off screen must not start a
            // travel that plays when the row comes back.
            animate: visible
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space6
            Layout.rightMargin: Theme.space6
            model: [qsTr("All"), qsTr("Tracks"), qsTr("Albums"),
                    qsTr("Artists"), qsTr("Playlists"), qsTr("Mixes")]
            currentIndex: root.activeTab
            onActivated: (index) => { root.activeTab = index }
        }

        Item { height: Theme.space2 }

        // Empty state, outside the ScrollView: the last few queries, hung
        // under the field and lined up with it, when there are any; a centred
        // first-run note otherwise.
        Item {
            objectName: "searchEmptyState"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.showsResults

            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.space4
                visible: root.recents.length === 0
                VectorIcon {
                    Layout.alignment: Qt.AlignHCenter
                    name: "search"
                    color: Theme.textDim
                    width: 48
                    height: 48
                }
                Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Search Tidal"); color: Theme.textPrimary; font.pixelSize: Theme.fontDisplay; font.bold: true }
                Text {
                    objectName: "searchFirstRunHint"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.maximumWidth: Math.max(0, root.width - 2 * Theme.space12)
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Results appear as you type. Searches that found something are kept here.")
                    color: Theme.textSec
                    font.pixelSize: Theme.fontBody
                }
            }

            ColumnLayout {
                objectName: "searchRecents"
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.leftMargin: Theme.space6
                width: Math.min(560, parent.width - 2 * Theme.space6)
                spacing: Theme.space1
                visible: root.recents.length > 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: Theme.space1
                    Text {
                        text: qsTr("Recent searches")
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSection
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
                        Accessible.role: Accessible.Button
                        Accessible.name: clearAllText.text
                        Accessible.onPressAction: bridge.clearRecentSearches()
                        Text {
                            id: clearAllText
                            anchors.fill: parent
                            text: qsTr("Clear all")
                            color: clearAll.activeFocus || clearAllMA.containsMouse
                                   ? Theme.accentText : Theme.textSec
                            font.pixelSize: Theme.fontMeta
                            font.underline: clearAll.activeFocus
                        }
                        MouseArea {
                            id: clearAllMA
                            anchors.fill: parent
                            anchors.margins: -Theme.space2
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
                        radius: Theme.radiusFull
                        color: rowMA.containsMouse ? Theme.hoverFill : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }

                        MouseArea {
                            id: rowMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.runRecent(recentRow.modelData)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.space3
                            anchors.rightMargin: Theme.space2
                            spacing: Theme.space3
                            VectorIcon {
                                name: "clock"
                                color: Theme.textDim
                                width: 14; height: 14
                            }
                            Text {
                                Layout.fillWidth: true
                                text: recentRow.modelData
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontBody
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
                                Accessible.role: Accessible.Button
                                Accessible.name: qsTr("Remove “%1” from recent searches").arg(recentRow.modelData)
                                Accessible.onPressAction: bridge.removeRecentSearch(recentRow.modelData)
                                Rectangle {
                                    anchors.fill: parent; anchors.margins: -Theme.space1
                                    radius: Theme.radiusMedium; color: "transparent"
                                    border.width: dropRecent.activeFocus ? 2 : 0
                                    border.color: Theme.accent
                                }
                                VectorIcon {
                                    anchors.fill: parent
                                    name: "x"
                                    color: dropRecent.activeFocus || dropMA.containsMouse
                                           ? Theme.accentText : Theme.textDim
                                }
                                MouseArea {
                                    id: dropMA
                                    anchors.fill: parent
                                    anchors.margins: -Theme.space1
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
            rightPadding: Theme.space4
            contentWidth: availableWidth
            // Stated, because a ScrollView on Qt 6.5 works its content height
            // out once and does not follow the column as rows arrive.
            contentHeight: resultsColumn.implicitHeight
            visible: root.showsResults
            opacity: root.resultsIn

            ColumnLayout {
                id: resultsColumn
                objectName: "searchResults"
                width: parent.width
                spacing: 0

                // A failed search says what it means, as Home's mixes row does;
                // Qt's own sentence (host, socket, HTTP reason) goes to the log.
                Item {
                    objectName: "searchErrorStrip"
                    Layout.fillWidth: true
                    // A Layout reads the preferred height; the offline copy wraps.
                    Layout.preferredHeight: Math.max(80, errorColumn.implicitHeight + 32)
                    visible: root.replied && root.errorText.length > 0
                    Column {
                        id: errorColumn
                        anchors.centerIn: parent
                        width: parent.width - 48
                        spacing: Theme.space3
                        Text {
                            id: errorLabel
                            objectName: "searchErrorLabel"
                            width: parent.width
                            text: root.errorOffline
                                  ? qsTr("Search needs Tidal, which cannot be reached right now. Check the connection; the notice above says when it is back.")
                                  : qsTr("Tidal could not answer this search.")
                            color: Theme.textSec
                            font.pixelSize: Theme.fontBody
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                        PillButton {
                            objectName: "searchRetry"
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: !root.errorOffline
                            text: qsTr("Try again")
                            accent: false
                            height: 32
                            onClicked: root.doSearch(root.repliedFor)
                        }
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
                        font.pixelSize: Theme.fontBody
                    }
                }

                // The server's own best match, over the five sections on the
                // All tab. A track plays on a click, as a track row does;
                // everything else opens its page.
                Column {
                    id: topHitBlock
                    Layout.fillWidth: true
                    visible: root.activeTab === 0 && root.replied && !!root.topHit
                             && root.errorText.length === 0
                    readonly property var  hit:  root.topHit ? root.topHit.item : null
                    readonly property string kind: root.topHit ? root.topHit.kind : ""

                    Item { width: 1; height: Theme.space4 }
                    Text {
                        x: Theme.space6
                        text: qsTr("Top result", "heading over the one best match of a search")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true
                    }
                    Item { width: 1; height: Theme.space3 }

                    Rectangle {
                        id: topHitCard
                        objectName: "searchTopHit"
                        x: Theme.space6
                        width: Math.min(520, parent.width - 2 * Theme.space6)
                        height: topHitRow.implicitHeight + 2 * Theme.space4
                        radius: Theme.radiusLarge
                        color: topHitHov.hovered || activeFocus ? Theme.hoverFill : Theme.surface
                        border.width: activeFocus ? 2 : 0
                        border.color: Theme.accent
                        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }

                        activeFocusOnTab: visible
                        Keys.onReturnPressed: root.openTopHit()
                        Keys.onSpacePressed:  root.openTopHit()
                        Accessible.role: Accessible.Button
                        Accessible.name: root.topHitTitle() + ", " + root.topHitKindLabel()
                        Accessible.onPressAction: root.openTopHit()

                        HoverHandler { id: topHitHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.openTopHit() }

                        RowLayout {
                            id: topHitRow
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.space4
                            anchors.rightMargin: Theme.space4
                            spacing: Theme.space4

                            CoverArt {
                                objectName: "searchTopHitCover"
                                Layout.preferredWidth: 96
                                Layout.preferredHeight: 96
                                // An artist is a face, round as on its card.
                                radius: topHitBlock.kind === "artist" ? width / 2 : Theme.radiusSmall
                                source: topHitBlock.hit ? (topHitBlock.hit.coverUrl || "") : ""
                                glyph: topHitBlock.kind === "artist" ? "artist"
                                     : topHitBlock.kind === "playlist" ? "playlist"
                                     : topHitBlock.kind === "album" ? "album" : "track"
                                decodeSize: Qt.size(192, 192)
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space1
                                Text {
                                    Layout.fillWidth: true
                                    text: root.topHitTitle()
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontTitle
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.topHitMeta()
                                    color: Theme.textSec
                                    font.pixelSize: Theme.fontMeta
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                    Item { width: 1; height: Theme.space6 }
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
                    // "End of results" under three albums would be noise, so
                    // the end is only announced for a kind that paged.
                    readonly property bool failed: root.moreFailedKind === root.activeTab
                                                   && !root.loadingMore
                    height: visible ? (failed ? moreFailColumn.implicitHeight + 32 : 56) : 0
                    visible: root.activeTab !== 0
                             && (root.loadingMore || failed
                                 || (!root._more[root.activeTab]
                                     && root.tabHits >= root.pageSize))
                    Text {
                        objectName: "searchPagingLabel"
                        anchors.centerIn: parent
                        visible: !parent.failed
                        text: root.loadingMore ? qsTr("Loading more…")
                                               : qsTr("End of results")
                        color: Theme.textDim
                        font.pixelSize: Theme.fontMeta
                    }
                    Column {
                        id: moreFailColumn
                        anchors.centerIn: parent
                        width: parent.width - 48
                        spacing: Theme.space3
                        visible: parent.failed
                        Text {
                            width: parent.width
                            text: root.moreFailedOffline
                                  ? qsTr("Tidal cannot be reached, so no more results could be loaded.")
                                  : qsTr("Tidal could not load more results.")
                            color: Theme.textSec
                            font.pixelSize: Theme.fontBody
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                        PillButton {
                            objectName: "searchMoreRetry"
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: qsTr("Try again")
                            accent: false
                            height: 32
                            onClicked: {
                                var kind = root.moreFailedKind
                                root.moreFailedKind = -1
                                root._setMore(kind, true)
                                root.loadMore(kind)
                            }
                        }
                    }
                }

                Item { height: Theme.space8 }
            }
        }
    }

    // The bottom of the results, watched. Outside the ScrollView, which takes
    // exactly one content item. A taller viewport can pass the end of a list
    // that filled it, and then there is nothing to scroll.
    Connections {
        target: resultsScroll.contentItem
        function onContentYChanged()      { root._checkBottomAfterLayout() }
        function onContentHeightChanged() { root._checkBottomAfterLayout() }
        function onHeightChanged()        { root._checkBottomAfterLayout() }
    }

    // Rows are positioned when the window polishes its items for a frame, and
    // afterAnimating follows that pass. The bottom is judged there and nowhere
    // else, so the heights it reads belong to the rows on the page.
    property bool _bottomOwed: false
    function _checkBottomAfterLayout() {
        _bottomOwed = true
        // Nothing else may have asked for a frame.
        if (Window.window) Window.window.update()
    }
    Connections {
        target: root.Window.window
        enabled: root._bottomOwed
        function onAfterAnimating() {
            root._bottomOwed = false
            root._maybeLoadMore()
        }
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

                Item { width: 1; height: Theme.space4 }
                Text {
                    x: 24
                    text: root.sectionTitle(root.kTracks)
                    color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true
                }
                Item { width: 1; height: Theme.space2 }

                // The tracks are one tab stop; see TrackRow.rowGroup.
                QtObject { id: trackGroup; property int current: 0 }
                Repeater {
                    onModelChanged: trackGroup.current = 0
                    // Nothing is built for a section nobody is looking at: a
                    // type tab other than Tracks would otherwise still carry
                    // every TrackRow of the result set, invisibly.
                    model: !tracksSec.visible ? 0
                           : root.activeTab === 0
                             ? Math.min(root.tracks.length, root.allTabTracksCap)
                             : root.tracks.length
                    TrackRow {
                        required property int index
                        rowGroup: trackGroup
                        rowIndex: index
                        x: 16
                        width: tracksCol.width - 32
                        trackNum:       index + 1
                        title:          root.tracks[index].title
                        artists:        root.tracks[index].artists
                        albumTitle:     root.tracks[index].albumTitle
                        durationStr:    root.tracks[index].durationStr
                        coverUrl:       root.tracks[index].coverUrl80
                        trackData:      root.tracks[index]
                        // Declares "search" as the source so the player bar
                        // stops naming the previous one. markPlayed() drops it,
                        // so nothing is recorded as played.
                        onPlayRequested: {
                            player.setPlaybackSource("search", root.query, root.query)
                            player.playTracks(root.tracks, index)
                        }
                    }
                }
                Item { width: 1; height: Theme.space4 }
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

                Item { width: 1; height: Theme.space4 }
                Text {
                    x: 24
                    text: root.sectionTitle(tileSec.kind)
                    color: Theme.textPrimary; font.pixelSize: Theme.fontSection; font.bold: true
                }
                Item { width: 1; height: Theme.space3 }

                Flow {
                    x: 24
                    width: Math.max(0, gridCol.width - 48)
                    spacing: Theme.space4
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
                Item { width: 1; height: Theme.space4 }
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
                         subtitle: qsTr("%Ln track(s)", "", p.numTracks),
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

    // ── the top result ──────────────────────────────────────────────────

    function topHitTitle() {
        var h = root.topHit ? root.topHit.item : null
        if (!h) return ""
        return root.topHit.kind === "artist" ? (h.name || "") : (h.title || "")
    }

    function topHitKindLabel() {
        switch (root.topHit ? root.topHit.kind : "") {
        case "artist":   return qsTr("Artist")
        case "album":    return qsTr("Album", "the kind of a search's top result")
        case "track":    return qsTr("Track", "the kind of a search's top result")
        case "playlist": return qsTr("Playlist", "the kind of a search's top result")
        }
        return ""
    }

    // The kind, then who made it where that is known.
    function topHitMeta() {
        var h = root.topHit ? root.topHit.item : null
        var parts = [root.topHitKindLabel()]
        if (h && h.artists && root.topHit.kind !== "artist") parts.push(h.artists)
        return parts.filter(function (p) { return p && p.length > 0 }).join(" · ")
    }

    function openTopHit() {
        if (!root.topHit || !root.topHit.item) return
        var h = root.topHit.item
        switch (root.topHit.kind) {
        case "track":
            // From its row where the list holds it, as a click on that row
            // would; on its own otherwise.
            player.setPlaybackSource("search", root.query, root.query)
            for (var i = 0; i < root.tracks.length; ++i)
                if (root.tracks[i].id === h.id) { player.playTracks(root.tracks, i); return }
            player.playTracks([h], 0)
            return
        case "album":    openTile(kAlbums, { id: h.id }); return
        case "artist":   openTile(kArtists, { id: h.id }); return
        case "playlist":
            openTile(kPlaylists, { id: h.uuid, title: h.title, coverUrl: h.coverUrl || "",
                                   playlistType: h.type || "" })
            return
        }
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
                console.warn("Search failed:", err)
                root.errorText = err
                root.errorOffline = bridge.offline === true
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
            root.topHit = (results.topHit && results.topHit.item) ? results.topHit : null

            // Remembered only once it has found something: the page searches as
            // the user types, and prefixes and typos do not belong here.
            if (root.totalHits > 0) bridge.addRecentSearch(q)

            // A first page that does not fill the window is already showing
            // its last row.
            root._checkBottomAfterLayout()
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
        // The query on screen is the answered one, not what is being typed.
        if (repliedFor.length < 2) return

        loadingMore = true
        var gen = root._searchGen
        var q = root.repliedFor
        // Where the page sits now. While the column's implicit height lags
        // behind its new children, contentY is clamped to the old maximum and
        // the view jumps up. Put back once the layout has settled.
        var flick = resultsScroll.contentItem
        var keepY = flick ? flick.contentY : 0

        bridge.search(q, function (results, err) {
            if (gen !== root._searchGen) return   // the query moved on
            root.loadingMore = false
            root.moreFailedKind = -1
            if (err.length > 0) {
                // The rows already on screen are still a true answer to this
                // query, so they stay; what stops is the asking, which would
                // otherwise retry on every pixel of scroll.
                console.warn("Search failed:", err)
                root.moreFailedKind = kind
                root.moreFailedOffline = bridge.offline === true
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
            // The page may have left the bottom where it was.
            root._checkBottomAfterLayout()
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
        moreFailedKind = -1
        tracks = []; albums = []; artists = []; playlists = []; mixes = []
        topHit = null
        _seen = ({})
        _sent  = [0, 0, 0, 0, 0, 0]
        _total = [0, 0, 0, 0, 0, 0]
        _more  = [false, false, false, false, false, false]
    }

    // Too short to search: nothing goes out and nothing still out may land,
    // but the answer on screen stays.
    function holdResults() {
        searchDebounce.stop()
        _searchGen++; loading = false; loadingMore = false
    }

    function clearResults() {
        _resetResults()
        sectionOrder = [kTracks, kAlbums, kArtists, kPlaylists, kMixes]
        _searchGen++; loading = false; loadingMore = false
        // Back below the threshold: there is no query to have an answer about.
        repliedFor = ""; errorText = ""; errorOffline = false
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    // Below the search field, which keeps the keyboard while results load.
    Skeleton { loading: root.loading; kind: "cards"; topInset: searchBar.y + searchBar.height }
}
