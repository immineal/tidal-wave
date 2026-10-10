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
    // 640 is the narrow end the layout is built for.
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

    // ─── Where back goes ───────────────────────────────────────────────────
    // A stack of (page, params) pairs. The top is where one back goes. Arriving
    // at a top-level destination empties it (see navigate), so it is as deep as
    // the chain of links followed since the sidebar was last used.
    property var navHistory: []

    // A chain of links can be followed forever and this process lives in the
    // tray for days, so the oldest entry is dropped at the ceiling.
    readonly property int maxNavHistory: 32

    // The params `currentPage` was reached with, kept so that leaving it can
    // push the pair and not the page on its own.
    property var _currentNavParams: ({})

    // ─── Now Playing's way in and out ──────────────────────────────────
    // It rises out of the player bar and sinks back into it. Hosted here
    // because the Loader has to outlive `currentPage`: the page stays on screen
    // for the slide out, after the window has moved on.
    property real nowPlayingness: currentPage === "nowplaying" ? 1 : 0
    // A Behavior does not run on a binding's first evaluation, so a window that
    // somehow starts on Now Playing starts with it up rather than sliding it in.
    Behavior on nowPlayingness {
        NumberAnimation { duration: Theme.dur(190); easing.type: Easing.OutCubic }
    }

    // ─── Fullscreen ────────────────────────────────────
    // Now Playing can take the whole screen. Only the window can drop its
    // chrome and hide the sidebar, so the page asks through Window.window.
    // The state to come back to is remembered: it may have been Maximized.
    property int preFullScreenVisibility: Window.Windowed

    // Going fullscreen also opens Now Playing (see toggleFullScreen), so coming
    // back has to know whether the page was already open.
    property bool preFullScreenNowPlaying: true

    // Written where the state changes, not bound to `visibility`: on Qt 6.4
    // visibilityChanged arrives after the turn the write happens in, and a
    // binding would read the old value for the rest of that turn.
    property bool fullScreen: visibility === Window.FullScreen

    // Still follows the window, since the window manager has its own ways out
    // of fullscreen. Read from `visibility`, not the signal's argument, which
    // can be stale on 6.4.
    onVisibilityChanged: (vis) => {
        root.fullScreen = (root.visibility === Window.FullScreen)
    }

    function enterFullScreen() {
        if (root.fullScreen) return
        // Hidden, Minimized and AutomaticVisibility are not states to come
        // back to; anything but Maximized returns to a normal window.
        root.preFullScreenVisibility =
            (root.visibility === Window.Maximized) ? Window.Maximized : Window.Windowed
        root.preFullScreenNowPlaying = (root.currentPage === "nowplaying")
        root.visibility = Window.FullScreen
        root.fullScreen = true
    }

    function leaveFullScreen() {
        if (!root.fullScreen) return
        root.visibility = root.preFullScreenVisibility
        root.fullScreen = false
    }

    // Also the F11 handler, so it navigates to Now Playing. The second press
    // undoes that navigation only if the first press made it and Now Playing is
    // still on screen.
    function toggleFullScreen() {
        if (root.fullScreen) {
            root.leaveFullScreen()
            if (!root.preFullScreenNowPlaying && root.currentPage === "nowplaying")
                root.goBack()
            return
        }
        // The window first: enterFullScreen() records the page being covered.
        root.enterFullScreen()
        if (root.currentPage !== "nowplaying") root.navigate("nowplaying")
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
        if (page === "nowplaying") return nowPlayingLoader
        if (["album", "artist", "playlist", "mix"].indexOf(page) !== -1) return detailLoader
        return null
    }

    // Pages a user can be inside of, where one consistent back action (button,
    // Escape, Alt+Left) makes sense. Top-level destinations are reached from
    // the sidebar and get no back affordance.
    readonly property var detailPages: ["album", "artist", "playlist", "mix", "nowplaying", "radio"]

    // The other side of that line, and the bottom of the back history: these
    // are reached in one press from the sidebar (and from Ctrl+H/Ctrl+F/Ctrl+L),
    // so there is never a chain of them to walk back through.
    readonly property var topLevelPages: ["home", "search", "collection"]

    // `fromHistory` is goBack()'s alone: it stops a back step from recording
    // the page it is leaving.
    function navigate(page, params, fromHistory) {
        // Fullscreen belongs to Now Playing. A link out of it brings the window
        // back first, so no other page is left without chrome and sidebar.
        if (page !== "nowplaying" && root.fullScreen) root.leaveFullScreen()

        var p = params || {}
        if (!fromHistory) {
            if (root.topLevelPages.indexOf(page) !== -1) {
                // A sidebar destination is the bottom of history, so arriving
                // there empties the stack. Signing in lands here too.
                root.navHistory = []
            } else if (root._isTopOfHistory(page, p)) {
                // Navigating onto the page that back would return to is a back
                // step, so unwind. The top entry only: a match further down is
                // a page the user has since walked away from.
                root.navHistory = root.navHistory.slice(0, -1)
            } else if (currentPage !== ""
                       && (page !== currentPage
                           || !root._sameNavParams(_currentNavParams, p))) {
                // A different page, or the same page type with different
                // params. Same page and params is a reload (below), which
                // blanks currentPage for a turn, hence the `!== ""`.
                root._pushHistory(currentPage, _currentNavParams)
            }
        }
        _currentNavParams = p

        var targetLoader = getLoader(page)
        if (targetLoader) {
            if (currentPage === page
                && ["home", "search", "collection", "nowplaying"].indexOf(page) === -1) {
                // Force reload of the same detail page type by toggling state
                var savedPage = currentPage
                currentPage = ""
                currentPage = savedPage
            }
            // home/search/collection have a fixed `source`, so their item
            // always matches the target. detailLoader's item matches only when
            // it already shows that page type; otherwise pageParams holds them.
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
            // Then the field inside it: the Loader, the page root and the bar's
            // input share one focus scope, so the line above only makes the
            // Loader the focus item.
            if (searchLoader.item && typeof searchLoader.item.takeFocus === "function") {
                searchLoader.item.takeFocus()
            }
        } else {
            focusStealer.forceActiveFocus()
        }
    }

    // A copy and an assignment: push() in place changes nothing the property's
    // change signal can see.
    function _pushHistory(page, params) {
        var h = root.navHistory.slice()
        h.push({ page: page, params: params || {} })
        if (h.length > root.maxNavHistory)
            h.splice(0, h.length - root.maxNavHistory)
        root.navHistory = h
    }

    function _isTopOfHistory(page, params) {
        if (root.navHistory.length === 0) return false
        var top = root.navHistory[root.navHistory.length - 1]
        return top.page === page && root._sameNavParams(top.params, params)
    }

    // Shallow, because every params object in the app is flat. Strict: a
    // playlist opened with a cover and the same one without do not draw the
    // same page, so both entries stay.
    function _sameNavParams(a, b) {
        var x = a || {}, y = b || {}
        for (var k in x) if (x[k] !== y[k]) return false
        for (var k2 in y) if (!(k2 in x)) return false
        return true
    }

    function goBack() {
        if (root.navHistory.length === 0) {
            // Nothing recorded. Back is a visible affordance and has to do
            // something, and home is where the app starts.
            root.navigate("home")
            return
        }
        var h = root.navHistory.slice()
        var entry = h.pop()
        root.navHistory = h
        root.navigate(entry.page, entry.params, true)
    }

    Connections {
        target: auth
        function onStateChanged(state) {
            if (state === 2) {
                root.navigate("home")
            } else {
                // Signing out lands on the login page, where every way out of
                // fullscreen is gated on being signed in.
                root.leaveFullScreen()
                // The history belongs to the session that just ended.
                root.navHistory = []
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

        // Every sequence below comes from the Shortcuts table in
        // src/ui/Shortcuts.cpp, which the Settings panel prints too. A new
        // Shortcut goes there first: tst_shortcuts.cpp fails on a literal.

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
            // Popup, so this one stands down while a modal is up. Any Popup
            // added in future has to be named on this line too.
            enabled: auth.state === 2 && !updatePrompt.visible
                     && !sideBar.settingsPanel.visible
            // Innermost first, so one Escape undoes one thing: the queue
            // overlay, then fullscreen, then the page.
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
                // Above the content pane, so the hover-expanded rail covers the
                // page instead of sliding under it.
                z: 2
                // Compact mode follows the window width. The layout reserves
                // only the rail width while compact, and the expanded panel
                // overflows that slot on purpose.
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
                        visible: ["home", "search", "collection",
                                  "nowplaying"].indexOf(root.currentPage) === -1
                        active: auth.state === 2
                        source: {
                            if (!active) return ""
                            switch (root.currentPage) {
                                case "album":      return "pages/AlbumPage.qml"
                                case "artist":     return "pages/ArtistPage.qml"
                                case "playlist":   return "pages/PlaylistPage.qml"
                                case "mix":        return "pages/MixPage.qml"
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

                    // `active` follows the slide and not `currentPage`, so the
                    // page is still there to sink back into the bar. Declared
                    // last, so it rises over the page it was opened from.
                    Loader {
                        id: nowPlayingLoader
                        anchors.fill: parent
                        source: "pages/NowPlayingPage.qml"
                        active: auth.state === 2
                                && (root.currentPage === "nowplaying"
                                    || root.nowPlayingness > 0.001)
                        visible: active
                        // A transform, not a y offset: the geometry the page's
                        // breakpoint reads stays put mid-slide.
                        transform: Translate {
                            y: (1 - root.nowPlayingness) * nowPlayingLoader.height
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
                    // `open`, not `visible`: the panel slides in and out, so it
                    // stays visible for as long as that takes.
                    open:        root.queueOpen
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
        // `updateCheck`, not `update`. Guarded because a host without that
        // context property would otherwise raise a QML warning.
        check: (typeof updateCheck !== "undefined") ? updateCheck : null
    }

    // The cached answer is already in UpdateCheck when the engine runs.
    // Whatever the network says afterwards is for the next launch.
    Component.onCompleted: updatePrompt.showIfAvailable()
}
