import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import TidalWave

// The one dialog behind every way of making a playlist. The sidebar's
// library header, the Collection page's Playlists tab and the track
// picker's new-playlist row open it and differ only in what they do with
// the answer: a caller handles playlistCreated and nothing else.
Popup {
    id: root
    objectName: "newPlaylistDialog"

    // ── what this talks to ───────────────────────────────────────────────
    // The object carrying createPlaylist(title, cb). Reached through `typeof`
    // because a host may install no bridge, and an unqualified name that is
    // not there is a ReferenceError. A test hands in one that fails on purpose.
    property var createSource: (typeof bridge !== "undefined") ? bridge : null

    // ── the three things that can be wrong with a name ───────────────────
    // Empty and whitespace-only are one case once the title is trimmed.
    // Over-long is stopped at the keyboard by maximumLength on the field.
    property int maxTitleLength: 100
    // How close to the cap the counter appears. Under this it would be noise
    // on a two-word name.
    readonly property int counterShowsFrom: Math.max(1, maxTitleLength - 20)

    // A request is out. The field goes read-only, both buttons go quiet and
    // the close policy drops every way out, so the callback never writes to a
    // dialog the user has left.
    property bool busy: false

    // Shown under the field in Theme.red. Not a toast: the dialog stays open
    // on a failure with the name still in the field, ready to retry.
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
        // Reachable by pressing Return on an empty field, where the button
        // is already dark. Return must not silently do nothing.
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
            // Two failures. An error string is the ordinary one; a success
            // with no uuid parsed to nothing, and the caller could not
            // navigate to it.
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
    // Reparented to the window overlay. anchors.centerIn alone only positions
    // against it: `parent` would stay the opener, and the width clamp below
    // would read the opener's width.
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

        // The heading and the way out, on one line.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                objectName: "newPlaylistTitle"
                Layout.fillWidth: true
                text: qsTr("New playlist")
                color: Theme.textPrimary
                font.pixelSize: 16
                font.bold: true
                elide: Text.ElideRight
            }

            Item {
                id: dialogClose
                objectName: "newPlaylistClose"
                Layout.preferredWidth: 26
                Layout.preferredHeight: 26
                Layout.alignment: Qt.AlignVCenter
                // Disabled while a create is in flight, like Cancel and Escape.
                // `enabled: false` stops the handlers and takes the item out of
                // the tab order; the opacity only shows it.
                enabled: !root.busy
                opacity: enabled ? 1 : 0.45
                Behavior on opacity { NumberAnimation { duration: Theme.dur(110) } }
                activeFocusOnTab: enabled
                Keys.onReturnPressed: root.close()
                Keys.onEnterPressed:  root.close()
                Keys.onSpacePressed:  root.close()

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusButton
                    color: "transparent"
                    border.width: dialogClose.activeFocus ? 2 : 0
                    border.color: Theme.accent
                }
                VectorIcon {
                    anchors.centerIn: parent
                    name: "x"
                    width: 14; height: 14; strokeWidth: 1.8
                    color: dialogClose.activeFocus ? Theme.accent
                         : dialogCloseHov.hovered ? Theme.textPrimary
                         : Theme.textSec
                }
                HoverHandler { id: dialogCloseHov; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.close() }
            }
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
                // Applies to a paste as well as to typing.
                maximumLength: root.maxTitleLength
                // Nothing may be typed into a name that is already on its way
                // to the server.
                readOnly: root.busy

                // Typing answers the complaint, so the complaint goes away.
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

            // PillButton draws no disabled state, so the dimming is here.
            // `enabled: false` stops the tap handler and takes the button out
            // of the tab order; the opacity only shows it.
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
