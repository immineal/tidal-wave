import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import TidalWave

// The sidebar, in both of its shapes (SPEC sections 2 and L2-L4).
//
// Wide windows get the full sidebar; below Prefs::railBreakpoint it collapses to
// a 68px rail of icons, and hovering that rail brings the *same* sidebar back as
// an overlay on top of the page, the way compact mode works in Zen Browser and
// Firefox. There is deliberately no manual toggle: window width is the only
// thing that decides.
//
// The overlay is why this item is not the panel it draws. The root is the slot
// the layout gives it — rail-wide while compact — and `panel` inside it is free
// to grow past that slot and cover the page without the layout reflowing and
// shoving the page sideways. Main.qml gives the root `z: 2` so it covers the
// page rather than sliding under it.
Item {
    id: root

    property string currentPage: "home"
    signal navigate(string page, var params)

    // The *window* width decides compact mode. The sidebar's own width is the
    // thing that changes, so measuring itself would be circular. Main.qml binds
    // this; the fallback keeps the component usable on its own.
    property int hostWidth: Window.window ? Window.window.width : root.width

    readonly property bool compact: hostWidth > 0 && hostWidth < prefs.railBreak()
    readonly property int  railWidth: prefs.rail()
    // prefs clamps this too, but a settings file written by another build has
    // to not be able to hand the layout a nonsense width.
    readonly property int  expandedWidth: Math.max(prefs.minSidebar(),
                                          Math.min(prefs.maxSidebar(), prefs.sidebarWidth))

    // Typing keeps the overlay open after the pointer has wandered off it.
    readonly property bool hoverExpanded: compact && (panelHover.hovered || finder.focused)
    readonly property bool expanded:   !compact || hoverExpanded
    readonly property bool overlaying:  compact && hoverExpanded

    // What the layout must reserve, which is *not* what the panel draws: that
    // difference is the overlay.
    readonly property int reservedWidth: compact ? railWidth : expandedWidth
    readonly property int targetWidth:   expanded ? expandedWidth : railWidth
    property int panelWidth: targetWidth

    // How open the panel is, 0 at the rail and 1 at full width. Everything that
    // has to move during the slide lerps off this rather than switching on
    // `expanded`, which would snap the moment the animation started instead of
    // travelling with it.
    readonly property real wideness: Math.max(0, Math.min(1,
        (panelWidth - railWidth) / Math.max(1, expandedWidth - railWidth)))
    // Content that only fits the full sidebar. Held back until the panel is a
    // quarter open so it fades in behind the leading edge rather than ahead
    // of it.
    readonly property bool showsWide: wideness > 0.25
    readonly property real wideOpacity: Math.max(0, (wideness - 0.25) / 0.75)

    // X6. Qt exposes no cross-platform reduced-motion hint, so Application
    // reads what the desktop does expose; see Application::reducedMotion().
    readonly property bool reduceMotion: app.reducedMotion === true

    // A drag is a continuous stream of new widths, so animating it would make
    // the border lag behind the pointer.
    Behavior on panelWidth {
        enabled: !root.reduceMotion && !dragHandle.dragging
        NumberAnimation { duration: 170; easing.type: Easing.OutCubic }
    }

    function openSettings() { settingsPopup.open() }

    // ── the rows the library list shows ──────────────────────────────────

    readonly property bool searching: finder.query.trim().length > 0
    property var rows: []

    function rebuildRows() {
        if (searching) {
            root.rows = library.search(finder.query, finder.kinds)
            return
        }
        var all = library.entries
        var kinds = finder.kinds
        if (!kinds || kinds.length === 0) {
            root.rows = all
            return
        }
        var out = []
        for (var i = 0; i < all.length; i++)
            if (kinds.indexOf(all[i].kind) >= 0) out.push(all[i])
        root.rows = out
    }

    // Coalesces a burst of keystrokes into one pass over the index. 120ms is
    // below the point where the list feels like it is lagging the typing.
    Timer {
        id: filterTimer
        interval: 120
        onTriggered: root.rebuildRows()
    }

    Connections {
        target: finder
        function onQueryChanged() { filterTimer.restart() }
        function onKindsChanged() { filterTimer.restart() }
    }

    Connections {
        target: library
        // The whole library arrived, or a play reordered it. No debounce: this
        // is not keystroke-rate.
        function onEntriesChanged() { root.rebuildRows() }
    }

    Component.onCompleted: rebuildRows()

    // ── the panel ────────────────────────────────────────────────────────

    Rectangle {
        id: panel
        objectName: "sidebarPanel"
        width: root.panelWidth
        height: root.height
        color: Theme.surface
        // While the panel is narrower than its content, the content must not
        // spill out over the page.
        clip: true

        HoverHandler { id: panelHover }

        ColumnLayout {
            id: body
            anchors.top: parent.top
            anchors.bottom: footer.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 0

            Item { Layout.fillWidth: true; Layout.preferredHeight: 20 }

            // ── mark and wordmark ────────────────────────────────────────
            Item {
                id: logoItem
                objectName: "sidebarLogo"
                Layout.fillWidth: true
                Layout.preferredHeight: 28

                Rectangle {
                    id: mark
                    // 20 centres the 28px mark in the 68px rail and is also the
                    // sidebar's left inset, so it does not move between the two.
                    x: 20
                    width: 28
                    height: 28
                    radius: Theme.radiusBadge
                    color: Theme.accent
                    Text {
                        anchors.centerIn: parent
                        text: "≋"
                        color: Theme.onAccent
                        font.pixelSize: 16
                        font.bold: true
                    }
                }
                Text {
                    anchors.left: mark.right
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: mark.verticalCenter
                    visible: root.showsWide
                    opacity: root.wideOpacity
                    text: "Tidal Wave"
                    color: Theme.textPrimary
                    font.pixelSize: 14
                    font.bold: true
                    font.letterSpacing: 1
                    elide: Text.ElideRight
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 24 }

            SideNavItem {
                icon: "home"
                label: qsTr("Home", "noun, the home page")
                page: "home"
                onActivated: root.navigate("home", {})
            }
            SideNavItem {
                icon: "search"
                label: qsTr("Search", "noun, the search page")
                page: "search"
                onActivated: root.navigate("search", {})
            }
            SideNavItem {
                icon: "heart"
                label: qsTr("Collection")
                page: "collection"
                onActivated: root.navigate("collection", {})
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 16 }
            Rectangle {
                objectName: "sidebarNavDivider"
                color: Theme.border
                height: 1
                Layout.fillWidth: true
                Layout.leftMargin: root.expanded ? 16 : 14
                Layout.rightMargin: root.expanded ? 16 : 14
            }
            Item { Layout.fillWidth: true; Layout.preferredHeight: 14 }

            // ── the finder: search field plus type chips (S5, S8) ────────
            LibraryFinder {
                id: finder
                objectName: "sidebarFinder"
                visible: root.showsWide
                opacity: root.wideOpacity
                Layout.fillWidth: true
                Layout.leftMargin: 12
                Layout.rightMargin: 12
                Layout.preferredHeight: implicitHeight
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 10
                visible: root.showsWide
            }

            // ── the flat library list (S1, S2) ───────────────────────────
            ListView {
                id: libList
                objectName: "sidebarLibraryList"
                visible: root.showsWide
                opacity: root.wideOpacity
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                bottomMargin: 8
                model: root.rows
                // A library can run to thousands of rows, so nothing outside
                // the viewport is kept alive.
                cacheBuffer: 240
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: LibraryRow { }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 32
                    visible: root.rows.length === 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.searching ? qsTr("No matches") : qsTr("Nothing saved yet")
                    color: Theme.textDim
                    font.pixelSize: 12
                }
            }

            // ── the rail's pinned covers (S9) ────────────────────────────
            ListView {
                id: railPins
                objectName: "sidebarRailPins"
                visible: !root.showsWide
                opacity: 1 - root.wideness
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                topMargin: 4
                bottomMargin: 8
                spacing: 4
                model: pins.items
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                    id: pinDelegate
                    required property var modelData
                    width: ListView.view.width
                    height: 44

                    Rectangle {
                        objectName: "railPinCover"
                        anchors.centerIn: parent
                        width: 40
                        height: 40
                        radius: Theme.radiusArt
                        color: Theme.surfaceHigh
                        border.width: pinHov.hovered ? 1 : 0
                        border.color: Theme.accent
                        clip: true

                        Image {
                            anchors.fill: parent
                            source: (pinDelegate.modelData.imageUrl || "").length > 0
                                    ? "image://tidal/" + pinDelegate.modelData.imageUrl : ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: status === Image.Ready
                        }
                        VectorIcon {
                            anchors.centerIn: parent
                            width: 18
                            height: 18
                            visible: (pinDelegate.modelData.imageUrl || "").length === 0
                            name: root.glyphFor(pinDelegate.modelData.kind)
                            color: Theme.textDim
                        }

                        HoverHandler { id: pinHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: root.open(pinDelegate.modelData.kind,
                                                pinDelegate.modelData.id,
                                                pinDelegate.modelData)
                        }
                        ToolTip.visible: pinHov.hovered
                        ToolTip.text: pinDelegate.modelData.title || ""
                        ToolTip.delay: 450
                    }
                }
            }
        }

        // ── footer: the username and the gear, nothing else (S10) ────────
        Rectangle {
            id: footer
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 56
            color: Theme.surfaceHigh

            Text {
                id: acctNameText
                objectName: "sidebarAccountName"
                visible: root.showsWide
                opacity: root.wideOpacity
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.right: gearItem.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                // Auth::displayNameFrom already picks the username over the
                // email address; there is deliberately no avatar beside it.
                text: auth.username.length > 0 ? auth.username : qsTr("My Account")
                color: Theme.textPrimary
                font.pixelSize: 13
                elide: Text.ElideRight
                ToolTip.visible: acctNameHov.hovered && acctNameText.truncated
                ToolTip.text: acctNameText.text
                ToolTip.delay: 600
                HoverHandler { id: acctNameHov }
            }

            Item {
                id: gearItem
                objectName: "sidebarSettingsGear"
                width: 28
                height: 28
                // Right-aligned in the sidebar, centred in the rail, and it
                // travels between the two with the slide.
                readonly property real railX: Math.round((root.railWidth - width) / 2)
                readonly property real wideX: Math.max(0, panel.width - width - 16)
                x: Math.round(railX + (wideX - railX) * root.wideness)
                anchors.verticalCenter: parent.verticalCenter

                activeFocusOnTab: true
                Keys.onReturnPressed: root.openSettings()
                Keys.onSpacePressed:  root.openSettings()

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: Theme.radiusButton
                    color: "transparent"
                    border.width: gearItem.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.centerIn: parent
                    name: "settings"
                    color: settingsHover.hovered ? Theme.textPrimary : Theme.textSec
                    width: 18
                    height: 18
                    strokeWidth: 1.8
                    ToolTip.visible: settingsHover.hovered
                    ToolTip.text: qsTr("Settings (Ctrl+,)")
                    HoverHandler { id: settingsHover }
                }
                TapHandler {
                    cursorShape: Qt.PointingHandCursor
                    onTapped: root.openSettings()
                }
            }
        }
    }

    // A soft edge where the overlay meets the page, so the sidebar reads as
    // floating above it. A gradient strip rather than MultiEffect: no extra QML
    // module to package, and it costs nothing under software rendering.
    Rectangle {
        id: panelShadow
        x: panel.width
        width: 14
        height: root.height
        visible: root.overlaying || root.panelWidth > root.reservedWidth
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, Theme.scrim.a * 0.55) }
            GradientStop { position: 1.0; color: Qt.rgba(Theme.scrim.r, Theme.scrim.g, Theme.scrim.b, 0) }
        }
    }

    // ── L3: the border is the resize handle ──────────────────────────────

    MouseArea {
        id: dragHandle
        objectName: "sidebarDragHandle"
        // Straddles the border so there is grabbable width on both sides of it.
        x: panel.width - 3
        width: 6
        height: root.height
        // Nothing to resize in the rail, and in the overlay the width on screen
        // is not the width being stored.
        visible: !root.compact
        enabled: !root.compact
        hoverEnabled: true
        cursorShape: Qt.SplitHCursor

        property bool dragging: false
        // Scene coordinates, because the handle itself travels with the edge it
        // is dragging: measuring in local coordinates would chase its own tail.
        property real originScene: 0
        property int  originWidth: 0

        onPressed: function (mouse) {
            dragging = true
            originScene = mapToItem(null, mouse.x, mouse.y).x
            originWidth = root.expandedWidth
        }
        onPositionChanged: function (mouse) {
            if (!dragging) return
            // Always measured from where the press started, so running past a
            // clamp does not bank width that comes back on the way home.
            prefs.sidebarWidth = Math.round(
                originWidth + (mapToItem(null, mouse.x, mouse.y).x - originScene))
        }
        onReleased: dragging = false
        onCanceled: dragging = false

        // The border itself, drawn by the handle so the two cannot drift apart.
        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 3
            width: 1
            height: parent.height
            color: dragHandle.containsMouse || dragHandle.dragging ? Theme.accent : Theme.border
        }
    }

    // ── navigation helpers ───────────────────────────────────────────────

    function glyphFor(kind) {
        // VectorIcon has no "track" glyph; a song is a note.
        return kind === "track" ? "music" : kind
    }

    // Opens one library row. `data` is the row as LibraryIndex handed it over.
    function open(kind, id, data) {
        library.markPlayed(kind, id)
        switch (kind) {
        case "playlist":
            // LibraryIndex does not carry the playlist type, and PlaylistPage
            // needs it to decide whether the playlist is editable. The bridge's
            // own cache of the user's playlists is the only hint available
            // without a round trip; an unknown playlist opens read-only.
            root.navigate("playlist", {
                playlistUuid:  id,
                playlistTitle: data.title || "",
                coverUrl:      data.imageUrl || "",
                playlistType:  root.playlistTypeFor(id)
            })
            break
        case "album":
            root.navigate("album", { albumId: parseInt(id) })
            break
        case "artist":
            root.navigate("artist", { artistId: parseInt(id) })
            break
        case "mix":
            root.navigate("mix", {
                mixId:    id,
                title:    data.title || "",
                subtitle: data.subtitle || "",
                coverUrl: data.imageUrl || ""
            })
            break
        case "track":
            // A song opens the album it came from, which is the only page a
            // single track has.
            if (data.albumId) root.navigate("album", { albumId: parseInt(data.albumId) })
            break
        }
    }

    function playlistTypeFor(uuid) {
        var mine = bridge.getUserPlaylists()
        for (var i = 0; i < mine.length; i++)
            if (mine[i].uuid === uuid) return mine[i].type || ""
        return ""
    }

    // The settings popup, exposed so tests/qml/tst_layout_player.qml can measure
    // it. Nothing else reads it.
    readonly property alias settingsPanel: settingsPopup

    Popup {
        id: settingsPopup
        anchors.centerIn: Overlay.overlay
        // 480x640 fixed did not fit its own window: the window minimum is 600
        // tall, so the popup was 40px taller than the smallest window it can
        // appear in. Clamp to the overlay with 32px of breathing room on every
        // side (SPEC L10); the ScrollView below already scrolls what is left
        // over. `parent` here is Overlay.overlay, courtesy of anchors.centerIn.
        width:  Math.min(480, (parent ? parent.width  : 480) - 64)
        height: Math.min(640, (parent ? parent.height : 640) - 64)
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 0
        background: Rectangle {
            color: Theme.surfaceHigh
            border.color: Theme.border
            radius: Theme.radiusPopup
        }

        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: parent.width
                spacing: 0

                // Header
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 16
                    Layout.topMargin: 20
                    Layout.bottomMargin: 12

                    Text {
                        text: qsTr("Settings")
                        color: Theme.textPrimary
                        font.pixelSize: 18
                        font.bold: true
                        Layout.fillWidth: true
                    }
                    VectorIcon {
                        name: "x"
                        color: Theme.textSec
                        width: 14; height: 14
                        strokeWidth: 1.8
                        MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: settingsPopup.close() }
                    }
                }

                Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

                // ── ACCOUNT ──────────────────────────────
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 14
                    Layout.bottomMargin: 4
                    spacing: 10

                    Text {
                        text: qsTr("Account")
                        color: Theme.textDim
                        font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Rectangle {
                            width: 36; height: 36; radius: 18; color: Theme.accent
                            Text { anchors.centerIn: parent; text: "♪"; color: Theme.onAccent; font.pixelSize: 16 }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { text: "Tidal Wave"; color: Theme.textPrimary; font.pixelSize: 14; font.bold: true }
                            Text {
                                objectName: "settingsVersion"
                                text: qsTr("Version %1").arg(prefs.appVersion())
                                color: Theme.textDim; font.pixelSize: 12
                            }
                        }
                        Rectangle {
                            height: 30; width: logoutLabel.implicitWidth + 20; radius: Theme.radiusButton
                            color: logoutHov.hovered ? Theme.red : Theme.surface
                            border.color: logoutHov.hovered ? Theme.red : Theme.border
                            Text {
                                id: logoutLabel; anchors.centerIn: parent
                                text: qsTr("Log out"); color: logoutHov.hovered ? Theme.onRed : Theme.red
                                font.pixelSize: 12
                            }
                            HoverHandler { id: logoutHov }
                            TapHandler { onTapped: { settingsPopup.close(); auth.logout() } }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                        }
                    }
                }

                Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20 }

                // ── PLAYBACK ─────────────────────────────
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 14
                    Layout.bottomMargin: 4
                    spacing: 10

                    Text {
                        text: qsTr("Playback")
                        color: Theme.textDim
                        font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text { text: qsTr("Streaming quality"); color: Theme.textPrimary; font.pixelSize: 14; Layout.fillWidth: true }
                        ComboBox {
                            id: qualityCombo
                            model: [qsTr("Normal (96 kbps)"), qsTr("High (320 kbps)"),
                                    qsTr("Lossless (FLAC)"), qsTr("Hi-Res (24-bit)")]
                            currentIndex: {
                                switch (bridge.preferredQuality) {
                                    case "LOW":             return 0
                                    case "HIGH":            return 1
                                    case "HI_RES_LOSSLESS": return 3
                                    default:                return 2
                                }
                            }
                            Layout.preferredWidth: 160
                            onActivated: function(idx) {
                                var codes = ["LOW", "HIGH", "LOSSLESS", "HI_RES_LOSSLESS"]
                                bridge.preferredQuality = codes[idx]
                            }

                            // Custom ComboBox styling to match dark theme
                            delegate: ItemDelegate {
                                width: qualityCombo.width
                                contentItem: Text {
                                    text: modelData
                                    color: highlighted ? Theme.textPrimary : Theme.textSec
                                    font.pixelSize: 13
                                    elide: Text.ElideRight
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    color: highlighted ? Theme.surfaceHov : Theme.surfaceHigh
                                }
                                highlighted: qualityCombo.highlightedIndex === index
                            }

                            indicator: Canvas {
                                id: canvas
                                x: qualityCombo.width - width - 10
                                y: qualityCombo.topPadding + (qualityCombo.availableHeight - height) / 2
                                width: 12
                                height: 8
                                contextType: "2d"

                                Connections {
                                    target: qualityCombo.popup
                                    function onVisibleChanged() { canvas.requestPaint() }
                                }

                                onPaint: {
                                    var context = getContext("2d");
                                    context.reset();
                                    context.moveTo(0, 0);
                                    context.lineTo(width, 0);
                                    context.lineTo(width / 2, height);
                                    context.closePath();
                                    context.fillStyle = Theme.textSec;
                                    context.fill();
                                }
                            }

                            contentItem: Text {
                                leftPadding: 10
                                rightPadding: qualityCombo.indicator.width + 15
                                text: qualityCombo.displayText
                                color: Theme.textPrimary
                                font.pixelSize: 13
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                            }

                            background: Rectangle {
                                implicitWidth: 160
                                implicitHeight: 32
                                border.color: qualityCombo.pressed ? Theme.accent : Theme.border
                                border.width: 1
                                color: Theme.surfaceHigh
                                radius: Theme.radiusButton
                            }

                            popup: Popup {
                                y: qualityCombo.height + 2
                                width: qualityCombo.width
                                implicitHeight: contentItem.implicitHeight
                                padding: 1
                                background: Rectangle {
                                    border.color: Theme.border
                                    border.width: 1
                                    color: Theme.surfaceHigh
                                    radius: Theme.radiusPopup
                                }
                                contentItem: ListView {
                                    clip: true
                                    implicitHeight: contentHeight
                                    model: qualityCombo.popup.visible ? qualityCombo.delegateModel : null
                                    currentIndex: qualityCombo.highlightedIndex
                                    ScrollIndicator.vertical: ScrollIndicator { }
                                }
                            }
                        }
                    }

                }

                Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20 }

                // ── KEYBOARD SHORTCUTS ───────────────────
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 14
                    Layout.bottomMargin: 20
                    spacing: 6

                    Text {
                        text: qsTr("Keyboard shortcuts")
                        color: Theme.textDim
                        font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    }

                    Repeater {
                        model: [
                            { k: qsTr("Space", "keyboard key"),      d: qsTr("Play / Pause") },
                            { k: qsTr("Ctrl+Right / Left"),          d: qsTr("Next / Previous track") },
                            { k: qsTr("Right / Left", "arrow keys"), d: qsTr("Seek forward / back 10s") },
                            { k: qsTr("Up / Down", "arrow keys"),    d: qsTr("Volume up / down") },
                            { k: qsTr("Ctrl+M"),                     d: qsTr("Mute") },
                            { k: qsTr("Ctrl+S"),                     d: qsTr("Toggle shuffle") },
                            { k: qsTr("Ctrl+R"),                     d: qsTr("Cycle repeat mode") },
                            { k: qsTr("Ctrl+1 / 2 / 3"),             d: qsTr("Home / Search / Collection") },
                            { k: qsTr("Ctrl+N"),                     d: qsTr("Now Playing") },
                            { k: qsTr("Ctrl+Q"),                     d: qsTr("Toggle queue") },
                            { k: qsTr("Alt+Left / Esc"),             d: qsTr("Go back") },
                            { k: qsTr("Ctrl+,"),                     d: qsTr("Settings") }
                        ]
                        delegate: RowLayout {
                            Layout.fillWidth: true
                            spacing: 12
                            Rectangle {
                                color: Theme.surface; radius: Theme.radiusBadge; border.color: Theme.border
                                implicitWidth: shortcutLabel.implicitWidth + 14; implicitHeight: 22
                                Text {
                                    id: shortcutLabel; anchors.centerIn: parent
                                    text: modelData.k; color: Theme.textPrimary
                                    font.pixelSize: 11; font.family: "monospace"
                                }
                            }
                            Text {
                                text: modelData.d; color: Theme.textSec
                                font.pixelSize: 12; Layout.fillWidth: true
                            }
                        }
                    }
                }
            }
        }
    }

    // ── inline components ────────────────────────────────────────────────

    // One row of the flat library list. The type icon is what tells a playlist
    // from an album from an artist from a mix now that they share one list.
    component LibraryRow : Item {
        id: rowItem
        objectName: "libraryRow"

        required property int index
        required property var modelData

        readonly property string kind:   modelData.kind
        readonly property string itemId: modelData.id
        readonly property string title:  modelData.title
        readonly property bool   pinned: modelData.pinned === true
        // S7: a row the search pulled in because of a neighbouring hit, rather
        // than because the user typed its name.
        readonly property bool   derived: modelData.expanded === true

        // The break between the pinned block and the rest (P3/P5). Search
        // results have no pinned block, so they have nothing to break.
        readonly property bool blockBreak: !root.searching && index > 0 && !pinned
                                           && root.rows[index - 1].pinned === true

        width: ListView.view ? ListView.view.width : 0
        height: 34 + (blockBreak ? 11 : 0)

        activeFocusOnTab: true
        Keys.onReturnPressed: root.open(kind, itemId, modelData)
        Keys.onSpacePressed:  root.open(kind, itemId, modelData)

        Rectangle {
            objectName: "pinnedBlockBreak"
            property int rowIndex: rowItem.index
            visible: rowItem.blockBreak
            anchors.top: parent.top
            anchors.topMargin: 5
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: parent.right
            anchors.rightMargin: 16
            height: 1
            color: Theme.border
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            height: 34
            radius: Theme.radiusRow
            color: rowHov.hovered ? Theme.surfaceHov : "transparent"
            border.width: rowItem.activeFocus ? 2 : 0
            border.color: Theme.accent

            HoverHandler { id: rowHov; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.open(rowItem.kind, rowItem.itemId, rowItem.modelData) }

            VectorIcon {
                id: rowIcon
                objectName: "libraryRowIcon"
                anchors.left: parent.left
                anchors.leftMargin: 8 + (rowItem.derived ? 12 : 0)
                anchors.verticalCenter: parent.verticalCenter
                name: root.glyphFor(rowItem.kind)
                width: 15
                height: 15
                strokeWidth: 1.5
                color: rowItem.pinned ? Theme.accent : Theme.textDim
            }

            Text {
                id: rowTitle
                objectName: "libraryRowTitle"
                anchors.left: rowIcon.right
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.title
                color: rowItem.derived ? Theme.textDim : Theme.textSec
                font.pixelSize: 13
                elide: Text.ElideRight
            }

            ToolTip.visible: rowHov.hovered && (rowTitle.truncated || subtitleOf.length > 0)
            ToolTip.text: subtitleOf.length > 0 ? rowItem.title + " · " + subtitleOf
                                                : rowItem.title
            ToolTip.delay: 600
            readonly property string subtitleOf: rowItem.modelData.subtitle || ""
        }
    }

    // A nav row. In the rail it is the icon alone, centred; expanded it gains
    // its label. Same item either way, so the switch is a slide, not a swap.
    component SideNavItem : Item {
        id: navItem
        property string icon: ""
        property string label: ""
        property string page: ""
        signal activated()

        readonly property bool current: root.currentPage === page

        Layout.fillWidth: true
        Layout.preferredHeight: 44

        activeFocusOnTab: true
        Keys.onReturnPressed: activated()
        Keys.onSpacePressed:  activated()

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            radius: Theme.radiusRow
            color: navItem.current
                   ? Theme.surfaceHov
                   : sideHov.hovered ? Theme.hoverFill : "transparent"
            border.width: navItem.activeFocus ? 2 : 0
            border.color: Theme.accent

            Rectangle {
                visible: navItem.current
                width: 3
                height: parent.height * 0.5
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: -8
                radius: 2
                color: Theme.accent
            }

            NavIcon {
                id: navGlyph
                objectName: "navIcon"
                name: navItem.icon
                color: navItem.current ? Theme.accent : Theme.textSec
                anchors.verticalCenter: parent.verticalCenter
                // 16 from the panel edge in the sidebar (8 here, inside the
                // row's 8px inset), centred in the rail, and travelling
                // between the two with the slide.
                readonly property real railX: Math.round((root.railWidth - 16 - width) / 2)
                x: Math.round(railX + (8 - railX) * root.wideness)
            }

            Text {
                objectName: "navLabel"
                visible: root.showsWide
                opacity: root.wideOpacity
                anchors.left: navGlyph.right
                anchors.leftMargin: 12
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: navItem.label
                color: navItem.current ? Theme.textPrimary : Theme.textSec
                font.pixelSize: 14
                font.bold: navItem.current
                elide: Text.ElideRight
            }

            HoverHandler { id: sideHov; cursorShape: Qt.PointingHandCursor }
            TapHandler   { onTapped: navItem.activated() }

            ToolTip.visible: sideHov.hovered && !root.showsWide
            ToolTip.text: navItem.label
            ToolTip.delay: 450
        }
    }
}
