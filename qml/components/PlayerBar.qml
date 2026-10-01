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
    // Below this the right-hand group sheds the volume slider and the cast
    // button, so the transport and the track info keep their space. 720 is
    // where the full group (218px) plus the left group's 280px preferred and
    // the transport's 204px stop fitting between the 16px margins. Now Playing
    // carries its own volume slider and its own cast picker, so neither
    // control is lost, only moved.
    readonly property int  compactRightBreakpoint: 720
    readonly property bool compactRight: root.width < compactRightBreakpoint

    // Exposed for tests/qml/tst_layout_player.qml: it checks the queue button
    // stays on screen and that the slider actually goes when the bar narrows.
    readonly property alias queueButton:  queueBtn
    readonly property alias volumeSlider: volSlider
    // Exposed for tests/qml/tst_nowplaying_access.qml: the button has to be on
    // screen at every supported width, and the group it sits in has to stay
    // the width it already was, or the transport shifts off centre.
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

            // The two buttons that act on the track sit together at the right
            // edge of the group, with only enough air between them to read as
            // two: each already carries 7px of padding inside its own 32px
            // box, and the group's 12px gap on top of that bought nothing but
            // width the title needs more.
            RowLayout {
                spacing: 4

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

                // Clicking the cover or the empty parts of the line above
                // opens Now Playing too, and always has, but nothing on the
                // bar said so. This is the control that says it, which is why
                // it is on screen rather than appearing on hover, and why it
                // points up: the page comes up over the bar. It lives inside
                // the left group's existing 280px, so the transport does not
                // move to make room for it.
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
            id: rightGroup
            // Measured, this group is 218px wide: 32 for the volume icon, 90
            // for the slider, 32 each for cast and queue, and four 8px gaps.
            // It used to declare `minimumWidth: 160`, so the row layout
            // squeezed it to 160 and the queue button clipped off the window
            // below about 731px. Binding the minimum to the group's own
            // implicit width keeps it honest as controls come and go.
            Layout.minimumWidth: implicitWidth
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter; spacing: 8

            Item { Layout.fillWidth: true }

            IconButton {
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

            // Cast to a Chromecast / Google Home device. Linux only: `cast`
            // is null elsewhere, which hides the button. Below the compact
            // breakpoint it moves to Now Playing, which has the room for it.
            IconButton {
                id: castBtn
                visible: !!cast && !root.compactRight
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
                        color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup
                    }
                    contentItem: ColumnLayout {
                        spacing: 2
                        Text {
                            text: qsTr("Cast to"); color: Theme.textDim
                            font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                            Layout.leftMargin: 8; Layout.topMargin: 4; Layout.bottomMargin: 2
                        }
                        CastRow {
                            label: qsTr("This computer")
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
                            text: qsTr("Searching for devices…")
                            color: Theme.textSec; font.pixelSize: 12
                            Layout.margins: 8
                        }
                    }
                }
            }

            IconButton {
                id: queueBtn
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
        radius: Theme.radiusRow
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
