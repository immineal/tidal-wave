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

    width: cardSize
    height: col.height + 8

    signal clicked()
    signal playClicked()

    ColumnLayout {
        id: col
        width: parent.width
        spacing: 8

        Rectangle {
            id: imgRect
            Layout.fillWidth: true
            height: cardSize
            radius: mediaType === "artist" ? cardSize/2 : Theme.radiusLg
            color: Theme.surfaceHigh
            clip: true

            Image {
                id: img
                anchors.fill: parent
                source: coverUrl.length > 0 ? "image://tidal/" + coverUrl : ""
                fillMode: Image.PreserveAspectCrop
                smooth: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            VectorIcon {
                visible: img.status !== Image.Ready
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
                color: Qt.rgba(0, 0, 0, hov.hovered ? 0.45 : 0)
                Behavior on color { ColorAnimation { duration: 150 } }

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
                        color: "white"
                        font.pixelSize: 16
                        leftPadding: 2
                    }

                    scale: playHov.hovered ? 1.05 : 1
                    Behavior on scale { NumberAnimation { duration: 100 } }
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
}
