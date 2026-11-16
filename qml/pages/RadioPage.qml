import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

// A track's radio as a plain list, with no identity on it. This is the fallback
// viewer: `tracks/<id>/radio` answers tracks and no mix id, so a station opened
// here cannot be saved. MixPage is the viewer whenever the track names its mix.
// TrackRow.startRadio() opens it; NowPlayingPage.sourceNav() returns to it.
Rectangle {
    id: root
    color: Theme.bg

    property var    radioTitle: ""
    property var    trackId:    0
    property var    tracks:     []
    property bool   loading:    false

    // What the last load was told, "" when it was served.
    property string loadError: ""

    // Nothing came back at all. The heading stays, since it names the track and
    // carries the way back, and the message goes where the list would be.
    readonly property bool loadFailed:
        loadError.length > 0 && !loading && tracks.length === 0

    // Records this radio station as the "playing from" source, then plays.
    function playFrom(list, i) {
        player.setPlaybackSource("radio", "" + root.trackId, root.radioTitle)
        player.playTracks(list, i)
    }

    onTrackIdChanged: if (trackId > 0) loadRadio()

    function loadRadio() {
        loading = true
        loadError = ""
        tracks  = []
        // Which track this reply is about. trackId can change while it is in
        // flight, and a reply for a station already left must not touch the
        // one now on screen.
        var requested = trackId
        bridge.fetchTrackRadio(trackId, function(t, err) {
            if (requested !== root.trackId) return
            root.loading = false
            if (err) { root.loadError = err; return }
            root.tracks = t
        })
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space6
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            // Same drawn arrow as BackButton, in a 32px target.
            Item {
                id: radioBack
                objectName: "radioBack"
                // In a RowLayout, so the size has to be asked for: a plain
                // width/height is overwritten by the layout.
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                Layout.alignment: Qt.AlignVCenter
                activeFocusOnTab: true
                Keys.onReturnPressed: Window.window.goBack()
                Keys.onSpacePressed:  Window.window.goBack()
                Accessible.role: Accessible.Button
                Accessible.name: qsTranslate("BackButton", "Back", "button, returns to the previous page")
                Accessible.onPressAction: Window.window.goBack()
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusMedium
                    color: "transparent"
                    border.width: radioBack.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.centerIn: parent
                    width: 18; height: 18
                    name: "chevron-left"
                    color: Theme.textSec
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Window.window.goBack() }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space1
                Text {
                    text: qsTr("Radio")
                    color: Theme.textDim
                    font.pixelSize: Theme.fontMicro
                    font.bold: true
                    font.letterSpacing: 1
                }
                Text {
                    Layout.fillWidth: true
                    text: root.radioTitle || qsTr("Track Radio")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontDisplay
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

        Item { height: Theme.space4 }

        Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

        Item { height: Theme.space2 }

        // Where the list would be. A sibling in the same ColumnLayout: a Layout
        // skips an invisible child, so the one drawn gets all the height.
        Item {
            objectName: "radioLoadError"
            visible: root.loadFailed
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 96, 420)
                spacing: Theme.space3

                VectorIcon {
                    Layout.alignment: Qt.AlignHCenter
                    // A Layout needs it asked for, or the implicit 24 draws.
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    name: "waves"
                    color: Theme.textDim
                }

                Text {
                    objectName: "radioLoadErrorText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("No radio for this track")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSection
                    font.bold: true
                    wrapMode: Text.WordWrap
                }

                // Not the server's own string; see AlbumPage's panel for why.
                // One long literal, since lupdate cannot read a concatenation.
                Text {
                    objectName: "radioLoadErrorDetail"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Tidal would not build a station from it. The track may have been taken down, or it may not be available where you are.")
                    color: Theme.textSec
                    font.pixelSize: Theme.fontMeta
                    wrapMode: Text.WordWrap
                }
            }
        }

        ListView {
            id: trackList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.loadFailed
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
                trackData:   modelData
                onPlayRequested: root.playFrom(root.tracks, index)
            }
        }
    }

    LoadingOverlay { loading: root.loading }
}
