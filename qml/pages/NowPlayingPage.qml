import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var track: player.currentTrack  // QVariantMap
    property bool hasTrack: track && track.id > 0
    property bool isLiked: false

    Connections {
        target: bridge
        function onFavoriteTracksChanged() { root.updateLikedState() }
    }
    Connections {
        target: player
        function onCurrentTrackChanged() { root.updateLikedState() }
    }
    function updateLikedState() {
        isLiked = (hasTrack && track.id > 0)
            ? bridge.isTrackFavorite(track.id)
            : false
    }
    Component.onCompleted: updateLikedState()

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(0,0.698,0.973,0.07) }
            GradientStop { position: 1; color: Theme.bg }
        }
    }

    ColumnLayout {
        anchors.fill: parent; anchors.margins: 48; spacing: 32

        Text {
            id: backLink
            text: "←  Now Playing"; color: Theme.textSec; font.pixelSize: 14
            activeFocusOnTab: true
            Keys.onReturnPressed: Window.window.goBack()
            Keys.onSpacePressed:  Window.window.goBack()
            Rectangle {
                anchors.fill: parent
                anchors.margins: -4
                radius: 4
                color: "transparent"
                border.width: backLink.activeFocus ? 2 : 0
                border.color: Theme.accent
            }
            MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: Window.window.goBack()
            }
        }

        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 64

            Rectangle {
                id: coverBox
                Layout.preferredWidth: Math.min(parent.width * 0.45, 420)
                Layout.preferredHeight: Layout.preferredWidth
                Layout.alignment: Qt.AlignVCenter
                radius: Theme.radiusLg; color: Theme.surfaceHigh; clip: true
                Image {
                    anchors.fill: parent
                    source: hasTrack ? "image://tidal/" + track.coverUrl : ""
                    fillMode: Image.PreserveAspectCrop; smooth: true; mipmap: true
                }
            }

            ColumnLayout {
                Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 24

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 16

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            text: hasTrack ? track.title : "—"; color: Theme.textPrimary
                            font.pixelSize: 32; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true
                        }
                        Text {
                            id: artistLink
                            text: hasTrack ? track.artists : ""; color: Theme.accent; font.pixelSize: 18
                            activeFocusOnTab: hasTrack && Number(track.artistId) > 0
                            Keys.onReturnPressed: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                            Keys.onSpacePressed:  if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                            Rectangle {
                                anchors.fill: parent; anchors.margins: -4; radius: 4; color: "transparent"
                                border.width: artistLink.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                            }
                        }
                        Text {
                            id: albumLink
                            text: hasTrack ? track.albumTitle : ""; color: Theme.textSec; font.pixelSize: 15
                            activeFocusOnTab: hasTrack && Number(track.albumId) > 0
                            Keys.onReturnPressed: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                            Keys.onSpacePressed:  if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                            Rectangle {
                                anchors.fill: parent; anchors.margins: -4; radius: 4; color: "transparent"
                                border.width: albumLink.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                            }
                        }
                    }

                    CtrlBtn {
                        id: npLikeBtn
                        visible: root.hasTrack
                        icon: root.isLiked ? "heart-filled" : "heart"
                        size: 24
                        active: root.isLiked
                        onClicked: {
                            var trackId = root.track.id
                            if (root.isLiked) {
                                bridge.removeTrackFavorite(trackId, function(success) {})
                            } else {
                                bridge.addTrackFavorite(trackId, function(success) {})
                            }
                        }
                    }
                }

                // Quality badge
                Rectangle {
                    visible: player.audioQuality.length > 0
                    height: 24; width: qlbl.implicitWidth + 12; radius: 4
                    color: player.audioQuality === "HI_RES_LOSSLESS" ? "#1a4a7a" :
                           player.audioQuality === "LOSSLESS" ? "#1a4a3a" : Theme.surfaceHigh
                    Text {
                        id: qlbl; anchors.centerIn: parent
                        text: player.audioQuality === "HI_RES_LOSSLESS" ? "⚛ MASTER" :
                              player.audioQuality === "LOSSLESS" ? "◆ LOSSLESS" :
                              player.audioQuality
                        color: Theme.accent; font.pixelSize: 11; font.bold: true
                    }
                }

                SeekBar {
                    Layout.fillWidth: true
                    position: player.position; duration: player.duration
                    onSeeked: (ms) => player.seek(ms)
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 16
                    CtrlBtn { icon: "shuffle"; size: 24; active: player.shuffle; onClicked: player.setShuffle(!player.shuffle) }
                    Item { Layout.fillWidth: true }
                    CtrlBtn { icon: "previous"; size: 28; onClicked: player.previous() }
                    Rectangle {
                        id: npPlayPause
                        width: 64; height: 64; radius: 32; color: Theme.textPrimary
                        border.width: activeFocus ? 2 : 0
                        border.color: Theme.accent
                        activeFocusOnTab: true
                        Keys.onReturnPressed: player.playPause()
                        Keys.onSpacePressed:  player.playPause()
                        VectorIcon {
                            anchors.centerIn: parent
                            name: player.playing ? "pause" : "play"
                            color: Theme.bg
                            width: 22
                            height: 22
                            strokeWidth: 1.5
                        }
                        scale: pHov.hovered ? 0.95 : 1; Behavior on scale { NumberAnimation { duration: 100 } }
                        HoverHandler { id: pHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler   { onTapped: player.playPause() }
                    }
                    CtrlBtn { icon: "next"; size: 28; onClicked: player.next() }
                    Item { Layout.fillWidth: true }
                    CtrlBtn { icon: player.repeatMode === 2 ? "repeat-one" : "repeat"; size: 24; active: player.repeatMode > 0; onClicked: player.setRepeatMode((player.repeatMode + 1) % 3) }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    Item {
                        id: muteBtn
                        width: 18; height: 18
                        activeFocusOnTab: true
                        Keys.onReturnPressed: player.setMuted(!player.muted)
                        Keys.onSpacePressed:  player.setMuted(!player.muted)
                        Rectangle {
                            anchors.fill: parent; anchors.margins: -4; radius: 4; color: "transparent"
                            border.width: muteBtn.activeFocus ? 2 : 0
                            border.color: Theme.accent
                        }
                        VectorIcon {
                            anchors.fill: parent
                            name: player.muted ? "volume-mute" : (player.volume < 0.3 ? "volume-low" : player.volume < 0.7 ? "volume-mid" : "volume-high")
                            color: Theme.textSec
                            strokeWidth: 1.5
                        }
                        MouseArea { anchors.fill: parent; onClicked: player.setMuted(!player.muted); cursorShape: Qt.PointingHandCursor }
                    }
                    VolumeSlider {
                        Layout.fillWidth: true
                        value: player.muted ? 0 : player.volume
                        onMoved: (v) => { player.setMuted(false); player.setVolume(v) }
                    }
                    Text { text: Math.round((player.muted ? 0 : player.volume)*100)+"%"; color: Theme.textDim; font.pixelSize: 12; width: 36 }
                }
            }
        }
    }

    component CtrlBtn : Item {
        id: ctrlBtn
        property string icon; property int size: 24; property bool active: false
        signal clicked()
        width: size+20; height: size+20
        activeFocusOnTab: true
        Keys.onReturnPressed: clicked()
        Keys.onSpacePressed:  clicked()
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: ctrlBtn.activeFocus ? 2 : 0
            border.color: Theme.accent
        }
        VectorIcon {
            anchors.centerIn: parent
            name: parent.icon
            color: parent.active ? Theme.accent : hov.hovered ? Theme.textPrimary : Theme.textSec
            width: parent.size
            height: parent.size
            strokeWidth: 1.5
        }
        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: parent.clicked() }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params || {})
    }
}
