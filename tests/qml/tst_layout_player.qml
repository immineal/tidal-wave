// Layout regression tests for the player chrome: the Now Playing page, the
// bottom player bar, the queue panel and the Settings popup.
//
// Everything is measured at 640 / 820 / 960 / 1280 (SPEC-0.4.0 X3), at both the
// 600px window minimum and a tall 1200px window. 960x1200 is the size that
// matters most: the user runs two 1920x1200 monitors, so half-screen is
// 960x1200.
//
// NowPlayingPage and QueuePanel live beside the sidebar in Main.qml, so they
// never get the whole window. The hosts below reproduce that with the same
// 220px sidebar Main.qml hands out today, which is the pessimistic case until
// the rail (SPEC L2) narrows it to 68 below 820. PlayerBar does span the whole
// window, so it is hosted at the full width.
//
// NowPlayingPage delegates its sleep timer to Window.window, so it cannot be
// instantiated bare; nowPlayingHost mirrors exactly the surface Main.qml
// provides, which is also the list tests/TestStubs.h documents.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "PlayerLayout"
    when: windowShown

    // Main.qml's sidebar width. Pages get the window minus this.
    readonly property int sidebarWidth: 220

    // Several controls draw their focus ring with `anchors.margins: -4`, a
    // deliberate four-pixel bleed rather than a layout failure, so an overflow
    // only counts past that. The faults this guards against are 54px and 58px.
    readonly property real overflowSlack: 4.5

    // How far apart the Now Playing page's two blocks have to be to count as
    // clear of each other. Settled, they are: the column gap is 64 side by side
    // and the stack gap 32 one above the other, so this is a floor under both
    // and not a figure either layout is built to.
    readonly property int blockClearance: 8

    // ── fixtures ─────────────────────────────────────────────────────────

    // Long strings on purpose: a layout that only holds for short titles is not
    // one that holds.
    function makeTrack(i) {
        return {
            id:          1000 + i,
            title:       "Everything In Its Right Place (Remastered Edition) " + i,
            artists:     "Some Artist With A Long Name, And A Featured Guest",
            albumTitle:  "An Album Whose Title Also Runs On For A While",
            albumId:     55,
            artistId:    77,
            coverUrl:    "",
            coverUrl80:  "",
            duration:    215
        }
    }

    function init() {
        // Two cases below measure a transition rather than a resting layout, so
        // motion has to be allowed. Another file in this suite turns the
        // preference on, and the stub carries it across files.
        app.setReducedMotionForTest(false)
        var q = []
        for (var i = 0; i < 6; i++) q.push(makeTrack(i))
        player.setQueueForTest(q, 0)
        player.setManualForTest([])
        player.setCurrentTrackForTest(makeTrack(0))
        player.setAudioQualityForTest("LOSSLESS")
        player.setDurationForTest(215000)
        player.setPositionForTest(42000)
        // One case drives this to the top of its range and the stub is shared
        // across the file, so every case starts from the same volume.
        player.setVolume(0.7)
        player.setMuted(false)
        player.setPlaybackSource("playlist", "abc-123",
                                 "A Playlist Whose Name Is Not Short")
        cast.setDevicesForTest([{ id: "d1", name: "Living Room Speaker" }])
    }

    // The four widths from SPEC-0.4.0 X3, each at the 600px window minimum and
    // at the 1200px the user's monitors actually give.
    function sizeRows() {
        var rows = []
        var widths = [640, 820, 960, 1280]
        for (var i = 0; i < widths.length; i++) {
            rows.push({ tag: widths[i] + "x600",  w: widths[i], h: 600  })
            rows.push({ tag: widths[i] + "x1200", w: widths[i], h: 1200 })
        }
        return rows
    }

    // ── tree walkers ─────────────────────────────────────────────────────

    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    // Collects every visible item that sticks out of its parent horizontally.
    function collectOverflow(item, path, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            var here = path + " > " + typeName(c)
            if (c.x < -overflowSlack
                    || c.x + c.width > item.width + overflowSlack) {
                out.push(here + " x=" + c.x.toFixed(1) + " w=" + c.width.toFixed(1)
                         + " but parent is " + item.width.toFixed(1) + " wide")
            }
            collectOverflow(c, here, out)
        }
        return out
    }

    function isText(obj) {
        return typeof obj.truncated === "boolean"
            && typeof obj.elide === "number"
            && typeof obj.wrapMode === "number"
    }

    // Collects every visible Text that is cut off. A Text that neither elides
    // nor wraps has no graceful degradation left, so it must fit; one that does
    // elide is allowed to, but not all the way down to nothing.
    function collectClipped(item, path, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            var here = path + " > " + typeName(c)
            if (isText(c) && c.text.length > 0) {
                if (c.elide === Text.ElideNone && c.wrapMode === Text.NoWrap) {
                    if (c.implicitWidth > c.width + 0.5 || c.truncated) {
                        out.push(here + " \"" + c.text.substring(0, 32)
                                 + "\" needs " + c.implicitWidth.toFixed(1)
                                 + " but got " + c.width.toFixed(1)
                                 + " with no elide and no wrap")
                    }
                } else if (c.elide !== Text.ElideNone && c.width < 8) {
                    out.push(here + " \"" + c.text.substring(0, 32)
                             + "\" elided away to " + c.width.toFixed(1) + "px")
                }
            }
            collectClipped(c, here, out)
        }
        return out
    }

    function reportFor(what, row, faults) {
        return what + " at " + row.tag + ":\n  " + faults.join("\n  ")
    }

    // ── hosts ────────────────────────────────────────────────────────────

    Component {
        id: nowPlayingHost
        Window {
            id: npWin
            width: 960; height: 1200
            // The sleep timer lives on the application window (Main.qml) so it
            // survives navigation away from the page; the page reaches it
            // through Window.window. Mirror that surface, nothing more.
            property bool   sleepTimerActive: false
            property bool   sleepStopAtEndOfTrack: false
            property int    sleepTimeLeft: 0
            property bool   sleepIsFading: false
            property bool   sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) { sleepTimerActive = true }
            function cancelSleepTimer() { sleepTimerActive = false }
            // Main.qml's own formatter, not a constant: one case below counts
            // the pill down and a fixed string would have hidden the thing it
            // is looking for.
            function formatSleepTime(seconds) {
                var h = Math.floor(seconds / 3600)
                var m = Math.floor((seconds % 3600) / 60)
                var sec = seconds % 60
                if (h > 0)
                    return h + ":" + (m < 10 ? "0" : "") + m + ":" + (sec < 10 ? "0" : "") + sec
                return m + ":" + (sec < 10 ? "0" : "") + sec
            }
            function navigate(page, params) {}
            function goBack() {}

            property alias page: np
            NowPlayingPage {
                id: np
                x: testCase.sidebarWidth
                width: Math.max(0, npWin.width - testCase.sidebarWidth)
                height: npWin.height
            }
        }
    }

    Component {
        id: playerBarHost
        Window {
            id: pbWin
            width: 960; height: 200
            property alias bar: pb
            PlayerBar {
                id: pb
                width: pbWin.width
                anchors.bottom: parent.bottom
            }
        }
    }

    Component {
        id: queueHost
        Window {
            id: qWin
            width: 960; height: 1200
            // Stands in for the page under the queue panel: if the scrim leaks,
            // this counter moves.
            property int pageClicks: 0
            property int dismissals: 0
            property alias panel: qp
            Item {
                x: testCase.sidebarWidth
                width: Math.max(0, qWin.width - testCase.sidebarWidth)
                height: qWin.height
                MouseArea {
                    anchors.fill: parent
                    onClicked: qWin.pageClicks++
                }
                QueuePanel {
                    id: qp
                    anchors.fill: parent
                    onDismissed: qWin.dismissals++
                }
            }
        }
    }

    // A VolumeSlider on its own, so the handle arithmetic is measured without
    // the player bar's animated slot in the way. `value` is a plain property
    // here and `moved` writes it back, which is what the bar does through the
    // player.
    Component {
        id: volumeSliderHost
        Window {
            id: vsWin
            width: 200; height: 100
            property real lastMoved: -1
            property int  moves: 0
            property alias slider: vs
            VolumeSlider {
                id: vs
                width: 90
                anchors.centerIn: parent
                value: 0.7
                onMoved: (v) => { vsWin.lastMoved = v; vsWin.moves++; vs.value = v }
            }
        }
    }

    Component {
        id: sideBarHost
        Window {
            id: sbWin
            width: 640; height: 600
            property alias sidebar: sb
            SideBar {
                id: sb
                width: testCase.sidebarWidth
                height: sbWin.height
            }
        }
    }

    function showHost(component, w, h) {
        var host = createTemporaryObject(component, testCase)
        verify(host, "host window was not created")
        host.width = w
        host.height = h
        host.visible = true
        waitForRendering(host.contentItem)
        return host
    }

    // ── Now Playing ──────────────────────────────────────────────────────

    function test_now_playing_fits_data() { return sizeRows() }

    function test_now_playing_fits(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = host.page
        compare(page.width, row.w - sidebarWidth, "page width")

        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0, reportFor("Now Playing overflows", row, faults))
    }

    function test_now_playing_text_fits_data() { return sizeRows() }

    function test_now_playing_text_fits(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var faults = collectClipped(host.page, "NowPlayingPage", [])
        verify(faults.length === 0, reportFor("Now Playing text clipped", row, faults))
    }

    // The transport row needs 344px of its own. Side by side the text column
    // only ever gets 55% of the content width less the 64px gap, which is 290px
    // at a 960px window, so below the breakpoint the cover has to move above it.
    function test_now_playing_stacks_below_breakpoint_data() { return sizeRows() }

    function test_now_playing_stacks_below_breakpoint(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = host.page
        compare(page.stacked, page.width < page.stackBreakpoint,
                "stacking should follow the page width, not the window width")
        // Whichever way it lays out, the column holding the transport must be
        // wide enough for the transport's fixed content plus its gaps.
        verify(page.infoWidth >= page.transportMinWidth,
               "transport column is " + page.infoWidth.toFixed(1)
               + "px at " + row.tag + " but needs " + page.transportMinWidth)
    }

    // ── crossing the stack breakpoint ────────────────────────────────────
    //
    // The page used to re-form between two frames; it travels now, off the one
    // `stackness` clock. Both halves of that are worth a test, and only one of
    // them is the end state: a case that measures the settled geometry alone
    // passes just as well on the version that snapped.

    // Everything one frame of the move has to agree about.
    function samplePage(page) {
        var cover = findChild(page, "nowPlayingCoverBox")
        var info  = findChild(page, "nowPlayingInfoColumn")
        var flick = findChild(page, "nowPlayingScroll")
        verify(cover && info && flick, "the page's two blocks were not found")
        return {
            t:          page.stackness,
            bodyWidth:  cover.parent.width,
            coverX:     cover.x,
            coverY:     cover.y,
            coverSize:  cover.width,
            infoX:      info.x,
            infoY:      info.y,
            infoWidth:  info.width,
            infoHeight: info.height,
            // Where the bottom of the text column is in the page's own
            // coordinates, which is the figure the page has to be scrollable to.
            infoBottom: info.mapToItem(page, 0, info.height).y,
            reach:      Math.max(cover.y + cover.height, info.y + info.height),
            // Read here and not in the checker: the samples are taken across
            // the move and looked at once it is over, so anything the checker
            // reads off the page itself would be the settled value measured
            // against a mid-flight snapshot.
            bodyReserve: page.bodyHeight,
            contentWidth: page.contentWidth,
            reserved:   cover.parent.height,
            contentH:   flick.contentHeight
        }
    }

    // `previous` is the sample before this one, or null for the first.
    function checkSample(page, s, previous, where) {
        var reach = Math.max(s.coverY + s.coverSize, s.infoY + s.infoHeight)
        // What the page reserves for the pair is exactly what the pair reaches,
        // on every frame: not the average of the two layouts, which is less
        // than the taller block needs halfway through and leaves the bottom of
        // the text column unreachable, and not the stacked height from the
        // first frame, which is the sidebar's "black bar where it will expand
        // to" again.
        verify(Math.abs(s.bodyReserve - reach) <= 1,
               where + ": the page reserves " + s.bodyReserve.toFixed(1)
               + " for blocks that reach " + reach.toFixed(1) + " (t=" + s.t.toFixed(3) + ")")
        // And the container that holds the reservation never runs ahead of
        // them. It is allowed to be one polish behind, and only behind: a
        // QQuickLayout answers at polish time, so the height it has realised is
        // sometimes last frame's, which is the safe side of this -- it is never
        // holding space the blocks have not got to yet.
        var had = previous ? Math.max(reach, previous.reach) : reach
        verify(s.reserved <= had + 1,
               where + ": the container is " + s.reserved.toFixed(1)
               + "px tall for blocks that have only reached " + had.toFixed(1)
               + " (t=" + s.t.toFixed(3) + ")")
        // Neither block hangs out of the page sideways at any point, and the
        // text column's right edge is the page margin at every value of
        // stackness -- which is why the two ends of that lerp are written as a
        // pair rather than each on its own.
        verify(s.coverX >= -0.5 && s.coverX + s.coverSize <= s.bodyWidth + 0.5,
               where + ": the cover is at " + s.coverX.toFixed(1) + ".."
               + (s.coverX + s.coverSize).toFixed(1) + " inside " + s.bodyWidth.toFixed(1))
        verify(s.infoX >= -0.5 && s.infoX + s.infoWidth <= s.bodyWidth + 0.5,
               where + ": the text column is at " + s.infoX.toFixed(1) + ".."
               + (s.infoX + s.infoWidth).toFixed(1) + " inside " + s.bodyWidth.toFixed(1))
        verify(Math.abs(s.infoX + s.infoWidth - s.contentWidth) <= 1.5,
               where + ": the text column ends at "
               + (s.infoX + s.infoWidth).toFixed(1) + " and the page's content is "
               + s.contentWidth.toFixed(1) + " wide, so there is a gap at one margin")
    }

    // Takes the page across the breakpoint and samples it on the way.
    function sweepPage(host, page, from, to) {
        host.width = from
        tryVerify(function () { return page.stackness === (page.stacked ? 1 : 0) },
                  2000, "the page never settled before the sweep began")
        var rows = []
        host.width = to
        // After the frame, not before it: the width is a binding and the layout
        // under it answers at polish time, so sampling in the same turn as the
        // write catches the old layout in the new window and says nothing about
        // the animation either way.
        for (var i = 0; i < 15; i++) {
            wait(16)
            rows.push(samplePage(page))
        }
        tryVerify(function () { return page.stackness === (page.stacked ? 1 : 0) },
                  2000, "the page never settled after the sweep")
        rows.push(samplePage(page))
        return rows
    }

    function midFlightCount(rows) {
        var n = 0
        for (var i = 0; i < rows.length; i++)
            if (rows[i].t > 0.001 && rows[i].t < 0.999) n++
        return n
    }

    function test_now_playing_restacks_without_reserving_ahead_data() {
        // Tall and short, because the short window is the one that scrolls and
        // therefore the one where the reservation is something the user can
        // run into.
        return [
            { tag: "to stacked, tall",       from: 1280, to: 1180, h: 1200, end: 1 },
            { tag: "to side by side, tall",  from: 1180, to: 1280, h: 1200, end: 0 },
            { tag: "to stacked, short",      from: 1280, to: 1180, h: 600,  end: 1 },
            { tag: "to side by side, short", from: 1180, to: 1280, h: 600,  end: 0 }
        ]
    }

    function test_now_playing_restacks_without_reserving_ahead(row) {
        var host = showHost(nowPlayingHost, row.from, row.h)
        var page = host.page
        var rows = sweepPage(host, page, row.from, row.to)

        verify(midFlightCount(rows) >= 3,
               "the page re-formed without ever being between the two layouts: "
               + "only " + midFlightCount(rows) + " of " + rows.length
               + " samples were mid-move, so nothing is being animated")

        for (var i = 0; i < rows.length; i++)
            checkSample(page, rows[i], i > 0 ? rows[i - 1] : null,
                        row.tag + " sample " + i)

        // One direction, no wandering: the clock only ever runs towards the
        // layout the width asked for.
        for (i = 1; i < rows.length; i++) {
            if (row.end === 1)
                verify(rows[i].t >= rows[i - 1].t - 0.001,
                       row.tag + ": stackness went backwards at sample " + i)
            else
                verify(rows[i].t <= rows[i - 1].t + 0.001,
                       row.tag + ": stackness went backwards at sample " + i)
        }

        compare(rows[rows.length - 1].t, row.end,
                "the move has to finish on the layout, not near it")
        // Settled, the bottom of the text column is somewhere the page can
        // actually be scrolled to.
        var last = rows[rows.length - 1]
        verify(last.infoBottom + page.pageMargin <= last.contentH + 1,
               row.tag + ": the column ends at " + last.infoBottom.toFixed(1)
               + " but the page only scrolls to " + last.contentH.toFixed(1))
        compare(page.stacked, page.width < page.stackBreakpoint,
                "stacking should follow the page width once the move is over")
        verify(page.infoWidth >= page.transportMinWidth,
               "the settled transport column is " + page.infoWidth.toFixed(1)
               + "px but needs " + page.transportMinWidth)
        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0,
               reportFor("Now Playing overflows after " + row.tag, row, faults))
    }

    // The layout the suite already sweeps has to be the layout the move lands
    // on, from either side, at every one of those widths.
    function test_now_playing_lands_on_the_swept_layout_data() { return sizeRows() }

    function test_now_playing_lands_on_the_swept_layout(row) {
        // In from the other side of the breakpoint, so every width is reached
        // by a transition rather than by being born at it.
        var opposite = row.w < 1220 ? 1280 : 820
        var host = showHost(nowPlayingHost, opposite, row.h)
        var page = host.page
        sweepPage(host, page, opposite, row.w)

        compare(page.width, row.w - sidebarWidth, "page width")
        compare(page.stacked, page.width < page.stackBreakpoint, "stacking")
        compare(page.stackness, page.stacked ? 1 : 0,
                "the page is still half way between its two layouts at " + row.tag)
        verify(page.infoWidth >= page.transportMinWidth,
               "transport column is " + page.infoWidth.toFixed(1) + "px at " + row.tag)
        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0, reportFor("Now Playing overflows", row, faults))
        faults = collectClipped(page, "NowPlayingPage", [])
        verify(faults.length === 0, reportFor("Now Playing text clipped", row, faults))
    }

    // ── player bar ───────────────────────────────────────────────────────

    function test_player_bar_fits_data() { return sizeRows() }

    function test_player_bar_fits(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        // The host is born wide and shown at row.w, so below the breakpoint the
        // bar is still regrouping for 150ms. This case is about the layout it
        // comes to rest in; the frames in between are
        // test_player_bar_regroups_without_leaving_a_gap's business.
        tryVerify(function () { return host.bar.volumeSlotRoom === host.bar.volumeTargetRoom },
                  2000, "the bar never settled at " + row.tag)
        var faults = collectOverflow(host.bar, "PlayerBar", [])
        verify(faults.length === 0, reportFor("Player bar overflows", row, faults))
    }

    function test_player_bar_text_fits_data() { return sizeRows() }

    function test_player_bar_text_fits(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        tryVerify(function () { return host.bar.volumeSlotRoom === host.bar.volumeTargetRoom },
                  2000, "the bar never settled at " + row.tag)
        var faults = collectClipped(host.bar, "PlayerBar", [])
        verify(faults.length === 0, reportFor("Player bar text clipped", row, faults))
    }

    // The queue button is the last thing in the right-hand group, so it is the
    // first thing to fall off the window when that group is squeezed.
    function test_player_bar_queue_button_on_screen_data() { return sizeRows() }

    function test_player_bar_queue_button_on_screen(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        var bar = host.bar
        tryVerify(function () { return bar.volumeSlotRoom === bar.volumeTargetRoom },
                  2000, "the bar never settled at " + row.tag)
        var btn = bar.queueButton
        verify(btn, "queue button not found")
        var right = btn.mapToItem(bar, btn.width, 0).x
        verify(right <= bar.width + 0.5,
               "queue button right edge is at " + right.toFixed(1)
               + " in a " + bar.width + "px bar at " + row.tag)
        verify(btn.x >= 0, "queue button starts left of the bar")
    }

    // Below the breakpoint the slider goes, so the transport and the track
    // info keep their space. The output button does not go with it: it is
    // what says where the sound is, and hiding it on a narrow window is
    // hiding exactly the thing that has to be true at a glance. Hover brings
    // the slider back (tst_output_picker.qml), so nothing is unreachable.
    function test_player_bar_sheds_controls_when_narrow_data() { return sizeRows() }

    function test_player_bar_sheds_controls_when_narrow(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        var bar = host.bar
        compare(bar.compactRight, row.w < bar.compactRightBreakpoint,
                "compact right group should follow the bar width")
        // The host is born wide and shown at row.w, so at the narrow widths this
        // is a transition and the slider is on its way out rather than already
        // gone. What the breakpoint decides is where it ends up.
        tryVerify(function () { return bar.volumeSlotRoom === bar.volumeTargetRoom },
                  2000, "the bar never settled at " + row.tag)
        compare(bar.volumeSlider.visible, !bar.compactRight, "volume slider visibility")
        verify(bar.outputButton.visible,
               "the output button must be on screen at " + row.tag)
        verify(bar.volumeButton.visible, "muting must stay reachable at " + row.tag)
    }

    // The two blocks cross through each other halfway through the move: they
    // swap both axes at once and each is most of the width of the page, so
    // there is no path between the two layouts that keeps them apart. The
    // clearance to spend is the 64px column gap across and the 32px stack gap
    // down, against a cover of around 400px and 480px of travel; measured at
    // every size below, the text column can be at most 8-19% of the way across
    // while it is anywhere in the first 90% of its way down. What is arranged
    // instead is which of them is on top, and that is what this pins: the
    // artwork passes over the text, never the other way round, so the title is
    // never drawn across album art.
    //
    // The other half of it is that the overlap belongs to the move and to
    // nothing else -- settled, at every width and height, the two are clear by
    // `blockClearance`. A layout change that quietly let them touch at rest
    // would fail here even though both of them fit the page.
    function rectsOf(s) {
        return {
            cover: { l: s.coverX, r: s.coverX + s.coverSize,
                     t: s.coverY, b: s.coverY + s.coverSize },
            info:  { l: s.infoX,  r: s.infoX + s.infoWidth,
                     t: s.infoY,  b: s.infoY + s.infoHeight }
        }
    }

    // Positive is clear by that many pixels, negative is overlapping.
    function separationOf(s) {
        var r = rectsOf(s)
        return Math.max(r.info.l - r.cover.r, r.cover.l - r.info.r,
                        r.info.t - r.cover.b, r.cover.t - r.info.b)
    }

    function test_now_playing_passes_the_artwork_over_the_text_data() {
        var rows = []
        var sizes = sizeRows()
        for (var i = 0; i < sizes.length; i++) {
            // In from the other side of the breakpoint, so every size is
            // reached by a real transition, and out again.
            var opposite = sizes[i].w < 1220 ? 1280 : 820
            rows.push({ tag: sizes[i].tag + " in",  from: opposite, to: sizes[i].w, h: sizes[i].h })
            rows.push({ tag: sizes[i].tag + " out", from: sizes[i].w, to: opposite, h: sizes[i].h })
        }
        return rows
    }

    function test_now_playing_passes_the_artwork_over_the_text(row) {
        if (row.from === row.to) {
            // 1280 sweeps against itself; there is nothing to cross.
            skip("no breakpoint between " + row.from + " and " + row.to)
            return
        }
        var host = showHost(nowPlayingHost, row.from, row.h)
        var page = host.page
        var cover = findChild(page, "nowPlayingCoverBox")
        var info  = findChild(page, "nowPlayingInfoColumn")
        verify(cover && info, "the page's two blocks were not found")

        var rows = sweepPage(host, page, row.from, row.to)
        var overlapped = 0
        for (var i = 0; i < rows.length; i++) {
            if (separationOf(rows[i]) >= blockClearance) continue
            overlapped++
            // Wherever they are not clear of each other, paint order has to be
            // unambiguous and has to put the artwork on top. Siblings with
            // equal z paint in declaration order, and the text column is
            // declared second, so the z is what does this and not luck.
            verify(cover.parent === info.parent,
                   row.tag + ": the blocks are no longer siblings, so their paint "
                   + "order is not a z comparison any more")
            verify(cover.z > info.z,
                   row.tag + " sample " + i + ": the blocks overlap by "
                   + (-separationOf(rows[i])).toFixed(1) + "px with the text column "
                   + "on top (cover z=" + cover.z + ", text z=" + info.z + ")")
        }

        // Settled, they are clear. Checked on the last sample, which sweepPage
        // takes after the move has finished.
        var last = rows[rows.length - 1]
        verify(separationOf(last) >= blockClearance,
               row.tag + ": settled, the two blocks are only "
               + separationOf(last).toFixed(1) + "px apart, which is inside the "
               + blockClearance + "px they are supposed to keep")
        // And the overlap really is confined to the move, so this case is
        // measuring the thing it claims to.
        verify(overlapped < rows.length,
               row.tag + ": every sample overlapped, including the settled one")
    }

    // ── crossing the bar's breakpoint ────────────────────────────────────
    //
    // Shedding the slider used to move the speaker 98px sideways between two
    // frames. The slot it leaves behind closes instead, and the invariant that
    // matters is the one the sidebar got wrong: what the layout reserves for
    // the slot is never more than the slot has actually reached.

    function barSample(bar) {
        var vol = bar.volumeButton
        var out = bar.outputButton
        var q   = bar.queueButton
        var arrow = bar.nowPlayingButton
        return {
            room:      bar.volumeSlotRoom,
            openness:  bar.volumeOpenness,
            slotShown: bar.volumeSlot.visible,
            slotWidth: bar.volumeSlot.width,
            volLeft:   vol.mapToItem(bar, 0, 0).x,
            volRight:  vol.mapToItem(bar, vol.width, 0).x,
            // The group is right-aligned, so where a control sits relative to
            // the bar's right edge is the figure that does not move when the
            // window does: it is the regroup on its own, with the resize that
            // caused it taken out.
            volFromRight: bar.width - vol.mapToItem(bar, vol.width, 0).x,
            outLeft:   out.mapToItem(bar, 0, 0).x,
            arrowLeft: arrow.mapToItem(bar, 0, 0).x,
            queueRight: q.mapToItem(bar, q.width, 0).x
        }
    }

    // `previous` is the sample before this one, or null for the first.
    function checkBarSample(bar, s, previous, where) {
        // The gap between the speaker and the output picker is the output
        // picker's own 8px plus whatever the slot is drawing, and nothing else.
        // A slot that had gone invisible while the group still kept its spacing
        // would show up here as 8px the bar is holding open with nothing in it,
        // which is the thing being guarded against.
        //
        // Both figures are the ones the layout has realised -- the slot's width
        // and the margin that travels with it come out of the same polish pass,
        // so the margin is derived from the realised width rather than from the
        // animation's current value, which may be a pass ahead.
        var held = s.slotShown
                 ? s.slotWidth + 8 * (s.slotWidth / bar.volumeSliderWidth)
                 : 0
        var gap  = s.outLeft - s.volRight
        verify(Math.abs(gap - (8 + held)) <= 1.5,
               where + ": the bar is holding " + gap.toFixed(1)
               + "px open for a slot that is drawing " + held.toFixed(1)
               + " (room=" + s.room.toFixed(1) + ")")
        // And the slot is never wider than the animation has got to, allowing
        // the one polish of latency a QQuickLayout answers with.
        var reached = previous ? Math.max(s.room, previous.room) : s.room
        verify(!s.slotShown || s.slotWidth <= reached + 1,
               where + ": the slot is " + s.slotWidth.toFixed(1)
               + "px wide for a bar that has only given it " + reached.toFixed(1))
        // The two controls that open a view are the ones a squeezed bar drops
        // off the end first, so they are checked at every sample and not only
        // at rest.
        verify(s.queueRight <= bar.width + 0.5,
               where + ": the queue button ends at " + s.queueRight.toFixed(1)
               + " in a " + bar.width + "px bar")
        verify(s.arrowLeft >= 0 && s.volLeft >= 0,
               where + ": a control slid off the left of the bar")
    }

    function sweepBar(host, bar, from, to) {
        host.width = from
        tryVerify(function () { return bar.volumeSlotRoom === bar.volumeTargetRoom },
                  2000, "the bar never settled before the sweep began")
        var rows = []
        host.width = to
        for (var i = 0; i < 14; i++) {
            rows.push(barSample(bar))
            wait(16)
        }
        tryVerify(function () { return bar.volumeSlotRoom === bar.volumeTargetRoom },
                  2000, "the bar never settled after the sweep")
        rows.push(barSample(bar))
        return rows
    }

    function test_player_bar_regroups_without_leaving_a_gap_data() {
        // Two pixels apart, so the only thing that really moves is the slot:
        // the group's right edge stays where it is and the speaker travels the
        // whole width of the slider.
        return [
            { tag: "sheds the slider", from: 721, to: 719, end: 0 },
            { tag: "takes it back",    from: 719, to: 721, end: 90 }
        ]
    }

    function test_player_bar_regroups_without_leaving_a_gap(row) {
        var host = showHost(playerBarHost, row.from, 200)
        var bar = host.bar
        var rows = sweepBar(host, bar, row.from, row.to)

        var mid = 0
        for (var i = 0; i < rows.length; i++)
            if (rows[i].room > 0.5 && rows[i].room < bar.volumeSliderWidth - 0.5) mid++
        verify(mid >= 3,
               "the bar regrouped without ever being between its two layouts: only "
               + mid + " of " + rows.length + " samples were mid-move")

        for (i = 0; i < rows.length; i++)
            checkBarSample(bar, rows[i], i > 0 ? rows[i - 1] : null,
                           row.tag + " sample " + i)

        // The speaker travels one way only. It closes on the right-hand end of
        // the bar as the slot shuts and backs away as it opens, and never
        // overshoots and comes back.
        for (i = 1; i < rows.length; i++) {
            if (row.end === 0)
                verify(rows[i].volFromRight <= rows[i - 1].volFromRight + 1,
                       row.tag + ": the speaker went backwards at sample " + i
                       + " (" + rows[i - 1].volFromRight.toFixed(1) + " then "
                       + rows[i].volFromRight.toFixed(1) + " from the right edge)")
            else
                verify(rows[i].volFromRight >= rows[i - 1].volFromRight - 1,
                       row.tag + ": the speaker went backwards at sample " + i
                       + " (" + rows[i - 1].volFromRight.toFixed(1) + " then "
                       + rows[i].volFromRight.toFixed(1) + " from the right edge)")
        }
        // And it really did travel: the whole point is that this 98px is not a
        // jump any more.
        var travelled = Math.abs(rows[0].volFromRight
                                 - rows[rows.length - 1].volFromRight)
        verify(travelled >= 80,
               row.tag + ": the speaker only moved " + travelled.toFixed(1)
               + "px, so the slider was not what came and went")

        compare(rows[rows.length - 1].room, row.end,
                "the slot has to finish open or closed, not part way")
        compare(bar.volumeSlider.visible, !bar.compactRight,
                "the settled bar disagrees with the breakpoint about its slider")
        compare(bar.volumeInlineGone, bar.compactRight,
                "the hover flyout is gated on an inline slider that is still there")
        var faults = collectOverflow(bar, "PlayerBar", [])
        verify(faults.length === 0,
               reportFor("Player bar overflows after " + row.tag, row, faults))
    }

    // Not every width change is a step across the breakpoint. Half a screen to
    // the 640px window minimum is 320px in one frame, which a tiling shortcut
    // does, and the slot cannot spend 150ms holding 90px a 640px bar has not
    // got: the queue button hung 38px off the end of the window for exactly
    // that long the first time this was written. Sampled from the frame after
    // the jump, which is where it showed.
    function test_player_bar_jumping_to_the_minimum_holds_nothing_back() {
        var host = showHost(playerBarHost, 960, 200)
        var bar = host.bar
        tryVerify(function () { return bar.volumeSlotRoom === bar.volumeSliderWidth },
                  2000, "the wide bar never settled with its slider")

        host.width = 640
        // The controls' own edges rather than collectOverflow, and the reason is
        // not the one that used to be written here. The old note said the handle
        // "sits 5px off the left end of its own track by design" and excluded
        // the slider on that basis. It was not by design: it was the bug the
        // user later met at max volume, and VolumeSlider.qml has since moved the
        // handle's centre to travel between the two radii, so at every value the
        // handle is inside its track. test_volume_slider_handle_stays_inside
        // holds that.
        //
        // What is still true is narrower: a closing slot takes the slider below
        // its own handle's 10px, and a 10px handle in a 4px slider is wider than
        // its parent however it is positioned. The slot clips it and nobody can
        // see it, but the tree walker counts it, so this case measures the bar's
        // right-hand end -- which is what it is about -- and checks the handle
        // directly for every sample where the slider is wide enough to hold it.
        var controls = [bar.volumeButton, bar.outputButton,
                        bar.nowPlayingButton, bar.queueButton]
        var handle = findChild(bar.volumeSlider, "volumeSliderHandle")
        verify(handle, "the volume slider handle was not found")
        for (var i = 0; i < 14; i++) {
            for (var c = 0; c < controls.length; c++) {
                var item = controls[c]
                if (!item.visible) continue
                var left  = item.mapToItem(bar, 0, 0).x
                var right = item.mapToItem(bar, item.width, 0).x
                verify(left >= -0.5 && right <= bar.width + 0.5,
                       "sample " + i + ": a control sits at " + left.toFixed(1) + ".."
                       + right.toFixed(1) + " in a " + bar.width
                       + "px bar while the slot is still "
                       + bar.volumeSlotRoom.toFixed(1) + "px wide")
            }
            var slider = bar.volumeSlider
            if (slider.visible && slider.width >= slider.handleSize) {
                var hl = handle.mapToItem(slider, 0, 0).x
                var hr = handle.mapToItem(slider, handle.width, 0).x
                verify(hl >= -0.5 && hr <= slider.width + 0.5,
                       "sample " + i + ": the handle is at " + hl.toFixed(1) + ".."
                       + hr.toFixed(1) + " in a " + slider.width.toFixed(1)
                       + "px slider, so the closing slot is slicing it")
            }
            wait(16)
        }
        tryVerify(function () { return bar.volumeSlotRoom === 0 }, 2000,
                  "the slot never closed at the window minimum")
        verify(!bar.volumeSlider.visible, "the 640px bar kept its inline slider")
        verify(bar.outputButton.visible,
               "the output button must survive the window minimum")
    }

    // The widths the suite already sweeps, reached by a transition rather than
    // by being born at them.
    function test_player_bar_lands_on_the_swept_layout_data() { return sizeRows() }

    function test_player_bar_lands_on_the_swept_layout(row) {
        var opposite = row.w < 720 ? 1280 : 640
        var host = showHost(playerBarHost, opposite, row.h)
        var bar = host.bar
        sweepBar(host, bar, opposite, row.w)

        compare(bar.compactRight, row.w < bar.compactRightBreakpoint, "compact right group")
        compare(bar.volumeSlotRoom, bar.compactRight ? 0 : bar.volumeSliderWidth,
                "the slot is still part way at " + row.tag)
        compare(bar.volumeSlider.visible, !bar.compactRight, "volume slider visibility")
        verify(bar.outputButton.visible && bar.volumeButton.visible,
               "a control went missing at " + row.tag)
        var faults = collectOverflow(bar, "PlayerBar", [])
        verify(faults.length === 0, reportFor("Player bar overflows", row, faults))
    }

    // ── the volume slider's handle ───────────────────────────────────────
    //
    // The user hit this at max volume: the handle was sliced in half. It was
    // positioned at `value * track.width - 5`, so half of it hung outside the
    // control at both ends -- 5px past the right edge at full volume -- and the
    // bar's volume slot clips, so what was left on screen was half a knob. The
    // handle's centre travels between the two radii now, which is the whole fix
    // and the thing these cases pin.

    function volumeParts(slider) {
        var handle = findChild(slider, "volumeSliderHandle")
        var fill   = findChild(slider, "volumeSliderFill")
        verify(handle, "the volume slider handle was not found")
        verify(fill, "the volume slider fill was not found")
        return {
            handle: handle,
            fill: fill,
            handleLeft:  handle.mapToItem(slider, 0, 0).x,
            handleRight: handle.mapToItem(slider, handle.width, 0).x,
            handleTop:    handle.mapToItem(slider, 0, 0).y,
            handleBottom: handle.mapToItem(slider, 0, handle.height).y,
            fillLeft:  fill.mapToItem(slider, 0, 0).x,
            fillRight: fill.mapToItem(slider, fill.width, 0).x
        }
    }

    function volumeValueRows() {
        var rows = []
        var vals = [0, 0.001, 0.1, 0.25, 0.5, 0.75, 0.999, 1]
        for (var i = 0; i < vals.length; i++)
            rows.push({ tag: "value " + vals[i], v: vals[i] })
        return rows
    }

    function test_volume_slider_handle_stays_inside_data() { return volumeValueRows() }

    function test_volume_slider_handle_stays_inside(row) {
        var host = showHost(volumeSliderHost, 200, 100)
        var slider = host.slider
        slider.value = row.v
        wait(0)
        var p = volumeParts(slider)
        verify(p.handleLeft >= -0.01,
               row.tag + ": the handle starts at " + p.handleLeft.toFixed(2)
               + ", which is off the left end of the slider")
        verify(p.handleRight <= slider.width + 0.01,
               row.tag + ": the handle ends at " + p.handleRight.toFixed(2)
               + " in a " + slider.width + "px slider")
        verify(p.handleTop >= -0.01 && p.handleBottom <= slider.height + 0.01,
               row.tag + ": the handle is at " + p.handleTop.toFixed(2) + ".."
               + p.handleBottom.toFixed(2) + " in a " + slider.height + "px slider")
    }

    // The fill reaches the handle's centre, so there is no bar of colour
    // sticking out past the knob and no gap where the two meet.
    function test_volume_slider_fill_meets_the_handle_data() { return volumeValueRows() }

    function test_volume_slider_fill_meets_the_handle(row) {
        var host = showHost(volumeSliderHost, 200, 100)
        var slider = host.slider
        slider.value = row.v
        wait(0)
        var p = volumeParts(slider)
        verify(p.fillRight <= p.handleRight + 0.01,
               row.tag + ": the fill ends at " + p.fillRight.toFixed(2)
               + " and the handle at " + p.handleRight.toFixed(2)
               + ", so the fill sticks out past the knob")
        verify(p.fillRight >= p.handleLeft - 0.01,
               row.tag + ": the fill ends at " + p.fillRight.toFixed(2)
               + " but the handle only starts at " + p.handleLeft.toFixed(2)
               + ", so there is a gap at the join")
        verify(p.fillLeft >= -0.01 && p.fillRight <= slider.width + 0.01,
               row.tag + ": the fill runs " + p.fillLeft.toFixed(2) + ".."
               + p.fillRight.toFixed(2) + " in a " + slider.width + "px slider")
    }

    // The inset the travel needs must not cost the ends: pressing the extreme
    // left still means silence and the extreme right still means full.
    function test_volume_slider_ends_are_reachable() {
        var host = showHost(volumeSliderHost, 200, 100)
        var slider = host.slider
        var mid = Math.round(slider.height / 2)

        mouseClick(slider, 0, mid)
        compare(host.moves, 1, "a press at the left end should move the slider")
        compare(host.lastMoved, 0, "the extreme left has to reach exactly 0")

        mouseClick(slider, slider.width - 1, mid)
        compare(host.moves, 2, "a press at the right end should move the slider")
        compare(host.lastMoved, 1, "the extreme right has to reach exactly 1")

        // And the middle lands near the middle rather than half a handle away.
        mouseClick(slider, Math.round(slider.width / 2), mid)
        verify(Math.abs(host.lastMoved - 0.5) <= 0.08,
               "a press at the midpoint gave " + host.lastMoved.toFixed(3))
    }

    // The same thing where the user met it: the real bar, at max volume, with
    // the slot clipping anything that hangs over.
    function test_player_bar_volume_handle_is_whole_at_max() {
        player.setVolume(1)
        var host = showHost(playerBarHost, 960, 200)
        var bar = host.bar
        tryVerify(function () { return bar.volumeSlotRoom === bar.volumeTargetRoom },
                  2000, "the bar never settled")
        verify(bar.volumeSlider.visible, "the 960px bar should have its inline slider")
        compare(bar.volumeSlider.value, 1, "the fixture did not reach full volume")

        var slot = bar.volumeSlot
        var handle = findChild(bar.volumeSlider, "volumeSliderHandle")
        verify(handle, "the volume slider handle was not found")
        var right = handle.mapToItem(slot, handle.width, 0).x
        var left  = handle.mapToItem(slot, 0, 0).x
        verify(left >= -0.01 && right <= slot.width + 0.01,
               "at full volume the handle is at " + left.toFixed(2) + ".."
               + right.toFixed(2) + " in a " + slot.width.toFixed(1)
               + "px slot that clips, so half of it is not drawn")
        var faults = collectOverflow(bar, "PlayerBar", [])
        verify(faults.length === 0,
               "player bar overflows at full volume:\n  " + faults.join("\n  "))
    }

    // ── lyrics ───────────────────────────────────────────────────────────
    //
    // The lyrics used to be poured into the artwork's square. In a short window
    // that square floors at 180px, so what the user got was a 185x195 box
    // floating in the middle of the hero with the whole width of the page empty
    // beside it and lines wrapping after four words. The slot has two shapes
    // now, one clock between them, and the list gets a measure.

    // The page's own lyrics state is writable, which is how a test gets timed
    // lyrics: the bridge stub answers fetchLyrics with nothing, by design.
    function giveLyrics(page, n) {
        var lines = []
        for (var i = 0; i < n; i++)
            lines.push({ ms: i * 5000,
                         text: "Line " + i + " of a lyric long enough to want a measure" })
        page.lyricsIsTimed = true
        page.lyricsData    = lines
        page.lyricsState   = "ready"
        page.userScrolled  = false
        page.currentLyricLine = 0
        return lines
    }

    function settlePage(page) {
        tryVerify(function () {
            return page.stackness === (page.stackedLayout ? 1 : 0)
                && page.lyricsness === (page.showLyrics ? 1 : 0)
        }, 3000, "the page never settled")
    }

    function openLyrics(host, lines) {
        var page = host.page
        settlePage(page)
        giveLyrics(page, lines === undefined ? 40 : lines)
        page.showLyrics = true
        settlePage(page)
        waitForRendering(host.contentItem)
        return page
    }

    function test_lyrics_use_the_page_not_the_cover_square_data() { return sizeRows() }

    function test_lyrics_use_the_page_not_the_cover_square(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = host.page
        settlePage(page)
        // The square the lyrics used to be served in.
        var square = page.coverSize

        openLyrics(host)
        var box   = findChild(page, "nowPlayingCoverBox")
        var panel = findChild(page, "nowPlayingLyricsPanel")
        var view  = findChild(page, "nowPlayingLyricsView")
        verify(box && panel && view, "the lyrics panel was not found")
        verify(panel.visible, "the lyrics panel did not open")

        // All the width the page has, up to the measure. This is the half of
        // the complaint that was "the entire width of the page empty to its
        // left and right": at 640 the artwork already took the whole content
        // width, so there is no width there to win, and the gain is the height.
        verify(Math.abs(box.width - Math.min(page.contentWidth, page.lyricsMeasure)) <= 1,
               row.tag + ": the lyrics got " + box.width.toFixed(1)
               + "px of a " + page.contentWidth.toFixed(1) + "px page, capped at "
               + page.lyricsMeasure)
        verify(box.height >= 280 - 0.5,
               row.tag + ": the lyrics column is only " + box.height.toFixed(1) + "px tall")
        // More room than the square it replaced, at every size. Stacking is
        // part of opening the lyrics, and stacking can shrink the cover, so this
        // is measured against the square the lyrics were actually served in.
        verify(box.width * box.height > square * square,
               row.tag + ": the lyrics got " + box.width.toFixed(1) + "x"
               + box.height.toFixed(1) + " where the artwork square was "
               + square.toFixed(1) + ", which is no more room than before")
        // And never smaller than the artwork it is standing in for right now,
        // which is what lets the crossfade leave the cover at its own size while
        // the slot grows around it.
        verify(box.width >= page.coverSize - 0.5 && box.height >= page.coverSize - 0.5,
               row.tag + ": the " + box.width.toFixed(1) + "x" + box.height.toFixed(1)
               + " slot cannot hold the " + page.coverSize.toFixed(1) + "px cover")
        // Still inside the page, at both margins.
        verify(box.x >= -0.5 && box.x + box.width <= page.contentWidth + 0.5,
               row.tag + ": the lyrics column is at " + box.x.toFixed(1) + ".."
               + (box.x + box.width).toFixed(1) + " in " + page.contentWidth.toFixed(1))
        // And the list really has that measure, not just the panel.
        verify(view.width >= box.width - 33,
               row.tag + ": the panel is " + box.width.toFixed(1)
               + " but the list only got " + view.width.toFixed(1))
        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0, reportFor("Now Playing overflows with lyrics", row, faults))
    }

    // The toggle used to be anchored over the list it toggles, which is both why
    // it covered a line of text and why tapping it seeked. It sits in a band the
    // list leaves at the bottom of the panel now.
    function test_lyrics_toggle_clears_the_lyric_lines_data() { return sizeRows() }

    function test_lyrics_toggle_clears_the_lyric_lines(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = openLyrics(host)
        var box    = findChild(page, "nowPlayingCoverBox")
        var view   = findChild(page, "nowPlayingLyricsView")
        var toggle = findChild(page, "nowPlayingLyricsToggle")
        verify(view && toggle, "the list or the toggle was not found")
        verify(toggle.visible, "the toggle has to stay reachable with lyrics open")

        var viewBottom   = view.mapToItem(box, 0, view.height).y
        var toggleTop    = toggle.mapToItem(box, 0, 0).y
        verify(toggleTop >= viewBottom - 0.5,
               row.tag + ": the toggle starts at " + toggleTop.toFixed(1)
               + " and the lyric list only ends at " + viewBottom.toFixed(1)
               + ", so the button is drawn over the words")

        // So does Resync, which floats over the same list.
        page.userScrolled = true
        wait(0)
        var resync = findChild(page, "nowPlayingLyricsResync")
        verify(resync && resync.visible, "the Resync chip did not appear")
        verify(resync.mapToItem(box, 0, 0).y >= viewBottom - 0.5,
               row.tag + ": the Resync chip is drawn over the words")
    }

    // The user: "closing the lyrics tab skips to the line that the lyrics switch
    // button is over." Both tap handlers were on the default DragThreshold
    // policy, which takes no exclusive grab, so one tap was delivered to the
    // chip and to the lyric line under it: the panel closed and playback jumped.
    // Asserting only that the panel closed would pass with the bug present, so
    // what this measures is that nothing seeked.
    function test_lyrics_toggle_closes_without_seeking() {
        var host = showHost(nowPlayingHost, 960, 1200)
        var page = openLyrics(host)
        var toggle = findChild(page, "nowPlayingLyricsToggle")
        verify(toggle && toggle.visible, "the lyrics toggle was not found")

        var wasAt = player.position
        var wasLine = page.currentLyricLine
        verify(wasAt > 0, "the fixture should be playing somewhere, not at zero")

        mouseClick(toggle, Math.round(toggle.width / 2), Math.round(toggle.height / 2))
        tryVerify(function () { return !page.showLyrics }, 2000,
                  "the toggle did not close the lyrics")
        compare(player.position, wasAt,
                "closing the lyrics seeked to the line under the button")
        compare(page.currentLyricLine, wasLine,
                "closing the lyrics moved the active line")
    }

    // Resizing a ListView keeps its scroll offset, not its centred item, and the
    // slot changes both axes when the lyrics open and again when the page
    // restacks. The line being sung has to survive that.
    function test_lyrics_active_line_stays_centred_across_a_mode_change() {
        var host = showHost(nowPlayingHost, 1280, 1200)
        var page = openLyrics(host, 40)
        var view = findChild(page, "nowPlayingLyricsView")
        verify(view, "the lyric list was not found")

        // Far enough into the list that centring is not clamped at either end.
        player.setPositionForTest(20 * 5000)
        tryVerify(function () { return page.currentLyricLine === 20 }, 3000,
                  "the sync timer never reached line 20")

        function centred() {
            var it = view.itemAtIndex(page.currentLyricLine)
            if (!it) return 1e6
            return Math.abs(it.mapToItem(view, 0, it.height / 2).y - view.height / 2)
        }
        tryVerify(function () { return centred() <= 8 }, 3000,
                  "the active line never came to the middle: off by "
                  + centred().toFixed(1) + "px")

        // Across the stack breakpoint, which resizes the lyrics column.
        host.width = 820
        settlePage(page)
        waitForRendering(host.contentItem)
        tryVerify(function () { return centred() <= 8 }, 3000,
                  "after the mode change the active line is off centre by "
                  + centred().toFixed(1) + "px")
        verify(view.width > 0 && view.height > 0, "the list lost its size")
    }

    function test_lyrics_resync_returns_to_the_active_line() {
        var host = showHost(nowPlayingHost, 1280, 1200)
        var page = openLyrics(host, 40)
        var view = findChild(page, "nowPlayingLyricsView")
        player.setPositionForTest(20 * 5000)
        tryVerify(function () { return page.currentLyricLine === 20 }, 3000,
                  "the sync timer never reached line 20")

        // Stand in for a scroll: the flag is what the panel reads, and the
        // offset is what the user would have left behind.
        page.userScrolled = true
        view.contentY = view.contentY + 400
        wait(0)
        var resync = findChild(page, "nowPlayingLyricsResync")
        verify(resync && resync.visible, "Resync should be offered after a scroll")

        mouseClick(resync, Math.round(resync.width / 2), Math.round(resync.height / 2))
        tryVerify(function () { return !page.userScrolled }, 2000,
                  "Resync did not clear the scrolled flag")
        tryVerify(function () {
            var it = view.itemAtIndex(page.currentLyricLine)
            return it && Math.abs(it.mapToItem(view, 0, it.height / 2).y
                                  - view.height / 2) <= 8
        }, 3000, "Resync did not bring the active line back to the middle")
        compare(page.currentLyricLine, 20, "Resync is not a seek")
    }

    // ── the sleep timer pill ─────────────────────────────────────────────
    //
    // The user: "the clock icon is weirdly spaced at the top and bottom in
    // relation to how it's spaced on the left in a fully rounded pill." In a
    // pill the content has to clear the curve, and the clearance at the
    // content's own top corner equals the clearance straight up only when the
    // horizontal padding equals the radius. It was 8 against a radius of 12.
    //
    // The relationship and not the number, so the next person to tighten it
    // fails here rather than shipping it.
    function test_sleep_timer_pill_clears_its_corners_data() {
        return [
            { tag: "idle",         active: false, atEnd: false, left: 0 },
            { tag: "counting",     active: true,  atEnd: false, left: 600 },
            { tag: "end of track", active: true,  atEnd: true,  left: 0 }
        ]
    }

    function test_sleep_timer_pill_clears_its_corners(row) {
        var host = showHost(nowPlayingHost, 1280, 1200)
        host.sleepTimerActive      = row.active
        host.sleepStopAtEndOfTrack = row.atEnd
        host.sleepTimeLeft         = row.left
        wait(0)
        var pill = findChild(host.page, "nowPlayingSleepTimerButton")
        var content = findChild(host.page, "nowPlayingSleepTimerRow")
        verify(pill && content, "the sleep timer pill was not found")
        verify(pill.visible, "the sleep timer pill should be on screen")

        // What the pill actually draws: Theme.radiusChip is a "fully round"
        // sentinel and Qt clamps it to half the shorter side.
        var r = Math.min(pill.radius, pill.height / 2, pill.width / 2)
        var pad = (pill.width - content.width) / 2
        verify(pad >= r - 0.5,
               row.tag + ": the pill pads " + pad.toFixed(1)
               + "px beside a " + r.toFixed(1) + "px corner, so the content "
               + "clears the straight side but not the curve")
        verify(content.height <= pill.height - 2,
               row.tag + ": the content is " + content.height.toFixed(1)
               + "px in a " + pill.height + "px pill, with nothing above or below it")
        // And the padding is a padding, not a gulf: twice the radius would be a
        // different shape again.
        verify(pad <= 2 * r,
               row.tag + ": " + pad.toFixed(1) + "px of padding on a "
               + r.toFixed(1) + "px corner is no longer a pill")
    }

    // A pill that breathes in and out once a second is worse than one with odd
    // padding: "10:00" and "9:59" are different widths and the pill is sized
    // from that label.
    function test_sleep_timer_pill_does_not_jitter_while_counting() {
        var host = showHost(nowPlayingHost, 1280, 1200)
        host.sleepTimerActive      = true
        host.sleepStopAtEndOfTrack = false
        var pill = findChild(host.page, "nowPlayingSleepTimerButton")
        verify(pill, "the sleep timer pill was not found")

        var seconds = [600, 599, 61, 60, 59, 10, 9, 1, 0]
        var first = -1
        var label = findChild(host.page, "nowPlayingSleepTimerLabel")
        verify(label, "the countdown label was not found")
        for (var i = 0; i < seconds.length; i++) {
            host.sleepTimeLeft = seconds[i]
            wait(0)
            if (first < 0) first = pill.width
            compare(pill.width, first,
                    "the pill resized at \"" + label.text + "\": "
                    + pill.width.toFixed(1) + " against " + first.toFixed(1))
        }
    }

    // ── queue panel ──────────────────────────────────────────────────────

    function test_queue_panel_width_data() { return sizeRows() }

    function test_queue_panel_width(row) {
        var host = showHost(queueHost, row.w, row.h)
        var qp = host.panel
        compare(qp.panelWidth, Math.min(340, qp.width * 0.85),
                "panel must not eat a narrow window whole")
        var faults = collectOverflow(qp, "QueuePanel", [])
        verify(faults.length === 0, reportFor("Queue panel overflows", row, faults))
    }

    // L9: the panel had no scrim and no MouseArea, so clicks landed on the page
    // underneath it.
    function test_queue_panel_scrim_swallows_clicks() {
        var host = showHost(queueHost, 960, 1200)
        var qp = host.panel
        verify(qp.width > qp.panelWidth, "need scrim to the left of the panel")
        // Well left of the panel, so this is scrim and nothing else.
        mouseClick(qp, 24, Math.round(qp.height / 2))
        compare(host.pageClicks, 0, "the scrim let a click through to the page")
        compare(host.dismissals, 1, "clicking the scrim should dismiss the queue")
    }

    // A click on the panel itself is the panel's business, not the scrim's.
    function test_queue_panel_body_does_not_dismiss() {
        var host = showHost(queueHost, 960, 1200)
        var qp = host.panel
        mouseClick(qp, Math.round(qp.width - qp.panelWidth / 2), 24)
        compare(host.pageClicks, 0, "the panel let a click through to the page")
        compare(host.dismissals, 0, "clicking the panel should not dismiss it")
    }

    // The swallowing MouseArea sits behind the panel's content, so the content
    // still gets its clicks first. "Clear" is a bare Text with a handler on
    // it, which is the thing most likely to be eaten by a MouseArea
    // underneath. It empties the *manual* queue now - the list the user built
    // - and is only offered while there is one, so the fixture has to make
    // one first.
    function test_queue_panel_content_still_gets_clicks() {
        player.setManualForTest([makeTrack(90), makeTrack(91)])
        var host = showHost(queueHost, 960, 1200)
        var clear = findText(host.panel, qsTr("Clear", "verb, empties the play queue"))
        verify(clear, "the Clear control was not found")
        compare(player.queueManual.length, 2, "fixture should have left a manual queue")
        mouseClick(clear, Math.round(clear.width / 2), Math.round(clear.height / 2))
        compare(player.queueManual.length, 0, "the panel swallowed its own content's click")
        compare(host.dismissals, 0, "a click on the panel is not a dismissal")
    }

    function findText(item, wanted) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            if (isText(c) && c.text === wanted) return c
            var found = findText(c, wanted)
            if (found) return found
        }
        return null
    }

    // ── settings popup ───────────────────────────────────────────────────

    // L10: the popup was a fixed 480x640 against a 600px window minimum, so it
    // did not fit the window it lives in.
    function test_settings_popup_fits_minimum_window() {
        var host = showHost(sideBarHost, 640, 600)
        host.sidebar.openSettings()
        var popup = host.sidebar.settingsPanel
        verify(popup, "settings popup not found")
        verify(popup.visible, "settings popup did not open")
        wait(0)
        verify(popup.width <= 640 - 64 + 0.5,
               "popup is " + popup.width + "px wide in a 640px window")
        verify(popup.height <= 600 - 64 + 0.5,
               "popup is " + popup.height + "px tall in a 600px window")
        verify(popup.x >= -0.5 && popup.y >= -0.5,
               "popup starts off the top or left of the window")
        verify(popup.x + popup.width <= 640 + 0.5
                   && popup.y + popup.height <= 600 + 0.5,
               "popup runs off the bottom or right of the window")
        popup.close()
    }

    function test_settings_popup_fits_data() { return sizeRows() }

    function test_settings_popup_fits(row) {
        var host = showHost(sideBarHost, row.w, row.h)
        host.sidebar.openSettings()
        var popup = host.sidebar.settingsPanel
        wait(0)
        verify(popup.width <= row.w - 64 + 0.5 && popup.height <= row.h - 64 + 0.5,
               "popup is " + popup.width + "x" + popup.height
               + " in a " + row.tag + " window")
        popup.close()
    }

}
