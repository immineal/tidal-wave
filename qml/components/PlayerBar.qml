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

    // ─── crossing that breakpoint ──────────────────────
    //
    // The slot the slider sits in, in pixels, and the one animated property in
    // this file: everything that has to move while the group regroups is
    // derived from it, the way components/SideBar.qml derives everything from
    // `panelWidth`. The bar used to re-form in a single frame, which moved the
    // speaker 98px sideways between two frames while nothing else on the bar
    // moved at all.
    //
    // It is the slot and not the slider's own width because an invisible item
    // is dropped from a RowLayout along with its margin: binding the slider's
    // width to this directly would have reserved 98px one frame and 0 the
    // next, which is the player bar's version of the bug QA reported against
    // the sidebar ("it reserves its space and for a few milliseconds there's a
    // black bar where it will expand to"). The slot stays visible until it has
    // actually closed, so the space it gives back is always the space it is
    // drawing.
    readonly property int  volumeSliderWidth: 90
    readonly property int  volumeTargetRoom: root.compactRight ? 0 : volumeSliderWidth
    property real volumeRoom: volumeTargetRoom

    // 150ms, OutCubic, at the quick end of the app's 100-200ms range: this is
    // a 98px move and anything slower reads as the bar thinking about it.
    // Reduced motion goes through the duration rather than through `enabled`,
    // so the regroup still starts and still finishes -- in the frame it
    // started (X6, and see Theme.dur).
    Behavior on volumeRoom {
        NumberAnimation { duration: Theme.dur(150); easing.type: Easing.OutCubic }
    }

    // How much of the slot this bar can afford to be holding, whatever the
    // animation still has to give back. At the breakpoint the slider exactly
    // fits, so every pixel the bar is narrower than that is a pixel the slot
    // has to have let go of already: this is the arithmetic that chose 720,
    // run backwards.
    //
    // It is here because a width change is not always a breakpoint crossing.
    // Dropping from 960 to 640 in one step -- half a screen to the window
    // minimum, which a tiling shortcut does in one frame -- asks the slot to
    // hold 90px that a 640px bar has not got, and the queue button would have
    // hung off the end of the window for the length of the animation. With the
    // cap, a bar that lands far below the breakpoint has already given the
    // space back and only closes the little that is left: 90px of travel at the
    // breakpoint, where the move is what the eye is following, and none of it
    // two hundred pixels below, where there was never room for it.
    readonly property real volumeRoomCap:
        Math.max(0, Math.min(volumeSliderWidth,
                             root.width - compactRightBreakpoint + volumeSliderWidth))

    // What the slot actually gets, and what every control's position below is
    // measured against.
    readonly property real volumeSlotRoom: Math.min(volumeRoom, volumeRoomCap)

    // How open the slot is, 0 closed and 1 at the slider's full width.
    readonly property real volumeOpenness:
        Math.max(0, Math.min(1, volumeSlotRoom / Math.max(1, volumeSliderWidth)))
    // Whether the inline slider has finished leaving. The hover flyout asks
    // this rather than `compactRight`, which goes true the instant the bar
    // crosses the breakpoint while the inline slider is still 90px wide and
    // on its way out: both sliders would have been on screen at once, one of
    // them drawn over the bar.
    readonly property bool volumeInlineGone: volumeSlotRoom <= 0

    // Exposed for tests/qml/tst_layout_player.qml: it checks the queue button
    // stays on screen and that the slider actually goes when the bar narrows,
    // and that the slot it leaves behind closes rather than vanishing.
    readonly property alias queueButton:  queueBtn
    readonly property alias volumeSlider: volSlider
    readonly property alias volumeSlot:   volSlot
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
    // string, which is what ArtistLinks falls back to.
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
                // One hover target and one tab stop per artist, so a
                // featured credit opens the guest rather than the lead. What is
                // not a name — the separators, and the space after the last one
                // — keeps the left group's own job of opening Now Playing.
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
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            // The 8px gaps are a margin on each control rather than one
            // `spacing: 8` on the group, because the slider's slot has to be
            // able to reach zero and a RowLayout's spacing cannot: it keeps
            // the full 8px on both sides of every visible item, so a slot
            // animating down to nothing would still have had 8px of spacing
            // left to give back in the frame it finally went invisible, and
            // the speaker would have hopped that far sideways at the end of an
            // animation whose whole point is that nothing hops. As a margin
            // the gap closes with the slot it belongs to. At rest the sums are
            // the ones the group had before: five gaps of 8 open, four closed.
            spacing: 0

            Item { Layout.fillWidth: true }

            IconButton {
                id: volBtn
                objectName: "playerBarVolumeButton"
                Layout.leftMargin: 8
                icon: player.muted ? "vol-mute" : (player.volume < 0.3 ? "vol-low" : player.volume < 0.7 ? "vol-mid" : "vol-high")
                size: 18; iconColor: Theme.textSec
                onClicked: player.setMuted(!player.muted)
            }

            // The slot, which is what the layout measures, and the slider
            // inside it, which is what the bar shows. Two items, because the
            // slot has one job the slider cannot do: a slider is 20px tall and
            // its handle hangs 5px off the left end of its own track, so a
            // nearly-closed slider would paint that handle over the speaker.
            // The slot clips it.
            //
            // Both directions are the same move in reverse. The slider shrinks
            // and fades as the slot closes, and grows and fades in as it opens;
            // it is gone, out of the layout and out of the tab order, only once
            // the slot has actually reached zero.
            Item {
                id: volSlot
                objectName: "playerBarVolumeSlot"
                visible: root.volumeSlotRoom > 0
                Layout.leftMargin: 8 * root.volumeOpenness
                Layout.preferredWidth: root.volumeSlotRoom
                Layout.preferredHeight: 20
                clip: true

                VolumeSlider {
                    id: volSlider
                    // On the slot and not on the breakpoint: the breakpoint goes
                    // in one frame and this has 150ms of travel to do. At rest
                    // the two say the same thing, which is the contract
                    // tst_output_picker.qml checks -- a settled narrow bar has no
                    // inline slider, and the hover flyout is the way to the
                    // volume there.
                    visible: root.volumeSlotRoom > 0
                    width: volSlot.width
                    height: volSlot.height
                    // The last fifth of the slot's travel takes the slider's
                    // opacity with it, in both directions, the mirror of the
                    // sidebar holding its wide-only content back until the panel
                    // is a quarter open: a 10px handle on an 8px track is a
                    // speck, not a control, and fading it means neither end of
                    // the move has anything half-drawn in it.
                    opacity: Math.min(1, root.volumeOpenness / 0.2)
                    value: player.muted ? 0 : player.volume
                    onMoved: (v) => { player.setMuted(false); player.setVolume(v) }
                    ToolTip.visible: volTipHov.hovered
                    ToolTip.text: qsTr("%1%").arg(
                        Math.round((player.muted ? 0 : player.volume) * 100)
                            .toLocaleString(Qt.locale(), 'f', 0))
                    ToolTip.delay: 400
                    HoverHandler { id: volTipHov }
                }
            }

            // Where the sound is going: this computer's outputs and any
            // Chromecast on the network, in one list. Replaces the cast
            // button, which was the only control here that could say so and
            // only knew about half of it.
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
    //
    // `volumeInlineGone` and not `compactRight`: the breakpoint goes while the
    // inline slider is still travelling, and a flyout that opened then would
    // put two sliders on screen at once, one of them over the bar.
    readonly property bool wantVolumeFlyout:
        root.volumeInlineGone
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

        // ...and they are hot-pluggable *while this menu is up*, which is a
        // second thing. Player raises audioDevicesChanged() from the deferred
        // turn of its own backend callback; without this the list stays as it
        // was when the menu opened, and closing and reopening was the only way
        // to see a sink that had just appeared. Both call sites - the bar and
        // Now Playing - get it, because it lives in the component.
        //
        // Only while the menu is showing: a refresh is not a reason to put a
        // menu on screen, and openMenu() re-reads anyway.
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
        //
        // ALSA and PipeWire name a sink after the card first and the socket
        // last: "Tiger Lake-H HD Audio Controller HDMI / DisplayPort 1". Every
        // sink on one card therefore reads identically for the first thirty-odd
        // characters and differs only at the very end - and elide-right threw
        // away exactly the end. On the Debian box all four physical sinks drew
        // as "Tiger Lake-H HD Audio Contr..." and the user could not pick.
        //
        // Two things fix it, in this order:
        //   * the prefix a device shares with another device is folded to a
        //     leading ellipsis, so the rows read "... Speaker" and "... HDMI /
        //     DisplayPort 1" and fit whole. The row keeps the full name for its
        //     tooltip. A device that shares nothing is untouched;
        //   * whatever is still too long elides in the middle, not on the
        //     right, so the socket at the end survives regardless.
        // Neither needs a wider popup, which matters: at scale factor 3.0 the
        // window is only 1280 logical px across and there is no room to widen
        // into.

        // The shortest shared prefix worth hiding. Below this the shared part
        // is not what is costing the row its name, and folding would read
        // worse: "Speaker Left" must not become "... Left".
        readonly property int sharedPrefixFloor: 16

        // The rows as drawn: {id, label, fullLabel, isDefault}, where `label`
        // may have been folded and `fullLabel` is always what the backend said.
        readonly property var localRows: picker.foldSharedPrefixes(picker.localDevices)

        // The longest prefix two labels share, cut back to the last whole word
        // so a folded row never starts in the middle of one. Empty for two
        // equal strings: there is nothing there to tell apart, and folding
        // would leave two rows both reading "...".
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
                // "System default" is a sentinel carrying an empty id, not a
                // piece of hardware. It shares no card name with anything, and
                // pairing it in could only ever shorten what the real sinks
                // have in common.
                if (!rows[i].id) continue
                // The *shortest* prefix this device shares with a neighbour,
                // not the longest. Three sinks on one card can share far more
                // than the card name with each other - "HDMI / DisplayPort 1"
                // and "... 2" agree right up to the digit - and folding to the
                // longest match leaves a row reading "... 1". The shortest
                // match that is still worth hiding is the card name, which is
                // the part they all have in common and the part to lose.
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

            // Height and position both come from the CONTENT, not from the
            // popup's own geometry.
            //
            // `y: -height - 10` is the ordinary idiom for "sit above the
            // button", and on Qt 6.4 it feeds a loop: the positioner sets the
            // popup's height during reposition, the Layout inside reacts to
            // that geometry change by rearranging, which moves the implicit
            // height, which repositions again. On a Debian box with Qt 6.4.2
            // that printed 1992 "called polish() inside updatePolish()"
            // warnings and eventually hung the test run outright.
            //
            // Note what it is NOT: the style. All 1992 warnings name
            // Controls/Basic/Popup.qml and the log mentions Fusion zero times,
            // so pinning Basic below 6.5 does not avoid this and never did -
            // the loop is the Popup/Layout interaction, whichever style draws
            // it.
            //
            // Binding both to the layout's own implicit height breaks the
            // cycle: the width is fixed, so that number does not depend on
            // anything the positioner touches.
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

    // A selectable row in the output picker. The tick is a state mark saying
    // which row the sound is going to, not an action icon, which is why it is
    // the one mark here that is not destructive.
    component OutputRow : Rectangle {
        id: orow
        property string label
        // What the backend called this, before the picker folded away the part
        // it shares with its neighbours. Same as `label` for a row that was
        // left alone, which is why the tooltip below only appears when there
        // is something more to read.
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

        // The whole name, for a row that is not showing all of it. Nothing
        // folded and nothing elided means nothing to add, and a tooltip
        // repeating the row underneath it would be noise.
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
