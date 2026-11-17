import QtQuick
import QtQuick.Controls
import TidalWave

// "Add to playlist": the user's own playlists, with New playlist… above
// them. It only picks; the host adds the tracks and owns the new-playlist
// dialog, so a track row, the queue and a whole album share one picker.
Popup {
    id: picker
    objectName: "playlistPicker"
    anchors.centerIn: Overlay.overlay
    width: 340
    modal: true
    // Dims the app behind, as the queue panel does. Fusion's own is faint.
    Overlay.modal: Rectangle { color: Theme.scrim }
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: 0

    // The track ids the pick is for.
    property var trackIds: []
    // Every playlist on offer, and the words typed into the search field.
    property var playlists: []
    property string query: ""
    // uuid -> true for a playlist that holds every track already. Replaced,
    // not changed in place, so the rows' bindings see it.
    property var held: ({})
    // Bumped on every open, so an answer about the last open is dropped.
    property int generation: 0

    signal chosen(string uuid, string title)
    signal newPlaylistRequested()

    // Only the user's own playlists: Tidal refuses a song for an
    // editorial one or another user's saved here.
    function fillFrom(pls) {
        var mine = []
        for (var i = 0; i < (pls || []).length; i++)
            if (pls[i].editable === true) mine.push(pls[i])
        picker.playlists = mine
        refill()
    }

    // Case and accents do not count, as in Search; see SearchPage.fold().
    function fold(s) {
        if (typeof s !== "string" || s.length === 0) return ""
        var d = (typeof s.normalize === "function") ? s.normalize("NFD") : s
        return d.replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/ß/g, "ss")
    }

    // The rows whose title holds every word typed.
    function refill() {
        var words = fold(picker.query).split(/\s+/).filter(function (w) { return w.length > 0 })
        plPickerModel.clear()
        for (var i = 0; i < picker.playlists.length; i++) {
            var p = picker.playlists[i], hay = fold(p.title)
            if (words.every(function (w) { return hay.indexOf(w) >= 0 })) plPickerModel.append(p)
        }
    }
    onQueryChanged: refill()

    // A row asks once it is drawn, so only playlists on screen are read.
    function askHeld(uuid, numTracks) {
        var gen = picker.generation, ids = picker.trackIds
        Edits.playlistHolds(uuid, numTracks, ids, function (all) {
            if (gen !== picker.generation || !all) return
            var next = Object.assign({}, picker.held)
            next[uuid] = true
            picker.held = next
        })
    }

    // Filled from the bridge's cache, which is paged in at sign-in and
    // kept current. The fetch covers the empty case only: an empty
    // cache cannot be told from one the paging has not reached yet.
    function openFor(ids) {
        picker.trackIds = Array.isArray(ids) ? ids.map(Number) : [Number(ids)]
        picker.generation++
        picker.held = ({})
        picker.playlists = []
        picker.query = ""
        searchField.text = ""
        plPickerModel.clear()
        open()
        // Typing goes straight into the search, as in Spotify's picker.
        searchField.takeFocus()

        var cached = bridge.getUserPlaylists()
        if (cached && cached.length > 0) { fillFrom(cached); return }

        bridge.fetchUserPlaylists(function(pls, err) {
            fillFrom(pls)
        }, 50, 0)
    }

    function choose(uuid, title) {
        picker.close()
        picker.chosen(uuid, title)
    }

    background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusLarge }

    Column {
        width: parent.width

        Item {
            width: parent.width
            height: 52
            Text {
                anchors.left: parent.left; anchors.leftMargin: Theme.space4
                anchors.verticalCenter: parent.verticalCenter
                text: qsTranslate("TrackRow", "Add to playlist")
                color: Theme.textPrimary; font.pixelSize: Theme.fontTitle; font.bold: true
            }
            // ── the way out ──────────────────────────────────────────────
            Item {
                id: pickerClose
                objectName: "pickerCloseButton"
                anchors.right: parent.right; anchors.rightMargin: Theme.space3
                anchors.verticalCenter: parent.verticalCenter
                width: 32
                height: 32
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: qsTranslate("NewPlaylistDialog", "Close", "button, closes the dialog")
                Accessible.onPressAction: picker.close()
                Keys.onReturnPressed: picker.close()
                Keys.onEnterPressed:  picker.close()
                Keys.onSpacePressed:  picker.close()

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusMedium
                    color: "transparent"
                    border.width: pickerClose.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.centerIn: parent
                    name: "x"
                    width: 14; height: 14
                    color: pickerClose.activeFocus ? Theme.accentText
                         : pickerCloseHov.hovered ? Theme.textPrimary
                         : Theme.textSec
                }
                HoverHandler { id: pickerCloseHov; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: picker.close() }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Theme.border }

        // ── finding one by name, first, as Spotify's "Find a playlist" ───
        Item {
            width: parent.width
            height: searchField.implicitHeight + 2 * Theme.space2
            SearchBar {
                id: searchField
                objectName: "pickerSearchField"
                anchors.left: parent.left; anchors.right: parent.right
                anchors.margins: Theme.space3
                anchors.verticalCenter: parent.verticalCenter
                placeholder: qsTr("Find a playlist", "search field in the Add to playlist picker")
                onEmptyEscape: picker.close()
                onTextEdited: (txt) => { picker.query = txt }
                // Return picks the one row the words leave.
                onSubmitted: if (plPickerModel.count === 1)
                                 picker.choose(plPickerModel.get(0).uuid, plPickerModel.get(0).title)
            }
        }

        // ── "New playlist…", above the list it adds to ───────────────────
        // First in the popup: the list underneath scrolls, and a row at the
        // bottom of a scrolling list is rarely seen.
        Item {
            id: pickerNewRow
            objectName: "pickerNewPlaylistRow"
            width: parent.width
            height: 44
            activeFocusOnTab: true
            Keys.onReturnPressed: picker.newPlaylistRequested()
            Keys.onEnterPressed:  picker.newPlaylistRequested()
            Keys.onSpacePressed:  picker.newPlaylistRequested()
            Accessible.role: Accessible.Button
            Accessible.name: pickerNewLabel.text
            Accessible.onPressAction: picker.newPlaylistRequested()

            Rectangle {
                anchors.fill: parent
                anchors.margins: Theme.space1
                radius: Theme.radiusMedium
                color: newPlHov.hovered ? Theme.hoverFill : "transparent"
                border.width: pickerNewRow.activeFocus ? 2 : 0
                border.color: Theme.accent

                HoverHandler { id: newPlHov; cursorShape: Qt.PointingHandCursor }
                TapHandler  { onTapped: picker.newPlaylistRequested() }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space3
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space3
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space3

                    // An outlined tile the size of the artwork below, so the
                    // labels line up, and plainly not a cover.
                    Rectangle {
                        width: 28
                        height: 28
                        radius: Theme.radiusSmall
                        color: "transparent"
                        border.width: 1
                        border.color: newPlHov.hovered ? Theme.accent : Theme.border
                        VectorIcon {
                            anchors.centerIn: parent
                            name: "plus"
                            width: 13
                            height: 13
                            color: newPlHov.hovered ? Theme.accentText : Theme.textDim
                        }
                    }
                    Text {
                        id: pickerNewLabel
                        objectName: "pickerNewPlaylistLabel"
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTranslate("TrackRow", "New playlist…")
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontMeta
                        elide: Text.ElideRight
                    }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.border }

        ListView {
            id: plPickerList
            objectName: "pickerPlaylistList"
            width: parent.width
            height: Math.min(contentHeight, 300)
            clip: true
            model: ListModel { id: plPickerModel }
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Item {
                id: pickRow
                width: plPickerList.width
                height: 44
                function choose() { picker.choose(model.uuid, model.title) }
                // Holds every track already: Spotify's tick, and words for it.
                readonly property bool holds: picker.held[model.uuid] === true
                Component.onCompleted: picker.askHeld(model.uuid, model.numTracks)
                // One tab stop for the list, the current row; the ListView
                // walks it with Up and Down.
                activeFocusOnTab: activeFocus || ListView.isCurrentItem || plPickerList.currentIndex < 0
                Keys.onReturnPressed: choose()
                Keys.onEnterPressed:  choose()
                Keys.onSpacePressed:  choose()
                Accessible.role: Accessible.ListItem
                Accessible.name: model.title
                Accessible.description: holds ? heldText.text : ""
                Accessible.onPressAction: choose()
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: Theme.space1
                    radius: Theme.radiusMedium
                    color: plHov2.hovered ? Theme.hoverFill : "transparent"
                    border.width: pickRow.activeFocus ? 2 : 0
                    border.color: Theme.accent
                    HoverHandler { id: plHov2 }
                    TapHandler { onTapped: pickRow.choose() }
                    VectorIcon {
                        id: heldMark
                        objectName: "pickerRowHeldMark"
                        visible: pickRow.holds
                        anchors.right: parent.right; anchors.rightMargin: Theme.space3
                        anchors.verticalCenter: parent.verticalCenter
                        name: "check"
                        width: 16; height: 16
                        color: Theme.accentText
                    }
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: Theme.space3
                        anchors.right: heldMark.left; anchors.rightMargin: Theme.space2
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.space3
                        // 28px box, decoded at twice that.
                        CoverArt {
                            width: 28; height: 28; color: Theme.surface
                            source: model.coverUrl || ""
                            glyph: "playlist"
                            decodeSize: Qt.size(56, 56)
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spaceHalf
                            Text {
                                objectName: "pickerRowTitle"
                                text: model.title; color: Theme.textPrimary; font.pixelSize: Theme.fontMeta
                            }
                            // Named so a test can read what the row actually draws.
                            Row {
                                spacing: Theme.space1
                                Text {
                                    objectName: "pickerRowTrackCount"
                                    text: qsTranslate("TrackRow", "%Ln track(s)", "", model.numTracks)
                                    color: Theme.textSec; font.pixelSize: Theme.fontMicro
                                }
                                Text {
                                    visible: pickRow.holds
                                    text: "·"
                                    color: Theme.textSec; font.pixelSize: Theme.fontMicro
                                }
                                Text {
                                    id: heldText
                                    objectName: "pickerRowHeldText"
                                    visible: pickRow.holds
                                    text: picker.trackIds.length > 1
                                          ? qsTr("Has all of these already", "picker row: the playlist holds every track being added")
                                          : qsTr("Has this track already", "picker row: the playlist holds the track being added")
                                    color: Theme.accentText; font.pixelSize: Theme.fontMicro
                                }
                            }
                        }
                    }
                }
            }
        }

        Item { width: parent.width; height: Theme.space2 }
    }
}
