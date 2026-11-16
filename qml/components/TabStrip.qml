import QtQuick
import TidalWave

// The one tab strip, used by Search and My Collection. The highlight is one
// accent pill that travels between the chips, drawn as a slice inside each
// chip because a Flow lays out anything added to it. Each label is drawn
// twice, each copy clipped to its own fill, so no glyph sits on the wrong one.
Flow {
    id: strip

    // The tab names, and the text each chip shows (a name with a count, say).
    property var model: []
    property var labelFor: function (index, name) { return name }
    property int currentIndex: 0
    // Object names come out as <prefix>TabsRow, <prefix>TabLabel and so on,
    // which is how the suites tell the two strips apart.
    property string namePrefix: "tab"
    // Off while the strip is out of sight, so a change there does not travel
    // when it comes back.
    property bool animate: true
    signal activated(int index)

    readonly property int chipHeight: 32

    objectName: namePrefix + "TabsRow"
    spacing: Theme.space1

    // Only `markT` is animated: the geometry is read live off the two chips,
    // whose widths change with every count.
    property Item markFrom: null
    property Item markTo:   null
    property real markT:    1
    // The reset to 0 that starts a travel must not animate, or the pill would
    // run backwards to the chip it is already on before setting off.
    property bool markResetting: false
    // The first placement is an initialisation, not a move. Without the gate
    // the pill would grow out of the row's left edge on every visit.
    property bool markSettled: false

    Behavior on markT {
        enabled: !strip.markResetting
        NumberAnimation { duration: Theme.dur(Theme.motionMedium); easing.type: Easing.OutCubic }
    }

    // The end it set off from, or the destination itself when there is none,
    // which makes the lerp degenerate: the first placement, a model rebuild.
    readonly property Item markA: markFrom ? markFrom : markTo
    readonly property real markX: markTo ? markA.x + (markTo.x - markA.x) * markT : 0
    readonly property real markY: markTo ? markA.y + (markTo.y - markA.y) * markT : 0
    readonly property real markW: markTo ? markA.width  + (markTo.width  - markA.width)  * markT : 0
    readonly property real markH: markTo ? markA.height + (markTo.height - markA.height) * markT : 0

    function retarget(travel) {
        var next = chips.itemAt(strip.currentIndex)
        if (next === null || next === strip.markTo) return
        strip.markFrom = (travel && strip.markTo !== null) ? strip.markTo : next
        strip.markTo   = next
        strip.markResetting = true
        strip.markT = 0
        strip.markResetting = false
        strip.markT = 1
    }

    onCurrentIndexChanged: retarget(markSettled && animate)

    Component.onCompleted: {
        retarget(false)
        Qt.callLater(function () { strip.markSettled = true })
    }

    Repeater {
        id: chips
        model: strip.model
        // itemAt() is a function call and not a dependency, so the pill is
        // aimed again as the chips arrive. A language change rebuilds them.
        onItemAdded: function (index, item) { strip.retarget(false) }

        Rectangle {
            id: chip
            required property var modelData
            required property int index
            readonly property bool current: strip.currentIndex === index

            height: strip.chipHeight
            width: label.implicitWidth + Theme.space6
            radius: Theme.radiusFull
            // Every chip rests on the same surface. The current one takes no
            // hover: the pill already marks it.
            color: hov.hovered && !chip.current
                   ? Qt.tint(Theme.surfaceHigh, Theme.hoverFill) : Theme.surfaceHigh
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.motionFast) } }
            border.width: chip.activeFocus ? 2 : 0
            border.color: Theme.accent

            activeFocusOnTab: true
            Keys.onReturnPressed: strip.activated(index)
            Keys.onSpacePressed:  strip.activated(index)
            Accessible.role: Accessible.PageTab
            Accessible.name: label.text
            Accessible.selected: chip.current
            Accessible.onPressAction: strip.activated(index)

            // Whether the accent's copy of the label covers every pixel the
            // chip's own copy occupies.
            readonly property bool labelFullyInked:
                   inkWindow.visible
                && inkWindow.x <= label.x
                && inkWindow.x + inkWindow.width  >= label.x + label.width
                && inkWindow.y <= label.y
                && inkWindow.y + inkWindow.height >= label.y + label.height

            // This chip's slice of the pill. The clip reaches 2px past the
            // chip, half the row's gap, so the slices meet.
            Item {
                anchors.fill: parent
                anchors.margins: -Theme.spaceHalf
                clip: true
                Rectangle {
                    objectName: strip.namePrefix + "TabPillSlice"
                    x: strip.markX - chip.x + Theme.spaceHalf
                    y: strip.markY - chip.y + Theme.spaceHalf
                    width:  strip.markW
                    height: strip.markH
                    radius: Theme.radiusFull
                    color: Theme.accent
                }
            }

            Text {
                id: label
                objectName: strip.namePrefix + "TabLabel"
                anchors.centerIn: parent
                text: strip.labelFor(chip.index, chip.modelData)
                // Always the resting ink. The accent's ink is the copy below.
                color: Theme.textSec
                // Hidden where the copy covers all of it: two Texts in one
                // place blend at the glyphs' antialiased edge.
                visible: !chip.labelFullyInked
                font.pixelSize: Theme.fontBody
            }

            // The label again in the accent's ink, clipped to the pill. The
            // two inks cannot cross-fade legibly.
            Item {
                id: inkWindow
                objectName: strip.namePrefix + "TabInk"
                // The pill in this chip's coordinates, clamped on both axes
                // since the row wraps. Not `top`/`bottom`: Item has those.
                readonly property real coveredLeft:   Math.max(0, strip.markX - chip.x)
                readonly property real coveredRight:  Math.min(chip.width, strip.markX + strip.markW - chip.x)
                readonly property real coveredTop:    Math.max(0, strip.markY - chip.y)
                readonly property real coveredBottom: Math.min(chip.height, strip.markY + strip.markH - chip.y)
                x: coveredLeft
                y: coveredTop
                width:  Math.max(0, coveredRight - coveredLeft)
                height: Math.max(0, coveredBottom - coveredTop)
                clip: true
                visible: width > 0 && height > 0
                Text {
                    objectName: strip.namePrefix + "TabInkLabel"
                    x: label.x - inkWindow.x
                    y: label.y - inkWindow.y
                    text: label.text
                    font: label.font
                    color: Theme.accentInk
                }
            }

            HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
            TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: strip.activated(chip.index)
            }
        }
    }
}
