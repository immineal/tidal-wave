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

    function appWindow() { return Window.window }


    Component.onCompleted: loadContent()

    // How many tiles a row holds before "View all" is the only way to the rest.
    readonly property int rowLimit: 12

    // The Loader that holds this page is never torn down, so the favourite rows
    // follow the bridge's signals. A refresh reads the bridge's in-memory
    // favourites, the same source Collection reads.
    Connections {
        target: bridge
        function onFavoriteAlbumsChanged()    { refreshDebounce.restart() }
        function onFavoriteArtistsChanged()   { refreshDebounce.restart() }
        function onFavoritePlaylistsChanged() { refreshDebounce.restart() }
    }

    // Each kind emits several times for one change, so the three handlers
    // coalesce into one pass.
    Timer {
        id: refreshDebounce
        interval: 120
        onTriggered: root.refreshRows()
    }

    function albumItem(a) {
        return { id: a.id, title: a.title, subtitle: a.artists,
                 coverUrl: a.coverUrl, type: "album" }
    }
    function playlistItem(p) {
        return { id: p.uuid, title: p.title,
                 subtitle: qsTr("%n track(s)", "", p.numTracks),
                 coverUrl: p.coverUrl, type: "playlist",
                 playlistType: p.type || "" }
    }
    function artistItem(a) {
        return { id: a.id, title: a.name, subtitle: qsTr("Artist"),
                 coverUrl: a.coverUrl || "", type: "artist" }
    }
    function firstOf(list, map) {
        var items = []
        for (var i = 0; i < Math.min(list.length, root.rowLimit); i++)
            items.push(map(list[i]))
        return items
    }

    function refreshRows() {
        recentAlbums = firstOf(bridge.searchFavoriteAlbums(""),  albumItem)
        playlists    = firstOf(bridge.getUserPlaylists(),        playlistItem)
        artists      = firstOf(bridge.searchFavoriteArtists(""), artistItem)
    }

    // The first fill goes to the network: the cache refreshRows() reads is
    // still being paged in when this page mounts.
    function loadContent() {
        loading = true
        bridge.fetchHomeMixes(function(mixList, err) {
            loading = false
            if (err.length > 0) return
            var items = []
            for (var i = 0; i < Math.min(mixList.length, root.rowLimit); i++) {
                var m = mixList[i]
                items.push({ id: m.id, title: m.title, subtitle: m.subtitle,
                             coverUrl: m.coverUrl, type: "mix",
                             // Carried through so the tile can hand it to
                             // MixPage; see SideBar.open().
                             mixType: m.mixType || "" })
            }
            mixes = items
        })

        bridge.fetchFavoriteAlbums(function(albums, err) {
            if (err.length > 0) return
            recentAlbums = firstOf(albums, albumItem)
        }, root.rowLimit, 0)

        bridge.fetchUserPlaylists(function(lists, err) {
            if (err.length > 0) return
            playlists = firstOf(lists, playlistItem)
        }, root.rowLimit, 0)

        bridge.fetchFavoriteArtists(function(artistList, err) {
            if (err.length > 0) return
            artists = firstOf(artistList, artistItem)
        }, root.rowLimit, 0)
    }

    ScrollView {
        anchors.fill: parent
        rightPadding: 14
        contentWidth: availableWidth

        ColumnLayout {
            width: parent.width
            spacing: 0

            // A ColumnLayout sizes a child from Layout.preferredHeight, so
            // every gap on this page sets that. A gap above a row that can be
            // empty hides with it.
            Item { Layout.preferredHeight: 24 }

            Text {
                Layout.leftMargin: 24
                text: root.greeting
                color: Theme.textPrimary
                font.pixelSize: 28
                font.bold: true
            }

            Item { Layout.preferredHeight: 24 }

            HorizontalSection {
                Layout.fillWidth: true
                title: qsTr("My Mixes")
                items: root.mixes
                mediaType: "mix"
                onItemClicked: (idx, item) => navigateTo("mix", {
                    mixId: item.id, title: item.title,
                    subtitle: item.subtitle, coverUrl: item.coverUrl,
                    mixType: item.mixType || ""
                })
                // Declaring the source is what records the play: the player bar
                // listens to player.sourceChanged. After the guard, so a failed
                // or empty fetch records nothing.
                onItemPlayClicked: (idx, item) => {
                    bridge.fetchMixTracks(item.id, function(tracks, err) {
                        if (err || tracks.length === 0) return
                        player.setPlaybackSource("mix", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
                onViewAllClicked: navigateTo("collection", { activeTab: 4 })
            }

            Item {
                Layout.preferredHeight: 32
                visible: recentAlbums.length > 0
            }

            HorizontalSection {
                Layout.fillWidth: true
                visible: recentAlbums.length > 0
                title: qsTr("Saved Albums")
                items: root.recentAlbums
                mediaType: "album"
                onItemClicked: (idx, item) => navigateTo("album", { albumId: item.id })
                onItemPlayClicked: (idx, item) => {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (err || tracks.length === 0) return
                        player.setPlaybackSource("album", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
                onViewAllClicked: navigateTo("collection", { activeTab: 1 })
            }

            Item {
                Layout.preferredHeight: 32
                visible: playlists.length > 0
            }

            HorizontalSection {
                Layout.fillWidth: true
                visible: playlists.length > 0
                title: qsTr("Your Playlists")
                items: root.playlists
                mediaType: "playlist"
                onItemClicked: (idx, item) => navigateTo("playlist", { playlistUuid: item.id, playlistTitle: item.title, coverUrl: item.coverUrl, playlistType: item.playlistType || "" })
                onItemPlayClicked: (idx, item) => {
                    bridge.fetchPlaylistTracks(item.id, function(tracks, err) {
                        if (err || tracks.length === 0) return
                        bridge.markPlaylistPlayed(item.id)
                        player.setPlaybackSource("playlist", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
                onViewAllClicked: navigateTo("collection", { activeTab: 3 })
            }

            Item {
                Layout.preferredHeight: 32
                visible: artists.length > 0
            }

            HorizontalSection {
                Layout.fillWidth: true
                visible: artists.length > 0
                title: qsTr("Favorite Artists")
                items: root.artists
                mediaType: "artist"
                onItemClicked: (idx, item) => navigateTo("artist", { artistId: item.id })
                onViewAllClicked: navigateTo("collection", { activeTab: 2 })
            }

            Item { Layout.preferredHeight: 32 }
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
