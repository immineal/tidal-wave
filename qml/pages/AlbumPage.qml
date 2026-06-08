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

    readonly property int effectiveArtistId: albumData.artistId > 0 ? albumData.artistId
        : (tracks.length > 0 && tracks[0].artistId > 0 ? tracks[0].artistId : 0)

    onAlbumIdChanged: if (albumId > 0) loadAlbum()

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
                            text: (albumData.year || "") +
                                  (albumData.numTracks ? " • " + albumData.numTracks + (albumData.numTracks === 1 ? " track" : " tracks") : "") +
                                  (albumData.quality ? " • " + albumData.quality : "")
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
                        }
                    }
                }
            }

            Item { height: 8; width: parent.width }

            // Column header
            Rectangle {
                width: parent.width
                height: 32
                color: "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 28
                    anchors.rightMargin: 28
                    spacing: 12
                    Text { width: 24; text: "#"; color: Theme.textDim; font.pixelSize: 12 }
                    Text { Layout.fillWidth: true; text: "TITLE"; color: Theme.textDim; font.pixelSize: 12; font.letterSpacing: 0.5 }
                    Text { width: 40; text: "⏱"; color: Theme.textDim; font.pixelSize: 12; horizontalAlignment: Text.AlignRight }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
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

    function navigateTo(page, params) {
        Window.window.navigate(page, params || {})
    }

    BackButton { anchors { top: parent.top; left: parent.left; margins: 16 } }

    LoadingOverlay { loading: root.loading }
}
