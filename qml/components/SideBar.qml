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
                    root.navigate("playlist", { playlistUuid: model.uuid, playlistTitle: model.title, coverUrl: model.coverUrl || "" })
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
            anchors.fill: parent
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
            Text { Layout.fillWidth: true; text: "My Account"; color: Theme.textPrimary; font.pixelSize: 13; elide: Text.ElideRight }
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
            Item {
                id: acctMenuButton
                width: 28; height: 28
                activeFocusOnTab: true
                Keys.onReturnPressed: accountMenu.popup(acctMenuButton, -130, -90)
                Keys.onSpacePressed:  accountMenu.popup(acctMenuButton, -130, -90)

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: 6
                    color: "transparent"
                    border.width: parent.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.centerIn: parent
                    name: "more-vertical"
                    color: Theme.textSec
                    width: 16
                    height: 16
                    strokeWidth: 1.8
                }
                TapHandler {
                    cursorShape: Qt.PointingHandCursor
                    onTapped: accountMenu.popup(acctMenuButton, -130, -90)
                }
            }
        }
    }

    function loadPlaylists() {
        bridge.fetchUserPlaylists(function(playlists, err) {
            playlistModel.clear()
            for (var i = 0; i < playlists.length; i++) {
                playlistModel.append({ title: playlists[i].title, uuid: playlists[i].uuid, coverUrl: playlists[i].coverUrl || "" })
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

    Menu {
        id: accountMenu
        background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: 8; implicitWidth: 150 }
        MenuItem {
            text: "Settings"
            contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: settingsPopup.open()
        }
        MenuItem {
            text: "Log out"
            contentItem: Text { text: parent.text; color: Theme.red; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
            onTriggered: auth.logout()
        }
    }

    Popup {
        id: settingsPopup
        anchors.centerIn: Overlay.overlay
        width: 460
        height: 560
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle {
            color: Theme.surfaceHigh
            border.color: Theme.border
            radius: 12
        }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 14

            RowLayout {
                Layout.fillWidth: true
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
                    width: 14
                    height: 14
                    strokeWidth: 1.8
                    MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: settingsPopup.close() }
                }
            }

            Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

            Text {
                text: "PLAYBACK"
                color: Theme.textDim
                font.pixelSize: 11
                font.bold: true
                font.letterSpacing: 1
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                Text {
                    text: "Streaming Quality"
                    color: Theme.textPrimary
                    font.pixelSize: 14
                    Layout.fillWidth: true
                }
                ComboBox {
                    id: qualityCombo
                    model: ["Normal", "High", "Lossless", "Hi-Res"]
                    currentIndex: {
                        switch (bridge.preferredQuality) {
                            case "LOW":             return 0
                            case "HIGH":            return 1
                            case "HI_RES_LOSSLESS": return 3
                            default:                return 2
                        }
                    }
                    Layout.preferredWidth: 130
                    onActivated: function(index) {
                        var codes = ["LOW", "HIGH", "LOSSLESS", "HI_RES_LOSSLESS"]
                        bridge.preferredQuality = codes[index]
                    }
                }
            }

            Rectangle { color: Theme.border; height: 1; Layout.fillWidth: true }

            Text {
                text: "KEYBOARD SHORTCUTS"
                color: Theme.textDim
                font.pixelSize: 11
                font.bold: true
                font.letterSpacing: 1
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 6

                Repeater {
                    model: [
                        { k: "Space",         d: "Play / Pause" },
                        { k: "Ctrl+→ / Ctrl+←", d: "Next / Previous track" },
                        { k: "→ / ←",         d: "Seek forward / back 10s" },
                        { k: "↑ / ↓",         d: "Volume up / down" },
                        { k: "Ctrl+M",        d: "Mute" },
                        { k: "Ctrl+S",        d: "Toggle shuffle" },
                        { k: "Ctrl+R",        d: "Cycle repeat mode" },
                        { k: "Ctrl+1 / 2 / 3", d: "Home / Search / Collection" },
                        { k: "Ctrl+N",        d: "Now Playing" },
                        { k: "Ctrl+Q",        d: "Toggle queue" },
                        { k: "Alt+← / Esc",   d: "Go back" },
                        { k: "Ctrl+,",        d: "Settings" }
                    ]
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Rectangle {
                            color: Theme.surface
                            radius: 4
                            border.color: Theme.border
                            implicitWidth: shortcutLabel.implicitWidth + 14
                            implicitHeight: 22
                            Text {
                                id: shortcutLabel
                                anchors.centerIn: parent
                                text: modelData.k
                                color: Theme.textPrimary
                                font.pixelSize: 11
                                font.family: "monospace"
                            }
                        }
                        Text {
                            text: modelData.d
                            color: Theme.textSec
                            font.pixelSize: 12
                            Layout.fillWidth: true
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
