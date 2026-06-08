import QtQuick
import QtQuick.Controls
import TidalWave

Menu {
    id: root
    property var trackData: null

    background: Rectangle {
        implicitWidth: 200
        color: "#1E1E1E"
        border.color: Theme.border
        radius: Theme.radius
    }

    function show(x, y, track) {
        trackData = track
        popup(x, y)
    }

    MenuItem {
        text: "Play"
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuItem {
        text: "Add to queue"
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuSeparator { contentItem: Rectangle { height: 1; color: Theme.border } }
    MenuItem {
        text: "Like"
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuItem {
        text: "Go to album"
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
    MenuItem {
        text: "Go to artist"
        contentItem: Text { text: parent.text; color: Theme.textPrimary; leftPadding: 16; font.pixelSize: 14 }
        background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
    }
}
