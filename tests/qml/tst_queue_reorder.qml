// Reordering the queue by dragging a row, as a playlist is reordered: the row
// stays in its place, marked, a preview with its title follows the pointer,
// and the line is the only thing in the gap. The host mirrors Main.qml:
// sidebar, a page under the queue overlay, and the player bar.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "QueueReorder"
    when: windowShown

    readonly property int settleMs: 3000

    function makeEntries() {
        return [
            { kind: "playlist", id: "p-mine", title: "Mine", subtitle: "", imageUrl: "",
              pinned: false, trackCount: 1, editable: true }
        ]
    }

    function queueTrack(i, tag) {
        return { id: 1000 + i + (tag === "Manual" ? 100 : 0), title: tag + " " + i,
                 artists: "Artist", albumTitle: "Album", albumId: 55, duration: 215,
                 coverUrl80: "" }
    }
    function queueTracks(n, tag) {
        var out = []
        for (var i = 0; i < n; ++i) out.push(queueTrack(i, tag))
        return out
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
        player.setQueueForTest(queueTracks(6, "Ctx"), 2)
        player.setCurrentTrackForTest(queueTrack(2, "Ctx"))
        player.setManualForTest(queueTracks(3, "Manual"))
        player.setPlaybackSource("album", "42", "Life 1")
        player.resetQueueCallsForTest()
    }

    function cleanup() {
        Edits.retryDelaysMs = [500, 1000, 2000, 4000]
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
    }

    Component {
        id: shellC
        Window {
            id: win
            width: 1280
            height: 800
            property alias sidebar: sb
            property alias panel: qp
            property alias bar: pbar
            property bool queueOpen: true
            property int pageClicks: 0
            function navigate(page, params) { }

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
                    }
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        MouseArea { anchors.fill: parent; onClicked: win.pageClicks++ }
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
        host.bar.queueSpringMs = 100000
        tryVerify(function () { return host.panel.rowCount > 0 && host.panel.openness === 1 },
                  settleMs, "the queue did not open")
        host.panel.queueList.positionViewAtBeginning()
        settle(host.contentItem)
        return host
    }

    function entryAt(panel, flat) {
        var e = panel.queueList.itemAtIndex(flat)
        verify(e, "queue row " + flat + " is not built")
        return e
    }

    function titles() {
        return player.queueManual.map(function (t) { return t.title }).join(",") + " | "
             + player.queueContext.map(function (t) { return t.title }).join(",")
    }
    readonly property string startOrder:
        "Manual 0,Manual 1,Manual 2 | Ctx 3,Ctx 4,Ctx 5"

    function preview(host) {
        var p = findByName(host.contentItem, "trackDragPreview")
        return (p && p.visible) ? p : null
    }

    // Presses on row `flat`'s grip and travels in steps to `to`, holding there.
    function dragTo(host, flat, to) {
        var grip = findByName(entryAt(host.panel, flat), "queueDragArea")
        verify(grip && grip.enabled, "row " + flat + " cannot be dragged")
        var from = grip.mapToItem(host.contentItem, grip.width / 2, grip.height / 2)
        mousePress(host.contentItem, from.x, from.y)
        var steps = 8
        for (var s = 1; s <= steps; ++s) {
            mouseMove(host.contentItem, from.x + (to.x - from.x) * s / steps,
                      from.y + (to.y - from.y) * s / steps)
            wait(5)
        }
        wait(5)
        return from
    }
    // By `dy` pixels straight down (or up).
    function dragBy(host, flat, dy) {
        var grip = findByName(entryAt(host.panel, flat), "queueDragArea")
        var from = grip.mapToItem(host.contentItem, grip.width / 2, grip.height / 2)
        dragTo(host, flat, Qt.point(from.x, from.y + dy))
        return Qt.point(from.x, from.y + dy)
    }

    // ── the look mid-drag ────────────────────────────────────────────────

    // A row and a bit down, off the tie at a row's middle: the line sits on
    // the seam above the row it lands before, inside no row's ground.
    function test_the_line_sits_between_rows_clear_of_their_text() {
        var host = show()
        var panel = host.panel
        var at = dragBy(host, panel.manualAt, panel.rowHeight + 10)
        var line = findByName(panel, "queueDropIndicator")
        verify(line.visible, "no drop line while dragging")
        compare(panel.dragTo, 1, "the drop is aimed at the wrong slot")
        var lineY = line.mapToItem(panel, 0, line.height / 2).y
        var seam = entryAt(panel, panel.manualAt + 2).mapToItem(panel, 0, 0).y
        fuzzyCompare(lineY, seam, 1.5, "the line is not on the seam above the row it lands before")
        for (var i = panel.playedAt; i < panel.rowCount; ++i) {
            var e = entryAt(panel, i)
            if (e.isHeader) continue
            var g = findByName(e, "queueRowGround")
            verify(g, "row " + i + " has no ground")
            var top = g.mapToItem(panel, 0, 0).y, bottom = top + g.height
            verify(lineY <= top + 2 || lineY >= bottom - 2,
                   "the line runs through row " + i + " (" + top + " to " + bottom
                   + ", line at " + lineY + ")")
        }
        mouseRelease(host.contentItem, at.x, at.y)
        settle(host.contentItem)
        compare(player.queueCalls.join(","), "moveManual 0 1")
        compare(titles(), "Manual 1,Manual 0,Manual 2 | Ctx 3,Ctx 4,Ctx 5")
    }

    function test_the_row_stays_put_and_a_preview_travels() {
        var host = show()
        var panel = host.panel
        var g = findByName(entryAt(panel, panel.contextAt), "queueRowGround")
        var before = g.mapToItem(panel, 0, 0).y
        var at = dragBy(host, panel.contextAt, 2 * panel.rowHeight + 10)
        verify(panel.dragging, "the drag never started")
        compare(g.mapToItem(panel, 0, 0).y, before, "the dragged row left its place")
        verify(Qt.colorEqual(g.color, Theme.surfaceHigh), "the dragged row is not marked")
        var pv = preview(host)
        verify(pv, "no preview travels with the pointer")
        compare(findByName(pv, "trackDragPreviewLabel").text, "Ctx 3")
        mouseRelease(host.contentItem, at.x, at.y)
        settle(host.contentItem)
        verify(!preview(host), "the preview outlived the drop")
        compare(player.queueCalls.join(","), "moveQueueRow context 0 context 2")
    }

    // On its own place the line would say nothing, so it is not drawn.
    function test_no_line_over_the_rows_own_place() {
        var host = show()
        var panel = host.panel
        // Past the start-drag distance, still inside the row's lower half.
        var at = dragBy(host, panel.manualAt + 1, 14)
        verify(panel.dragging, "the drag never started")
        verify(!findByName(panel, "queueDropIndicator").visible, "a line where nothing moves")
        mouseRelease(host.contentItem, at.x, at.y)
        settle(host.contentItem)
        compare(player.queueCalls.join(","), "", "a drop in place reached the player")
    }

    // ── what calls a move off ────────────────────────────────────────────

    function test_escape_calls_the_move_off() {
        var host = show()
        var panel = host.panel
        var at = dragBy(host, panel.manualAt, 2 * panel.rowHeight + 10)
        verify(findByName(panel, "queueDropIndicator").visible, "no drag to call off")
        keyClick(Qt.Key_Escape)
        verify(!panel.dragging, "Escape left the drag on")
        verify(!findByName(panel, "queueDropIndicator").visible, "the line outlived Escape")
        verify(!preview(host), "Escape left the preview up")
        mouseRelease(host.contentItem, at.x, at.y)
        settle(host.contentItem)
        compare(player.queueCalls.join(","), "", "the drop after Escape still moved the row")
        compare(titles(), startOrder)
        verify(host.queueOpen, "Escape closed the queue")
    }

    // Let go anywhere but the list, nothing moves, nothing is added.
    function test_a_drop_outside_the_list_does_nothing_data() {
        return [ { tag: "the dimmed page" }, { tag: "the queue button" },
                 { tag: "the queue heading" } ]
    }

    function test_a_drop_outside_the_list_does_nothing(data) {
        var host = show()
        var panel = host.panel
        var to = data.tag === "the dimmed page"
                     ? panel.mapToItem(host.contentItem, 60, panel.height / 2)
               : data.tag === "the queue button"
                     ? host.bar.queueButton.mapToItem(host.contentItem,
                                                      host.bar.queueButton.width / 2,
                                                      host.bar.queueButton.height / 2)
                     : panel.queueList.mapToItem(host.contentItem, panel.queueList.width / 2, -26)
        dragTo(host, panel.manualAt, to)
        verify(panel.dragging, "the drag never started")
        verify(!findByName(panel, "queueDropIndicator").visible,
               "a line while over " + data.tag)
        verify(!host.bar.queueButton.active, "the queue button offers to take its own row")
        mouseRelease(host.contentItem, to.x, to.y)
        settle(host.contentItem)
        compare(player.queueCalls.join(","), "", "a drop on " + data.tag + " changed the queue")
        compare(titles(), startOrder)
        verify(!panel.dragging, "the drag outlived the drop")
        verify(!preview(host), "the preview outlived the drop")
        compare(host.pageClicks, 0, "the drop clicked the page")
        verify(host.queueOpen, "the drop closed the queue")
    }

    // A queue row carried onto one of the user's playlists goes in, as a
    // row from any other list does; the queue stays as it was.
    function test_a_queue_row_dropped_on_my_playlist_goes_in() {
        var host = show()
        var panel = host.panel
        tryVerify(function () { return host.sidebar.rows.length === 1 }, settleMs,
                  "the sidebar did not list the fixture")
        var list = findByName(host.sidebar, "sidebarLibraryList")
        var target = null
        for (var i = 0; i < list.count; ++i) {
            var r = list.itemAtIndex(i)
            if (r && r.itemId === "p-mine") target = r
        }
        verify(target, "no sidebar row for the playlist")
        var to = target.mapToItem(host.contentItem, target.width / 2, target.height / 2)
        dragTo(host, panel.manualAt + 1, to)
        mouseRelease(host.contentItem, to.x, to.y)
        tryVerify(function () { return bridge.addToPlaylistCallsForTest() === 1 }, settleMs,
                  "the drop added nothing")
        compare(bridge.lastAddedTrackIdForTest(), 1101, "another track went in")
        compare(player.queueCalls.join(","), "", "the queue changed as well")
        verify(!panel.dragging, "the drag outlived the drop")
    }

    // A queue change under a drag calls it off, preview and all, so the
    // release cannot land as a track carried in from outside.
    function test_a_queue_change_calls_the_drag_off() {
        var host = show()
        var panel = host.panel
        var at = dragBy(host, panel.contextAt, panel.rowHeight + 10)
        verify(preview(host), "the drag never started")
        player.setManualForTest(queueTracks(2, "Manual"))
        player.resetQueueCallsForTest()
        verify(!panel.dragging, "the drag outlived the queue change")
        verify(!preview(host), "the preview outlived the queue change")
        mouseRelease(host.contentItem, at.x, at.y)
        settle(host.contentItem)
        compare(player.queueCalls.join(","), "", "the release still changed the queue")
    }
}
