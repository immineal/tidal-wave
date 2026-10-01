import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import TidalWave

// The queue overlay: a scrim across the page with the panel pinned to the right
// of it. It covers the whole content area rather than being a bare 340px strip,
// because without a scrim and a MouseArea of its own every click simply landed
// on the page underneath it (SPEC L9).
Item {
    id: root

    // Raised by a click on the scrim. The owner decides what dismissal means.
    signal dismissed()

    // 340 is the design width. The 85% cap keeps the panel from eating a narrow
    // window whole: at the 640px minimum the content area is 420px, where a
    // fixed 340 would leave 80px of page showing.
    readonly property int panelWidth: Math.min(340, Math.round(width * 0.85))

    // The queue in true play order (respects shuffle). In shuffle mode each
    // entry carries "_queueIndex" so rows still map back to the real queue
    // index.
    //
    // Two things keep this off the hot path. It is gated on visible, because a
    // closed panel still evaluated its binding and held a copy of the whole
    // queue in JS; and the shuffled branch subscribes to queueChanged by
    // reading queueCount rather than queueTracks, so the queue is marshalled
    // once per rebuild instead of twice. Advancing a track no longer raises
    // queueChanged at all (Player::setIndex), so this does not run on a track
    // change — only on a real add/remove/reorder/shuffle/clear/new context.
    property var queueModel:
        !visible ? []
                 : player.shuffle ? (player.queueCount, player.playbackOrderTracks())
                                  : player.queueTracks

    // Which displayed row is playing. Reads player.queueIndex as a property, so
    // it follows whichever signal the Player notifies it with.
    readonly property int currentRow: {
        var qi = player.queueIndex
        if (qi < 0) return -1
        if (!player.shuffle) return qi
        var m = root.queueModel
        for (var i = 0; i < m.length; i++)
            if (m[i] && m[i]._queueIndex === qi) return i
        return -1
    }

    // Keeps the playing row on screen as the queue advances. Contain only moves
    // the view when the row has actually fallen outside it.
    function revealCurrent() {
        if (!visible || currentRow < 0 || currentRow >= queueListView.count) return
        queueListView.positionViewAtIndex(currentRow, ListView.Contain)
    }
    onCurrentRowChanged: revealCurrent()
    // On open the rows do not exist yet, so the scroll has to wait for them.
    onVisibleChanged: if (visible) Qt.callLater(revealCurrent)

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    // Swallows anything that misses the panel, so no click reaches the page.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.dismissed()
        onWheel: (wheel) => wheel.accepted = true
    }

    Rectangle {
        id: panel
        anchors.top:    parent.top
        anchors.bottom: parent.bottom
        anchors.right:  parent.right
        width: root.panelWidth
        color: Theme.surface
        border.color: Theme.border

        // Declared before the panel's content, so it only ever sees what the
        // content did not take. The panel is not the scrim: a click that lands
        // on it stays on it.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                height: 52
                color: "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    Text { text: qsTr("Queue", "noun, the play queue"); color: Theme.textPrimary; font.pixelSize: 16; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: qsTr("%n track(s)", "", player.queueCount); color: Theme.textSec; font.pixelSize: 12 }
                    Text {
                        visible: player.shuffle
                        text: qsTr("· Shuffled")
                        color: Theme.accent; font.pixelSize: 12
                    }
                    Item { width: 8 }
                    Text {
                        text: qsTr("Clear", "verb, empties the play queue")
                        color: clearHov.hovered ? Theme.textPrimary : Theme.textSec
                        font.pixelSize: 12
                        visible: player.queueCount > 0
                        HoverHandler { id: clearHov }
                        TapHandler { onTapped: player.clearQueue() }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

            ListView {
                id: queueListView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: root.queueModel
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: QueueDelegate {
                    required property int     index
                    required property var     modelData
                    // In shuffle mode the row's real queue index travels in the map.
                    trackIndex: (modelData && modelData._queueIndex !== undefined)
                                ? modelData._queueIndex : index
                    track:      modelData
                    width: queueListView.width
                }
            }
        }
    }

    component QueueDelegate : Item {
        id: queueItem
        property int trackIndex: 0

        height: 52

        property bool isCurrent:  player.queueIndex === trackIndex
        property var  track:      null
        readonly property bool userQueued: track && track["_userQueued"] === true

        // Only a string is a title; a missing or wrongly typed field is not.
        function fieldOf(key) {
            var v = track ? track[key] : undefined
            return (typeof v === "string") ? v : ""
        }
        // The two fallbacks come out of TrackRow's context rather than being
        // declared again here: the same sentence in two contexts is the same
        // sentence translated twice, and free to drift.
        readonly property string titleText:
            fieldOf("title")   || qsTranslate("TrackRow", "Unknown track")
        readonly property string artistsText:
            fieldOf("artists") || qsTranslate("TrackRow", "Unknown artist")
        readonly property string coverText:   fieldOf("coverUrl80")

        activeFocusOnTab: true
        Keys.onReturnPressed: player.jumpToQueue(trackIndex)
        Keys.onSpacePressed:  player.jumpToQueue(trackIndex)

        // Accent stripe for user-queued tracks
        Rectangle {
            visible: queueItem.userQueued && !queueItem.isCurrent
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 3; height: 28; radius: 2
            color: Theme.accent
            opacity: 0.7
        }

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            radius: Theme.radiusRow
            color: isCurrent ? Theme.accentSoft : qHov.hovered ? Theme.surfaceHov : "transparent"
            border.width: queueItem.activeFocus ? 2 : 0
            border.color: Theme.accent

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 8
                spacing: 8

                // Up/Down reorder buttons, hidden while shuffled, where a
                // linear move would fight the displayed play order.
                Column {
                    spacing: 1
                    visible: !player.shuffle
                    opacity: qHov.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(120) } }
                    Repeater {
                        model: [{ glyph: "▲", delta: -1 }, { glyph: "▼", delta: 1 }]
                        Item {
                            required property var modelData
                            width: 18; height: 18
                            Text {
                                anchors.centerIn: parent
                                text: modelData.glyph
                                color: arrHov.hovered ? Theme.textPrimary : Theme.textDim
                                font.pixelSize: 9
                            }
                            HoverHandler { id: arrHov }
                            TapHandler {
                                onTapped: {
                                    var to = queueItem.trackIndex + modelData.delta
                                    if (to >= 0 && to < player.queueCount)
                                        player.moveQueueItem(queueItem.trackIndex, to)
                                }
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                        }
                    }
                }

                Rectangle {
                    width: 36
                    height: 36
                    radius: Theme.radiusArt
                    color: Theme.surfaceHigh
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: queueItem.coverText ? "image://tidal/" + queueItem.coverText : ""
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    // A truncated payload must still read as a row.
                    Text {
                        Layout.fillWidth: true
                        text: queueItem.titleText
                        color: isCurrent ? Theme.accent : Theme.textPrimary
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: queueItem.artistsText
                        color: Theme.textSec
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }

                // Remove button, visible on hover
                Item {
                    visible: qHov.hovered
                    width: 24; height: 24
                    VectorIcon {
                        anchors.centerIn: parent
                        name: "x"
                        color: removeHov.hovered ? Theme.textPrimary : Theme.textSec
                        width: 12; height: 12
                        strokeWidth: 2
                    }
                    HoverHandler { id: removeHov }
                    TapHandler {
                        onTapped: player.removeFromQueue(queueItem.trackIndex)
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; acceptedButtons: Qt.NoButton }
                }
            }

            HoverHandler { id: qHov }
            TapHandler   { onDoubleTapped: player.jumpToQueue(trackIndex) }

            // Right-click context menu
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: queueContextMenu.popup()
            }
            Menu {
                id: queueContextMenu
                background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup; implicitWidth: 180 }
                MenuItem {
                    text: qsTr("Remove from queue")
                    contentItem: Text { text: parent.text; color: Theme.textPrimary; font.pixelSize: 13; leftPadding: 12; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.highlighted ? Theme.surfaceHov : "transparent" }
                    onTriggered: player.removeFromQueue(queueItem.trackIndex)
                }
            }
        }
    }
}
