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
                radius: 4
                color: Theme.accent
                Text { anchors.centerIn: parent; text: "≋"; color: "white"; font.pixelSize: 16; font.bold: true }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "TIDAL WAVE"
                color: Theme.textPrimary
                font.pixelSize: 14
                font.bold: true
                font.letterSpacing: 1
            }
        }

        Item { height: 24 }

        SideNavItem {
            icon: "home"
            label: "Home"
            page: "home"
            currentPage: root.currentPage
            onActivated: root.navigate("home", {})
        }
        SideNavItem {
            icon: "search"
            label: "Search"
            page: "search"
            currentPage: root.currentPage
            onActivated: root.navigate("search", {})
        }
        SideNavItem {
            icon: "heart"
            label: "Collection"
            page: "collection"
            currentPage: root.currentPage
            onActivated: root.navigate("collection", {})
        }

        Item { height: 16 }
        Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16 }
        Item { height: 16 }

        Text {
            Layout.leftMargin: 20
            text: "PLAYLISTS"
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
                    radius: 6
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
                            radius: 4
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
            Rectangle {
                width: 32
                height: 32
                radius: 16
                color: Theme.surfaceHov
                VectorIcon {
                    anchors.centerIn: parent
                    name: "user"
                    color: Theme.textSec
                    width: 16
                    height: 16
                    strokeWidth: 1.8
                }
            }
            Text {
                id: acctNameText
                Layout.fillWidth: true
                text: auth.username.length > 0 ? auth.username : "My Account"
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
                    radius: 6
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
                    ToolTip.text: "Settings (Ctrl+,)"
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

    Popup {
        id: settingsPopup
        anchors.centerIn: Overlay.overlay
        width: 480
        height: 640
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 0
        background: Rectangle {
            color: Theme.surfaceHigh
            border.color: Theme.border
            radius: 12
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
                        text: "Settings"
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
                        text: "ACCOUNT"
                        color: Theme.textDim
                        font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Rectangle {
                            width: 36; height: 36; radius: 18; color: Theme.accent
                            Text { anchors.centerIn: parent; text: "♪"; color: "white"; font.pixelSize: 16 }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { text: "Tidal Wave"; color: Theme.textPrimary; font.pixelSize: 14; font.bold: true }
                            Text { text: "v0.1-alpha"; color: Theme.textDim; font.pixelSize: 12 }
                        }
                        Rectangle {
                            height: 30; width: logoutLabel.implicitWidth + 20; radius: 6
                            color: logoutHov.hovered ? Theme.red : Theme.surface
                            border.color: logoutHov.hovered ? Theme.red : Theme.border
                            Text {
                                id: logoutLabel; anchors.centerIn: parent
                                text: "Log out"; color: logoutHov.hovered ? "white" : Theme.red
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
                        text: "PLAYBACK"
                        color: Theme.textDim
                        font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text { text: "Streaming Quality"; color: Theme.textPrimary; font.pixelSize: 14; Layout.fillWidth: true }
                        ComboBox {
                            id: qualityCombo
                            model: ["Normal (96 kbps)", "High (320 kbps)", "Lossless (FLAC)", "Hi-Res (24-bit)"]
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
                                radius: Theme.radius
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
                                    radius: Theme.radius
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
                        text: "KEYBOARD SHORTCUTS"
                        color: Theme.textDim
                        font.pixelSize: 11; font.bold: true; font.letterSpacing: 1
                    }

                    Repeater {
                        model: [
                            { k: "Space",              d: "Play / Pause" },
                            { k: "Ctrl+Right / Left",  d: "Next / Previous track" },
                            { k: "Right / Left",        d: "Seek forward / back 10s" },
                            { k: "Up / Down",           d: "Volume up / down" },
                            { k: "Ctrl+M",             d: "Mute" },
                            { k: "Ctrl+S",             d: "Toggle shuffle" },
                            { k: "Ctrl+R",             d: "Cycle repeat mode" },
                            { k: "Ctrl+1 / 2 / 3",    d: "Home / Search / Collection" },
                            { k: "Ctrl+N",             d: "Now Playing" },
                            { k: "Ctrl+Q",             d: "Toggle queue" },
                            { k: "Alt+Left / Esc",     d: "Go back" },
                            { k: "Ctrl+,",             d: "Settings" }
                        ]
                        delegate: RowLayout {
                            Layout.fillWidth: true
                            spacing: 12
                            Rectangle {
                                color: Theme.surface; radius: 4; border.color: Theme.border
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

    // Inline component for nav items — properties on separate lines to avoid semicolon issues
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
            radius: Theme.radius
            color: root.currentPage === page
                   ? Theme.surfaceHov
                   : sideHov.hovered ? Qt.rgba(1,1,1,0.04) : "transparent"
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
