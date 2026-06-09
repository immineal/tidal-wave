import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var artistId: 0
    property var artistData: ({})
    property var topTracks: []
    property var albums: []
    property bool loading: false
    property bool showAllTracks: false
    property bool isFollowing: false

    function updateFollowState() {
        isFollowing = artistId > 0 ? bridge.isArtistFavorite(artistId) : false
    }

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
            if (!err) albums = a
        })
    }

    ScrollView {
        anchors.fill: parent
        rightPadding: 14
        contentWidth: availableWidth

        ColumnLayout {
            width: parent.width
            spacing: 0

            // Hero
            Rectangle {
                Layout.fillWidth: true
                height: 320
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
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.margins: 28
                    spacing: 8

                    Text {
                        text: artistData.name || ""
                        color: Theme.textPrimary
                        font.pixelSize: 36
                        font.bold: true
                        style: Text.Outline
                        styleColor: Qt.rgba(0, 0, 0, 0.5)
                    }

                    PillButton {
                        text: "Play"
                        glyph: "▶"
                        accent: true
                        onClicked: if (topTracks.length > 0) player.playTracks(topTracks, 0)
                    }

                    PillButton {
                        text: root.isFollowing ? "Following" : "Follow"
                        glyph: root.isFollowing ? "♥" : "♡"
                        accent: root.isFollowing
                        onClicked: {
                            if (root.isFollowing) {
                                bridge.removeArtistFavorite(root.artistId, function(success) {})
                            } else {
                                bridge.addArtistFavorite(root.artistId, function(success) {})
                            }
                        }
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
                    text: "Popular"
                    color: Theme.textPrimary
                    font.pixelSize: 20
                    font.bold: true
                    Layout.fillWidth: true
                }
                Text {
                    visible: root.topTracks.length > 5
                    text: root.showAllTracks ? "Show less" : "Show all"
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
                    trackNum:    index + 1
                    title:       modelData.title
                    artists:     modelData.artists
                    albumTitle:  modelData.albumTitle
                    durationStr: modelData.durationStr
                    coverUrl:    modelData.coverUrl80
                    isPlaying:   player.currentTrack.id === modelData.id && player.playing
                    trackData:   modelData
                    onPlayRequested: player.playTracks(root.topTracks, index)
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
                title: singlesSection.singles.length > 0 ? "Albums" : "Discography"
                showViewAll: false
                mediaType: "album"
                items: mainAlbums.map(function(a) {
                    return { id: a.id, title: a.title, subtitle: a.year, coverUrl: a.coverUrl }
                })
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                onItemPlayClicked: function(i, item) {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (!err && tracks.length > 0) player.playTracks(tracks, 0)
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
                title: "Singles & EPs"
                showViewAll: false
                mediaType: "album"
                items: singles.map(function(a) {
                    return { id: a.id, title: a.title, subtitle: a.year, coverUrl: a.coverUrl }
                })
                onItemClicked: function(i, item) { navigateTo("album", { albumId: item.id }) }
                onItemPlayClicked: function(i, item) {
                    bridge.fetchAlbumTracks(item.id, function(tracks, err) {
                        if (!err && tracks.length > 0) player.playTracks(tracks, 0)
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
                    text: "About"
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
                title: "Related Artists"
                mediaType: "artist"
                showViewAll: false
                items: (artistData.similarArtists || []).map(function(a) {
                    return { id: a.id, title: a.name, subtitle: "Artist", coverUrl: a.coverUrl || "" }
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

    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52; color: "transparent"
        BackButton { anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 } }
    }

    LoadingOverlay { loading: root.loading }
}
