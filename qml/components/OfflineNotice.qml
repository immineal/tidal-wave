import QtQuick
import QtQuick.Layouts
import TidalWave

// One strip over the page while Tidal cannot be reached. It goes by itself
// with the next answer: the bridge asks again on a growing interval, and
// "Try now" asks at once.
Rectangle {
    id: root
    objectName: "offlineNotice"

    // The `bridge` context property, passed in so a test can hand it a double.
    property var source: null
    readonly property bool shown: !!source && source.offline === true

    visible: shown
    implicitHeight: shown ? row.implicitHeight + 16 : 0
    color: Theme.surfaceHigh

    RowLayout {
        id: row
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 24
        anchors.rightMargin: 16
        spacing: 12

        VectorIcon {
            Layout.preferredWidth: 18
            Layout.preferredHeight: 18
            name: "info"
            color: Theme.textSec
        }

        Text {
            objectName: "offlineNoticeText"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.source && root.source.libraryFromCache
                  ? qsTr("Tidal cannot be reached. Your library is shown as last saved on this computer.")
                  : qsTr("Tidal cannot be reached. Trying again by itself.")
            color: Theme.textPrimary
            font.pixelSize: 13
        }

        PillButton {
            objectName: "offlineNoticeRetry"
            text: qsTr("Try now")
            accent: false
            Layout.preferredWidth: implicitWidth
            Layout.preferredHeight: 30
            onClicked: if (root.source) root.source.retryConnection()
        }
    }
}
