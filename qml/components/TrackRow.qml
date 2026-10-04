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

    // ── who made it, name by name ───────────────────────────────────────
    //
    // TidalBridge::trackToMap() carries the whole artist list as [{id, name}],
    // which is what makes each name its own link (SPEC N2). textOf() above
    // cannot carry it: it answers with a string or nothing, on purpose.
    //
    // A map without the field — a recently-played entry restored from disk,
    // anything a caller builds by hand — leaves this empty and ArtistLinks
    // falls back to the joined `artists` string and the lead id.
    readonly property var artistList:
        (root.trackData && root.trackData.artistList && root.trackData.artistList.length > 0)
            ? root.trackData.artistList : []

    readonly property real leadArtistId: {
        var n = root.trackData ? Number(root.trackData.artistId) : 0
        return isFinite(n) ? n : 0
    }

    // The credits the "Go to artist" menu entry can actually offer: every one
    // with a usable id, in order. A credit with no id is dropped rather than
    // becoming a row that does nothing, the same way the text links skip it
    // for tab focus. When the map carries no list at all, the lead id is the
    // one credit there is.
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

    // Like/Unlike in the row menu, and what it says when the server refuses.
    // isLiked above is read back from the bridge on the signal and never
    // written by the action, so a refusal has nothing to undo - only something
    // to say. See ContextMenu.FavoriteAction.
    //
    // Not behind a Loader like the menu and the picker, for the opposite
    // reason: this is a QtObject with three functions and two properties, not a
    // popup with a list in it, and the thing a Loader would save is dwarfed by
    // the two Connections this row already builds for every one of its 5000.
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

    // Routing for the menu's artist rows. Asked from the row and not from the
    // menu entry: a submenu is a Popup, and until it is shown it is in no
    // item's window, so `Window.window` inside one is null and the navigate
    // call went nowhere.
    function goToArtist(artistId) {
        if (artistId > 0 && Window.window)
            Window.window.navigate("artist", { artistId: artistId })
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

        // The row's hover, read by the play glyph, the background, the download
        // button and the menu button. A handler and not the MouseArea's
        // containsMouse: the artist names in the line below are hit targets of
        // their own, and a child MouseArea takes the hover event off the item
        // behind it, so the row dropped back to its resting look whenever the
        // pointer was on a name. A HoverHandler is not blocked that way.
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
                    objectName: "trackRowCover"
                    anchors.fill: parent
                    source: root.coverText.length > 0 ? "image://tidal/" + root.coverText : ""
                    // Decoded at twice the 36px box it is drawn in rather than
                    // at the 320px the cover URL serves: a long list was
                    // holding a full-size QImage per row for a thumbnail.
                    // Both dimensions, never one - sourceSize.width alone
                    // reaches the provider as 72x0, which QSize calls valid
                    // and QImageReader scales away to nothing. Safe against
                    // the crop because this art is square (tidal serves it
                    // WxW), which is the condition MediaCard does not meet.
                    sourceSize: Qt.size(72, 72)
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
                // One hover target and one tab stop per artist. The row's
                // own MouseArea is declared before the RowLayout holding this,
                // so a name takes the left click before the row does; a right
                // click is not one of this item's buttons and still reaches the
                // row menu.
                ArtistLinks {
                    Layout.fillWidth: true
                    namePrefix: "trackRow"
                    fontPixelSize: 12
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

    // "New playlist…", from the picker's first row.
    //
    // Its own Loader rather than a child of the picker's Popup: a Popup
    // declared inside another Popup's contentData has no reliable window to
    // resolve `Overlay.overlay` against, and this one has to centre on the
    // window like every other dialog in the app. A Loader holding a Popup is
    // the shape the picker below already proves works.
    //
    // Lazy for the same reason as the menu and the picker: the track lists are
    // stress-tested at 5000 rows, and a dialog on each of them is tens of
    // thousands of objects built for something almost no row is asked for.
    function openNewPlaylist() {
        if (root.trackId <= 0) return
        newPlaylistLoader.active = true
        newPlaylistLoader.item.openEmpty()
    }

    // A Popup is not a visual child of the row once it reparents itself to the
    // window overlay, so this is a test's only handle on it - the same reason
    // `rowMenu` above exists. Null until the row has been asked for one.
    readonly property alias newPlaylistPopup: newPlaylistLoader.item

    // The picker itself, for the same reason and in the same shape: it
    // reparents to the window overlay, so this is a test's only handle on it.
    // Null until the row has been asked for one.
    readonly property alias playlistPicker: pickerLoader.item

    Loader {
        id: newPlaylistLoader
        active: false
        sourceComponent: NewPlaylistDialog {
            objectName: "trackRowNewPlaylistDialog"
            onPlaylistCreated: function (playlist) {
                const uuid  = (playlist && playlist.uuid)  ? String(playlist.uuid) : ""
                const title = (playlist && playlist.title) ? playlist.title : ""
                // The whole point of making one from here: the song goes
                // straight into it. A playlist the user then has to go and fill
                // by hand would make this row a detour rather than a shortcut.
                if (uuid.length > 0 && root.trackId > 0) {
                    bridge.addTracksToPlaylist(uuid, root.trackId, function (ok) {
                        root.confirmAddedToPlaylist(ok === true, title)
                    })
                }
                if (pickerLoader.item) pickerLoader.item.close()
            }
        }
    }

    // The same confirmation the shared ContextMenu gives, and for the same
    // reason: queueing without a sign it worked is how a track ends up in
    // the queue twice. Drawn over the row the user just acted on. The dwell
    // is deliberately not Theme.dur() - see ContextMenu.confirmMs.
    readonly property int confirmMs: 2000

    // What the last confirmation said. ToolTip.show() writes to the shared
    // tooltip instance, which nothing outside this item can read back, so the
    // text is kept here too - it is the only way a test can check that a
    // *failed* add is not reported to the user as a success.
    property string lastConfirmation: ""

    function confirm(text) {
        root.lastConfirmation = text
        ToolTip.show(text, root.confirmMs)
    }

    function confirmQueued(atFront) {
        root.confirm(atFront ? qsTr("%n track(s) added to play next", "queue confirmation", 1)
                             : qsTr("%n track(s) added to queue", "queue confirmation", 1))
    }

    // The same thing for the picker, which gave no sign at all: it closed, and
    // whether the song had landed anywhere was a trip to the playlist to find
    // out. Both ways through the picker say so now - an existing playlist and
    // one made on the spot - because the second is the one where there is most
    // to doubt.
    //
    // Reports what the server said rather than what was asked for. Every
    // caller of addTracksToPlaylist in the app passes `function (ok) {}` and
    // throws the answer away, so a failed add has always been silent; a
    // confirmation that fired regardless would be worse than that - it would be
    // wrong rather than absent.
    function confirmAddedToPlaylist(ok, title) {
        root.confirm(ok ? qsTr("Added to “%1”",
                               "confirmation after adding a track to a playlist").arg(title)
                        : qsTr("Could not add the song to “%1”",
                               "shown when adding a track to a playlist failed").arg(title))
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

            // The row that opens a submenu is never declared: a nested Menu's
            // row in its parent is built from the parent's `delegate`, with the
            // submenu's title as its text and its `subMenu` already set. So the
            // "Go to artist ▸" row is described here, and the only submenu in
            // this menu is the artists one.
            delegate: ContextMenu.Entry {
                id: artistSubRow
                objectName: "goToArtistSubMenuRow"
                iconName: "artist"
                // One credit is the direct action below, not a submenu.
                visible: root.artistCredits.length > 1
                height: visible ? implicitHeight : 0
                // Room for the arrow, which the style draws beside the content
                // item rather than inside it.
                rightPadding: 12 + 18
                arrow: VectorIcon {
                    visible: artistSubRow.subMenu
                    x: artistSubRow.width - width - 12
                    y: (artistSubRow.height - height) / 2
                    width: 14; height: 14
                    name: "chevron-right"
                    color: artistSubRow.ink
                    strokeWidth: 1.6
                }
            }

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
                objectName: "likeMenuItem"
                text: root.isLiked ? qsTr("Unlike", "verb, remove from favourites")
                                   : qsTr("Like", "verb, add to favourites")
                // Filled is the state it is in, so it is the row that undoes
                // it -- the same pairing the pin row uses.
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
            // One credited artist, one action — which is every single-artist
            // track, and what this row has always been. Still shown but dead
            // when the map carries no usable artist id at all, as before.
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

                // Everything below is the same treatment the two menus above
                // get, for the same reasons: insets reset rather than inherited
                // (a style's drop-shadow insets laid the panel out past the
                // popup), `popupType` set only where it exists and through
                // `this.` so a miss is undefined rather than a ReferenceError,
                // and opacity-only transitions because Qt 6.4 loops when a
                // popup's own geometry feeds back into its contents.
                leftInset: 0; rightInset: 0; topInset: 0; bottomInset: 0
                Component.onCompleted: {
                    if (this.popupType !== undefined) this.popupType = Popup.Item
                }
                enter: ContextMenu.OpenFade { }
                exit:  ContextMenu.CloseFade { }
                implicitWidth: Theme.menuWidth(this)
                background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }

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
            // No "/browse/" in the link: tidal.com answers a 301 from
            // /browse/track/<id> to /track/<id>, so the short form is the
            // canonical one and the longer one only costs the recipient a
            // redirect.
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

            function fillFrom(pls) {
                plPickerModel.clear()
                for (var i = 0; i < pls.length; i++)
                    plPickerModel.append(pls[i])
            }

            // Opening this used to go back to the network every single time,
            // and the list sat empty until the round trip answered. The bridge
            // already holds the account's playlists - it pages them in at
            // sign-in, keeps them current on every create, and sorts them the
            // way every other list in the app is sorted - so the picker was
            // asking the server for something it was standing next to. Worse,
            // a playlist made a second ago in the sidebar was *missing* here
            // until the fetch came back, which is the one list where it most
            // needs to be.
            //
            // The fetch is kept for the empty case only. An empty cache cannot
            // be told apart from a cache the login paging has not reached yet,
            // which is exactly the state the first picker of a session opens
            // in; a genuinely empty account then pays one round trip that
            // answers nothing, and that is the cheap side of the trade.
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

                // ── "New playlist…", above the list it adds to ───────────
                //
                // The single most common moment anyone wants a new playlist is
                // while they are putting a song somewhere, and this picker was
                // the one place in the app that had an "Add to playlist" flow
                // and no way to make one. Worse at the start: an account with
                // no playlists opened this and got a title bar over an empty
                // box, with no way forward at all.
                //
                // First in the popup rather than last. The list underneath can
                // run to fifty rows and scrolls; a row at the bottom of a
                // scrolling list is a row most people never see.
                Item {
                    objectName: "pickerNewPlaylistRow"
                    width: parent.width
                    height: 44

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: Theme.radiusRow
                        color: newPlHov.hovered ? Theme.surfaceHov : "transparent"

                        HoverHandler { id: newPlHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler  { onTapped: root.openNewPlaylist() }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10

                            // An outlined tile where the rows below carry
                            // artwork: the same size, so the two labels line
                            // up, and plainly not a cover, so this does not
                            // read as a playlist whose picture failed to load.
                            Rectangle {
                                width: 28
                                height: 28
                                radius: Theme.radiusArt
                                color: "transparent"
                                border.width: 1
                                border.color: newPlHov.hovered ? Theme.accent : Theme.border
                                VectorIcon {
                                    anchors.centerIn: parent
                                    name: "plus"
                                    width: 13
                                    height: 13
                                    strokeWidth: 1.8
                                    color: newPlHov.hovered ? Theme.accent : Theme.textDim
                                }
                            }
                            Text {
                                objectName: "pickerNewPlaylistLabel"
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("New playlist…")
                                color: Theme.textPrimary
                                font.pixelSize: 13
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.border }

                ListView {
                    id: plPickerList
                    // A test's handle on the list itself. Until the stub's
                    // fetchUserPlaylists stopped answering an empty array,
                    // nothing in here could be driven at all and the only
                    // reachable row was the declared "New playlist…" one above.
                    objectName: "pickerPlaylistList"
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
                                    var intoTitle = model.title
                                    bridge.addTracksToPlaylist(model.uuid, trackPicker.pendingTrackId,
                                                               function (ok) {
                                        root.confirmAddedToPlaylist(ok === true, intoTitle)
                                    })
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
                                        // 28px box, doubled; see the row cover above.
                                        sourceSize: Qt.size(56, 56)
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
