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

    // How many tiles a row holds before "View all" is the only way to the rest.
    readonly property int rowLimit: 12

    // The three favourite rows change while this page is alive. The Loader that
    // holds HomePage is never torn down, so a row built at login kept whatever
    // it was built with: an album saved from its own page was missing from
    // Saved Albums, and playing a playlist did not move it to the front, until
    // the app was restarted.
    //
    // The bridge pages the whole favourites set into memory at login and keeps
    // that copy current on every add and remove, so a refresh reads it instead
    // of going back to the network. It is the same source Collection reads,
    // which is what makes the two pages agree.
    Connections {
        target: bridge
        function onFavoriteAlbumsChanged()    { refreshDebounce.restart() }
        function onFavoriteArtistsChanged()   { refreshDebounce.restart() }
        function onFavoritePlaylistsChanged() { refreshDebounce.restart() }
    }

    // Each kind emits once when its first page lands and again when its last
    // one does, and saving a single album emits twice more, so the three
    // handlers above coalesce into one pass instead of rebuilding three rows
    // five times.
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

    // The first fill goes to the network. The cache the refresh reads is still
    // being paged in at this point - the page mounts the moment auth completes,
    // which is also when that paging starts - so reading it here would race it.
    function loadContent() {
        loading = true
        bridge.fetchHomeMixes(function(mixList, err) {
            loading = false
            if (err.length > 0) return
            var items = []
            for (var i = 0; i < Math.min(mixList.length, root.rowLimit); i++) {
                var m = mixList[i]
                items.push({ id: m.id, title: m.title, subtitle: m.subtitle,
                             coverUrl: m.coverUrl, type: "mix" })
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

            // A ColumnLayout takes a child's preferred height from
            // Layout.preferredHeight, so a spacer with a plain height depends
            // on the layout happening to cache its first measurement. Every
            // gap on this page is one of these, and each one above a row that
            // can be empty is hidden with it: otherwise a user with no
            // playlists got that row's gap twice over.
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
                    subtitle: item.subtitle, coverUrl: item.coverUrl
                })
                // Declaring the source is what records the play: the player
                // bar listens to player.sourceChanged and is the only place
                // markPlayed() is called from. Inside the callback and after
                // the guard, so a fetch that fails or comes back empty cannot
                // record a play that never happened.
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
        // Walk up to the ApplicationWindow to call navigate()
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
