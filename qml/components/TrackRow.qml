import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import QtQml.Models
import TidalWave

Item {
    id: root
    height: 52
    // What the row needs before anything in it has to give way: the fixed
    // columns and gaps plus 120 for the title and artist line. Every list sets
    // an explicit width, so this is the floor.
    implicitWidth: 368

    // The five text inputs are `var`, not `string`: pages feed them straight
    // off an API map, and a missing or wrongly typed key against a string
    // property warns once per delegate per field. What to draw is decided here.
    property int    trackNum: 1
    property var    title
    property var    artists
    property var    albumTitle
    property var    durationStr
    property var    coverUrl
    // Draws the row as the playing one whatever the player holds; for
    // previews. A real row works it out from the player.
    property bool   isPlaying: false
    property bool   showAlbum: true
    property bool   showCover: true
    property var    trackData: null   // full track map (has albumId, id, etc.)

    // ── what a partial payload degrades to ──────────────────────────────
    // Only a non-empty string counts; anything else is "we were not told".
    function textOf(v) { return (typeof v === "string") ? v : "" }

    // Name the track and whoever made it, rather than leaving the row to read
    // as an empty stripe the user cannot tell from a loading placeholder.
    readonly property string titleText:   textOf(root.title)   || qsTr("Unknown track")
    readonly property string artistsText: textOf(root.artists) || qsTr("Unknown artist")
    // No honest stand-in exists for an album nobody named, and the column is
    // supplementary, so it stays empty rather than inventing one.
    readonly property string albumText:   textOf(root.albumTitle)
    // A length the payload forgot to pre-format is still in the map as whole
    // seconds, so recover it there before giving up on the column.
    readonly property string durationText: {
        var s = textOf(root.durationStr)
        if (s.length > 0) return s
        var secs = root.trackData ? Number(root.trackData.duration) : NaN
        if (!isFinite(secs) || secs <= 0) return ""
        return Theme.clock(secs * 1000)
    }
    readonly property string coverText:   textOf(root.coverUrl)

    // ── this track's radio, as a mix id ─────────────────────────────────
    // "" when the payload carried none, which is normal: not every listing
    // is known to include the `mixes` object, and a row built by hand has no
    // such key. A string of hex characters, so textOf() guards it.
    readonly property string trackMixId:
        root.trackData ? textOf(root.trackData.trackMixId) : ""

    // Opens this track's radio on MixPage when a mix id can be had, off the
    // payload or from one `tracks/<id>` lookup, and on RadioPage otherwise.
    // The reply touches nothing on `root`: the row may be recycled by then.
    function startRadio() {
        if (root.trackId <= 0) return
        var win = Window.window
        if (!win) return

        var id    = root.trackId
        var label = root.titleText
        // The title and mixType are handed over so the hero is not blank and
        // the heading reads "Radio" from the first frame.
        var toMix  = function (mixId) {
            win.navigate("mix", { mixId: mixId, title: label, mixType: "TRACK_MIX" })
        }
        var toList = function () {
            win.navigate("radio", { trackId: id, radioTitle: label })
        }

        if (root.trackMixId.length > 0) { toMix(root.trackMixId); return }

        bridge.fetchTrackMix(id, function (mixId, err) {
            // The shape is checked as well as the error: a reply that never
            // arrived leaves the argument undefined, and String(undefined)
            // would navigate to a mix called "undefined".
            if (!err && typeof mixId === "string" && mixId.length > 0) toMix(mixId)
            else                                                       toList()
        })
    }

    // ── who made it, name by name ───────────────────────────────────────
    // TidalBridge::trackToMap() carries the whole artist list as [{id, name}],
    // which makes each name its own link. A map without the field leaves this
    // empty and ArtistLinks falls back to the joined string and the lead id.
    readonly property var artistList:
        (root.trackData && root.trackData.artistList && root.trackData.artistList.length > 0)
            ? root.trackData.artistList : []

    readonly property real leadArtistId: {
        var n = root.trackData ? Number(root.trackData.artistId) : 0
        return isFinite(n) ? n : 0
    }

    // The credits the artist menu entry can offer: every one with a usable
    // id, in order. Without a list, the lead id is the one credit there is.
    readonly property var artistCredits: {
        var out = []
        var list = root.artistList
        for (var i = 0; i < list.length; i++) {
            var id = Number(list[i].id)
            if (id > 0) out.push({ id: id, name: String(list[i].name) })
        }
        if (out.length === 0 && root.leadArtistId > 0)
            out.push({ id: root.leadArtistId, name: root.artistsText })
        return out
    }

    // 0 when the payload carried no usable id, which is what every id-keyed
    // action below checks before offering itself.
    readonly property real trackId: {
        var n = root.trackData ? Number(root.trackData.id) : 0
        return isFinite(n) ? n : 0
    }

    // The player's track, playing or paused. A track Tidal does not stream
    // is played from its twin, which names this row's id as the one it stands for.
    readonly property bool isCurrent: root.isPlaying
        || (root.trackId > 0 && (Number(player.currentTrack.id) === root.trackId
                                 || Number(player.currentTrack.standsForId) === root.trackId))
    readonly property bool playsNow: root.isPlaying || (root.isCurrent && player.playing)

    // A click on the current track pauses or resumes it, and never starts it over.
    function activate() {
        if (root.isCurrent && !root.isPlaying) player.playPause()
        else root.playRequested()
    }

    property bool   isLiked: trackId > 0 ? bridge.isTrackFavorite(trackId) : false
    // Playlist context: set when TrackRow is inside a PlaylistPage
    property string playlistUuid: ""
    property int    trackItemIndex: -1  // 0-based position in playlist
    property bool   showPopularity: false
    // Download state for this row: "idle" | "busy" | "done" | "error"
    property string dlState: "idle"
    property string dlError: ""
    // The file this track was saved as since launch, "" if none or gone.
    property string savedFile: ""
    // A sentence to read, so it stays up as long as LoadErrorTip's.
    readonly property int dlErrorDwellMs: 6000

    // Column breakpoints, measured against the row's own width, not the
    // window's. The fixed columns add up to 472px with all of them on, so the
    // album column goes first at 640 and popularity at 560.
    readonly property int albumBreakpoint: 640
    readonly property int popularityBreakpoint: 560

    // Reads the row's hover state from outside, e.g. so a layout test can
    // check the title does not move when the pointer enters.
    readonly property alias hovered: hov.hovered

    Connections {
        target: bridge
        function onFavoriteTracksChanged() {
            root.isLiked = root.trackId > 0 ? bridge.isTrackFavorite(root.trackId) : false
        }
    }

    // Like/Unlike in the row menu, and what it says when the server refuses.
    // isLiked is read back from the bridge on the signal and never written by
    // the action. See ContextMenu.FavoriteAction.
    readonly property alias favoriteAction: trackFav
    ContextMenu.FavoriteAction { id: trackFav }

    // Reflect download progress for this track. Delegates are recycled on scroll,
    // so re-evaluate whenever trackData is (re)assigned.
    Connections {
        target: downloader
        function onDownloadStarted(id) {
            if (root.trackId > 0 && id === root.trackId) root.dlState = "busy"
        }
        function onDownloadFinished(id, path) {
            if (root.trackId > 0 && id === root.trackId) {
                root.dlState = "done"
                root.savedFile = path
                dlResetTimer.interval = 3000
                dlResetTimer.restart()
            }
        }
        function onDownloadError(id, msg) {
            if (root.trackId > 0 && id === root.trackId) {
                root.dlState = "error"
                root.dlError = msg
                dlResetTimer.interval = root.dlErrorDwellMs
                dlResetTimer.restart()
                root.showDownloadError()
            }
        }
    }
    Timer {
        id: dlResetTimer
        interval: 3000
        onTriggered: {
            if (root.dlState === "error") dlButton.ToolTip.hide()
            root.dlState = "idle"
            root.dlError = ""
        }
    }
    onTrackDataChanged: {
        if (root.dlState === "error") dlButton.ToolTip.hide()
        root.dlState = (root.trackId > 0 && downloader.isDownloading(root.trackId)) ? "busy" : "idle"
        root.dlError = ""
        root.savedFile = root.trackId > 0 ? downloader.savedPath(root.trackId) : ""
    }

    // Says why the download failed, over the red download button, as the
    // player bar says why a track would not load. Not while the row is off screen.
    function showDownloadError() {
        if (root.dlError === "" || !root.visible || !Window.window || !Window.window.visible) return
        dlButton.ToolTip.show(root.dlError, root.dlErrorDwellMs)
    }

    // Routing for the menu's artist rows. Asked from the row: a submenu is a
    // Popup, in no item's window until shown, so `Window.window` inside one
    // is null.
    function goToArtist(artistId) {
        if (artistId > 0 && Window.window)
            Window.window.navigate("artist", { artistId: artistId })
    }

    signal playRequested()
    signal menuRequested(real x, real y)
    signal removeFromPlaylistRequested(int itemIndex)

    // A list is one tab stop and the arrows walk it. In a ListView that is
    // the current row; rows laid out by a Repeater share a rowGroup
    // (an object with an int `current`) and say their rowIndex.
    property QtObject rowGroup: null
    property int      rowIndex: -1
    // activeFocus keeps the row a stop until it lets go: Qt refuses to clear
    // the flag on the focused item and would leave two stops behind.
    activeFocusOnTab: activeFocus || (ListView.view ? (ListView.isCurrentItem || ListView.view.currentIndex < 0)
                                      : rowGroup ? rowGroup.current === rowIndex : true)
    onActiveFocusChanged: {
        if (!activeFocus) return
        if (rowGroup) rowGroup.current = rowIndex
        else if (ListView.view)
            ListView.view.positionViewAtIndex(ListView.view.currentIndex, ListView.Contain)
    }
    // Space stays play/pause for the window (Main.qml reads this).
    readonly property bool leavesSpaceToPlayer: true
    Keys.onReturnPressed: root.activate()
    Keys.onEnterPressed:  root.activate()

    function moveToRow(target) {
        var view = ListView.view
        if (view) {
            var i = Math.max(0, Math.min(view.count - 1, target))
            view.currentIndex = i
            if (view.currentItem) view.currentItem.forceActiveFocus(Qt.TabFocusReason)
            return true
        }
        if (!rowGroup || !parent) return false
        var rows = parent.children
        for (var k = 0; k < rows.length; ++k) {
            var r = rows[k]
            if (r !== root && r.rowGroup === rowGroup && r.rowIndex === target && r.visible) {
                rowGroup.current = target
                r.forceActiveFocus(Qt.TabFocusReason)
                return true
            }
        }
        return false
    }
    function lastGroupIndex() {
        var last = rowIndex
        var rows = parent ? parent.children : []
        for (var k = 0; k < rows.length; ++k)
            if (rows[k].rowGroup === rowGroup && rows[k].visible) last = Math.max(last, rows[k].rowIndex)
        return last
    }

    // Read as one line of a list: what the eye takes from the title and the
    // names. Press is what a click does.
    Accessible.role: Accessible.ListItem
    Accessible.name: qsTr("%1, %2", "track row for a screen reader: title, artists")
                         .arg(root.titleText).arg(root.artistsText)
    Accessible.description: root.albumText.length > 0
                            ? qsTr("%1, %2", "track row for a screen reader: album, length")
                                  .arg(root.albumText).arg(root.durationText)
                            : root.durationText
    Accessible.onPressAction: root.activate()
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            root.menuRequested(width / 2, height / 2)
            root.openMenu(true)
            event.accepted = true
            return
        }
        if (event.modifiers !== Qt.NoModifier) return
        var view = ListView.view
        // A ListView walks Up and Down itself; Home and End it does not.
        if (event.key === Qt.Key_Home && (view || rowGroup))
            event.accepted = root.moveToRow(0)
        else if (event.key === Qt.Key_End && (view || rowGroup))
            event.accepted = root.moveToRow(view ? view.count - 1 : root.lastGroupIndex())
        else if (!view && rowGroup && event.key === Qt.Key_Down)
            event.accepted = root.moveToRow(rowIndex + 1)
        else if (!view && rowGroup && event.key === Qt.Key_Up)
            event.accepted = root.moveToRow(rowIndex - 1)
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.spaceHalf
        radius: Theme.radiusMedium
        color: root.isCurrent ? Theme.accentSoft
               : hov.hovered ? Theme.hoverFill : "transparent"
        border.width: root.activeFocus ? 2 : 0
        border.color: Theme.accent

        // The row's hover, as a handler and not the MouseArea's containsMouse:
        // the artist names are hit targets of their own, and a child MouseArea
        // takes the hover event off the item behind it.
        HoverHandler { id: rowHover }

        MouseArea {
            id: hov
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            readonly property bool hovered: rowHover.hovered

            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    root.openMenu()
                } else {
                    root.activate()
                }
            }
        }

        RowLayout {
            anchors { fill: parent; leftMargin: Theme.space3; rightMargin: Theme.space8 }
            spacing: Theme.space3

            // Track number / now playing indicator
            Item {
                width: 24
                Layout.alignment: Qt.AlignVCenter
                Text {
                    objectName: "trackRowNumber"
                    anchors.centerIn: parent
                    visible: !root.playsNow && !hov.hovered
                    text: root.trackNum
                    // A paused current track keeps its number, in the accent.
                    color: root.isCurrent ? Theme.accentText : Theme.textDim
                    font.pixelSize: Theme.fontMeta
                }
                VectorIcon.PlayingIndicator {
                    objectName: "trackRowPlayingIndicator"
                    anchors.centerIn: parent
                    visible: root.playsNow && !hov.hovered
                    animate: player.playing
                    width: 14
                    height: 14
                }
                // Replaces the track number on hover and is the row's primary
                // action. 18 fills the 24px slot without crowding it.
                VectorIcon {
                    objectName: "trackRowHoverPlay"
                    anchors.centerIn: parent
                    visible: hov.hovered
                    name: root.playsNow ? "pause" : "play"
                    color: Theme.textPrimary
                    width: 18
                    height: 18
                }
            }

            Rectangle {
                visible: showCover
                width: 36; height: 36; radius: Theme.radiusSmall
                color: Theme.surfaceHigh
                clip: true
                Image {
                    objectName: "trackRowCover"
                    anchors.fill: parent
                    source: root.coverText.length > 0 ? "image://tidal/" + root.coverText : ""
                    // Decoded at twice the 36px box, not the 320px the URL
                    // serves. Both dimensions: width alone reaches the provider
                    // as 72x0. Safe on a crop only because this art is square.
                    sourceSize: Qt.size(72, 72)
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                    mipmap: true
                }
            }

            // Title + artists
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space1
                Text {
                    objectName: "trackTitle"
                    Layout.fillWidth: true
                    text: root.titleText
                    color: root.isCurrent ? Theme.accentText : Theme.textPrimary
                    font.pixelSize: Theme.fontBody
                    elide: Text.ElideRight
                }
                // One hover target and one tab stop per artist. The row's
                // MouseArea is declared before the RowLayout holding this, so a
                // name takes the left click and a right click reaches the menu.
                ArtistLinks {
                    Layout.fillWidth: true
                    tabStops: false
                    namePrefix: "trackRow"
                    fontPixelSize: Theme.fontMeta
                    artistList: root.artistList
                    joinedText: root.artistsText
                    fallbackArtistId: root.leadArtistId
                }
            }

            // Album, the widest fixed column and the first to go when the row
            // gets narrow
            Text {
                objectName: "trackAlbumColumn"
                visible: showAlbum && root.width >= root.albumBreakpoint
                Layout.preferredWidth: 160
                text: root.albumText
                color: Theme.textSec
                font.pixelSize: Theme.fontMeta
                elide: Text.ElideRight
            }

            Text {
                objectName: "trackDuration"
                text: root.durationText
                color: Theme.textDim
                font.pixelSize: Theme.fontMeta
                Layout.preferredWidth: Math.max(40, implicitWidth)
                horizontalAlignment: Text.AlignRight
            }

            // Popularity, shown only when showPopularity is true (Search page)
            Text {
                id: popText
                objectName: "trackPopularityColumn"
                readonly property real score:
                    root.trackData ? Number(root.trackData.popularity) : NaN
                visible: root.showPopularity && root.width >= root.popularityBreakpoint
                         && isFinite(score) && score > 0
                // Guarded, or a payload without the field prints "NaN%".
                text: (isFinite(score) && score > 0)
                      ? qsTr("%1%").arg(score.toLocaleString(Qt.locale(), 'f', 0))
                      : ""
                color: Theme.textDim
                font.pixelSize: Theme.fontMicro
                Layout.preferredWidth: 40
                horizontalAlignment: Text.AlignRight
                ToolTip.visible: popHov.hovered && visible
                ToolTip.text: qsTr("Popularity")
                ToolTip.delay: Theme.tooltipDelay
                HoverHandler { id: popHov }
            }

            // Download button, shown on hover and kept while busy, done or in
            // error. The slot is always laid out and only the glyphs fade, so
            // the title does not jump under the cursor.
            Item {
                id: dlButton
                objectName: "trackDownloadButton"
                readonly property bool shown: hov.hovered || root.dlState !== "idle"
                opacity: shown ? 1 : 0
                Layout.preferredWidth: 24
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignVCenter

                VectorIcon {
                    anchors.centerIn: parent
                    visible: root.dlState === "idle" || root.dlState === "error"
                    name: "download"
                    color: root.dlState === "error" ? Theme.redText : Theme.textSec
                    width: 16; height: 16
                }
                VectorIcon {
                    anchors.centerIn: parent
                    visible: root.dlState === "done"
                    name: "check"
                    color: Theme.green
                    width: 16; height: 16
                }
                Item {
                    id: dlSpinner
                    anchors.centerIn: parent
                    width: 16; height: 16
                    visible: root.dlState === "busy"
                    Rectangle {
                        width: 3; height: 7; radius: width / 2
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: Theme.accent
                    }
                    // Still a visible busy mark under reduced motion, just a
                    // still one; see LoadingOverlay for why it is shaped this
                    // way rather than switched off.
                    RotationAnimator {
                        target: dlSpinner
                        from: 0; to: 360
                        duration: Theme.dur(Theme.motionSlow * 2)
                        loops: Theme.reduceMotion ? 1 : Animation.Infinite
                        running: root.dlState === "busy"
                    }
                }

                // Like the menu button: a plain click MouseArea with no hover
                // detection. Anything tracking hover on the button itself
                // desyncs from the row's hover and makes the button flicker.
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Theme.space1
                    enabled: dlButton.shown && root.dlState !== "busy" && root.trackId > 0
                    cursorShape: Qt.PointingHandCursor
                    // The tick, still up after a save, opens the file's folder.
                    onClicked: {
                        if (root.dlState === "done" && root.savedFile !== "")
                            downloader.showInFolder(root.savedFile)
                        else if (root.trackId > 0 && root.dlState !== "busy")
                            downloader.downloadTrack(root.trackData)
                    }
                }
            }

            // Context menu button, same reserved slot as the download button
            Item {
                id: menuButton
                objectName: "rowMenuButton"
                readonly property bool shown: hov.hovered || root.activeFocus
                opacity: shown ? 1 : 0
                Layout.preferredWidth: 24
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignVCenter
                VectorIcon {
                    anchors.centerIn: parent
                    name: "more"
                    color: Theme.textSec
                    width: 16
                    height: 16
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Theme.space1
                    enabled: menuButton.shown
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (m) => {
                        root.menuRequested(m.x, m.y)
                        root.openMenu()
                    }
                }
                HoverHandler { id: menuHov }
                ToolTip.visible: menuHov.hovered && menuButton.shown
                ToolTip.text: qsTr("More options", "button on a track row, opens its menu")
                ToolTip.delay: Theme.tooltipDelay
            }
        }
    }

    // The row's menu and the playlist picker are built the first time one is
    // asked for. A long track list would otherwise build a Menu and a Popup
    // per row for two things almost no row is asked for.
    readonly property alias rowMenu: menuLoader.item

    // From the keyboard the menu opens on the row; from the mouse, at the pointer.
    function openMenu(fromKeyboard) {
        // Asked again: the file may have been moved or deleted since.
        if (root.trackId > 0) root.savedFile = downloader.savedPath(root.trackId)
        menuLoader.active = true
        if (fromKeyboard) menuLoader.item.popup(root, 16, root.height)
        else menuLoader.item.popup()
    }

    function openPicker() {
        if (root.trackId <= 0) return
        pickerLoader.active = true
        pickerLoader.item.openFor(root.trackId)
    }

    // The new-playlist dialog, from the picker's first row. Its own Loader:
    // a Popup declared inside another Popup's contentData has no reliable
    // window to resolve `Overlay.overlay` against. Lazy like the menu.
    function openNewPlaylist() {
        if (root.trackId <= 0) return
        newPlaylistLoader.active = true
        newPlaylistLoader.item.openEmpty()
    }

    // A Popup reparents itself to the window overlay, so this is a test's only
    // handle on it. Null until the row has been asked for one.
    readonly property alias newPlaylistPopup: newPlaylistLoader.item

    // The picker, likewise. Null until the row has been asked for one.
    readonly property alias playlistPicker: pickerLoader.item

    Loader {
        id: newPlaylistLoader
        active: false
        sourceComponent: NewPlaylistDialog {
            objectName: "trackRowNewPlaylistDialog"
            onPlaylistCreated: function (playlist) {
                const uuid  = (playlist && playlist.uuid)  ? String(playlist.uuid) : ""
                const title = (playlist && playlist.title) ? playlist.title : ""
                // A playlist made from here gets the song straight away.
                if (uuid.length > 0 && root.trackId > 0) {
                    bridge.addTracksToPlaylist(uuid, root.trackId, function (ok) {
                        root.confirmAddedToPlaylist(ok === true, title)
                    })
                }
                if (pickerLoader.item) pickerLoader.item.close()
            }
        }
    }

    // The same confirmation the shared ContextMenu gives, drawn over the row
    // the user just acted on. The dwell is not Theme.dur(); see
    // ContextMenu.confirmMs.
    readonly property int confirmMs: 2000

    // What the last confirmation said, kept because the shared tool tip cannot
    // be read back. A test checks a failed add is not reported as a success.
    property string lastConfirmation: ""

    function confirm(text) {
        root.lastConfirmation = text
        ToolTip.show(text, root.confirmMs)
    }

    function confirmQueued(atFront) {
        root.confirm(atFront ? qsTr("%Ln track(s) added to play next", "queue confirmation", 1)
                             : qsTr("%Ln track(s) added to queue", "queue confirmation", 1))
    }

    // The same for the picker, for an existing playlist and for one made on
    // the spot. Reports what the server said, not what was asked for.
    function confirmAddedToPlaylist(ok, title) {
        root.confirm(ok ? qsTr("Added to “%1”",
                               "confirmation after adding a track to a playlist").arg(title)
                        : qsTr("Could not add the track to “%1”",
                               "shown when adding a track to a playlist failed").arg(title))
    }

    // The removal side, and the refusal only: on success the row leaving the
    // list is the confirmation.
    function confirmRemovedFromPlaylist(ok) {
        if (ok === true) return
        root.confirm(qsTr("Could not remove the track from the playlist",
                          "shown when removing a track from a playlist failed"))
    }

    Loader {
        id: menuLoader
        active: false
        // Parented to the row rather than to this Loader, which is a zero
        // sized item at the row's origin.
        sourceComponent: Menu {
            parent: root
            // The same arrival as every other menu in the app; see
            // ContextMenu.qml for why it is opacity and nothing else.
            enter: ContextMenu.OpenFade { }
            exit:  ContextMenu.CloseFade { }
            // Insets reset, not inherited; see ContextMenu.qml.
            leftInset: 0; rightInset: 0; topInset: 0; bottomInset: 0

            // Assigned where it exists (Qt 6.8); see ContextMenu.qml.
            Component.onCompleted: {
                if (this.popupType !== undefined) this.popupType = Popup.Item
            }
            implicitWidth: Theme.menuWidth(this)
            overlap: 0
            background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusLarge }

            // Qt 6.4 leaves the keyboard on the window when a menu closes;
            // later Qt gives it back to the item that had it, as this does.
            property Item focusBefore: null
            onAboutToShow: focusBefore = root.Window.window ? root.Window.window.activeFocusItem : null
            onClosed: {
                var w = root.Window.window
                if (focusBefore && focusBefore.visible && w
                        && (!w.activeFocusItem || w.activeFocusItem === w.contentItem))
                    focusBefore.forceActiveFocus()
                focusBefore = null
            }

            // So a test can read the two queue labels without walking a
            // popup's contents, the way ContextMenu exposes its pin item.
            readonly property alias playNextItem:   playNextEntry
            readonly property alias addToQueueItem: addToQueueEntry

            // The row that opens a submenu is never declared. A nested Menu's
            // row is built from the parent's `delegate`, with the submenu's
            // title as its text, and the artists submenu is the only one here.
            delegate: ContextMenu.Entry {
                id: artistSubRow
                objectName: "goToArtistSubMenuRow"
                iconName: "artist"
                // One credit is the direct action below, not a submenu.
                visible: root.artistCredits.length > 1
                height: visible ? implicitHeight : 0
                // Room for the arrow, which the style draws beside the content
                // item rather than inside it.
                rightPadding: Theme.space3 + Theme.space5
                arrow: VectorIcon {
                    visible: artistSubRow.subMenu
                    x: artistSubRow.width - width - 12
                    y: (artistSubRow.height - height) / 2
                    width: 14; height: 14
                    name: "chevron-right"
                    color: artistSubRow.ink
                }
            }

            ContextMenu.Entry {
                text: qsTr("Play now")
                iconName: "play"
                // On the current track it resumes a pause, and leaves it be if it plays.
                onTriggered: {
                    if (!root.isCurrent || root.isPlaying) root.playRequested()
                    else if (!player.playing) player.playPause()
                }
            }
            // Above Add to queue: of the two, playing the track next is what
            // a user reaches for more often.
            ContextMenu.Entry {
                id: playNextEntry
                objectName: "playNextMenuItem"
                enabled: root.trackData !== null
                text: qsTr("Play next", "verb, play this right after the current track")
                iconName: "next"
                onTriggered: {
                    if (!root.trackData) return
                    player.playNext([root.trackData])
                    root.confirmQueued(true)
                }
            }
            ContextMenu.Entry {
                id: addToQueueEntry
                objectName: "addToQueueMenuItem"
                enabled: root.trackData !== null
                text: qsTr("Add to queue", "verb, put this at the end of the queue")
                iconName: "queue"
                onTriggered: {
                    if (!root.trackData) return
                    player.addToQueue([root.trackData])
                    root.confirmQueued(false)
                }
            }
            ContextMenu.Entry {
                text: qsTr("Download…")
                iconName: "download"
                enabled: root.trackId > 0 && root.dlState !== "busy"
                onTriggered: { if (root.trackId > 0) downloader.downloadTrack(root.trackData) }
            }
            ContextMenu.Entry {
                objectName: "showInFolderMenuItem"
                text: qsTr("Show in folder", "opens the file manager at a downloaded track")
                iconName: "folder"
                visible: root.savedFile !== ""
                height: visible ? implicitHeight : 0
                enabled: root.savedFile !== ""
                onTriggered: downloader.showInFolder(root.savedFile)
            }
            ContextMenu.Entry {
                text: qsTr("Add to playlist")
                // The plus, not a second list glyph. "Add to queue" above it
                // already draws a list, and two lists one row apart at 16px
                // are one smudge twice.
                iconName: "plus"
                enabled: root.trackId > 0
                onTriggered: root.openPicker()
            }
            ContextMenu.Entry {
                objectName: "removeFromPlaylistMenuItem"
                text: qsTr("Remove from playlist")
                danger: true
                iconName: "trash"
                visible: root.playlistUuid.length > 0
                height: visible ? implicitHeight : 0
                enabled: root.trackData !== null && root.playlistUuid.length > 0
                onTriggered: {
                    if (root.trackData && root.playlistUuid.length > 0 && root.trackItemIndex >= 0)
                        root.removeFromPlaylistRequested(root.trackItemIndex)
                }
            }
            // Opens MixPage by the mix id, where the hero's Save pill can put
            // the station in the library and take it out again. See
            // root.startRadio().
            ContextMenu.Entry {
                objectName: "startRadioMenuItem"
                text: qsTr("Start radio")
                // What the queue heading already draws for a radio source;
                // see QueuePanel.contextGlyph.
                iconName: "waves"
                enabled: root.trackId > 0
                onTriggered: root.startRadio()
            }
            ContextMenu.Entry {
                objectName: "likeMenuItem"
                text: root.isLiked ? qsTr("Unlike", "verb, remove from favourites")
                                   : qsTr("Like", "verb, add to favourites")
                // Filled is the state it is in, so it is the row that undoes
                // it, the same pairing the pin row uses.
                iconName: root.isLiked ? "heart-filled" : "heart"
                enabled: root.trackId > 0
                // Over the row, not the menu entry: the menu has closed by the
                // time a refusal comes back, and a tool tip anchored to a
                // destroyed popup item has nowhere to draw.
                onTriggered: root.favoriteAction.toggleTrack(root.trackId, root.isLiked, root)
            }
            MenuSeparator { contentItem: Rectangle { height: 1; color: Theme.border } }
            ContextMenu.Entry {
                text: qsTr("Go to album")
                iconName: "album"
                enabled: root.trackData && Number(root.trackData.albumId) > 0
                onTriggered: {
                    if (root.trackData && Number(root.trackData.albumId) > 0)
                        Window.window.navigate("album", { albumId: Number(root.trackData.albumId) })
                }
            }
            // One credited artist, one action. Still shown but disabled when
            // the map carries no usable artist id at all.
            ContextMenu.Entry {
                objectName: "goToArtistMenuItem"
                text: qsTr("Go to artist")
                iconName: "artist"
                visible: root.artistCredits.length <= 1
                height: visible ? implicitHeight : 0
                enabled: root.artistCredits.length === 1
                onTriggered: {
                    if (root.artistCredits.length === 1)
                        root.goToArtist(root.artistCredits[0].id)
                }
            }
            // More than one, and the names go in a submenu rather than the one
            // row picking the lead for you. Its row in this menu comes from the
            // `delegate` above.
            Menu {
                id: artistSubMenu
                // A Popup is a QObject and not an Item, so it is in no item's
                // children; the objectName is how a test reaches it, the way
                // QueuePanel's per-row menu is reached.
                objectName: "goToArtistSubMenu"
                title: qsTr("Go to artist")

                // The same treatment as the menu above: insets reset,
                // popupType assigned where it exists, opacity-only fades.
                // See ContextMenu.qml.
                leftInset: 0; rightInset: 0; topInset: 0; bottomInset: 0
                Component.onCompleted: {
                    if (this.popupType !== undefined) this.popupType = Popup.Item
                }
                enter: ContextMenu.OpenFade { }
                exit:  ContextMenu.CloseFade { }
                implicitWidth: Theme.menuWidth(this)
                background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusLarge }

                // Instantiator and not a Repeater: a Repeater is an Item, so a
                // Menu would take it for an entry of its own. This is the shape
                // Qt documents for a menu whose rows are data.
                Instantiator {
                    model: root.artistCredits
                    delegate: ContextMenu.Entry {
                        objectName: "goToArtistCreditItem"
                        // No icon: the row above already says "artist", and the
                        // gutter is reserved per menu, so a submenu of bare
                        // names is not indented for nothing.
                        text: modelData.name
                        onTriggered: root.goToArtist(modelData.id)
                    }
                    onObjectAdded: (index, object) => artistSubMenu.insertItem(index, object)
                    onObjectRemoved: (index, object) => artistSubMenu.removeItem(object)
                }
            }
            MenuSeparator { contentItem: Rectangle { height: 1; color: Theme.border } }
            // No "/browse/" in the link: tidal.com redirects /browse/track/<id>
            // to /track/<id>, so the short form is the canonical one.
            ContextMenu.Entry {
                text: qsTr("Copy link")
                iconName: "copy"
                enabled: root.trackId > 0
                onTriggered: {
                    if (root.trackId > 0)
                        bridge.copyToClipboard("https://tidal.com/track/" + root.trackId)
                }
            }
        }
    }

    Loader {
        id: pickerLoader
        active: false
        sourceComponent: Popup {
            id: trackPicker
            anchors.centerIn: Overlay.overlay
            width: 340
            modal: true
            focus: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
            padding: 0
            property var pendingTrackId: 0

            // Only the user's own playlists: Tidal refuses a song for an
            // editorial one or another user's saved here.
            function fillFrom(pls) {
                plPickerModel.clear()
                for (var i = 0; i < pls.length; i++)
                    if (pls[i].editable === true) plPickerModel.append(pls[i])
            }

            // Filled from the bridge's cache, which is paged in at sign-in and
            // kept current. The fetch covers the empty case only: an empty
            // cache cannot be told from one the paging has not reached yet.
            function openFor(trackId) {
                pendingTrackId = trackId
                plPickerModel.clear()
                open()

                var cached = bridge.getUserPlaylists()
                if (cached && cached.length > 0) { fillFrom(cached); return }

                bridge.fetchUserPlaylists(function(pls, err) {
                    fillFrom(pls)
                }, 50, 0)
            }

            background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusLarge }

            Column {
                width: parent.width

                Item {
                    width: parent.width
                    height: 52
                    Text {
                        anchors.left: parent.left; anchors.leftMargin: Theme.space4
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Add to playlist")
                        color: Theme.textPrimary; font.pixelSize: Theme.fontTitle; font.bold: true
                    }
                    // ── the way out ──────────────────────────────────────
                    Item {
                        id: pickerClose
                        objectName: "pickerCloseButton"
                        anchors.right: parent.right; anchors.rightMargin: Theme.space3
                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        height: 32
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTranslate("NewPlaylistDialog", "Close", "button, closes the dialog")
                        Accessible.onPressAction: trackPicker.close()
                        Keys.onReturnPressed: trackPicker.close()
                        Keys.onEnterPressed:  trackPicker.close()
                        Keys.onSpacePressed:  trackPicker.close()

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusMedium
                            color: "transparent"
                            border.width: pickerClose.activeFocus ? 2 : 0
                            border.color: Theme.accent
                        }
                        VectorIcon {
                            anchors.centerIn: parent
                            name: "x"
                            width: 14; height: 14
                            color: pickerClose.activeFocus ? Theme.accentText
                                 : pickerCloseHov.hovered ? Theme.textPrimary
                                 : Theme.textSec
                        }
                        HoverHandler { id: pickerCloseHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: trackPicker.close() }
                    }
                }
                Rectangle { width: parent.width; height: 1; color: Theme.border }

                // ── "New playlist…", above the list it adds to ───────────
                // First in the popup: the list underneath scrolls, and a
                // row at the bottom of a scrolling list is rarely seen.
                Item {
                    id: pickerNewRow
                    objectName: "pickerNewPlaylistRow"
                    width: parent.width
                    height: 44
                    activeFocusOnTab: true
                    Keys.onReturnPressed: root.openNewPlaylist()
                    Keys.onEnterPressed:  root.openNewPlaylist()
                    Keys.onSpacePressed:  root.openNewPlaylist()
                    Accessible.role: Accessible.Button
                    Accessible.name: pickerNewLabel.text
                    Accessible.onPressAction: root.openNewPlaylist()

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Theme.space1
                        radius: Theme.radiusMedium
                        color: newPlHov.hovered ? Theme.hoverFill : "transparent"
                        border.width: pickerNewRow.activeFocus ? 2 : 0
                        border.color: Theme.accent

                        HoverHandler { id: newPlHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler  { onTapped: root.openNewPlaylist() }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space3
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space3
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.space3

                            // An outlined tile the size of the artwork below,
                            // so the labels line up, and plainly not a cover.
                            Rectangle {
                                width: 28
                                height: 28
                                radius: Theme.radiusSmall
                                color: "transparent"
                                border.width: 1
                                border.color: newPlHov.hovered ? Theme.accent : Theme.border
                                VectorIcon {
                                    anchors.centerIn: parent
                                    name: "plus"
                                    width: 13
                                    height: 13
                                    color: newPlHov.hovered ? Theme.accentText : Theme.textDim
                                }
                            }
                            Text {
                                id: pickerNewLabel
                                objectName: "pickerNewPlaylistLabel"
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("New playlist…")
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontMeta
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.border }

                ListView {
                    id: plPickerList
                    objectName: "pickerPlaylistList"
                    width: parent.width
                    height: Math.min(contentHeight, 300)
                    clip: true
                    model: ListModel { id: plPickerModel }
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Item {
                        id: pickRow
                        width: plPickerList.width
                        height: 44
                        function choose() {
                            var intoTitle = model.title
                            bridge.addTracksToPlaylist(model.uuid, trackPicker.pendingTrackId,
                                                       function (ok) {
                                root.confirmAddedToPlaylist(ok === true, intoTitle)
                            })
                            trackPicker.close()
                        }
                        // One tab stop for the list, the current row; the
                        // ListView walks it with Up and Down.
                        activeFocusOnTab: activeFocus || ListView.isCurrentItem || plPickerList.currentIndex < 0
                        Keys.onReturnPressed: choose()
                        Keys.onEnterPressed:  choose()
                        Keys.onSpacePressed:  choose()
                        Accessible.role: Accessible.ListItem
                        Accessible.name: model.title
                        Accessible.onPressAction: choose()
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Theme.space1
                            radius: Theme.radiusMedium
                            color: plHov2.hovered ? Theme.hoverFill : "transparent"
                            border.width: pickRow.activeFocus ? 2 : 0
                            border.color: Theme.accent
                            HoverHandler { id: plHov2 }
                            TapHandler { onTapped: pickRow.choose() }
                            Row {
                                anchors.left: parent.left; anchors.leftMargin: Theme.space3
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.space3
                                Rectangle {
                                    width: 28; height: 28; radius: Theme.radiusSmall; color: Theme.surface; clip: true
                                    Image {
                                        anchors.fill: parent
                                        source: model.coverUrl ? "image://tidal/" + model.coverUrl : ""
                                        // 28px box, doubled; see the row cover above.
                                        sourceSize: Qt.size(56, 56)
                                        fillMode: Image.PreserveAspectCrop; smooth: true
                                    }
                                }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spaceHalf
                                    Text {
                                        objectName: "pickerRowTitle"
                                        text: model.title; color: Theme.textPrimary; font.pixelSize: Theme.fontMeta
                                    }
                                    // Named so a test can read what the row
                                    // actually draws.
                                    Text {
                                        objectName: "pickerRowTrackCount"
                                        text: qsTr("%Ln track(s)", "", model.numTracks)
                                        color: Theme.textSec; font.pixelSize: Theme.fontMicro
                                    }
                                }
                            }
                        }
                    }
                }

                Item { width: parent.width; height: Theme.space2 }
            }
        }
    }
}
