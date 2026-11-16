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
            // albumId can change before the reply lands, and a reply for the
            // album on screen at the press says nothing about the one there now.
            if (asked !== root.albumId) return
            root.unsaving = false
            // Only an explicit true counts as accepted, as in
            // ContextMenu.FavoriteAction: undefined must not read as success.
            if (ok === true) root.unsaveDone = true
            else             root.unsaveRefused = true
        })
    }

    // A track's disc, 1 when the payload has none.
    function discOf(t) {
        var v = t ? Number(t.volumeNumber) : NaN
        return v > 0 ? v : 1
    }

    // Disc headers are drawn only for an album that has more than one disc.
    readonly property bool multiDisc: {
        for (var i = 1; i < tracks.length; ++i)
            if (discOf(tracks[i]) !== discOf(tracks[0])) return true
        return false
    }

    // Records this album as the "playing from" source, then starts playback.
    function playFrom(list, i) {
        player.setPlaybackSource("album", "" + root.albumId, root.albumData.title || "")
        player.playTracks(list, i)
    }

    // The release day in the reader's own date order and language: the locale's
    // long format without the weekday. Anything that is not a full ISO date
    // comes back untouched. NowPlayingPage.releaseDateText() is the same.
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
        loadOtherVersions()
        updateSavedState()
        readSavedAlbum()
    }

    // The other products of this record, as Tidal's own album page names
    // them. Empty until the answer is in, and when it names none.
    property var otherVersions: []

    function loadOtherVersions() {
        var requested = root.albumId
        root.otherVersions = []
        bridge.fetchAlbumOtherVersions(requested, function (versions, err) {
            // A reply for an album the page has left says nothing about the
            // one on it, and a failure leaves the page without the row.
            if (requested !== root.albumId || err) return
            root.otherVersions = versions || []
        })
    }

    function listHas(list, value) {
        for (var i = 0; list && i < list.length; ++i)
            if (list[i] === value) return true
        return false
    }

    // A product with Dolby Atmos and no stereo mode. Tidal lists it as low
    // quality, and answers a request for its stream with the stereo version.
    function atmosOnly(a) {
        return listHas(a.audioModes, "DOLBY_ATMOS") && !listHas(a.audioModes, "STEREO")
    }

    // What a product sounds like, in the names of the quality settings. Hi-res
    // is a tag: the listed quality of such a product says LOSSLESS.
    function soundOf(a) {
        if (atmosOnly(a)) return qsTr("Dolby Atmos")
        if (listHas(a.mediaTags, "HIRES_LOSSLESS")) return player.qualityLabel("HI_RES_LOSSLESS")
        return a.quality ? player.qualityLabel(a.quality) : ""
    }

    // The cards of the row. Under each title stands what tells that version
    // apart: explicit or clean where the versions differ in that, then its
    // sound. The album on the page is one of the versions compared.
    readonly property var versionCards: {
        var all = root.otherVersions.concat(
            root.albumData.explicit_ !== undefined ? [root.albumData] : [])
        var explicitOnes = all.filter(function (a) { return a.explicit_ }).length
        var differ = explicitOnes > 0 && explicitOnes < all.length
        return root.otherVersions.map(function (a) {
            var parts = []
            if (differ) parts.push(a.explicit_
                    ? qsTr("Explicit", "a version of an album with its lyrics as recorded")
                    : qsTr("Clean", "a version of an album with its lyrics edited"))
            parts.push(root.soundOf(a))
            return { id: a.id, title: a.title, coverUrl: a.coverUrl,
                     subtitle: parts.filter(function (p) { return p.length > 0 }).join(" · "),
                     // The subtitle is translated words, so a pin stores this.
                     pinSubtitle: a.artists || "" }
        })
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
        // albumId can change while the replies are out. One for the album the
        // page has left belongs to no album on it.
        var requested = root.albumId
        loading = true
        loadError = ""
        bridge.fetchAlbum(requested, function(album, err) {
            if (requested !== root.albumId) return
            if (err) { root.loadError = err; return }
            root.albumData = album
        })
        bridge.fetchAlbumTracks(requested, function(t, err) {
            if (requested !== root.albumId) return
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

            DetailHero {
                id: hero
                width: parent.width
                kind: qsTr("Album")
                title: albumData.title || ""
                artSource: albumData.coverUrl || ""
                artIcon: "album"
                backdropSource: albumData.coverUrl640 || ""
                onPinRequested: (x, y) => {
                    var p = hero.mapToItem(root, x, y)
                    root.showHeroPinMenu(p.x, p.y)
                }

                // One hover target and one tab stop per artist, so a featured
                // credit opens the guest rather than the lead.
                ArtistLinks {
                    Layout.fillWidth: true
                    namePrefix: "albumHero"
                    fontPixelSize: Theme.fontBody
                    artistList: root.albumArtistList
                    joinedText: albumData.artists || ""
                    fallbackArtistId: root.effectiveArtistId
                }

                Text {
                    objectName: "albumFacts"
                    text: {
                        // Bullet-separated facts, each a complete qsTr unit.
                        var parts = []
                        // The whole date where there is one, the year on
                        // its own where the response only had that.
                        var released = root.releaseText(albumData.releaseDate)
                        if (released) parts.push(released)
                        else if (albumData.year) parts.push(albumData.year)
                        if (albumData.numTracks) parts.push(qsTr("%Ln track(s)", "", albumData.numTracks))
                        if (albumData.duration > 0) parts.push(Theme.lengthText(albumData.duration))
                        // Raw API codes like HI_RES_LOSSLESS never reach the user
                        if (root.atmosOnly(albumData)) parts.push(qsTr("Dolby Atmos, plays in stereo"))
                        else parts.push(root.soundOf(albumData))
                        // qualityLabel echoes a code it does not know, and an
                        // unknown code can be empty, which otherwise leaves the
                        // line ending in a dangling separator.
                        return parts.filter(function (p) { return p && String(p).length > 0 }).join(" · ")
                    }
                    color: Theme.textSec
                    font.pixelSize: Theme.fontMeta
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
                    font.pixelSize: Theme.fontMicro
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                actions: [
                    PillButton {
                        text: qsTr("Play", "verb, button label")
                        icon: "play"
                        accent: true
                        onClicked: if (root.tracks.length > 0) root.playFrom(root.tracks, 0)
                    },
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
                    },
                    PillButton {
                        objectName: "albumSavePill"
                        text: root.isSaved ? qsTr("Saved", "state, album is in the library")
                                           : qsTr("Save", "verb, add album to the library")
                        icon: root.isSaved ? "heart-filled" : "heart"
                        accent: root.isSaved
                        // Anchored on the action row, which has clear space
                        // above it.
                        onClicked: root.favoriteAction.toggleAlbum(root.albumId, root.isSaved,
                                                                  hero.actionRow)
                    }
                ]
            }

            Item { height: Theme.space2; width: parent.width }
        }

        // A wrapper, so a disc's first row can carry its "Disc n" header.
        delegate: Column {
            id: trackDelegate
            width: tracksList.width
            readonly property int disc: root.discOf(modelData)
            readonly property bool startsDisc: root.multiDisc
                && (index === 0 || root.discOf(root.tracks[index - 1]) !== disc)

            Text {
                objectName: "albumDiscHeader"
                visible: trackDelegate.startsDisc
                x: 16 + 12
                width: parent.width - 32 - 12
                height: visible ? implicitHeight : 0
                topPadding: index === 0 ? Theme.space1 : Theme.space5
                bottomPadding: Theme.space2
                text: qsTr("Disc %1", "heading over one disc's tracks on an album page")
                          .arg(trackDelegate.disc.toLocaleString(Qt.locale(), 'f', 0))
                color: Theme.textSec
                font.pixelSize: Theme.fontMeta
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            TrackRow {
                width: tracksList.width - 32
                x: 16
                // The album's own numbering, which starts over on each disc.
                trackNum:    modelData.trackNumber > 0 ? modelData.trackNumber : index + 1
                title:       modelData.title
                artists:     modelData.artists
                albumTitle:  root.albumData.title || ""
                durationStr: modelData.durationStr
                showAlbum:   false
                showCover:   false
                trackData:   modelData
                onPlayRequested: root.playFrom(root.tracks, index)
            }
        }

        footer: Column {
            width: tracksList.width

            Item { width: parent.width; height: 24; visible: versionsRow.visible }

            HorizontalSection {
                id: versionsRow
                objectName: "albumOtherVersions"
                width: parent.width
                visible: root.versionCards.length > 0
                title: qsTr("Other versions")
                showViewAll: false
                mediaType: "album"
                items: root.versionCards
                onItemClicked: function (i, item) { root.navigateTo("album", { albumId: item.id }) }
                // Declares the source, so the player bar records the play.
                onItemPlayClicked: function (i, item) {
                    bridge.fetchAlbumTracks(item.id, function (tracks, err) {
                        if (err || tracks.length === 0) return
                        player.setPlaybackSource("album", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
            }

            Item { width: parent.width; height: Theme.space8 }
        }

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
            spacing: Theme.space3

            VectorIcon {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                name: "album"
                color: Theme.textDim
            }

            Text {
                objectName: "albumLoadErrorText"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("This album is not available")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontSection
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
                font.pixelSize: Theme.fontMeta
                wrapMode: Text.WordWrap
            }

            // What can still be done about a record the API will not serve.
            // Each button is hidden when it has nothing to act on: no title to
            // search for, nothing saved to remove.
            RowLayout {
                objectName: "albumLoadErrorActions"
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.space2
                spacing: Theme.space3

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
                    text: qsTr("Remove from collection")
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
                text: root.unsaveDone    ? qsTr("Removed from your collection.")
                    : root.unsaveRefused ? qsTr("Tidal would not remove it. It is still in your collection.")
                    : root.unsaving      ? qsTr("Removing…")
                    : ""
                color: root.unsaveRefused ? Theme.redText : Theme.textSec
                font.pixelSize: Theme.fontMeta
                wrapMode: Text.WordWrap
            }
        }
    }

    // The back button is always there; the title fades in once the hero
    // scrolls out.
    DetailBar {
        id: stickyHeader
        objectName: "albumStickyHeader"
        flickable: tracksList
        heroHeight: tracksList.headerItem ? tracksList.headerItem.height : 280
        title: albumData.title || ""
        ArtistLinks {
            Layout.fillWidth: true
            namePrefix: "albumSticky"
            fontPixelSize: Theme.fontMeta
            artistList: root.albumArtistList
            joinedText: albumData.artists || ""
            fallbackArtistId: root.effectiveArtistId
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

    Skeleton { loading: root.loading; kind: "detail" }
}
