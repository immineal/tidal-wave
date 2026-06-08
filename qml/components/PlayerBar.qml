import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

Rectangle {
    id: root
    height: 82
    color: Theme.surface

    Rectangle { width: parent.width; height: 1; color: Theme.border }

    signal showQueue()
    signal showNowPlaying()

    property var track: player.currentTrack  // QVariantMap
    property bool hasTrack: track && track.id > 0

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 0

        // ── Track info (left) ──────────────────────────
        RowLayout {
            Layout.preferredWidth: 280
            Layout.minimumWidth: 200
            spacing: 12

            Rectangle {
                width: 56; height: 56; radius: 4
                color: Theme.surfaceHigh; clip: true
                Image {
                    anchors.fill: parent
                    source: hasTrack ? "image://tidal/" + track.coverUrl : ""
                    fillMode: Image.PreserveAspectCrop; smooth: true
                }
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: root.showNowPlaying()
                }
            }

            ColumnLayout {
                Layout.fillWidth: true; spacing: 3; clip: true

                Text {
                    Layout.fillWidth: true
                    text: hasTrack ? track.title : "No track playing"
                    color: Theme.textPrimary; font.pixelSize: 14; font.bold: true; elide: Text.ElideRight
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showNowPlaying() }
                }
                Text {
                    Layout.fillWidth: true
                    text: hasTrack ? track.artists : ""
                    color: Theme.textSec; font.pixelSize: 12; elide: Text.ElideRight
                }
                Rectangle {
                    visible: hasTrack && player.audioQuality.length > 0
                    height: 16; width: ql.implicitWidth + 8; radius: 3
                    color: {
                        var q = player.audioQuality
                        if (q === "HI_RES_LOSSLESS") return "#1a4a7a"
                        if (q === "LOSSLESS") return "#1a4a3a"
                        return Theme.surfaceHigh
                    }
                    Text {
                        id: ql; anchors.centerIn: parent
                        text: {
                            var q = player.audioQuality
                            if (q === "HI_RES_LOSSLESS") return "MAX"
                            if (q === "LOSSLESS") return "LOSSLESS"
                            return q
                        }
                        color: Theme.accent; font.pixelSize: 9; font.bold: true
                    }
                }
            }
        }

        // ── Central controls ───────────────────────────
        ColumnLayout {
            Layout.fillWidth: true; spacing: 4

            RowLayout {
                Layout.alignment: Qt.AlignHCenter; spacing: 8

                IconButton { icon: "⇌"; size: 18; iconColor: player.shuffle ? Theme.accent : Theme.textSec; onClicked: player.setShuffle(!player.shuffle) }
                IconButton { icon: "⏮"; size: 22; iconColor: Theme.textPrimary; onClicked: player.previous() }

                Rectangle {
                    width: 40; height: 40; radius: 20; color: Theme.textPrimary
                    Text {
                        anchors.centerIn: parent
                        text: player.loading ? "…" : (player.playing ? "⏸" : "▶")
                        color: Theme.bg; font.pixelSize: player.playing ? 16 : 14; leftPadding: player.playing ? 0 : 2
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler   { onTapped: player.playPause() }
                }

                IconButton { icon: "⏭"; size: 22; iconColor: Theme.textPrimary; onClicked: player.next() }
                IconButton {
                    icon: player.repeatMode === 2 ? "↺₁" : "↺"; size: 18
                    iconColor: player.repeatMode > 0 ? Theme.accent : Theme.textSec
                    onClicked: player.setRepeatMode((player.repeatMode + 1) % 3)
                }
            }

            SeekBar {
                Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                position: player.position; duration: player.duration
                onSeeked: (ms) => player.seek(ms)
            }
        }

        // ── Right controls ─────────────────────────────
        RowLayout {
            Layout.preferredWidth: 220; Layout.minimumWidth: 160
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter; spacing: 8

            Item { Layout.fillWidth: true }

            IconButton {
                icon: player.muted ? "vol-mute" : (player.volume < 0.3 ? "vol-low" : player.volume < 0.7 ? "vol-mid" : "vol-high")
                size: 18; iconColor: Theme.textSec
                onClicked: player.setMuted(!player.muted)
            }

            VolumeSlider {
                width: 90
                value: player.muted ? 0 : player.volume
                onMoved: (v) => { player.setMuted(false); player.setVolume(v) }
            }

            IconButton {
                icon: "≡"; size: 20
                iconColor: Theme.textSec
                onClicked: root.showQueue()
            }
        }
    }

    component IconButton : Item {
        property string icon
        property color  iconColor: Theme.textSec
        property int    size: 18
        signal clicked()
        width: Math.max(size + 12, 32)
        height: Math.max(size + 12, 32)

        Loader {
            anchors.centerIn: parent
            sourceComponent: (icon.startsWith("vol-") || icon === "music" || icon === "artist") ? vectorComp : textComp
        }

        Component {
            id: textComp
            Text {
                text: icon
                color: hov.hovered ? Theme.textPrimary : iconColor
                font.pixelSize: size
                Behavior on color { ColorAnimation { duration: 100 } }
            }
        }

        Component {
            id: vectorComp
            VectorIcon {
                name: {
                    if (icon === "vol-mute") return "volume-mute"
                    if (icon === "vol-low") return "volume-low"
                    if (icon === "vol-mid") return "volume-mid"
                    if (icon === "vol-high") return "volume-high"
                    return icon
                }
                color: hov.hovered ? Theme.textPrimary : iconColor
                width: size
                height: size
                strokeWidth: 1.5
            }
        }

        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: parent.clicked() }
    }
}
