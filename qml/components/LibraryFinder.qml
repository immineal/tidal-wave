import QtQuick
import QtQuick.Controls
import TidalWave

// The sidebar's finder: the search field with the type filter chips drawn
// inside its rounded container as one unit. The chips are icons only, at
// every width; their names are in the tooltips.
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
    // SideBar gives this block a 12px margin each side. Five chips need
    //     4 + 5*30 + 4*2 + 4 = 166px of block, a 190px sidebar,
    // which is why Prefs::minSidebarWidth is 190.
    readonly property int chipSpacing: 2
    readonly property int chipInset: 4
    readonly property int chipHeight: 24
    readonly property int chipWidth: 30

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

    // Back to no filter at all. Guarded on both halves: `kinds = []` on an
    // empty list is still a new array and still emits, and the sidebar would
    // rebuild its model in the middle of a slide.
    function reset() {
        if (input.text.length > 0) input.text = ""
        if (kinds.length > 0)      kinds = []
        releaseFocus()
    }

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
                // Left-aligned. The inset puts the first chip's icon on the
                // same vertical as the magnifier above it, and the matching
                // inset on the right is in the width budget at the top.
                anchors.left: parent.left
                anchors.leftMargin: root.chipInset
                anchors.right: parent.right
                anchors.rightMargin: root.chipInset
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.chipSpacing

                Repeater {
                    model: [
                        { kind: "track",    glyph: "track",    label: qsTr("Tracks") },
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
