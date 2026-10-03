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
    property bool   loading:   false
    property int    activeTab: 0
    property int    _searchGen: 0

    // The query the four arrays and `errorText` below describe, and the reason
    // the last reply failed (empty when it did not).
    //
    // A search has three outcomes and the page only had two of them. "I have
    // results" and "I have none" leaves no way to say *not yet*, so the
    // no-results strip - which asked nothing more than whether the four arrays
    // were empty - was up for the whole 400ms the debounce was still waiting,
    // on every keystroke, naming a query nothing had been asked about. Four
    // empty arrays are the state the page starts in, not an answer.
    //
    // Nothing may be said about a query until a reply for *that* query has
    // landed, which is what `replied` below is.
    property string repliedFor: ""
    property string errorText:  ""

    readonly property bool replied: query.length >= 2 && repliedFor === query

    // Hits of the kind the active tab shows. The strip used to ask whether all
    // four arrays were empty while each section showed itself only when its own
    // array was not, so the Albums tab for a query that matched only tracks hid
    // every section *and* suppressed the strip: a pane with nothing in it at
    // all and no way to tell that from a page still loading.
    readonly property int tabHits:
          activeTab === 1 ? tracks.length
        : activeTab === 2 ? albums.length
        : activeTab === 3 ? artists.length
        : activeTab === 4 ? playlists.length
        : totalHits

    readonly property int totalHits:
        tracks.length + albums.length + artists.length + playlists.length

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

    // The results change shape on a tab switch: "All" shows four sections and
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
    onActiveTabChanged: resultsEntry.restart()

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
        }

        Item { height: 12 }

        // Tab bar
        Row {
            objectName: "searchTabsRow"
            visible: root.query.length >= 2
            Layout.leftMargin: 24
            spacing: 4
            Repeater {
                model: [qsTr("All"), qsTr("Tracks"), qsTr("Albums"), qsTr("Artists"), qsTr("Playlists")]
                Rectangle {
                    id: searchTab
                    required property string modelData
                    required property int    index
                    height: 30; width: tabLabel.implicitWidth + 24; radius: Theme.radiusChip
                    color: root.activeTab === index ? Theme.accent
                           : tabMA.containsMouse ? Theme.surfaceHov : "transparent"
                    // Same as Collection's row, and for the same reason: the
                    // chip is what was clicked, so it must not be the one thing
                    // that snaps while the results below it fade. The hover gets
                    // the fade too, which is what the rest of the app does.
                    Behavior on color { ColorAnimation { duration: Theme.dur(140) } }
                    // The fill's own progress, so the label's ink can be chosen
                    // against what is actually painted under it. See the long
                    // note on CollectionPage's chip: the ink steps rather than
                    // fading, because the two inks and the two fills are
                    // luminance-inverted on the light palettes and every
                    // continuous path between them goes through an invisible
                    // label. This row inverts harder than Collection's - its
                    // resting fill is the page itself - so it needs it more.
                    property real filled: root.activeTab === index ? 1 : 0
                    Behavior on filled { NumberAnimation { duration: Theme.dur(140) } }
                    border.width: searchTab.activeFocus ? 2 : 0
                    border.color: Theme.accent
                    activeFocusOnTab: true
                    Keys.onReturnPressed: root.activeTab = index
                    Keys.onSpacePressed:  root.activeTab = index
                    Text {
                        id: tabLabel; objectName: "searchTabLabel"; anchors.centerIn: parent
                        text: modelData
                        color: searchTab.filled > 0.5 ? Theme.accentInk : Theme.textSec
                        font.pixelSize: 13
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

        Item { height: 8 }

        // Empty state — shown outside ScrollView so it centers in the page
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.query.length < 2

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 16
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
        }

        ScrollView {
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

                // Tracks
                ColumnLayout {
                    visible: (root.activeTab === 0 || root.activeTab === 1) && root.tracks.length > 0 && root.activeTab !== 4
                    Layout.fillWidth: true
                    spacing: 0

                    Item { height: 16 }
                    Text { Layout.leftMargin: 24; text: qsTr("Tracks"); color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
                    Item { height: 8 }

                    Repeater {
                        model: root.activeTab === 0 ? Math.min(root.tracks.length, 5) : root.tracks.length
                        TrackRow {
                            required property int index
                            Layout.fillWidth: true
                            Layout.leftMargin: 16
                            Layout.rightMargin: 16
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
                    Item { height: 16 }
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
                            ? (root.activeTab === 1 ? qsTr("No tracks for \"%1\"").arg(root.query)
                             : root.activeTab === 2 ? qsTr("No albums for \"%1\"").arg(root.query)
                             : root.activeTab === 3 ? qsTr("No artists for \"%1\"").arg(root.query)
                             : root.activeTab === 4 ? qsTr("No playlists for \"%1\"").arg(root.query)
                             : qsTr("No results for \"%1\"").arg(root.query))
                            : qsTr("No results for \"%1\"").arg(root.query)
                        color: Theme.textSec
                        font.pixelSize: 15
                    }
                }

                // A failed search used to look exactly like a successful one:
                // the spinner went away, the previous query's results stayed on
                // screen under the new text, and nothing said the request had
                // failed. There is no banner, toast or retry anywhere in this
                // app - LoginPage reports a failed sign-in as one line of
                // Theme.red text and that is the whole precedent - so this is
                // that line, in the slot the strip above uses.
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

                // Albums
                HorizontalSection {
                    Layout.fillWidth: true
                    visible: (root.activeTab === 0 || root.activeTab === 2) && root.albums.length > 0 && root.activeTab !== 4
                    title: qsTr("Albums")
                    showViewAll: false
                    items: root.albums.map(function(a) {
                        return { id: a.id, title: a.title, subtitle: a.artists, coverUrl: a.coverUrl }
                    })
                    mediaType: "album"
                    onItemClicked: (i, item) => navigateTo("album", { albumId: item.id })
                    // Declares the source, so the player bar records the play.
                    // See the same change in HomePage.
                    onItemPlayClicked: (i, item) => {
                        bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                            if (err || tracks.length === 0) return
                            player.setPlaybackSource("album", "" + item.id, item.title || "")
                            player.playTracks(tracks, 0)
                        })
                    }
                }

                // Artists
                HorizontalSection {
                    Layout.fillWidth: true
                    visible: (root.activeTab === 0 || root.activeTab === 3) && root.artists.length > 0 && root.activeTab !== 4
                    title: qsTr("Artists")
                    showViewAll: false
                    items: root.artists.map(function(a) {
                        return { id: a.id, title: a.name, subtitle: qsTr("Artist"), coverUrl: a.coverUrl || "" }
                    })
                    mediaType: "artist"
                    onItemClicked: (i, item) => navigateTo("artist", { artistId: item.id })
                }

                // Playlists
                HorizontalSection {
                    Layout.fillWidth: true
                    visible: (root.activeTab === 0 || root.activeTab === 4) && root.playlists.length > 0
                    title: qsTr("Playlists")
                    showViewAll: false
                    items: root.playlists.map(function(p) {
                        return { id: p.uuid, title: p.title, subtitle: qsTr("%n track(s)", "", p.numTracks), coverUrl: p.coverUrl || "", playlistType: p.type || "" }
                    })
                    mediaType: "playlist"
                    onItemClicked: (i, item) => navigateTo("playlist", { playlistUuid: item.id, playlistTitle: item.title, coverUrl: item.coverUrl, playlistType: item.playlistType || "" })
                    onItemPlayClicked: (i, item) => {
                        bridge.fetchPlaylistTracks(item.id, function(tracks, err) {
                            if (err || tracks.length === 0) return
                            bridge.markPlaylistPlayed(item.id)
                            player.setPlaybackSource("playlist", "" + item.id, item.title || "")
                            player.playTracks(tracks, 0)
                        })
                    }
                }

                Item { height: 32 }
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

    function doSearch(q) {
        loading = true
        var gen = ++root._searchGen
        bridge.search(q, function(results, err) {
            // Network replies can arrive out of order — a slow response for
            // an earlier keystroke could otherwise overwrite the results of
            // a more recent search (often with an empty result set, making
            // it look like "search finds nothing"). Only the most recently
            // dispatched request may update the UI.
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
                root.tracks = []; root.albums = []; root.artists = []; root.playlists = []
                return
            }
            root.errorText = ""
            root.tracks    = results.tracks    || []
            root.albums    = results.albums    || []
            root.artists   = results.artists   || []
            root.playlists = results.playlists || []
        }, 20)
    }

    function clearResults() {
        tracks = []; albums = []; artists = []; playlists = []
        _searchGen++; loading = false
        // Back below the threshold: there is no query to have an answer about.
        repliedFor = ""; errorText = ""
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
