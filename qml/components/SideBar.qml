import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

Rectangle {
    id: root
    color: Theme.surface

    property string currentPage: "home"
    signal navigate(string page, var params)

    function openSettings() { settingsPopup.open() }

    ColumnLayout {
        anchors.top: parent.top
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        Item { height: 20 }

        Row {
            Layout.leftMargin: 20
            spacing: 8
            Rectangle {
                width: 28
                height: 28
                radius: Theme.radiusBadge
                color: Theme.accent
                Text { anchors.centerIn: parent; text: "≋"; color: Theme.onAccent; font.pixelSize: 16; font.bold: true }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Tidal Wave"
                color: Theme.textPrimary
                font.pixelSize: 14
                font.bold: true
                font.letterSpacing: 1
            }
        }

        Item { height: 24 }

        SideNavItem {
            icon: "home"
            label: qsTr("Home", "noun, the home page")
            page: "home"
            currentPage: root.currentPage
            onActivated: root.navigate("home", {})
        }
        SideNavItem {
            icon: "search"
            label: qsTr("Search", "noun, the search page")
            page: "search"
            currentPage: root.currentPage
            onActivated: root.navigate("search", {})
        }
        SideNavItem {
            icon: "heart"
            label: qsTr("Collection")
            page: "collection"
            currentPage: root.currentPage
            onActivated: root.navigate("collection", {})
        }

        Item { height: 16 }
        Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16 }
        Item { height: 16 }

        Text {
            Layout.leftMargin: 20
            text: qsTr("Playlists")
            color: Theme.textDim
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.5
        }

        Item { height: 8 }

        ListView {
            id: playlistList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            bottomMargin: 8
            model: ListModel { id: playlistModel }

            delegate: Item {
                id: plDelegate
                width: ListView.view.width
                height: 36

                function activate() {
                    root.navigate("playlist", { playlistUuid: model.uuid, playlistTitle: model.title, coverUrl: model.coverUrl || "", playlistType: model.type || "" })
                }

                activeFocusOnTab: true
                Keys.onReturnPressed: activate()
                Keys.onSpacePressed:  activate()

                Rectangle {
                    id: plRect
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: Theme.radiusRow
                    color: plHov.hovered ? Theme.surfaceHov : "transparent"
                    border.width: plDelegate.activeFocus ? 2 : 0
                    border.color: Theme.accent
                    HoverHandler { id: plHov }
                    TapHandler {
                        onTapped: plDelegate.activate()
                    }
                    Text {
                        id: plText
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: model.title
                        color: Theme.textSec
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        width: parent.width - 32
                    }
                    ToolTip {
                        id: plToolTip
                        delay: 600
                        visible: plHov.hovered && plText.truncated
                        text: model.title
                        background: Rectangle {
                            color: Theme.surfaceHigh
                            border.color: Theme.border
                            radius: Theme.radiusBadge
                        }
                        contentItem: Text {
                            text: plToolTip.text
                            color: Theme.textPrimary
                            font.pixelSize: 12
                        }
                    }
                }
            }
        }

    }

    Rectangle {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        color: Theme.surfaceHigh

        RowLayout {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 56
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 10
            Text {
                id: acctNameText
                Layout.fillWidth: true
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
                width: 28; height: 28
                activeFocusOnTab: true
                Keys.onReturnPressed: root.openSettings()
                Keys.onSpacePressed:  root.openSettings()

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: Theme.radiusButton
                    color: "transparent"
                    border.width: parent.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    id: settingsButton
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

    function loadPlaylists() {
        bridge.fetchUserPlaylists(function(playlists, err) {
            playlistModel.clear()
            for (var i = 0; i < playlists.length; i++) {
                playlistModel.append({
                    title:   playlists[i].title,
                    uuid:    playlists[i].uuid,
                    coverUrl: playlists[i].coverUrl || "",
                    type:    playlists[i].type || ""
                })
            }
        }, 30, 0)
    }

    Component.onCompleted: { if (auth.state === 2) loadPlaylists() }

    Connections {
        target: auth
        function onStateChanged(state) {
            if (state === 2) loadPlaylists()
        }
    }

    Connections {
        target: bridge
        function onFavoritePlaylistsChanged() {
            loadPlaylists()
        }
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
                            Text { text: qsTr("Version %1").arg(prefs.appVersion()); color: Theme.textDim; font.pixelSize: 12 }
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

    // Inline component for nav items. Properties on separate lines to avoid semicolon issues.
    component SideNavItem : Item {
        id: navItem
        property string icon: ""
        property string label: ""
        property string page: ""
        property string currentPage: ""
        signal activated()

        Layout.fillWidth: true
        height: 44

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
            color: root.currentPage === page
                   ? Theme.surfaceHov
                   : sideHov.hovered ? Theme.hoverFill : "transparent"
            border.width: navItem.activeFocus ? 2 : 0
            border.color: Theme.accent

            Rectangle {
                visible: root.currentPage === page
                width: 3
                height: parent.height * 0.5
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: -8
                radius: 2
                color: Theme.accent
            }

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                NavIcon {
                    name: icon
                    color: root.currentPage === page ? Theme.accent : Theme.textSec
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: label
                    color: root.currentPage === page ? Theme.textPrimary : Theme.textSec
                    font.pixelSize: 14
                    font.bold: root.currentPage === page
                }
            }

            HoverHandler { id: sideHov }
            TapHandler   { onTapped: activated() }
        }
    }
}
