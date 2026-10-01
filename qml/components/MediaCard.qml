import QtQuick
import QtQuick.Layouts
import TidalWave

Item {
    id: root

    property string coverUrl: ""
    property string title: ""
    property string subtitle: ""
    property string mediaType: "album"
    property int    cardSize: 160

    // What a right-click pins (P2). The tile's own type doubles as the pin
    // kind; without an id there is nothing to pin and no menu is offered.
    property string itemId: ""
    property string pinKind: mediaType
    // An artist tile's subtitle is the word "Artist", a type label rather than
    // data, and a pin outlives the session it was made in, so the stored
    // subtitle would be a translated word frozen at pin time.
    readonly property string pinSubtitle: mediaType === "artist" ? "" : subtitle

    readonly property alias pinMenu: cardMenu

    width: cardSize
    height: col.height + 8

    signal clicked()
    signal playClicked()

    activeFocusOnTab: true
    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed:  root.clicked()

    ColumnLayout {
        id: col
        width: parent.width
        spacing: 8

        Rectangle {
            id: imgRect
            Layout.fillWidth: true
            height: cardSize
            radius: mediaType === "artist" ? cardSize/2 : Theme.radiusCard
            color: Theme.surfaceHigh
            clip: true
            border.width: root.activeFocus ? 4 : 0
            border.color: Theme.accent

            Image {
                id: img
                anchors.fill: parent
                source: coverUrl.length > 0 ? "image://tidal/" + coverUrl : ""
                fillMode: Image.PreserveAspectCrop
                smooth: true
                mipmap: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.dur(200) } }
            }

            VectorIcon {
                visible: root.coverUrl.length === 0 || img.status === Image.Error
                anchors.centerIn: parent
                name: mediaType === "artist" ? "artist" : "music"
                color: Theme.textDim
                width: 48
                height: 48
                strokeWidth: 1.5
            }

            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                // Dims the art so the play button reads; a wash over cover art
                // cannot follow the ground, so it is the same in every theme.
                color: hov.hovered ? Theme.artScrim : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.dur(150) } }

                Rectangle {
                    visible: hov.hovered
                    width: 44
                    height: 44
                    radius: 22
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    anchors.margins: 12
                    color: Theme.accent

                    Text {
                        anchors.centerIn: parent
                        text: "▶"
                        color: Theme.onAccent
                        font.pixelSize: 16
                        leftPadding: 2
                    }

                    scale: playHov.hovered ? 1.05 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.dur(100) } }
                    HoverHandler { id: playHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler   { onTapped: root.playClicked() }
                }
            }

            HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
            TapHandler   { onTapped: root.clicked() }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: root.title
                color: Theme.textPrimary
                font.pixelSize: 14
                font.bold: true
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
            }

            Text {
                Layout.fillWidth: true
                text: root.subtitle
                color: Theme.textSec
                font.pixelSize: 12
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
            }
        }
    }

    // P2. Right button only, so the cover's tap and hover handlers underneath
    // keep every left-click they had.
    MouseArea {
        objectName: "cardMenuArea"
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: function (mouse) {
            var p = mapToItem(root, mouse.x, mouse.y)
            cardMenu.showPin(p.x, p.y, root.pinKind, root.itemId,
                             root.title, root.pinSubtitle, root.coverUrl)
        }
    }

    ContextMenu {
        id: cardMenu
        objectName: "cardPinMenu"
    }
}
