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

    // The query the five arrays and `errorText` below describe, and the reason
    // the last reply failed (empty when it did not).
    //
    // A search has three outcomes and the page only had two of them. "I have
    // results" and "I have none" leaves no way to say *not yet*, so the
    // no-results strip - which asked nothing more than whether the arrays
    // were empty - was up for the whole 400ms the debounce was still waiting,
    // on every keystroke, naming a query nothing had been asked about. Empty
    // arrays are the state the page starts in, not an answer.
    //
    // Nothing may be said about a query until a reply for *that* query has
    // landed, which is what `replied` below is.
    property string repliedFor: ""
    property string errorText:  ""

    readonly property bool replied: query.length >= 2 && repliedFor === query

    // Hits of the kind the active tab shows. The strip used to ask whether all
    // the arrays were empty while each section showed itself only when its own
    // array was not, so the Albums tab for a query that matched only tracks hid
    // every section *and* suppressed the strip: a pane with nothing in it at
    // all and no way to tell that from a page still loading.
    readonly property int tabHits:
        activeTab === 0 ? totalHits : rowsOf(activeTab).length

    readonly property int totalHits:
        tracks.length + albums.length + artists.length
        + playlists.length + mixes.length

    // ── paging ──────────────────────────────────────────────────────────
    //
    // The search endpoint takes an offset and this page never sent one, so a
    // search was twenty of each kind and that was the whole catalogue as far
    // as the user was concerned. It pages now: the bottom of a type tab asks
    // for the next twenty of that kind and appends them.
    //
    // Three pieces of state per kind, and they are three because the obvious
    // single counter is wrong in a different way for each:
    //
    //   _sent   how many rows the *server* has handed over for this kind. The
    //           offset of the next request, and not the same as the length of
    //           the array below it, because duplicates are dropped on arrival
    //           (see _fresh) - counting the array would re-ask for the rows
    //           that were dropped and get them again, forever.
    //   _total  what the reply said the kind holds. The bridge used to throw
    //           these away; without them a last page that happens to be full
    //           is indistinguishable from one with more behind it.
    //   _more   whether to ask again. Both of the above can lie - a server
    //           that omits totalNumberOfItems reports 0 - so this is set from
    //           whichever of the two said "that is all": a short page, or a
    //           total that has been reached.
    //
    // Index 0 (the All tab) is never used: see _maybeLoadMore.
    property var _sent:  [0, 0, 0, 0, 0, 0]
    property var _total: [0, 0, 0, 0, 0, 0]
    property var _more:  [false, false, false, false, false, false]
    // "kind:id" for every row already on screen, so a row the server repeats
    // across two pages - which it does whenever the result set shifts under a
    // query between requests - is dropped rather than drawn twice. A plain
    // object and not a property anything binds to: nothing watches it.
    property var _seen: ({})
    property bool loadingMore: false

    readonly property int pageSize: 20
    // How close to the bottom counts as the bottom: about four rows of tracks,
    // so the next page is on its way before the last of them is on screen.
    readonly property int loadMoreMargin: 240

    // ── which section leads ─────────────────────────────────────────────
    //
    // The All tab was always Tracks -> Albums -> Artists -> Playlists, so
    // searching for an artist put the artist third and, in a small window,
    // below the fold. The order follows the query now: the kind whose best hit
    // the query matches most strongly leads, and the rest keep their default
    // order behind it.
    //
    // Recomputed once per *search*, from the reply, and never on an append or
    // a keystroke - the page jumping around under a half-typed word is the one
    // thing this must not do.
    property var sectionOrder: [1, 2, 3, 4, 5]

    readonly property int defaultTracksCap: 5
    // The leading section earns a few more rows than it would in third place.
    // Tracks is the only section with a cap at all - the other four are tile
    // rows that show what they were given - so this is the whole of it.
    readonly property int leadingTracksCap: 8
    readonly property int allTabTracksCap:
        sectionOrder.length > 0 && sectionOrder[0] === kTracks
            ? leadingTracksCap : defaultTracksCap

    // ── the scoring vocabulary ──────────────────────────────────────────
    //
    // The same four tiers, the same coverage ceiling and the same folding as
    // LibraryIndex (src/api/LibraryIndex.cpp, `fold`, `matchScore`,
    // `coverageBonus` and the long note above them), so the catalogue search
    // and the sidebar finder agree about what a strong match is. Restated here
    // rather than shared: the rows being scored are a remote reply that never
    // enters LibraryIndex, and reaching back into C++ to rank five JS arrays
    // would be a round trip through QVariant for no gain. If the tiers ever
    // move, they move in both places.
    //
    // The tiers are 100 apart and the two adjustments below can never reach
    // that, which is what keeps a tier sealed.
    readonly property int tierExact:     400   // the name *is* the query
    readonly property int tierPrefix:    300   // the name starts with it
    readonly property int tierWordStart: 200   // a later word starts with it
    readonly property int tierMidWord:   100   // buried inside a word
    readonly property int coverageMax:    40   // how much of the name the query is
    // How far down its own kind the hit sits. One point a row so that the same
    // score at index 0 beats it at index 7, capped well under the 60 that
    // would let a deep hit fall out of its tier.
    readonly property int indexPenaltyMax: 20
    // And the threshold the user chose: the leader has to be a full tier clear
    // of the runner-up or nothing moves. That is the point of it - it keeps the
    // page steady for half-typed and ambiguous queries, which is the cost that
    // came with reordering instead of a "Top result" card.
    readonly property int leadMargin: 100

    function releaseFocus() {
        searchBar.releaseFocus()
    }

    // Arriving at the page. The router gives the Loader active focus, which is
    // not the same as giving it to the field: the Loader, this page's root and
    // the bar's input all sit in one focus scope, so whichever of them asked
    // last owns it and the field was never the one asking. Nothing typed
    // reached it, and leaving the page (releaseFocus above) left the scope with
    // no focus item at all, so a second visit had nothing to hand focus back
    // to either.
    function takeFocus() {
        searchBar.takeFocus()
    }

    // The results change shape on a tab switch: "All" shows every section and
    // every other tab shows one, so the whole column below is replaced between
    // two frames. It fades in instead.
    //
    // A fade and not a reorder: the sections are Repeaters over JS arrays, so
    // nothing here is a view with a change set to animate, and the content
    // after a switch is different content rather than the same content
    // rearranged.
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
        // The tab just switched to may already be showing its last row - but
        // the column is the *previous* tab's height until it has been laid
        // out again, which is shorter than the viewport often enough to have
        // asked for a second page the user never scrolled to.
        bottomSettle.restart()
    }

    // ── recent searches ─────────────────────────────────────────────────
    //
    // The queries this account has run, newest first, kept by TidalBridge in
    // QSettings beside the recents LibraryIndex already keeps (see the note on
    // TidalBridge::recentSearchesKey for why there and not in a file). Nothing
    // leaves the machine and nothing is logged.
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
            // Enter means "this is the query", so it is remembered whatever the
            // reply turns out to be - including nothing, which is still a thing
            // the user looked for and may want to pick off the list again.
            onSubmitted: (text) => {
                if (text.length < 2) return
                bridge.addRecentSearch(text)
                searchDebounce.stop()
                root.doSearch(text)
            }
        }

        Item { height: 12 }

        // ── the tab bar, and its highlight as one pill that travels ──────
        //
        // The accent fill used to belong to the chip: the one being left faded
        // back to nothing while the one arriving faded up to the accent, so the
        // highlight was briefly nowhere and nothing ever crossed the gap
        // between the two (QA: "the highlighting bar can move up and not just
        // fade out in one place and then fade in in the other place"). There is
        // one pill now and it moves, the same way the sidebar's bar moves
        // between its three rows and Collection's pill between its chips, and
        // on the same 140ms, so the three read as one idea.
        //
        // A host Item around the row rather than Collection's per-chip slices:
        // a Row lays out every visible child it has, so the pill cannot be one
        // of them, but it can be the row's sibling - and then it is one whole
        // pill that crosses the 4px gaps because it is never cut up in the
        // first place. Collection's chips are in a Flow, which left nowhere to
        // put a sibling, which is the only reason it is sliced there.
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
            // between the two chips' *live* boxes, so a layout change - the
            // language changing under the row, a chip's label being retranslated
            // - arrives in the frame it happens instead of being chased for
            // 140ms by a pill that was told where the chip used to be.
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

            // The end it set off from - the destination itself when there is
            // nothing to set off from, which makes the lerp degenerate and
            // markT unobservable. That is the first placement, and it is also a
            // model rebuild.
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

            // `visible` in the condition as well as the gate. The row is only
            // there with a query on it, and the page itself is hidden outright
            // whenever the shell is on another one (Main.qml's searchLoader
            // keeps it alive behind `visible`), so a tab changed while the row
            // is off screen has to be where it belongs the moment the row comes
            // back rather than crossing it on the way in - a travel started
            // behind a hidden row has its whole 140ms still to run. Same guard
            // the sidebar's bar has for fullscreen.
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

            // Behind the chips, which rest on nothing at all, so the pill is
            // what the eye reads as the fill. Behind and not in front because a
            // chip's hover tint is opaque and would sit on top of it; see the
            // chip's colour below for the other half of that.
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
                    // pill is aimed again as the chips arrive as well as when
                    // the tab changes - a language change rebuilds all six.
                    onItemAdded: function (index, item) { tabsHost.retarget(false) }
                    Rectangle {
                        id: searchTab
                        required property string modelData
                        required property int    index
                        height: 30; width: tabLabel.implicitWidth + 24; radius: Theme.radiusChip
                        // Every chip rests on nothing now, including the current
                        // one: what marks it is the pill behind the row.
                        //
                        // The hover tint drops out on any chip the pill is over,
                        // which is what the old `activeTab === index ? accent :
                        // hover` said - the highlight beat the hover - now that
                        // where the highlight is is a box and not an index.
                        // surfaceHov is opaque and the pill is behind the row, so
                        // without this the tint would paint the highlight out from
                        // under the pointer, and the pointer is on the chip that
                        // was just clicked.
                        //
                        // The whole chip and not only the covered part of it: for
                        // the 140ms a travel passes over a chip the pointer happens
                        // to be on, the tint fades out and back rather than being
                        // cut in two by a moving edge. Two rounded slivers chasing
                        // the pill is a worse answer than none.
                        color: tabMA.containsMouse && !searchTab.pillOverlaps
                               ? Theme.surfaceHov : "transparent"
                        // Same as Collection's row, and for the same reason: the
                        // chip is what was clicked, so it must not be the one thing
                        // that snaps while the results below it fade. The hover gets
                        // the fade too, which is what the rest of the app does.
                        Behavior on color { ColorAnimation { duration: Theme.dur(140) } }

                        // Is any part of the pill over this chip? Horizontal only:
                        // the row does not wrap, so every chip is on the one line
                        // the pill travels along.
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
                            // The ink the bare row takes, always. The accent's ink
                            // is the copy below, and which of the two is on screen
                            // at a given pixel is decided by where the pill is
                            // rather than by a clock.
                            color: Theme.textSec
                            // Not drawn at all where the copy covers every pixel of
                            // it, which is the resting state of the current chip.
                            // Two Texts in the same place blend at the glyphs'
                            // antialiased edge, and the ink underneath is the
                            // resting ink on the accent fill - the ~2:1 pairing the
                            // note below calls invisible, which is only *nearly*
                            // invisible, and the settled chip is where the eye lives.
                            visible: !searchTab.labelFullyInked
                            font.pixelSize: 13
                        }

                        // The same label again in the ink the accent needs, clipped
                        // to exactly the part of the pill that is over this chip.
                        //
                        // This is what lets the fill travel at all. The two inks are
                        // luminance-inverted against the two fills on the three
                        // light palettes - dark ink on a bare row becomes white ink
                        // on an accent chip - so a label cannot cross-fade between
                        // them (measured in 354d460: under 2:1 for 57ms of a 140ms
                        // fade, bottoming out at 1.01:1), and it cannot be stepped
                        // either when a hard fill edge is sweeping across it:
                        // whichever ink it steps to, half the glyphs are on the
                        // wrong fill for as long as the edge takes to cross them.
                        // Two copies, each clipped to its own fill, means every
                        // glyph pixel is on the fill its ink was chosen for in every
                        // frame of the travel - better than the single stepped frame
                        // the fade settled for, rather than a trade against it.
                        //
                        // This row needs it harder than Collection's: its resting
                        // fill is the page itself, so the pair inverts further.
                        Item {
                            id: inkWindow
                            objectName: "searchTabInk"
                            // The pill, in this chip's coordinates, clamped to the
                            // chip. Vertically as well, though the row cannot wrap:
                            // the clamp is what makes the window empty rather than
                            // negative when the pill is elsewhere.
                            //
                            // Not `top`/`bottom`: an Item has those as final
                            // members, and a property that shadows one takes the
                            // whole type out of the build with it.
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

        // Empty state — shown outside ScrollView so it centers in the page.
        //
        // The last few queries, when there are any. An illustration saying
        // "Search Tidal" over a field the user is already looking at told them
        // nothing; the one thing worth putting here is what they searched for
        // last, because a search is the kind of thing people repeat. The
        // illustration stays for the case where there is nothing to show yet.
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

                // A failed search used to look exactly like a successful one:
                // the spinner went away, the previous query's results stayed on
                // screen under the new text, and nothing said the request had
                // failed. There is no banner, toast or retry anywhere in this
                // app - LoginPage reports a failed sign-in as one line of
                // Theme.red text and that is the whole precedent - so this is
                // that line.
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

                // No results indicator — only ever about a query that has an
                // answer of its own (see `replied`), and only about the kind of
                // thing the tab in front of the user is showing.
                Item {
                    objectName: "searchEmptyStrip"
                    Layout.fillWidth: true
                    height: 80
                    visible: root.replied && root.errorText.length === 0
                             && root.tabHits === 0 && !root.loading
                    Text {
                        objectName: "searchEmptyLabel"
                        anchors.centerIn: parent
                        // Two different facts, and the strip used to have only
                        // the first: the search found nothing, or it found
                        // nothing *of this kind*. On a type tab whose own kind
                        // came back empty while another did not, "No results"
                        // is simply false - the tab row above is offering those
                        // other kinds one click away - so the line names the
                        // kind it is actually talking about. When nothing
                        // matched anywhere it is about the search again,
                        // whichever tab the user happens to be standing on.
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

                // The five sections, in whatever order the query put them.
                //
                // A Repeater over five slots rather than five sections written
                // out in order, because a ColumnLayout lays its children out in
                // declaration order and there is no way to permute that from a
                // binding. The Loaders stay put; what they load changes.
                //
                // Each section component is an Item that publishes an
                // `implicitHeight` and nothing else: a Loader inside a layout
                // is given an explicit size, which overwrites any `height`
                // binding on the item it holds - and HorizontalSection binds
                // exactly that - so the height has to reach the layout as an
                // implicit one or every tile row collapses to nothing.
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
                    // the end is only announced for a kind that actually
                    // paged - one full page or more.
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

    // The bottom of the results, watched. Outside the ScrollView on purpose:
    // a Control puts everything declared inside it into its content, and this
    // one is allowed exactly one content item.
    //
    // The two signals are not treated alike, and the difference matters more
    // than it looks. A scroll is the user, and the column is holding still
    // while it happens, so "am I near the bottom" can be answered on the spot.
    // A *height* change is the column growing, and it does not grow in one
    // step: twenty appended rows arrive as twenty delegates over several
    // passes, and for the first few of them the bottom is still a few pixels
    // away - so a page absorbed on the spot would ask for the next one, and
    // the one after that, straight to the end of the result set. It is asked
    // again only once the growing has stopped.
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
                        // The one play site in the app that declared no
                        // source. Nothing was recorded as played here,
                        // which is right - a song is not one of the four
                        // kinds the sidebar lists, and markPlayed() drops
                        // it - but the *previous* source was left standing,
                        // so the player bar went on naming the album or
                        // playlist the user had been in before searching.
                        // "search" is dropped by markPlayed for the same
                        // reason "radio" and "collection" are, so this
                        // corrects the label and records nothing.
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

    // Albums, artists, playlists and mixes: the same tile section four times
    // over, told which kind it is by the Loader holding it.
    //
    // Two presentations, and the difference is what makes paging mean
    // anything. On the All tab a kind is one horizontal row - a summary, which
    // is what the All tab is for. On the kind's own tab it is a grid that grows
    // downwards, because "load more as you scroll" needs somewhere to scroll:
    // a horizontal row has no bottom, and a page of twenty appended to it would
    // have scrolled the page not at all and asked for the next twenty straight
    // away, all the way to the end of the result set.
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
    // track's artist - that is what makes the ordering rule general rather than
    // an artist special case, and it is the same choice LibraryIndex made
    // deliberately (see docs/SPEC-0.4.0.md on S7, and the comment on
    // LibraryIndex::search).
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

    // Declaring the source is what records the play; see the same shape on
    // HomePage. Inside the callback and after the guard, so a fetch that fails
    // or comes back empty cannot record a play that never happened.
    //
    // An artist tile has no entry here on purpose: "play this artist" has no
    // honest meaning and no page in the app offers it.
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

    // Case- and accent-insensitive, the way LibraryIndex's fold() is:
    // decompose, drop the combining marks, lower-case, and spell the sharp s
    // out so a search for "strasse" finds "Straße".
    //
    // String.prototype.normalize is guarded because Qt 6.4 is this project's
    // floor; without it the accents simply survive, which costs an accented
    // name its match rather than breaking the page.
    function fold(s) {
        if (typeof s !== "string" || s.length === 0) return ""
        var d = (typeof s.normalize === "function") ? s.normalize("NFD") : s
        var out = ""
        for (var i = 0; i < d.length; ++i) {
            var c = d.charCodeAt(i)
            // The combining blocks NFD produces for Latin, Greek and Cyrillic.
            // LibraryIndex drops the three Mark_* categories by name, which QML
            // has no access to; these are the ranges that matters here.
            if ((c >= 0x0300 && c <= 0x036f) || (c >= 0x1ab0 && c <= 0x1aff)
                || (c >= 0x1dc0 && c <= 0x1dff) || (c >= 0x20d0 && c <= 0x20f0)
                || (c >= 0xfe20 && c <= 0xfe2f)) continue
            out += d.charAt(i)
        }
        return out.toLowerCase().replace(/ß/g, "ss")
    }

    // QChar::isLetterOrNumber, as far as JS can tell: a digit, or a character
    // that has two cases. A caseless script reads as a word boundary, which is
    // the conservative way round - it can promote a mid-word hit to a
    // word-start one, never demote a real one.
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

    // The order the five sections go in for this query and this reply.
    //
    // The best-scoring kind leads, but only if it is a full tier clear of the
    // runner-up; otherwise the default order stands. Two kinds that score the
    // same are therefore a tie that changes nothing - the gap is zero - and so
    // is a query no kind matches at all, where every score is 0.
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
            // Network replies can arrive out of order — a slow response for
            // an earlier keystroke could otherwise overwrite the results of
            // a more recent search (often with an empty result set, making
            // it look like "search finds nothing"). Only the most recently
            // dispatched request may update the UI. The page fetches below
            // read the same counter without bumping it: a page of a search
            // that has since been superseded is dropped by the same test.
            if (gen !== root._searchGen) return
            loading = false
            // Whatever came back came back for *this* query. Recording it is
            // what lets the two strips above speak at all.
            root.repliedFor = q
            if (err.length > 0) {
                root.errorText = err
                // The arrays still hold the hits of whatever query last
                // succeeded. Leaving them under the text the user is looking at
                // is the page claiming a result it does not have, so they go.
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

            // Remembered only once it has found something. The page searches
            // as the user types, so every pause mid-word dispatches a request:
            // recording every one of them would fill the list with prefixes of
            // one search, and recording the ones that matched nothing would
            // fill it with typing mistakes. withRecentSearch() then collapses
            // what is left - "kendri" followed by "kendrick" is one entry.
            if (root.totalHits > 0) bridge.addRecentSearch(q)

            // A first page that does not fill the window is already showing
            // its last row. Once the column has settled, and not before.
            bottomSettle.restart()
        }, pageSize, 0)
    }

    // Whether a kind that has handed over `sent` of `total` rows, the last page
    // of them `pageLen` long, has anything left.
    //
    // A short page is the end whatever the total says - that is the signal that
    // survives a server which omits totalNumberOfItems, where `total` is 0 and
    // would otherwise end every run after one page even when it was full.
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
        // Where the page sits now. Appending below the viewport does not move a
        // Flickable, but the frame in which the column's implicit height has
        // not caught up with its new children does: contentY is clamped to the
        // old maximum and the view jumps back up. Put back once the layout has
        // settled, never past the new end.
        //
        // A safeguard rather than a fix for something seen: with the settle
        // above in place, tst_search's scroll-position case passes whether or
        // not this runs, so no test tells the two apart. It stays because the
        // clamp is a real property of Flickable and costs one comparison.
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
