import QtQuick
import QtQuick.Layouts
import TidalWave

// The bar over every detail page: the back button always, and the page's
// title fading in once the hero has scrolled out. Children go under the
// title, for a line such as an album's artists.
Rectangle {
    id: bar

    // What scrolls under the bar, and how tall its hero is.
    property Flickable flickable: null
    property real heroHeight: 280
    property string title: ""
    property string backObjectName: "detailBack"
    default property alias details: detailColumn.data

    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 52
    z: 10

    // 0 while the hero is still on screen, 1 from where the first row reaches
    // the bar. A ListView counts from originY, which is minus its header.
    readonly property real reveal: {
        if (!flickable) return 0
        var scrolled = flickable.contentY - flickable.originY
        var fade = Theme.space16 + Theme.space4
        return Math.min(1, Math.max(0, (scrolled - (heroHeight - height - fade)) / fade))
    }
    // Opaque once revealed: rows scrolling under a see-through bar read as
    // text printed over the title.
    color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, reveal)

    BackButton {
        objectName: bar.backObjectName
        anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: Theme.space2 }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space16
        anchors.rightMargin: Theme.space4
        opacity: bar.reveal
        // Faded out is still there, so nothing in it takes a click or a tab.
        enabled: bar.reveal > 0
        ColumnLayout {
            id: detailColumn
            Layout.fillWidth: true
            spacing: Theme.spaceHalf
            Text {
                objectName: "detailBarTitle"
                Layout.fillWidth: true
                text: bar.title
                color: Theme.textPrimary
                font.pixelSize: Theme.fontBody
                font.bold: true
                elide: Text.ElideRight
            }
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border
        opacity: bar.reveal
    }
}
