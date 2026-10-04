import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    // How much of this pane's width is only on loan. Below Prefs::railBreakpoint
    // the sidebar collapses to its 68px rail and hands the page back the ~150px
    // it had been using, so the pane gets *wider* as the window gets narrower:
    // the pane's width does not fall with the window's, it has a step in it.
    // Any column that switches on the pane therefore un-hides itself halfway
    // down a drag. The track rows' album column dropped out at an 892px window,
    // came back at 819 when the rail took over, and went again at 740, which is
    // the flicker the user saw. Subtracting the loan measures the breakpoint
    // against a width that only ever shrinks with the window, and across the
    // step it is the same number on both sides, so nothing jumps there either.
    readonly property int sidebarReclaim: {
        var w = Window.window ? Window.window.width : 0
        return (w > 0 && w < prefs.railBreak())
               ? Math.max(0, prefs.sidebarWidth - prefs.rail()) : 0
    }

    property var artistId: 0
    property var artistData: ({})
    property var topTracks: []
    property var albums: []
    property bool loading: false
    property bool showAllTracks: false
    property bool isFollowing: false

    // Records this artist as the "playing from" source, then plays.
    function playFrom(list, i) {
        player.setPlaybackSource("artist", "" + root.artistId, root.artistData.name || "")
        player.playTracks(list, i)
    }

    function updateFollowState() {
        isFollowing = artistId > 0 ? bridge.isArtistFavorite(artistId) : false
    }

    // The Follow pill's one call, and what it says when the server refuses it.
    // isFollowing above is read back from the bridge and never written here, so
    // a refusal has nothing to undo - only something to say. See
    // ContextMenu.FavoriteAction.
    readonly property alias favoriteAction: artistFav
    ContextMenu.FavoriteAction { id: artistFav }

    onArtistIdChanged: if (artistId > 0) { loadArtist(); updateFollowState() }

    Connections {
        target: bridge
        function onFavoriteArtistsChanged() { root.updateFollowState() }
    }

    function loadArtist() {
        loading = true
        bridge.fetchArtistDetail(artistId, function(d, err) {
            if (!err) artistData = d
        })
        bridge.fetchArtistTopTracks(artistId, function(t, err) {
            if (!err) topTracks = t
        })
        bridge.fetchArtistAlbums(artistId, function(a, err) {
            loading = false
            // Tidal's artist/albums endpoint lists every edition of a release
            // (Standard, Deluxe, Explicit, retailer-exclusives …) as separate ids,
            // so the discography shows the same cover many times. Collapse them by
            // artwork + base title (title minus trailing "(…)"/"[…]" qualifiers).
            // Different covers are kept apart, so genuinely distinct releases like
            // "Fearless" vs "Fearless (Taylor's Version)" still both show.
            if (!err) albums = root.dedupeEditions(a)
        })
    }

    // Title without trailing edition qualifiers, e.g.
    // "1989 (Deluxe Edition) [Explicit]" -> "1989". Only strips parenthetical/
    // bracketed suffixes, so "(Taylor's Version)" collapses editions of that
    // re-recording together but never merges it with the original album.
    function baseTitle(t) {
        var s = ("" + (t || "")).toLowerCase().trim()
        for (var k = 0; k < 2; k++)
            s = s.replace(/\s*[\(\[][^\(\)\[\]]*[\)\]]\s*$/, "").trim()
        return s
    }

    // Collapse duplicate album editions, keying on artwork + base title so that
    // same-release editions merge while distinct releases (different covers) stay.
    function dedupeEditions(list) {
        var seen = ({})
        var out = []
        for (var i = 0; i < list.length; i++) {
            var a = list[i]
            var cover = a.coverUrl || ("id:" + a.id)
            var key = cover + "" + root.baseTitle(a.title)
            if (seen[key]) continue
            seen[key] = true
            out.push(a)
        }
        return out
    }

    ScrollView {
        anchors.fill: parent
        rightPadding: 14
        contentWidth: availableWidth

        ColumnLayout {
            width: parent.width
            spacing: 0

            // Hero. Grows with its content rather than sitting at a fixed
            // 320, so a wrapped name or a wrapped pill row still fits.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: Math.max(320, heroCol.implicitHeight + 56)
                color: "transparent"
                clip: true

                Image {
                    anchors.fill: parent
                    source: artistData.coverUrl750 ? "image://tidal/" + artistData.coverUrl750 : ""
                    fillMode: Image.PreserveAspectCrop
                    opacity: 0.4
                    smooth: true
                    mipmap: true
                }

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.4; color: "transparent" }
                        GradientStop { position: 1; color: Theme.bg }
                    }
                }

                ColumnLayout {
                    id: heroCol
                    // Anchored right as well: without it the name had no width
                    // to work with and a long one ran off the page.
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 28
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        text: artistData.name || ""
                        color: Theme.textPrimary
                        font.pixelSize: 36
                        font.bold: true
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        style: Text.Outline
                        styleColor: Theme.artScrimStrong
                    }

                    // A Flow, so the pills wrap instead of running off the
                    // hero once a German label makes them wider.
                    Flow {
                        id: heroActions
                        Layout.fillWidth: true
                        spacing: 12
                        PillButton {
                            text: qsTr("Play", "verb, button label")
                            icon: "play"
                            accent: true
                            onClicked: if (topTracks.length > 0) root.playFrom(topTracks, 0)
                        }

                        PillButton {
                            objectName: "artistFollowPill"
                            text: root.isFollowing ? qsTr("Following") : qsTr("Follow")
                            icon: root.isFollowing ? "heart-filled" : "heart"
                            accent: root.isFollowing
                            // On the action row, not the pill, for the reason
                            // the hero's pin menu gives on the same item.
                            onClicked: root.favoriteAction.toggleArtist(root.artistId, root.isFollowing,
                                                                      heroActions)
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

            Item { height: 8 }

            RowLayout {
                visible: root.topTracks.length > 0
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                Text {
                    text: qsTr("Popular")
                    color: Theme.textPrimary
                    font.pixelSize: 20
                    font.bold: true
                    Layout.fillWidth: true
                }
                Text {
                    visible: root.topTracks.length > 5
                    text: root.showAllTracks ? qsTr("Show less") : qsTr("Show all")
                    color: showAllHov.hovered ? Theme.textPrimary : Theme.textSec
                    font.pixelSize: 13
                    HoverHandler { id: showAllHov }
                    TapHandler { onTapped: root.showAllTracks = !root.showAllTracks }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                }
            }

            Item { height: 8; visible: root.topTracks.length > 0 }

            Repeater {
                model: root.showAllTracks ? root.topTracks : root.topTracks.slice(0, 5)
                TrackRow {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    // Against the width this row would have with the sidebar
                    // out, so the column cannot reappear as the window
                    // narrows. See root.sidebarReclaim.
                    showAlbum:   width - root.sidebarReclaim >= albumBreakpoint
                    trackNum:    index + 1
                    title:       modelData.title
                    artists:     modelData.artists
                    albumTitle:  modelData.albumTitle
                    durationStr: modelData.durationStr
                    coverUrl:    modelData.coverUrl80
                    isPlaying:   player.currentTrack.id === modelData.id && player.playing
                    trackData:   modelData
                    onPlayRequested: root.playFrom(root.topTracks, index)
                }
            }

            Item { height: 24; visible: root.topTracks.length > 0 }

            HorizontalSection {
                id: albumsSection
                Layout.fillWidth: true
                property var mainAlbums: root.albums.filter(function(a) {
                    var t = a.type || ""
                    if (t === "SINGLE" || t === "EP") return false
                    if (t === "ALBUM" || t === "COMPILATION") return true
                    return (a.numTracks || 1) > 3
                })
                visible: mainAlbums.length > 0
                title: singlesSection.singles.length > 0 ? qsTr("Albums") : qsTr("Discography")
                showViewAll: false
                mediaType: "album"
                items: mainAlbums.map(function(a) {
                    return { id: a.id, title: a.title, subtitle: a.year, coverUrl: a.coverUrl }
                })
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                // Declares the source, so the player bar records the play. See
                // the same change in HomePage.
                onItemPlayClicked: function(i, item) {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (err || tracks.length === 0) return
                        player.setPlaybackSource("album", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
            }

            HorizontalSection {
                id: singlesSection
                Layout.fillWidth: true
                property var singles: root.albums.filter(function(a) {
                    var t = a.type || ""
                    if (t === "SINGLE" || t === "EP") return true
                    if (t === "ALBUM" || t === "COMPILATION") return false
                    return (a.numTracks || 1) <= 3
                })
                visible: singles.length > 0
                title: qsTr("Singles & EPs")
                showViewAll: false
                mediaType: "album"
                items: singles.map(function(a) {
                    return { id: a.id, title: a.title, subtitle: a.year, coverUrl: a.coverUrl }
                })
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                onItemPlayClicked: function(i, item) {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (err || tracks.length === 0) return
                        player.setPlaybackSource("album", "" + item.id, item.title || "")
                        player.playTracks(tracks, 0)
                    })
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                visible: (artistData.bio || "").length > 0
                spacing: 8

                Item { height: 8 }

                Text {
                    text: qsTr("About")
                    color: Theme.textPrimary
                    font.pixelSize: 20
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: root.formatBio(artistData.bio || "")
                    color: Theme.textSec
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    lineHeight: 1.5
                    textFormat: Text.RichText
                    onLinkActivated: (link) => {
                        var parts = link.split(":")
                        if (parts.length === 2) {
                            var type = parts[0]
                            var id = Number(parts[1])
                            if (type === "artist") {
                                navigateTo("artist", { artistId: id })
                            } else if (type === "album") {
                                navigateTo("album", { albumId: id })
                            }
                        }
                    }
                }
            }

            HorizontalSection {
                Layout.fillWidth: true
                visible: (artistData.similarArtists || []).length > 0
                title: qsTr("Related Artists")
                mediaType: "artist"
                showViewAll: false
                items: (artistData.similarArtists || []).map(function(a) {
                    return { id: a.id, title: a.name, subtitle: qsTr("Artist"), coverUrl: a.coverUrl || "" }
                })
                onItemClicked: function(i, item) { navigateTo("artist", { artistId: item.id }) }
            }

            Item { height: 32 }
        }
    }

    function formatBio(bio) {
        if (!bio) return ""
        var html = bio
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
        html = html.replace(/\[wimpLink\s+(artistId|albumId|playlistId|trackId)="([^"]+)"\](.*?)\[\/wimpLink\]/g, function(match, typeAttr, id, text) {
            var type = typeAttr.replace("Id", "")
            return "<a href='" + type + ":" + id + "' style='color: " + Theme.accent + "; text-decoration: none; font-weight: bold;'>" + text + "</a>"
        })
        return html.replace(/\n/g, "<br/>")
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params)
    }

    // P2. The pin carries the labels and the artwork the page is showing, so
    // the sidebar row reads the same as the page it came from.
    readonly property alias pinMenu: heroPinMenu

    function showHeroPinMenu(x, y) {
        heroPinMenu.showPin(x, y, "artist", root.artistId > 0 ? "" + root.artistId : "",
                            root.artistData.name || "", "", root.artistData.coverUrl || "")
    }

    ContextMenu {
        id: heroPinMenu
        objectName: "heroPinMenu"
        // No trackSource, so the menu offers no queue actions here. An artist
        // is not a tracklist: the only thing to queue would be the top ten,
        // which is a chart position rather than anything the user picked, so
        // "add this artist to the queue" would not mean what it says. Play and
        // Shuffle in the hero still play those tracks, which is honest because
        // the button says play, not queue. Pinning is unaffected.

        // The hero's action row, which has the page above it to draw over.
        confirmAnchor: heroActions
    }

    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52; color: "transparent"
        BackButton { anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 } }
    }

    LoadingOverlay { loading: root.loading }
}
