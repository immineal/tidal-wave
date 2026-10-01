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

    // Records this radio station as the "playing from" source, then plays.
    function playFrom(list, i) {
        player.setPlaybackSource("radio", "" + root.trackId, root.radioTitle)
        player.playTracks(list, i)
    }

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

            // Same drawn arrow as BackButton and PageHeader; see BackButton
            // for why none of the three is a character any more.
            VectorIcon {
                name: "chevron-left"
                color: Theme.textSec
                // In a RowLayout, so the size has to be asked for: a plain
                // width/height is overwritten by the layout.
                Layout.preferredWidth: 18
                Layout.preferredHeight: 18
                Layout.alignment: Qt.AlignVCenter
                strokeWidth: 2
                MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: Window.window.goBack() }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Text {
                    text: qsTr("Radio")
                    color: Theme.textDim
                    font.pixelSize: 11
                    font.bold: true
                    font.letterSpacing: 1
                }
                Text {
                    Layout.fillWidth: true
                    text: root.radioTitle || qsTr("Track Radio")
                    color: Theme.textPrimary
                    font.pixelSize: 22
                    font.bold: true
                    elide: Text.ElideRight
                }
            }

            PillButton {
                visible: root.tracks.length > 0
                text: qsTr("Play all")
                icon: "play"
                accent: true
                onClicked: root.playFrom(root.tracks, 0)
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
                onPlayRequested: root.playFrom(root.tracks, index)
            }
        }
    }

    LoadingOverlay { loading: root.loading }
}
