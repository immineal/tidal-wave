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
    property string placeholder: qsTr("Collection…", "placeholder of the field that filters the collection")

    readonly property bool focused: input.activeFocus

    // Fixed rather than derived from the children: the children fill this item,
    // so measuring them to size it would be a loop.
    readonly property int fieldHeight: 40
    readonly property int chipRowHeight: 32

    // ── how five icon chips are made to fit any sidebar ──────────────────
    // SideBar gives this block a 12px margin each side. Five 32px targets
    //     3 + 5*32 + 3 = 166px of block, a 190px sidebar,
    // which is why Prefs::minSidebarWidth is 190. The pill drawn is smaller.
    readonly property int chipSpacing: 0
    readonly property int chipInset: 3
    readonly property int chipHeight: 32
    readonly property int chipWidth: 32

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

    // The chip the strip's one tab stop is on.
    property int currentChip: 0
    function focusChip(i) {
        var c = chipRepeater.itemAt(Math.max(0, Math.min(chipRepeater.count - 1, i)))
        if (c) c.forceActiveFocus(Qt.TabFocusReason)
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
                anchors.leftMargin: Theme.space3
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                color: root.focused ? Theme.accentText : Theme.textDim
                width: 16
                height: 16
            }

            TextInput {
                id: input
                objectName: "finderInput"
                anchors.left: glass.right
                anchors.leftMargin: Theme.space2
                anchors.right: clearBtn.left
                anchors.rightMargin: -Theme.space1
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                color: Theme.textPrimary
                font.pixelSize: Theme.fontBody
                clip: true
                selectByMouse: true
                selectionColor: Theme.textSelection
                selectedTextColor: Theme.textSelectionInk
                verticalAlignment: TextInput.AlignVCenter
                // Claimed ahead of the window's Escape shortcut, which would
                // otherwise take it and go back.
                Keys.onShortcutOverride: (event) => {
                    if (event.key === Qt.Key_Escape) event.accepted = true
                }
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
                font.pixelSize: Theme.fontBody
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }

            Item {
                id: clearBtn
                objectName: "finderClear"
                // A 32px target; the 13px cross sits where it always did.
                anchors.right: parent.right
                anchors.rightMargin: 0
                anchors.verticalCenter: parent.verticalCenter
                width: 32
                height: 32
                visible: input.text.length > 0
                activeFocusOnTab: visible
                Keys.onReturnPressed: input.text = ""
                Keys.onSpacePressed:  input.text = ""
                Accessible.role: Accessible.Button
                Accessible.name: qsTranslate("SearchBar", "Clear search", "button, empties the search field")
                Accessible.onPressAction: input.text = ""
                Rectangle {
                    anchors.centerIn: parent; width: 22; height: 22
                    radius: Theme.radiusButton; color: "transparent"
                    border.width: clearBtn.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.centerIn: parent
                    width: 13; height: 13
                    name: "x"
                    color: clearHov.hovered ? Theme.textPrimary : Theme.textDim
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
                    id: chipRepeater
                    model: [
                        { kind: "track",    glyph: "track",    label: qsTr("Tracks") },
                        { kind: "album",    glyph: "album",    label: qsTr("Albums") },
                        { kind: "artist",   glyph: "artist",   label: qsTr("Artists") },
                        { kind: "playlist", glyph: "playlist", label: qsTr("Playlists") },
                        { kind: "mix",      glyph: "mix",      label: qsTr("Mixes") }
                    ]

                    delegate: Item {
                        id: chip
                        objectName: "finderChip"
                        required property var modelData
                        readonly property string kind: modelData.kind
                        readonly property string label: modelData.label
                        readonly property bool selected: root.kinds.indexOf(kind) >= 0

                        required property int index
                        width: root.chipWidth
                        height: root.chipHeight

                        // On is a solid fill and focus a ring outside it, so
                        // the two never read as the same thing.
                        Rectangle {
                            objectName: "finderChipFill"
                            anchors.centerIn: parent
                            width: root.chipWidth - 6; height: 22
                            radius: Theme.radiusChip
                            color: chip.selected ? Theme.accent
                                                 : chipHov.hovered ? Theme.hoverFill : "transparent"
                        }
                        Rectangle {
                            objectName: "finderChipRing"
                            anchors.centerIn: parent
                            width: root.chipWidth; height: 28
                            radius: Theme.radiusChip
                            color: "transparent"
                            border.width: chip.activeFocus ? 2 : 0
                            border.color: Theme.accent
                        }

                        // The strip is one tab stop, as a toolbar is: Left and
                        // Right move along it.
                        activeFocusOnTab: activeFocus || root.currentChip === chip.index
                        onActiveFocusChanged: if (activeFocus) root.currentChip = chip.index
                        Keys.onReturnPressed: root.toggleKind(chip.kind)
                        Keys.onSpacePressed:  root.toggleKind(chip.kind)
                        Keys.onLeftPressed:   root.focusChip(chip.index - 1)
                        Keys.onRightPressed:  root.focusChip(chip.index + 1)
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Home) root.focusChip(0)
                            else if (event.key === Qt.Key_End) root.focusChip(chipRepeater.count - 1)
                            else return
                            event.accepted = true
                        }
                        Accessible.role: Accessible.Button
                        Accessible.name: chip.label
                        Accessible.checkable: true
                        Accessible.checked: chip.selected
                        Accessible.onPressAction: root.toggleKind(chip.kind)
                        Accessible.onToggleAction: root.toggleKind(chip.kind)

                        VectorIcon {
                            objectName: "finderChipIcon"
                            anchors.centerIn: parent
                            name: chip.modelData.glyph
                            width: 15
                            height: 15
                            color: chip.selected ? Theme.accentInk
                                                 : chipHov.hovered ? Theme.textPrimary : Theme.textDim
                        }

                        HoverHandler { id: chipHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.toggleKind(chip.kind) }

                        // On focus too: the icon is all a keyboard user sees.
                        ToolTip.visible: chipHov.hovered || chip.activeFocus
                        ToolTip.text: chip.label
                        ToolTip.delay: Theme.tooltipDelay
                    }
                }
            }
        }
    }
}
