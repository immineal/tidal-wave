// Carrying a track row out of its list: onto one of the user's playlists in
// the sidebar, onto the queue button, and into the open queue at a gap. The
// host mirrors Main.qml: sidebar, a page with a row under the queue overlay,
// and the player bar. StubBridge answers the adds, StubPlayer the queue.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TrackDrag"
    when: windowShown

    readonly property int settleMs: 3000

    function makeEntries() {
        return [
            { kind: "playlist", id: "p-mine",   title: "Mine",   subtitle: "", imageUrl: "", pinned: false, trackCount: 1, editable: true  },
            { kind: "playlist", id: "p-theirs", title: "Theirs", subtitle: "", imageUrl: "", pinned: false, trackCount: 4, editable: false },
            { kind: "album",    id: "a1",       title: "Abendrot", subtitle: "Someone", imageUrl: "", pinned: false, trackCount: 11 }
        ]
    }

    function makeTrack() {
        return { id: 9001, title: "Carried Song", artists: "Kestrel Arcade",
                 albumTitle: "Glass Orchard", durationStr: "4:07", duration: 247,
                 coverUrl: "", coverUrl80: "", albumId: 42, artistId: 7 }
    }

    function queueTrack(i, tag) {
        return { id: 1000 + i, title: tag + " " + i, artists: "Artist", albumTitle: "Album",
                 albumId: 55, duration: 215, coverUrl80: "" }
    }
    function queueTracks(n, tag) {
        var out = []
        for (var i = 0; i < n; ++i) out.push(queueTrack(i, tag))
        return out
    }
    function seedQueue() {
        player.setQueueForTest(queueTracks(6, "Ctx"), 2)
        player.setCurrentTrackForTest(queueTrack(2, "Ctx"))
        player.setManualForTest(queueTracks(2, "Manual"))
        player.setPlaybackSource("album", "42", "Life 1")
        player.resetQueueCallsForTest()
    }

    function init() {
        app.setReducedMotionForTest(true)
        prefs.setSidebarWidthForTest(220)
        auth.setStateForTest(2)
        library.setEntriesForTest(makeEntries())
        library.setTracksForTest([])
        pins.setItemsForTest([])
        bridge.resetForTest()
        bridge.setServerPlaylistForTest("p-mine", [5001])
        Edits.clearHistory()
        Edits.retryDelaysMs = [1]
        Toasts.dismiss()
        player.setShuffle(false)
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
        player.setPlaybackSource("", "", "")
        player.resetQueueCallsForTest()
    }

    function cleanup() {
        Edits.retryDelaysMs = [500, 1000, 2000, 4000]
    }

    Component {
        id: shellC
        Window {
            id: win
            width: 1280
            height: 800
            property alias sidebar: sb
            property alias row: trackRow
            property alias panel: qp
            property alias bar: pbar
            property bool queueOpen: false
            property var visits: []
            function navigate(page, params) { visits = visits.concat([page]) }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    SideBar {
                        id: sb
                        z: 2
                        hostWidth: win.width
                        Layout.preferredWidth: sb.reservedWidth
                        Layout.fillHeight: true
                        onNavigate: (page, params) => win.navigate(page, params)
                    }
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        TrackRow {
                            id: trackRow
                            x: 16
                            y: 40
                            width: 700
                        }
                        QueuePanel {
                            id: qp
                            anchors.fill: parent
                            open: win.queueOpen
                            onDismissed: win.queueOpen = false
                        }
                    }
                }
                PlayerBar {
                    id: pbar
                    Layout.fillWidth: true
                    onShowQueue: win.queueOpen = !win.queueOpen
                }
            }
        }
    }

    SignalSpy { id: playSpy; signalName: "playRequested" }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }
    function settle(item) { wait(1); frame(item); wait(1) }

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

    function show() {
        var host = createTemporaryObject(shellC, testCase)
        verify(host, "the host window was not created")
        host.visible = true
        host.requestActivate()
        frame(host.contentItem)
        host.row.title = makeTrack().title
        host.row.artists = makeTrack().artists
        host.row.albumTitle = makeTrack().albumTitle
        host.row.durationStr = makeTrack().durationStr
        host.row.trackData = makeTrack()
        mouseMove(host.contentItem, host.width - 8, host.height / 2)
        tryVerify(function () { return host.sidebar.rows.length === 3 }, settleMs,
                  "the sidebar did not list the fixture")
        settle(host.contentItem)
        playSpy.target = host.row
        playSpy.clear()
        return host
    }

    function sidebarRow(host, id) {
        var list = findByName(host.sidebar, "sidebarLibraryList")
        for (var i = 0; i < list.count; ++i) {
            var r = list.itemAtIndex(i)
            if (r && r.itemId === id) return r
        }
        verify(false, "no sidebar row for " + id)
    }

    function centreOf(host, item) {
        return item.mapToItem(host.contentItem, item.width / 2, item.height / 2)
    }

    // Presses on the row's number, travels to `to` in steps and stays there.
    function carry(host, to) {
        var from = host.row.mapToItem(host.contentItem, 30, host.row.height / 2)
        mousePress(host.contentItem, from.x, from.y)
        var steps = 10
        for (var s = 1; s <= steps; ++s) {
            mouseMove(host.contentItem, from.x + (to.x - from.x) * s / steps,
                      from.y + (to.y - from.y) * s / steps)
            wait(5)
        }
        wait(5)
        return from
    }

    function preview(host) {
        var p = findByName(host.contentItem, "trackDragPreview")
        return (p && p.visible) ? p : null
    }

    // ── onto a playlist in the sidebar ───────────────────────────────────

    function test_a_track_dropped_on_one_of_my_playlists_goes_in() {
        var host = show()
        var target = sidebarRow(host, "p-mine")
        var at = centreOf(host, target)
        carry(host, at)

        var pv = preview(host)
        verify(pv, "no preview travels with the pointer")
        compare(findByName(pv, "trackDragPreviewLabel").text, "Carried Song",
                "the preview does not name the track")
        verify(findByName(target, "libraryRowTrackDrop").containsDrag,
               "the playlist under the pointer is not marked as the target")
        verify(host.row.reordering, "the carried row is not marked")

        mouseRelease(host.contentItem, at.x, at.y)
        tryVerify(function () { return bridge.addToPlaylistCallsForTest() === 1 }, settleMs,
                  "the drop added nothing")
        compare(bridge.lastAddedPlaylistForTest(), "p-mine", "it went into another playlist")
        compare(bridge.lastAddedTrackIdForTest(), 9001, "another track went in")
        tryVerify(function () { return Toasts.text === "Added to “Mine”" }, settleMs,
                  "the drop said \"" + Toasts.text + "\"")
        verify(Toasts.actionLabel.length > 0, "the add offers no Undo")
        verify(!preview(host), "the preview outlived the drop")
        verify(!host.row.reordering, "the row is still marked after the drop")
        compare(playSpy.count, 0, "the drag also played the row")
    }

    function test_only_my_own_playlists_take_a_track_data() {
        return [ { tag: "someone else's playlist", id: "p-theirs" },
                 { tag: "an album", id: "a1" } ]
    }

    function test_only_my_own_playlists_take_a_track(data) {
        var host = show()
        var target = sidebarRow(host, data.id)
        var at = centreOf(host, target)
        carry(host, at)
        verify(!findByName(target, "libraryRowTrackDrop").containsDrag,
               data.tag + " is marked as a target")
        mouseRelease(host.contentItem, at.x, at.y)
        wait(20)
        compare(bridge.addToPlaylistCallsForTest(), 0, data.tag + " took the track")
        verify(!preview(host), "the preview outlived the drop")
    }

    // ── what stays as it was ─────────────────────────────────────────────

    function test_escape_puts_the_track_back() {
        var host = show()
        var target = sidebarRow(host, "p-mine")
        var at = centreOf(host, target)
        carry(host, at)
        verify(preview(host), "no drag to cancel")
        keyClick(Qt.Key_Escape)
        verify(!preview(host), "Escape left the preview up")
        verify(!host.row.reordering, "Escape left the row marked")
        mouseRelease(host.contentItem, at.x, at.y)
        wait(20)
        compare(bridge.addToPlaylistCallsForTest(), 0, "the drop after Escape still added")
        compare(playSpy.count, 0, "the release after Escape played the row")
        compare(host.visits.length, 0, "Escape also navigated")
    }

    function test_a_click_and_a_twitch_still_play() {
        var host = show()
        var at = host.row.mapToItem(host.contentItem, 30, host.row.height / 2)
        mouseClick(host.contentItem, at.x, at.y)
        compare(playSpy.count, 1, "a click no longer plays the row")
        mousePress(host.contentItem, at.x, at.y)
        mouseMove(host.contentItem, at.x + 1, at.y + 1)
        verify(!preview(host), "a twitch started a drag")
        mouseRelease(host.contentItem, at.x + 1, at.y + 1)
        compare(playSpy.count, 2, "a click with a twitch no longer plays the row")
    }

    // ── into the queue ───────────────────────────────────────────────────

    function test_dropped_on_the_queue_button_it_goes_to_the_end() {
        seedQueue()
        var host = show()
        host.bar.queueSpringMs = 100000
        var btn = host.bar.queueButton
        var at = centreOf(host, btn)
        carry(host, at)
        verify(btn.active, "the queue button is not marked as the target")
        mouseRelease(host.contentItem, at.x, at.y)
        compare(player.queueCalls.join(","), "addToQueue 1", "the drop did not queue the track")
        compare(player.queueManual[2].title, "Carried Song", "the track is not at the end")
        verify(/^1 track.* added to queue$/.test(Toasts.text), "the drop said \"" + Toasts.text + "\"")
        verify(!host.queueOpen, "the queue opened without being held over")
    }

    // Held over the button, the queue opens; the drop lands at the line.
    function openQueueByHolding(host) {
        host.bar.queueSpringMs = 50
        carry(host, centreOf(host, host.bar.queueButton))
        tryVerify(function () { return host.queueOpen }, settleMs,
                  "holding a track over the queue button did not open the queue")
        tryVerify(function () { return host.panel.rowCount > 0 && host.panel.openness === 1 }, settleMs)
        settle(host.contentItem)
    }

    function entryAt(panel, flat) {
        var e = panel.queueList.itemAtIndex(flat)
        verify(e, "queue row " + flat + " is not built")
        return e
    }

    function moveTo(host, p) {
        mouseMove(host.contentItem, p.x, p.y)
        wait(5)
        mouseMove(host.contentItem, p.x, p.y + 1)
        wait(5)
    }

    function test_held_over_the_queue_it_opens_and_the_track_lands_at_the_line() {
        seedQueue()
        var host = show()
        openQueueByHolding(host)
        var panel = host.panel
        // The top quarter of the second queued row: the gap above it.
        var second = entryAt(panel, panel.manualAt + 1)
        var p = second.mapToItem(host.contentItem, second.width / 2, 8)
        moveTo(host, p)
        var line = findByName(panel, "queueDropIndicator")
        verify(line.visible, "no line where the track would land")
        fuzzyCompare(line.mapToItem(panel, 0, 1).y, second.mapToItem(panel, 0, 0).y, 1,
                     "the line is not in the gap above the row")
        mouseRelease(host.contentItem, p.x, p.y + 1)
        compare(player.queueCalls.join(","), "insertQueueRows 1 manual 1",
                "the drop did not put the track at the line")
        compare(player.queueManual.map(function (t) { return t.title }).join(","),
                "Manual 0,Carried Song,Manual 1")
        verify(/^1 track.* added to queue$/.test(Toasts.text), "the drop said \"" + Toasts.text + "\"")
        verify(!line.visible, "the line outlived the drop")
    }

    // A long history: the queue opens scrolled to the playing row, and the
    // line still sits in the gap it names.
    function test_the_line_sits_at_the_gap_in_a_scrolled_queue() {
        player.setQueueForTest(queueTracks(40, "Ctx"), 30)
        player.setCurrentTrackForTest(queueTrack(30, "Ctx"))
        player.setManualForTest(queueTracks(2, "Manual"))
        player.setPlaybackSource("album", "42", "Life 1")
        player.resetQueueCallsForTest()
        var host = show()
        openQueueByHolding(host)
        var panel = host.panel
        // By index: content coordinates are estimates, below 0 on Qt 6.5.
        var view = panel.queueList
        verify(view.indexAt(1, view.contentY + 1) > 0, "the queue did not open scrolled")
        var second = entryAt(panel, panel.manualAt + 1)
        var p = second.mapToItem(host.contentItem, second.width / 2, 8)
        moveTo(host, p)
        var line = findByName(panel, "queueDropIndicator")
        verify(line.visible, "no line where the track would land")
        fuzzyCompare(line.mapToItem(panel, 0, 1).y, second.mapToItem(panel, 0, 0).y, 1,
                     "the line is not in the gap above the row")
        mouseRelease(host.contentItem, p.x, p.y + 1)
        compare(player.queueCalls.join(","), "insertQueueRows 1 manual 1")
    }

    function test_dropped_among_what_the_album_plays_next_it_joins_it() {
        seedQueue()
        var host = show()
        openQueueByHolding(host)
        var panel = host.panel
        var row = entryAt(panel, panel.contextAt + 1)
        var p = row.mapToItem(host.contentItem, row.width / 2, 8)
        moveTo(host, p)
        mouseRelease(host.contentItem, p.x, p.y + 1)
        compare(player.queueCalls.join(","), "insertQueueRows 1 context 1")
        compare(player.queueContext.map(function (t) { return t.title }).join(","),
                "Ctx 3,Carried Song,Ctx 4,Ctx 5")
    }

    function test_the_history_and_the_dimmed_page_take_nothing() {
        seedQueue()
        var host = show()
        openQueueByHolding(host)
        var panel = host.panel
        var played = entryAt(panel, panel.playedAt)
        moveTo(host, played.mapToItem(host.contentItem, played.width / 2, played.height / 2))
        verify(!findByName(panel, "queueDropIndicator").visible, "the history offers a place")
        // Over the scrim, left of the panel.
        var p = host.row.mapToItem(host.contentItem, 30, host.row.height / 2)
        moveTo(host, p)
        mouseRelease(host.contentItem, p.x, p.y + 1)
        compare(player.queueCalls.join(","), "", "a drop off the queue changed it")
        verify(host.queueOpen, "the drop closed the queue")
    }
}
