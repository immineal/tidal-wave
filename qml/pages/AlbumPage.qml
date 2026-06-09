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

    function updateSavedState() {
        isSaved = albumId > 0 ? bridge.isAlbumFavorite(albumId) : false
    }

    readonly property int effectiveArtistId: albumData.artistId > 0 ? albumData.artistId
        : (tracks.length > 0 && tracks[0].artistId > 0 ? tracks[0].artistId : 0)

    onAlbumIdChanged: if (albumId > 0) { loadAlbum(); updateSavedState() }

    Connections {
        target: bridge
        function onFavoriteAlbumsChanged() { root.updateSavedState() }
    }

    function loadAlbum() {
        loading = true
        bridge.fetchAlbum(albumId, function(album, err) {
            if (!err) albumData = album
        })
        bridge.fetchAlbumTracks(albumId, function(t, err) {
            loading = false
            if (!err) tracks = t
        })
    }

    ListView {
        id: tracksList
        anchors.fill: parent
        clip: true
        model: root.tracks
        boundsBehavior: Flickable.StopAtBounds

        header: Column {
            width: tracksList.width

            // Hero header
            Rectangle {
                width: parent.width
                height: 280
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
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0; color: Qt.rgba(0.04,0.04,0.04,0.6) }
                        GradientStop { position: 1; color: Theme.bg }
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    anchors.leftMargin: 64
                    spacing: 24

                    Rectangle {
                        width: 200
                        height: 200
                        radius: Theme.radiusLg
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
                            text: "Album"
                            color: Theme.textDim
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

                        Text {
                            id: artistNameText
                            text: albumData.artists || ""
                            color: root.effectiveArtistId > 0 ? Theme.accent : Theme.textSec
                            font.pixelSize: 14
                            activeFocusOnTab: root.effectiveArtistId > 0
                            Keys.onReturnPressed: if (root.effectiveArtistId > 0) root.navigateTo("artist", { artistId: root.effectiveArtistId })
                            Keys.onSpacePressed:  if (root.effectiveArtistId > 0) root.navigateTo("artist", { artistId: root.effectiveArtistId })
                            Rectangle {
                                anchors.fill: parent; anchors.margins: -4; radius: 4; color: "transparent"
                                border.width: artistNameText.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: root.effectiveArtistId > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: if (root.effectiveArtistId > 0) root.navigateTo("artist", { artistId: root.effectiveArtistId })
                            }
                        }

                        Text {
                            text: {
                                var parts = []
                                if (albumData.year) parts.push(albumData.year)
                                if (albumData.numTracks) parts.push(albumData.numTracks + (albumData.numTracks === 1 ? " track" : " tracks"))
                                if (albumData.duration > 0) {
                                    var d = albumData.duration
                                    var hrs = Math.floor(d / 3600)
                                    var mins = Math.floor((d % 3600) / 60)
                                    parts.push(hrs > 0 ? hrs + " hr " + mins + " min" : mins + " min")
                                }
                                if (albumData.quality) parts.push(albumData.quality)
                                return parts.join(" • ")
                            }
                            color: Theme.textSec
                            font.pixelSize: 13
                        }

                        Row {
                            spacing: 12

                            PillButton {
                                text: "Play"
                                glyph: "▶"
                                accent: true
                                onClicked: if (root.tracks.length > 0) player.playTracks(root.tracks, 0)
                            }

                            PillButton {
                                text: "Shuffle"
                                glyph: "⇌"
                                accent: false
                                onClicked: {
                                    if (root.tracks.length > 0) {
                                        player.setShuffle(true)
                                        player.playTracks(root.tracks, Math.floor(Math.random() * root.tracks.length))
                                    }
                                }
                            }

                            PillButton {
                                text: root.isSaved ? "Saved" : "Save"
                                glyph: root.isSaved ? "♥" : "♡"
                                accent: root.isSaved
                                onClicked: {
                                    if (root.isSaved) {
                                        bridge.removeAlbumFavorite(root.albumId, function(success) {})
                                    } else {
                                        bridge.addAlbumFavorite(root.albumId, function(success) {})
                                    }
                                }
                            }
                        }
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
            onPlayRequested: player.playTracks(root.tracks, index)
        }

        footer: Item { height: 32; width: tracksList.width }

        ScrollBar.vertical: ScrollBar {
            active: true
            policy: ScrollBar.AsNeeded
        }
    }

    // Sticky bar — back button always visible; title fades in once hero scrolls out
    Rectangle {
        id: stickyHeader
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52
        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b,
                       Math.min(0.95, Math.max(0, (tracksList.contentY - 200) / 80)))

        BackButton { anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 } }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 64
            anchors.rightMargin: 16
            spacing: 12
            opacity: Math.min(1, Math.max(0, (tracksList.contentY - 200) / 80))
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
                Text {
                    Layout.fillWidth: true
                    text: albumData.artists || ""
                    color: Theme.textSec
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border
            opacity: Math.min(1, Math.max(0, (tracksList.contentY - 200) / 80))
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params || {})
    }

    LoadingOverlay { loading: root.loading }
}
