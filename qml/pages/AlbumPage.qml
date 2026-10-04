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

    // What the last load was told, "" when it was served. Both fetches used to
    // read `if (!err)` and drop this, which is the whole of the bug in
    // tests/qml/tst_album_load_error.qml: an album the API refuses - a delisted
    // edition still sitting in the user's favourites answers 404 for both the
    // header and the tracklist - left the page on its empty initial state with
    // no spinner and nothing said, and a dead record looked exactly like a
    // broken app. Same lesson as the eleven dropped refusals in a35cbe3.
    property string loadError: ""

    // Nothing came back at all. Either call failing on its own still leaves a
    // page worth drawing - a header with no tracklist under it, or a tracklist
    // under a hero the caller's data fills - so the panel is only for the case
    // where the page has nothing *and* the server said why. An empty answer
    // that carried no error is not this: an album still in flight, or one that
    // genuinely has nothing, must not be reported as refused.
    readonly property bool loadFailed:
        loadError.length > 0 && !loading && tracks.length === 0 && !albumData.title

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

    // The day the record came out, in the reader's own date order and language.
    //
    // The hero used to print `albumData.year`, which is the first four
    // characters of this: the user asked for "the actual date that something
    // came out", and albums/<id> has carried it in full all along.
    //
    // Anything that is not a full ISO date is handed back untouched rather than
    // guessed at - a bare year from an older response stays a bare year - which
    // is also what keeps Date.fromLocaleDateString away from a string it would
    // throw on.
    // The locale's long date format with the weekday taken off the front: which
    // Friday a record came out on is noise, and Qt's short form is all digits
    // and drops the month name. A locale whose long format does not lead with
    // the weekday is left exactly as it is. The same function is in
    // qml/pages/NowPlayingPage.qml, where the credits panel prints the same
    // date; sharing it would take a new QML file in the module.
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
    // isSaved above is read back from the bridge and never written here, so a
    // refusal has nothing to undo - only something to say. See
    // ContextMenu.FavoriteAction.
    readonly property alias favoriteAction: albumFav
    ContextMenu.FavoriteAction { id: albumFav }

    readonly property int effectiveArtistId: albumData.artistId > 0 ? albumData.artistId
        : (tracks.length > 0 && tracks[0].artistId > 0 ? tracks[0].artistId : 0)

    // The album's own credits, name by name (SPEC N2). Deliberately not
    // recovered off the tracklist the way effectiveArtistId recovers the lead
    // id: a compilation's album credit and its first track's credit are
    // different things, and taking the names from track 1 would put that
    // track's artists under the album's title. No list means the joined
    // `artists` string and the one id above, which is what ArtistLinks falls
    // back to.
    readonly property var albumArtistList:
        (albumData.artistList && albumData.artistList.length > 0) ? albumData.artistList : []

    onAlbumIdChanged: if (albumId > 0) { loadAlbum(); updateSavedState() }

    Connections {
        target: bridge
        function onFavoriteAlbumsChanged() { root.updateSavedState() }
    }

    // What the hero's queue actions act on: the whole album, which is not
    // always what the list is showing. The menu can be opened while
    // fetchAlbumTracks() is still out, so an empty page asks again rather
    // than queueing nothing.
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
        // So a test can scroll the hero out of the way and ask what the sticky
        // header does when it is actually on screen.
        objectName: "albumTracksList"
        anchors.fill: parent
        // A blank hero is not worth leaving behind the panel below: its Play,
        // Shuffle and Save pills would still be hit targets and tab stops over
        // an album that does not exist. Hidden rather than covered, because an
        // invisible item is neither.
        visible: !root.loadFailed
        clip: true
        model: root.tracks
        boundsBehavior: Flickable.StopAtBounds

        header: Column {
            width: tracksList.width

            // Hero header. Grows with its content rather than sitting at a
            // fixed 280: a wrapped title or a wrapped pill row used to be cut
            // off at the bottom edge.
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
                    // accentTint, not artScrimStrong. The hero is a tint over
                    // the page, not a wash over cover art - the artwork behind
                    // it is at 0.18 - and artScrimStrong is black at 60% in
                    // every theme by design. On the two light themes that
                    // composited to a mud grey that put the eyebrow at 1.3:1
                    // and the artist link at 2.2:1. Playlist, Mix and Now
                    // Playing already tint the same header from the accent.
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

                        // The rights line, exactly as the label worded it: a
                        // legal notice, so it is neither translated nor
                        // reformatted. Under the facts line and dimmer than it,
                        // because it is the sleeve's small print and not one of
                        // the facts about the record. Hidden entirely when the
                        // response carried none, so nothing reserves a row for
                        // an empty string.
                        Text {
                            objectName: "albumCopyright"
                            visible: text.length > 0
                            text: albumData.copyright || ""
                            color: Theme.textDim
                            font.pixelSize: 11
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        // A Flow, so the pills wrap onto a second line instead
                        // of pushing the column past the hero's right edge.
                        // Three pills are 384px at the old fixed width, more
                        // than the 328px the column gets in a 640px pane.
                        Flow {
                            id: heroActions
                            Layout.fillWidth: true
                            spacing: 12
                            // The queue confirmation is drawn just above the
                            // row of actions it confirms. Assigned rather than
                            // bound: the hero lives in the list's header, and
                            // an id inside that component is out of reach from
                            // the page root, where the menu is.
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
                                // Anchored on the action row rather than the
                                // pill, the way the hero's pin menu anchors its
                                // confirmation: the pill sits low in the hero
                                // and the row is what has clear space above it.
                                onClicked: root.favoriteAction.toggleAlbum(root.albumId, root.isSaved,
                                                                          heroActions)
                            }
                        }
                    }
                }

                // P2: a right-click on the hero pins what the page is showing.
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
    // Persistent, not a tool tip: the queue and favourite refusals in
    // ContextMenu are about a press that did not land and the page behind them
    // is still the page, whereas this *is* the page, and it is wrong for as
    // long as the user is looking at it.
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

            // Deliberately not the server's own string: it is a Qt network
            // error with the whole request URL in it. What the user can act on
            // is that the record is gone, not that a GET returned 404 - and
            // the reason it is still in their library is that Tidal keeps
            // answering for it in the favourites list and nowhere else.
            Text {
                objectName: "albumLoadErrorDetail"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                // One long literal and not a concatenation of three: lupdate
                // extracts the source text, and two literals joined by a plus
                // are an expression it cannot read - the string would ship
                // untranslatable in every language. (Said without writing the
                // bad form out: tst_shortcuts scans this file for call sites
                // and would count an example in a comment as one.)
                text: qsTr("Tidal would not serve it. It may have been taken down, or it may not be available where you are. Searching for the title often finds another release of it.")
                color: Theme.textSec
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }
        }
    }

    // Sticky bar — back button always visible; title fades in once hero scrolls out
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
                    // The header is present at full size the whole time and
                    // only fades in, so without this its links would be hit
                    // targets and tab stops over the top of the hero while it
                    // is invisible. A disabled item is neither.
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

    // P2. The pin carries the labels and the artwork the page is showing, so
    // the sidebar row reads the same as the page it came from.
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
