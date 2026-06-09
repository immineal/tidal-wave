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

    onClosing: (close) => {
        if (!app.reallyQuit) {
            close.accepted = false
            root.hide()
        }
    }

    property string currentPage: "home"
    property var    pageParams:  ({})
    property bool   queueOpen:   false

    property string previousPage: "home"
    property var    previousPageParams: ({})
    property var    _currentNavParams: ({})

    function applyParams(item, params) {
        if (!item || !params) return
        for (var k in params) {
            if (item[k] !== undefined) {
                item[k] = params[k]
            }
        }
    }

    function getLoader(page) {
        if (page === "home") return homeLoader
        if (page === "search") return searchLoader
        if (page === "collection") return collectionLoader
        if (["album", "artist", "playlist", "mix", "nowplaying"].indexOf(page) !== -1) return detailLoader
        return null
    }

    // Pages a user can be "inside" of, where a single consistent back
    // action (button, Escape, Alt+Left) makes sense. Top-level destinations
    // (home/search/collection) are reached directly from the sidebar and
    // don't need — or want — a back affordance.
    readonly property var detailPages: ["album", "artist", "playlist", "mix", "nowplaying", "radio"]

    function navigate(page, params) {
        var p = params || {}
        if (page !== currentPage) {
            previousPage = currentPage
            previousPageParams = _currentNavParams
        }
        _currentNavParams = p
        
        var targetLoader = getLoader(page)
        if (targetLoader) {
            if (currentPage === page && ["home", "search", "collection"].indexOf(page) === -1) {
                // Force reload of the same detail page type by toggling state
                var savedPage = currentPage
                currentPage = ""
                currentPage = savedPage
            }
            // home/search/collection each have a fixed `source`, so their
            // loaded item always matches the target type — apply params to it
            // directly. detailLoader swaps between page types based on
            // currentPage, so its item only matches when we're already
            // showing that same page type — otherwise it's still the
            // outgoing page and has no matching properties (e.g. clicking
            // an artist link while on Now Playing would silently no-op).
            var loaderAlwaysMatchesTarget = targetLoader !== detailLoader
            if ((loaderAlwaysMatchesTarget || currentPage === page) && targetLoader.status === Loader.Ready) {
                applyParams(targetLoader.item, p)
            } else {
                root.pageParams = p
            }
        } else {
            root.pageParams = p
        }
        currentPage = page
        if (page === "search") {
            searchLoader.forceActiveFocus()
        } else {
            focusStealer.forceActiveFocus()
        }
    }

    function goBack() {
        navigate(previousPage, previousPageParams)
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
    function isTypingContext(f) {
        if (!f) return false
        if (typeof f.text !== "string" || typeof f.cursorPosition !== "number") return false
        var p = f
        while (p) {
            if (!p.visible) return false
            p = p.parent
        }
        return true
    }

    Item {
        id: focusStealer
        focus: true
        Keys.onPressed: (event) => { event.accepted = false }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Playback Shortcuts
        Shortcut { sequence: "Space";      context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.playPause() }
        Shortcut { sequence: "Ctrl+Right"; context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.next() }
        Shortcut { sequence: "Ctrl+Left";  context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.previous() }
        Shortcut { sequence: "Right";      context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.seek(Math.min(player.duration, player.position + 10000)) }
        Shortcut { sequence: "Left";       context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.seek(Math.max(0, player.position - 10000)) }
        Shortcut { sequence: "Up";         context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.setVolume(Math.min(1, player.volume + 0.05)) }
        Shortcut { sequence: "Down";       context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.setVolume(Math.max(0, player.volume - 0.05)) }
        Shortcut { sequence: "Ctrl+M";     context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.setMuted(!player.muted) }
        Shortcut { sequence: "Ctrl+S";     context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.setShuffle(!player.shuffle) }
        Shortcut { sequence: "Ctrl+R";     context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.setRepeatMode((player.repeatMode + 1) % 3) }

        // Navigation Shortcuts
        Shortcut { sequence: "Ctrl+1"; context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.navigate("home") }
        Shortcut { sequence: "Ctrl+2"; context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.navigate("search") }
        Shortcut { sequence: "Ctrl+3"; context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.navigate("collection") }
        Shortcut {
            sequence: "Ctrl+N"
            context: Qt.ApplicationShortcut
            enabled: auth.state === 2
            onActivated: {
                if (root.currentPage === "nowplaying") {
                    root.goBack()
                } else {
                    root.navigate("nowplaying")
                }
            }
        }
        Shortcut { sequence: "Ctrl+Q"; context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.queueOpen = !root.queueOpen }
        Shortcut { sequence: "Ctrl+,"; context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: sideBar.openSettings() }
        Shortcut {
            sequence: "Escape"
            context: Qt.ApplicationShortcut
            enabled: auth.state === 2
            onActivated: {
                if (root.queueOpen) root.queueOpen = false
                else if (root.detailPages.indexOf(root.currentPage) !== -1) root.goBack()
            }
        }
        Shortcut {
            sequence: "Alt+Left"
            context: Qt.ApplicationShortcut
            enabled: auth.state === 2 && root.detailPages.indexOf(root.currentPage) !== -1
            onActivated: root.goBack()
        }

        RowLayout {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            spacing: 0

            SideBar {
                id: sideBar
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

                Item {
                    id: mainContainer
                    anchors.fill: parent
                    visible: auth.state === 2

                    Loader {
                        id: homeLoader
                        anchors.fill: parent
                        source: "pages/HomePage.qml"
                        visible: root.currentPage === "home"
                        active: auth.state === 2
                        onLoaded: {
                            if (item && root.pageParams) {
                                var params = root.pageParams
                                root.pageParams = {}
                                root.applyParams(item, params)
                            }
                        }
                    }

                    Loader {
                        id: searchLoader
                        focus: true
                        anchors.fill: parent
                        source: "pages/SearchPage.qml"
                        visible: root.currentPage === "search"
                        active: auth.state === 2
                        onVisibleChanged: {
                            if (!visible && item && typeof item.releaseFocus === "function") {
                                item.releaseFocus()
                            }
                        }
                        onLoaded: {
                            if (item && root.pageParams) {
                                var params = root.pageParams
                                root.pageParams = {}
                                root.applyParams(item, params)
                            }
                        }
                    }

                    Loader {
                        id: collectionLoader
                        anchors.fill: parent
                        source: "pages/CollectionPage.qml"
                        visible: root.currentPage === "collection"
                        active: auth.state === 2
                        onLoaded: {
                            if (item && root.pageParams) {
                                var params = root.pageParams
                                root.pageParams = {}
                                root.applyParams(item, params)
                            }
                        }
                    }

                    Loader {
                        id: detailLoader
                        anchors.fill: parent
                        visible: ["home", "search", "collection"].indexOf(root.currentPage) === -1
                        active: auth.state === 2
                        source: {
                            if (!active) return ""
                            switch (root.currentPage) {
                                case "album":      return "pages/AlbumPage.qml"
                                case "artist":     return "pages/ArtistPage.qml"
                                case "playlist":   return "pages/PlaylistPage.qml"
                                case "mix":        return "pages/MixPage.qml"
                                case "nowplaying": return "pages/NowPlayingPage.qml"
                                case "radio":      return "pages/RadioPage.qml"
                                default:           return ""
                            }
                        }
                        onLoaded: {
                            if (item && root.pageParams) {
                                var params = root.pageParams
                                root.pageParams = {}
                                root.applyParams(item, params)
                            }
                        }
                    }
                }

                Loader {
                    id: loginLoader
                    anchors.fill: parent
                    visible: auth.state !== 2
                    active: auth.state !== 2
                    source: "pages/LoginPage.qml"
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
