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

    // The artwork tile. `artCovers` is a 2x2 collage for when there is no
    // cover of its own; `artIcon` is drawn while there is neither.
    property bool   showArt: true
    property string artSource: ""
    property var    artCovers: []
    property string artIcon: ""
    readonly property int artSize: 200

    // A photo behind the whole hero, as on an artist or an album.
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

    // accentTint, not artScrimStrong: the hero is a tint over the page, and
    // the black scrim composites to a low-contrast grey on the light themes.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0; color: Theme.accentTint }
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
                visible: hero.artSource.length > 0
                source: hero.artSource.length > 0 ? "image://tidal/" + hero.artSource : ""
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
                visible: hero.artSource.length === 0 && hero.artCovers.length >= 4
                Repeater {
                    model: collage.visible ? hero.artCovers.slice(0, 4) : []
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
                font.letterSpacing: 1
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
