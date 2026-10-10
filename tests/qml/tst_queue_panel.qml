// The queue panel: played history, the current track, the manual queue and
// the rest of the context, in one scrolling list. The player stub from
// tests/TestStubs.h models the real split: setQueueForTest() seeds the
// context and the index cuts it into played and upcoming, setManualForTest()
// fills the manual queue. The host mirrors Main.qml: a click-counting page
// under a QueuePanel that fills it.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "QueuePanel"
    when: windowShown

    // ── fixtures ─────────────────────────────────────────────────────────

    function makeTrack(i, tag) {
        return {
            id:         1000 + i,
            title:      (tag || "Track") + " " + i,
            artists:    "Artist " + (i % 7),
            albumTitle: "Album " + (i % 3),
            albumId:    55,
            duration:   215,
            coverUrl80: ""
        }
    }

    function makeTracks(n, tag) {
        var out = []
        for (var i = 0; i < n; ++i) out.push(makeTrack(i, tag))
        return out
    }

    // A context of six with the third one playing, so there is a played
    // section, a current track and a context remainder, plus two tracks the
    // user queued by hand.
    function seedAll() {
        player.setQueueForTest(makeTracks(6, "Ctx"), 2)
        player.setCurrentTrackForTest(makeTrack(2, "Ctx"))
        player.setManualForTest(makeTracks(2, "Manual"))
        player.setPlaybackSource("album", "42", "Life 1")
        player.resetQueueCallsForTest()
    }

    SignalSpy { id: queueSpy; target: player; signalName: "queueChanged" }

    function init() {
        app.setReducedMotionForTest(true)      // no fades to wait out
        player.setShuffle(false)
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
        player.setPlaybackSource("", "", "")
        player.resetQueueCallsForTest()
        queueSpy.clear()
    }

    // ── tree walkers ─────────────────────────────────────────────────────

    function findByName(item, name) {
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function collectByName(item, name, out) {
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) collectByName(kids[i], name, out)
        return out
    }

    // Delegates in flat-index order, which is the order the user reads them
    // in. ListView parents them to contentItem in creation order, not in
    // index order, so they have to be sorted.
    function entries(panel) {
        var all = collectByName(panel, "queueEntry", [])
        all.sort(function (a, b) { return a.rowIndex - b.rowIndex })
        return all
    }

    function entryAt(panel, flatIndex) {
        var all = entries(panel)
        for (var i = 0; i < all.length; ++i)
            if (all[i].rowIndex === flatIndex) return all[i]
        return null
    }

    // The visible section headers, top to bottom, as the labels they draw.
    function headerLabels(panel) {
        var out = []
        var all = entries(panel)
        for (var i = 0; i < all.length; ++i)
            if (all[i].isHeader) out.push(all[i].headerText)
        return out
    }

    // Every row's title, top to bottom, headers excluded.
    function rowTitles(panel) {
        var out = []
        var all = entries(panel)
        for (var i = 0; i < all.length; ++i)
            if (!all[i].isHeader) out.push(all[i].titleText)
        return out
    }

    function liveDelegates(view) {
        return (view.contentItem && view.contentItem.children)
             ? view.contentItem.children.length : -1
    }

    // Events go through the window's content item, never through the item
    // being dragged: a dragged row travels with the pointer, so coordinates
    // taken against it would chase themselves.
    function pointIn(host, item, dx, dy) {
        return item.mapToItem(host.contentItem, dx, dy)
    }

    // A settled scene produces no new frame, so waitForRendering would sit
    // out its whole timeout. The cap keeps that short, and anything pending
    // arrives inside one frame.
    function settle(item) {
        wait(1)
        waitForRendering(item, 100)
        wait(1)        // lets the callLater that frame scheduled actually run
    }

    // ── host ─────────────────────────────────────────────────────────────

    Component {
        id: queueHost
        Window {
            id: win
            width: 960
            height: 700
            color: "black"

            // Stands in for the page under the panel: if the scrim leaks,
            // this counter moves.
            property int pageClicks: 0
            property int dismissals: 0
            property alias panel: qp

            MouseArea {
                anchors.fill: parent
                onClicked: win.pageClicks++
            }

            QueuePanel {
                id: qp
                anchors.fill: parent
                visible: false
                onDismissed: win.dismissals++
            }
        }
    }

    function showHost() {
        var host = createTemporaryObject(queueHost, testCase)
        verify(host, "host window was not created")
        host.visible = true
        waitForRendering(host.contentItem, 2000)
        return host
    }

    // Opening the panel is a visibility change, which is what the reveal
    // hangs off, so every test that wants rows goes through this.
    function openPanel(host) {
        host.panel.visible = true
        settle(host.contentItem)
        tryVerify(function () { return host.panel.rowCount > 0 }, 5000,
                  "the panel drew no rows at all")
        settle(host.contentItem)
        return host.panel
    }

    // The decode budget TrackRow's cover carries: one decode per thumbnail
    // adds up in a long queue. Both dimensions, because a width-only
    // sourceSize reaches the image provider with a height of zero.
    function test_a_queue_thumbnail_decodes_at_the_size_it_is_drawn() {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        var cover = findByName(entryAt(panel, 0), "queueRowCover")
        verify(cover, "a queue row has no cover image")
        var box = cover.width
        verify(box > 0, "the cover box collapsed")

        compare(cover.sourceSize.width, cover.sourceSize.height,
                "a square cover was asked for at " + cover.sourceSize.width
                + "x" + cover.sourceSize.height + ", which stretches it")
        verify(cover.sourceSize.width >= box && cover.sourceSize.width <= 2 * box,
               "the cover decodes at " + cover.sourceSize.width
               + " for a box of " + box)
    }

    // ── the three sections, in order, with their headers ──────────────────

    function test_the_sections_render_in_order_with_their_headers() {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        compare(headerLabels(panel).join(" | "),
                [qsTr("Played"), qsTr("Now Playing"), qsTr("Next in queue"),
                 qsTr("Next from: %1").arg("Life 1")].join(" | "),
                "the four section headers, in reading order")

        // Played (oldest first), the current track, the manual queue, then
        // what is left of the album.
        compare(rowTitles(panel).join(","),
                "Ctx 0,Ctx 1,Ctx 2,Manual 0,Manual 1,Ctx 3,Ctx 4,Ctx 5",
                "the rows must follow the play order the model promises")

        // And each row knows which section it is in, which is what every
        // click below depends on.
        var all = entries(panel)
        var kinds = []
        for (var i = 0; i < all.length; ++i) kinds.push(all[i].kind)
        compare(kinds.join(","),
                "playedHeader,played,played,nowHeader,current,"
                + "manualHeader,manual,manual,contextHeader,context,context,context",
                "the flat index must map back onto the sections")
    }

    function test_the_context_header_names_the_source() {
        seedAll()
        player.setPlaybackSource("playlist", "uuid-p1", "Evening Drive")
        var host = showHost()
        var panel = openPanel(host)

        verify(headerLabels(panel).indexOf(qsTr("Next from: %1").arg("Evening Drive")) >= 0,
               "the context header does not name the playlist it came from")
    }

    // ── empty sections draw no header ────────────────────────────────────

    function test_an_empty_section_shows_no_header() {
        // Nothing queued by hand, and the first track of the album playing:
        // no manual queue and no history.
        player.setQueueForTest(makeTracks(4, "Ctx"), 0)
        player.setCurrentTrackForTest(makeTrack(0, "Ctx"))
        player.setPlaybackSource("album", "42", "Life 1")

        var host = showHost()
        var panel = openPanel(host)

        var labels = headerLabels(panel)
        compare(labels.indexOf(qsTr("Next in queue")), -1,
                "an empty manual queue still drew its header")
        compare(labels.indexOf(qsTr("Played")), -1,
                "an empty history still drew its header")
        compare(labels.join(" | "),
                [qsTr("Now Playing"), qsTr("Next from: %1").arg("Life 1")].join(" | "),
                "only the two sections with something in them belong on screen")
        compare(rowTitles(panel).join(","), "Ctx 0,Ctx 1,Ctx 2,Ctx 3",
                "the rows themselves are unaffected")

        // And the last track of the album: nothing upcoming, so no context
        // header either, even though the context still has a name.
        player.setQueueForTest(makeTracks(4, "Ctx"), 3)
        player.setCurrentTrackForTest(makeTrack(3, "Ctx"))
        settle(host.contentItem)
        compare(headerLabels(panel).indexOf(qsTr("Next from: %1").arg("Life 1")), -1,
                "a context with nothing left in it still drew its header")
    }

    // ── a manual row is removable ────────────────────────────────────────

    function test_a_manual_row_can_be_removed() {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        var row = entryAt(panel, panel.manualAt + 1)      // Manual 1
        verify(row, "the second manual row was never drawn")
        compare(row.kind, "manual", "the index arithmetic put the wrong row here")

        // The button lives behind hover.
        var p = pointIn(host, row, row.width / 2, row.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        settle(host.contentItem)

        var btn = findByName(row, "queueRemoveButton")
        verify(btn, "a manual row offers no way to remove it")
        verify(btn.visible, "the remove button never showed on hover")

        var at = pointIn(host, btn, btn.width / 2, btn.height / 2)
        mouseClick(host.contentItem, at.x, at.y)
        settle(host.contentItem)

        compare(player.queueCalls.join(","), "removeManual 1",
                "removing a row must go through removeManual with its own index")
        compare(player.queueManual.length, 1, "the row was not removed")
        compare(player.queueManual[0].title, "Manual 0", "the wrong row was removed")
        compare(rowTitles(panel).join(","),
                "Ctx 0,Ctx 1,Ctx 2,Manual 0,Ctx 3,Ctx 4,Ctx 5",
                "the list did not follow the removal")
    }

    // Only the manual queue is the user's to edit: a context row is not
    // removable, because there is no API for it.
    function test_a_context_row_has_no_remove_button() {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        var row = entryAt(panel, panel.contextAt)
        verify(row, "the first context row was never drawn")
        compare(row.kind, "context", "the index arithmetic put the wrong row here")

        var p = pointIn(host, row, row.width / 2, row.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        settle(host.contentItem)

        var btn = findByName(row, "queueRemoveButton")
        verify(!btn || !btn.visible, "a context row offered a remove button")
    }

    // ── drag to reorder, inside the manual queue and nowhere else ────────

    function test_dragging_reorders_the_manual_queue() {
        player.setQueueForTest(makeTracks(6, "Ctx"), 2)
        player.setCurrentTrackForTest(makeTrack(2, "Ctx"))
        player.setManualForTest(makeTracks(3, "Manual"))
        player.setPlaybackSource("album", "42", "Life 1")
        player.resetQueueCallsForTest()

        var host = showHost()
        var panel = openPanel(host)
        compare(rowTitles(panel).join(","),
                "Ctx 0,Ctx 1,Ctx 2,Manual 0,Manual 1,Manual 2,Ctx 3,Ctx 4,Ctx 5",
                "the starting order")

        var row = entryAt(panel, panel.manualAt)
        var grip = findByName(row, "queueDragArea")
        verify(grip, "a manual row has no drag affordance")
        verify(grip.enabled, "the drag affordance is dead")

        var from = pointIn(host, grip, grip.width / 2, grip.height / 2)
        mousePress(host.contentItem, from.x, from.y)
        mouseMove(host.contentItem, from.x, from.y + panel.rowHeight)
        wait(1)

        var marker = findByName(panel, "queueDropIndicator")
        verify(marker, "there is no drop indicator")
        verify(marker.visible, "the drop indicator never showed")
        compare(panel.dragTo, 1, "one row of travel is one slot")

        mouseMove(host.contentItem, from.x, from.y + 2 * panel.rowHeight)
        wait(1)
        compare(panel.dragTo, 2, "two rows of travel is two slots")

        mouseRelease(host.contentItem, from.x, from.y + 2 * panel.rowHeight)
        settle(host.contentItem)

        // moveManual(0, 2) and nothing else: a swap would leave Manual 2 in the
        // middle.
        compare(player.queueCalls.join(","), "moveManual 0 2",
                "the drop called moveManual with the wrong pair")
        compare(player.queueManual[0].title + "," + player.queueManual[1].title + ","
                + player.queueManual[2].title,
                "Manual 1,Manual 2,Manual 0", "the manual queue is in the wrong order")
        compare(rowTitles(panel).join(","),
                "Ctx 0,Ctx 1,Ctx 2,Manual 1,Manual 2,Manual 0,Ctx 3,Ctx 4,Ctx 5",
                "the visible order did not follow the drop")
        verify(!findByName(panel, "queueDropIndicator").visible,
               "the drop indicator outlived the drag")
    }

    // The drag is confined to its section: a manual row dropped over the
    // context below, over the history above, or off the panel entirely is
    // not moved at all. A slip of the hand must not be an edit.
    function test_a_drag_cannot_leave_the_manual_section_data() {
        return [
            { tag: "down into the context", dx: 0,   dy:  5 },
            { tag: "up into the played",    dx: 0,   dy: -5 },
            { tag: "sideways onto the page", dx: -600, dy: 1 }
        ]
    }

    function test_a_drag_cannot_leave_the_manual_section(row) {
        player.setQueueForTest(makeTracks(6, "Ctx"), 2)
        player.setCurrentTrackForTest(makeTrack(2, "Ctx"))
        player.setManualForTest(makeTracks(3, "Manual"))
        player.setPlaybackSource("album", "42", "Life 1")
        player.resetQueueCallsForTest()

        var host = showHost()
        var panel = openPanel(host)

        var grip = findByName(entryAt(panel, panel.manualAt), "queueDragArea")
        var from = pointIn(host, grip, grip.width / 2, grip.height / 2)
        var toX = from.x + row.dx
        var toY = from.y + row.dy * panel.rowHeight

        mousePress(host.contentItem, from.x, from.y)
        mouseMove(host.contentItem, toX, toY)
        wait(1)
        verify(!findByName(panel, "queueDropIndicator").visible,
               "the indicator should go dark once the pointer leaves the section ("
               + row.tag + ")")
        mouseRelease(host.contentItem, toX, toY)
        settle(host.contentItem)

        compare(player.queueCalls.length, 0,
                "a drop " + row.tag + " reached the player")
        compare(player.queueManual[0].title + "," + player.queueManual[1].title + ","
                + player.queueManual[2].title,
                "Manual 0,Manual 1,Manual 2",
                "a drop " + row.tag + " reordered the manual queue")
        compare(rowTitles(panel).join(","),
                "Ctx 0,Ctx 1,Ctx 2,Manual 0,Manual 1,Manual 2,Ctx 3,Ctx 4,Ctx 5",
                "the list reordered anyway after a drop " + row.tag)
    }

    function test_only_manual_rows_have_a_grip_data() {
        return [{ tag: "played" }, { tag: "current" }, { tag: "context" }]
    }

    function test_only_manual_rows_have_a_grip(row) {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        var at = row.tag === "played"  ? panel.playedAt
               : row.tag === "current" ? panel.currentAt
                                       : panel.contextAt
        var entry = entryAt(panel, at)
        verify(entry, "the " + row.tag + " row was never drawn")
        compare(entry.kind, row.tag, "the index arithmetic put the wrong row here")
        var grip = findByName(entry, "queueDragArea")
        verify(!grip || !grip.enabled, "a " + row.tag + " row can be dragged")
    }

    // ── going back to something already played ───────────────────────────

    function test_clicking_a_played_row_goes_back_to_it() {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        var row = entryAt(panel, panel.playedAt + 1)       // Ctx 1
        verify(row, "the second played row was never drawn")
        compare(row.kind, "played", "the index arithmetic put the wrong row here")
        compare(row.titleText, "Ctx 1", "the played section is not oldest first")

        var p = pointIn(host, row, row.width / 2, row.height / 2)
        mouseClick(host.contentItem, p.x, p.y)
        settle(host.contentItem)

        compare(player.queueCalls.join(","), "jumpToPlayed 1",
                "a played row must go back through jumpToPlayed with its own index")
    }

    function test_clicking_the_other_sections_jumps_through_their_own_call_data() {
        return [
            { tag: "manual",  at: "manualAt",  want: "jumpToManual 0"  },
            { tag: "context", at: "contextAt", want: "jumpToContext 0" }
        ]
    }

    function test_clicking_the_other_sections_jumps_through_their_own_call(row) {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        var entry = entryAt(panel, panel[row.at])
        verify(entry, "the first " + row.tag + " row was never drawn")
        var p = pointIn(host, entry, entry.width / 2, entry.height / 2)
        mouseClick(host.contentItem, p.x, p.y)
        settle(host.contentItem)

        compare(player.queueCalls.join(","), row.want,
                "a " + row.tag + " row called the wrong thing")
    }

    // ── finding your place ───────────────────────────────────────────────

    // Opening the panel on a queue that has been playing for a while must
    // land on the current track.
    function test_opening_the_panel_scrolls_to_the_current_track() {
        player.setQueueForTest(makeTracks(400, "Ctx"), 250)
        player.setCurrentTrackForTest(makeTrack(250, "Ctx"))
        player.setPlaybackSource("playlist", "uuid-p1", "Life 1")

        var host = showHost()
        var panel = openPanel(host)
        var view = panel.queueList

        verify(view.contentY > 0, "the panel opened at the top of the history")
        verify(panel.currentOnScreen,
               "the current track is not on screen after opening the panel")

        // The delegate exists and sits inside the viewport.
        var entry = entryAt(panel, panel.currentAt)
        verify(entry, "the current row has no delegate")
        var top = entry.mapToItem(view, 0, 0).y
        verify(top >= -0.5 && top + entry.height <= view.height + 0.5,
               "the current row is at y=" + top.toFixed(1) + " in a "
               + view.height + "px viewport")

        verify(!findByName(panel, "queueJumpToCurrent").visible,
               "the jump affordance showed while the current track was on screen")
    }

    function test_scrolling_away_reveals_the_jump_affordance_and_it_returns() {
        player.setQueueForTest(makeTracks(400, "Ctx"), 250)
        player.setCurrentTrackForTest(makeTrack(250, "Ctx"))
        player.setPlaybackSource("playlist", "uuid-p1", "Life 1")

        var host = showHost()
        var panel = openPanel(host)
        var view = panel.queueList
        var jump = findByName(panel, "queueJumpToCurrent")
        verify(jump, "there is no jump affordance at all")
        verify(!jump.visible, "the affordance showed before anyone scrolled")

        // Away, by a long way, in both directions.
        view.contentY = 0
        settle(host.contentItem)
        verify(!panel.currentOnScreen, "scrolled to the top and still 'on screen'")
        verify(jump.visible, "scrolling to the top revealed no way back")

        view.contentY = view.contentHeight - view.height
        settle(host.contentItem)
        verify(jump.visible, "scrolling to the bottom revealed no way back")

        // And back, through the affordance itself.
        var p = pointIn(host, jump, jump.width / 2, jump.height / 2)
        mouseClick(host.contentItem, p.x, p.y)
        settle(host.contentItem)

        verify(panel.currentOnScreen, "the affordance did not return to the current track")
        tryVerify(function () { return !jump.visible }, 2000,
                  "the affordance outlived its usefulness")

        // It hides on its own too, without being used.
        view.contentY = 0
        settle(host.contentItem)
        verify(jump.visible, "the affordance did not come back")
        view.positionViewAtIndex(panel.currentAt, ListView.Center)
        settle(host.contentItem)
        verify(!jump.visible, "scrolling back by hand left the affordance showing")
    }

    // At 5000 rows a panel that builds its whole list freezes the window.
    function test_five_thousand_rows_stay_virtualised() {
        var n = 5000
        player.setQueueForTest(makeTracks(n, "Ctx"), 4000)
        player.setCurrentTrackForTest(makeTrack(4000, "Ctx"))
        player.setManualForTest(makeTracks(3, "Manual"))
        player.setPlaybackSource("playlist", "uuid-p1", "Life 1")

        var host = showHost()
        var panel = openPanel(host)
        var view = panel.queueList

        // 5000 context tracks + 3 manual + the current one, plus four headers.
        compare(panel.rowCount, n + 3 + 4, "the flat row count is wrong")
        compare(view.count, panel.rowCount, "the view is not showing the whole queue")

        var live = liveDelegates(view)
        verify(live < 400, "the panel built " + live + " delegates for " + n + " rows")

        // The reveal has to be O(1) as well: it runs on open, when the list is
        // at its biggest.
        verify(panel.currentOnScreen, "a 5000 row queue did not open on the current track")
        var entry = entryAt(panel, panel.currentAt)
        verify(entry, "the current row has no delegate at 5000 rows")
        compare(entry.titleText, "Ctx 4000", "the reveal landed on the wrong row")

        // Scrolling the whole way must not accumulate delegates either.
        view.contentY = 0
        settle(host.contentItem)
        view.contentY = view.contentHeight - view.height
        settle(host.contentItem)
        live = liveDelegates(view)
        verify(live < 400,
               live + " delegates are alive after scrolling, so the view keeps "
               + "every delegate it ever built")

        // And the way back is still one call, from the far end of 5000 rows.
        var jump = findByName(panel, "queueJumpToCurrent")
        verify(jump.visible, "no way back from the end of a 5000 row queue")
        var p = pointIn(host, jump, jump.width / 2, jump.height / 2)
        mouseClick(host.contentItem, p.x, p.y)
        settle(host.contentItem)
        verify(panel.currentOnScreen, "the affordance could not reach the current track")
        verify(liveDelegates(view) < 400, "the jump built the list it skipped over")
    }

    // ── a track simply ending ────────────────────────────────────────────

    // An advance moves the index and shortens the manual run without
    // republishing the queue (tests/tst_queue_perf.cpp guards that), so the
    // panel must follow the boundaries with no queueChanged.
    function test_an_advance_moves_the_sections_with_no_queue_change() {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)
        compare(rowTitles(panel).join(","),
                "Ctx 0,Ctx 1,Ctx 2,Manual 0,Manual 1,Ctx 3,Ctx 4,Ctx 5",
                "the starting order")

        queueSpy.clear()
        player.advanceForTest()          // Ctx 2 ends, Manual 0 takes over
        settle(host.contentItem)

        compare(queueSpy.count, 0, "the fixture republished the queue, so this proves nothing")
        compare(panel.playedCount, 3, "the finished track did not join the history")
        compare(panel.manualCount, 1, "the manual queue did not give up its row")
        compare(entryAt(panel, panel.currentAt).titleText, "Manual 0",
                "the panel is a row behind the player")
        compare(entryAt(panel, panel.playedAt + 2).kind, "played",
                "the finished track is still drawn as something upcoming")
        compare(headerLabels(panel).join(" | "),
                [qsTr("Played"), qsTr("Now Playing"), qsTr("Next in queue"),
                 qsTr("Next from: %1").arg("Life 1")].join(" | "),
                "the headings did not follow the boundaries")

        // Two more, which empties the manual queue and hands playback back to
        // the album.
        player.advanceForTest()
        player.advanceForTest()
        settle(host.contentItem)

        compare(queueSpy.count, 0, "an advance republished the whole queue")
        compare(panel.playedCount, 5, "the history did not keep up")
        compare(panel.manualCount, 0, "the manual queue was not consumed")
        compare(entryAt(panel, panel.currentAt).titleText, "Ctx 3",
                "playback did not fall back to the album")
        compare(headerLabels(panel).indexOf(qsTr("Next in queue")), -1,
                "the emptied manual section kept its header")
        compare(rowTitles(panel).join(","),
                "Ctx 0,Ctx 1,Ctx 2,Manual 0,Manual 1,Ctx 3,Ctx 4,Ctx 5",
                "the rows themselves never moved; only the boundaries did")
    }

    // ── Clear ────────────────────────────────────────────────────────────

    function test_clear_empties_the_manual_queue_only() {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        var clear = findByName(panel, "queueClear")
        verify(clear, "the Clear control was not found")
        verify(clear.visible, "Clear is hidden while there is a manual queue to clear")

        var p = pointIn(host, clear, clear.width / 2, clear.height / 2)
        mouseClick(host.contentItem, p.x, p.y)
        settle(host.contentItem)

        compare(player.queueCalls.join(","), "clearManual", "Clear called the wrong thing")
        compare(player.queueManual.length, 0, "the manual queue survived Clear")
        compare(player.queueContext.length, 3, "Clear took the album with it")
        compare(player.queuePlayed.length, 2, "Clear took the history with it")
        compare(rowTitles(panel).join(","), "Ctx 0,Ctx 1,Ctx 2,Ctx 3,Ctx 4,Ctx 5",
                "the list did not follow the clear")
        compare(headerLabels(panel).indexOf(qsTr("Next in queue")), -1,
                "the emptied section kept its header")
        verify(!clear.visible, "Clear stayed offered with nothing left to clear")
    }

    // ── the scrim ────────────────────────────────────────────────────────

    function test_the_scrim_still_swallows_clicks() {
        seedAll()
        var host = showHost()
        var panel = openPanel(host)

        compare(panel.panelWidth, Math.min(340, Math.round(panel.width * 0.85)),
                "the panel must not eat a narrow window whole")
        verify(panel.width > panel.panelWidth, "need scrim to the left of the panel")

        // Well left of the panel, so this is scrim and nothing else.
        mouseClick(host.contentItem, 24, Math.round(panel.height / 2))
        compare(host.pageClicks, 0, "the scrim let a click through to the page")
        compare(host.dismissals, 1, "clicking the scrim should dismiss the queue")

        // A click on the panel's own chrome is the panel's business.
        mouseClick(host.contentItem, Math.round(panel.width - panel.panelWidth / 2), 24)
        compare(host.pageClicks, 0, "the panel let a click through to the page")
        compare(host.dismissals, 1, "clicking the panel should not dismiss it")
    }

    // A closed panel holds no copy of the queue: this is what keeps a track
    // change off the hot path when the panel is not even on screen.
    function test_a_closed_panel_holds_no_rows() {
        player.setQueueForTest(makeTracks(5000, "Ctx"), 2500)
        player.setCurrentTrackForTest(makeTrack(2500, "Ctx"))
        player.setManualForTest(makeTracks(3, "Manual"))

        var host = showHost()
        compare(host.panel.rowCount, 0, "a closed panel built a model anyway")
        compare(host.panel.queueList.count, 0, "a closed panel built a view anyway")
    }
}
