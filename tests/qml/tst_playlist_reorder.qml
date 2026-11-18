// Reordering a playlist by dragging its rows. Only in the list's own order,
// unfiltered and the user's own; the row moves on Tidal's word, and a view
// that went stale is read again. StubBridge::moveTrackInPlaylist answers.

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "PlaylistReorder"
    when: windowShown
    visible: true
    width: 1200
    height: 900

    readonly property int settleMs: 2000

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 7000 + i, title: "Song " + i, artists: "Kestrel Arcade",
                       albumTitle: "Glass Orchard", durationStr: "3:0" + (i % 10),
                       duration: 180 + i, coverUrl: "", coverUrl80: "", albumId: 42,
                       artistId: 7, addedAt: 1000 - i })
        return out
    }

    function ids(n) {
        var out = []
        for (var i = 0; i < n; ++i) out.push(7000 + i)
        return out
    }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        Edits.clearHistory()
        Edits.retryDelaysMs = [1]
        Toasts.dismiss()
        bridge.setPlaylistTracksForTest(makeTracks(6))
        bridge.setServerPlaylistForTest("p-mine", ids(6))
        bridge.setPlaylistForTest({ uuid: "p-mine", title: "Mine", type: "USER", editable: true })
    }

    function cleanup() {
        Edits.retryDelaysMs = [500, 1000, 2000, 4000]
    }

    Component {
        id: hostC
        Window {
            property alias pane: pane
            function navigate(page, params) { }
            width: 1200
            height: 900
            Item { id: pane; anchors.fill: parent }
        }
    }
    Component { id: pageC; PlaylistPage { anchors.fill: parent } }

    function showPage() {
        var host = createTemporaryObject(hostC, testCase)
        verify(host, "the host window was not created")
        host.visible = true
        verify(waitForRendering(host.contentItem), "the window drew no frame")
        var page = createTemporaryObject(pageC, host.pane,
                                         { playlistUuid: "p-mine", playlistTitle: "Mine" })
        verify(page, "PlaylistPage did not load")
        tryVerify(function () { return page.trackRows.length === 6 && page.playlistEditable },
                  settleMs, "the playlist did not load")
        var list = findByName(page, "playlistTracksList")
        // The rows in view, below the hero.
        list.positionViewAtIndex(0, ListView.Beginning)
        wait(20)
        return { host: host, page: page, list: list }
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findByName(item.children[i], name)
            if (hit) return hit
        }
        return null
    }

    function rowAt(p, i) {
        var r = p.list.itemAtIndex(i)
        verify(r, "row " + i + " was not built")
        return r
    }

    // Presses on row `from` by its number, clear of the artist and album
    // links, drags by `rows` rows and a little past, off the tie at a row's
    // middle, and lets go.
    function drag(p, from, rows, release) {
        var row = rowAt(p, from)
        var at = row.mapToItem(p.host.contentItem, 30, row.height / 2)
        var dy = rows * 52 + (rows > 0 ? 10 : rows < 0 ? -10 : 0)
        mousePress(p.host.contentItem, at.x, at.y)
        var steps = 8
        for (var s = 1; s <= steps; ++s) {
            mouseMove(p.host.contentItem, at.x, at.y + dy * s / steps)
            wait(5)
        }
        if (release !== false) mouseRelease(p.host.contentItem, at.x, at.y + dy)
        return at
    }

    function titles(page) {
        return page.trackRows.list().map(function (t) { return t.title }).join(",")
    }

    // ── a drag moves the row ─────────────────────────────────────────────

    function test_dragging_a_row_down_moves_it() {
        var p = showPage()
        drag(p, 1, 2)
        compare(bridge.movesForTest(), ["1>3"], "the move asked for the wrong places")
        compare(titles(p.page), "Song 0,Song 2,Song 3,Song 1,Song 4,Song 5")
        compare(bridge.serverPlaylistForTest("p-mine"), [7000, 7002, 7003, 7001, 7004, 7005])
    }

    function test_dragging_a_row_up_moves_it() {
        var p = showPage()
        drag(p, 4, -3)
        compare(bridge.movesForTest(), ["4>1"])
        compare(titles(p.page), "Song 0,Song 4,Song 1,Song 2,Song 3,Song 5")
    }

    function test_mid_drag_the_line_shows_where_it_lands() {
        var p = showPage()
        var at = drag(p, 0, 2, false)
        var line = findByName(p.page, "playlistDropIndicator")
        verify(line.visible, "no drop line while dragging")
        compare(p.page.dropTo, 2)
        // Across the rows, a little inside their ends.
        var row = rowAt(p, 1), rx = row.mapToItem(p.page, 0, 0).x
        fuzzyCompare(line.mapToItem(p.page, 0, 0).x, rx + Theme.space2, 0.5, "the line starts off the rows")
        fuzzyCompare(line.width, row.width - 2 * Theme.space2, 0.5, "the line is not as wide as the rows")
        verify(rowAt(p, 0).reordering, "the row is not marked as dragged")
        mouseRelease(p.host.contentItem, at.x, at.y + 2 * 52 + 10)
    }

    function test_a_drag_back_to_its_place_sends_nothing() {
        var p = showPage()
        var at = drag(p, 2, 1, false)
        mouseMove(p.host.contentItem, at.x, at.y)
        wait(5)
        mouseRelease(p.host.contentItem, at.x, at.y)
        compare(bridge.movesForTest(), [], "a drop in place went out")
    }

    // ── only on Tidal's word ─────────────────────────────────────────────

    function test_a_refused_move_leaves_the_rows_and_says_so() {
        var p = showPage()
        bridge.setMoveAnswerForTest("fail")
        drag(p, 0, 2)
        compare(titles(p.page), "Song 0,Song 1,Song 2,Song 3,Song 4,Song 5")
        compare(Toasts.text, "Could not move the track")
    }

    function test_the_row_waits_for_the_answer_and_no_second_drag_starts() {
        var p = showPage()
        bridge.deferMovesForTest(true)
        drag(p, 0, 2)
        compare(titles(p.page), "Song 0,Song 1,Song 2,Song 3,Song 4,Song 5",
                "the row moved before Tidal answered")
        verify(!p.page.canReorder, "a second drag could start while the first was out")
        bridge.answerMoveForTest()
        compare(titles(p.page), "Song 1,Song 2,Song 0,Song 3,Song 4,Song 5")
        verify(p.page.canReorder)
    }

    function test_a_stale_view_is_read_again_and_said() {
        var p = showPage()
        bridge.setMoveAnswerForTest("stale")
        var fetches = bridge.playlistTracksFetchesForTest()
        drag(p, 0, 2)
        tryVerify(function () { return bridge.playlistTracksFetchesForTest() > fetches },
                  settleMs, "the stale page was not read again")
        compare(Toasts.text,
                "This playlist was changed somewhere else, so nothing was moved. It has been reloaded.")
    }

    function test_ctrl_z_moves_it_back() {
        var p = showPage()
        drag(p, 0, 3)
        tryVerify(function () { return Edits.count === 1 }, settleMs, "the move left no undo")
        verify(Toasts.text !== "Could not move the track")
        Edits.undoLast()
        tryVerify(function () { return titles(p.page) === "Song 0,Song 1,Song 2,Song 3,Song 4,Song 5" },
                  settleMs, "the undo did not put it back: " + titles(p.page))
        compare(bridge.movesForTest(), ["0>3", "3>0"])
        compare(Toasts.text, "Moved back in “Mine”")
    }

    // ── when drag is off ─────────────────────────────────────────────────

    function test_no_drag_while_sorted_filtered_or_not_editable_data() {
        return [
            { tag: "sorted by title" }, { tag: "filtered" }, { tag: "someone else's" }
        ]
    }

    function test_no_drag_while_sorted_filtered_or_not_editable(row) {
        if (row.tag === "someone else's")
            bridge.setPlaylistForTest({ uuid: "p-mine", title: "Mine", type: "USER", editable: false })
        var p = row.tag === "someone else's" ? null : showPage()
        if (!p) {
            var host = createTemporaryObject(hostC, testCase)
            host.visible = true
            verify(waitForRendering(host.contentItem))
            var page = createTemporaryObject(pageC, host.pane,
                                             { playlistUuid: "p-mine", playlistTitle: "Mine" })
            tryVerify(function () { return page.trackRows.length === 6 }, settleMs)
            p = { host: host, page: page, list: findByName(page, "playlistTracksList") }
            p.list.positionViewAtIndex(0, ListView.Beginning)
            wait(20)
        }
        if (row.tag === "sorted by title") findSort(p.page).cycle("title")
        if (row.tag === "filtered") p.page.trackFilter = "song"
        wait(20)
        verify(!p.page.canReorder, "drag is on")
        drag(p, 0, 2)
        compare(bridge.movesForTest(), [], "a move went out")
    }

    function findSort(page) {
        var h = findByName(page, "playlistTracksHeader")
        verify(h && h.sort, "no column headings")
        return h.sort
    }
}
