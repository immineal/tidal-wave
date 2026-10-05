import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    // How much of this pane's width is only on loan. Below Prefs::railBreakpoint
    // the sidebar collapses to its 68px rail and hands the page back the ~150px
    // it had been using, so the pane gets *wider* as the window gets narrower:
    // the pane's width does not fall with the window's, it has a step in it.
    // Any column that switches on the pane therefore un-hides itself halfway
    // down a drag. The track rows' album column dropped out at an 892px window,
    // came back at 819 when the rail took over, and went again at 740, which is
    // the flicker the user saw. Subtracting the loan measures the breakpoint
    // against a width that only ever shrinks with the window, and across the
    // step it is the same number on both sides, so nothing jumps there either.
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

    // Which kind of mix, as Tidal names it: "DISCOVERY_MIX", "TRACK_MIX", and so
    // on. The only handle on that question code may branch on - the title
    // arrives in the account's language, so matching one breaks in German (see
    // MixTypes in src/api/Models.h).
    //
    // Here for one reason: a TRACK_MIX is a track's radio, and this page is now
    // the one and only viewer for one. Calling it a "Mix" on the heading is what
    // the owner noticed first ("it looks like an album except it says mix at the
    // top"), so the heading says what they asked for instead.
    property string mixType: ""

    // Whether this mix is in the account's saved mixes - Tidal's
    // v2/favorites/mixes, which is what put a radio saved on another device into
    // the sidebar in the first place.
    //
    // Read back out of the bridge and never written here, so a refused save has
    // nothing to undo, only something to say. See ContextMenu.FavoriteAction.
    //
    // NOT the same thing as a pin, and the hero keeps the two apart on purpose:
    // the pill is this, the account's own list, shared with every other Tidal
    // client; the right-click menu is PinStore, which is local to this machine
    // and this account and never leaves it. Conflating them is how this page
    // came to look as though it offered a way to unsave when it did not.
    property bool isSaved: false

    // The heading over the title. "Radio" for a track's radio station, because
    // that is the word every other surface in the app uses for one and the word
    // the user pressed to get here; "Mix" for everything else.
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

    // What the last load was told, "" when it was served. The one callback used
    // to read `if (err) return` and drop it, which is AlbumPage's bug from
    // 8ec30ed: a mix that has rotated out of the user's set, or one pinned to
    // the sidebar months ago, answers nothing for `pages/mix` - and the page
    // kept the title the caller handed it over an empty list, saying nothing
    // about why the list was empty.
    property string loadError: ""

    // Nothing came back at all. Milder than AlbumPage's and ArtistPage's case
    // on purpose: this page is *not* blank when it fails, because the title, the
    // subtitle and the artwork the caller passed are still correct and still on
    // screen. So the hero stays and only the empty half of the page says why.
    // Gated on what the server said and not on the list being empty, because a
    // mix still in flight, and a video mix whose track module this app cannot
    // read, both legitimately have nothing in them.
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

    // The page labels itself. It can be opened with nothing but an id - the
    // "Playing from" link in Now Playing navigates with exactly that, which is
    // how a mix came up with its tracks loaded and a blank hero - so the title,
    // the subtitle and the artwork come out of the response, not out of
    // whoever happened to navigate here.
    //
    // A caller that already has them still passes them, and should: that is
    // what keeps the hero from flashing empty for the length of a request. But
    // the page no longer depends on it, and nothing the response leaves out
    // overwrites what the caller gave - a header with no title, or no header
    // at all, leaves the caller's standing rather than blanking it.
    function loadMix() {
        loading = true
        loadError = ""
        // Which mix this reply is about. The loader is reused when one mix
        // navigates to another, so a slow reply for the mix just left would
        // otherwise retitle the one now on screen.
        var requested = mixId
        bridge.fetchMixPage(requested, function (header, t, err) {
            // Two checks that must never become one. This one says the reply is
            // about a mix the user has already left, which is not a failure and
            // must draw nothing; the one below says the mix on screen was
            // refused, which must. Folded together - as PlaylistPage's two
            // callbacks had them - fast navigation would draw error panels over
            // pages that are loading perfectly well.
            if (requested !== root.mixId) return
            loading = false
            if (err) { root.loadError = err; return }
            if (header) {
                if (header.title)    root.title    = header.title
                if (header.subtitle) root.subtitle = header.subtitle
                if (header.coverUrl) root.coverUrl = header.coverUrl
                // Same rule as the three above, and it matters more here: a
                // header that names no mixType must not turn a caller's
                // "TRACK_MIX" back into "", which would relabel the heading
                // "Mix" the moment the response landed.
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
            // Grows with its content rather than sitting at a fixed 240: a
            // wrapped title or a wrapped pill row used to be cut off at the
            // bottom edge.
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
                        // The hero knows what page it is; a mix with no
                        // artwork shows the mix glyph, not a note.
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

                    // A Flow, so the pills wrap instead of pushing the
                    // column past the hero's right edge once a German label
                    // makes them wider.
                    Flow {
                        id: heroActions
                        Layout.fillWidth: true
                        spacing: 12
                        // The queue confirmation is drawn just above the row
                        // of actions it confirms. Assigned rather than bound:
                        // the hero lives in the list's header, and an id
                        // inside that component is out of reach from the page
                        // root, where the menu is.
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

                        // The half of the complaint that was simply missing:
                        // nowhere in the app could a mix be saved or unsaved.
                        // A heart and the words, exactly as AlbumPage's pill
                        // reads, so the account-wide favourite is plainly a
                        // different affordance from the local pin on the
                        // right-click menu - which is a pin glyph and the words
                        // "Pin"/"Unpin" and writes nothing to Tidal.
                        PillButton {
                            objectName: "mixSavePill"
                            // Dead until the page knows which mix it is: a
                            // MixPage can be constructed with no id at all.
                            enabled: root.mixId.length > 0
                            text: root.isSaved ? qsTr("Saved", "state, mix is in the library")
                                               : qsTr("Save", "verb, add mix to the library")
                            icon: root.isSaved ? "heart-filled" : "heart"
                            accent: root.isSaved
                            // Anchored on the action row rather than the pill,
                            // the way the hero's pin menu anchors its
                            // confirmation: the pill sits low in the hero and
                            // the row is what has clear space above it.
                            onClicked: root.favoriteAction.toggleMix(root.mixId, root.isSaved,
                                                                    heroActions)
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

        // The footer, not an overlay anchored under the hero. On a mix with no
        // tracks the footer sits directly beneath the header, which is exactly
        // where the missing list is, and it scrolls with the hero instead of
        // floating over it. The hero itself is left alone: its title is the
        // caller's and still true, and its Play and Shuffle pills already do
        // nothing on an empty list.
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
                    // Layout.preferredWidth/Height and not width/height: a
                    // Layout owns the size of its direct children, and a plain
                    // width is overwritten - see the hero's own glyph above,
                    // which is anchored and so may use width.
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
                // One long literal and not a concatenation, so lupdate can read
                // it.
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

    // P2. The pin carries the labels and the artwork the page is showing, so
    // the sidebar row reads the same as the page it came from.
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
