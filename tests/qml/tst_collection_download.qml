// Downloading a whole album or playlist from its hero: the button starts the
// run, cancels it while it goes, and opens the folder once it is done, and the
// line beside it says where the run stands. The downloader is the stub from
// tests/TestStubs.h, whose state the test sets.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CollectionDownload"
    when: windowShown
    visible: true
    width: 900
    height: 300

    function tracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 9400 + i, title: "Titel " + i, artists: "Erika Mustermann", duration: 200 })
        return out
    }

    Component {
        id: actionC
        DownloadAction {
            kind: "album"
            itemId: "7788"
            folderName: "Erika Mustermann - Nachtfahrt"
            trackSource: function (cb) { cb(testCase.tracks(3)) }
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        downloader.resetForTest()
    }

    function make() {
        var a = createTemporaryObject(actionC, testCase)
        verify(a, "DownloadAction did not load")
        waitForRendering(a)
        return a
    }

    function button(a) { return findChild(a, "collectionDownloadButton").children[0] }
    function status(a) { return findChild(a, "collectionDownloadStatus") }

    function test_the_button_starts_the_run_with_every_track() {
        var a = make()
        compare(button(a).label, "Download album")
        verify(!status(a).visible, "an idle download already says something")
        mouseClick(button(a))
        compare(downloader.collectionCallsForTest(), ["download album:7788 3"])
        compare(downloader.collectionTitleForTest(), "Erika Mustermann - Nachtfahrt")
    }

    function test_a_running_download_shows_where_it_is_and_cancels() {
        var a = make()
        downloader.setCollectionStateForTest("album", "7788",
            { state: "running", total: 12, saved: 2, failed: 0, position: 3, progress: 0.2 })
        compare(button(a).label, "Cancel download")
        compare(button(a).icon, "x")
        compare(status(a).text, "Downloading 3 of 12")
        verify(findChild(a, "collectionDownloadProgress").visible, "no ring shows how far it got")
        mouseClick(button(a))
        compare(downloader.collectionCallsForTest(), ["cancel album:7788"])
    }

    function test_a_waiting_download_can_be_cancelled_too() {
        var a = make()
        downloader.setCollectionStateForTest("album", "7788", { state: "waiting", total: 4 })
        compare(button(a).label, "Cancel download")
        compare(status(a).text, "Waiting for the other download to finish")
    }

    function test_a_finished_download_opens_its_folder() {
        var a = make()
        downloader.setCollectionStateForTest("album", "7788",
            { state: "done", total: 3, saved: 3, failed: 0, folder: "/home/someone/Music/Nachtfahrt" })
        compare(button(a).label, "Show in folder")
        // No catalogue is loaded here, so a plural reads as its source.
        verify(status(a).text.indexOf("3 track") === 0, status(a).text)
        mouseClick(button(a))
        compare(downloader.shownInFolderForTest(), ["/home/someone/Music/Nachtfahrt"])
        compare(downloader.collectionCallsForTest(), [])
    }

    function test_the_line_says_how_a_run_ended_data() {
        return [
            { tag: "cancelled", st: { state: "cancelled", total: 12, saved: 4 },
              text: "Download cancelled. 4 of 12 saved.", label: "Download album" },
            { tag: "paused", st: { state: "paused", total: 12, saved: 5, pauseSecs: 1170 },
              text: "Tidal asked for a pause. 5 of 12 saved. Try again in about 20 minute",
              label: "Download album" },
            { tag: "some failed", st: { state: "done", total: 12, saved: 10, failed: 2 },
              text: "10 of 12 saved. 2 track", label: "Show in folder" },
            { tag: "none saved", st: { state: "done", total: 2, saved: 0, failed: 2,
                                       error: "ffmpeg was not found on PATH." },
              text: "None of the tracks could be downloaded. ffmpeg was not found on PATH.",
              label: "Download album" },
        ]
    }

    function test_the_line_says_how_a_run_ended(row) {
        var a = make()
        downloader.setCollectionStateForTest("album", "7788", row.st)
        // Compared from the start: a plural reads as its source here.
        verify(status(a).text.indexOf(row.text) === 0, status(a).text)
        compare(button(a).label, row.label)
    }

    // ── on the pages ────────────────────────────────────────────────────

    Component {
        id: pageHost
        Window {
            width: 1280; height: 800
            function navigate(page, params) {}
            function goBack() {}
        }
    }
    Component { id: albumC;    AlbumPage    { anchors.fill: parent } }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }

    function test_the_album_and_playlist_heroes_offer_it_data() {
        return [
            { tag: "album", c: albumC, props: { albumId: 7788 }, kind: "album", id: "7788" },
            { tag: "playlist", c: playlistC,
              props: { playlistUuid: "0c1d2e3f-aaaa-bbbb-cccc-000000000001", playlistTitle: "Liste" },
              kind: "playlist", id: "0c1d2e3f-aaaa-bbbb-cccc-000000000001" },
        ]
    }

    function test_the_album_and_playlist_heroes_offer_it(row) {
        var host = createTemporaryObject(pageHost, testCase)
        host.visible = true
        var p = createTemporaryObject(row.c, host.contentItem, row.props)
        verify(p, "the page was not created")
        waitForRendering(host.contentItem)
        var a = findChild(p, "collectionDownload")
        verify(a, row.tag + " offers no download in its hero")
        compare(a.kind, row.kind)
        compare(a.itemId, row.id)
        var more = findChild(p, "heroMoreButton")
        verify(more && a.parent === more.parent, "the download is not in the hero's action row")
    }
}
