import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import TidalWave

Rectangle {
    id: root
    color: Theme.bg

    property string mixId: ""
    property string title: ""
    property string subtitle: ""
    property string coverUrl: ""
    property var    tracks: []
    property bool   loading: false

    // Records this mix as the "playing from" source, then starts playback.
    function playFrom(list, i) {
        player.setPlaybackSource("mix", root.mixId, root.title)
        player.playTracks(list, i)
    }

    onMixIdChanged: if (mixId.length > 0) loadMix()

    function loadMix() {
        loading = true
        bridge.fetchMixTracks(mixId, function(t, err) {
            loading = false
            if (!err) tracks = t
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
                    width: 180
                    height: 180
                    radius: Theme.radiusArt
                    color: Theme.accentWash
                    clip: true
                    Image {
                        id: mixCover
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
                        name: "music"
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
                        text: qsTr("Mix", "noun, a Tidal mix")
                        color: Theme.textDim
                        font.pixelSize: 12
                        font.bold: true
                        font.letterSpacing: 1
                    }

                    Text {
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
                        Layout.fillWidth: true
                        spacing: 12

                        PillButton {
                            text: qsTr("Play", "verb, button label")
                            glyph: "▶"
                            accent: true
                            onClicked: if (root.tracks.length > 0) root.playFrom(root.tracks, 0)
                        }

                        PillButton {
                            text: qsTr("Shuffle")
                            glyph: "⇌"
                            accent: false
                            onClicked: {
                                if (root.tracks.length > 0) {
                                    player.setShuffle(true)
                                    root.playFrom(root.tracks, Math.floor(Math.random() * root.tracks.length))
                                }
                            }
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

        footer: Item { height: 32; width: tracksList.width }

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
    }
}
