import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var albumId: 0
    property var albumData: ({})
    property var tracks: []
    property bool loading: false
    property bool isSaved: false

    // Records this album as the "playing from" source, then starts playback.
    function playFrom(list, i) {
        player.setPlaybackSource("album", "" + root.albumId, root.albumData.title || "")
        player.playTracks(list, i)
    }

    // "1 hr 4 min" / "52 min". Each case is a whole translatable string, so a
    // translation can reorder or re-unit it instead of inheriting English order.
    function durationText(seconds) {
        var loc  = Qt.locale()
        var hrs  = Math.floor(seconds / 3600)
        var mins = Math.floor((seconds % 3600) / 60)
        return hrs > 0
            ? qsTr("%1 hr %2 min").arg(hrs.toLocaleString(loc, 'f', 0)).arg(mins.toLocaleString(loc, 'f', 0))
            : qsTr("%1 min").arg(mins.toLocaleString(loc, 'f', 0))
    }

    function updateSavedState() {
        isSaved = albumId > 0 ? bridge.isAlbumFavorite(albumId) : false
    }

    readonly property int effectiveArtistId: albumData.artistId > 0 ? albumData.artistId
        : (tracks.length > 0 && tracks[0].artistId > 0 ? tracks[0].artistId : 0)

    onAlbumIdChanged: if (albumId > 0) { loadAlbum(); updateSavedState() }

    Connections {
        target: bridge
        function onFavoriteAlbumsChanged() { root.updateSavedState() }
    }

    // What the hero's queue actions act on: the whole album, which is not
    // always what the list is showing. The menu can be opened while
    // fetchAlbumTracks() is still out, so an empty page asks again rather
    // than queueing nothing.
    function allTracks(cb) {
        if (root.tracks.length > 0) { cb(root.tracks); return }
        if (!(root.albumId > 0)) return
        bridge.fetchAlbumTracks(root.albumId, function (t, err) {
            if (!err && t.length > 0) cb(t)
        })
    }

    function loadAlbum() {
        loading = true
        bridge.fetchAlbum(albumId, function(album, err) {
            if (!err) albumData = album
        })
        bridge.fetchAlbumTracks(albumId, function(t, err) {
            loading = false
            if (!err) tracks = t
        })
    }

    ListView {
        id: tracksList
        anchors.fill: parent
        clip: true
        model: root.tracks
        boundsBehavior: Flickable.StopAtBounds

        header: Column {
            width: tracksList.width

            // Hero header. Grows with its content rather than sitting at a
            // fixed 280: a wrapped title or a wrapped pill row used to be cut
            // off at the bottom edge.
            Rectangle {
                width: parent.width
                implicitHeight: Math.max(280, heroRow.implicitHeight + 48)
                color: "transparent"
                clip: true

                Image {
                    anchors.fill: parent
                    source: albumData.coverUrl640 ? "image://tidal/" + albumData.coverUrl640 : ""
                    fillMode: Image.PreserveAspectCrop
                    opacity: 0.18
                    smooth: true
                    mipmap: true
                }

                Rectangle {
                    anchors.fill: parent
                    // accentTint, not artScrimStrong. The hero is a tint over
                    // the page, not a wash over cover art - the artwork behind
                    // it is at 0.18 - and artScrimStrong is black at 60% in
                    // every theme by design. On the two light themes that
                    // composited to a mud grey that put the eyebrow at 1.3:1
                    // and the artist link at 2.2:1. Playlist, Mix and Now
                    // Playing already tint the same header from the accent.
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0; color: Theme.accentTint }
                        GradientStop { position: 1; color: Theme.bg }
                    }
                }

                RowLayout {
                    id: heroRow
                    anchors {
                        left: parent.left; right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 64; rightMargin: 24
                    }
                    spacing: 24

                    Rectangle {
                        objectName: "heroArt"
                        width: 200
                        height: 200
                        radius: Theme.radiusArt
                        color: Theme.surfaceHigh
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: albumData.coverUrl ? "image://tidal/" + albumData.coverUrl : ""
                            fillMode: Image.PreserveAspectCrop
                            smooth: true
                            mipmap: true
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 8

                        Text {
                            text: qsTr("Album")
                            color: Theme.textSec
                            font.pixelSize: 12
                            font.bold: true
                            font.letterSpacing: 1
                        }

                        Text {
                            Layout.fillWidth: true
                            text: albumData.title || ""
                            color: Theme.textPrimary
                            font.pixelSize: 28
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            id: artistNameText
                            Layout.fillWidth: true
                            text: albumData.artists || ""
                            color: root.effectiveArtistId > 0 ? Theme.accent : Theme.textSec
                            font.pixelSize: 14
                            elide: Text.ElideRight
                            activeFocusOnTab: root.effectiveArtistId > 0
                            Keys.onReturnPressed: if (root.effectiveArtistId > 0) root.navigateTo("artist", { artistId: root.effectiveArtistId })
                            Keys.onSpacePressed:  if (root.effectiveArtistId > 0) root.navigateTo("artist", { artistId: root.effectiveArtistId })
                            Rectangle {
                                anchors.fill: parent; anchors.margins: -4; radius: Theme.radiusButton; color: "transparent"
                                border.width: artistNameText.activeFocus ? 2 : 0
                                border.color: Theme.accent
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: root.effectiveArtistId > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: if (root.effectiveArtistId > 0) root.navigateTo("artist", { artistId: root.effectiveArtistId })
                            }
                        }

                        Text {
                            text: {
                                // Bullet-separated facts, each a complete qsTr unit.
                                var parts = []
                                if (albumData.year) parts.push(albumData.year)
                                if (albumData.numTracks) parts.push(qsTr("%n track(s)", "", albumData.numTracks))
                                if (albumData.duration > 0) parts.push(root.durationText(albumData.duration))
                                // Raw API codes like HI_RES_LOSSLESS never reach the user
                                if (albumData.quality) parts.push(player.qualityLabel(albumData.quality))
                                // qualityLabel echoes a code it does not know, and an
                                // unknown code can be empty, which otherwise leaves the
                                // line ending in a dangling separator.
                                return parts.filter(function (p) { return p && String(p).length > 0 }).join(" • ")
                            }
                            color: Theme.textSec
                            font.pixelSize: 13
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        // A Flow, so the pills wrap onto a second line instead
                        // of pushing the column past the hero's right edge.
                        // Three pills are 384px at the old fixed width, more
                        // than the 328px the column gets in a 640px pane.
                        Flow {
                            id: heroActions
                            Layout.fillWidth: true
                            spacing: 12
                            // The queue confirmation is drawn just above the
                            // row of actions it confirms. Assigned rather than
                            // bound: the hero lives in the list's header, and
                            // an id inside that component is out of reach from
                            // the page root, where the menu is.
                            Component.onCompleted: if (heroPinMenu) heroPinMenu.confirmAnchor = heroActions

                            PillButton {
                                text: qsTr("Play", "verb, button label")
                                icon: "play"
                                accent: true
                                onClicked: if (root.tracks.length > 0) root.playFrom(root.tracks, 0)
                            }

                            PillButton {
                                text: qsTr("Shuffle")
                                icon: "shuffle"
                                accent: false
                                onClicked: {
                                    if (root.tracks.length > 0) {
                                        player.setShuffle(true)
                                        root.playFrom(root.tracks, Math.floor(Math.random() * root.tracks.length))
                                    }
                                }
                            }

                            PillButton {
                                text: root.isSaved ? qsTr("Saved", "state, album is in the library")
                                                   : qsTr("Save", "verb, add album to the library")
                                icon: root.isSaved ? "heart-filled" : "heart"
                                accent: root.isSaved
                                onClicked: {
                                    if (root.isSaved) {
                                        bridge.removeAlbumFavorite(root.albumId, function(success) {})
                                    } else {
                                        bridge.addAlbumFavorite(root.albumId, function(success) {})
                                    }
                                }
                            }
                        }
                    }
                }

                // P2: a right-click on the hero pins what the page is showing.
                MouseArea {
                    objectName: "heroPinArea"
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: function (mouse) {
                        var p = mapToItem(root, mouse.x, mouse.y)
                        root.showHeroPinMenu(p.x, p.y)
                    }
                }
            }

            Item { height: 8; width: parent.width }
        }

        delegate: TrackRow {
            width: tracksList.width - 32
            x: 16
            trackNum:    index + 1
            title:       modelData.title
            artists:     modelData.artists
            albumTitle:  root.albumData.title || ""
            durationStr: modelData.durationStr
            showAlbum:   false
            showCover:   false
            isPlaying:   player.currentTrack.id === modelData.id && player.playing
            trackData:   modelData
            onPlayRequested: root.playFrom(root.tracks, index)
        }

        footer: Item { height: 32; width: tracksList.width }

        ScrollBar.vertical: ScrollBar {
            active: true
            policy: ScrollBar.AsNeeded
        }
    }

    // Sticky bar — back button always visible; title fades in once hero scrolls out
    Rectangle {
        id: stickyHeader
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52
        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b,
                       Math.min(0.95, Math.max(0, (tracksList.contentY - 200) / 80)))

        BackButton { anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 } }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 64
            anchors.rightMargin: 16
            spacing: 12
            opacity: Math.min(1, Math.max(0, (tracksList.contentY - 200) / 80))
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: albumData.title || ""
                    color: Theme.textPrimary
                    font.pixelSize: 15
                    font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: albumData.artists || ""
                    color: Theme.textSec
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border
            opacity: Math.min(1, Math.max(0, (tracksList.contentY - 200) / 80))
        }
    }

    function navigateTo(page, params) {
        Window.window.navigate(page, params || {})
    }

    // P2. The pin carries the labels and the artwork the page is showing, so
    // the sidebar row reads the same as the page it came from.
    readonly property alias pinMenu: heroPinMenu

    function showHeroPinMenu(x, y) {
        heroPinMenu.showPin(x, y, "album", root.albumId > 0 ? "" + root.albumId : "",
                            root.albumData.title || "", root.albumData.artists || "",
                            root.albumData.coverUrl || "")
    }

    ContextMenu {
        id: heroPinMenu
        objectName: "heroPinMenu"
        trackSource: root.allTracks
    }

    LoadingOverlay { loading: root.loading }
}
