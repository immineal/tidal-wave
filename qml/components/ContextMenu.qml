import QtQuick
import QtQuick.Controls
import TidalWave

Menu {
    id: root
    property var trackData: null

    background: Rectangle {
        implicitWidth: 200
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusPopup
    }

    function show(x, y, track) {
        trackData = track
        popup(x, y)
    }

    MenuItem {
        text: qsTr("Play", "verb, menu item")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuItem {
        text: qsTr("Add to queue")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuSeparator { contentItem: Rectangle { height: 1; color: Theme.border } }
    MenuItem {
        text: qsTr("Like", "verb, add to favourites")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuItem {
        text: qsTr("Go to album")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuItem {
        text: qsTr("Go to artist")
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
}
