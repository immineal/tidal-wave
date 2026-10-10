import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    // The width the collapsed sidebar hands back. Below the rail breakpoint the
    // pane gets wider as the window narrows, so a breakpoint subtracts this to
    // measure against a width that only shrinks with the window.
    readonly property int sidebarReclaim: {
        var w = Window.window ? Window.window.width : 0
        return (w > 0 && w < prefs.railBreak())
               ? Math.max(0, prefs.sidebarWidth - prefs.rail()) : 0
    }

    property string mixId: ""
    property string title: ""
    property string subtitle: ""
    property string coverUrl: ""
    property var    tracks: []
    property bool   loading: false

    // Which kind of mix, as Tidal names it: "DISCOVERY_MIX", "TRACK_MIX" and so
    // on. Code branches on this and never on the title, which arrives in the
    // account's language. A TRACK_MIX is a track's radio.
    property string mixType: ""

    // Whether this mix is in the account's saved mixes. Read back from the
    // bridge and never written here. Separate from a pin, which is local to
    // this machine: the pill is this, the right-click menu is PinStore.
    property bool isSaved: false

    // The heading over the title: "Radio" for a track's radio station, "Mix"
    // for everything else.
    readonly property bool isTrackRadio: root.mixType === "TRACK_MIX"

    function updateSavedState() {
        isSaved = mixId.length > 0 ? bridge.isMixFavorite(mixId) : false
    }

    // The Save pill's one call, and what it says when the server refuses it.
    readonly property alias favoriteAction: mixFav
    ContextMenu.FavoriteAction { id: mixFav }

    Connections {
        target: bridge
        function onFavoriteMixesChanged() { root.updateSavedState() }
    }

    // What the last load was told, "" when it was served.
    property string loadError: ""

    // Nothing came back at all. The hero stays, since the caller's title and
    // artwork are still correct. Gated on what the server said: a mix in flight
    // and a video mix both legitimately have no tracks.
    readonly property bool loadFailed:
        loadError.length > 0 && !loading && tracks.length === 0

    // Records this mix as the "playing from" source, then starts playback.
    function playFrom(list, i) {
        player.setPlaybackSource("mix", root.mixId, root.title)
        player.playTracks(list, i)
    }

    onMixIdChanged: if (mixId.length > 0) { loadMix(); updateSavedState() }

    // What the hero's queue actions act on: the whole mix. The menu can be
    // opened while fetchMixTracks() is still out, so an empty page asks
    // again rather than queueing nothing.
    function allTracks(cb) {
        if (root.tracks.length > 0) { cb(root.tracks); return }
        if (root.mixId.length === 0) return
        bridge.fetchMixTracks(root.mixId, function (t, err) {
            if (!err && t.length > 0) cb(t)
        })
    }

    // The page labels itself from the response, since it can be opened with
    // nothing but an id. A caller's labels keep the hero from flashing empty,
    // and a response that leaves one out never blanks the caller's.
    function loadMix() {
        loading = true
        loadError = ""
        // Which mix this reply is about. The loader is reused when one mix
        // navigates to another, so a slow reply for the mix just left would
        // otherwise retitle the one now on screen.
        var requested = mixId
        bridge.fetchMixPage(requested, function (header, t, err) {
            // Kept apart from the error check below: a reply for a mix already
            // left is not a failure and must draw nothing.
            if (requested !== root.mixId) return
            loading = false
            if (err) { root.loadError = err; return }
            if (header) {
                if (header.title)    root.title    = header.title
                if (header.subtitle) root.subtitle = header.subtitle
                if (header.coverUrl) root.coverUrl = header.coverUrl
                // Same rule: a header that names no mixType must not turn a
                // caller's "TRACK_MIX" back into "".
                if (header.mixType)  root.mixType  = header.mixType
            }
            tracks = t
        })
    }

    ListView {
        id: tracksList
        anchors.fill: parent
        clip: true
        model: root.tracks
        boundsBehavior: Flickable.StopAtBounds

        header: Rectangle {
            width: tracksList.width
            // Grows with its content, so a wrapped title or pill row fits.
            implicitHeight: Math.max(240, heroRow.implicitHeight + 48)
            color: "transparent"

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
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
                    width: 180
                    height: 180
                    radius: Theme.radiusArt
                    color: Theme.accentWash
                    clip: true
                    Image {
                        id: mixCover
                        objectName: "heroCover"
                        anchors.fill: parent
                        source: root.coverUrl.length > 0 ? "image://tidal/" + root.coverUrl : ""
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                        opacity: status === Image.Ready ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.dur(200) } }
                    }
                    VectorIcon {
                        visible: mixCover.status !== Image.Ready
                        anchors.centerIn: parent
                        name: "mix"
                        color: Theme.accent
                        width: 64
                        height: 64
                        strokeWidth: 1.5
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 8

                    Text {
                        objectName: "heroKindLabel"
                        text: root.isTrackRadio
                              ? qsTr("Radio", "noun, a track's radio station")
                              : qsTr("Mix", "noun, a Tidal mix")
                        color: Theme.textSec
                        font.pixelSize: 12
                        font.bold: true
                        font.letterSpacing: 1
                    }

                    Text {
                        objectName: "heroTitle"
                        Layout.fillWidth: true
                        text: root.title
                        color: Theme.textPrimary
                        font.pixelSize: 28
                        font.bold: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: root.subtitle.length > 0
                        Layout.fillWidth: true
                        text: root.subtitle
                        color: Theme.textSec
                        font.pixelSize: 14
                        wrapMode: Text.WordWrap
                    }

                    // A Flow, so the pills wrap when a translation widens them.
                    Flow {
                        id: heroActions
                        Layout.fillWidth: true
                        spacing: 12
                        // The queue confirmation is drawn just above this row.
                        // Assigned, not bound: an id inside the list's header
                        // component is out of reach from the page root.
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

                        // The account-wide favourite, a heart and the words as
                        // on AlbumPage. The local pin is on the right-click
                        // menu and writes nothing to Tidal.
                        PillButton {
                            objectName: "mixSavePill"
                            // Dead until the page knows which mix it is: a
                            // MixPage can be constructed with no id at all.
                            enabled: root.mixId.length > 0
                            text: root.isSaved ? qsTr("Saved", "state, mix is in the library")
                                               : qsTr("Save", "verb, add mix to the library")
                            icon: root.isSaved ? "heart-filled" : "heart"
                            accent: root.isSaved
                            // On the action row, which has clear space above.
                            onClicked: root.favoriteAction.toggleMix(root.mixId, root.isSaved,
                                                                    heroActions)
                        }
                    }
                }
            }

            // A right-click on the hero pins what the page is showing.
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

        delegate: TrackRow {
            width: tracksList.width - 32
            x: 16
            // Against the width this row would have with the sidebar out, so
            // the column cannot reappear as the window narrows. See
            // root.sidebarReclaim.
            showAlbum:   width - root.sidebarReclaim >= albumBreakpoint
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

        // The footer, so on a mix with no tracks the message sits directly
        // beneath the header and scrolls with it.
        footer: Item {
            width: tracksList.width
            height: root.loadFailed ? 200 : 32

            ColumnLayout {
                objectName: "mixLoadError"
                visible: root.loadFailed
                anchors.centerIn: parent
                width: Math.min(parent.width - 96, 420)
                spacing: 10

                VectorIcon {
                    Layout.alignment: Qt.AlignHCenter
                    // A Layout owns the size of its direct children, so a plain
                    // width would be overwritten.
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    name: "mix"
                    color: Theme.textDim
                    strokeWidth: 1.5
                }

                Text {
                    objectName: "mixLoadErrorText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("This mix could not be loaded")
                    color: Theme.textPrimary
                    font.pixelSize: 18
                    font.bold: true
                    wrapMode: Text.WordWrap
                }

                // Not the server's own string; see AlbumPage's panel for why.
                // One long literal, since lupdate cannot read a concatenation.
                Text {
                    objectName: "mixLoadErrorDetail"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Tidal would not serve its tracks. A mix is rebuilt for you every day, so one that was saved or pinned a while ago may no longer exist.")
                    color: Theme.textSec
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                }
            }
        }

        ScrollBar.vertical: ScrollBar {
            active: true
            policy: ScrollBar.AsNeeded
        }
    }

    BackButton { anchors { top: parent.top; left: parent.left; margins: 16 } }

    LoadingOverlay { loading: root.loading }

    // The pin carries the labels and the artwork the page is showing, so the
    // sidebar row reads the same as the page it came from.
    readonly property alias pinMenu: heroPinMenu

    function showHeroPinMenu(x, y) {
        heroPinMenu.showPin(x, y, "mix", root.mixId, root.title, root.subtitle, root.coverUrl)
    }

    ContextMenu {
        id: heroPinMenu
        objectName: "heroPinMenu"
        trackSource: root.allTracks
    }
}
