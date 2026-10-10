import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    // The width the collapsed sidebar hands back. Below the rail breakpoint the
    // pane gets wider as the window narrows, so a breakpoint subtracts this to
    // measure against a width that only shrinks with the window.
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

    // What the last load was told, "" when it was served.
    property string loadError: ""

    // Nothing came back at all. Every section hides when its list is empty, so
    // a refused artist would be a blank page. Gated on what the server said, so
    // an artist still in flight or with nothing filed is not called gone.
    readonly property bool loadFailed:
        loadError.length > 0 && !loading && !artistData.name
        && topTracks.length === 0 && albums.length === 0

    // The first reason is kept: all three calls fail with the same message.
    function noteLoadError(err) {
        if (root.loadError.length === 0) root.loadError = err
    }

    // Records this artist as the "playing from" source, then plays.
    function playFrom(list, i) {
        player.setPlaybackSource("artist", "" + root.artistId, root.artistData.name || "")
        player.playTracks(list, i)
    }

    function updateFollowState() {
        isFollowing = artistId > 0 ? bridge.isArtistFavorite(artistId) : false
    }

    // The Follow pill's one call, and what it says when the server refuses it.
    // isFollowing is read back from the bridge and never written here.
    readonly property alias favoriteAction: artistFav
    ContextMenu.FavoriteAction { id: artistFav }

    onArtistIdChanged: if (artistId > 0) { loadArtist(); updateFollowState() }

    Connections {
        target: bridge
        function onFavoriteArtistsChanged() { root.updateFollowState() }
    }

    function loadArtist() {
        loading = true
        loadError = ""
        // Which artist these three replies are about. Main.qml reuses this page
        // item when one artist navigates to another, so a reply for the artist
        // just left must not touch the one on screen. Checked before the error.
        var requested = artistId
        bridge.fetchArtistDetail(artistId, function(d, err) {
            if (requested !== root.artistId) return
            if (err) { root.noteLoadError(err); return }
            root.artistData = d
        })
        bridge.fetchArtistTopTracks(artistId, function(t, err) {
            if (requested !== root.artistId) return
            if (err) { root.noteLoadError(err); return }
            root.topTracks = t
        })
        bridge.fetchArtistAlbums(artistId, function(a, err) {
            if (requested !== root.artistId) return
            root.loading = false
            if (err) { root.noteLoadError(err); return }
            // TidalClient::fetchArtistAlbums merges its three requests, so this
            // callback is the only place that clears `loading`. Tidal lists
            // every edition of a release under its own id: collapse them.
            root.albums = root.dedupeEditions(a)
        })
    }

    // Title without trailing edition qualifiers: "1989 (Deluxe Edition)
    // [Explicit]" becomes "1989". Only trailing parenthesised or bracketed
    // suffixes are stripped.
    function baseTitle(t) {
        var s = ("" + (t || "")).toLowerCase().trim()
        for (var k = 0; k < 2; k++)
            s = s.replace(/\s*[\(\[][^\(\)\[\]]*[\)\]]\s*$/, "").trim()
        return s
    }

    // True for the Singles & EPs row, false for the Albums row. Tidal's `type`
    // is the rule and the track count only a fallback for a response that omits
    // it. dedupeEditions() keys on this answer too.
    function isSingleOrEp(a) {
        var t = a.type || ""
        if (t === "SINGLE" || t === "EP") return true
        if (t === "ALBUM" || t === "COMPILATION") return false
        return (a.numTracks || 1) <= 3
    }

    // Collapses editions of one release, keyed on artwork and base title. The
    // section is part of the key: a lead single often carries its album's
    // artwork and title, and the two must stay separate rows.
    function dedupeEditions(list) {
        var seen = ({})
        var out = []
        for (var i = 0; i < list.length; i++) {
            var a = list[i]
            var cover = a.coverUrl || ("id:" + a.id)
            var key = (root.isSingleOrEp(a) ? "s" : "a") + ""
                      + cover + "" + root.baseTitle(a.title)
            if (seen[key]) continue
            seen[key] = true
            out.push(a)
        }
        return out
    }

    ScrollView {
        objectName: "artistContent"
        anchors.fill: parent
        rightPadding: 14
        contentWidth: availableWidth
        // Hidden, not covered: behind the error panel the Play and Follow pills
        // would still be hit targets and tab stops for an artist the API will
        // not answer for.
        visible: !root.loadFailed

        ColumnLayout {
            width: parent.width
            spacing: 0

            // Hero. Grows with its content, so a wrapped name or pill row fits.
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
                    // Anchored right too, so a long name has room to wrap.
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

                    // A Flow, so the pills wrap when a translation widens them.
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
                            // On the action row, which has clear space above.
                            onClicked: root.favoriteAction.toggleArtist(root.artistId, root.isFollowing,
                                                                      heroActions)
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
                objectName: "artistAlbumsSection"
                Layout.fillWidth: true
                property var mainAlbums: root.albums.filter(function(a) {
                    return !root.isSingleOrEp(a)
                })
                visible: mainAlbums.length > 0
                title: singlesSection.singles.length > 0 ? qsTr("Albums") : qsTr("Discography")
                showViewAll: false
                mediaType: "album"
                items: mainAlbums.map(function(a) {
                    return { id: a.id, title: a.title, subtitle: a.year, coverUrl: a.coverUrl }
                })
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                // Declares the source, so the player bar records the play.
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
                objectName: "artistSinglesSection"
                Layout.fillWidth: true
                property var singles: root.albums.filter(function(a) {
                    return root.isSingleOrEp(a)
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

    // The pin carries the labels and the artwork the page is showing, so the
    // sidebar row reads the same as the page it came from.
    readonly property alias pinMenu: heroPinMenu

    function showHeroPinMenu(x, y) {
        heroPinMenu.showPin(x, y, "artist", root.artistId > 0 ? "" + root.artistId : "",
                            root.artistData.name || "", "", root.artistData.coverUrl || "")
    }

    ContextMenu {
        id: heroPinMenu
        objectName: "heroPinMenu"
        // No trackSource, so no queue actions: an artist is not a tracklist.

        // The hero's action row, which has the page above it to draw over.
        confirmAnchor: heroActions
    }

    // What the page says when there is nothing to draw and a reason for it.
    // Declared before the back-button bar so the bar stays on top.
    Rectangle {
        objectName: "artistLoadError"
        anchors.fill: parent
        visible: root.loadFailed
        color: Theme.bg

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 96, 420)
            spacing: 10

            VectorIcon {
                Layout.alignment: Qt.AlignHCenter
                // A Layout owns the size of its direct children, so a plain
                // width would be overwritten.
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                name: "artist"
                color: Theme.textDim
                strokeWidth: 1.5
            }

            Text {
                objectName: "artistLoadErrorText"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("This artist is not available")
                color: Theme.textPrimary
                font.pixelSize: 18
                font.bold: true
                wrapMode: Text.WordWrap
            }

            // Not the server's own string, which is a Qt network error with the
            // request URL in it.
            Text {
                objectName: "artistLoadErrorDetail"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                // One long literal: lupdate cannot read a concatenation.
                text: qsTr("Tidal would not serve the page for this artist. They may have been removed from the catalogue, or they may not be available where you are. Searching for the name often finds their releases anyway.")
                color: Theme.textSec
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }
        }
    }

    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52; color: "transparent"
        BackButton { anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 } }
    }

    LoadingOverlay { loading: root.loading }
}
