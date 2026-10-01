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
                // centred strip floats in the middle of nowhere, and 4px puts
                // the first chip's icon on the same vertical as the magnifier
                // above it.
                anchors.left: parent.left
                anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

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

                        width: 30
                        height: 24
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
