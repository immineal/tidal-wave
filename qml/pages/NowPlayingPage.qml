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
            text: "←  Now Playing"; color: Theme.textSec; font.pixelSize: 14
            MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: {
                    var win = Window.window
                    win.navigate(win.previousPage, win.previousPageParams)
                }
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
                    fillMode: Image.PreserveAspectCrop; smooth: true
                }
            }

            ColumnLayout {
                Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: 24

                ColumnLayout {
                    spacing: 8
                    Text {
                        text: hasTrack ? track.title : "—"; color: Theme.textPrimary
                        font.pixelSize: 32; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true
                    }
                    Text {
                        text: hasTrack ? track.artists : ""; color: Theme.accent; font.pixelSize: 18
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                        }
                    }
                    Text {
                        text: hasTrack ? track.albumTitle : ""; color: Theme.textSec; font.pixelSize: 15
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
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
                    CtrlBtn { icon: "⇌"; size: 24; active: player.shuffle; onClicked: player.setShuffle(!player.shuffle) }
                    Item { Layout.fillWidth: true }
                    CtrlBtn { icon: "⏮"; size: 28; onClicked: player.previous() }
                    Rectangle {
                        width: 64; height: 64; radius: 32; color: Theme.textPrimary
                        Text { anchors.centerIn: parent; text: player.playing ? "⏸" : "▶"; color: Theme.bg; font.pixelSize: player.playing ? 22 : 20; leftPadding: player.playing ? 0 : 3 }
                        scale: pHov.hovered ? 0.95 : 1; Behavior on scale { NumberAnimation { duration: 100 } }
                        HoverHandler { id: pHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler   { onTapped: player.playPause() }
                    }
                    CtrlBtn { icon: "⏭"; size: 28; onClicked: player.next() }
                    Item { Layout.fillWidth: true }
                    CtrlBtn { icon: player.repeatMode === 2 ? "↺₁" : "↺"; size: 24; active: player.repeatMode > 0; onClicked: player.setRepeatMode((player.repeatMode + 1) % 3) }
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    VectorIcon {
                        name: player.muted ? "volume-mute" : (player.volume < 0.3 ? "volume-low" : player.volume < 0.7 ? "volume-mid" : "volume-high")
                        color: Theme.textSec
                        width: 18
                        height: 18
                        strokeWidth: 1.5
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
        property string icon; property int size: 24; property bool active: false
        signal clicked()
        width: size+20; height: size+20
        Text {
            anchors.centerIn: parent; text: parent.icon
            color: parent.active ? Theme.accent : hov.hovered ? Theme.textPrimary : Theme.textSec
            font.pixelSize: parent.size; Behavior on color { ColorAnimation { duration: 100 } }
        }
        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: parent.clicked() }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params || {})
    }
}
