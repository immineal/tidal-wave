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

    // Cards are a fixed size and the row clips. A size derived from the row
    // width resizes every card continuously while the window is dragged.
    readonly property int  cardSize: 160
    readonly property int  listSpacing: 16
    readonly property int  edgeInset: 24      // the leading inset, as list header/footer

    readonly property real rowSpace: Math.max(0, width - edgeInset)
    // Only for callers that want to know whether the row overflows at all.
    readonly property bool overflows: items.length * (cardSize + listSpacing) > rowSpace
    // The whole cards between the two insets: what an arrow pages by.
    readonly property int  visibleCards:
        Math.max(1, Math.floor((width - 2 * edgeInset + listSpacing) / (cardSize + listSpacing)))

    // The row's travel, from the first card to the last page.
    readonly property real minX: hlist.originX
    readonly property real maxX: Math.max(minX, hlist.originX + hlist.contentWidth - hlist.width)

    function scrollTo(x) {
        rowMove.stop()
        hlist.contentX = Math.max(minX, Math.min(maxX, x))
    }
    // One page of whole cards, animated, landing on a card's edge.
    function page(dir) {
        var step = visibleCards * (cardSize + listSpacing)
        var from = hlist.contentX - minX
        var to = dir > 0 ? (Math.floor(from / step + 0.01) + 1) * step
                         : (Math.ceil(from / step - 0.01) - 1) * step
        rowMove.to = Math.max(minX, Math.min(maxX, minX + to))
        rowMove.restart()
    }

    signal itemClicked(int index, var item)
    signal itemPlayClicked(int index, var item)
    signal viewAllClicked()

    ColumnLayout {
        id: col
        width: parent.width
        spacing: Theme.space3

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space6
            Layout.rightMargin: Theme.space6
            spacing: 0

            ColumnLayout {
                spacing: Theme.spaceHalf
                Text {
                    text: root.title
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSection
                    font.bold: true
                }
                Text {
                    visible: root.subtitle.length > 0
                    text: root.subtitle
                    color: Theme.textSec
                    font.pixelSize: Theme.fontMeta
                }
            }
            Item { Layout.fillWidth: true }

            // Paging arrows, only on a row with more than fits. Held in a box
            // of the label's height so the header keeps its own.
            Item {
                visible: root.overflows
                implicitWidth: arrows.implicitWidth
                implicitHeight: viewAll.implicitHeight
                Layout.rightMargin: root.showViewAll ? Theme.space3 : 0
                Row {
                    id: arrows
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space1
                    IconButton {
                        objectName: "sectionScrollBack"
                        icon: "chevron-left"; size: 16
                        label: qsTr("Scroll back", "arrow on a row of cards")
                        enabled: hlist.contentX > root.minX + 0.5
                        opacity: enabled ? 1 : 0.35
                        onClicked: root.page(-1)
                    }
                    IconButton {
                        objectName: "sectionScrollForward"
                        icon: "chevron-right"; size: 16
                        label: qsTr("Scroll forward", "arrow on a row of cards")
                        enabled: hlist.contentX < root.maxX - 0.5
                        opacity: enabled ? 1 : 0.35
                        onClicked: root.page(1)
                    }
                }
            }

            // The arrow is drawn beside the label, out of the icon set. It is
            // the only thing marking this grey line as a control.
            Item {
                id: viewAll
                visible: root.showViewAll
                // A Row positions every child it has, so the hit area cannot
                // be one of them; it is a sibling over this wrapper instead.
                implicitWidth:  viewAllRow.implicitWidth
                implicitHeight: viewAllRow.implicitHeight
                activeFocusOnTab: root.showViewAll
                Keys.onReturnPressed: root.viewAllClicked()
                Keys.onSpacePressed:  root.viewAllClicked()
                Accessible.role: Accessible.Link
                Accessible.name: qsTr("Show all: %1", "link to the full list of a section").arg(root.title)
                Accessible.onPressAction: root.viewAllClicked()

                readonly property color ink: viewAll.activeFocus ? Theme.accentText : Theme.textSec

                Row {
                    id: viewAllRow
                    anchors.fill: parent
                    spacing: Theme.space1
                    Text {
                        id: viewAllText
                        objectName: "viewAllLabel"
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Show all")
                        color: viewAll.ink
                        font.pixelSize: Theme.fontMeta
                        font.underline: viewAll.activeFocus
                    }
                    VectorIcon {
                        objectName: "viewAllChevron"
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-right"
                        color: viewAll.ink
                        width: 11; height: 11
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Theme.space1
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.viewAllClicked()
                }
            }
        }

        // Horizontal scroll list
        Item {
            Layout.fillWidth: true
            height: cardSize + 64 + (hbar.visible ? 8 : 0)

            // A sideways drag moves the row, taking the grab from a card past
            // the threshold so it never opens one. Its own item under the
            // list and short of the scroll bar, which keeps its own drag.
            Item {
                anchors { left: hlist.left; right: hlist.right; top: hlist.top }
                height: hlist.height - (hbar.visible ? hbar.height : 0)
                DragHandler {
                    target: null
                    yAxis.enabled: false
                    property real startX: 0
                    onActiveChanged: if (active) { rowMove.stop(); startX = hlist.contentX }
                    onTranslationChanged: if (active) root.scrollTo(startX - translation.x)
                }
            }

            ListView {
                id: hlist
                objectName: "sectionList"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: cardSize + 64
                orientation: ListView.Horizontal
                clip: true
                spacing: root.listSpacing
                // The inset is content (header/footer), not a margin. With
                // leftMargin the rest position is contentX = -leftMargin, which
                // the wheel handler (clamped to >= 0) cannot reach.
                header: Item { width: root.edgeInset; height: 1 }
                footer: Item { width: root.edgeInset; height: 1 }
                model: root.items
                // Not a Flickable gesture: a vertical wheel over the row must
                // reach the page. The handlers below drag and wheel the row.
                interactive: false
                // Not tied to `interactive`: the row is one tab stop and
                // Left/Right walk its cards.
                keyNavigationEnabled: true

                ScrollBar.horizontal: ScrollBar {
                    id: hbar
                    // Shown whenever the row overflows: it is the only cue that
                    // the row scrolls.
                    policy: root.overflows ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                    minimumSize: 0.05
                }

                delegate: MediaCard {
                    required property var modelData
                    required property int index
                    coverUrl:  modelData.coverUrl  || ""
                    title:     modelData.title     || ""
                    subtitle:  modelData.subtitle  || ""
                    storedSubtitle: modelData.pinSubtitle
                    mediaType: root.mediaType
                    // What a right-click pins. Playlists are keyed by uuid,
                    // everything else by id.
                    itemId:    "" + (modelData.uuid || modelData.id || "")
                    cardSize:  root.cardSize
                    tabStop: ListView.isCurrentItem || hlist.currentIndex < 0
                    // A card the keyboard reaches is scrolled into view; the
                    // row does not follow its current item by itself here.
                    onKeyboardOnChanged: if (keyboardOn) { rowMove.stop(); hlist.positionViewAtIndex(index, ListView.Contain) }
                    onClicked:      root.itemClicked(index, modelData)
                    onPlayClicked:  root.itemPlayClicked(index, modelData)
                }
            }

            NumberAnimation {
                id: rowMove
                target: hlist; property: "contentX"
                duration: Theme.dur(Theme.motionMedium); easing.type: Easing.OutCubic
            }

            // A horizontal wheel or swipe and Shift+wheel move the row; a plain
            // vertical wheel scrolls the page. Two handlers, because one
            // WheelHandler only hears the wheel of its own orientation.
            WheelHandler {
                orientation: Qt.Horizontal
                onWheel: (event) => root.wheel(event)
            }
            WheelHandler {
                orientation: Qt.Vertical
                onWheel: (event) => root.wheel(event)
            }
        }
    }

    function wheel(event) {
        var hDelta = event.pixelDelta.x !== 0 ? event.pixelDelta.x : event.angleDelta.x
        var vDelta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y
        var hasShift = (event.modifiers & Qt.ShiftModifier) !== 0
        var sideways = Math.abs(hDelta) > Math.abs(vDelta) ? hDelta : (hasShift ? vDelta : 0)
        if (sideways !== 0) {
            var before = hlist.contentX
            root.scrollTo(hlist.contentX - sideways)
            event.accepted = hlist.contentX !== before
            return
        }
        if (vDelta === 0) { event.accepted = false; return }
        var p = root.parent
        while (p && !(p.contentY !== undefined && p.contentHeight !== undefined
                      && p.flickableDirection !== undefined))
            p = p.parent
        if (!p) { event.accepted = false; return }
        // From originY: a ListView with a header starts above 0.
        var minY = p.originY
        var maxY = minY + Math.max(0, p.contentHeight - p.height)
        p.contentY = Math.max(minY, Math.min(maxY, p.contentY - vDelta))
        event.accepted = true
    }

    // Nothing sits over the whole section. A hoverEnabled MouseArea here would
    // be in front of every card and swallow the cards' own hover. See
    // tst_layout_pages.
}
