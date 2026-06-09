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

    function releaseFocus() {
        searchBar.releaseFocus()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item { height: 16 }

        SearchBar {
            id: searchBar
            focus: true
            Layout.fillWidth: true
            Layout.leftMargin: 24
            Layout.rightMargin: 24
            height: 46
            placeholder: "Search tracks, albums, artists, playlists…"
            onTextEdited: (text) => {
                root.query = text
                if (text.length < 2) { clearResults(); return }
                searchDebounce.restart()
            }
        }

        Item { height: 12 }

        // Tab bar
        Row {
            visible: root.query.length >= 2
            Layout.leftMargin: 24
            spacing: 4
            Repeater {
                model: ["All", "Tracks", "Albums", "Artists", "Playlists"]
                Rectangle {
                    id: searchTab
                    required property string modelData
                    required property int    index
                    height: 30; width: tabLabel.implicitWidth + 24; radius: 15
                    color: root.activeTab === index ? Theme.accent
                           : tabMA.containsMouse ? Theme.surfaceHov : "transparent"
                    border.width: searchTab.activeFocus ? 2 : 0
                    border.color: Theme.accent
                    activeFocusOnTab: true
                    Keys.onReturnPressed: root.activeTab = index
                    Keys.onSpacePressed:  root.activeTab = index
                    Text {
                        id: tabLabel; anchors.centerIn: parent
                        text: modelData
                        color: root.activeTab === index ? "white" : Theme.textSec
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
                Text { Layout.alignment: Qt.AlignHCenter; text: "Search Tidal"; color: Theme.textPrimary; font.pixelSize: 22; font.bold: true }
                Text { Layout.alignment: Qt.AlignHCenter; text: "Find tracks, albums, artists and more"; color: Theme.textSec; font.pixelSize: 14 }
            }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            rightPadding: 14
            contentWidth: availableWidth
            visible: root.query.length >= 2

            ColumnLayout {
                width: parent.width
                spacing: 0

                // Tracks
                ColumnLayout {
                    visible: (root.activeTab === 0 || root.activeTab === 1) && root.tracks.length > 0 && root.activeTab !== 4
                    Layout.fillWidth: true
                    spacing: 0

                    Item { height: 16 }
                    Text { Layout.leftMargin: 24; text: "Tracks"; color: Theme.textPrimary; font.pixelSize: 18; font.bold: true }
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
                            onPlayRequested: player.playTracks(root.tracks, index)
                        }
                    }
                    Item { height: 16 }
                }

                // No results indicator
                Item {
                    Layout.fillWidth: true
                    height: 80
                    visible: root.tracks.length === 0 && root.albums.length === 0 && root.artists.length === 0 && root.playlists.length === 0 && !root.loading
                    Text {
                        anchors.centerIn: parent
                        text: "No results for \"" + root.query + "\""
                        color: Theme.textSec
                        font.pixelSize: 15
                    }
                }

                // Albums
                HorizontalSection {
                    Layout.fillWidth: true
                    visible: (root.activeTab === 0 || root.activeTab === 2) && root.albums.length > 0 && root.activeTab !== 4
                    title: "Albums"
                    showViewAll: false
                    items: root.albums.map(function(a) {
                        return { id: a.id, title: a.title, subtitle: a.artists, coverUrl: a.coverUrl }
                    })
                    mediaType: "album"
                    onItemClicked: (i, item) => navigateTo("album", { albumId: item.id })
                    onItemPlayClicked: (i, item) => {
                        bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                            if (!err && tracks.length > 0) player.playTracks(tracks, 0)
                        })
                    }
                }

                // Artists
                HorizontalSection {
                    Layout.fillWidth: true
                    visible: (root.activeTab === 0 || root.activeTab === 3) && root.artists.length > 0 && root.activeTab !== 4
                    title: "Artists"
                    showViewAll: false
                    items: root.artists.map(function(a) {
                        return { id: a.id, title: a.name, subtitle: "Artist", coverUrl: a.coverUrl || "" }
                    })
                    mediaType: "artist"
                    onItemClicked: (i, item) => navigateTo("artist", { artistId: item.id })
                }

                // Playlists
                HorizontalSection {
                    Layout.fillWidth: true
                    visible: (root.activeTab === 0 || root.activeTab === 4) && root.playlists.length > 0
                    title: "Playlists"
                    showViewAll: false
                    items: root.playlists.map(function(p) {
                        return { id: p.uuid, title: p.title, subtitle: p.numTracks + " tracks", coverUrl: p.coverUrl || "", playlistType: p.type || "" }
                    })
                    mediaType: "playlist"
                    onItemClicked: (i, item) => navigateTo("playlist", { playlistUuid: item.id, playlistTitle: item.title, coverUrl: item.coverUrl, playlistType: item.playlistType || "" })
                    onItemPlayClicked: (i, item) => {
                        bridge.markPlaylistPlayed(item.id)
                        bridge.fetchPlaylistTracks(item.id, function(tracks, err) {
                            if (!err && tracks.length > 0) player.playTracks(tracks, 0)
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
            if (err.length > 0) return
            root.tracks    = results.tracks    || []
            root.albums    = results.albums    || []
            root.artists   = results.artists   || []
            root.playlists = results.playlists || []
        }, 20)
    }

    function clearResults() { tracks = []; albums = []; artists = []; playlists = []; _searchGen++; loading = false }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
