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

    // Cards are a FIXED size and the row simply clips. Deriving the size from
    // the row width so it always ended on a deliberate sliver meant every
    // card in every row resized continuously while the window was dragged,
    // which is far noisier than a clean cut: the thing you are looking at
    // should hold still while you resize the thing around it.
    //
    // What a row ends on is now whatever falls there. That costs the old
    // "there is more to the right" cue, so the scrollbar is no longer hidden
    // until hover when the row actually overflows; it is the honest signal and
    // it does not move the artwork to deliver it.
    readonly property int  cardSize: 160
    readonly property int  listSpacing: 16
    readonly property int  edgeInset: 24      // the leading inset, as list header/footer

    readonly property real rowSpace: Math.max(0, width - edgeInset)
    // Only for callers that want to know whether the row overflows at all.
    readonly property bool overflows: items.length * (cardSize + listSpacing) > rowSpace

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

            // The arrow used to live inside the translatable string. It is
            // drawn beside it now: it is the only thing marking this grey
            // line as a control rather than a caption, so it stays, but as
            // part of the icon set rather than as a character the font may
            // not have.
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

                readonly property color ink: viewAll.activeFocus ? Theme.accent : Theme.textSec

                Row {
                    id: viewAllRow
                    anchors.fill: parent
                    spacing: 4
                    Text {
                        id: viewAllText
                        objectName: "viewAllLabel"
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("View all")
                        color: viewAll.ink
                        font.pixelSize: 12
                        font.underline: viewAll.activeFocus
                    }
                    VectorIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-right"
                        color: viewAll.ink
                        width: 11; height: 11
                        strokeWidth: 2
                    }
                }
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
                    // Shown when the row overflows, because the cards no
                    // longer resize to leave a sliver of the next one and
                    // that sliver was the only cue that the row scrolled.
                    policy: root.overflows ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
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

    // Nothing sits over the whole section. A hoverEnabled MouseArea used to,
    // left over from when the scrollbar was only shown while the row was
    // hovered; the scrollbar follows `overflows` now and nothing read it. As
    // the section's last child it was in front of every card, and hover
    // delivery stops at the first item that takes it, so it swallowed the
    // cards' own hover: no wash, no play button and the arrow cursor where the
    // pointing hand belongs. See tst_layout_pages.
}
