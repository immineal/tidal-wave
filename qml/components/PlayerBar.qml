import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
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

    // ─── The volume cluster ────────────────────────────
    // At rest the volume is the speaker over the percentage, plus the output
    // picker. The slider comes up on hover in a VolumeFlyout parented to the
    // stack, so it stands over both rows. Now Playing builds the same parts.
    readonly property int volumePercentWidth: 36
    // The gap between the speaker and the readout under it, spent inside the
    // readout as top padding and not as column spacing: the two are one hover
    // target, and a dead strip between them would drop the flyout.
    readonly property int volumeStackGap: 4

    // IconButton's box leaves 7px empty below an 18px glyph, which Now
    // Playing's bare speaker does not have. The readout is lifted over it and
    // padded back by the same, so the ink gap matches there and no box moves.
    readonly property int volumeSpeakerBoxSlack: 7

    // ─── Exposed for the suites ────────────────────────
    // tests/qml/tst_layout_player.qml checks the queue button stays on screen;
    // the speaker, the readout and the flyout are what tst_output_picker.qml
    // drives.
    readonly property alias queueButton:  queueBtn
    readonly property alias volumeButton:      volBtn
    readonly property alias volumePercentText: volPct
    // The two of them as one object. The group's width is measured from here:
    // the speaker is 32 wide and centred in a 36px stack.
    readonly property alias volumeStack:       volStack
    readonly property var   hoverVolumeSlider: volumeFlyout.slider
    readonly property alias hoverVolumePopup:  volumeFlyout
    // The one picker for "where is this playing". tst_output_picker.qml reads
    // its menu and its icon.
    readonly property alias outputButton: outputBtn
    // Exposed for tests/qml/tst_nowplaying_access.qml: the button has to be on
    // screen at every supported width.
    readonly property alias nowPlayingButton: nowPlayingBtn
    readonly property alias trackInfoGroup:   leftGroup

    // ─── Artist links ──────────────────────────────────
    // TidalBridge::trackToMap() carries the whole artist list as [{id, name}].
    // A map without it has only the joined `artists` string, which is what
    // ArtistLinks falls back to.
    readonly property var artistList:
        (hasTrack && track.artistList && track.artistList.length > 0) ? track.artistList : []

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

    // The heart's one call, and what it says when the server refuses it. The
    // state above is read back from the bridge and never written here.
    // Published because `lastMessage` is a test's only way to see what it said.
    readonly property alias favoriteAction: likeFav
    ContextMenu.FavoriteAction { id: likeFav }

    // Recently-played is tracked locally and orders the sidebar. Every page
    // declares where a play came from before starting it, so this one listener
    // records them all. markPlayed() drops kinds the sidebar does not list.
    Connections {
        target: player
        function onSourceChanged() {
            library.markPlayed(player.sourceType, player.sourceId)
        }
    }

    // The song itself, which is a different list: the sidebar's Tracks pill is
    // ordered by the most recent of played or liked. markTrackPlayed() drops a
    // song that is not in the library. Kept apart from the heart's listener.
    Connections {
        target: player
        function onCurrentTrackChanged() {
            const t = player.currentTrack
            if (t && t.id > 0)
                library.markTrackPlayed("" + t.id)
        }
    }
    Component.onCompleted: updateLikedState()

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 0

        // ── Track info (left) ──────────────────────────
        RowLayout {
            id: leftGroup
            Layout.preferredWidth: 280
            Layout.minimumWidth: 200
            spacing: 12

            Rectangle {
                objectName: "playerBarCover"
                width: 56; height: 56; radius: Theme.radiusArt
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
                    text: hasTrack ? track.title : qsTr("No track playing")
                    color: Theme.textPrimary; font.pixelSize: 14; font.bold: true; elide: Text.ElideRight
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showNowPlaying() }
                }
                // One hover target and one tab stop per artist. What is not a
                // name keeps the left group's own job of opening Now Playing.
                Item {
                    Layout.fillWidth: true
                    implicitHeight: artistLine.implicitHeight

                    // Declared first, so it sits under the names and they get
                    // the click before it does.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.showNowPlaying()
                    }

                    ArtistLinks {
                        id: artistLine
                        anchors.left: parent.left
                        anchors.right: parent.right
                        namePrefix: "playerBar"
                        fontPixelSize: 12
                        artistList: root.artistList
                        joinedText: hasTrack ? track.artists : ""
                        // 0 on purpose: the bar's joined fallback is not a link
                        // of its own, so a click on it falls through to the
                        // MouseArea above and opens Now Playing.
                        fallbackArtistId: 0
                    }
                }
                Rectangle {
                    objectName: "qualityBadge"
                    visible: hasTrack && player.audioQuality.length > 0
                    height: 16; width: ql.implicitWidth + 8; radius: Theme.radiusBadge
                    color: {
                        var q = player.audioQuality
                        if (q === "HI_RES_LOSSLESS") return Theme.accentWash
                        if (q === "LOSSLESS") return Theme.greenWash
                        return Theme.surfaceHigh
                    }
                    Text {
                        id: ql; objectName: "qualityBadgeText"
                        anchors.centerIn: parent
                        text: player.qualityLabel(player.audioQuality)
                        color: Theme.textPrimary; font.pixelSize: 9; font.bold: true
                    }
                }
            }

            // Like is the only thing in this group that acts on the track. The
            // Now Playing arrow opens a view, so it sits with the queue button.
            IconButton {
                id: likeBtn
                objectName: "playerLikeButton"
                visible: root.hasTrack
                icon: root.isLiked ? "heart-filled" : "heart"
                size: 16
                iconColor: root.isLiked ? Theme.accent : Theme.textSec
                ToolTip.visible: likeTipHov.hovered
                ToolTip.text: root.isLiked ? qsTr("Unlike track") : qsTr("Like track")
                ToolTip.delay: 600
                HoverHandler { id: likeTipHov }
                // Anchored on the bar, not on this button. The three ToolTip
                // lines above bind the shared tool tip, so anchored here the
                // hint's delay, visibility and text would apply to the refusal.
                onClicked: root.favoriteAction.toggleTrack(root.track.id, root.isLiked, root)
            }
        }

        // ── Central controls ───────────────────────────
        ColumnLayout {
            Layout.fillWidth: true; spacing: 4
            // Never squeeze the transport: its buttons and gaps cannot shrink,
            // and without this the row layout hands the column less and the
            // buttons spill over each other.
            Layout.minimumWidth: implicitWidth

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
                    // The still-loading state of the play button. No label
                    // fits in a 40px disc, so the mark is all there is.
                    VectorIcon {
                        anchors.centerIn: parent
                        name: "more"
                        color: Theme.bg
                        width: 18; height: 18
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
            id: rightGroup
            // Bound to the group's own implicit width, so the row layout cannot
            // squeeze it and clip the queue button off a narrow window.
            Layout.minimumWidth: implicitWidth
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            // The 8px gaps are a margin on each control, not one `spacing: 8`.
            // The speaker and the readout are one item whose own gap is the
            // readout's top padding, which a group-wide spacing cannot express.
            spacing: 0

            Item { Layout.fillWidth: true }

            // The speaker over the readout as one object, so the flyout
            // parented to it stands over both. Nothing here is given a `width`
            // or a `height`: a Layout owns its children's size.
            ColumnLayout {
                id: volStack
                Layout.leftMargin: 8
                Layout.alignment: Qt.AlignVCenter
                // Zero on purpose: the gap is the readout's own top padding
                // (see volumeStackGap), so there is no dead strip between them.
                spacing: 0

                IconButton {
                    id: volBtn
                    objectName: "playerBarVolumeButton"
                    Layout.alignment: Qt.AlignHCenter
                    icon: player.muted ? "vol-mute" : (player.volume < 0.3 ? "vol-low" : player.volume < 0.7 ? "vol-mid" : "vol-high")
                    size: 18; iconColor: Theme.textSec
                    onClicked: player.setMuted(!player.muted)
                }

                // The level, in words, at rest. Layout.preferredWidth and not
                // width: a Layout reads a Text's implicit width first, and a
                // label that measured itself would shift its neighbours.
                Text {
                    id: volPct
                    objectName: "playerBarVolumePercent"
                    Layout.preferredWidth: root.volumePercentWidth
                    Layout.alignment: Qt.AlignHCenter
                    // Up over the empty bottom of the speaker's tap target, and
                    // the same amount back on as padding so nothing but this
                    // number moves. See volumeSpeakerBoxSlack.
                    Layout.topMargin: -root.volumeSpeakerBoxSlack
                    topPadding: root.volumeStackGap
                    bottomPadding: root.volumeSpeakerBoxSlack
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("%1%").arg(
                        Math.round((player.muted ? 0 : player.volume) * 100)
                            .toLocaleString(Qt.locale(), 'f', 0))
                    color: Theme.textDim; font.pixelSize: 12
                    HoverHandler { id: volPctHov }
                }
            }

            OutputPicker {
                id: outputBtn
                objectName: "playerBarOutputButton"
                Layout.leftMargin: 8
                size: 20
            }

            // The two controls that open a view, side by side. The arrow
            // points up because Now Playing comes up over the bar.
            IconButton {
                id: nowPlayingBtn
                objectName: "playerBarNowPlayingButton"
                visible: root.hasTrack
                Layout.leftMargin: 8
                icon: "chevron-up"
                size: 18
                iconColor: Theme.textSec
                ToolTip.visible: nowPlayingTipHov.hovered
                ToolTip.text: qsTr("Open Now Playing", "player bar button, opens the full-page player")
                ToolTip.delay: 600
                HoverHandler { id: nowPlayingTipHov }
                onClicked: root.showNowPlaying()
            }

            IconButton {
                id: queueBtn
                Layout.leftMargin: 8
                icon: "queue"; size: 20
                iconColor: Theme.textSec
                onClicked: root.showQueue()
            }
        }
    }

    // ── the volume on hover ──────────────────────────────────────────────
    // Pointing at the speaker or the readout brings the slider up over the
    // bar. Hover only, and it withdraws while the output menu is open: both
    // draw upwards out of the bar and would otherwise overlap.
    readonly property bool wantVolumeFlyout:
        !outputBtn.menuVisible && (volBtn.hovered || volPctHov.hovered)

    VolumeFlyout {
        id: volumeFlyout
        objectName: "playerBarVolumeFlyout"
        // The stack, not the speaker in it: the popup centres itself on its
        // parent, and centred on the stack it stands over both rows.
        parent: volStack
        pointedAt: root.wantVolumeFlyout
    }

    // ── the flyout itself, built once for both places the volume lives ───
    // Now Playing instantiates this too, as it does OutputPicker, so the two
    // places share one behaviour.
    component VolumeFlyout : Popup {
        id: flyout

        // What the host points at. The flyout adds its own hover, because the
        // pointer is over the popup for the whole time it is being used.
        property bool pointedAt: false
        readonly property bool wanted: flyout.pointedAt || flyoutHov.hovered
        readonly property alias slider: flyoutSlider

        property int sliderLength:    110
        property int sliderThickness: 20

        // Both come from the slider's fixed numbers, not from the popup's
        // realised geometry: on Qt 6.4 `y: -height - n` feeds a reposition
        // loop (see the output menu below).
        readonly property real flyoutWidth:  sliderThickness + leftPadding + rightPadding
        readonly property real flyoutHeight: sliderLength + topPadding + bottomPadding
        width:  flyoutWidth
        height: flyoutHeight
        // Upward, and centred on whatever it is parented to. Upward in both
        // places: here it has only the 82px of bar below it, and in Now
        // Playing the transport row has the Up Next list under it.
        x: parent ? Math.round((parent.width - flyoutWidth) / 2) : 0
        y: -flyoutHeight - 6
        padding: 10

        // Hover decides when this goes away, not a click somewhere else: an
        // auto-close would fight the timer below and swallow the click that
        // was meant for whatever is underneath.
        closePolicy: Popup.NoAutoClose

        onWantedChanged: {
            if (flyout.wanted) {
                flyoutCloser.stop()
                flyout.open()
            } else {
                flyoutCloser.restart()
            }
        }

        // The pointer has to cross a few pixels between the speaker and the
        // slider. A plain interval, not Theme.dur(): it is a wait, and reduced
        // motion zeroing it would make the flyout impossible to reach.
        Timer {
            id: flyoutCloser
            interval: 240
            onTriggered: if (!flyout.wanted) flyout.close()
        }

        enter: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1
                              duration: Theme.dur(120); easing.type: Easing.OutCubic }
        }
        exit: Transition {
            NumberAnimation { property: "opacity"; from: 1; to: 0
                              duration: Theme.dur(120); easing.type: Easing.OutCubic }
        }

        background: Rectangle {
            color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup
        }

        contentItem: VolumeSlider {
            id: flyoutSlider
            objectName: "hoverVolumeSlider"
            orientation: Qt.Vertical
            implicitWidth:  flyout.sliderThickness
            implicitHeight: flyout.sliderLength
            value: player.muted ? 0 : player.volume
            onMoved: (v) => { player.setMuted(false); player.setVolume(v) }
        }

        HoverHandler { id: flyoutHov }
    }

    // ── the output picker ────────────────────────────────────────────────
    // One control for where the sound is playing: this computer's outputs and
    // any Chromecast the scan has turned up, under two headings. The icon is
    // the cast glyph while casting. `cast` is null on every platform but Linux.
    component OutputPicker : Item {
        id: picker

        property int size: 20

        // Player::availableAudioDevices() hands back [{id, label, isDefault}],
        // "System default" first with an empty id. Held in a property so a test
        // can supply its own.
        property var deviceSource: (typeof player !== "undefined") ? player : null

        // CastManager, which only exists on Linux; null makes the menu a
        // local-only picker. A property so a test can reach the null state.
        property var castSource: (typeof cast !== "undefined") ? cast : null

        readonly property bool casting: !!castSource && castSource.connected
        // So a host can tell whether this is showing without reaching into
        // the popup, which is what the volume flyout above stands back for.
        readonly property bool menuVisible: menu.visible
        readonly property alias menu: menu

        // Outputs are hot-pluggable, so the list is re-read every time the
        // menu opens rather than bound once; SettingsPanel re-reads on
        // aboutToShow for the same reason.
        property var localDevices: []

        function reloadDevices() {
            picker.localDevices =
                (deviceSource && typeof deviceSource.availableAudioDevices === "function")
                    ? deviceSource.availableAudioDevices() : []
        }

        // Outputs can also appear while the menu is up. Player raises
        // audioDevicesChanged(), and the list is re-read only while the menu is
        // showing: a refresh is no reason to put a menu on screen.
        Connections {
            target: picker.deviceSource
            // A host can hand in anything through deviceSource, and the stub
            // player tests/TestStubs.h installs has no such signal.
            ignoreUnknownSignals: true
            function onAudioDevicesChanged() {
                if (menu.visible) picker.reloadDevices()
            }
        }

        // ── making four sinks on one card distinguishable ────────────────
        // ALSA and PipeWire name a sink after the card first and the socket
        // last, so sinks on one card differ only at the end. A shared prefix
        // folds to a leading ellipsis, and the rest elides in the middle.

        // The shortest shared prefix worth hiding. Below this the shared part
        // is not what is costing the row its name, and folding would read
        // worse: "Speaker Left" must not become "... Left".
        readonly property int sharedPrefixFloor: 16

        // The rows as drawn: {id, label, fullLabel, isDefault}, where `label`
        // may have been folded and `fullLabel` is always what the backend said.
        readonly property var localRows: picker.foldSharedPrefixes(picker.localDevices)

        // The longest prefix two labels share, cut back to the last whole word.
        // Empty for two equal strings: there is nothing to tell apart.
        function sharedPrefix(a, b) {
            if (a === b) return ""
            var n = Math.min(a.length, b.length)
            var i = 0
            while (i < n && a.charAt(i) === b.charAt(i)) ++i
            var cut = a.substring(0, i).lastIndexOf(" ")
            return cut > 0 ? a.substring(0, cut) : ""
        }

        function foldSharedPrefixes(devices) {
            var rows = []
            var i, j
            for (i = 0; i < devices.length; ++i)
                rows.push({ id:        devices[i].id,
                            label:     devices[i].label,
                            fullLabel: devices[i].label,
                            isDefault: devices[i].isDefault === true })

            for (i = 0; i < rows.length; ++i) {
                // "System default" is a sentinel with an empty id, not a piece
                // of hardware, and shares no card name with anything.
                if (!rows[i].id) continue
                // The shortest prefix this device shares with a neighbour, not
                // the longest: sinks on one card can agree right up to a final
                // digit, and the part to lose is the card name they all share.
                var best = ""
                for (j = 0; j < rows.length; ++j) {
                    if (j === i || !rows[j].id) continue
                    var p = picker.sharedPrefix(rows[i].fullLabel, rows[j].fullLabel)
                    if (p.length < picker.sharedPrefixFloor) continue
                    if (best.length === 0 || p.length < best.length) best = p
                }
                if (best.length === 0) continue
                var rest = rows[i].fullLabel.substring(best.length)
                                            .replace(/^[\s:,\-]+/, "")
                if (rest.length === 0) continue
                rows[i].label = "… " + rest
            }
            return rows
        }

        function openMenu() {
            picker.reloadDevices()
            if (picker.castSource) picker.castSource.startScan()
            menu.open()
        }

        // Picking a local output while casting has to stop the cast as well,
        // or the choice is silently ignored: the sound is not coming out of
        // this machine at all.
        function chooseLocal(id) {
            if (picker.casting) picker.castSource.disconnect()
            prefs.audioDevice = id
            menu.close()
        }

        function chooseCast(id) {
            if (picker.castSource) picker.castSource.connectToDevice(id)
            menu.close()
        }

        width:  Math.max(size + 12, 32)
        height: Math.max(size + 12, 32)

        activeFocusOnTab: true
        Keys.onReturnPressed: picker.openMenu()
        Keys.onSpacePressed:  picker.openMenu()

        ToolTip.visible: outHov.hovered
        ToolTip.text: qsTr("Audio output", "player bar button, picks a speaker or a cast target")
        ToolTip.delay: 600

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: picker.activeFocus ? 2 : 0
            border.color: Theme.accent
        }

        VectorIcon {
            anchors.centerIn: parent
            name: picker.casting ? "cast" : "speaker"
            color: picker.casting ? Theme.accent
                 : outHov.hovered ? Theme.textPrimary : Theme.textSec
            width: picker.size
            height: picker.size
            strokeWidth: 1.5
        }

        HoverHandler { id: outHov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: picker.openMenu() }

        Popup {
            id: menu
            objectName: "outputMenu"
            x: picker.width - width
            width: 260
            padding: 6

            // Height and position come from the content, not the popup's own
            // geometry. On Qt 6.4 `y: -height - 10` loops in any style: the
            // positioner sets the height and the Layout moves the implicit one.
            readonly property real menuHeight:
                menuContent.implicitHeight + topPadding + bottomPadding
            height: menuHeight
            y: -menuHeight - 10
            background: Rectangle {
                color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup
            }
            contentItem: ColumnLayout {
                id: menuContent
                spacing: 2

                Text {
                    objectName: "outputLocalHeading"
                    visible: picker.localDevices.length > 0
                    text: qsTr("This computer")
                    color: Theme.textDim
                    font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    Layout.leftMargin: 8; Layout.topMargin: 4; Layout.bottomMargin: 2
                }
                Repeater {
                    model: picker.localRows
                    delegate: OutputRow {
                        required property var modelData
                        objectName: "outputLocalRow"
                        glyph: "speaker"
                        label: modelData.label
                        fullLabel: modelData.fullLabel
                        // Only one row in the whole menu is ticked, so a
                        // local output stops being the answer the moment the
                        // sound is going somewhere else.
                        active: !picker.casting && prefs.audioDevice === modelData.id
                        onSelected: picker.chooseLocal(modelData.id)
                    }
                }

                Text {
                    objectName: "outputCastHeading"
                    visible: !!picker.castSource
                    text: qsTr("Cast to")
                    color: Theme.textDim
                    font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    Layout.leftMargin: 8; Layout.topMargin: 6; Layout.bottomMargin: 2
                }
                Repeater {
                    model: picker.castSource ? picker.castSource.devices : []
                    delegate: OutputRow {
                        required property var modelData
                        objectName: "outputCastRow"
                        glyph: "cast"
                        label: modelData.name
                        active: picker.casting && picker.castSource.deviceName === modelData.name
                        onSelected: picker.chooseCast(modelData.id)
                    }
                }
                Text {
                    objectName: "outputCastSearching"
                    visible: !!picker.castSource && picker.castSource.devices.length === 0
                    text: qsTr("Searching for devices…")
                    color: Theme.textSec; font.pixelSize: 12
                    Layout.margins: 8
                }
            }
        }
    }

    // A selectable row in the output picker. The tick marks the row the sound
    // is going to.
    component OutputRow : Rectangle {
        id: orow
        property string label
        // What the backend called this, before the picker folded away the part
        // it shares with its neighbours.
        property string fullLabel: orow.label
        property string glyph: "speaker"
        property bool   active: false
        signal selected()
        Layout.fillWidth: true
        implicitWidth: 240
        implicitHeight: 36
        radius: Theme.radiusRow
        color: orowHov.hovered ? Theme.surfaceHov : "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
            VectorIcon {
                name: orow.glyph; width: 16; height: 16; strokeWidth: 1.6
                color: orow.active ? Theme.accent : Theme.textSec
            }
            Text {
                id: orowLabel
                objectName: "outputRowLabel"
                Layout.fillWidth: true; text: orow.label
                color: orow.active ? Theme.accent : Theme.textPrimary
                // The middle, not the right. What tells two outputs on the
                // same card apart is the socket at the end of the name, and
                // elide-right is the one mode that is guaranteed to delete it.
                font.pixelSize: 13; elide: Text.ElideMiddle
            }
            VectorIcon {
                visible: orow.active; name: "check"
                width: 14; height: 14; strokeWidth: 2; color: Theme.accent
            }
        }
        HoverHandler { id: orowHov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: orow.selected() }

        // The whole name, only for a row that is not showing all of it.
        ToolTip.visible: orowHov.hovered
                         && (orow.label !== orow.fullLabel || orowLabel.truncated)
        ToolTip.text: orow.fullLabel
        ToolTip.delay: 600
    }

    component IconButton : Item {
        id: iconBtn
        property string icon
        property color  iconColor: Theme.textSec
        property int    size: 18
        // The speaker's hover drives the volume flyout, which is not a child
        // of the button and so cannot see the handler below.
        readonly property alias hovered: hov.hovered
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
