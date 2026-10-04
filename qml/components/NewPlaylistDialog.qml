import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// "New playlist" — the one dialog behind every way of making one.
//
// Creating a playlist was the only thing in the account the app could not do:
// TidalBridge::createPlaylist, the signal it raises and LibraryIndex::addPlaylist
// on the far end have all been in place and tested for a while, with nothing in
// qml/ ever calling them. This is the caller.
//
// Three places open it — the sidebar's library header, the Collection page's
// Playlists tab, and the "New playlist…" row on a track's "Add to playlist"
// picker — and they differ only in what they do with the answer. The field, the
// three validations, the in-flight state and the error line are therefore here
// once rather than three times; a caller handles `playlistCreated` and nothing
// else.
//
// Shaped after the two dialogs already in the app, PlaylistPage's Edit-playlist
// popup and SettingsPanel: centred on the window overlay, modal, Escape or a
// click outside to leave, Theme tokens for every colour, radius and duration.
Popup {
    id: root
    objectName: "newPlaylistDialog"

    // ── what this talks to ───────────────────────────────────────────────
    //
    // The object carrying createPlaylist(title, cb). Held in a property and
    // reached through `typeof` rather than used inline, the way PlayerBar's
    // OutputPicker holds `deviceSource`: a host may install no bridge at all,
    // an unqualified name that is not there is a ReferenceError rather than
    // undefined (tests/tst_firstrun.cpp fails on any QML warning), and a test
    // needs a way to hand in a bridge that fails on purpose.
    property var createSource: (typeof bridge !== "undefined") ? bridge : null

    // ── the three things that can be wrong with a name ───────────────────
    //
    // Empty and whitespace-only are the same case once the title is trimmed,
    // and the Create button is dark for both. Over-long is stopped at the
    // keyboard instead: `maximumLength` on the field below means there is no
    // way to put a title in that the server would refuse, and the counter says
    // why the typing stopped rather than leaving it a mystery.
    property int maxTitleLength: 100
    // How close to the cap the counter appears. Under this it would be noise
    // on a two-word name.
    readonly property int counterShowsFrom: Math.max(1, maxTitleLength - 20)

    // A request is out. The field goes read-only, both buttons go quiet, and
    // the close policy drops every way out of here: a dialog that can be
    // dismissed under a call that is still going to answer leaves the callback
    // writing to a dialog the user has already left, and - worse - leaves them
    // unable to tell whether the playlist was made.
    property bool busy: false

    // Shown under the field in Theme.red. Empty is "nothing is wrong yet".
    // Deliberately not a toast: the dialog stays open on a failure with the
    // name still in the field, so the answer to a failed create is one click
    // and not retyping it.
    property string errorText: ""

    readonly property string trimmedTitle: nameField.text.trim()
    readonly property bool   canSubmit: !busy && trimmedTitle.length > 0

    // The playlist the server made, as TidalBridge::playlistToMap spells it:
    // {uuid, title, description, numTracks, duration, coverUrl, type}.
    signal playlistCreated(var playlist)

    // ── opening and submitting ───────────────────────────────────────────

    // Always from a blank field and a blank error. Reopening onto the last
    // failed attempt would be a dialog that remembers a mistake.
    function openEmpty() {
        nameField.text = ""
        root.errorText = ""
        root.busy      = false
        root.open()
    }

    function submit() {
        if (root.busy) return

        const title = root.trimmedTitle
        // Reachable by pressing Return on an empty or all-spaces field; the
        // button is already dark. Both ways in have to say the same thing,
        // because a Return that silently does nothing reads as a broken
        // dialog.
        if (title.length === 0) {
            root.errorText = qsTr("Enter a name for the playlist.")
            return
        }
        if (!root.createSource || typeof root.createSource.createPlaylist !== "function") {
            root.errorText = qsTr("Could not create the playlist.")
            return
        }

        root.busy      = true
        root.errorText = ""
        root.createSource.createPlaylist(title, function (playlist, err) {
            root.busy = false
            const uuid = (playlist && playlist.uuid) ? String(playlist.uuid) : ""
            // Two failures, not one. An error string is the ordinary case; a
            // success carrying no uuid is the response that parsed to nothing,
            // and treating it as a win would announce a playlist that is not
            // there and hand the caller an id it cannot navigate to. The
            // bridge guards its own list the same way.
            if ((err && String(err).length > 0) || uuid.length === 0) {
                root.errorText = (err && String(err).length > 0)
                    ? qsTr("Could not create the playlist: %1").arg(err)
                    : qsTr("Could not create the playlist.")
                return
            }
            root.playlistCreated(playlist)
            root.close()
        })
    }

    // ── the popup itself ─────────────────────────────────────────────────
    //
    // Reparented to the window overlay rather than left on whatever opened it.
    // anchors.centerIn alone only *positions* against the overlay - `parent`
    // would stay the sidebar, and the clamp below would then be reading a
    // 220px sidebar. SettingsPanel carries the same two lines for the same
    // reason.
    parent: Overlay.overlay
    anchors.centerIn: parent
    // Clamped to the window, which at the 640px minimum is the binding that
    // decides the width.
    width: Math.min(380, (parent ? parent.width : 380) - 48)
    modal: true
    focus: true
    closePolicy: root.busy
                 ? Popup.NoAutoClose
                 : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
    padding: 20

    background: Rectangle {
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusPopup
    }

    // The field is the only thing in here anyone wants, so it takes the focus
    // and the user types straight away.
    onOpened: nameField.forceActiveFocus()

    contentItem: ColumnLayout {
        spacing: 12

        Text {
            objectName: "newPlaylistTitle"
            Layout.fillWidth: true
            text: qsTr("New playlist")
            color: Theme.textPrimary
            font.pixelSize: 16
            font.bold: true
            elide: Text.ElideRight
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.border
        }

        // ── the name field ───────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            radius: Theme.radiusField
            color: Theme.surface
            border.width: 1
            border.color: nameField.activeFocus ? Theme.accent : Theme.border

            TextInput {
                id: nameField
                objectName: "newPlaylistField"
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                color: Theme.textPrimary
                font.pixelSize: 14
                clip: true
                selectByMouse: true
                selectionColor: Theme.accent
                selectedTextColor: Theme.accentInk
                verticalAlignment: TextInput.AlignVCenter
                // The over-long case, stopped before it can be submitted.
                // Applies to a paste as well as to typing, which is the way a
                // 4000-character title actually arrives.
                maximumLength: root.maxTitleLength
                // Nothing may be typed into a name that is already on its way
                // to the server.
                readOnly: root.busy

                // Typing is the user answering the complaint, so the complaint
                // goes away. Leaving it up while the field is being corrected
                // is how an error line comes to be ignored.
                onTextChanged: if (root.errorText.length > 0) root.errorText = ""

                Keys.onReturnPressed: root.submit()
                Keys.onEnterPressed:  root.submit()
            }

            Text {
                objectName: "newPlaylistPlaceholder"
                anchors.fill: nameField
                visible: nameField.text.length === 0
                text: qsTr("Playlist name")
                color: Theme.textDim
                font.pixelSize: 14
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }
        }

        // ── the counter, and the error ───────────────────────────────────
        //
        // One row, because they never want to be read at the same time and
        // two stacked lines would make the dialog jump twice.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                objectName: "newPlaylistError"
                Layout.fillWidth: true
                visible: root.errorText.length > 0
                text: root.errorText
                color: Theme.red
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            // Holds the row's height while there is no error, so the dialog
            // does not grow by a line the first time something goes wrong.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                visible: root.errorText.length === 0
            }

            Text {
                objectName: "newPlaylistCounter"
                visible: nameField.text.length >= root.counterShowsFrom
                text: qsTr("%1/%2", "characters typed out of the maximum")
                        .arg(nameField.text.length)
                        .arg(root.maxTitleLength)
                color: nameField.text.length >= root.maxTitleLength
                       ? Theme.red : Theme.textDim
                font.pixelSize: 12
            }
        }

        // ── the two buttons ──────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 10

            Item { Layout.fillWidth: true }

            // PillButton draws no disabled state of its own, so the dimming is
            // here. `enabled: false` on an Item is what actually stops the tap
            // handler and takes it out of the tab order; the opacity only says
            // so.
            PillButton {
                objectName: "newPlaylistCancel"
                text: qsTr("Cancel")
                accent: false
                enabled: !root.busy
                opacity: enabled ? 1 : 0.45
                Behavior on opacity { NumberAnimation { duration: Theme.dur(110) } }
                Layout.preferredWidth:  implicitWidth
                Layout.preferredHeight: implicitHeight
                onClicked: root.close()
            }

            PillButton {
                objectName: "newPlaylistCreate"
                // The in-flight state says so on the button that started it,
                // which is where the user is looking. A spinner somewhere else
                // in the dialog would be a second thing to find.
                text: root.busy
                      ? qsTr("Creating…")
                      : qsTr("Create", "verb, the button that creates the playlist")
                accent: true
                enabled: root.canSubmit
                opacity: enabled ? 1 : 0.45
                Behavior on opacity { NumberAnimation { duration: Theme.dur(110) } }
                Layout.preferredWidth:  implicitWidth
                Layout.preferredHeight: implicitHeight
                onClicked: root.submit()
            }
        }
    }
}
