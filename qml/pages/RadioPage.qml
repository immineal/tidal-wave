import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import TidalWave

// A track's radio as a plain list, with no identity on it.
//
// This is the *fallback* viewer, and reaching it means one specific thing: the
// track did not name the mix its radio is, and `tracks/<id>` did not name one
// either. See TrackRow.startRadio(), which is the only route in.
//
// Why there is a second page at all: `tracks/<id>/radio` answers tracks and
// nothing else - no mix id, no artwork, no title of its own - so a station
// opened this way cannot be saved, cannot be unsaved, and cannot be the same
// thing as the mix row a saved radio shows up as in the sidebar. That split is
// what the owner reported twice ("the two different views of a track radio as a
// mix and a radio"). MixPage is the one viewer now; this one is what is left
// when there is no mix to open, and keeping it is what stops an absent id from
// turning "Start radio" into a dead menu entry.
Rectangle {
    id: root
    color: Theme.bg

    property var    radioTitle: ""
    property var    trackId:    0
    property var    tracks:     []
    property bool   loading:    false

    // What the last load was told, "" when it was served. The one callback used
    // to read `if (!err)` and drop it, which is AlbumPage's bug from 0361ac1 on
    // the page with the least left over: a station Tidal will not build - ask
    // for one from a track that has since been delisted and `tracks/<id>/radio`
    // answers 404 the same way `albums/<id>` does - left `tracks` empty and
    // `loading` false, which is this page's empty initial state.
    property string loadError: ""

    // Nothing came back at all. The list *is* this page: there is no artwork, no
    // description and the one pill hides itself when there is nothing to play,
    // so a refusal leaves a correct heading over an empty rectangle. The heading
    // is kept - it says which track the station was asked for, and it carries
    // the way back - and the message goes where the list would have been.
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
        // Which track this reply is about; see MixPage.loadMix(). A row's
        // "Start radio" can be used again from inside the station it opened,
        // and the page item is reused - so a reply for the station just left
        // must not empty, fill or condemn the one now on screen. A superseded
        // request is not a failure: checked first, and on its own.
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

        // Where the list would have been. The heading above stays, because it is
        // still true and still the way out; only the empty half is replaced.
        // A sibling in the same ColumnLayout rather than an overlay: a Layout
        // skips an invisible child outright, so the one of these two that is
        // drawn gets the whole remaining height either way.
        Item {
            objectName: "radioLoadError"
            visible: root.loadFailed
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 96, 420)
                spacing: 10

                VectorIcon {
                    Layout.alignment: Qt.AlignHCenter
                    // See the note on the chevron above: in a Layout the size
                    // has to be asked for, or the implicit 24 is what draws.
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    name: "waves"
                    color: Theme.textDim
                    strokeWidth: 1.5
                }

                Text {
                    objectName: "radioLoadErrorText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("No radio for this track")
                    color: Theme.textPrimary
                    font.pixelSize: 18
                    font.bold: true
                    wrapMode: Text.WordWrap
                }

                // Not the server's own string; see AlbumPage's panel for why.
                // One long literal and not a concatenation, so lupdate can read
                // it.
                Text {
                    objectName: "radioLoadErrorDetail"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Tidal would not build a station from it. The track may have been taken down, or it may not be available where you are.")
                    color: Theme.textSec
                    font.pixelSize: 13
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
                isPlaying:   player.currentTrack.id === modelData.id && player.playing
                trackData:   modelData
                onPlayRequested: root.playFrom(root.tracks, index)
            }
        }
    }

    LoadingOverlay { loading: root.loading }
}
