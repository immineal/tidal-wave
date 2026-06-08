import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import TidalWave

ApplicationWindow {
    id: root
    visible: true
    width: 1280
    height: 800
    minimumWidth: 900
    minimumHeight: 600
    title: "Tidal Wave"
    color: Theme.bg

    property string currentPage: "home"
    property var    pageParams:  ({})
    property bool   queueOpen:   false

    property string previousPage: "home"
    property var    previousPageParams: ({})
    property var    _currentNavParams: ({})

    function navigate(page, params) {
        var p = params || {}
        if (page === "nowplaying" && currentPage !== "nowplaying") {
            previousPage = currentPage
            previousPageParams = _currentNavParams
        }
        _currentNavParams = p
        pageParams  = p
        currentPage = page
    }

    Connections {
        target: auth
        function onStateChanged(state) {
            if (state === 2) {
                root.navigate("home")
            }
        }
    }

    // ─── Keyboard shortcuts ────────────────────────────
    // Bare keys (Space, arrows, Up/Down) are suppressed while a text field
    // has focus so they don't fight with typing/cursor movement in search etc.
    function isTypingContext() {
        var f = root.activeFocusItem
        return !!(f && typeof f.text === "string" && typeof f.cursorPosition === "number")
    }

    // Playback
    Shortcut { sequence: "Space";      enabled: auth.state === 2 && !root.isTypingContext(); onActivated: player.playPause() }
    Shortcut { sequence: "Ctrl+Right"; enabled: auth.state === 2; onActivated: player.next() }
    Shortcut { sequence: "Ctrl+Left";  enabled: auth.state === 2; onActivated: player.previous() }
    Shortcut { sequence: "Right";      enabled: auth.state === 2 && !root.isTypingContext(); onActivated: player.seek(Math.min(player.duration, player.position + 10000)) }
    Shortcut { sequence: "Left";       enabled: auth.state === 2 && !root.isTypingContext(); onActivated: player.seek(Math.max(0, player.position - 10000)) }
    Shortcut { sequence: "Up";         enabled: auth.state === 2 && !root.isTypingContext(); onActivated: player.setVolume(Math.min(1, player.volume + 0.05)) }
    Shortcut { sequence: "Down";       enabled: auth.state === 2 && !root.isTypingContext(); onActivated: player.setVolume(Math.max(0, player.volume - 0.05)) }
    Shortcut { sequence: "Ctrl+M";     enabled: auth.state === 2; onActivated: player.setMuted(!player.muted) }
    Shortcut { sequence: "Ctrl+S";     enabled: auth.state === 2; onActivated: player.setShuffle(!player.shuffle) }
    Shortcut { sequence: "Ctrl+R";     enabled: auth.state === 2; onActivated: player.setRepeatMode((player.repeatMode + 1) % 3) }

    // Navigation
    Shortcut { sequence: "Ctrl+1"; enabled: auth.state === 2; onActivated: root.navigate("home") }
    Shortcut { sequence: "Ctrl+2"; enabled: auth.state === 2; onActivated: root.navigate("search") }
    Shortcut { sequence: "Ctrl+3"; enabled: auth.state === 2; onActivated: root.navigate("collection") }
    Shortcut { sequence: "Ctrl+N"; enabled: auth.state === 2; onActivated: root.navigate("nowplaying") }
    Shortcut { sequence: "Ctrl+Q"; enabled: auth.state === 2; onActivated: root.queueOpen = !root.queueOpen }
    Shortcut {
        sequence: "Escape"
        enabled: auth.state === 2
        onActivated: {
            if (root.queueOpen) root.queueOpen = false
            else if (root.currentPage === "nowplaying") root.navigate(root.previousPage, root.previousPageParams)
        }
    }
    Shortcut {
        sequence: "Alt+Left"
        enabled: auth.state === 2 && root.currentPage === "nowplaying"
        onActivated: root.navigate(root.previousPage, root.previousPageParams)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            spacing: 0

            SideBar {
                visible: auth.state === 2
                Layout.preferredWidth: 220
                Layout.fillHeight: true
                currentPage: root.currentPage
                onNavigate: function(page, params) { root.navigate(page, params) }
            }

            Item {
                Layout.fillWidth:  true
                Layout.fillHeight: true
                clip: true

                Loader {
                    id: pageLoader
                    anchors.fill: parent
                    source: {
                        if (auth.state !== 2) return "pages/LoginPage.qml"
                        switch (root.currentPage) {
                            case "home":       return "pages/HomePage.qml"
                            case "search":     return "pages/SearchPage.qml"
                            case "collection": return "pages/CollectionPage.qml"
                            case "album":      return "pages/AlbumPage.qml"
                            case "artist":     return "pages/ArtistPage.qml"
                            case "playlist":   return "pages/PlaylistPage.qml"
                            case "mix":        return "pages/MixPage.qml"
                            case "nowplaying": return "pages/NowPlayingPage.qml"
                            default:           return "pages/HomePage.qml"
                        }
                    }
                    onLoaded: {
                        if (item && root.pageParams) {
                            var params = root.pageParams
                            root.pageParams = {}
                            for (var k in params) {
                                if (item[k] !== undefined)
                                    item[k] = params[k]
                            }
                        }
                    }
                }

                QueuePanel {
                    id: queuePanel
                    anchors.top:    parent.top
                    anchors.bottom: parent.bottom
                    anchors.right:  parent.right
                    width:          340
                    visible:        root.queueOpen
                }
            }
        }

        PlayerBar {
            visible:          auth.state === 2 && root.currentPage !== "nowplaying"
            Layout.fillWidth: true
            onShowQueue:      root.queueOpen = !root.queueOpen
            onShowNowPlaying: root.navigate("nowplaying")
        }
    }
}
