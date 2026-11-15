import QtQuick
import TidalWave

// Asks before a playlist is deleted from the account, then deletes it. The
// bridge's playlistDeleted takes it out of the sidebar, the collection and
// the history, so a host does nothing with the answer.
ConfirmDialog {
    id: root
    objectName: "deletePlaylistDialog"

    // The object carrying deletePlaylist(uuid, cb). See NewPlaylistDialog's
    // createSource for the `typeof`.
    property var deleteSource: (typeof bridge !== "undefined") ? bridge : null

    property string uuid: ""
    property string title: ""

    heading: qsTr("Delete playlist?")
    text: qsTr("“%1” will be deleted from your Tidal account on every device. This cannot be undone.")
          .arg(root.title)
    confirmLabel: qsTr("Delete", "verb, the button that deletes the playlist")
    busyLabel: qsTr("Deleting…")

    function askFor(uuid, title) {
        root.uuid  = uuid ? "" + uuid : ""
        root.title = title || ""
        root.ask()
    }

    onConfirmed: {
        if (root.uuid.length === 0 || !root.deleteSource
                || typeof root.deleteSource.deletePlaylist !== "function") {
            root.errorText = qsTr("Could not delete the playlist.")
            return
        }
        root.busy      = true
        root.errorText = ""
        root.deleteSource.deletePlaylist(root.uuid, function (ok) {
            root.busy = false
            if (ok !== true) {
                root.errorText = qsTr("Could not delete the playlist.")
                return
            }
            root.close()
        })
    }
}
