import QtQuick
import QtQuick.Shapes
import TidalWave

// The hero's download for a whole album or playlist: one button that starts,
// cancels or opens the folder, a ring for how far the run has got, and a line
// saying where it stands. The run itself lives in the downloader, so leaving
// the page and coming back shows it again.
Row {
    id: root
    objectName: "collectionDownload"

    property string kind: ""          // "album" or "playlist"
    property string itemId: ""
    // The folder made for it, e.g. "Artist - Album".
    property string folderName: ""
    // function (cb): hands cb every track, as the pages' allTracks() do.
    property var    trackSource: null

    readonly property var dl: typeof downloader !== "undefined" ? downloader : null
    readonly property string key: kind + ":" + itemId
    property var st: ({ state: "idle" })
    readonly property string phase: st.state || "idle"
    readonly property bool busy: phase === "running" || phase === "waiting"
    readonly property int saved: st.saved || 0
    readonly property int total: st.total || 0
    readonly property bool opensFolder: phase === "done" && saved > 0

    spacing: Theme.space3

    function refresh() {
        root.st = (root.dl && root.itemId.length > 0)
            ? root.dl.collectionState(root.kind, root.itemId) : ({ state: "idle" })
    }
    onKeyChanged: refresh()
    Component.onCompleted: refresh()

    Connections {
        target: root.dl
        function onCollectionChanged(k) { if (k === root.key) root.refresh() }
    }

    function activate() {
        if (!root.dl || root.itemId.length === 0) return
        if (root.busy) { root.dl.cancelCollection(root.kind, root.itemId); return }
        if (root.opensFolder) { root.dl.showInFolder(root.st.folder); return }
        if (!root.trackSource) return
        root.trackSource(function (tracks) {
            root.dl.downloadCollection(root.kind, root.itemId, root.folderName, tracks)
        })
    }

    readonly property string buttonLabel:
        root.busy ? qsTr("Cancel download")
        : root.opensFolder ? qsTr("Show in folder", "opens the file manager at a downloaded album or playlist")
        : root.kind === "album" ? qsTr("Download album")
        : qsTr("Download playlist")

    readonly property string statusText: {
        var s = root.st
        switch (root.phase) {
        case "waiting":
            return qsTr("Waiting for the other download to finish")
        case "running":
            return qsTr("Downloading %1 of %2").arg(s.position).arg(s.total)
        case "cancelled":
            return qsTr("Download cancelled. %1 of %2 saved.").arg(s.saved).arg(s.total)
        case "paused":
            // Tidal's wait, rounded up to whole minutes.
            return qsTr("Tidal asked for a pause. %1 of %2 saved. Try again in about %Ln minute(s).",
                        "", Math.max(1, Math.ceil((s.pauseSecs || 0) / 60)))
                       .arg(s.saved).arg(s.total)
        case "done":
            if (s.saved === 0)
                return qsTr("None of the tracks could be downloaded. %1").arg(s.error || "")
            if (s.failed > 0)
                return qsTr("%1 of %2 saved. %Ln track(s) could not be downloaded.", "", s.failed)
                           .arg(s.saved).arg(s.total)
            return qsTr("%Ln track(s) saved", "", s.saved)
        }
        return ""
    }

    Item {
        objectName: "collectionDownloadButton"
        width: button.implicitWidth
        height: button.implicitHeight

        IconButton {
            id: button
            anchors.centerIn: parent
            icon: root.busy ? "x" : root.opensFolder ? "check" : "download"
            label: root.buttonLabel
            active: root.opensFolder
            size: 20
            pad: Theme.space5
            backed: true
            onClicked: root.activate()
        }

        // How far the whole run has got, drawn round the button.
        Shape {
            objectName: "collectionDownloadProgress"
            anchors.fill: parent
            visible: root.phase === "running" && (root.st.progress || 0) > 0
            antialiasing: true
            ShapePath {
                fillColor: "transparent"
                strokeColor: Theme.accent
                strokeWidth: waitRing.thickness
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: button.width / 2
                    centerY: button.height / 2
                    radiusX: (button.width - waitRing.thickness) / 2
                    radiusY: (button.height - waitRing.thickness) / 2
                    startAngle: -90
                    sweepAngle: 360 * Math.min(1, root.st.progress || 0)
                }
            }
        }
        // Before the first segment lands, and while waiting its turn.
        BusyRing {
            id: waitRing
            anchors.fill: parent
            running: visible
            visible: root.busy && !((root.st.progress || 0) > 0 && root.phase === "running")
        }
    }

    Text {
        objectName: "collectionDownloadStatus"
        anchors.verticalCenter: parent.verticalCenter
        visible: text.length > 0
        width: Math.min(implicitWidth, 360)
        text: root.statusText
        color: root.phase === "done" && root.saved === 0 ? Theme.redText : Theme.textSec
        font.pixelSize: Theme.fontMeta
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
    }
}
