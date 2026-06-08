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

    signal playRequested()
    signal menuRequested(real x, real y)

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

            // Context menu button
            Text {
                visible: hov.hovered
                text: "⋯"
                color: Theme.textSec
                font.pixelSize: 18
                Layout.preferredWidth: 24
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignVCenter
                MouseArea {
                    anchors.fill: parent
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
    }
}
