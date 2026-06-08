import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import TidalWave

Item {
    id: root
    height: col.height
    width: parent ? parent.width : 0

    property string  title: ""
    property string  subtitle: ""
    property var     items: []         // [{coverUrl, title, subtitle, id, type}]
    property int     cardSize: 160
    property string  mediaType: "album"

    signal itemClicked(int index, var item)
    signal itemPlayClicked(int index, var item)
    signal viewAllClicked()

    ColumnLayout {
        id: col
        width: parent.width
        spacing: 12

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 24
            Layout.rightMargin: 24
            spacing: 0

            ColumnLayout {
                spacing: 2
                Text {
                    text: root.title
                    color: Theme.textPrimary
                    font.pixelSize: 20
                    font.bold: true
                }
                Text {
                    visible: root.subtitle.length > 0
                    text: root.subtitle
                    color: Theme.textSec
                    font.pixelSize: 13
                }
            }
            Item { Layout.fillWidth: true }

            Text {
                text: "View all →"
                color: Theme.textSec
                font.pixelSize: 12
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.viewAllClicked()
                }
            }
        }

        // Horizontal scroll list
        Item {
            Layout.fillWidth: true
            height: cardSize + 64 + (hbar.visible ? 8 : 0)

            ListView {
                id: hlist
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: cardSize + 64
                orientation: ListView.Horizontal
                clip: true
                spacing: 16
                leftMargin: 24
                rightMargin: 24
                model: root.items
                interactive: false  // let parent page handle wheel; users drag the scrollbar

                ScrollBar.horizontal: ScrollBar {
                    id: hbar
                    policy: (hlist.contentWidth > hlist.width && sectionHover.containsMouse)
                            ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    minimumSize: 0.05
                }

                delegate: MediaCard {
                    required property var modelData
                    required property int index
                    coverUrl:  modelData.coverUrl  || ""
                    title:     modelData.title     || ""
                    subtitle:  modelData.subtitle  || ""
                    mediaType: root.mediaType
                    cardSize:  root.cardSize
                    onClicked:      root.itemClicked(index, modelData)
                    onPlayClicked:  root.itemPlayClicked(index, modelData)
                }
            }

            // Shift+wheel or native horizontal trackpad two-finger swipe
            WheelHandler {
                onWheel: (event) => {
                    var hDelta = event.angleDelta.x
                    var vDelta = event.angleDelta.y
                    var hasShift = (event.modifiers & Qt.ShiftModifier) !== 0
                    var effectiveDelta = (Math.abs(hDelta) > Math.abs(vDelta))
                        ? hDelta
                        : (hasShift ? vDelta : 0)

                    if (effectiveDelta !== 0) {
                        var maxX = Math.max(0, hlist.contentWidth - hlist.width)
                        var newX = Math.max(0, Math.min(maxX, hlist.contentX - effectiveDelta * 0.8))
                        if (newX !== hlist.contentX) {
                            hlist.contentX = newX
                            event.accepted = true
                        } else {
                            event.accepted = false
                        }
                    } else if (vDelta !== 0) {
                        var p = root.parent
                        var scrollParent = null
                        while (p) {
                            if (p.contentY !== undefined && p.contentHeight !== undefined && p.flickableDirection !== undefined) {
                                scrollParent = p
                                break
                            }
                            p = p.parent
                        }
                        if (scrollParent) {
                            var maxY = Math.max(0, scrollParent.contentHeight - scrollParent.height)
                            scrollParent.contentY = Math.max(0, Math.min(maxY, scrollParent.contentY - vDelta))
                            event.accepted = true
                        } else {
                            event.accepted = false
                        }
                    }
                }
            }
        }
    }

    // Track hover over entire section for scrollbar visibility
    MouseArea {
        id: sectionHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }
}
