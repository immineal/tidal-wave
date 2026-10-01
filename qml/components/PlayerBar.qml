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

    // ─── Responsive sizing ─────────────────────────────
    // Below this the right-hand group sheds the volume slider, so the
    // transport and the track info keep their space. 720 is where the full
    // group plus the left group's 280px preferred and the transport's 204px
    // stop fitting between the 16px margins.
    //
    // The slider is the only thing shed now. The output button stays at every
    // width: it says where the sound is going, which is the one thing about
    // it that has to be true at a glance, and it is the only way to reach the
    // device list without opening Now Playing. What a narrow bar loses is
    // only the always-visible slider, and hovering the speaker brings that
    // back (see volumeFlyout).
    readonly property int  compactRightBreakpoint: 720
    readonly property bool compactRight: root.width < compactRightBreakpoint

    // Exposed for tests/qml/tst_layout_player.qml: it checks the queue button
    // stays on screen and that the slider actually goes when the bar narrows.
    readonly property alias queueButton:  queueBtn
    readonly property alias volumeSlider: volSlider
    // The speaker, and the slider it reveals on hover once the inline one has
    // gone. tests/qml/tst_layout_player.qml drives both.
    readonly property alias volumeButton:      volBtn
    readonly property alias hoverVolumeSlider: volFlyoutSlider
    readonly property alias hoverVolumePopup:  volumeFlyout
    // The one picker for "where is this playing". tst_output_picker.qml reads
    // its menu and its icon.
    readonly property alias outputButton: outputBtn
    // Exposed for tests/qml/tst_nowplaying_access.qml: the button has to be on
    // screen at every supported width, and it sits with the queue button now,
    // not with Like.
    readonly property alias nowPlayingButton: nowPlayingBtn
    readonly property alias trackInfoGroup:   leftGroup

    // ─── Artist links (SPEC N2) ────────────────────────
    // TidalBridge::trackToMap() carries the whole artist list as [{id, name}].
    // Tracks whose map predates it — the recently-played entries saved to
    // disk, anything a caller builds by hand — only have the joined `artists`
    // string, so the single line below stands in for them.
    readonly property var artistList:
        (hasTrack && track.artistList && track.artistList.length > 0) ? track.artistList : []

    // Sits between two names and belongs to neither, so it is not a link.
    readonly property string artistSeparator: qsTr(", ", "between two artist names")

    FontMetrics { id: artistFm; font.pixelSize: 12 }

    // Where the i-th name begins, measured on the names in front of it rather
    // than on the laid-out items: a delegate cannot see its siblings' widths,
    // and binding a width to the x a Row just assigned is how binding loops
    // start.
    function artistStartX(i) {
        if (i <= 0) return 0
        var before = []
        for (var k = 0; k < i && k < root.artistList.length; k++)
            before.push(root.artistList[k].name)
        return artistFm.advanceWidth(before.join(root.artistSeparator))
    }

    // Routing lives on the application window, which is where TrackRow's
    // context menu reaches for it too.
    function openArtist(artistId) {
        if (artistId > 0 && Window.window)
            Window.window.navigate("artist", { artistId: artistId })
    }

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

    // S4: recently-played is tracked locally, and it is what orders the
    // sidebar. Every page declares where a play came from immediately before
    // starting it, so one listener on the always-present player bar records
    // all of them, rather than a markPlayed() call bolted onto each page's
    // play action (and forgotten on the next one). markPlayed() drops anything
    // that is not one of the four kinds the sidebar lists, so a "collection"
    // or "radio" source needs no filtering here.
    //
    // sourceChanged rather than a signal of its own per play: the one case it
    // misses is starting the same context twice in a row, and that cannot
    // change the ordering, because nothing was played in between and the
    // entry is already the most recent one.
    Connections {
        target: player
        function onSourceChanged() {
            library.markPlayed(player.sourceType, player.sourceId)
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
                // One hover target per artist, so a featured credit opens the
                // guest rather than the lead. What is not a name — the
                // separators, and the space after the last one — keeps the
                // left group's own job of opening Now Playing.
                Item {
                    id: artistLine
                    objectName: "playerBarArtistLine"
                    Layout.fillWidth: true
                    implicitHeight: Math.max(joinedArtists.implicitHeight, artistRow.implicitHeight)

                    // Declared first, so it sits under the names and they get
                    // the click before it does.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.showNowPlaying()
                    }

                    Text {
                        id: joinedArtists
                        objectName: "playerBarArtists"
                        anchors.left: parent.left
                        anchors.right: parent.right
                        visible: root.artistList.length === 0
                        text: hasTrack ? track.artists : ""
                        color: Theme.textSec; font.pixelSize: 12; elide: Text.ElideRight
                    }

                    Row {
                        id: artistRow
                        width: parent.width
                        visible: root.artistList.length > 0
                        spacing: 0

                        Repeater {
                            model: root.artistList
                            delegate: Row {
                                id: artistItem
                                required property var modelData
                                required property int index

                                readonly property bool linkable: Number(modelData.id) > 0
                                readonly property real sepWidth: index > 0 ? sep.implicitWidth : 0
                                // What the line has left once the names in
                                // front of this one have taken theirs. The
                                // pixel of slack absorbs the difference
                                // between the measured string and the
                                // rendered one.
                                readonly property real room:
                                    Math.max(0, artistRow.width - root.artistStartX(index) - sepWidth - 1)
                                // Too tight to read is too tight to aim at, so
                                // the name goes rather than leaving a clickable
                                // sliver behind.
                                visible: room >= 8
                                spacing: 0

                                Text {
                                    id: sep
                                    objectName: "playerBarArtistSeparator"
                                    visible: artistItem.index > 0
                                    text: root.artistSeparator
                                    color: Theme.textSec
                                    font.pixelSize: 12
                                }

                                Text {
                                    objectName: "playerBarArtistName"
                                    text: artistItem.modelData.name
                                    // Only the name that runs out of line
                                    // elides; the ones before it keep their
                                    // full width.
                                    width: Math.min(implicitWidth, artistItem.room)
                                    elide: Text.ElideRight
                                    font.pixelSize: 12
                                    font.underline: nameHit.containsMouse
                                    color: nameHit.containsMouse ? Theme.textPrimary : Theme.textSec

                                    // A MouseArea rather than a Tap/Hover
                                    // handler pair: a TapHandler only takes a
                                    // passive grab, so the Now Playing
                                    // MouseArea under the names answered the
                                    // same click and one press did both
                                    // things. This one swallows the press.
                                    // Disabled when the artist has no id, so
                                    // that name is not a dead target: the
                                    // click falls through and opens Now
                                    // Playing like the gaps around it.
                                    MouseArea {
                                        id: nameHit
                                        anchors.fill: parent
                                        enabled: artistItem.linkable
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.openArtist(Number(artistItem.modelData.id))
                                    }
                                }
                            }
                        }
                    }
                }
                Rectangle {
                    visible: hasTrack && player.audioQuality.length > 0
                    height: 16; width: ql.implicitWidth + 8; radius: Theme.radiusBadge
                    color: {
                        var q = player.audioQuality
                        if (q === "HI_RES_LOSSLESS") return Theme.accentWash
                        if (q === "LOSSLESS") return Theme.greenWash
                        return Theme.surfaceHigh
                    }
                    Text {
                        id: ql; anchors.centerIn: parent
                        text: player.qualityLabel(player.audioQuality)
                        color: Theme.textPrimary; font.pixelSize: 9; font.bold: true
                    }
                }
            }

            // Like is the only thing in this group that acts on the track, so
            // it is the only thing left in it. The up-arrow used to sit
            // beside it and does not any more: it opens a view rather than
            // doing anything to what is playing, so it belongs with the queue
            // button at the other end of the bar.
            IconButton {
                id: likeBtn
                visible: root.hasTrack
                icon: root.isLiked ? "heart-filled" : "heart"
                size: 16
                iconColor: root.isLiked ? Theme.accent : Theme.textSec
                ToolTip.visible: likeTipHov.hovered
                ToolTip.text: root.isLiked ? qsTr("Unlike track") : qsTr("Like track")
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
            // Never squeeze the transport: its five buttons measure 172px and
            // its four gaps 32px, and none of that can shrink. Without this the
            // row layout happily hands the column less than that and the
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
                    // The "still loading" state of the play button. No label
                    // can go in a 40px disc, so the mark is all there is; the
                    // three dots are drawn now rather than being an ellipsis
                    // borrowed from the font.
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
            // It used to declare `minimumWidth: 160`, so the row layout
            // squeezed it to 160 and the queue button clipped off the window
            // below about 731px. Binding the minimum to the group's own
            // implicit width keeps it honest as controls come and go, which
            // they now do: the up-arrow joined this group and the slider
            // leaves it below the breakpoint.
            Layout.minimumWidth: implicitWidth
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter; spacing: 8

            Item { Layout.fillWidth: true }

            IconButton {
                id: volBtn
                objectName: "playerBarVolumeButton"
                icon: player.muted ? "vol-mute" : (player.volume < 0.3 ? "vol-low" : player.volume < 0.7 ? "vol-mid" : "vol-high")
                size: 18; iconColor: Theme.textSec
                onClicked: player.setMuted(!player.muted)
            }

            VolumeSlider {
                id: volSlider
                visible: !root.compactRight
                width: 90
                value: player.muted ? 0 : player.volume
                onMoved: (v) => { player.setMuted(false); player.setVolume(v) }
                ToolTip.visible: volTipHov.hovered
                ToolTip.text: qsTr("%1%").arg(
                    Math.round((player.muted ? 0 : player.volume) * 100)
                        .toLocaleString(Qt.locale(), 'f', 0))
                ToolTip.delay: 400
                HoverHandler { id: volTipHov }
            }

            // Where the sound is going: this computer's outputs and any
            // Chromecast on the network, in one list. Replaces the cast
            // button, which was the only control here that could say so and
            // only knew about half of it.
            OutputPicker {
                id: outputBtn
                objectName: "playerBarOutputButton"
                size: 20
            }

            // The two controls that open a view, side by side. The arrow
            // points up because Now Playing comes up over the bar.
            IconButton {
                id: nowPlayingBtn
                objectName: "playerBarNowPlayingButton"
                visible: root.hasTrack
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
                icon: "queue"; size: 20
                iconColor: Theme.textSec
                onClicked: root.showQueue()
            }
        }
    }

    // ── volume on hover ──────────────────────────────────────────────────
    //
    // Below the breakpoint the inline slider is gone and the speaker can only
    // mute, which makes the bar's volume all-or-nothing. Pointing at the
    // speaker brings the slider back, over the bar rather than in it, so
    // nothing in the row moves and no width has to be found for it.
    //
    // It shares the right-hand group with the output picker, and the two are
    // kept apart three ways: the speaker and the output button are separate
    // controls with different glyphs (a cone with waves against a cabinet);
    // the triggers do not overlap, since this one is hover-only and never
    // takes a click while the output menu only ever opens on one; and the
    // output menu wins outright, because `wantVolumeFlyout` reads its
    // visibility and withdraws while it is open. Both draw upwards out of an
    // 82px bar, so without that last rule they would be drawn over each
    // other.
    readonly property bool wantVolumeFlyout:
        root.compactRight
        && !outputBtn.menuVisible
        && (volBtn.hovered || volFlyoutHov.hovered)

    onWantVolumeFlyoutChanged: {
        if (root.wantVolumeFlyout) {
            volFlyoutCloser.stop()
            volumeFlyout.open()
        } else {
            volFlyoutCloser.restart()
        }
    }

    // The pointer has to cross a few pixels of bar between the speaker and
    // the slider above it, and the flyout is not under the pointer for that
    // moment. Closing on a delay rather than at once is what stops it
    // flickering shut on the way.
    Timer {
        id: volFlyoutCloser
        interval: 240
        onTriggered: if (!root.wantVolumeFlyout) volumeFlyout.close()
    }

    Popup {
        id: volumeFlyout
        objectName: "playerBarVolumeFlyout"
        parent: volBtn
        // Centred over the speaker and clear of the bar's top border.
        x: (volBtn.width - width) / 2
        y: -height - 4
        padding: 10
        // Hover decides when this goes away, not a click somewhere else: an
        // auto-close would fight the timer above and swallow the click that
        // was meant for whatever is underneath.
        closePolicy: Popup.NoAutoClose
        background: Rectangle {
            color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup
        }
        contentItem: VolumeSlider {
            id: volFlyoutSlider
            objectName: "playerBarHoverVolumeSlider"
            // Both, because a Popup sizes itself from its content item's
            // implicit size and then forces the content to the result.
            // VolumeSlider carries a plain `height: 20` and no implicit one,
            // so without this the popup comes out nothing tall and the
            // slider's own hit area goes with it.
            implicitWidth: 110
            implicitHeight: 20
            value: player.muted ? 0 : player.volume
            onMoved: (v) => { player.setMuted(false); player.setVolume(v) }
        }
        HoverHandler { id: volFlyoutHov }
    }

    // ── the output picker ────────────────────────────────────────────────
    //
    // One control for "where is this playing", in one list under two
    // headings: this computer's own audio outputs, and any Chromecast or
    // Google Home the scan has turned up. There used to be a cast button that
    // knew only the second half, while the first half was buried in Settings.
    //
    // The icon is the speaker cabinet normally and the cast glyph while
    // casting, so the bar says at a glance that the sound has left the
    // machine. Now Playing instantiates this same component (it has the room
    // for it), rather than keeping a second picker of its own that could
    // drift.
    //
    // `cast` is null on every platform but Linux. That hides the cast
    // heading, its rows and the "searching" line, and leaves a perfectly
    // ordinary local picker behind: the local half is never guarded on it.
    component OutputPicker : Item {
        id: picker

        property int size: 20

        // Player::availableAudioDevices() hands back [{id, label, isDefault}]
        // with "System default" first carrying an empty id. Held in a
        // property rather than read off `player` inline so a test can supply
        // its own: tests/TestStubs.h has no such invokable.
        property var deviceSource: (typeof player !== "undefined") ? player : null

        // CastManager, which only exists on Linux: `cast` is null everywhere
        // else and the menu is then a local-only picker. Held in a property
        // for the same reason as deviceSource, and because null is the one
        // state a test cannot otherwise reach - the stub context always
        // installs a cast object.
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
            y: -height - 10
            x: picker.width - width
            width: 260
            padding: 6
            background: Rectangle {
                color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup
            }
            contentItem: ColumnLayout {
                spacing: 2

                // Same string the old picker put on its "play here" row. It
                // is the heading over the local outputs now, because picking
                // any one of them is what "play here" means.
                Text {
                    objectName: "outputLocalHeading"
                    visible: picker.localDevices.length > 0
                    text: qsTr("This computer")
                    color: Theme.textDim
                    font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    Layout.leftMargin: 8; Layout.topMargin: 4; Layout.bottomMargin: 2
                }
                Repeater {
                    model: picker.localDevices
                    delegate: OutputRow {
                        required property var modelData
                        objectName: "outputLocalRow"
                        glyph: "speaker"
                        label: modelData.label
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

    // A selectable row in the output picker. The tick is a state mark saying
    // which row the sound is going to, not an action icon, which is why it is
    // the one mark here that is not destructive.
    component OutputRow : Rectangle {
        id: orow
        property string label
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
                Layout.fillWidth: true; text: orow.label
                color: orow.active ? Theme.accent : Theme.textPrimary
                font.pixelSize: 13; elide: Text.ElideRight
            }
            VectorIcon {
                visible: orow.active; name: "check"
                width: 14; height: 14; strokeWidth: 2; color: Theme.accent
            }
        }
        HoverHandler { id: orowHov; cursorShape: Qt.PointingHandCursor }
        TapHandler   { onTapped: orow.selected() }
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
