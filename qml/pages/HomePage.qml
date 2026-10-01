import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var mixes: []
    property var recentAlbums: []
    property var playlists: []
    property var artists: []
    property bool loading: false
    property string greeting: greetingFor(new Date().getHours())

    function greetingFor(h) {
        if (h < 12) return qsTr("Good morning")
        if (h < 18) return qsTr("Good afternoon")
        return qsTr("Good evening")
    }

    Timer {
        interval: 60000; running: true; repeat: true
        onTriggered: root.greeting = root.greetingFor(new Date().getHours())
    }

    // Access the window root for navigation
    function appWindow() { return Window.window }


    Component.onCompleted: loadContent()

    function loadContent() {
        loading = true
        bridge.fetchHomeMixes(function(mixList, err) {
            loading = false
            if (err.length > 0) return
            var items = []
            for (var i = 0; i < Math.min(mixList.length, 12); i++) {
                var m = mixList[i]
                items.push({ id: m.id, title: m.title, subtitle: m.subtitle,
                             coverUrl: m.coverUrl, type: "mix" })
            }
            mixes = items
        })

        bridge.fetchFavoriteAlbums(function(albums, err) {
            if (err.length > 0) return
            var items = []
            for (var i = 0; i < Math.min(albums.length, 12); i++) {
                var a = albums[i]
                items.push({ id: a.id, title: a.title, subtitle: a.artists,
                             coverUrl: a.coverUrl, type: "album" })
            }
            recentAlbums = items
        }, 12, 0)

        bridge.fetchUserPlaylists(function(lists, err) {
            if (err.length > 0) return
            var items = []
            for (var i = 0; i < Math.min(lists.length, 12); i++) {
                var p = lists[i]
                items.push({ id: p.uuid, title: p.title, subtitle: qsTr("%n track(s)", "", p.numTracks),
                             coverUrl: p.coverUrl, type: "playlist", playlistType: p.type || "" })
            }
            playlists = items
        }, 12, 0)

        bridge.fetchFavoriteArtists(function(artistList, err) {
            if (err.length > 0) return
            var items = []
            for (var i = 0; i < Math.min(artistList.length, 12); i++) {
                var a = artistList[i]
                items.push({ id: a.id, title: a.name, subtitle: qsTr("Artist"),
                             coverUrl: a.coverUrl || "", type: "artist" })
            }
            artists = items
        }, 12, 0)

    }

    ScrollView {
        anchors.fill: parent
        rightPadding: 14
        contentWidth: availableWidth

        ColumnLayout {
            width: parent.width
            spacing: 0

            Item { height: 24 }

            Text {
                Layout.leftMargin: 24
                text: root.greeting
                color: Theme.textPrimary
                font.pixelSize: 28
                font.bold: true
            }

            Item { height: 24 }

            HorizontalSection {
                Layout.fillWidth: true
                title: qsTr("My Mixes")
                items: root.mixes
                mediaType: "mix"
                onItemClicked: (idx, item) => navigateTo("mix", {
                    mixId: item.id, title: item.title,
                    subtitle: item.subtitle, coverUrl: item.coverUrl
                })
                onItemPlayClicked: (idx, item) => {
                    bridge.fetchMixTracks(item.id, function(tracks, err) {
                        if (!err && tracks.length > 0) player.playTracks(tracks, 0)
                    })
                }
                onViewAllClicked: navigateTo("collection", { activeTab: 4 })
            }

            Item { height: 32 }


            Item { height: 32 }

            HorizontalSection {
                Layout.fillWidth: true
                visible: recentAlbums.length > 0
                title: qsTr("Saved Albums")
                items: root.recentAlbums
                mediaType: "album"
                onItemClicked: (idx, item) => navigateTo("album", { albumId: item.id })
                onItemPlayClicked: (idx, item) => {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (!err && tracks.length > 0) player.playTracks(tracks, 0)
                    })
                }
                onViewAllClicked: navigateTo("collection", { activeTab: 1 })
            }

            Item { height: 32 }

            HorizontalSection {
                Layout.fillWidth: true
                visible: playlists.length > 0
                title: qsTr("Your Playlists")
                items: root.playlists
                mediaType: "playlist"
                onItemClicked: (idx, item) => navigateTo("playlist", { playlistUuid: item.id, playlistTitle: item.title, coverUrl: item.coverUrl, playlistType: item.playlistType || "" })
                onItemPlayClicked: (idx, item) => {
                    bridge.markPlaylistPlayed(item.id)
                    bridge.fetchPlaylistTracks(item.id, function(tracks, err) {
                        if (!err && tracks.length > 0) player.playTracks(tracks, 0)
                    })
                }
                onViewAllClicked: navigateTo("collection", { activeTab: 3 })
            }

            Item { height: 32 }

            HorizontalSection {
                Layout.fillWidth: true
                visible: artists.length > 0
                title: qsTr("Favorite Artists")
                items: root.artists
                mediaType: "artist"
                onItemClicked: (idx, item) => navigateTo("artist", { artistId: item.id })
                onViewAllClicked: navigateTo("collection", { activeTab: 2 })
            }

            Item { height: 32 }
        }
    }

    function navigateTo(page, params) {
        // Walk up to the ApplicationWindow to call navigate()
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
