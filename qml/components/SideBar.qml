import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

Rectangle {
    id: root
    color: Theme.surface

    property string currentPage: "home"
    signal navigate(string page, var params)

    ColumnLayout {
        anchors.fill: parent
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
                width: ListView.view.width
                height: 36
                Rectangle {
                    id: plRect
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: 6
                    color: plHov.hovered ? Theme.surfaceHov : "transparent"
                    HoverHandler { id: plHov }
                    TapHandler {
                        onTapped: root.navigate("playlist", { playlistUuid: model.uuid, playlistTitle: model.title, coverUrl: model.coverUrl || "" })
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

        Rectangle {
            Layout.fillWidth: true
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
                    color: Theme.accent
                    Text { anchors.centerIn: parent; text: "U"; color: "white"; font.bold: true }
                }
                Text { Layout.fillWidth: true; text: "My Account"; color: Theme.textPrimary; font.pixelSize: 13; elide: Text.ElideRight }
                Text {
                    id: acctMenuButton
                    text: "⋮"
                    color: Theme.textSec
                    font.pixelSize: 18
                    width: 32
                    horizontalAlignment: Text.AlignHCenter
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: accountMenu.popup(acctMenuButton, -130, -90)
                    }
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
        width: 320
        height: 200
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
            spacing: 16
            Text {
                text: "Settings"
                color: Theme.textPrimary
                font.pixelSize: 18
                font.bold: true
                Layout.alignment: Qt.AlignHCenter
            }
            Rectangle {
                color: Theme.border
                height: 1
                Layout.fillWidth: true
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
                        var q = player.audioQuality
                        if (q === "HI_RES_LOSSLESS") return 3
                        if (q === "LOSSLESS") return 2
                        return 1
                    }
                    Layout.preferredWidth: 110
                }
            }
            Item { Layout.fillHeight: true }
            Button {
                text: "Close"
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredHeight: 32
                Layout.preferredWidth: 80
                onClicked: settingsPopup.close()
                contentItem: Text {
                    text: parent.text
                    color: "white"
                    font.bold: true
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: Theme.accent
                    radius: Theme.radius
                }
            }
        }
    }

    // Inline component for nav items — properties on separate lines to avoid semicolon issues
    component SideNavItem : Item {
        property string icon: ""
        property string label: ""
        property string page: ""
        property string currentPage: ""
        signal activated()

        Layout.fillWidth: true
        height: 44

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
