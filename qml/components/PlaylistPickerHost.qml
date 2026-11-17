import QtQuick
import QtQuick.Controls
import TidalWave

// The window's own playlist picker, for everything that is not a single
// track row: the queue's rows, an album, the whole queue. It answers
// Edits.pickPlaylist(), adds the tracks and owns the new-playlist dialog.
Item {
    id: host

    readonly property alias picker: picker
    readonly property alias newPlaylistDialog: newPlaylist
    // The tracks the open pick is for, as track maps.
    property var tracks: []
    // What the add said last, so a test can read it.
    property string lastConfirmation: ""

    function pick(list) {
        host.tracks = list || []
        if (host.tracks.length === 0) return
        picker.openFor(host.tracks.map(function (t) { return Number(t.id) }))
    }

    function addTo(uuid, title) {
        var ids = host.tracks.map(function (t) { return Number(t.id) })
        Edits.addTracksToPlaylist(uuid, title, ids, function (ok, message) {
            host.lastConfirmation = message
        })
    }

    Connections {
        target: Edits
        function onPlaylistPickRequested(list) { host.pick(list) }
    }

    PlaylistPicker {
        id: picker
        onChosen: (uuid, title) => host.addTo(uuid, title)
        onNewPlaylistRequested: newPlaylist.openEmpty()
    }

    NewPlaylistDialog {
        id: newPlaylist
        objectName: "pickerNewPlaylistDialog"
        onPlaylistCreated: function (playlist) {
            var uuid = (playlist && playlist.uuid) ? String(playlist.uuid) : ""
            if (uuid.length > 0) host.addTo(uuid, playlist.title || "")
            picker.close()
        }
    }
}
