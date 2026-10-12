// A track Tidal does not stream is played from its twin, a track with another
// id. The list the user started it from still holds the row it was given, and
// that row is the one shown as playing.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TwinRow"
    when: windowShown
    // TestCase declares visible: false, which would make every child report
    // visible == false.
    visible: true
    width: 1280
    height: 900

    // ── fixtures ─────────────────────────────────────────────────────────

    // The shape TidalBridge::trackToMap() produces.
    function rowOf(id, title) {
        return {
            id: id, title: title, artists: "Erste Interpretin", artistId: 7,
            albumTitle: "Ein Album", albumId: 42, coverUrl: "", coverUrl80: "",
            duration: 247, durationStr: "4:07"
        }
    }

    function listRows() {
        return [ rowOf(8000, "Winterabend"), rowOf(8001, "Nebelmeer"), rowOf(8002, "Morgenrot") ]
    }

    // The queue row the player makes of a row once it found the twin.
    function twinOf(row) {
        var t = rowOf(9001, row.title)
        t.albumTitle  = "Ein anderes Album"
        t.albumId     = 43
        t.standsForId = row.id
        return t
    }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        bridge.setPlaylistTracksForTest(listRows())
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
        player.setPlayingForTest(false)
    }

    function cleanup() {
        bridge.resetForTest()
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
        player.setPlayingForTest(false)
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }

    Component {
        id: pageHost
        Window {
            property alias pane: pane
            function navigate(page, params) { }
            width: 1200
            height: 900
            Item { id: pane; anchors.fill: parent }
        }
    }

    function showPlaylist() {
        var host = createTemporaryObject(pageHost, testCase)
        verify(host, "the host window was not created")
        host.visible = true
        frame(host.contentItem)
        var page = createTemporaryObject(playlistC, host.pane, {
            playlistUuid: "p-tape", playlistTitle: "Tape", playlistType: "USER"
        })
        verify(page, "PlaylistPage did not load")
        wait(1)
        frame(host.contentItem)
        compare(page.tracks.length, 3, "the page did not load its three tracks")
        return host
    }

    // The page's track rows by their place in the list. A TrackRow is known
    // by the signal only it has.
    function trackRows(host) {
        var found = []
        function walk(it) {
            if (!it) return
            if (it.removeFromPlaylistRequested !== undefined && it.trackItemIndex >= 0)
                found[it.trackItemIndex] = it
            for (var i = 0; i < it.children.length; ++i) walk(it.children[i])
        }
        walk(host.contentItem)
        return found
    }

    // Whether the row draws itself as the playing one: the bars in place of
    // its number and the title in the accent colour.
    function shownAsPlaying(row) {
        var bars  = findByName(row, "trackRowPlayingIndicator")
        var title = findByName(row, "trackTitle")
        verify(bars && title, "the row has no playing indicator or no title")
        return bars.visible && Qt.colorEqual(title.color, Theme.accent)
    }

    // ── the tests ────────────────────────────────────────────────────────

    function test_the_row_that_was_picked_is_shown_as_playing_while_its_twin_plays() {
        var host = showPlaylist()
        var rows = trackRows(host)
        compare(rows.length, 3, "the page built no row for each track")

        rows[1].playRequested()
        compare(player.currentTrack.id, 8001)
        tryVerify(function () { return shownAsPlaying(rows[1]) }, 2000,
                  "a row that plays as itself is not shown as playing")

        // The player found the twin and put it in the row's place.
        var queue = listRows()
        queue[1] = twinOf(queue[1])
        player.setQueueForTest(queue, 1)
        player.setCurrentTrackForTest(queue[1])
        wait(1)

        verify(shownAsPlaying(rows[1]), "the row whose twin plays is not shown as playing")
        verify(!shownAsPlaying(rows[0]), "the row before it is shown as playing")
        verify(!shownAsPlaying(rows[2]), "the row after it is shown as playing")

        player.setPlayingForTest(false)
        wait(1)
        verify(!shownAsPlaying(rows[1]), "the row is shown as playing while nothing plays")
    }

    // A track that stands for no other marks no row but its own, and a
    // track that stands for a row marks no row with another id.
    function test_only_the_row_the_twin_stands_for_is_marked() {
        var host = showPlaylist()
        var rows = trackRows(host)
        compare(rows.length, 3, "the page built no row for each track")

        var stranger = rowOf(9001, "Anderswo")
        player.setCurrentTrackForTest(stranger)
        player.setPlayingForTest(true)
        wait(1)
        for (var i = 0; i < 3; ++i)
            verify(!shownAsPlaying(rows[i]), "row " + i + " is shown as playing for a track of another list")

        stranger.standsForId = 7999
        player.setCurrentTrackForTest(stranger)
        wait(1)
        for (var k = 0; k < 3; ++k)
            verify(!shownAsPlaying(rows[k]), "row " + k + " is shown as playing for a twin of another row")
    }
}
