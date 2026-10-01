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
    property string  mediaType: "album"
    property bool    showViewAll: true

    // Card size is derived from the row width so the row always ends on a
    // deliberate sliver of the next card: that sliver is the only thing
    // telling you the row scrolls, since the scrollbar is hidden until hover.
    // A fixed 160 ended wherever it happened to end - sometimes on a whole
    // card, which reads as "that is all there is", sometimes on a 3px edge.
    readonly property int  cardTarget: 160    // the size the cards were drawn at
    readonly property int  cardMin: 128
    readonly property int  cardMax: 200
    readonly property real peek: 0.4          // of a card, left showing at the right edge
    readonly property int  listSpacing: 16
    readonly property int  edgeInset: 24      // the leading inset, as list header/footer

    readonly property real rowSpace: Math.max(0, width - edgeInset)
    // Whole cards that fit once the peek has taken its share
    readonly property int  cardsPerRow: Math.max(1, Math.round(
        (rowSpace - peek * cardTarget) / (cardTarget + listSpacing)))
    // n cards + n gaps + the peek fill the row exactly
    property int cardSize: Math.max(cardMin, Math.min(cardMax, Math.round(
        (rowSpace - listSpacing * cardsPerRow) / (cardsPerRow + peek))))

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
                id: viewAllText
                visible: root.showViewAll
                text: qsTr("View all →")
                color: viewAllText.activeFocus ? Theme.accent : Theme.textSec
                font.pixelSize: 12
                font.underline: viewAllText.activeFocus
                activeFocusOnTab: root.showViewAll
                Keys.onReturnPressed: root.viewAllClicked()
                Keys.onSpacePressed:  root.viewAllClicked()
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
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
                objectName: "sectionList"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: cardSize + 64
                orientation: ListView.Horizontal
                clip: true
                spacing: root.listSpacing
                // Leading/trailing inset as real content (header/footer) rather than
                // leftMargin/rightMargin: with margins the rest position is contentX
                // = -leftMargin, which the wheel handler (clamped to >= 0) can't reach,
                // so the inset was lost after scrolling right and back. As content the
                // inset lives in [0, contentWidth-width] and is always preserved.
                header: Item { width: root.edgeInset; height: 1 }
                footer: Item { width: root.edgeInset; height: 1 }
                model: root.items
                interactive: false  // let parent page handle wheel; users drag the scrollbar

                ScrollBar.horizontal: ScrollBar {
                    id: hbar
                    policy: ScrollBar.AlwaysOff
                    minimumSize: 0.05
                }

                delegate: MediaCard {
                    required property var modelData
                    required property int index
                    coverUrl:  modelData.coverUrl  || ""
                    title:     modelData.title     || ""
                    subtitle:  modelData.subtitle  || ""
                    mediaType: root.mediaType
                    // What a right-click pins (P2). Playlists are keyed by
                    // uuid, everything else by id.
                    itemId:    "" + (modelData.uuid || modelData.id || "")
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
