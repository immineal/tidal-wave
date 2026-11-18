// A track row's download: a failure says why over the red button, as the
// player bar does for a track that would not load, and a saved file can be
// shown in its folder. The downloader is the stub from tests/TestStubs.h.

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TrackRowDownload"
    when: windowShown
    visible: true
    width: 900
    height: 300

    readonly property int trackId: 830001

    Component { id: rowC; TrackRow { width: 700 } }

    function init() {
        app.setReducedMotionForTest(true)
        downloader.resetForTest()
    }

    function makeRow() {
        var track = { id: testCase.trackId, title: "Ein Titel", artists: "Eine Band",
                      artistId: 7, albumTitle: "Ein Album", albumId: 42, coverUrl: "",
                      coverUrl80: "", duration: 200 }
        var row = createTemporaryObject(rowC, testCase, {
            trackData: track, title: track.title, artists: track.artists
        })
        verify(row, "TrackRow did not load")
        waitForRendering(row)
        return row
    }

    function menuItemNamed(menu, objectName) {
        for (var i = 0; i < menu.count; ++i) {
            var it = menu.itemAt(i)
            if (it && it.objectName === objectName) return it
        }
        return null
    }

    function test_a_failed_download_says_why() {
        var row = makeRow()
        var button = findChild(row, "trackDownloadButton")
        verify(button, "the row has no download button")
        var reason = "Could not download the audio for this track. Host not found"
        downloader.emitDownloadErrorForTest(testCase.trackId, reason)
        compare(row.dlState, "error")
        tryVerify(function () { return button.ToolTip.visible }, 2000,
                  "the failure was stored and never shown")
        compare(button.ToolTip.toolTip.text, reason)
        // Up long enough to read, and taken down with the error state.
        wait(3500)
        verify(button.ToolTip.visible, "the reason went away before it could be read")
        tryVerify(function () { return row.dlState === "idle" }, 5000, "the error state never ended")
        tryVerify(function () { return !button.ToolTip.visible }, 2000,
                  "the reason outlived the error state")
    }

    function test_a_saved_track_can_be_shown_in_its_folder() {
        var row = makeRow()
        row.openMenu()
        var entry = menuItemNamed(row.rowMenu, "showInFolderMenuItem")
        verify(entry, "the row menu has no Show in folder entry")
        verify(!entry.visible, "Show in folder is offered before anything was saved")
        row.rowMenu.close()

        var path = "/home/someone/Music/Eine Band - Ein Titel.flac"
        downloader.emitDownloadFinishedForTest(testCase.trackId, path)
        compare(row.dlState, "done")

        // The tick opens the folder while it is up.
        var button = findChild(row, "trackDownloadButton")
        mouseClick(button, button.width / 2, button.height / 2)
        compare(downloader.shownInFolderForTest(), [path])

        row.openMenu()
        entry = menuItemNamed(row.rowMenu, "showInFolderMenuItem")
        verify(entry.visible, "Show in folder is not offered after the save")
        entry.triggered()
        row.rowMenu.close()
        compare(downloader.shownInFolderForTest(), [path, path])
    }

    // A recycled delegate asks the downloader, so the entry survives a scroll.
    function test_a_new_row_for_a_saved_track_still_offers_its_folder() {
        var path = "/home/someone/Music/x.flac"
        downloader.emitDownloadFinishedForTest(testCase.trackId, path)
        var row = makeRow()
        compare(row.savedFile, path)
    }
}
