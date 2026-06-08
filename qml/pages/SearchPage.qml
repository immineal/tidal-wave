import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property string query: ""
    property var    tracks:    []
    property var    albums:    []
    property var    artists:   []
    property bool   loading:   false
    property int    activeTab: 0

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item { height: 16 }

        SearchBar {
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
                model: ["All", "Tracks", "Albums", "Artists"]
                Rectangle {
                    required property string modelData
                    required property int    index
                    height: 30; width: tabLabel.implicitWidth + 24; radius: 15
                    color: root.activeTab === index ? Theme.accent
                           : tabMA.containsMouse ? Theme.surfaceHov : "transparent"
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
                    visible: (root.activeTab === 0 || root.activeTab === 1) && root.tracks.length > 0
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
                            trackNum:    index + 1
                            title:       root.tracks[index].title
                            artists:     root.tracks[index].artists
                            albumTitle:  root.tracks[index].albumTitle
                            durationStr: root.tracks[index].durationStr
                            coverUrl:    root.tracks[index].coverUrl80
                            isPlaying:   player.currentTrack.id === root.tracks[index].id && player.playing
                            trackData:   root.tracks[index]
                            onPlayRequested: player.playTracks(root.tracks, index)
                        }
                    }
                    Item { height: 16 }
                }

                // No results indicator
                Item {
                    Layout.fillWidth: true
                    height: 80
                    visible: root.tracks.length === 0 && root.albums.length === 0 && root.artists.length === 0 && !root.loading
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
                    visible: (root.activeTab === 0 || root.activeTab === 2) && root.albums.length > 0
                    title: "Albums"
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
                    visible: (root.activeTab === 0 || root.activeTab === 3) && root.artists.length > 0
                    title: "Artists"
                    items: root.artists.map(function(a) {
                        return { id: a.id, title: a.name, subtitle: "Artist", coverUrl: a.coverUrl || "" }
                    })
                    mediaType: "artist"
                    onItemClicked: (i, item) => navigateTo("artist", { artistId: item.id })
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
        bridge.search(q, function(results, err) {
            loading = false
            if (err.length > 0) return
            root.tracks  = results.tracks  || []
            root.albums  = results.albums  || []
            root.artists = results.artists || []
        }, 20)
    }

    function clearResults() { tracks = []; albums = []; artists = [] }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
