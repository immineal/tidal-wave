import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Item {
    id: root
    height: 52
    implicitWidth: 100

    property int    trackNum: 1
    property string title: ""
    property string artists: ""
    property string albumTitle: ""
    property string durationStr: ""
    property string coverUrl: ""
    property bool   isPlaying: false
    property bool   showAlbum: true
    property bool   showCover: true
    property var    trackData: null   // full track map (has albumId, id, etc.)
    property bool   isLiked: trackData ? bridge.isTrackFavorite(trackData.id) : false
    // Playlist context: set when TrackRow is inside a PlaylistPage
    property string playlistUuid: ""
    property int    trackItemIndex: -1  // 0-based position in playlist
    property bool   showPopularity: false

    Connections {
        target: bridge
        function onFavoriteTracksChanged() {
            root.isLiked = root.trackData ? bridge.isTrackFavorite(root.trackData.id) : false
        }
    }

    signal playRequested()
    signal menuRequested(real x, real y)
    signal removeFromPlaylistRequested(int itemIndex)

    activeFocusOnTab: true
    Keys.onReturnPressed: root.playRequested()
    Keys.onSpacePressed:  root.playRequested()
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            root.menuRequested(width / 2, height / 2)
            contextMenu.popup()
            event.accepted = true
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: 6
        color: isPlaying ? Qt.rgba(0, 0.698, 0.973, 0.08)
               : hov.hovered ? Theme.surfaceHov : "transparent"
        border.width: root.activeFocus ? 2 : 0
        border.color: Theme.accent

        MouseArea {
            id: hov
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            readonly property bool hovered: containsMouse

            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    contextMenu.popup()
                } else {
                    root.playRequested()
                }
            }
        }

        RowLayout {
            anchors { fill: parent; leftMargin: 12; rightMargin: 28 }
            spacing: 12

            // Track number / now playing indicator
            Item {
                width: 24
                Layout.alignment: Qt.AlignVCenter
                Text {
                    anchors.centerIn: parent
                    visible: !isPlaying && !hov.hovered
                    text: root.trackNum
                    color: Theme.textDim
                    font.pixelSize: 13
                }
                VectorIcon {
                    anchors.centerIn: parent
                    visible: isPlaying && !hov.hovered
                    name: "music"
                    color: Theme.accent
                    width: 14
                    height: 14
                    strokeWidth: 1.5
                }
                Text {
                    anchors.centerIn: parent
                    visible: hov.hovered
                    text: isPlaying ? "⏸" : "▶"
                    color: Theme.textPrimary
                    font.pixelSize: 14
                }
            }

            // Cover art
            Rectangle {
                visible: showCover
                width: 36; height: 36; radius: 4
                color: Theme.surfaceHigh
                clip: true
                Image {
                    anchors.fill: parent
                    source: coverUrl.length > 0 ? "image://tidal/" + coverUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                    mipmap: true
                }
            }

            // Title + artists
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                Text {
                    Layout.fillWidth: true
                    text: root.title
                    color: isPlaying ? Theme.accent : Theme.textPrimary
                    font.pixelSize: 14
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: root.artists
                    color: Theme.textSec
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
            }

            // Album
            Text {
                visible: showAlbum
                Layout.preferredWidth: 160
                text: root.albumTitle
                color: Theme.textSec
                font.pixelSize: 13
                elide: Text.ElideRight
            }

            // Duration
            Text {
                text: root.durationStr
                color: Theme.textDim
                font.pixelSize: 13
                Layout.preferredWidth: 40
                horizontalAlignment: Text.AlignRight
            }

            // Popularity — shown only when showPopularity is true (Search page)
            Text {
                id: popText
                visible: root.showPopularity && root.trackData && root.trackData.popularity > 0
                text: root.trackData ? root.trackData.popularity + "%" : ""
                color: Theme.textDim
                font.pixelSize: 11
                Layout.preferredWidth: 40
                horizontalAlignment: Text.AlignRight
                ToolTip.visible: popHov.hovered && visible
                ToolTip.text: "Popularity"
                ToolTip.delay: 400
                HoverHandler { id: popHov }
            }

            // Context menu button
            Item {
                visible: hov.hovered
                Layout.preferredWidth: 24
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignVCenter
                VectorIcon {
                    anchors.centerIn: parent
                    name: "more"
                    color: Theme.textSec
                    width: 16
                    height: 16
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (m) => {
                        root.menuRequested(m.x, m.y)
                        contextMenu.popup()
                    }
                }
            }
        }
    }

    Menu {
        id: contextMenu
        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: 8; implicitWidth: 200 }

        MenuItem {
            text: "▶  Play now"
            contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: root.playRequested()
        }
        MenuItem {
            text: "+  Add to queue"
            contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: { if (root.trackData) player.appendQueue([root.trackData]) }
        }
        MenuItem {
            text: "📋  Add to playlist"
            enabled: root.trackData !== null
            contentItem: Text { text: parent.text; color: parent.enabled ? Theme.textPrimary : Theme.textDim; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: { if (root.trackData) playlistPicker.openFor(root.trackData.id) }
        }
        MenuItem {
            text: "🗑  Remove from playlist"
            visible: root.playlistUuid.length > 0
            height: visible ? implicitHeight : 0
            enabled: root.trackData !== null && root.playlistUuid.length > 0
            contentItem: Text { text: parent.text; color: parent.enabled ? Theme.red : Theme.textDim; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: {
                if (root.trackData && root.playlistUuid.length > 0 && root.trackItemIndex >= 0)
                    root.removeFromPlaylistRequested(root.trackItemIndex)
            }
        }
        MenuItem {
            text: "📻  Start radio"
            enabled: root.trackData !== null
            contentItem: Text { text: parent.text; color: parent.enabled ? Theme.textPrimary : Theme.textDim; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: {
                if (!root.trackData) return
                Window.window.navigate("radio", {
                    trackId:    root.trackData.id,
                    radioTitle: root.trackData.title
                })
            }
        }
        MenuItem {
            text: root.isLiked ? "♥  Unlike" : "♡  Like"
            enabled: root.trackData !== null
            contentItem: Text { text: parent.text; color: parent.enabled ? Theme.textPrimary : Theme.textDim; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: {
                if (!root.trackData) return
                if (root.isLiked) {
                    bridge.removeTrackFavorite(root.trackData.id, function(success) {})
                } else {
                    bridge.addTrackFavorite(root.trackData.id, function(success) {})
                }
            }
        }
        MenuSeparator {}
        MenuItem {
            text: "💿  Go to album"
            enabled: root.trackData && root.trackData.albumId > 0
            contentItem: Text { text: parent.text; color: parent.enabled ? Theme.textPrimary : Theme.textDim; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: {
                if (root.trackData && root.trackData.albumId > 0)
                    Window.window.navigate("album", { albumId: root.trackData.albumId })
            }
        }
        MenuItem {
            text: "🎤  Go to artist"
            enabled: root.trackData && root.trackData.artistId > 0
            contentItem: Text { text: parent.text; color: parent.enabled ? Theme.textPrimary : Theme.textDim; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: {
                if (root.trackData && root.trackData.artistId > 0)
                    Window.window.navigate("artist", { artistId: root.trackData.artistId })
            }
        }
        MenuSeparator {}
        MenuItem {
            text: "🔗  Copy link"
            enabled: root.trackData !== null
            contentItem: Text { text: parent.text; color: parent.enabled ? Theme.textPrimary : Theme.textDim; font.pixelSize: 13; leftPadding: 12; horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: {
                if (root.trackData)
                    bridge.copyToClipboard("https://tidal.com/browse/track/" + root.trackData.id)
            }
        }
    }

    // Playlist picker popup (for "Add to playlist")
    Popup {
        id: playlistPicker
        anchors.centerIn: Overlay.overlay
        width: 340
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 0
        property var pendingTrackId: 0

        function openFor(trackId) {
            pendingTrackId = trackId
            plPickerModel.clear()
            open()
            bridge.fetchUserPlaylists(function(pls, err) {
                plPickerModel.clear()
                for (var i = 0; i < pls.length; i++) {
                    plPickerModel.append(pls[i])
                }
            }, 50, 0)
        }

        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: 12 }

        Column {
            width: parent.width

            Item {
                width: parent.width
                height: 52
                Text {
                    anchors.left: parent.left; anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add to playlist"
                    color: Theme.textPrimary; font.pixelSize: 15; font.bold: true
                }
                VectorIcon {
                    anchors.right: parent.right; anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    name: "x"; color: Theme.textSec; width: 12; height: 12; strokeWidth: 2
                    MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: playlistPicker.close() }
                }
            }
            Rectangle { width: parent.width; height: 1; color: Theme.border }

            ListView {
                id: plPickerList
                width: parent.width
                height: Math.min(contentHeight, 300)
                clip: true
                model: ListModel { id: plPickerModel }
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Item {
                    width: plPickerList.width
                    height: 44
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: 6
                        color: plHov2.hovered ? Theme.surfaceHov : "transparent"
                        HoverHandler { id: plHov2 }
                        TapHandler {
                            onTapped: {
                                bridge.addTracksToPlaylist(model.uuid, playlistPicker.pendingTrackId, function(ok) {})
                                playlistPicker.close()
                            }
                        }
                        Row {
                            anchors.left: parent.left; anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10
                            Rectangle {
                                width: 28; height: 28; radius: 4; color: Theme.surface; clip: true
                                Image {
                                    anchors.fill: parent
                                    source: model.coverUrl ? "image://tidal/" + model.coverUrl : ""
                                    fillMode: Image.PreserveAspectCrop; smooth: true
                                }
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                Text { text: model.title; color: Theme.textPrimary; font.pixelSize: 13 }
                                Text { text: model.numTracks + " tracks"; color: Theme.textSec; font.pixelSize: 11 }
                            }
                        }
                    }
                }
            }

            Item { width: parent.width; height: 8 }
        }
    }
}
