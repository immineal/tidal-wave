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
    // Download state for the current track: "idle" | "busy" | "done" | "error"
    property string dlState: "idle"

    // ─── Responsive layout ─────────────────────────────
    // The page margin and the gap between the cover and the text column, named
    // because all the width arithmetic below leans on them.
    readonly property int pageMargin: 48
    readonly property int columnGap:  64

    readonly property real contentWidth: Math.max(0, width - 2 * pageMargin)

    // The transport row's fixed content measures 248px (44 shuffle, 48
    // previous, 64 play, 48 next, 44 repeat) and its six 16px gaps bring it to
    // 344. Side by side the text column only ever gets 55% of the content
    // width less the 64px gap, which is 290px at a 960px window: 54px short,
    // and short at the old 900px minimum too. So below this page width the
    // cover moves above the text and the transport rather than beside them.
    // 1000 is the agreed round number; the arithmetic itself gives out at 838.
    readonly property int  stackBreakpoint: 1000
    readonly property bool stacked: width < stackBreakpoint

    // Stacked, the cover takes the height the rest of the page leaves it,
    // capped at 420 and at the content width and floored at 180 so it stays a
    // cover. Deriving it rather than taking a fixed fraction of the height is
    // what keeps 960x1200, the user's half-screen size, off the scrollbar: a
    // flat 420 overshot it by twenty pixels. Side by side it keeps the 45% of
    // the content width it always had.
    readonly property real coverSize: stacked
        ? Math.min(contentWidth, 420, Math.max(180, stackedCoverRoom))
        : Math.min(contentWidth * 0.45, 420)

    // What is left once the margins, the back link, the two 32px gaps and the
    // text column have taken their height. The text column's own height does
    // not depend on the cover's, so this cannot chase its own tail.
    readonly property real stackedCoverRoom:
        height - 2 * pageMargin - backLink.height - 32 - 32 - infoColumn.implicitHeight

    // What the title and transport column actually gets.
    readonly property real infoWidth: stacked
        ? contentWidth
        : Math.max(0, contentWidth - coverSize - columnGap)

    // 248px of buttons and six gaps. Where 344 will not fit, which is any
    // window at or below 640, the gaps tighten to 8 and the row comes down to
    // 296 rather than the buttons spilling over each other.
    readonly property int transportFixedWidth: 248
    readonly property int transportGaps: 6
    readonly property int transportSpacing:
        infoWidth >= transportFixedWidth + transportGaps * 16 ? 16 : 8
    readonly property int transportMinWidth:
        transportFixedWidth + transportGaps * transportSpacing

    // Sleep Timer Delegation (mapping properties to Window.window to persist in background)
    readonly property bool   sleepTimerActive:      Window.window ? Window.window.sleepTimerActive : false
    readonly property bool   sleepStopAtEndOfTrack: Window.window ? Window.window.sleepStopAtEndOfTrack : false
    readonly property int    sleepTimeLeft:         Window.window ? Window.window.sleepTimeLeft : 0
    readonly property bool   sleepIsFading:         Window.window ? Window.window.sleepIsFading : false
    property bool            sleepFadeOut:          Window.window ? Window.window.sleepFadeOut : true

    function startSleepTimer(minutes, stopAtEnd) {
        if (Window.window) Window.window.startSleepTimer(minutes, stopAtEnd)
    }
    function cancelSleepTimer() {
        if (Window.window) Window.window.cancelSleepTimer()
    }
    function formatSleepTime(seconds) {
        return Window.window ? Window.window.formatSleepTime(seconds) : ""
    }

    // Lyrics state: "none", "loading", "ready", "unavailable"
    property string lyricsState: "none"
    property var    lyricsData:  []   // [{ms, text}] for timed; [{ms: 0, text}] for plain
    property bool   lyricsIsTimed: false
    property int    currentLyricLine: -1
    property bool   userScrolled: false
    property bool   ignoreLyricsSync: false

    Timer {
        id: ignoreSyncTimer
        interval: 1000
        running: false
        repeat: false
        onTriggered: root.ignoreLyricsSync = false
    }

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
            if (root.ignoreLyricsSync) return
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
            root.ignoreLyricsSync = false
            ignoreSyncTimer.stop()
            root.updateLikedState()
            root.loadLyrics()
            var t = player.currentTrack
            root.dlState = (t && t.id > 0 && downloader.isDownloading(t.id)) ? "busy" : "idle"
        }
    }

    Connections {
        target: bridge
        function onFavoriteTracksChanged() { root.updateLikedState() }
    }

    // Reflect download progress for the currently-playing track.
    Connections {
        target: downloader
        function onDownloadStarted(id)         { if (root.hasTrack && id === root.track.id) root.dlState = "busy" }
        function onDownloadFinished(id, path)  { if (root.hasTrack && id === root.track.id) { root.dlState = "done";  npDlReset.restart() } }
        function onDownloadError(id, msg)      { if (root.hasTrack && id === root.track.id) { root.dlState = "error"; npDlReset.restart() } }
    }
    Timer { id: npDlReset; interval: 3000; onTriggered: root.dlState = "idle" }
    function updateLikedState() {
        isLiked = (hasTrack && track.id > 0)
            ? bridge.isTrackFavorite(track.id)
            : false
    }
    Component.onCompleted: {
        updateLikedState()
        loadLyrics()
        if (hasTrack && downloader.isDownloading(track.id)) dlState = "busy"
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: Theme.accentSoft }
            GradientStop { position: 1; color: Theme.bg }
        }
    }

    // The page scrolls when it cannot fit, which stacking makes likely: the
    // stacked column stands a whole cover taller than the side by side one and
    // the window minimum is only 600 tall. Non-interactive while everything
    // fits, so nothing moves at the sizes where it already fitted.
    Flickable {
        id: pageFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(height, pageColumn.implicitHeight + 2 * root.pageMargin)
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: ScrollBar {
            policy: pageFlick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        }

        ColumnLayout {
            id: pageColumn
            x: root.pageMargin
            y: root.pageMargin
            width:  root.contentWidth
            height: Math.max(0, pageFlick.contentHeight - 2 * root.pageMargin)
            spacing: 32

            Text {
                id: backLink
                text: qsTr("←  Now Playing"); color: Theme.textSec; font.pixelSize: 14
                activeFocusOnTab: true
                Keys.onReturnPressed: Window.window.goBack()
                Keys.onSpacePressed:  Window.window.goBack()
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -4
                    radius: Theme.radiusButton
                    color: "transparent"
                    border.width: backLink.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: Window.window.goBack()
                }
            }

            // Two columns side by side above the breakpoint, one stacked column
            // below it. The same two items either way, so crossing the breakpoint
            // reflows rather than rebuilding anything. No animation: a grid owns
            // its children's positions, so animating the cover across the cell
            // boundary would only fight it.
            GridLayout {
                Layout.fillWidth: true; Layout.fillHeight: true
                columns: root.stacked ? 1 : 2
                columnSpacing: root.columnGap
                rowSpacing: 32

                Item {
                    id: coverBox
                    Layout.preferredWidth:  root.coverSize
                    Layout.preferredHeight: root.coverSize
                    Layout.alignment: root.stacked ? Qt.AlignHCenter | Qt.AlignTop
                                                   : Qt.AlignVCenter

                    // Album art
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radiusArt; color: Theme.surfaceHigh; clip: true
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
                        // Takes the cover's slot, so it takes the cover's corner too
                        radius: Theme.radiusArt
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
                                id: lyricText
                                required property var  modelData
                                required property int  index
                                readonly property bool active: root.lyricsIsTimed && index === root.currentLyricLine
                                readonly property bool hovered: root.lyricsIsTimed && hoverHandler.hovered
                                width: lyricsView.width
                                text: modelData.text
                                color: active ? Theme.accent : (hovered ? Theme.textPrimary : Theme.textSec)
                                font.pixelSize: 14
                                font.bold: active
                                opacity: active ? 1.0 : (hovered ? 0.85 : 0.55)
                                lineHeight: 1.6
                                wrapMode: Text.WordWrap
                                Behavior on opacity { NumberAnimation { duration: Theme.dur(180); easing.type: Easing.OutCubic } }
                                Behavior on color   { ColorAnimation  { duration: Theme.dur(180) } }

                                HoverHandler {
                                    id: hoverHandler
                                    enabled: root.lyricsIsTimed
                                    cursorShape: root.lyricsIsTimed ? Qt.PointingHandCursor : Qt.ArrowCursor
                                }

                                TapHandler {
                                    enabled: root.lyricsIsTimed
                                    onTapped: {
                                        root.ignoreLyricsSync = true
                                        ignoreSyncTimer.restart()
                                        player.seek(modelData.ms)
                                        root.userScrolled = false
                                        root.currentLyricLine = index
                                        lyricsView.positionViewAtIndex(index, ListView.Center)
                                    }
                                }
                            }

                            // Loading / empty states
                            Text {
                                anchors.centerIn: parent
                                visible: root.lyricsState === "loading"
                                text: qsTr("Loading lyrics…")
                                color: Theme.textDim; font.pixelSize: 14
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: root.lyricsState === "unavailable"
                                text: qsTr("No lyrics available")
                                color: Theme.textDim; font.pixelSize: 14
                            }
                        }

                        // Resync button
                        Rectangle {
                            visible: root.userScrolled && root.lyricsIsTimed && root.currentLyricLine >= 0
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottomMargin: 10
                            width: rsText.implicitWidth + 20; height: 28; radius: Theme.radiusChip
                            color: Theme.artScrimStrong
                            border.color: Theme.artBorder
                            Text {
                                id: rsText
                                anchors.centerIn: parent
                                text: qsTr("⟳ Resync")
                                color: Theme.onArt; font.pixelSize: 12
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
                        height: 26; radius: Theme.radiusChip
                        color: root.showLyrics ? Theme.accent : Theme.artScrimStrong
                        border.color: root.showLyrics ? "transparent" : Theme.artBorder
                        Text {
                            id: lyricsToggleText
                            anchors.centerIn: parent
                            text: root.lyricsState === "loading" ? qsTr("Loading…") : qsTr("Lyrics")
                            color: root.showLyrics ? Theme.onAccent : Theme.onArt; font.pixelSize: 11; font.bold: true
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
                    id: infoColumn
                    Layout.fillWidth: true
                    Layout.alignment: root.stacked ? Qt.AlignTop : Qt.AlignVCenter
                    spacing: 24

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 16

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            // "Playing from" source link — navigates back to the
                            // playlist / album / mix / liked songs it started from.
                            Text {
                                id: sourceLink
                                visible: hasTrack && player.sourceName.length > 0
                                text: qsTr("Playing from %1").arg(player.sourceName)
                                color: sourceLinkHov.hovered ? Theme.textPrimary : Theme.textDim
                                font.pixelSize: 12
                                font.letterSpacing: 0.5
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                                HoverHandler { id: sourceLinkHov; cursorShape: Qt.PointingHandCursor }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: goToSource()
                                }
                            }
                            // The title opens the album the track is on
                            // (SPEC N1), the same place the album line below
                            // goes. Built like the two links under it: the hit
                            // target and the focus ring follow the words, not
                            // the column the Text fills.
                            Text {
                                id: titleLink
                                objectName: "nowPlayingTitle"
                                text: hasTrack ? track.title : "–"; color: Theme.textPrimary
                                font.pixelSize: 32; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true
                                font.underline: titleHit.containsMouse && hasTrack && Number(track.albumId) > 0
                                activeFocusOnTab: hasTrack && Number(track.albumId) > 0
                                Keys.onReturnPressed: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Keys.onSpacePressed:  if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Rectangle {
                                    x: -4; y: -4
                                    width:  Math.min(parent.width, parent.contentWidth) + 8
                                    height: parent.height + 8
                                    radius: Theme.radiusButton; color: "transparent"
                                    border.width: titleLink.activeFocus ? 2 : 0
                                    border.color: Theme.accent
                                }
                                MouseArea {
                                    id: titleHit
                                    width:  Math.min(parent.width, parent.contentWidth)
                                    height: parent.height
                                    hoverEnabled: true
                                    cursorShape: hasTrack && Number(track.albumId) > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                }
                            }
                            Text {
                                id: artistLink
                                text: hasTrack ? track.artists : ""; color: Theme.accent; font.pixelSize: 18
                                // Fills and elides, like the title above it. Without
                                // this the Text's own 453px of artist names was the
                                // column's minimum width and dragged the whole page
                                // out past the window edge.
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font.underline: artistHit.containsMouse && hasTrack && Number(track.artistId) > 0
                                activeFocusOnTab: hasTrack && Number(track.artistId) > 0
                                Keys.onReturnPressed: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                                Keys.onSpacePressed:  if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                                Rectangle {
                                    // Tracks the words, not the column the Text now
                                    // fills, so the ring and the hit target do not
                                    // float out to the right of a short name.
                                    x: -4; y: -4
                                    width:  Math.min(parent.width, parent.contentWidth) + 8
                                    height: parent.height + 8
                                    radius: Theme.radiusButton; color: "transparent"
                                    border.width: artistLink.activeFocus ? 2 : 0
                                    border.color: Theme.accent
                                }
                                MouseArea {
                                    id: artistHit
                                    width:  Math.min(parent.width, parent.contentWidth)
                                    height: parent.height
                                    hoverEnabled: true
                                    cursorShape: hasTrack && Number(track.artistId) > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (hasTrack && Number(track.artistId) > 0) navigateTo("artist", { artistId: Number(track.artistId) })
                                }
                            }
                            Text {
                                id: albumLink
                                text: hasTrack ? track.albumTitle : ""; color: Theme.textSec; font.pixelSize: 15
                                // Same reason as the artist line above.
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font.underline: albumHit.containsMouse && hasTrack && Number(track.albumId) > 0
                                activeFocusOnTab: hasTrack && Number(track.albumId) > 0
                                Keys.onReturnPressed: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Keys.onSpacePressed:  if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                Rectangle {
                                    x: -4; y: -4
                                    width:  Math.min(parent.width, parent.contentWidth) + 8
                                    height: parent.height + 8
                                    radius: Theme.radiusButton; color: "transparent"
                                    border.width: albumLink.activeFocus ? 2 : 0
                                    border.color: Theme.accent
                                }
                                MouseArea {
                                    id: albumHit
                                    width:  Math.min(parent.width, parent.contentWidth)
                                    height: parent.height
                                    hoverEnabled: true
                                    cursorShape: hasTrack && Number(track.albumId) > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (hasTrack && Number(track.albumId) > 0) navigateTo("album", { albumId: Number(track.albumId) })
                                }
                            }
                        }

                        // Download button — always visible while a track is playing
                        Item {
                            id: npDownloadBtn
                            visible: root.hasTrack
                            Layout.preferredWidth: 44
                            Layout.preferredHeight: 44
                            activeFocusOnTab: root.dlState !== "busy"
                            Keys.onReturnPressed: if (root.hasTrack && root.dlState !== "busy") downloader.downloadTrack(root.track)
                            Keys.onSpacePressed:  if (root.hasTrack && root.dlState !== "busy") downloader.downloadTrack(root.track)
                            Rectangle {
                                anchors.fill: parent; radius: width / 2; color: "transparent"
                                border.width: npDownloadBtn.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                            VectorIcon {
                                anchors.centerIn: parent
                                visible: root.dlState === "idle" || root.dlState === "error"
                                name: "download"
                                color: root.dlState === "error" ? Theme.red
                                       : (npDlHov.hovered ? Theme.textPrimary : Theme.textSec)
                                width: 24; height: 24; strokeWidth: 1.5
                            }
                            VectorIcon {
                                anchors.centerIn: parent
                                visible: root.dlState === "done"
                                name: "check"; color: Theme.green
                                width: 24; height: 24; strokeWidth: 2
                            }
                            Item {
                                id: npSpinner
                                anchors.centerIn: parent
                                width: 22; height: 22
                                visible: root.dlState === "busy"
                                Rectangle {
                                    width: 3.5; height: 9; radius: 1.75
                                    anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
                                    color: Theme.accent
                                }
                                RotationAnimator {
                                    target: npSpinner; from: 0; to: 360; duration: Theme.dur(800)
                                    loops: Theme.reduceMotion ? 1 : Animation.Infinite
                                    running: root.dlState === "busy"
                                }
                            }
                            HoverHandler { id: npDlHov; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: if (root.hasTrack && root.dlState !== "busy") downloader.downloadTrack(root.track) }
                            ToolTip.visible: npDlHov.hovered && root.dlState === "error"
                            ToolTip.text: qsTr("Download failed. Click to retry.")
                            ToolTip.delay: 300
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

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        // Quality badge
                        Rectangle {
                            visible: player.audioQuality.length > 0
                            height: 24; width: qlbl.implicitWidth + 12; radius: Theme.radiusBadge
                            color: player.audioQuality === "HI_RES_LOSSLESS" ? Theme.accentWash :
                                   player.audioQuality === "LOSSLESS" ? Theme.greenWash : Theme.surfaceHigh
                            Text {
                                id: qlbl; anchors.centerIn: parent
                                text: (player.audioQuality === "HI_RES_LOSSLESS" ? "⚛ " :
                                       player.audioQuality === "LOSSLESS" ? "◆ " : "")
                                      + player.qualityLabel(player.audioQuality)
                                color: Theme.textPrimary; font.pixelSize: 11; font.bold: true
                            }
                        }

                        Item { Layout.fillWidth: true } // Pusher

                        // Sleep Timer button
                        Rectangle {
                            id: sleepTimerBtn
                            height: 24
                            width: sleepTimerRow.implicitWidth + 16
                            radius: Theme.radiusChip
                            color: root.sleepTimerActive ? Theme.accentTint : Theme.surfaceHigh
                            border.color: root.sleepTimerActive ? Theme.accent : Theme.border
                            border.width: 1
                        
                            RowLayout {
                                id: sleepTimerRow
                                anchors.centerIn: parent
                                spacing: 6
                            
                                VectorIcon {
                                    name: "clock"
                                    color: root.sleepTimerActive ? Theme.accent : Theme.textSec
                                    width: 12
                                    height: 12
                                }
                            
                                Text {
                                    text: root.sleepTimerActive ? 
                                          (root.sleepStopAtEndOfTrack ? qsTr("End of Track") : root.formatSleepTime(root.sleepTimeLeft)) : 
                                          qsTr("Sleep Timer")
                                    color: root.sleepTimerActive ? Theme.accent : Theme.textSec
                                    font.pixelSize: 11
                                    font.bold: root.sleepTimerActive
                                }
                            }
                        
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: sleepTimerPopup.open()
                            }
                        }
                    }

                    Popup {
                        id: sleepTimerPopup
                        parent: sleepTimerBtn
                        x: sleepTimerBtn.width - width
                        y: sleepTimerBtn.height + 6
                        width: 260
                        height: contentCol.implicitHeight + 24
                        padding: 12
                        modal: true
                        focus: true
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                    
                        background: Rectangle {
                            color: Theme.surfaceHigh
                            border.color: Theme.border
                            border.width: 1
                            radius: Theme.radiusPopup
                        
                            MouseArea {
                                anchors.fill: parent
                                // Capture and accept all mouse events to prevent propagating to items below the popup
                                onClicked: (mouse) => mouse.accepted = true
                                onPressed: (mouse) => mouse.accepted = true
                                onReleased: (mouse) => mouse.accepted = true
                            }
                        }

                        ColumnLayout {
                            id: contentCol
                            anchors.fill: parent
                            spacing: 12

                            Text {
                                text: qsTr("Sleep Timer")
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                font.bold: true
                                Layout.alignment: Qt.AlignLeft
                            }

                            // Options container when timer is INACTIVE
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                visible: !root.sleepTimerActive

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 3
                                    columnSpacing: 8
                                    rowSpacing: 8
                                
                                    SleepOptionBtn { minutes: 5 }
                                    SleepOptionBtn { minutes: 15 }
                                    SleepOptionBtn { minutes: 30 }
                                    SleepOptionBtn { minutes: 45 }
                                    SleepOptionBtn { minutes: 60 }
                                    SleepOptionBtn { minutes: 90 }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 32
                                    radius: Theme.radiusButton
                                    color: maEndOfTrack.containsMouse ? Theme.surfaceHov : Theme.surface
                                    border.color: Theme.border
                                    border.width: 1
                                
                                    RowLayout {
                                        anchors.centerIn: parent
                                        spacing: 6
                                        VectorIcon {
                                            name: "music"
                                            color: Theme.accent
                                            width: 12
                                            height: 12
                                        }
                                        Text {
                                            text: qsTr("Stop at End of Track")
                                            color: Theme.textPrimary
                                            font.pixelSize: 12
                                            font.bold: true
                                        }
                                    }
                                
                                    MouseArea {
                                        id: maEndOfTrack
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        hoverEnabled: true
                                        onClicked: {
                                            root.startSleepTimer(0, true)
                                            sleepTimerPopup.close()
                                        }
                                    }
                                }

                                // Divider
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: Theme.border
                                }

                                // Custom Slider (using the project's native slider styling)
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text {
                                            text: qsTr("Custom: %1 min").arg(customSlider.value)
                                            color: Theme.textSec
                                            font.pixelSize: 12
                                        }
                                        Item { Layout.fillWidth: true }
                                        Text {
                                            text: qsTr("Start", "verb, begins the sleep timer")
                                            color: Theme.accent
                                            font.pixelSize: 12
                                            font.bold: true
                                        
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root.startSleepTimer(customSlider.value, false)
                                                    sleepTimerPopup.close()
                                                }
                                            }
                                        }
                                    }
                                
                                    Item {
                                        id: customSlider
                                        property int value: 20
                                        Layout.fillWidth: true
                                        height: 20
                                    
                                        Rectangle {
                                            id: customTrack
                                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                                            // A 3px bar, so the chip radius clamps to a capsule
                                            height: 3; radius: Theme.radiusChip
                                            color: Theme.border

                                            Rectangle {
                                                width: ((customSlider.value - 1) / 119.0) * customTrack.width
                                                height: parent.height; radius: parent.radius
                                                color: Theme.accent
                                            }

                                            Rectangle {
                                                x: Math.max(0, Math.min(customTrack.width - width, ((customSlider.value - 1) / 119.0) * customTrack.width - width / 2))
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 10; height: 10; radius: 5
                                                color: Theme.textPrimary
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            preventStealing: true
                                            onPressed: (mouse) => {
                                                var pct = Math.max(0, Math.min(1, mouse.x / width))
                                                customSlider.value = Math.round(1 + pct * 119)
                                            }
                                            onPositionChanged: (mouse) => {
                                                if (pressed) {
                                                    var pct = Math.max(0, Math.min(1, mouse.x / width))
                                                    customSlider.value = Math.round(1 + pct * 119)
                                                }
                                            }
                                            cursorShape: Qt.PointingHandCursor
                                        }
                                    }
                                }
                            }

                            // Options container when timer is ACTIVE
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                visible: root.sleepTimerActive

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 50
                                    color: Theme.accentSoft
                                    border.color: Theme.accentDim
                                    border.width: 1
                                    radius: Theme.radiusCard
                                
                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        spacing: 2
                                        Text {
                                            text: root.sleepStopAtEndOfTrack ? qsTr("Stopping at end of track") : 
                                                  root.sleepIsFading ? qsTr("Fading out audio…") : 
                                                  qsTr("Remaining: %1").arg(root.formatSleepTime(root.sleepTimeLeft))
                                            color: Theme.textPrimary
                                            font.pixelSize: 13
                                            font.bold: true
                                            Layout.alignment: Qt.AlignHCenter
                                        }
                                        Text {
                                            text: root.sleepStopAtEndOfTrack ? qsTr("Fades out last 15s") : qsTr("Fades out last 30s")
                                            color: Theme.textDim
                                            font.pixelSize: 10
                                            visible: root.sleepFadeOut
                                            Layout.alignment: Qt.AlignHCenter
                                        }
                                    }
                                }
                            
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 32
                                    radius: Theme.radiusButton
                                    color: Theme.redSoft
                                    border.color: Theme.red
                                    border.width: 1
                                
                                    Text {
                                        anchors.centerIn: parent
                                        text: qsTr("Cancel Sleep Timer")
                                        color: Theme.red
                                        font.pixelSize: 12
                                        font.bold: true
                                    }
                                
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.cancelSleepTimer()
                                            sleepTimerPopup.close()
                                        }
                                    }
                                }
                            }

                            // Divider
                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: Theme.border
                            }

                            // Robust Options Toggle (Custom Row Switch)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 12
                            
                                Text {
                                    text: qsTr("Fade out audio")
                                    color: Theme.textSec
                                    font.pixelSize: 12
                                    Layout.fillWidth: true
                                }
                            
                                Rectangle {
                                    width: 34
                                    height: 18
                                    radius: Theme.radiusChip
                                    color: root.sleepFadeOut ? Theme.accent : Theme.surface
                                    border.color: Theme.border
                                    border.width: 1
                                
                                    Rectangle {
                                        x: root.sleepFadeOut ? 17 : 1
                                        y: 1
                                        width: 16
                                        height: 16
                                        radius: 8
                                        color: root.sleepFadeOut ? Theme.onAccent : Theme.textPrimary
                                        Behavior on x { NumberAnimation { duration: Theme.dur(150) } }
                                    }
                                }
                            
                                // Handlers rather than a MouseArea: the whole
                                // row is the hit target, and an anchored
                                // MouseArea inside a layout is undefined
                                // behaviour (Qt warns about it).
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    onTapped: {
                                        if (Window.window) Window.window.sleepFadeOut = !Window.window.sleepFadeOut
                                    }
                                }
                            }
                        }
                    }

                    SeekBar {
                        Layout.fillWidth: true
                        position: player.position; duration: player.duration
                        onSeeked: (ms) => player.seek(ms)
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: root.transportSpacing
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
                            scale: pHov.hovered ? 0.95 : 1; Behavior on scale { NumberAnimation { duration: Theme.dur(100) } }
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
                                anchors.fill: parent; anchors.margins: -4; radius: Theme.radiusButton; color: "transparent"
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
                        Text {
                            text: qsTr("%1%").arg(Math.round((player.muted ? 0 : player.volume) * 100)
                                                      .toLocaleString(Qt.locale(), 'f', 0))
                            color: Theme.textDim; font.pixelSize: 12; width: 36
                        }

                        // Cast picker. The player bar sheds its own cast button
                        // below 720px (SPEC L8) and this is where casting stays
                        // reachable. Linux only: `cast` is null elsewhere, which
                        // hides the button, same as in the bar.
                        CtrlBtn {
                            id: npCastBtn
                            visible: !!cast
                            icon: "cast"
                            size: 20
                            active: !!cast && cast.connected
                            onClicked: { if (cast) cast.startScan(); npCastPopup.open() }

                            Popup {
                                id: npCastPopup
                                y: -height - 8
                                x: parent.width - width
                                width: 260
                                padding: 6
                                modal: true
                                focus: true
                                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                                background: Rectangle {
                                    color: Theme.surfaceHigh
                                    border.color: Theme.border
                                    border.width: 1
                                    radius: Theme.radiusPopup
                                }
                                contentItem: ColumnLayout {
                                    spacing: 2
                                    // Same three strings as the player bar's
                                    // picker. Borrowed from its context rather
                                    // than duplicated, so a language pays for
                                    // them once and they cannot drift apart.
                                    Text {
                                        text: qsTranslate("PlayerBar", "Cast to")
                                        color: Theme.textDim
                                        font.pixelSize: 11; font.bold: true
                                        Layout.leftMargin: 8
                                        Layout.topMargin: 4
                                        Layout.bottomMargin: 2
                                    }
                                    CastDeviceRow {
                                        label: qsTranslate("PlayerBar", "This computer")
                                        active: !(cast && cast.connected)
                                        onSelected: { if (cast) cast.disconnect(); npCastPopup.close() }
                                    }
                                    Repeater {
                                        model: cast ? cast.devices : []
                                        delegate: CastDeviceRow {
                                            required property var modelData
                                            label: modelData.name
                                            active: cast && cast.connected && cast.deviceName === modelData.name
                                            onSelected: { if (cast) cast.connectToDevice(modelData.id); npCastPopup.close() }
                                        }
                                    }
                                    Text {
                                        visible: !cast || cast.devices.length === 0
                                        text: qsTranslate("PlayerBar", "Searching for devices…")
                                        color: Theme.textSec; font.pixelSize: 12
                                        Layout.margins: 8
                                    }
                                }
                            }
                        }
                    }

                    // Up Next preview
                    ColumnLayout {
                        id: upNextCol
                        Layout.fillWidth: true
                        spacing: 12
                        // Reflects the true play order (respects shuffle).
                        // queueCount, not queueTracks, is read for the
                        // dependency: both are notified by queueChanged, but
                        // queueTracks copies the entire queue into JS to be
                        // thrown away, which on a 5000-track queue is the
                        // whole cost of a track change. queueIndex brings the
                        // advance, shuffle brings a reorder.
                        property var upNext: (player.queueCount, player.queueIndex,
                                              player.shuffle, player.upcomingTracks(3))
                        visible: upNext.length > 0

                        Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

                        Text {
                            text: qsTr("Up Next")
                            color: Theme.textDim
                            font.pixelSize: 11
                            font.bold: true
                            font.letterSpacing: 1
                        }

                        Repeater {
                            model: upNextCol.upNext
                            delegate: RowLayout {
                                required property int index
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                Layout.bottomMargin: 4
                                spacing: 12
                                property var upTrack: modelData
                                Rectangle {
                                    width: 44; height: 44; radius: Theme.radiusArt; color: Theme.surfaceHigh; clip: true
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
    }

    component SleepOptionBtn : Rectangle {
        id: optBtn
        property int minutes
        // Derived, so the unit suffix is one translatable string instead of six
        property string label: qsTr("%1m", "compact duration in minutes").arg(optBtn.minutes)
        Layout.fillWidth: true
        height: 28
        radius: Theme.radiusButton
        color: ma.containsMouse ? Theme.surfaceHov : Theme.surface
        border.color: Theme.border
        border.width: 1
        
        Text {
            anchors.centerIn: parent
            text: optBtn.label
            color: Theme.textPrimary
            font.pixelSize: 12
        }
        
        MouseArea {
            id: ma
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: {
                root.startSleepTimer(optBtn.minutes, false)
                sleepTimerPopup.close()
            }
        }
    }

    // A selectable row in the cast device picker. The twin of PlayerBar's
    // CastRow; the two cannot share a file without a new entry in
    // CMakeLists.txt, which this change is not allowed to touch.
    component CastDeviceRow : Rectangle {
        id: cdr
        property string label
        property bool   active: false
        signal selected()
        Layout.fillWidth: true
        implicitWidth: 240
        implicitHeight: 36
        radius: Theme.radiusRow
        color: cdrHov.hovered ? Theme.surfaceHov : "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
            VectorIcon {
                name: "cast"; width: 16; height: 16; strokeWidth: 1.6
                color: cdr.active ? Theme.accent : Theme.textSec
            }
            Text {
                Layout.fillWidth: true; text: cdr.label
                color: cdr.active ? Theme.accent : Theme.textPrimary
                font.pixelSize: 13; elide: Text.ElideRight
            }
            VectorIcon {
                visible: cdr.active; name: "check"
                width: 14; height: 14; strokeWidth: 2; color: Theme.accent
            }
        }
        HoverHandler { id: cdrHov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: cdr.selected() }
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

    // Maps the current "playing from" source to a navigation target, or null if
    // the source can't be navigated to. Param names match each detail page.
    function sourceNav() {
        var t = player.sourceType
        if (t === "album")      return { page: "album",      params: { albumId: Number(player.sourceId) } }
        if (t === "artist")     return { page: "artist",     params: { artistId: Number(player.sourceId) } }
        if (t === "playlist")   return { page: "playlist",   params: { playlistUuid: player.sourceId, playlistTitle: player.sourceName, coverUrl: "", playlistType: "" } }
        if (t === "mix")        return { page: "mix",        params: { mixId: player.sourceId } }
        if (t === "radio")      return { page: "radio",      params: { radioTitle: player.sourceName, trackId: Number(player.sourceId) } }
        if (t === "collection") return { page: "collection", params: { activeTab: 0 } }
        return null
    }
    function goToSource() {
        var n = sourceNav()
        if (n) navigateTo(n.page, n.params)
    }
}
