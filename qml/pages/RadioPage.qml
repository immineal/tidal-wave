import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property var    radioTitle: ""
    property var    trackId:    0
    property var    tracks:     []
    property bool   loading:    false

    onTrackIdChanged: if (trackId > 0) loadRadio()

    function loadRadio() {
        loading = true
        tracks  = []
        bridge.fetchTrackRadio(trackId, function(t, err) {
            loading = false
            if (!err) tracks = t
        })
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            spacing: 16

            Text {
                text: "←"
                color: Theme.textSec
                font.pixelSize: 18
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Window.window.goBack() }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Text {
                    text: "Radio"
                    color: Theme.textDim
                    font.pixelSize: 11
                    font.bold: true
                    font.letterSpacing: 1
                }
                Text {
                    Layout.fillWidth: true
                    text: root.radioTitle || "Track Radio"
                    color: Theme.textPrimary
                    font.pixelSize: 22
                    font.bold: true
                    elide: Text.ElideRight
                }
            }

            PillButton {
                visible: root.tracks.length > 0
                text: "Play all"
                glyph: "▶"
                accent: true
                onClicked: player.playTracks(root.tracks, 0)
            }
        }

        Item { height: 16 }

        Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

        Item { height: 8 }

        ListView {
            id: trackList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.tracks
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: TrackRow {
                required property var modelData
                required property int index
                width: trackList.width
                trackNum:    index + 1
                title:       modelData.title
                artists:     modelData.artists
                albumTitle:  modelData.albumTitle
                durationStr: modelData.durationStr
                coverUrl:    modelData.coverUrl80
                isPlaying:   player.currentTrack.id === modelData.id && player.playing
                trackData:   modelData
                onPlayRequested: player.playTracks(root.tracks, index)
            }
        }
    }

    LoadingOverlay { loading: root.loading }
}
