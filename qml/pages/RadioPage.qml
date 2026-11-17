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

    // The order the column headings ask for: only what is shown and what
    // plays from here. root.tracks keeps the order it came in.
    TrackListHeader.Sort { id: trackSort }
    readonly property var shownTracks: trackSort.sorted(root.tracks)

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

    ListView {
        id: trackList
        objectName: "radioTracksList"
        anchors.fill: parent
        clip: true
        model: root.shownTracks
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {
            objectName: "radioScrollBar"
            policy: ScrollBar.AsNeeded
            // A long list keeps a handle the pointer can find and grab.
            minimumSize: availableHeight > 0 ? Math.min(1, Theme.scrollHandleMin / availableHeight) : 0
        }
        WheelStep { view: trackList }

        // The radio has no artwork of its own, so the hero shows the covers
        // of the first four tracks in it.
        // The hero, then the column headings, which scroll away with it.
        header: Column {
            width: trackList.width

            DetailHero {
                width: trackList.width
                kind: qsTr("Radio")
                title: root.radioTitle || qsTr("Track radio")
                artCovers: root.tracks.map(function (t) { return t ? t.coverUrl || "" : "" })
                artIcon: "waves"

                actions: [
                    PillButton {
                        visible: root.tracks.length > 0
                        text: qsTranslate("AlbumPage", "Play", "verb, button label")
                        icon: "play"
                        accent: true
                        onClicked: root.playFrom(root.shownTracks, 0)
                    },
                    PillButton {
                        visible: root.tracks.length > 0
                        text: qsTranslate("AlbumPage", "Shuffle")
                        icon: "shuffle"
                        accent: false
                        onClicked: {
                            player.setShuffle(true)
                            root.playFrom(root.shownTracks, Math.floor(Math.random() * root.tracks.length))
                        }
                    }
                ]
            }

            TrackListHeader {
                objectName: "radioTracksHeader"
                x: 16
                width: trackList.width - 32
                sort: trackSort
            }
        }

        delegate: TrackRow {
            required property var modelData
            required property int index
            width: trackList.width - 32
            x: 16
            trackNum:    index + 1
            title:       modelData.title
            artists:     modelData.artists
            albumTitle:  modelData.albumTitle
            durationStr: modelData.durationStr
            coverUrl:    modelData.coverUrl80
            trackData:   modelData
            onPlayRequested: root.playFrom(root.shownTracks, index)
        }

        // The footer, so with no tracks the message sits directly beneath
        // the hero and scrolls with it, as on MixPage.
        footer: Item {
            width: trackList.width
            height: root.loadFailed ? 200 : 32

            ColumnLayout {
                objectName: "radioLoadError"
                visible: root.loadFailed
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
    }

    DetailBar {
        objectName: "radioStickyHeader"
        backObjectName: "radioBack"
        flickable: trackList
        heroHeight: trackList.headerItem ? trackList.headerItem.height : 280
        title: root.radioTitle || qsTr("Track radio")
    }

    Skeleton { loading: root.loading; kind: "detail" }
}
