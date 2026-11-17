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

    // The failure came with Tidal out of reach; see AlbumPage.loadOffline.
    property bool loadOffline: false

    // Try again, and the way back once Tidal answers again.
    function retryLoad() {
        if (!(root.trackId > 0)) return
        if (bridge.offline) bridge.retryConnection()
        loadRadio()
    }

    Connections {
        target: bridge
        function onOfflineChanged() {
            if (!bridge.offline && root.loadFailed && root.loadOffline) root.retryLoad()
        }
    }

    // Records this radio station as the "playing from" source, then plays.
    function playFrom(list, i) {
        player.setPlaybackSource("radio", "" + root.trackId, root.radioTitle)
        player.playTracks(list, i)
    }

    onTrackIdChanged: if (trackId > 0) loadRadio()

    function loadRadio() {
        loading = true
        loadError = ""
        loadOffline = false
        tracks  = []
        // Which track this reply is about. trackId can change while it is in
        // flight, and a reply for a station already left must not touch the
        // one now on screen.
        var requested = trackId
        bridge.fetchTrackRadio(trackId, function(t, err) {
            if (requested !== root.trackId) return
            root.loading = false
            if (err) { root.loadError = err; root.loadOffline = bridge.offline === true; return }
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
        // The hero, then the column headings, which stay under the bar once
        // the hero has scrolled away. Over the rows, which pass beneath them.
        header: Item {
            width: trackList.width
            z: 2
            // A height from the start: a Column reports one only after its
            // first layout, and the view, scrolled to that, stays past the hero.
            height: hero.height + headings.height
            // For the bar, opaque by the time the headings reach it.
            readonly property real heroHeight: hero.height

            DetailHero {
                id: hero
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
                id: headings
                objectName: "radioTracksHeader"
                y: hero.height
                pinIn: trackList
                pinBelow: detailBar.height
                // At x 0 with the rows' width: a vertical ListView puts its
                // rows at its left edge, whatever x they ask for.
                width: trackList.width - 32
                sort: trackSort
            }
        }

        delegate: TrackRow {
            required property var modelData
            required property int index
            width: trackList.width - 32
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
            height: root.loadFailed ? loadErrorState.implicitHeight + 2 * Theme.space12 : 32

            ErrorState {
                id: loadErrorState
                objectName: "radioLoadError"
                visible: root.loadFailed
                anchors.centerIn: parent
                width: Math.min(parent.width - 96, 420)
                namePrefix: "radioLoadError"
                icon: "waves"
                offline: root.loadOffline
                title: qsTr("No radio for this track")
                // One long literal, since lupdate cannot read a concatenation.
                detail: qsTr("Tidal would not build a station from it. The track may have been taken down, or it may not be available where you are.")
                onRetry: root.retryLoad()
            }
        }
    }

    DetailBar {
        id: detailBar
        objectName: "radioStickyHeader"
        backObjectName: "radioBack"
        flickable: trackList
        heroHeight: trackList.headerItem ? trackList.headerItem.heroHeight : 280
        title: root.radioTitle || qsTr("Track radio")
    }

    Skeleton { loading: root.loading; kind: "detail" }
}
