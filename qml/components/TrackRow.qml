import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Item {
    id: root
    height: 52
    // What the row needs before anything in it has to give way: the fixed
    // columns and gaps (12+24+12+36+12 ... +40+12+24+12+24+28) plus 120 for
    // the title and artist line. It was 100, which is less than the fixed
    // columns alone, so a host that sized a row by its implicit width got one
    // whose contents overflowed it. Every list sets an explicit width, so
    // this is the floor and not the usual case.
    implicitWidth: 368

    // The five text inputs are `var`, not `string`, on purpose. Every page
    // feeds them straight off an API map (`title: modelData.title`), and a
    // truncated or timed-out response simply has no such key: against a string
    // property that is one "Unable to assign [undefined] to QString" per
    // delegate per field, and a row of empty columns. A wrongly typed field
    // (an object where a name was expected) warned the same way. Taking them
    // as `var` and deciding what to draw here means one place does it for all
    // seven pages, instead of a guard at every call site.
    property int    trackNum: 1
    property var    title
    property var    artists
    property var    albumTitle
    property var    durationStr
    property var    coverUrl
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
        return Math.floor(secs / 60) + ":" + ("0" + Math.floor(secs % 60)).slice(-2)
    }
    readonly property string coverText:   textOf(root.coverUrl)

    // 0 when the payload carried no usable id, which is what every id-keyed
    // action below checks before offering itself.
    readonly property real trackId: {
        var n = root.trackData ? Number(root.trackData.id) : 0
        return isFinite(n) ? n : 0
    }

    property bool   isLiked: trackId > 0 ? bridge.isTrackFavorite(trackId) : false
    // Playlist context: set when TrackRow is inside a PlaylistPage
    property string playlistUuid: ""
    property int    trackItemIndex: -1  // 0-based position in playlist
    property bool   showPopularity: false
    // Download state for this row: "idle" | "busy" | "done" | "error"
    property string dlState: "idle"
    property string dlError: ""

    // Column breakpoints, measured against the row's own width rather than the
    // window's: the row is handed the list width less an inset, and the sidebar
    // has already taken its share. The fixed columns add up to 472px with every
    // one of them on, so at a 640px row the title and artist line are down to
    // ~168px: the 160px album column is the first thing not worth its space.
    // Dropping it leaves 312px of fixed columns, and popularity goes at 560,
    // which keeps the title above 250px all the way down.
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

    // Reflect download progress for this track. Delegates are recycled on scroll,
    // so re-evaluate whenever trackData is (re)assigned.
    Connections {
        target: downloader
        function onDownloadStarted(id) {
            if (root.trackId > 0 && id === root.trackId) root.dlState = "busy"
        }
        function onDownloadFinished(id, path) {
            if (root.trackId > 0 && id === root.trackId) { root.dlState = "done"; dlResetTimer.restart() }
        }
        function onDownloadError(id, msg) {
            if (root.trackId > 0 && id === root.trackId) { root.dlState = "error"; root.dlError = msg; dlResetTimer.restart() }
        }
    }
    Timer { id: dlResetTimer; interval: 3000; onTriggered: root.dlState = "idle" }
    onTrackDataChanged: {
        root.dlState = (root.trackId > 0 && downloader.isDownloading(root.trackId)) ? "busy" : "idle"
        root.dlError = ""
    }

    signal playRequested()
    signal menuRequested(real x, real y)
    signal removeFromPlaylistRequested(int itemIndex)

    activeFocusOnTab: true
    Keys.onReturnPressed: root.playRequested()
    Keys.onSpacePressed:  root.playRequested()
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            root.menuRequested(width / 2, height / 2)
            root.openMenu()
            event.accepted = true
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: Theme.radiusRow
        color: isPlaying ? Theme.accentSoft
               : hov.hovered ? Theme.surfaceHov : "transparent"
        border.width: root.activeFocus ? 2 : 0
        border.color: Theme.accent

        MouseArea {
            id: hov
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            readonly property bool hovered: containsMouse

            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    root.openMenu()
                } else {
                    root.playRequested()
                }
            }
        }

        RowLayout {
            anchors { fill: parent; leftMargin: 12; rightMargin: 28 }
            spacing: 12

            // Track number / now playing indicator
            Item {
                width: 24
                Layout.alignment: Qt.AlignVCenter
                Text {
                    anchors.centerIn: parent
                    visible: !isPlaying && !hov.hovered
                    text: root.trackNum
                    color: Theme.textDim
                    font.pixelSize: 13
                }
                // The one row that is playing, in the album and playlist
                // track lists as well as everywhere else TrackRow is used.
                // It used to be a note, which said "this is a song" on a row
                // that was already a song. Bars that move say the thing the
                // row cannot: this is the one you are hearing.
                VectorIcon.PlayingIndicator {
                    objectName: "trackRowPlayingIndicator"
                    anchors.centerIn: parent
                    visible: isPlaying && !hov.hovered
                    animate: player.playing
                    width: 14
                    height: 14
                }
                // Bigger than the 13px it was. This glyph replaces the track
                // number on hover and is the row's primary action, so it was
                // reading as smaller than the number it covers; 18 fills the
                // 24px slot without crowding it.
                VectorIcon {
                    objectName: "trackRowHoverPlay"
                    anchors.centerIn: parent
                    visible: hov.hovered
                    name: isPlaying ? "pause" : "play"
                    color: Theme.textPrimary
                    width: 18
                    height: 18
                }
            }

            // Cover art
            Rectangle {
                visible: showCover
                width: 36; height: 36; radius: Theme.radiusArt
                color: Theme.surfaceHigh
                clip: true
                Image {
                    anchors.fill: parent
                    source: root.coverText.length > 0 ? "image://tidal/" + root.coverText : ""
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                    mipmap: true
                }
            }

            // Title + artists
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                Text {
                    objectName: "trackTitle"
                    Layout.fillWidth: true
                    text: root.titleText
                    color: isPlaying ? Theme.accent : Theme.textPrimary
                    font.pixelSize: 14
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: root.artistsText
                    color: Theme.textSec
                    font.pixelSize: 12
                    elide: Text.ElideRight
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
                font.pixelSize: 13
                elide: Text.ElideRight
            }

            // Duration
            Text {
                text: root.durationText
                color: Theme.textDim
                font.pixelSize: 13
                Layout.preferredWidth: 40
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
                font.pixelSize: 11
                Layout.preferredWidth: 40
                horizontalAlignment: Text.AlignRight
                ToolTip.visible: popHov.hovered && visible
                ToolTip.text: qsTr("Popularity")
                ToolTip.delay: 400
                HoverHandler { id: popHov }
            }

            // Download button, revealed on hover; stays shown while busy/done/error.
            // The slot itself is always laid out: taking it out of the row when
            // the pointer left re-flowed the row and made the title jump under
            // the cursor, so only the glyphs fade.
            Item {
                id: dlButton
                readonly property bool shown: hov.hovered || root.dlState !== "idle"
                opacity: shown ? 1 : 0
                Layout.preferredWidth: 24
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignVCenter

                // idle / error glyph (error tints red)
                VectorIcon {
                    anchors.centerIn: parent
                    visible: root.dlState === "idle" || root.dlState === "error"
                    name: "download"
                    color: root.dlState === "error" ? Theme.red : Theme.textSec
                    width: 16; height: 16
                    strokeWidth: 1.8
                }
                // done glyph
                VectorIcon {
                    anchors.centerIn: parent
                    visible: root.dlState === "done"
                    name: "check"
                    color: Theme.green
                    width: 16; height: 16
                    strokeWidth: 2
                }
                // busy spinner (matches LoadingOverlay idiom)
                Item {
                    id: dlSpinner
                    anchors.centerIn: parent
                    width: 16; height: 16
                    visible: root.dlState === "busy"
                    Rectangle {
                        width: 3; height: 7; radius: 1.5
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
                        duration: Theme.dur(800)
                        loops: Theme.reduceMotion ? 1 : Animation.Infinite
                        running: root.dlState === "busy"
                    }
                }

                // Mirror the menu button exactly: a plain click MouseArea with NO
                // hover detection. Anything that tracks hover on the button itself
                // (hoverEnabled MouseArea or a HoverHandler) desyncs from the row's
                // hover and makes the button flicker/shift as it toggles.
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    enabled: dlButton.shown && root.dlState !== "busy" && root.trackId > 0
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (root.trackId > 0 && root.dlState !== "busy")
                            downloader.downloadTrack(root.trackData)
                    }
                }
            }

            // Context menu button, same reserved slot as the download button
            Item {
                id: menuButton
                readonly property bool shown: hov.hovered
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
                    anchors.margins: -4
                    enabled: menuButton.shown
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (m) => {
                        root.menuRequested(m.x, m.y)
                        root.openMenu()
                    }
                }
            }
        }
    }

    // The row's menu and the playlist picker it opens are built the first
    // time one of them is asked for. The track lists are stress-tested at
    // 5000 rows (X4), and a Menu of a dozen items plus a Popup holding a
    // ListView, on every one of them, is tens of thousands of objects built
    // for two things almost no row is ever asked for.
    readonly property alias rowMenu: menuLoader.item

    function openMenu() {
        menuLoader.active = true
        menuLoader.item.popup()
    }

    function openPicker() {
        if (root.trackId <= 0) return
        pickerLoader.active = true
        pickerLoader.item.openFor(root.trackId)
    }

    // The same confirmation the shared ContextMenu gives, and for the same
    // reason: queueing without a sign it worked is how a track ends up in
    // the queue twice. Drawn over the row the user just acted on. The dwell
    // is deliberately not Theme.dur() - see ContextMenu.confirmMs.
    readonly property int confirmMs: 2000

    function confirmQueued(atFront) {
        ToolTip.show(atFront ? qsTr("%n track(s) added to play next", "queue confirmation", 1)
                             : qsTr("%n track(s) added to queue", "queue confirmation", 1),
                     root.confirmMs)
    }

    Loader {
        id: menuLoader
        active: false
        // Parented to the row rather than to this Loader, which is a zero
        // sized item at the row's origin.
        sourceComponent: Menu {
            parent: root
            // Insets reset, not inherited. A Menu's insets exist for a style's drop
            // shadow, and the native macOS style sets all four to -32; this menu
            // replaces the background with its own Rectangle and never drew that
            // shadow, so the panel was laid out 32px past the popup on every side and
            // real entries were clipped at the window edge (a 207x56 popup drawing a
            // 271x120 background). Pinning the Basic style fixes it today, because
            // Basic's insets are 0; stating it here is what survives the next style
            // change, and it is a no-op wherever they already are 0.
            leftInset: 0; rightInset: 0; topInset: 0; bottomInset: 0

            // Set here rather than declaratively, and only where it exists.
            //
            // `popupType` and `Popup.Item` are both Qt 6.8. A declarative
            // `popupType: Popup.Item` is resolved when the file loads, so on
            // older Qt it does not merely warn - it makes this whole type
            // unavailable, and every type that uses it, all the way up. A real
            // Debian 12 build failed exactly that way: "Cannot assign to
            // non-existent property popupType", then "Type ContextMenu
            // unavailable", then "Type SideBar unavailable", and the app exited
            // with no window.
            //
            // Nothing is lost by leaving it unset on older Qt, because before
            // 6.8 an in-scene item was a menu's only form - the property was
            // added to allow native and separate-window popups, which arrived
            // with it. So this asks whether the property exists and sets it when
            // it does, which is the behaviour we want on both.
            //
            // `this.` is load-bearing. A *bare* identifier that names no property is
            // not undefined in QML's JS scope, it is a ReferenceError - and the error
            // aborts the whole handler rather than warning, at every instantiation,
            // which for a per-row menu is a stream of them. Qualifying the access
            // makes the miss a plain undefined. Worth knowing that this is invisible
            // on a current Qt, where the property exists and the bare form resolves
            // fine.
            Component.onCompleted: {
                if (this.popupType !== undefined) this.popupType = Popup.Item
            }
            implicitWidth: Theme.menuWidth(this)
            overlap: 0
            background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }

            // So a test can read the two queue labels without walking a
            // popup's contents, the way ContextMenu exposes its pin item.
            readonly property alias playNextItem:   playNextEntry
            readonly property alias addToQueueItem: addToQueueEntry

            ContextMenu.Entry {
                text: qsTr("Play now")
                iconName: "play"
                onTriggered: root.playRequested()
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
            ContextMenu.Entry {
                text: qsTr("Start radio")
                // What the queue heading already draws for a radio source;
                // see QueuePanel.contextGlyph.
                iconName: "waves"
                enabled: root.trackId > 0
                onTriggered: {
                    if (root.trackId <= 0) return
                    Window.window.navigate("radio", {
                        trackId:    root.trackId,
                        radioTitle: root.titleText
                    })
                }
            }
            ContextMenu.Entry {
                text: root.isLiked ? qsTr("Unlike", "verb, remove from favourites")
                                   : qsTr("Like", "verb, add to favourites")
                // Filled is the state it is in, so it is the row that undoes
                // it -- the same pairing the pin row uses.
                iconName: root.isLiked ? "heart-filled" : "heart"
                enabled: root.trackId > 0
                onTriggered: {
                    if (root.trackId <= 0) return
                    if (root.isLiked) {
                        bridge.removeTrackFavorite(root.trackId, function(success) {})
                    } else {
                        bridge.addTrackFavorite(root.trackId, function(success) {})
                    }
                }
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
            ContextMenu.Entry {
                text: qsTr("Go to artist")
                iconName: "artist"
                enabled: root.trackData && Number(root.trackData.artistId) > 0
                onTriggered: {
                    if (root.trackData && Number(root.trackData.artistId) > 0)
                        Window.window.navigate("artist", { artistId: Number(root.trackData.artistId) })
                }
            }
            MenuSeparator { contentItem: Rectangle { height: 1; color: Theme.border } }
            ContextMenu.Entry {
                text: qsTr("Copy link")
                iconName: "copy"
                enabled: root.trackId > 0
                onTriggered: {
                    if (root.trackId > 0)
                        bridge.copyToClipboard("https://tidal.com/browse/track/" + root.trackId)
                }
            }
        }
    }

    // Playlist picker popup (for "Add to playlist")
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

            function openFor(trackId) {
                pendingTrackId = trackId
                plPickerModel.clear()
                open()
                bridge.fetchUserPlaylists(function(pls, err) {
                    plPickerModel.clear()
                    for (var i = 0; i < pls.length; i++) {
                        plPickerModel.append(pls[i])
                    }
                }, 50, 0)
            }

            background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }

            Column {
                width: parent.width

                Item {
                    width: parent.width
                    height: 52
                    Text {
                        anchors.left: parent.left; anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Add to playlist")
                        color: Theme.textPrimary; font.pixelSize: 15; font.bold: true
                    }
                    VectorIcon {
                        anchors.right: parent.right; anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        name: "x"; color: Theme.textSec; width: 12; height: 12; strokeWidth: 2
                        MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: trackPicker.close() }
                    }
                }
                Rectangle { width: parent.width; height: 1; color: Theme.border }

                ListView {
                    id: plPickerList
                    width: parent.width
                    height: Math.min(contentHeight, 300)
                    clip: true
                    model: ListModel { id: plPickerModel }
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Item {
                        width: plPickerList.width
                        height: 44
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 4
                            radius: Theme.radiusRow
                            color: plHov2.hovered ? Theme.surfaceHov : "transparent"
                            HoverHandler { id: plHov2 }
                            TapHandler {
                                onTapped: {
                                    bridge.addTracksToPlaylist(model.uuid, trackPicker.pendingTrackId, function(ok) {})
                                    trackPicker.close()
                                }
                            }
                            Row {
                                anchors.left: parent.left; anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10
                                Rectangle {
                                    width: 28; height: 28; radius: Theme.radiusArt; color: Theme.surface; clip: true
                                    Image {
                                        anchors.fill: parent
                                        source: model.coverUrl ? "image://tidal/" + model.coverUrl : ""
                                        fillMode: Image.PreserveAspectCrop; smooth: true
                                    }
                                }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1
                                    Text { text: model.title; color: Theme.textPrimary; font.pixelSize: 13 }
                                    Text { text: qsTr("%n track(s)", "", model.numTracks); color: Theme.textSec; font.pixelSize: 11 }
                                }
                            }
                        }
                    }
                }

                Item { width: parent.width; height: 8 }
            }
        }
    }
}
