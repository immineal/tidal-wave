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
    property bool showLyrics: false

    // Lyrics state: "none", "loading", "ready", "unavailable"
    property string lyricsState: "none"
    property var    lyricsData:  []   // [{ms, text}] for timed; [{ms: 0, text}] for plain
    property bool   lyricsIsTimed: false
    property int    currentLyricLine: -1
    property bool   userScrolled: false

    function parseLrc(text) {
        var lines = []
        var re = /\[(\d{2}):(\d{2})[\.\:](\d{2,3})\](.*)/
        var raw = text.split('\n')
        for (var i = 0; i < raw.length; i++) {
            var m = raw[i].match(re)
            if (m) {
                var mins = parseInt(m[1])
                var secs = parseInt(m[2])
                var sub  = parseInt(m[3])
                var ms   = (mins * 60 + secs) * 1000 + (m[3].length === 2 ? sub * 10 : sub)
                var txt  = (m[4] || "").trim()
                if (txt.length > 0) lines.push({ ms: ms, text: txt })
            }
        }
        lines.sort(function(a, b) { return a.ms - b.ms })
        return lines
    }

    function loadLyrics() {
        if (!hasTrack || track.id <= 0) return
        lyricsState = "loading"
        bridge.fetchLyrics(track.id, function(result, err) {
            if (err) { lyricsState = "unavailable"; return }
            var rawText = result.text || ""
            var timed   = result.timed || false
            if (rawText.length === 0) { lyricsState = "unavailable"; return }
            lyricsIsTimed = timed
            if (timed) {
                lyricsData = parseLrc(rawText)
            } else {
                var plain = rawText.split('\n')
                var arr = []
                for (var i = 0; i < plain.length; i++) {
                    var t = plain[i].trim()
                    if (t.length > 0) arr.push({ ms: 0, text: t })
                }
                lyricsData = arr
            }
            lyricsState = lyricsData.length > 0 ? "ready" : "unavailable"
            currentLyricLine = 0
        })
    }

    Timer {
        id: lyricsSyncTimer
        interval: 400
        running: root.showLyrics && root.lyricsIsTimed && root.lyricsData.length > 0
        repeat: true
        onTriggered: {
            var pos = player.position
            var found = 0
            for (var i = 0; i < root.lyricsData.length; i++) {
                if (root.lyricsData[i].ms <= pos) found = i
                else break
            }
            if (found !== root.currentLyricLine) {
                root.currentLyricLine = found
                if (!root.userScrolled)
                    lyricsView.positionViewAtIndex(found, ListView.Center)
            }
        }
    }

    Connections {
        target: player
        function onCurrentTrackChanged() {
            root.lyricsData   = []
            root.lyricsState  = "none"
            root.currentLyricLine = -1
            root.userScrolled = false
            root.updateLikedState()
            root.loadLyrics()
        }
    }

    Connections {
        target: bridge
        function onFavoriteTracksChanged() { root.updateLikedState() }
    }
    function updateLikedState() {
        isLiked = (hasTrack && track.id > 0)
            ? bridge.isTrackFavorite(track.id)
            : false
    }
    Component.onCompleted: {
        updateLikedState()
        loadLyrics()
    }

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

            Item {
                id: coverBox
                Layout.preferredWidth: Math.min(parent.width * 0.45, 420)
                Layout.preferredHeight: Layout.preferredWidth
                Layout.alignment: Qt.AlignVCenter

                // Album art
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusLg; color: Theme.surfaceHigh; clip: true
                    visible: !root.showLyrics
                    Image {
                        anchors.fill: parent
                        source: hasTrack ? "image://tidal/" + track.coverUrl : ""
                        fillMode: Image.PreserveAspectCrop; smooth: true; mipmap: true
                    }
                }

                // Lyrics panel
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusLg
                    color: Theme.surface
                    border.color: Theme.border
                    visible: root.showLyrics
                    clip: true

                    ListView {
                        id: lyricsView
                        anchors.fill: parent
                        anchors.margins: 16
                        clip: true
                        model: root.lyricsData
                        spacing: 8
                        cacheBuffer: 200

                        onMovingChanged: if (moving) root.userScrolled = true

                        delegate: Text {
                            required property var  modelData
                            required property int  index
                            readonly property bool active: root.lyricsIsTimed && index === root.currentLyricLine
                            width: lyricsView.width
                            text: modelData.text
                            color: active ? Theme.accent : Theme.textSec
                            font.pixelSize: 14
                            font.bold: active
                            opacity: active ? 1.0 : 0.55
                            lineHeight: 1.6
                            wrapMode: Text.WordWrap
                            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                            Behavior on color   { ColorAnimation  { duration: 180 } }
                        }

                        // Loading / empty states
                        Text {
                            anchors.centerIn: parent
                            visible: root.lyricsState === "loading"
                            text: "Loading lyrics…"
                            color: Theme.textDim; font.pixelSize: 14
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: root.lyricsState === "unavailable"
                            text: "No lyrics available"
                            color: Theme.textDim; font.pixelSize: 14
                        }
                    }

                    // Resync button
                    Rectangle {
                        visible: root.userScrolled && root.lyricsIsTimed && root.currentLyricLine >= 0
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottomMargin: 10
                        width: rsText.implicitWidth + 20; height: 28; radius: 14
                        color: Qt.rgba(0,0,0,0.65)
                        border.color: Qt.rgba(1,1,1,0.2)
                        Text {
                            id: rsText
                            anchors.centerIn: parent
                            text: "⟳ Resync"
                            color: "white"; font.pixelSize: 12
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                root.userScrolled = false
                                if (root.currentLyricLine >= 0)
                                    lyricsView.positionViewAtIndex(root.currentLyricLine, ListView.Center)
                            }
                        }
                    }
                }

                // Lyrics toggle button — hidden when lyrics confirmed unavailable
                Rectangle {
                    visible: root.lyricsState !== "unavailable"
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    anchors.margins: 10
                    width: lyricsToggleText.implicitWidth + 16
                    height: 26; radius: 13
                    color: root.showLyrics ? Theme.accent : Qt.rgba(0,0,0,0.5)
                    border.color: root.showLyrics ? "transparent" : Qt.rgba(1,1,1,0.3)
                    Text {
                        id: lyricsToggleText
                        anchors.centerIn: parent
                        text: root.lyricsState === "loading" ? "Loading…" : "Lyrics"
                        color: "white"; font.pixelSize: 11; font.bold: true
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            root.showLyrics = !root.showLyrics
                            if (root.showLyrics && root.lyricsState === "none") root.loadLyrics()
                        }
                    }
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
                            font.underline: artistLinkHov.hovered && hasTrack && Number(track.artistId) > 0
                            activeFocusOnTab: hasTrack && Number(track.artistId) > 0
                            Keys.onReturnPressed: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                            Keys.onSpacePressed:  if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                            Rectangle {
                                anchors.fill: parent; anchors.margins: -4; radius: 4; color: "transparent"
                                border.width: artistLink.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                            HoverHandler { id: artistLinkHov; cursorShape: hasTrack && Number(track.artistId) > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                            }
                        }
                        Text {
                            id: albumLink
                            text: hasTrack ? track.albumTitle : ""; color: Theme.textSec; font.pixelSize: 15
                            font.underline: albumLinkHov.hovered && hasTrack && Number(track.albumId) > 0
                            activeFocusOnTab: hasTrack && Number(track.albumId) > 0
                            Keys.onReturnPressed: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                            Keys.onSpacePressed:  if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                            Rectangle {
                                anchors.fill: parent; anchors.margins: -4; radius: 4; color: "transparent"
                                border.width: albumLink.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                            HoverHandler { id: albumLinkHov; cursorShape: hasTrack && Number(track.albumId) > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor }
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
                              player.audioQuality === "HIGH" ? "HI-FI" :
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
                            width: 32
                            height: 32
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

                // Up Next preview
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    visible: player.queueCount > player.queueIndex + 1

                    Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

                    Text {
                        text: "Up Next"
                        color: Theme.textDim
                        font.pixelSize: 11
                        font.bold: true
                        font.letterSpacing: 1
                    }

                    Repeater {
                        model: Math.min(3, Math.max(0, player.queueCount - player.queueIndex - 1))
                        delegate: RowLayout {
                            required property int index
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            Layout.bottomMargin: 4
                            spacing: 12
                            property var upTrack: player.queueTrackAt(player.queueIndex + 1 + index)
                            Rectangle {
                                width: 44; height: 44; radius: 6; color: Theme.surfaceHigh; clip: true
                                Image {
                                    anchors.fill: parent
                                    source: upTrack && upTrack.coverUrl80 ? "image://tidal/" + upTrack.coverUrl80 : ""
                                    fillMode: Image.PreserveAspectCrop; smooth: true; mipmap: true
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 4
                                Text { Layout.fillWidth: true; text: upTrack ? upTrack.title : ""; color: Theme.textPrimary; font.pixelSize: 14; elide: Text.ElideRight }
                                Text { Layout.fillWidth: true; text: upTrack ? upTrack.artists : ""; color: Theme.textSec; font.pixelSize: 12; elide: Text.ElideRight }
                            }
                        }
                    }
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
