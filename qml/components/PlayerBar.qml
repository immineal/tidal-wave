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
                    fillMode: Image.PreserveAspectCrop; smooth: true; mipmap: true
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
                        text: player.qualityLabel(player.audioQuality).toUpperCase()
                        color: Theme.accent; font.pixelSize: 9; font.bold: true
                    }
                }
            }

            IconButton {
                id: likeBtn
                visible: root.hasTrack
                icon: root.isLiked ? "heart-filled" : "heart"
                size: 16
                iconColor: root.isLiked ? Theme.accent : Theme.textSec
                ToolTip.visible: likeTipHov.hovered
                ToolTip.text: root.isLiked ? "Unlike track" : "Like track"
                ToolTip.delay: 600
                HoverHandler { id: likeTipHov }
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

        // ── Central controls ───────────────────────────
        ColumnLayout {
            Layout.fillWidth: true; spacing: 4

            RowLayout {
                Layout.alignment: Qt.AlignHCenter; spacing: 8

                IconButton { icon: "shuffle"; size: 18; iconColor: player.shuffle ? Theme.accent : Theme.textSec; onClicked: player.setShuffle(!player.shuffle) }
                IconButton { icon: "previous"; size: 22; iconColor: Theme.textPrimary; onClicked: player.previous() }

                Rectangle {
                    id: playPauseBtn
                    width: 40; height: 40; radius: 20; color: Theme.textPrimary
                    border.width: activeFocus ? 2 : 0
                    border.color: Theme.accent
                    activeFocusOnTab: true
                    Keys.onReturnPressed: player.playPause()
                    Keys.onSpacePressed:  player.playPause()
                    VectorIcon {
                        anchors.centerIn: parent
                        name: player.playing ? "pause" : "play"
                        color: Theme.bg
                        width: 24
                        height: 24
                        strokeWidth: 1.5
                        visible: !player.loading
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "…"
                        color: Theme.bg; font.pixelSize: 14
                        visible: player.loading
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler   { onTapped: player.playPause() }
                }

                IconButton { icon: "next"; size: 22; iconColor: Theme.textPrimary; onClicked: player.next() }
                IconButton {
                    icon: player.repeatMode === 2 ? "repeat-one" : "repeat"
                    size: 18
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
                ToolTip.visible: volTipHov.hovered
                ToolTip.text: Math.round((player.muted ? 0 : player.volume) * 100) + "%"
                ToolTip.delay: 400
                HoverHandler { id: volTipHov }
            }

            // Cast to a Chromecast / Google Home device (Linux only — `cast`
            // is null elsewhere, which hides the button).
            IconButton {
                id: castBtn
                visible: !!cast
                icon: "cast"; size: 20
                iconColor: (cast && cast.connected) ? Theme.accent : Theme.textSec
                onClicked: { if (cast) cast.startScan(); castPopup.open() }

                Popup {
                    id: castPopup
                    y: -height - 10
                    x: parent.width - width
                    width: 260
                    padding: 6
                    background: Rectangle {
                        color: Theme.surfaceHigh; border.color: Theme.border; radius: 8
                    }
                    contentItem: ColumnLayout {
                        spacing: 2
                        Text {
                            text: "Cast to"; color: Theme.textDim
                            font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                            Layout.leftMargin: 8; Layout.topMargin: 4; Layout.bottomMargin: 2
                        }
                        CastRow {
                            label: "This computer"
                            active: !(cast && cast.connected)
                            onSelected: { if (cast) cast.disconnect(); castPopup.close() }
                        }
                        Repeater {
                            model: cast ? cast.devices : []
                            delegate: CastRow {
                                required property var modelData
                                label: modelData.name
                                active: cast && cast.connected && cast.deviceName === modelData.name
                                onSelected: { if (cast) cast.connectToDevice(modelData.id); castPopup.close() }
                            }
                        }
                        Text {
                            visible: !cast || cast.devices.length === 0
                            text: "Searching for devices…"
                            color: Theme.textSec; font.pixelSize: 12
                            Layout.margins: 8
                        }
                    }
                }
            }

            IconButton {
                icon: "queue"; size: 20
                iconColor: Theme.textSec
                onClicked: root.showQueue()
            }
        }
    }

    // A selectable row in the cast device picker.
    component CastRow : Rectangle {
        id: cr
        property string label
        property bool   active: false
        signal selected()
        Layout.fillWidth: true
        implicitWidth: 240
        implicitHeight: 36
        radius: 6
        color: crHov.hovered ? Theme.surfaceHov : "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
            VectorIcon {
                name: "cast"; width: 16; height: 16; strokeWidth: 1.6
                color: cr.active ? Theme.accent : Theme.textSec
            }
            Text {
                Layout.fillWidth: true; text: cr.label
                color: cr.active ? Theme.accent : Theme.textPrimary
                font.pixelSize: 13; elide: Text.ElideRight
            }
            VectorIcon {
                visible: cr.active; name: "check"
                width: 14; height: 14; strokeWidth: 2; color: Theme.accent
            }
        }
        HoverHandler { id: crHov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: cr.selected() }
    }

    component IconButton : Item {
        id: iconBtn
        property string icon
        property color  iconColor: Theme.textSec
        property int    size: 18
        signal clicked()
        width: Math.max(size + 12, 32)
        height: Math.max(size + 12, 32)

        activeFocusOnTab: true
        Keys.onReturnPressed: clicked()
        Keys.onSpacePressed:  clicked()

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: iconBtn.activeFocus ? 2 : 0
            border.color: Theme.accent
        }

        VectorIcon {
            anchors.centerIn: parent
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

        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: parent.clicked() }
    }
}
