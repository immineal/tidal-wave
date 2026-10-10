import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var albumId: 0
    property var albumData: ({})
    property var tracks: []
    property bool loading: false
    property bool isSaved: false

    // What the last load was told, "" when it was served.
    property string loadError: ""

    // Nothing came back at all. Either call failing alone still leaves a page
    // worth drawing. An empty answer with no error is not this: an album in
    // flight must not be reported as refused.
    readonly property bool loadFailed:
        loadError.length > 0 && !loading && tracks.length === 0 && !albumData.title

    // The title the favourites list still holds for this album, which is the
    // one endpoint that names a delisted edition. The failure panel searches
    // for it. Read once, since unsaveDeadAlbum() deletes the row it is in.
    property string savedTitle: ""

    function readSavedAlbum() {
        var saved = albumId > 0 ? bridge.favoriteAlbumById(albumId) : null
        root.savedTitle = (saved && saved.title) ? saved.title : ""
    }

    // Unsave, and what the panel says about it: in flight, landed, refused. Not
    // ContextMenu.FavoriteAction, whose tool tip does not stay on screen.
    // Flags, so the wording stays in a qsTr() binding.
    property bool unsaving:      false
    property bool unsaveDone:    false
    property bool unsaveRefused: false

    function unsaveDeadAlbum() {
        if (!(albumId > 0) || root.unsaving || root.unsaveDone) return
        var asked = root.albumId
        root.unsaving = true
        root.unsaveRefused = false
        bridge.removeAlbumFavorite(asked, function (ok) {
            // The page is reused for the next album, so a reply for the one on
            // screen at the press says nothing about the one on screen now.
            if (asked !== root.albumId) return
            root.unsaving = false
            // Only an explicit true counts as accepted, as in
            // ContextMenu.FavoriteAction: undefined must not read as success.
            if (ok === true) root.unsaveDone = true
            else             root.unsaveRefused = true
        })
    }

    // Records this album as the "playing from" source, then starts playback.
    function playFrom(list, i) {
        player.setPlaybackSource("album", "" + root.albumId, root.albumData.title || "")
        player.playTracks(list, i)
    }

    // "1 hr 4 min" / "52 min". Each case is a whole translatable string, so a
    // translation can reorder or re-unit it instead of inheriting English order.
    function durationText(seconds) {
        var loc  = Qt.locale()
        var hrs  = Math.floor(seconds / 3600)
        var mins = Math.floor((seconds % 3600) / 60)
        return hrs > 0
            ? qsTr("%1 hr %2 min").arg(hrs.toLocaleString(loc, 'f', 0)).arg(mins.toLocaleString(loc, 'f', 0))
            : qsTr("%1 min").arg(mins.toLocaleString(loc, 'f', 0))
    }

    // The release day in the reader's own date order and language: the locale's
    // long format without the weekday. Anything that is not a full ISO date
    // comes back untouched. NowPlayingPage.qml has the same function.
    function releaseText(iso) {
        if (!iso) return ""
        if (!/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso
        var d = Date.fromLocaleDateString(Qt.locale(), iso, "yyyy-MM-dd")
        if (isNaN(d.getTime())) return iso
        var fmt = Qt.locale().dateFormat(Locale.LongFormat)
                             .replace(/^dddd[,.]?\s*/, "")
                             .replace(/[,.]?\s*dddd$/, "")
        return d.toLocaleDateString(Qt.locale(), fmt)
    }

    function updateSavedState() {
        isSaved = albumId > 0 ? bridge.isAlbumFavorite(albumId) : false
    }

    // The Save pill's one call, and what it says when the server refuses it.
    // isSaved is read back from the bridge and never written here.
    readonly property alias favoriteAction: albumFav
    ContextMenu.FavoriteAction { id: albumFav }

    readonly property int effectiveArtistId: albumData.artistId > 0 ? albumData.artistId
        : (tracks.length > 0 && tracks[0].artistId > 0 ? tracks[0].artistId : 0)

    // The album's own credits, name by name. Not recovered from the tracklist:
    // on a compilation the first track's artists are not the album's. With no
    // list, ArtistLinks falls back to the joined string and the one id above.
    readonly property var albumArtistList:
        (albumData.artistList && albumData.artistList.length > 0) ? albumData.artistList : []

    onAlbumIdChanged: if (albumId > 0) {
        root.unsaving = false
        root.unsaveDone = false
        root.unsaveRefused = false
        loadAlbum()
        updateSavedState()
        readSavedAlbum()
    }

    Connections {
        target: bridge
        function onFavoriteAlbumsChanged() {
            root.updateSavedState()
            // The favourites list arrives after the window does. Only ever
            // gains a title: re-reading after the removal would lose it.
            if (root.savedTitle.length === 0) root.readSavedAlbum()
        }
    }

    // What the hero's queue actions act on: the whole album. The menu can be
    // opened while fetchAlbumTracks() is still out, so an empty page asks again
    // rather than queueing nothing.
    function allTracks(cb) {
        if (root.tracks.length > 0) { cb(root.tracks); return }
        if (!(root.albumId > 0)) return
        bridge.fetchAlbumTracks(root.albumId, function (t, err) {
            if (!err && t.length > 0) cb(t)
        })
    }

    function loadAlbum() {
        loading = true
        loadError = ""
        bridge.fetchAlbum(albumId, function(album, err) {
            if (err) { root.loadError = err; return }
            root.albumData = album
        })
        bridge.fetchAlbumTracks(albumId, function(t, err) {
            root.loading = false
            // The header's reason first where there is one: both calls fail
            // together on a dead album, and the two strings say the same thing.
            if (err) {
                if (root.loadError.length === 0) root.loadError = err
                return
            }
            root.tracks = t
        })
    }

    ListView {
        id: tracksList
        objectName: "albumTracksList"
        anchors.fill: parent
        // Hidden, not covered: behind the error panel the hero's pills would
        // still be hit targets and tab stops.
        visible: !root.loadFailed
        clip: true
        model: root.tracks
        boundsBehavior: Flickable.StopAtBounds

        header: Column {
            width: tracksList.width

            // Hero header. Grows with its content, so a wrapped title or pill
            // row is not cut off.
            Rectangle {
                width: parent.width
                implicitHeight: Math.max(280, heroRow.implicitHeight + 48)
                color: "transparent"
                clip: true

                Image {
                    anchors.fill: parent
                    source: albumData.coverUrl640 ? "image://tidal/" + albumData.coverUrl640 : ""
                    fillMode: Image.PreserveAspectCrop
                    opacity: 0.18
                    smooth: true
                    mipmap: true
                }

                Rectangle {
                    anchors.fill: parent
                    // accentTint, not artScrimStrong: the hero is a tint over
                    // the page, and the black scrim composites to a
                    // low-contrast grey on the light themes.
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0; color: Theme.accentTint }
                        GradientStop { position: 1; color: Theme.bg }
                    }
                }

                RowLayout {
                    id: heroRow
                    anchors {
                        left: parent.left; right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 64; rightMargin: 24
                    }
                    spacing: 24

                    Rectangle {
                        objectName: "heroArt"
                        width: 200
                        height: 200
                        radius: Theme.radiusArt
                        color: Theme.surfaceHigh
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: albumData.coverUrl ? "image://tidal/" + albumData.coverUrl : ""
                            fillMode: Image.PreserveAspectCrop
                            smooth: true
                            mipmap: true
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 8

                        Text {
                            text: qsTr("Album")
                            color: Theme.textSec
                            font.pixelSize: 12
                            font.bold: true
                            font.letterSpacing: 1
                        }

                        Text {
                            Layout.fillWidth: true
                            text: albumData.title || ""
                            color: Theme.textPrimary
                            font.pixelSize: 28
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }

                        // One hover target and one tab stop per artist, so a
                        // featured credit opens the guest rather than the lead.
                        ArtistLinks {
                            Layout.fillWidth: true
                            namePrefix: "albumHero"
                            fontPixelSize: 14
                            artistList: root.albumArtistList
                            joinedText: albumData.artists || ""
                            fallbackArtistId: root.effectiveArtistId
                        }

                        Text {
                            text: {
                                // Bullet-separated facts, each a complete qsTr unit.
                                var parts = []
                                // The whole date where there is one, the year on
                                // its own where the response only had that.
                                var released = root.releaseText(albumData.releaseDate)
                                if (released) parts.push(released)
                                else if (albumData.year) parts.push(albumData.year)
                                if (albumData.numTracks) parts.push(qsTr("%n track(s)", "", albumData.numTracks))
                                if (albumData.duration > 0) parts.push(root.durationText(albumData.duration))
                                // Raw API codes like HI_RES_LOSSLESS never reach the user
                                if (albumData.quality) parts.push(player.qualityLabel(albumData.quality))
                                // qualityLabel echoes a code it does not know, and an
                                // unknown code can be empty, which otherwise leaves the
                                // line ending in a dangling separator.
                                return parts.filter(function (p) { return p && String(p).length > 0 }).join(" • ")
                            }
                            color: Theme.textSec
                            font.pixelSize: 13
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        // The rights line as the label worded it: a legal
                        // notice, so neither translated nor reformatted. Hidden
                        // when the response carried none.
                        Text {
                            objectName: "albumCopyright"
                            visible: text.length > 0
                            text: albumData.copyright || ""
                            color: Theme.textDim
                            font.pixelSize: 11
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        // A Flow, so the pills wrap in a narrow pane.
                        Flow {
                            id: heroActions
                            Layout.fillWidth: true
                            spacing: 12
                            // The queue confirmation is drawn above this row.
                            // Assigned, not bound: an id inside the list's
                            // header component is out of reach from the root.
                            Component.onCompleted: if (heroPinMenu) heroPinMenu.confirmAnchor = heroActions

                            PillButton {
                                text: qsTr("Play", "verb, button label")
                                icon: "play"
                                accent: true
                                onClicked: if (root.tracks.length > 0) root.playFrom(root.tracks, 0)
                            }

                            PillButton {
                                text: qsTr("Shuffle")
                                icon: "shuffle"
                                accent: false
                                onClicked: {
                                    if (root.tracks.length > 0) {
                                        player.setShuffle(true)
                                        root.playFrom(root.tracks, Math.floor(Math.random() * root.tracks.length))
                                    }
                                }
                            }

                            PillButton {
                                objectName: "albumSavePill"
                                text: root.isSaved ? qsTr("Saved", "state, album is in the library")
                                                   : qsTr("Save", "verb, add album to the library")
                                icon: root.isSaved ? "heart-filled" : "heart"
                                accent: root.isSaved
                                // Anchored on the action row, which has clear
                                // space above it.
                                onClicked: root.favoriteAction.toggleAlbum(root.albumId, root.isSaved,
                                                                          heroActions)
                            }
                        }
                    }
                }

                // A right-click on the hero pins what the page is showing.
                MouseArea {
                    objectName: "heroPinArea"
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: function (mouse) {
                        var p = mapToItem(root, mouse.x, mouse.y)
                        root.showHeroPinMenu(p.x, p.y)
                    }
                }
            }

            Item { height: 8; width: parent.width }
        }

        delegate: TrackRow {
            width: tracksList.width - 32
            x: 16
            trackNum:    index + 1
            title:       modelData.title
            artists:     modelData.artists
            albumTitle:  root.albumData.title || ""
            durationStr: modelData.durationStr
            showAlbum:   false
            showCover:   false
            isPlaying:   player.currentTrack.id === modelData.id && player.playing
            trackData:   modelData
            onPlayRequested: root.playFrom(root.tracks, index)
        }

        footer: Item { height: 32; width: tracksList.width }

        ScrollBar.vertical: ScrollBar {
            active: true
            policy: ScrollBar.AsNeeded
        }
    }

    // What the page says when there is nothing to draw and a reason for it.
    // Persistent, not a tool tip: this is the whole page while it shows.
    Rectangle {
        objectName: "albumLoadError"
        anchors.fill: parent
        visible: root.loadFailed
        color: Theme.bg

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 96, 420)
            spacing: 10

            VectorIcon {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                name: "album"
                color: Theme.textDim
                strokeWidth: 1.5
            }

            Text {
                objectName: "albumLoadErrorText"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("This album is not available")
                color: Theme.textPrimary
                font.pixelSize: 18
                font.bold: true
                wrapMode: Text.WordWrap
            }

            // Not the server's own string, which is a Qt network error with the
            // request URL in it.
            Text {
                objectName: "albumLoadErrorDetail"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                // One long literal: lupdate cannot read a concatenation. No
                // example of the bad form here, because tst_shortcuts counts a
                // call site in a comment.
                text: qsTr("Tidal would not serve it. It may have been taken down, or it may not be available where you are. Searching for the title often finds another release of it.")
                color: Theme.textSec
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            // What can still be done about a record the API will not serve.
            // Each button is hidden when it has nothing to act on: no title to
            // search for, nothing saved to remove.
            RowLayout {
                objectName: "albumLoadErrorActions"
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 6
                spacing: 10

                PillButton {
                    objectName: "albumLoadErrorFind"
                    text: qsTr("Find album", "verb, look for another release of this album")
                    icon: "search"
                    visible: root.savedTitle.length > 0
                    // The title, since the id is what is dead. `requestedQuery`
                    // hands Search a term to run.
                    onClicked: root.navigateTo("search", { requestedQuery: root.savedTitle })
                }

                PillButton {
                    objectName: "albumLoadErrorUnsave"
                    // The words CollectionPage's removeLabel uses for this.
                    text: qsTr("Remove from library")
                    icon: "trash"
                    accent: false
                    // isSaved alone: the bridge emits favoriteAlbumsChanged
                    // before it answers the callback, so the flag is already
                    // false when the removal lands.
                    visible: root.isSaved
                    enabled: !root.unsaving
                    onClicked: root.unsaveDeadAlbum()
                }
            }

            Text {
                objectName: "albumLoadErrorUnsaveStatus"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                visible: text.length > 0
                text: root.unsaveDone    ? qsTr("Removed from your library.")
                    : root.unsaveRefused ? qsTr("Tidal would not remove it. It is still in your library.")
                    : root.unsaving      ? qsTr("Removing…")
                    : ""
                color: root.unsaveRefused ? Theme.red : Theme.textSec
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }
        }
    }

    // Sticky bar: the back button is always visible, the title fades in once
    // the hero scrolls out.
    Rectangle {
        id: stickyHeader
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52
        // How far the header has come in: 0 while the hero is still on screen,
        // 1 once it has scrolled away.
        readonly property real reveal:
            Math.min(1, Math.max(0, (tracksList.contentY - 200) / 80))
        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, Math.min(0.95, reveal))

        BackButton { anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 } }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 64
            anchors.rightMargin: 16
            spacing: 12
            opacity: stickyHeader.reveal
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: albumData.title || ""
                    color: Theme.textPrimary
                    font.pixelSize: 15
                    font.bold: true
                    elide: Text.ElideRight
                }
                ArtistLinks {
                    Layout.fillWidth: true
                    namePrefix: "albumSticky"
                    fontPixelSize: 12
                    artistList: root.albumArtistList
                    joinedText: albumData.artists || ""
                    fallbackArtistId: root.effectiveArtistId
                    // The header is always present at full size and only fades
                    // in, so its links are disabled while it is invisible.
                    enabled: stickyHeader.reveal > 0
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border
            opacity: stickyHeader.reveal
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params || {})
    }

    // The pin carries the labels and the artwork the page is showing, so the
    // sidebar row reads the same as the page it came from.
    readonly property alias pinMenu: heroPinMenu

    function showHeroPinMenu(x, y) {
        heroPinMenu.showPin(x, y, "album", root.albumId > 0 ? "" + root.albumId : "",
                            root.albumData.title || "", root.albumData.artists || "",
                            root.albumData.coverUrl || "")
    }

    ContextMenu {
        id: heroPinMenu
        objectName: "heroPinMenu"
        trackSource: root.allTracks
    }

    LoadingOverlay { loading: root.loading }
}
