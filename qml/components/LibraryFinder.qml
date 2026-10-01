import QtQuick
import QtQuick.Controls
import TidalWave

// The sidebar's finder: the search field (SPEC S5) with the type filter chips
// (S8) drawn inside it as one unit.
//
// The chips are deliberately *inside* the field's rounded container rather than
// a row of pills underneath it. The labelled variant was tried and the pills
// came out too big and too loose; the names live in the tooltips now and the
// chips are icons only, at every width.
Rectangle {
    id: root

    property alias query: input.text
    // The kinds the chips have switched on, spelled the way LibraryIndex spells
    // them. Empty means no filter, which is also what "every chip off" means.
    property var kinds: []
    property string placeholder: qsTr("Find in library")

    readonly property bool focused: input.activeFocus

    // Fixed rather than derived from the children: the children fill this item,
    // so measuring them to size it would be a loop.
    readonly property int fieldHeight: 36
    readonly property int chipRowHeight: 30

    // ── how five icon chips are made to fit any sidebar ──────────────────
    //
    // Measured, because the number is not obvious. SideBar gives this block a
    // 12px margin on each side, so the block is the sidebar less 24. Inside
    // it the strip keeps `chipInset` left and right and `chipSpacing` between
    // chips, so five full-size chips want
    //     4 + 5*30 + 4*2 + 4 = 166px of block, i.e. a 190px sidebar.
    // Prefs::minSidebarWidth is 180, which leaves 156, and the fifth chip used
    // to run 6px past the right edge and get sliced by the block's clip.
    //
    // Below 190 the chips give back horizontal padding rather than the row
    // giving back a chip. The icon stays 15px at every width and the height
    // never moves, so what shrinks is only the air around the glyph: at the
    // 180px minimum the formula lands on 28px, which still carries 6.5px of
    // padding on each side of the icon.
    readonly property int chipSpacing: 2
    readonly property int chipInset: 4
    readonly property int chipHeight: 24
    readonly property int chipMaxWidth: 30
    // The floor, for a minimum sidebar width this file did not get to see:
    // 15px of icon plus 5.5px of padding each side is the narrowest that still
    // reads as a chip and is still worth aiming a pointer at. The chips are a
    // dense desktop control, so this sits under the 32px touch target on
    // purpose; they were already 30x24 before anything shrank.
    readonly property int chipMinWidth: 26
    readonly property int chipWidth: Math.max(chipMinWidth, Math.min(chipMaxWidth,
        Math.floor((width - 2 * chipInset - 4 * chipSpacing) / 5)))

    implicitHeight: fieldHeight + 1 + chipRowHeight
    implicitWidth: 200
    radius: Theme.radiusField
    color: Theme.surfaceHigh
    border.width: 1
    border.color: focused ? Theme.accent : Theme.border
    // The chip strip runs to the bottom edge, so without this its corners would
    // stick out square past the rounding.
    clip: true

    function releaseFocus() { input.focus = false }

    function toggleKind(kind) {
        var next = kinds.slice()
        var at = next.indexOf(kind)
        if (at >= 0) next.splice(at, 1)
        else         next.push(kind)
        kinds = next
    }

    Column {
        anchors.fill: parent
        spacing: 0

        // ── the field ────────────────────────────────────────────────────
        Item {
            id: fieldRow
            objectName: "finderField"
            width: parent.width
            height: root.fieldHeight

            VectorIcon {
                id: glass
                objectName: "finderSearchIcon"
                anchors.left: parent.left
                anchors.leftMargin: 11
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                color: root.focused ? Theme.accent : Theme.textDim
                width: 15
                height: 15
                strokeWidth: 1.8
            }

            TextInput {
                id: input
                objectName: "finderInput"
                anchors.left: glass.right
                anchors.leftMargin: 8
                anchors.right: clearBtn.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                color: Theme.textPrimary
                font.pixelSize: 13
                clip: true
                selectByMouse: true
                selectionColor: Theme.accent
                selectedTextColor: Theme.accentInk
                verticalAlignment: TextInput.AlignVCenter
                Keys.onEscapePressed: {
                    if (text.length > 0) text = ""
                    else                 root.releaseFocus()
                }
            }

            Text {
                anchors.fill: input
                visible: input.text.length === 0
                text: root.placeholder
                color: Theme.textDim
                font.pixelSize: 13
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }

            Item {
                id: clearBtn
                objectName: "finderClear"
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 13
                height: 13
                visible: input.text.length > 0
                VectorIcon {
                    anchors.fill: parent
                    name: "x"
                    color: clearHov.hovered ? Theme.textPrimary : Theme.textDim
                    strokeWidth: 1.8
                }
                HoverHandler { id: clearHov; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: input.text = "" }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.border
        }

        // ── the chips ────────────────────────────────────────────────────
        Item {
            id: chipStrip
            objectName: "finderChips"
            width: parent.width
            height: root.chipRowHeight

            Row {
                // Left-aligned rather than centred: at 420px of sidebar a
                // centred strip floats in the middle of nowhere, and the inset
                // puts the first chip's icon on the same vertical as the
                // magnifier above it. The matching inset on the right is what
                // the arithmetic at the top of this file budgets for, so the
                // last chip never ends flush against the rounded edge.
                anchors.left: parent.left
                anchors.leftMargin: root.chipInset
                anchors.right: parent.right
                anchors.rightMargin: root.chipInset
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.chipSpacing

                Repeater {
                    model: [
                        { kind: "track",    glyph: "music",    label: qsTr("Tracks") },
                        { kind: "album",    glyph: "album",    label: qsTr("Albums") },
                        { kind: "artist",   glyph: "artist",   label: qsTr("Artists") },
                        { kind: "playlist", glyph: "playlist", label: qsTr("Playlists") },
                        { kind: "mix",      glyph: "mix",      label: qsTr("Mixes") }
                    ]

                    delegate: Rectangle {
                        id: chip
                        objectName: "finderChip"
                        required property var modelData
                        readonly property string kind: modelData.kind
                        readonly property string label: modelData.label
                        readonly property bool selected: root.kinds.indexOf(kind) >= 0

                        width: root.chipWidth
                        height: root.chipHeight
                        radius: Theme.radiusChip
                        color: selected ? Theme.accentSoft
                                        : chipHov.hovered ? Theme.hoverFill : "transparent"

                        activeFocusOnTab: true
                        Keys.onReturnPressed: root.toggleKind(chip.kind)
                        Keys.onSpacePressed:  root.toggleKind(chip.kind)

                        border.width: chip.activeFocus ? 2 : 0
                        border.color: Theme.accent

                        VectorIcon {
                            objectName: "finderChipIcon"
                            anchors.centerIn: parent
                            name: chip.modelData.glyph
                            width: 15
                            height: 15
                            strokeWidth: 1.6
                            color: chip.selected ? Theme.accent
                                                 : chipHov.hovered ? Theme.textPrimary : Theme.textDim
                        }

                        HoverHandler { id: chipHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.toggleKind(chip.kind) }

                        ToolTip.visible: chipHov.hovered
                        ToolTip.text: chip.label
                        ToolTip.delay: 450
                    }
                }
            }
        }
    }
}
