import QtQuick
import QtQuick.Layouts
import TidalWave

// The hero at the top of every detail page: album, playlist, mix, artist and
// radio. The artwork, a kind label over the title, the page's own lines under
// it (the children), and the action row. Right-click asks for the pin menu.
Rectangle {
    id: hero

    property string kind: ""
    property string title: ""
    // Artist names its title for the suites; everything else is heroTitle.
    property string titleObjectName: "heroTitle"
    property int    titleLines: 0

    // The artwork tile. `artCovers` are the tracks' covers, for when there is
    // no cover of its own: four distinct ones make a 2x2 mosaic, fewer make
    // the first one whole. `artIcon` is drawn while there is neither.
    property bool   showArt: true
    property string artSource: ""
    property var    artCovers: []
    property string artIcon: ""
    readonly property int artSize: 200

    readonly property var distinctCovers: {
        var seen = {}, out = []
        for (var i = 0; i < hero.artCovers.length && out.length < 4; i++) {
            var c = hero.artCovers[i]
            if (!c || seen[c]) continue
            seen[c] = true
            out.push(c)
        }
        return out
    }
    readonly property bool   showsMosaic: artSource.length === 0 && distinctCovers.length >= 4
    readonly property string shownCover: artSource.length > 0 ? artSource
                                       : distinctCovers.length > 0 && !showsMosaic ? distinctCovers[0] : ""

    // A photo behind the whole hero, as on an artist page.
    property string backdropSource: ""
    property real   backdropOpacity: 0.18
    property string backdropObjectName: "heroBackdrop"

    default property alias details: detailColumn.data
    property alias actions: heroActions.data
    // Where a confirmation for the actions is drawn: above the row.
    readonly property alias actionRow: heroActions

    signal pinRequested(real x, real y)

    implicitHeight: Math.max(280, heroRow.implicitHeight + Theme.space12)
    color: "transparent"
    clip: true

    Image {
        objectName: hero.backdropObjectName
        anchors.fill: parent
        visible: hero.backdropSource.length > 0
        source: hero.backdropSource.length > 0 ? "image://tidal/" + hero.backdropSource : ""
        fillMode: Image.PreserveAspectCrop
        opacity: hero.backdropOpacity
        smooth: true
        mipmap: true
    }

    // The cover the hero takes its colour from: the tile's, else the
    // mosaic's first, else the backdrop photo's.
    readonly property string tintSource: shownCover.length > 0 ? shownCover
                                       : distinctCovers.length > 0 ? distinctCovers[0]
                                       : backdropSource

    // Held between bg and surfaceHigh in C++, the band every text token is
    // tested against, so the hero's lines stay readable on any cover.
    CoverTint {
        id: coverTint
        objectName: "heroCoverTint"
        active: hero.tintSource.length > 0
        coverId: hero.tintSource
        bg: Theme.bg
        limit: Theme.surfaceHigh
    }

    // The accent wash until the cover's colour is known. Over a backdrop
    // photo the tint keeps the wash's alpha, so the photo still shows.
    property color tintTop: !coverTint.hasColor ? Theme.accentTint
                          : backdropSource.length > 0
                          ? Qt.rgba(coverTint.color.r, coverTint.color.g, coverTint.color.b,
                                    Theme.accentTint.a)
                          : coverTint.color
    Behavior on tintTop { ColorAnimation { duration: Theme.dur(Theme.motionSlow) } }

    // A tint, not artScrimStrong: the black scrim composites to a
    // low-contrast grey on the light themes.
    Rectangle {
        objectName: "heroGradient"
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0; color: hero.tintTop }
            GradientStop { position: 1; color: Theme.bg }
        }
    }

    RowLayout {
        id: heroRow
        anchors {
            left: parent.left; right: parent.right
            verticalCenter: parent.verticalCenter
            leftMargin: Theme.space16; rightMargin: Theme.space6
        }
        spacing: Theme.space6

        Rectangle {
            objectName: "heroArt"
            visible: hero.showArt
            Layout.preferredWidth: hero.artSize
            Layout.preferredHeight: hero.artSize
            Layout.alignment: Qt.AlignVCenter
            radius: Theme.radiusSmall
            color: Theme.accentWash
            clip: true
            Image {
                id: cover
                objectName: "heroCover"
                anchors.fill: parent
                visible: hero.shownCover.length > 0
                source: hero.shownCover.length > 0 ? "image://tidal/" + hero.shownCover : ""
                fillMode: Image.PreserveAspectCrop
                smooth: true
                mipmap: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.motionMedium) } }
            }
            Grid {
                id: collage
                anchors.fill: parent
                columns: 2
                visible: hero.showsMosaic
                Repeater {
                    model: collage.visible ? hero.distinctCovers : []
                    Image {
                        width: hero.artSize / 2
                        height: hero.artSize / 2
                        source: modelData ? "image://tidal/" + modelData : ""
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                    }
                }
            }
            VectorIcon {
                visible: hero.artIcon.length > 0 && cover.status !== Image.Ready && !collage.visible
                anchors.centerIn: parent
                name: hero.artIcon
                color: Theme.accentText
                width: Theme.space16
                height: Theme.space16
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Theme.space2

            Text {
                objectName: "heroKindLabel"
                visible: text.length > 0
                text: hero.kind
                color: Theme.textSec
                font.pixelSize: Theme.fontMicro
                font.bold: true
            }

            Text {
                objectName: hero.titleObjectName
                Layout.fillWidth: true
                text: hero.title
                color: Theme.textPrimary
                font.pixelSize: Theme.fontDisplay
                font.bold: true
                wrapMode: Text.WordWrap
                maximumLineCount: hero.titleLines > 0 ? hero.titleLines : 1000
                elide: hero.titleLines > 0 ? Text.ElideRight : Text.ElideNone
            }

            ColumnLayout {
                id: detailColumn
                Layout.fillWidth: true
                spacing: Theme.space2
                visible: children.length > 0
            }

            // A Flow, so the pills wrap when a pane is narrow or a
            // translation widens them.
            Flow {
                id: heroActions
                objectName: "heroActions"
                Layout.fillWidth: true
                Layout.topMargin: Theme.space1
                spacing: Theme.space3
            }
        }
    }

    // A right-click on the hero pins what the page is showing.
    MouseArea {
        objectName: "heroPinArea"
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: function (mouse) { hero.pinRequested(mouse.x, mouse.y) }
    }
}
