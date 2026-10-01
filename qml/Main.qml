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
    // 640 is the narrow end the layout is built for (SPEC L1): the user runs
    // two 1920x1200 monitors, so half-screen is 960x1200, and 640 leaves room
    // to go narrower still. The old 900 was not even wide enough for the Now
    // Playing transport row.
    minimumWidth: 640
    minimumHeight: 600
    // Show the current track in the window/taskbar/dock title.
    title: (player.currentTrack && player.currentTrack.title)
           ? qsTr("%1 – %2 · Tidal Wave").arg(player.currentTrack.title)
                                         .arg(player.currentTrack.artists)
           : "Tidal Wave"
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

    // ─── Fullscreen ────────────────────────────────────
    // Now Playing can take the whole screen: the window drops its chrome and
    // the sidebar steps aside. Only the window can do either, so the page asks
    // for it through Window.window instead of owning any of it.
    //
    // What to come back to is remembered rather than assumed. Restoring to a
    // hardcoded Windowed would quietly un-maximise a window that was maximised
    // when the user went fullscreen.
    property int preFullScreenVisibility: Window.Windowed
    readonly property bool fullScreen: visibility === Window.FullScreen

    function enterFullScreen() {
        if (root.fullScreen) return
        // Hidden, Minimized and AutomaticVisibility are not states to come
        // back to; anything but Maximized returns to a normal window.
        root.preFullScreenVisibility =
            (root.visibility === Window.Maximized) ? Window.Maximized : Window.Windowed
        root.visibility = Window.FullScreen
    }

    function leaveFullScreen() {
        if (!root.fullScreen) return
        root.visibility = root.preFullScreenVisibility
    }

    // Also the F11 handler, which is why it navigates: F11 anywhere in the app
    // means "give me the player, big", not "do nothing unless you are already
    // looking at it".
    function toggleFullScreen() {
        if (root.fullScreen) {
            root.leaveFullScreen()
            return
        }
        if (root.currentPage !== "nowplaying") root.navigate("nowplaying")
        root.enterFullScreen()
    }

    // ─── Sleep Timer Core State & Logic ──────────────────
    property bool   sleepTimerActive: false
    property int    sleepTimeTotal: 0      // total seconds
    property int    sleepTimeLeft: 0       // seconds remaining
    property bool   sleepStopAtEndOfTrack: false
    property bool   sleepFadeOut: true     // whether to fade out volume
    property double sleepOriginalVolume: 1.0
    property bool   sleepIsFading: false

    property int lastTrackPosition: 0
    property int lastTrackDuration: 0

    function startSleepTimer(minutes, stopAtEnd) {
        cancelSleepTimer()
        if (stopAtEnd) {
            sleepStopAtEndOfTrack = true
            sleepTimerActive = true
            sleepTimeLeft = 0
            sleepTimeTotal = 0
        } else {
            sleepStopAtEndOfTrack = false
            sleepTimeTotal = minutes * 60
            sleepTimeLeft = minutes * 60
            sleepTimerActive = true
        }
    }

    function cancelSleepTimer() {
        volumeRestoreTimer.stop()
        if (sleepIsFading) {
            player.setVolume(sleepOriginalVolume)
        }
        sleepTimerActive = false
        sleepIsFading = false
        sleepTimeLeft = 0
        sleepStopAtEndOfTrack = false
    }

    function triggerSleepStop() {
        if (player.playing) {
            player.playPause()
        }
        if (sleepIsFading) {
            volumeRestoreTimer.originalVol = sleepOriginalVolume
            volumeRestoreTimer.start()
        }
        sleepTimerActive = false
        sleepIsFading = false
        sleepTimeLeft = 0
        sleepStopAtEndOfTrack = false
    }

    function formatSleepTime(seconds) {
        var h = Math.floor(seconds / 3600)
        var m = Math.floor((seconds % 3600) / 60)
        var s = seconds % 60
        if (h > 0) {
            return h + ":" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
        }
        return m + ":" + (s < 10 ? "0" : "") + s
    }

    Timer {
        id: sleepTimer
        interval: 1000
        running: root.sleepTimerActive && !root.sleepStopAtEndOfTrack && player.playing
        repeat: true
        onTriggered: {
            if (root.sleepTimeLeft > 0) {
                root.sleepTimeLeft -= 1
                var fadeDuration = 30 // fade out in the last 30 seconds
                if (root.sleepFadeOut && root.sleepTimeLeft <= fadeDuration && player.playing) {
                    if (!root.sleepIsFading) {
                        root.sleepIsFading = true
                        root.sleepOriginalVolume = player.volume
                    }
                    var ratio = Math.max(0.0, root.sleepTimeLeft / fadeDuration)
                    player.setVolume(root.sleepOriginalVolume * ratio)
                } else if (root.sleepIsFading) {
                    // Timer adjusted back up! Restore volume
                    player.setVolume(root.sleepOriginalVolume)
                    root.sleepIsFading = false
                }
                if (root.sleepTimeLeft === 0) {
                    root.triggerSleepStop()
                }
            } else {
                root.triggerSleepStop()
            }
        }
    }

    Timer {
        id: volumeRestoreTimer
        interval: 300 // 300ms delay to allow playback to stop fully before restoring volume
        repeat: false
        property double originalVol: 1.0
        onTriggered: {
            player.setVolume(originalVol)
        }
    }

    Connections {
        target: player
        
        function onPositionChanged(ms) {
            if (player.duration > 0) {
                root.lastTrackPosition = ms
                root.lastTrackDuration = player.duration
                
                // End-of-track fade out logic (last 15 seconds)
                if (root.sleepTimerActive && root.sleepStopAtEndOfTrack && root.sleepFadeOut) {
                    var timeLeftMs = player.duration - ms
                    var fadeDurationMs = 15000 // 15s fade out
                    if (timeLeftMs > 0 && timeLeftMs <= fadeDurationMs) {
                        if (!root.sleepIsFading) {
                            root.sleepIsFading = true
                            root.sleepOriginalVolume = player.volume
                        }
                        var ratio = Math.max(0.0, timeLeftMs / fadeDurationMs)
                        player.setVolume(root.sleepOriginalVolume * ratio)
                    } else if (root.sleepIsFading) {
                        // User must have seeked back! Restore volume
                        player.setVolume(root.sleepOriginalVolume)
                        root.sleepIsFading = false
                    }
                }
            }
        }
        
        function onCurrentTrackChanged() {
            if (root.sleepTimerActive && root.sleepStopAtEndOfTrack) {
                // If it transitioned naturally, last known position was close to duration
                var finishedNaturally = (root.lastTrackDuration > 0) && (root.lastTrackDuration - root.lastTrackPosition < 2000)
                if (finishedNaturally) {
                    root.triggerSleepStop()
                }
            }
            root.lastTrackPosition = 0
            root.lastTrackDuration = 0
        }
    }

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
        // Fullscreen belongs to Now Playing. Following a link out of it - an
        // artist name, the album, the source it is playing from - brings the
        // window back first, so the user never lands on another page with no
        // chrome and no sidebar.
        if (page !== "nowplaying" && root.fullScreen) root.leaveFullScreen()

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
            } else {
                // Signing out drops the window on the login page, and every
                // way back out of fullscreen - Escape, F11, the page's own
                // toggle - is either gated on being signed in or on the page
                // that just went away. Leaving it here is what keeps that from
                // being a window only the window manager can rescue.
                root.leaveFullScreen()
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

        // Every sequence below comes out of the Shortcuts table in
        // src/ui/Shortcuts.cpp rather than being written here, because the
        // Settings panel prints the same list and the two used to be
        // independent literals that could drift - and did, silently, off Linux.
        // A new Shortcut belongs in that table first; tst_shortcuts.cpp fails on
        // one bound to a literal, and on a table entry with no row in Settings.

        // Playback Shortcuts
        Shortcut { sequence: Shortcuts.sequence("playPause");      context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.playPause() }
        Shortcut { sequence: Shortcuts.sequence("next"); context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.next() }
        Shortcut { sequence: Shortcuts.sequence("previous");  context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.previous() }
        Shortcut { sequence: Shortcuts.sequence("seekForward");      context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.seek(Math.min(player.duration, player.position + 10000)) }
        Shortcut { sequence: Shortcuts.sequence("seekBack");       context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.seek(Math.max(0, player.position - 10000)) }
        Shortcut { sequence: Shortcuts.sequence("volumeUp");         context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.setVolume(Math.min(1, player.volume + 0.05)) }
        Shortcut { sequence: Shortcuts.sequence("volumeDown");       context: Qt.ApplicationShortcut; enabled: auth.state === 2 && !root.isTypingContext(root.activeFocusItem); onActivated: player.setVolume(Math.max(0, player.volume - 0.05)) }
        Shortcut { sequence: Shortcuts.sequence("mute");     context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.setMuted(!player.muted) }
        Shortcut { sequence: Shortcuts.sequence("shuffle");     context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.setShuffle(!player.shuffle) }
        Shortcut { sequence: Shortcuts.sequence("repeat");     context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: player.setRepeatMode((player.repeatMode + 1) % 3) }

        // Navigation Shortcuts
        Shortcut { sequence: Shortcuts.sequence("home"); context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.navigate("home") }
        Shortcut { sequence: Shortcuts.sequence("search"); context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.navigate("search") }
        Shortcut { sequence: Shortcuts.sequence("collection"); context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.navigate("collection") }
        Shortcut {
            sequence: Shortcuts.sequence("nowPlaying")
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
        Shortcut { sequence: Shortcuts.sequence("fullScreen"); context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.toggleFullScreen() }
        Shortcut { sequence: Shortcuts.sequence("queue"); context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: root.queueOpen = !root.queueOpen }
        Shortcut { sequence: Shortcuts.sequence("settings"); context: Qt.ApplicationShortcut; enabled: auth.state === 2; onActivated: sideBar.openSettings() }
        Shortcut {
            sequence: Shortcuts.sequence("escape")
            context: Qt.ApplicationShortcut
            // An application shortcut outranks the key handling of an open
            // Popup, so while a modal is up this one has to stand down or
            // Escape would navigate back instead of dismissing it.
            //
            // Settings was missing from this list, and the bug was invisible
            // until someone signed in on the Debian box: the shortcut only
            // exists when `auth.state === 2`, so the whole class was
            // unreachable signed out. Escape over an open Settings panel
            // navigated the page back instead of closing it, which made its
            // own closePolicy's CloseOnEscape dead. Any Popup added here in
            // future has to be named on this line too.
            enabled: auth.state === 2 && !updatePrompt.visible
                     && !sideBar.settingsPanel.visible
            // Innermost first, so one Escape undoes one thing: the overlay on
            // top of the page, then the window state, then the page itself.
            // Leaving fullscreen before navigating matters because the two
            // together would drop the user on the previous page with no
            // chrome and no sidebar, which is not a state they asked for.
            onActivated: {
                if (root.queueOpen) root.queueOpen = false
                else if (root.fullScreen) root.leaveFullScreen()
                else if (root.detailPages.indexOf(root.currentPage) !== -1) root.goBack()
            }
        }
        Shortcut {
            sequence: Shortcuts.sequence("back")
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
                // Fullscreen means the page and nothing else; a Layout skips
                // an invisible item entirely, so the page gets the width back.
                visible: auth.state === 2 && !root.fullScreen
                // Above the content pane, so when the rail hover-expands it
                // covers the page instead of sliding under it (SPEC L4).
                z: 2
                // Compact mode follows the *window* width, and the slot the
                // layout reserves is the rail width while it is compact — the
                // expanded panel overflows that slot on purpose.
                hostWidth: root.width
                Layout.preferredWidth: sideBar.reservedWidth
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

                // Fills the content area: the panel is pinned to the right
                // inside it, and the rest is the scrim that stops clicks
                // reaching the page behind.
                QueuePanel {
                    id: queuePanel
                    anchors.fill: parent
                    visible:     root.queueOpen
                    onDismissed: root.queueOpen = false
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

    // Lives on the window, not on a page, so navigating cannot rebuild it and
    // bring it back; showIfAvailable() only ever answers yes once per launch.
    UpdatePrompt {
        id: updatePrompt
        // `updateCheck`, not `update`: see the comment where Application.cpp
        // installs it. Guarded because tests/tst_firstrun.cpp loads Main.qml
        // against the stub context, which has no update check in it, and that
        // test fails on any QML warning at all.
        check: (typeof updateCheck !== "undefined") ? updateCheck : null
    }

    // The cached answer is already in UpdateCheck by the time the engine runs,
    // so this is the launch the user was promised the prompt on. Whatever the
    // network says afterwards is for the next one.
    Component.onCompleted: updatePrompt.showIfAvailable()
}
