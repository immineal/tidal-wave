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
    property bool loading: false

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
                text: {
                    var h = (new Date()).getHours()
                    if (h < 12) return "Good morning"
                    if (h < 18) return "Good afternoon"
                    return "Good evening"
                }
                color: Theme.textPrimary
                font.pixelSize: 28
                font.bold: true
            }

            Item { height: 24 }

            HorizontalSection {
                Layout.fillWidth: true
                title: "My Mixes"
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
                onViewAllClicked: navigateTo("collection", { activeTab: 3 })
            }

            Item { height: 32 }

            HorizontalSection {
                Layout.fillWidth: true
                visible: recentAlbums.length > 0
                title: "Saved Albums"
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
        }
    }

    function navigateTo(page, params) {
        // Walk up to the ApplicationWindow to call navigate()
        Window.window.navigate(page, params)
    }

    LoadingOverlay { loading: root.loading }
}
