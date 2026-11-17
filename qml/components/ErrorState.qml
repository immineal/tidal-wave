import QtQuick
import QtQuick.Layouts
import TidalWave

// What a page says when it has nothing to show and a reason for it. Two
// cases: Tidal could not be reached (the page loads again by itself once it
// can), or Tidal answered and would not serve the item (the page's own words).
// Try again in both. Extra actions, such as Find album, go in as children.
ColumnLayout {
    id: root

    // objectNames for the tests: <prefix>Text, <prefix>Detail, <prefix>Retry.
    property string namePrefix: ""
    property string icon: ""
    // The words for an item Tidal refused.
    property string title: ""
    property string detail: ""
    // The failure came with Tidal out of reach.
    property bool offline: false

    signal retry()

    default property alias actions: actionRow.data

    spacing: Theme.space3

    VectorIcon {
        Layout.alignment: Qt.AlignHCenter
        // A Layout owns the size of its direct children.
        Layout.preferredWidth: 40
        Layout.preferredHeight: 40
        name: root.offline ? "info" : root.icon
        color: Theme.textDim
    }

    Text {
        objectName: root.namePrefix + "Text"
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: root.offline ? qsTr("Tidal cannot be reached") : root.title
        color: Theme.textPrimary
        font.pixelSize: Theme.fontSection
        font.bold: true
        wrapMode: Text.WordWrap
    }

    // Never the server's own string, which is a Qt network error with the
    // request URL in it.
    Text {
        objectName: root.namePrefix + "Detail"
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: root.offline
              ? qsTr("Check the connection. The page loads by itself once Tidal answers again.")
              : root.detail
        color: Theme.textSec
        font.pixelSize: Theme.fontMeta
        wrapMode: Text.WordWrap
    }

    RowLayout {
        id: actionRow
        objectName: root.namePrefix + "Actions"
        Layout.alignment: Qt.AlignHCenter
        Layout.topMargin: Theme.space2
        spacing: Theme.space3

        PillButton {
            objectName: root.namePrefix + "Retry"
            text: qsTr("Try again")
            accent: false
            onClicked: root.retry()
        }
    }
}
