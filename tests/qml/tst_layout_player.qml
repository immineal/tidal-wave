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
            // A VectorIcon is checked, but not opened. Inside it the glyph is a
            // fixed 24x24 Shape centred in the icon and brought down to size by
            // a Scale transform, so below 24px its x and width read as a wild
            // overflow and it paints nowhere near there: at a 14px icon the
            // Shape is at x=-5 and 24 wide, and the ink lands between 1 and 13.
            // This walker compares untransformed geometry, which is the right
            // thing everywhere else and cannot answer that question here.
            // tests/qml/tst_menus_and_glyphs.qml asks it properly, from a grab,
            // for every glyph in the app:
            // test_every_mark_draws_and_only_inside_its_box.
            if (typeof c._pathFor === "function") continue
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
            // What the popup asked for, not just that it asked: the Start
            // button below moved out of the slider's label row and a button
            // that looks right and starts the wrong timer would otherwise
            // read as a pass.
            property int  lastSleepMinutes: -1
            property bool lastSleepAtEnd: false
            function startSleepTimer(minutes, stopAtEnd) {
                sleepTimerActive = true
                lastSleepMinutes = minutes
                lastSleepAtEnd = stopAtEnd === true
            }
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

            // Fullscreen lives on the application window too (Main.qml), and the
            // page can only ask: it reads Window.window.fullScreen and calls
            // Window.window.toggleFullScreen(). Mirror that surface, nothing
            // more - the real one also hides the sidebar and the player bar, and
            // the page's own geometry is what these cases measure.
            property bool fullScreen: false
            function toggleFullScreen() { fullScreen = !fullScreen }

            property alias page: np
            NowPlayingPage {
                id: np
                // Fullscreen hides the sidebar in Main.qml, and a Layout skips an
                // invisible item entirely, so the page gets that width back. The
                // reading view cases below measure the page against the screen,
                // so the host has to hand it the screen.
                x: npWin.fullScreen ? 0 : testCase.sidebarWidth
                width: Math.max(0, npWin.width
                                   - (npWin.fullScreen ? 0 : testCase.sidebarWidth))
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

    // A VolumeSlider on its own, so the handle arithmetic is measured with
    // nothing else in the way. `value` is a plain property here and `moved`
    // writes it back, which is what both hosts do through the player.
    //
    // One host for both orientations: the point of the cases below is that the
    // two are the same arithmetic, and a second host would be the first place
    // the two could be given different numbers.
    Component {
        id: volumeSliderHost
        Window {
            id: vsWin
            width: 200; height: 200
            property bool sliderVertical: false
            property real lastMoved: -1
            property int  moves: 0
            property alias slider: vs
            VolumeSlider {
                id: vs
                orientation: vsWin.sliderVertical ? Qt.Vertical : Qt.Horizontal
                width:  vsWin.sliderVertical ? 20 : 90
                height: vsWin.sliderVertical ? 110 : 20
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

    // The size goes in as an initial property rather than being assigned after
    // creation, which is not a detail. Assigned after, nowPlayingHost came up at
    // the 960 it declares - 960 less the sidebar is under the 1000px breakpoint,
    // so the page was born stacked - and every 1280 row then measured it part
    // way through the 170ms rearrangement out of that, because waitForRendering()
    // waits for a frame and not for an animation. Which frame it landed on
    // depended on the machine, so the resting-layout cases below were measuring
    // a moving layout, differently on every box. Built at its final size there
    // is nothing to move: `stackness` starts at the value its width asks for,
    // and a Behavior does not animate an initial binding. The cases that do want
    // the move drive it themselves, through sweepPage().
    function showHost(component, w, h) {
        var host = createTemporaryObject(component, testCase,
                                         { width: w, height: h })
        verify(host, "host window was not created")
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
            contentH:   flick.contentHeight,
            // The whole tree, not just the pair. checkSample() measures the two
            // blocks' own geometry, and that stayed correct through a frame in
            // which a grandchild of the text column - the seek bar's duration
            // label - sat 116px outside it. The settled cases cannot see that
            // either, because by the time they look the move is over. See the
            // note in qml/components/SeekBar.qml.
            overflow:   collectOverflow(page, "NowPlayingPage", [])
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
        // And nothing anywhere under either block hangs out of its parent on the
        // way, which is a different question from the two above.
        verify(s.overflow.length === 0,
               where + " (t=" + s.t.toFixed(3) + "): something inside the page "
               + "overflowed mid-move:\n  " + s.overflow.join("\n  "))
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
        var faults = collectOverflow(host.bar, "PlayerBar", [])
        verify(faults.length === 0, reportFor("Player bar overflows", row, faults))
    }

    function test_player_bar_text_fits_data() { return sizeRows() }

    function test_player_bar_text_fits(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        var faults = collectClipped(host.bar, "PlayerBar", [])
        verify(faults.length === 0, reportFor("Player bar text clipped", row, faults))
    }

    // The queue button is the last thing in the right-hand group, so it is the
    // first thing to fall off the window when that group is squeezed.
    function test_player_bar_queue_button_on_screen_data() { return sizeRows() }

    function test_player_bar_queue_button_on_screen(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        var bar = host.bar
        var btn = bar.queueButton
        verify(btn, "queue button not found")
        var right = btn.mapToItem(bar, btn.width, 0).x
        verify(right <= bar.width + 0.5,
               "queue button right edge is at " + right.toFixed(1)
               + " in a " + bar.width + "px bar at " + row.tag)
        verify(btn.x >= 0, "queue button starts left of the bar")
    }

    // ── one volume cluster, at every width ───────────────────────────────
    //
    // The bar used to shed a 90px inline slider below 720px and hand the
    // volume to a hover flyout from there down, which meant the bar's volume
    // was two controls depending on how wide the window was. It is one now:
    // the speaker, the readout and the picker at every width, and the slider
    // on hover at every width. tst_output_picker.qml drives the hover; this is
    // about what the layout does with the three that stay.
    //
    // 164px: the 36px speaker-over-readout stack, the 32px picker, the two 32px
    // view buttons and the four 8px gaps, which is also why the old 720px
    // breakpoint has gone. It existed to buy back 98px that the group no longer
    // asks for.
    //
    // It was 204 while the speaker sat beside the readout. Stacking them put
    // the glyph over the number in 36px of width instead of 32 + 8 + 44 = 84,
    // and the 40px that bought back is the whole of what makes the band below
    // move and what hands the track info 240px at the 640px window minimum
    // where it used to get 200.
    readonly property int barVolumeGroupWidth: 164

    function test_player_bar_keeps_one_volume_cluster_data() { return sizeRows() }

    function test_player_bar_keeps_one_volume_cluster(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        var bar = host.bar
        verify(bar.volumeButton.visible, "muting must stay reachable at " + row.tag)
        verify(bar.volumePercentText.visible,
               "the level must stay readable at " + row.tag)
        verify(bar.outputButton.visible,
               "the output button must be on screen at " + row.tag)
        // Nothing inline, at any width. A slider under the bar would mean the
        // hover one is a second control rather than the only one.
        var strays = collectVisibleNamed(bar, "volumeSliderHandle", [])
        compare(strays.length, 0,
                row.tag + ": the bar draws " + strays.length + " inline slider(s)")

        // The group is the same width at every one of them, measured from the
        // volume stack's left edge to the queue button's right. A group whose
        // width moved with the window is the breakpoint coming back.
        //
        // From the stack and not from the speaker inside it: the speaker is 32
        // wide and centred in a 36px stack, so measuring the glyph under-reports
        // the group by the two pixels the readout is wider on each side - which
        // is a thing a reader of this file should not have to know.
        var left  = bar.volumeStack.mapToItem(bar, 0, 0).x
        var right = bar.queueButton.mapToItem(bar, bar.queueButton.width, 0).x
        compare(Math.round(right - left), barVolumeGroupWidth - 8,
                row.tag + ": the right-hand group measures "
                + (right - left).toFixed(1) + "px from the volume stack")
    }

    // ── the speaker over the readout ─────────────────────────────────────
    //
    // The user, on the horizontal cluster: "If there is enough space, and in the
    // bottom bar there definitely is, it makes more sense to put the speaker at
    // the top and the percentage at the bottom, or the other way around, so that
    // when you hover it, the bar is over both of them and not just over one of
    // them. Over the middle would also look weird, and there is enough vertical
    // space, also in full screen now playing and in full screen."
    //
    // So: two rows, one above the other, sharing a vertical centre line, with
    // nothing between them - the gap is paid inside the readout as top padding,
    // so the pair is one unbroken hover target and the pointer cannot fall
    // through a dead strip on its way from the glyph to the number.
    //
    // Both places and both homes. The bar builds its stack out of IconButton
    // and a Text; the page builds its own out of an Item with a VectorIcon and
    // a Text, and the two files do not share that code - only the flyout above
    // it and the output picker beside it are shared. So each is measured.
    function stackShape(root, speaker, readout) {
        var sTop = speaker.mapToItem(root, 0, 0)
        var rTop = readout.mapToItem(root, 0, 0)
        return {
            sx: sTop.x, sy: sTop.y, sw: speaker.width, sh: speaker.height,
            rx: rTop.x, ry: rTop.y, rw: readout.width, rh: readout.height
        }
    }

    function checkStacked(s, where) {
        // The speaker is above the readout, not beside it: the readout begins
        // below the speaker's top edge and ends below its bottom one. Not "the
        // readout begins where the speaker ends" any more - see the strip check
        // at the end of this function for what the bar does instead and why.
        verify(s.ry > s.sy + 0.5 && s.ry + s.rh > s.sy + s.sh + 0.5,
               where + ": the speaker spans y " + s.sy.toFixed(1) + "-"
               + (s.sy + s.sh).toFixed(1) + " and the readout " + s.ry.toFixed(1)
               + "-" + (s.ry + s.rh).toFixed(1)
               + " - the two are not one above the other")
        // ...and they are NOT beside each other: the two boxes share x.
        verify(s.rx < s.sx + s.sw && s.sx < s.rx + s.rw,
               where + ": the speaker spans x " + s.sx.toFixed(1) + "-"
               + (s.sx + s.sw).toFixed(1) + " and the readout " + s.rx.toFixed(1)
               + "-" + (s.rx + s.rw).toFixed(1) + ", which do not overlap")
        // One centre line, so the glyph sits over the middle of the number.
        var sc = s.sx + s.sw / 2, rc = s.rx + s.rw / 2
        verify(Math.abs(sc - rc) <= 0.5,
               where + ": the speaker is centred at " + sc.toFixed(1)
               + " and the readout at " + rc.toFixed(1))
        // No strip between them, which is what makes the two one hover target.
        // One-sided on purpose, and it was not always: the gap is paid inside
        // the readout as its own top padding, so in Now Playing the two boxes
        // meet exactly - and in the bar they now overlap, because the bar's
        // readout is lifted over the 7px of empty box under its IconButton
        // glyph (PlayerBar.volumeSpeakerBoxSlack) so that the two places draw
        // the same gap. An overlap belongs to both of them, which is the whole
        // of the promise. A gap belongs to neither, and is where a pointer on
        // its way down from the glyph to the number drops the flyout.
        verify(s.ry <= s.sy + s.sh + 0.5,
               where + ": there is a " + (s.ry - (s.sy + s.sh)).toFixed(1)
               + "px strip between the speaker and the readout that belongs to "
               + "neither of them")
    }

    function test_the_bar_stacks_the_speaker_over_the_readout_data() {
        return sizeRows()
    }

    function test_the_bar_stacks_the_speaker_over_the_readout(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        var bar = host.bar
        checkStacked(stackShape(bar, bar.volumeButton, bar.volumePercentText),
                     "the bar at " + row.tag)
        // And the stack is as wide as the wider of the two, so the cluster is a
        // fixed object and not one that grows with the glyph's hit target.
        compare(Math.round(bar.volumeStack.width), 36,
                row.tag + ": the bar's volume stack is "
                + bar.volumeStack.width.toFixed(1) + "px wide")
        // The two rows cover the stack from its top edge to its bottom one, so
        // there is no strip anywhere inside it that neither of them hovers. A
        // `spacing` on the column would open one in the middle, and that is
        // caught by checkStacked above; this is the other two places it could
        // open, at the ends.
        //
        // This was "the stack is exactly the two rows added up" and cannot be
        // any more: the bar lifts its readout 7px over the empty bottom of the
        // speaker's tap target and hands the 7px back as the readout's bottom
        // padding, so the box is the same 53px it always was while the two rows
        // now measure 60 between them. The sum was only ever a proxy for this.
        var speakerTop = bar.volumeButton.mapToItem(bar.volumeStack, 0, 0).y
        var readoutEnd = bar.volumePercentText.mapToItem(
                             bar.volumeStack, 0, bar.volumePercentText.height).y
        verify(speakerTop <= 0.5,
               row.tag + ": the speaker starts " + speakerTop.toFixed(1)
               + "px into the stack, so the top of it is hovered by neither row")
        verify(readoutEnd >= bar.volumeStack.height - 0.5,
               row.tag + ": the readout ends at " + readoutEnd.toFixed(1)
               + " in a " + bar.volumeStack.height.toFixed(1)
               + "px stack, so the bottom of it is hovered by neither row")
    }

    function test_the_page_stacks_the_speaker_over_the_readout_data() {
        return volumeRows()
    }

    function test_the_page_stacks_the_speaker_over_the_readout(row) {
        var host = volumeHost(row)
        var page = host.page
        var cluster = volumeCluster(page)
        var mute = findChild(cluster, "nowPlayingMuteButton")
        var pct  = findChild(cluster, "nowPlayingVolumePercent")
        verify(mute && pct, row.tag + ": the page's speaker or readout is missing")
        checkStacked(stackShape(page, mute, pct), "the page at " + row.tag)
        compare(Math.round(cluster.stack.width), page.volumeStackWidth,
                row.tag + ": the page's volume stack is "
                + cluster.stack.width.toFixed(1) + " where the page budgets "
                + page.volumeStackWidth)
        compare(Math.round(cluster.stack.height),
                Math.round(mute.height + pct.height),
                row.tag + ": the stack is " + cluster.stack.height.toFixed(1)
                + "px around an " + mute.height + "px speaker and a "
                + pct.height.toFixed(1) + "px readout")
        // The gap really is inside the readout, which is what makes the two one
        // hover target: its height is the line it draws plus the gap.
        compare(Math.round(pct.height - pct.contentHeight), page.volumeStackGap,
                row.tag + ": the readout is " + pct.height.toFixed(1)
                + "px around " + pct.contentHeight.toFixed(1)
                + "px of text, so the " + page.volumeStackGap
                + "px gap is not being paid as its padding")
        // The picker did not join them. Three in a column takes the transport
        // row from 64 to 71, which is the measurement that kept it out.
        var out = findChild(cluster, "nowPlayingOutputButton")
        var o = out.mapToItem(page, 0, 0)
        var m = mute.mapToItem(page, 0, 0)
        verify(o.x >= m.x + mute.width - 0.5,
               row.tag + ": the output picker has joined the stack at x="
               + o.x.toFixed(1) + " against a speaker at " + m.x.toFixed(1))
    }

    // The point of the stack: the flyout stands over both rows of it rather
    // than over the glyph alone. That is the whole of what the user asked for,
    // and it is a property of the popup's *parent* - parented to the speaker
    // the popup is centred on 32px of glyph, parented to the stack it is
    // centred on the 36px both rows share.
    //
    // Measured as horizontal coverage and not as "the parent is volStack": the
    // popup could be reparented, re-centred or given a different width and the
    // question the user asked would still be the one below.
    function flyoutCoversBoth(host, root, flyout, speaker, readout, where) {
        // A Popup's x is in its parent's coordinates, so the window is the one
        // frame all three can be compared in.
        var fl = flyout.parent.mapToItem(root, flyout.x, flyout.y)
        var fL = fl.x, fR = fl.x + flyout.width, fB = fl.y + flyout.height
        var s = speaker.mapToItem(root, 0, 0)
        var r = readout.mapToItem(root, 0, 0)
        verify(fL <= s.x + 0.5 && fR >= s.x + speaker.width - 0.5,
               where + ": the flyout spans x " + fL.toFixed(1) + "-"
               + fR.toFixed(1) + " and does not cover the speaker at "
               + s.x.toFixed(1) + "-" + (s.x + speaker.width).toFixed(1))
        verify(fL <= r.x + 0.5 && fR >= r.x + readout.width - 0.5,
               where + ": the flyout spans x " + fL.toFixed(1) + "-"
               + fR.toFixed(1) + " and does not cover the readout at "
               + r.x.toFixed(1) + "-" + (r.x + readout.width).toFixed(1))
        // And it is above both of them, which is the other half of "over": a
        // popup drawn across the pair would hide what it is reporting.
        //
        // Against the top of whichever row is higher, not against the speaker's.
        // The flyout is positioned relative to its parent, and with the speaker
        // on top those two are the same number - which is itself a reason the
        // speaker is the one on top: the popup clears the whole stack whether it
        // is parented to the stack or to the speaker in it, so the choice of
        // parent cannot quietly become a bug. Written against the higher row so
        // that swapping the order *would* be caught.
        var stackTop = Math.min(s.y, r.y)
        verify(fB <= stackTop + 0.5,
               where + ": the flyout's bottom edge is at " + fB.toFixed(1)
               + " and the top of the stack at " + stackTop.toFixed(1)
               + ", so it is drawn across the stack rather than above it")
    }

    function test_the_bar_flyout_stands_over_both_rows() {
        var host = showHost(playerBarHost, 960, 200)
        var bar = host.bar
        var btn = bar.volumeButton
        var p = btn.mapToItem(host.contentItem, btn.width / 2, btn.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "the bar's flyout did not open on hover")
        flyoutCoversBoth(host, bar, bar.hoverVolumePopup,
                         bar.volumeButton, bar.volumePercentText, "the bar")
    }

    function test_the_page_flyout_stands_over_both_rows() {
        var host = showHost(nowPlayingHost, 1920, 1200)
        var page = host.page
        settlePage(page)
        waitForRendering(host.contentItem)
        var cluster = volumeCluster(page)
        var mute = findChild(cluster, "nowPlayingMuteButton")
        var pct  = findChild(cluster, "nowPlayingVolumePercent")
        var flyout = volumeFlyoutIn(page)
        var p = mute.mapToItem(host.contentItem, mute.width / 2, mute.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        tryVerify(function () { return flyout.visible }, 2000,
                  "the page's flyout did not open on hover")
        flyoutCoversBoth(host, page, flyout, mute, pct, "the page")
    }

    // ── the vertical room the second row is spent out of ─────────────────
    //
    // "there is enough vertical space, also in full screen now playing and in
    // full screen". Measured rather than taken on trust, at every size the two
    // places are drawn at, because what pays for the second row is different in
    // each:
    //
    //   the bar      an 82px bar around a 59px left group. The stack is 53 -
    //                a 32px IconButton over a 28px readout lifted 7px into the
    //                empty bottom of it, which is 32 - 7 + 28 - so the bar has
    //                29px of slack and the group 6. The readout is 28 and not
    //                the old 21 because it carries the 7px of the lift back as
    //                bottom padding, which is what leaves the box at the 53 it
    //                has always been; see PlayerBar.volumeSpeakerBoxSlack.
    //   the page,    the transport row is 64 tall because the play button in
    //   riding       the middle of it is. The stack is 39, so the row carries it
    //                with 25px to spare and does not grow by a pixel: the
    //                cluster's height has no effect on the column's at all.
    //   the page,    a line of its own, which does grow - from 32 to 39. The
    //   own row      column it is in is already taller than the shortest page
    //                the app allows and scrolls, so the 7px is 7px of scroll and
    //                not an overflow. Held to that by collectOverflow below.
    //
    // The threshold, for the record: the stack would start costing the page
    // height the moment it passed the transport row's 64, which the two-row
    // stack reaches at a 46px readout against the 21 it draws. The three-row
    // version - picker included - measures 71 and does, which is why the picker
    // stays beside the stack.
    function test_the_bar_has_the_room_for_two_rows_data() { return sizeRows() }

    function test_the_bar_has_the_room_for_two_rows(row) {
        var host = showHost(playerBarHost, row.w, row.h)
        var bar = host.bar
        var stack = bar.volumeStack
        var top = stack.mapToItem(bar, 0, 0).y
        verify(top >= 1 - 0.5,
               row.tag + ": the volume stack starts at y=" + top.toFixed(1)
               + ", over the bar's 1px top rule")
        verify(top + stack.height <= bar.height + 0.5,
               row.tag + ": the volume stack reaches y="
               + (top + stack.height).toFixed(1) + " in an "
               + bar.height + "px bar")
        // Two rows, really: a stack no taller than one of them is a stack that
        // folded back into a row and would pass every box check above.
        verify(stack.height >= bar.volumeButton.height + 8,
               row.tag + ": the stack is " + stack.height.toFixed(1)
               + "px tall around a " + bar.volumeButton.height
               + "px speaker, which is not two rows")
    }

    // The case above has a branch per home, and a file in which every size rode
    // the transport row would run only one of them and say nothing about the
    // other. So: both homes occur among the widths this file measures.
    //
    // One window resized rather than fourteen built, because what is being
    // counted is which answer each width gives and not how any of them looks.
    // The reading-view rows are not in here: at 1280 and 1920 the page is the
    // whole screen and every one of them rides, which the case above reports
    // through page.volumeInTransport anyway.
    function test_both_volume_homes_occur_at_the_widths_this_file_measures() {
        var host = showHost(nowPlayingHost, 1920, 1200)
        var widths = [640, 820, 960, 1280, 1920]
        var riding = [], own = []
        for (var i = 0; i < widths.length; i++) {
            host.width = widths[i]
            wait(0)
            if (host.page.volumeInTransport) riding.push(widths[i])
            else own.push(widths[i])
        }
        verify(own.length > 0,
               "every width this file measures rides the transport row ("
               + riding.join(", ") + "), so the fallback row is never tested")
        verify(riding.length > 0,
               "no width this file measures carries the volume on the transport "
               + "row (" + own.join(", ") + ")")
        console.log("HOMES own row at " + own.join(", ")
                    + "; rides at " + riding.join(", "))
    }

    function test_the_page_has_the_room_for_two_rows_data() { return volumeRows() }

    function test_the_page_has_the_room_for_two_rows(row) {
        var host = volumeHost(row)
        var page = host.page
        var cluster = volumeCluster(page)
        var trow = findChild(page, "nowPlayingTransportRow")
        var play = findChild(page, "nowPlayingPlayButton")

        verify(cluster.height >= page.volumeIconSize + 8,
               row.tag + ": the cluster is " + cluster.height.toFixed(1)
               + "px tall, which is not two rows")

        if (page.volumeInTransport) {
            // The row is the play button's height and nothing else's, which is
            // the whole of why the second row costs the column nothing here.
            compare(Math.round(trow.height), Math.round(play.height),
                    row.tag + ": the transport row is " + trow.height.toFixed(1)
                    + "px around a " + play.height + "px play button, so the "
                    + "volume stack has made it taller")
            verify(cluster.height <= trow.height + 0.5,
                   row.tag + ": the cluster is " + cluster.height.toFixed(1)
                   + "px in a " + trow.height.toFixed(1) + "px row")
            var c = cluster.mapToItem(trow, 0, 0)
            verify(c.y >= -0.5 && c.y + cluster.height <= trow.height + 0.5,
                   row.tag + ": the cluster runs from y=" + c.y.toFixed(1)
                   + " to " + (c.y + cluster.height).toFixed(1)
                   + " in a " + trow.height.toFixed(1) + "px row")
        } else {
            var home = volumeHome(page)
            verify(Math.abs(home.height - cluster.height) <= 0.5,
                   row.tag + ": the fallback line is " + home.height.toFixed(1)
                   + "px around a " + cluster.height.toFixed(1) + "px cluster")
        }

        // And nothing anywhere is hanging out of its parent, which is where a
        // second row the page could not pay for would show up.
        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0,
               reportFor("the page overflows with the volume stacked", row, faults))
    }

    // ── what the stack hands back to the track info ──────────────────────
    //
    // Not a thing the user asked for, and the reason the measurement is here:
    // the right-hand group going from 204 to 164 is 40px the bar's left group
    // gets instead, and the left group is where the title elides.
    //
    // b1ee02a shipped a compromise it wrote down - "At 640 that leaves the track
    // info on its 200px minimum against the 280 it asks for, so the title elides
    // between 640 and 675". Measured on that build, the left group ran from
    // 200px at a 640px window to 235 at 675 and 236 at 676, one pixel of group
    // per pixel of window: 236 is the width at which the eliding stopped.
    //
    // Stacking hands the group 240 at the 640px minimum, so there is no window
    // the app allows in which the title has less room than it had where the
    // eliding stopped. The band has moved below Main.qml's minimum and is
    // unreachable.
    //
    // 236 and not "no longer truncated": which title truncates depends on the
    // title, and the fixture's is 358.7px and truncates past 1280 either way.
    // What is a property of the layout rather than of a string is how much room
    // the group gets, so that is what is pinned.
    readonly property int leftGroupWhereElidingStopped: 236

    function test_stacking_hands_the_title_back_the_elided_band() {
        var host = showHost(playerBarHost, 640, 600)
        var bar = host.bar
        var left = bar.trackInfoGroup
        verify(left.width >= leftGroupWhereElidingStopped,
               "at the 640px window minimum the track info gets "
               + left.width.toFixed(1) + "px, where the eliding band it was "
               + "shipped with only cleared at " + leftGroupWhereElidingStopped)
        // And the 40px really came from the volume: the group is 164 here too,
        // so this is not a case that passes because the bar got wider.
        var gl = bar.volumeStack.mapToItem(bar, 0, 0).x
        var gr = bar.queueButton.mapToItem(bar, bar.queueButton.width, 0).x
        compare(Math.round(gr - gl), barVolumeGroupWidth - 8,
                "the right-hand group is " + (gr - gl).toFixed(1)
                + "px at the window minimum")
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

    // ── the bar resizing ─────────────────────────────────────────────────
    //
    // There used to be a breakpoint here. The bar shed its inline slider at
    // 720px and the slot it left behind closed over 150ms, and most of the
    // cases in this spot were about that move not leaving a gap behind it.
    //
    // There is no move any more: the right-hand group is 164px at every width
    // it is drawn at, so what a resize does to it is nothing at all. That is
    // the stronger promise and it is the one measured here - sampled every
    // frame of a resize, because "nothing moves" is only worth asserting
    // against the frames in which something could.

    function barSample(bar) {
        var vol = bar.volumeButton
        var pct = bar.volumePercentText
        var stack = bar.volumeStack
        var out = bar.outputButton
        var q   = bar.queueButton
        var arrow = bar.nowPlayingButton
        return {
            // The group is right-aligned, so where a control sits relative to
            // the bar's right edge is the figure that does not move when the
            // window does: it is the regroup on its own, with the resize that
            // caused it taken out.
            volFromRight:   bar.width - vol.mapToItem(bar, vol.width, 0).x,
            pctFromRight:   bar.width - pct.mapToItem(bar, pct.width, 0).x,
            outFromRight:   bar.width - out.mapToItem(bar, out.width, 0).x,
            queueFromRight: bar.width - q.mapToItem(bar, q.width, 0).x,
            stackLeft: stack.mapToItem(bar, 0, 0).x,
            outLeft:   out.mapToItem(bar, 0, 0).x,
            // The speaker and the readout are one above the other, so the seam
            // between them is horizontal and these two are y.
            volBottom: vol.mapToItem(bar, 0, vol.height).y,
            pctTop:    pct.mapToItem(bar, 0, 0).y,
            // The far ends of the pair as well, because a resize is exactly
            // when a layout could open a hole at one of them.
            volTop:    vol.mapToItem(bar, 0, 0).y,
            pctBottom: pct.mapToItem(bar, 0, pct.height).y,
            stackTop:    stack.mapToItem(bar, 0, 0).y,
            stackBottom: stack.mapToItem(bar, 0, stack.height).y,
            arrowLeft: arrow.mapToItem(bar, 0, 0).x,
            queueRight: q.mapToItem(bar, q.width, 0).x
        }
    }

    function checkBarSample(bar, s, first, where) {
        // Every control in the group keeps its distance from the right-hand
        // edge, whatever the bar is doing. Anything that shrank or grew with
        // the window would show up here.
        var axes = ["volFromRight", "pctFromRight", "outFromRight",
                    "queueFromRight"]
        for (var i = 0; i < axes.length; i++)
            verify(Math.abs(s[axes[i]] - first[axes[i]]) <= 0.5,
                   where + ": " + axes[i] + " moved from "
                   + first[axes[i]].toFixed(1) + " to " + s[axes[i]].toFixed(1)
                   + " while the bar resized")
        // And the speaker and the readout stay against each other, which is
        // what makes them one hover target. Stacked, that is the readout's top
        // edge at or above the speaker's bottom one. Above, here: the bar lifts
        // its readout over the empty bottom of the speaker's tap target, and an
        // overlap belongs to both of them. Only below is a strip that belongs to
        // neither.
        verify(s.pctTop - s.volBottom <= 0.5,
               where + ": a " + (s.pctTop - s.volBottom).toFixed(1)
               + "px strip opened up between the speaker and the readout")
        // ...and the pair still reaches both ends of the stack it is in.
        verify(s.volTop <= s.stackTop + 0.5 && s.pctBottom >= s.stackBottom - 0.5,
               where + ": the pair spans y " + s.volTop.toFixed(1) + "-"
               + s.pctBottom.toFixed(1) + " in a stack spanning "
               + s.stackTop.toFixed(1) + "-" + s.stackBottom.toFixed(1)
               + ", so part of the stack is hovered by neither of them")
        // The two controls that open a view are the ones a squeezed bar drops
        // off the end first, so they are checked at every sample and not only
        // at rest.
        verify(s.queueRight <= bar.width + 0.5,
               where + ": the queue button ends at " + s.queueRight.toFixed(1)
               + " in a " + bar.width + "px bar")
        verify(s.arrowLeft >= 0 && s.stackLeft >= 0,
               where + ": a control slid off the left of the bar")
    }

    function sweepBar(host, bar, from, to) {
        host.width = from
        waitForRendering(host.contentItem)
        var rows = []
        host.width = to
        // One frame before the first sample. Setting a Window's width moves
        // the window's own property at once and the items in it on the next
        // polish pass, so the frame of the assignment is one in which `bar.width`
        // and the controls' positions are measuring two different bars - which
        // says nothing about this code, and is the one frame in which no
        // window has been painted either. A 320px jump reads as a 304px
        // overflow there and nowhere else.
        waitForRendering(host.contentItem)
        for (var i = 0; i < 14; i++) {
            rows.push(barSample(bar))
            wait(16)
        }
        rows.push(barSample(bar))
        return rows
    }

    function test_player_bar_resizes_without_regrouping_data() {
        // Across the width the breakpoint used to be at, both ways, and a
        // jump of the size a tiling shortcut makes: half a screen to the
        // window minimum in one frame, which is what used to hang the queue
        // button 38px off the end of the window for 150ms.
        return [
            { tag: "past the old breakpoint", from: 721, to: 719 },
            { tag: "back past it",            from: 719, to: 721 },
            { tag: "half screen to minimum",  from: 960, to: 640 },
            { tag: "minimum to half screen",  from: 640, to: 960 }
        ]
    }

    function test_player_bar_resizes_without_regrouping(row) {
        var host = showHost(playerBarHost, row.from, 200)
        var bar = host.bar
        var rows = sweepBar(host, bar, row.from, row.to)
        for (var i = 0; i < rows.length; i++)
            checkBarSample(bar, rows[i], rows[0], row.tag + " sample " + i)

        var faults = collectOverflow(bar, "PlayerBar", [])
        verify(faults.length === 0,
               reportFor("Player bar overflows after " + row.tag, row, faults))
    }

    // The widths the suite already sweeps, reached by a transition rather than
    // by being born at them.
    function test_player_bar_lands_on_the_swept_layout_data() { return sizeRows() }

    function test_player_bar_lands_on_the_swept_layout(row) {
        var opposite = row.w < 720 ? 1280 : 640
        var host = showHost(playerBarHost, opposite, row.h)
        var bar = host.bar
        sweepBar(host, bar, opposite, row.w)

        verify(bar.outputButton.visible && bar.volumeButton.visible
               && bar.volumePercentText.visible,
               "a control went missing at " + row.tag)
        var left  = bar.volumeStack.mapToItem(bar, 0, 0).x
        var right = bar.queueButton.mapToItem(bar, bar.queueButton.width, 0).x
        compare(Math.round(right - left), barVolumeGroupWidth - 8,
                "the group did not land at its one width at " + row.tag)
        var faults = collectOverflow(bar, "PlayerBar", [])
        verify(faults.length === 0, reportFor("Player bar overflows", row, faults))
    }

    // ── the volume slider's handle, both ways round ──────────────────────
    //
    // The user hit this at max volume: the handle was sliced in half. It was
    // positioned at `value * track.width - 5`, so half of it hung outside the
    // control at both ends -- 5px past the right edge at full volume -- and the
    // bar's volume slot clips, so what was left on screen was half a knob. The
    // handle's centre travels between the two radii now, which is the whole fix
    // and the thing these cases pin.
    //
    // Every one of them runs twice, once per orientation. That is the reason
    // the upright slider is a mode on the same component rather than a second
    // file: one piece of arithmetic, measured once, and a vertical copy of
    // this bug cannot be introduced without a vertical copy of these failing.
    // The two axes are read through `along` and `across` so each case is
    // written once as well.

    // Everything about a sample that depends on which way the slider runs.
    // `along` is the axis the value travels on, `across` the other one, and
    // both are measured in the slider's own coordinates.
    function volumeParts(slider, vertical) {
        var handle = findChild(slider, "volumeSliderHandle")
        var fill   = findChild(slider, "volumeSliderFill")
        verify(handle, "the volume slider handle was not found")
        verify(fill, "the volume slider fill was not found")
        var hTL = handle.mapToItem(slider, 0, 0)
        var hBR = handle.mapToItem(slider, handle.width, handle.height)
        var fTL = fill.mapToItem(slider, 0, 0)
        var fBR = fill.mapToItem(slider, fill.width, fill.height)
        // Upright, "the loud end" is the top and the value grows towards
        // smaller y, so the axis is read backwards from the far edge. Every
        // case below is then written once, in the direction the value runs.
        var span = vertical ? slider.height : slider.width
        function alongOf(pt)  { return vertical ? span - pt.y : pt.x }
        function acrossOf(pt) { return vertical ? pt.x : pt.y }
        return {
            handle: handle, fill: fill, span: span,
            // The near end of the handle in value order, and the far one.
            handleNear: Math.min(alongOf(hTL), alongOf(hBR)),
            handleFar:  Math.max(alongOf(hTL), alongOf(hBR)),
            handleAcrossNear: Math.min(acrossOf(hTL), acrossOf(hBR)),
            handleAcrossFar:  Math.max(acrossOf(hTL), acrossOf(hBR)),
            fillNear: Math.min(alongOf(fTL), alongOf(fBR)),
            fillFar:  Math.max(alongOf(fTL), alongOf(fBR)),
            acrossSpan: vertical ? slider.width : slider.height
        }
    }

    function volumeValueRows() {
        var rows = []
        var vals = [0, 0.001, 0.1, 0.25, 0.5, 0.75, 0.999, 1]
        var ways = [{ name: "across", vertical: false },
                    { name: "upright", vertical: true }]
        for (var w = 0; w < ways.length; w++)
            for (var i = 0; i < vals.length; i++)
                rows.push({ tag: ways[w].name + " at " + vals[i],
                            v: vals[i], vertical: ways[w].vertical })
        return rows
    }

    function sliderHost(vertical) {
        var host = createTemporaryObject(volumeSliderHost, testCase,
                                         { width: 200, height: 200,
                                           sliderVertical: vertical === true })
        verify(host, "slider host was not created")
        host.visible = true
        waitForRendering(host.contentItem)
        return host
    }

    function test_volume_slider_handle_stays_inside_data() { return volumeValueRows() }

    function test_volume_slider_handle_stays_inside(row) {
        var host = sliderHost(row.vertical)
        var slider = host.slider
        slider.value = row.v
        wait(0)
        var p = volumeParts(slider, row.vertical)
        verify(p.handleNear >= -0.01,
               row.tag + ": the handle starts at " + p.handleNear.toFixed(2)
               + ", which is off the quiet end of the slider")
        verify(p.handleFar <= p.span + 0.01,
               row.tag + ": the handle ends at " + p.handleFar.toFixed(2)
               + " in a " + p.span + "px slider")
        verify(p.handleAcrossNear >= -0.01
               && p.handleAcrossFar <= p.acrossSpan + 0.01,
               row.tag + ": the handle is at " + p.handleAcrossNear.toFixed(2)
               + ".." + p.handleAcrossFar.toFixed(2) + " across a "
               + p.acrossSpan + "px slider")
    }

    // The fill reaches the handle's centre, so there is no bar of colour
    // sticking out past the knob and no gap where the two meet.
    function test_volume_slider_fill_meets_the_handle_data() { return volumeValueRows() }

    function test_volume_slider_fill_meets_the_handle(row) {
        var host = sliderHost(row.vertical)
        var slider = host.slider
        slider.value = row.v
        wait(0)
        var p = volumeParts(slider, row.vertical)
        verify(p.fillFar <= p.handleFar + 0.01,
               row.tag + ": the fill ends at " + p.fillFar.toFixed(2)
               + " and the handle at " + p.handleFar.toFixed(2)
               + ", so the fill sticks out past the knob")
        verify(p.fillFar >= p.handleNear - 0.01,
               row.tag + ": the fill ends at " + p.fillFar.toFixed(2)
               + " but the handle only starts at " + p.handleNear.toFixed(2)
               + ", so there is a gap at the join")
        verify(p.fillNear >= -0.01 && p.fillFar <= p.span + 0.01,
               row.tag + ": the fill runs " + p.fillNear.toFixed(2) + ".."
               + p.fillFar.toFixed(2) + " in a " + p.span + "px slider")
    }

    // The inset the travel needs must not cost the ends: pressing the quiet
    // end still means silence and the loud end still means full. Upright, the
    // loud end is the top, which is the half of the mapping that an inverted
    // axis gets wrong without noticing.
    function test_volume_slider_ends_are_reachable_data() {
        return [{ tag: "across", vertical: false },
                { tag: "upright", vertical: true }]
    }

    function test_volume_slider_ends_are_reachable(row) {
        var host = sliderHost(row.vertical)
        var slider = host.slider
        var quiet = row.vertical ? { x: Math.round(slider.width / 2), y: slider.height - 1 }
                                 : { x: 0, y: Math.round(slider.height / 2) }
        var loud  = row.vertical ? { x: Math.round(slider.width / 2), y: 0 }
                                 : { x: slider.width - 1, y: Math.round(slider.height / 2) }
        var mid   = { x: Math.round(slider.width / 2), y: Math.round(slider.height / 2) }

        mouseClick(slider, quiet.x, quiet.y)
        compare(host.moves, 1, row.tag + ": a press at the quiet end should move it")
        compare(host.lastMoved, 0, row.tag + ": the quiet end has to reach exactly 0")

        mouseClick(slider, loud.x, loud.y)
        compare(host.moves, 2, row.tag + ": a press at the loud end should move it")
        compare(host.lastMoved, 1, row.tag + ": the loud end has to reach exactly 1")

        // And the middle lands near the middle rather than half a handle away.
        mouseClick(slider, mid.x, mid.y)
        verify(Math.abs(host.lastMoved - 0.5) <= 0.08,
               row.tag + ": a press at the midpoint gave "
               + host.lastMoved.toFixed(3))
    }

    // The same thing where the user met it: a real slider, at max volume, in
    // the popup that is the only place one is drawn now. There is no clipping
    // slot left to slice the knob, but there is a 10px popup padding, and a
    // handle that hung half out of its control would be drawn over the popup's
    // own border instead.
    function test_hover_volume_handle_is_whole_at_max() {
        player.setVolume(1)
        var host = showHost(playerBarHost, 960, 200)
        var bar = host.bar
        var btn = bar.volumeButton
        var p = btn.mapToItem(host.contentItem, btn.width / 2, btn.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        tryVerify(function () { return bar.hoverVolumePopup.visible }, 2000,
                  "the flyout did not open")
        var slider = bar.hoverVolumeSlider
        compare(slider.value, 1, "the fixture did not reach full volume")

        var parts = volumeParts(slider, true)
        verify(parts.handleNear >= -0.01 && parts.handleFar <= parts.span + 0.01,
               "at full volume the handle runs " + parts.handleNear.toFixed(2)
               + ".." + parts.handleFar.toFixed(2) + " in a "
               + parts.span.toFixed(1) + "px slider, so part of it is outside")
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
                && page.creditsness === (page.showCredits ? 1 : 0)
                && page.readingness === (page.readingView ? 1 : 0)
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

    // The list uses the WHOLE panel, and keeps room for the chips as content
    // margins rather than as a hole in the viewport.
    //
    // This case used to assert the opposite - that the list stopped above the
    // chips - and that is what shipped. It worked and it cost the thing it was
    // protecting: the bottom of the panel stayed permanently empty, the last
    // line of a song could never reach it, and the user reported the box as
    // looking broken. "Nothing is drawn under the chip" was never the
    // requirement; "a tap on the chip does not also seek" was, and that is held
    // by the exclusive grab and measured by the case below.
    function test_the_lyric_list_uses_the_whole_panel_data() { return sizeRows() }

    function test_the_lyric_list_uses_the_whole_panel(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = openLyrics(host)
        var panel  = findChild(page, "nowPlayingLyricsPanel")
        var view   = findChild(page, "nowPlayingLyricsView")
        var toggle = findChild(page, "nowPlayingLyricsToggle")
        verify(panel && view && toggle, "the panel, list or toggle was not found")
        verify(toggle.visible, "the toggle has to stay reachable with lyrics open")

        // The viewport reaches the bottom of the panel, bar the panel's own
        // inset. If a band ever comes back, this is what fails.
        var viewBottom  = view.mapToItem(panel, 0, view.height).y
        verify(viewBottom >= panel.height - 20,
               row.tag + ": the list ends at " + viewBottom.toFixed(1)
               + " in a panel " + panel.height.toFixed(1)
               + " tall, so the bottom of the box cannot show words")

        // ...and the room the chips need is content margin, so a line can still
        // be scrolled clear of them instead of being stuck underneath.
        verify(view.bottomMargin >= 30,
               row.tag + ": the list reserves no content room at the bottom ("
               + view.bottomMargin + "), so the last line cannot clear the chips")
        verify(view.topMargin >= 30,
               row.tag + ": the list reserves no content room at the top ("
               + view.topMargin + "), so the first line can only ever sit flush "
               + "against the top of the panel")

        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0, reportFor("Now Playing overflows with lyrics", row, faults))
    }

    // ── the reading view ─────────────────────────────────────────────────
    //
    // Fullscreen with a panel open is not a second fullscreen and has no control
    // of its own: the chrome row's button is still the only one, and this is what
    // it shows. The user asked for exactly that - "lass uns den fullscreen
    // einfach das anzeigen wenn lyrics an sind und der user auf fullscreen ist" -
    // after finding that the lyrics panel's own fullscreen button "just do[es]
    // the same thing as the button that's like four centimetres to the top
    // right".

    // Screen sizes, not window sizes: fullscreen is the whole screen and the
    // sidebar is gone with it. 1920x1200 is the user's own monitor.
    //
    // `roomy` is whether the page has any height to give the words in the first
    // place. At 600 it has not - the text column alone is taller than that - so
    // there the reading view can only be asked not to make things worse.
    function fullScreenRows() {
        return [
            { tag: "1920x1200", w: 1920, h: 1200, roomy: true  },
            { tag: "1920x1080", w: 1920, h: 1080, roomy: true  },
            { tag: "1280x1200", w: 1280, h: 1200, roomy: true  },
            { tag: "1280x600",  w: 1280, h: 600,  roomy: false }
        ]
    }

    function enterReading(host) {
        host.fullScreen = true
        settlePage(host.page)
        waitForRendering(host.contentItem)
    }

    // The size the first lyric line is really painted at, off the delegate and
    // not off the page's property for it: the page asking for 28 and the list
    // drawing 14 is exactly the kind of disagreement a layout test is for, and
    // reading only the property passed with the delegate reverted to a literal.
    function lyricLinePixelSize(page) {
        var view = findChild(page, "nowPlayingLyricsView")
        if (!view) return -1
        // Whichever delegate the view happens to have realised, not index 0: the
        // list re-wraps when the measure changes and the first line is not
        // always one of them, which would read as "the type is gone" when the
        // type is fine.
        var kids = view.contentItem ? view.contentItem.children : []
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (c && c.visible && typeof c.text === "string" && c.text.length > 0
                    && c.font)
                return c.font.pixelSize
        }
        return -1
    }

    // What an item is really drawn at. Opacity is inherited down the tree, so a
    // parent fading shows here as well as the item itself fading.
    function effectiveOpacity(item) {
        var o = item.opacity
        var p = item.parent
        while (p) { o *= p.opacity; p = p.parent }
        return o
    }

    // Everything the panel is at rest, in one object, so a before and an after
    // can be compared field by field.
    function panelShape(page) {
        var box = findChild(page, "nowPlayingCoverBox")
        verify(box, "the hero slot was not found")
        return { w: box.width, h: box.height, size: page.lyricLineSize,
                 drawn: lyricLinePixelSize(page), info: page.infoHeight }
    }

    function test_reading_view_gives_the_words_the_screen_data() { return fullScreenRows() }

    function test_reading_view_gives_the_words_the_screen(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = openLyrics(host)
        var docked = panelShape(page)

        // Docked, the words are the smaller half of the page: the text column is
        // taller than the panel. That is the thing being changed, so it is
        // measured rather than assumed.
        verify(docked.h < docked.info,
               row.tag + ": docked, the panel is already " + docked.h.toFixed(1)
               + " against a " + docked.info.toFixed(1)
               + "px text column, so this case is measuring nothing")

        enterReading(host)
        verify(page.readingView,
               row.tag + ": fullscreen with the lyrics open is the reading view")

        var reading = panelShape(page)

        // All the width the page has, up to the measure - which is held in
        // characters, so at twice the type it is twice the pixels.
        verify(reading.size === 2 * docked.size,
               row.tag + ": the lyric line is set at " + reading.size
               + "px where docked it was " + docked.size)
        verify(docked.drawn > 0 && reading.drawn > 0,
               row.tag + ": the lyric line's painted size was not measured")
        verify(reading.drawn === reading.size,
               row.tag + ": the page asks for " + reading.size
               + "px lines and the list paints them at " + reading.drawn)
        verify(reading.drawn > docked.drawn,
               row.tag + ": the lines are painted at " + reading.drawn
               + "px, the same as the " + docked.drawn + " they had docked")
        verify(Math.abs(reading.w - Math.min(page.contentWidth, 2 * 640)) <= 1,
               row.tag + ": the words got " + reading.w.toFixed(1)
               + "px of a " + page.contentWidth.toFixed(1) + "px page")
        verify(reading.w > docked.w + 1,
               row.tag + ": the words are no wider than the " + docked.w.toFixed(1)
               + "px they had docked")

        // And all the height the page can spare, with nothing capping it: the
        // 560 the docked panel stops at is gone, and the floor and the room are
        // all that are left.
        var spare = Math.max(page.coverSize, 280, page.stackedCoverRoom)
        verify(Math.abs(reading.h - spare) <= 0.5,
               row.tag + ": the panel is " + reading.h.toFixed(1)
               + " where the page could spare " + spare.toFixed(1))
        verify(reading.h >= docked.h - 0.5,
               row.tag + ": the panel lost height entering the reading view, "
               + docked.h.toFixed(1) + " -> " + reading.h.toFixed(1))

        // Up Next has folded, and that is where the height came from: it is the
        // one block on the page that is neither chrome nor a control.
        var upNext = findChild(page, "nowPlayingUpNextColumn")
        var volume = volumeHome(page)
        verify(upNext, "the Up Next block was not found")
        verify(upNext.height <= 0.5,
               row.tag + ": Up Next is " + upNext.height.toFixed(1)
               + " tall in the reading view, so it did not fold")
        verify(reading.info < docked.info - 1,
               row.tag + ": the text column still stands " + reading.info.toFixed(1)
               + "px tall, so the words gained nothing from the fold")

        // And the volume has not folded. It did once; shown what the fold was
        // worth the user kept it, because the volume slider is something they
        // reach for with the mouse rather than with the arrow keys. This is the
        // assertion that stops it being folded again, and it follows the
        // controls: the volume is not a row of its own any more at these
        // widths, it rides the right-hand end of the transport row, and the
        // guarantee is about wherever volumeHome() finds it.
        verify(volume.implicitHeight > 1,
               row.tag + ": " + volume.objectName + " asks for "
               + volume.implicitHeight.toFixed(1)
               + "px, so this case cannot tell a kept block from a folded one")
        verify(volume.visible,
               row.tag + ": " + volume.objectName
               + " is not visible in the reading view")
        verify(Math.abs(volume.height - volume.implicitHeight) <= 0.5,
               row.tag + ": " + volume.objectName + " is "
               + volume.height.toFixed(1)
               + "px tall against the " + volume.implicitHeight.toFixed(1)
               + "px it asks for, so it folded - the user chose to keep it")
        var volumeOpacity = effectiveOpacity(volume)
        verify(volumeOpacity > 0.99,
               row.tag + ": " + volume.objectName + " is drawn at "
               + volumeOpacity.toFixed(2) + " opacity in the reading view")
        // At these widths the volume's home is the transport row, so the row
        // has to keep its own height too: fold that and the volume folds with
        // it, which is the trade the user turned down. The cluster cannot be
        // folded from inside a row whose tallest child is the 64px play
        // button, so this is where that half of the promise is held.
        var transport = findChild(page, "nowPlayingTransportRow")
        verify(transport, row.tag + ": the transport row was not found")
        verify(Math.abs(transport.height - transport.implicitHeight) <= 0.5,
               row.tag + ": the transport row is " + transport.height.toFixed(1)
               + "px tall against the " + transport.implicitHeight.toFixed(1)
               + "px it asks for, so the volume folded with it")

        // ...and the cluster inside it is the whole cluster at its whole
        // width, not a squeezed version of one. The slider that used to be
        // measured here lives in the hover flyout now, so what is left to
        // keep is the three controls and the width they agree on.
        var readingCluster = volumeCluster(page)
        compare(readingCluster.width, page.volumeClusterWidth,
                row.tag + ": the volume cluster is " + readingCluster.width.toFixed(1)
                + "px in the reading view")
        verify(effectiveOpacity(readingCluster) > 0.99,
               row.tag + ": the volume cluster is drawn at "
               + effectiveOpacity(readingCluster).toFixed(2) + " opacity")
        var readingPct = findChild(readingCluster, "nowPlayingVolumePercent")
        verify(readingPct && readingPct.visible,
               row.tag + ": the reading view lost the level readout")

        // Where the page has the height to give, the words are now the biggest
        // thing on it, which is the whole point and the opposite of the docked
        // measurement above.
        if (row.roomy)
            verify(reading.h > reading.info,
                   row.tag + ": the panel is " + reading.h.toFixed(1)
                   + " against a " + reading.info.toFixed(1)
                   + "px text column, so the page is still mostly not the words")

        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0,
               reportFor("the reading view overflows", row, faults))
    }

    // The chrome row and the transport stay, and they stay at full strength.
    // The user picked this over a cinematic mode that hides them and brings them
    // back on mouse move, so that skipping and scrubbing do not cost a mouse
    // move first. Nothing here may fade.
    function test_reading_view_never_fades_the_chrome_data() { return fullScreenRows() }

    function test_reading_view_never_fades_the_chrome(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = openLyrics(host)
        enterReading(host)

        var names = ["nowPlayingCollapse", "nowPlayingFullscreen",
                     "nowPlayingSeekBar", "nowPlayingTransportRow"]
        for (var i = 0; i < names.length; i++) {
            var it = findChild(page, names[i])
            verify(it, row.tag + ": " + names[i] + " was not found")
            verify(it.visible, row.tag + ": " + names[i]
                   + " is not visible in the reading view")
            var o = effectiveOpacity(it)
            verify(o > 0.99, row.tag + ": " + names[i] + " is drawn at "
                   + o.toFixed(2) + " opacity in the reading view")
            // And actually on the screen, not scrolled off the bottom of it.
            if (row.roomy) {
                var top = it.mapToItem(page, 0, 0).y
                verify(top >= 0 && top + it.height <= page.height + 0.5,
                       row.tag + ": " + names[i] + " sits at " + top.toFixed(1)
                       + ".." + (top + it.height).toFixed(1)
                       + " on a page " + page.height + " tall")
            }
        }
    }

    // One column at every width. Opening a panel already stacks the page
    // whatever the window is doing, so the reading view has no second
    // arrangement to get wrong - and the two blocks still have to be clear of
    // each other once it has settled.
    function test_reading_view_is_one_column_at_every_width_data() {
        var rows = []
        var widths = [640, 820, 960, 1280, 1920]
        for (var i = 0; i < widths.length; i++)
            rows.push({ tag: widths[i] + "x1200", w: widths[i], h: 1200 })
        return rows
    }

    function test_reading_view_is_one_column_at_every_width(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = openLyrics(host)
        enterReading(host)

        compare(page.stackness, 1,
                row.tag + ": the reading view is not one column")
        var box  = findChild(page, "nowPlayingCoverBox")
        var info = findChild(page, "nowPlayingInfoColumn")
        verify(box && info, "the two blocks were not found")
        verify(info.y >= box.y + box.height + blockClearance,
               row.tag + ": the text column starts at " + info.y.toFixed(1)
               + " where the panel ends at " + (box.y + box.height).toFixed(1))
    }

    // The panel's own fullscreen button is gone. The user: "then we also don't
    // need the separate full screen icon in the lyrics thing, right?" - it did
    // the same thing as the chrome row's, which is visible the whole time now.
    function test_the_lyrics_panel_has_no_fullscreen_button_of_its_own() {
        var host = showHost(nowPlayingHost, 1920, 1200)
        var page = openLyrics(host)
        var panel = findChild(page, "nowPlayingLyricsPanel")
        verify(panel && panel.visible, "the lyrics panel did not open")

        verify(findChild(page, "nowPlayingLyricsFullscreen") === null,
               "the lyrics panel still has a fullscreen button of its own")

        // And the one in the chrome row is reachable and is the one that works.
        var chrome = findChild(page, "nowPlayingFullscreen")
        verify(chrome && chrome.visible, "the chrome row's fullscreen button is gone")
        verify(!page.readingView, "the page should not start fullscreen")
        mouseClick(chrome, Math.round(chrome.width / 2),
                           Math.round(chrome.height / 2))
        tryVerify(function () { return page.readingView }, 2000,
                  "the chrome row's button did not put the page into the reading view")
    }

    // The reading view is fullscreen *with a panel*, so a panel that closes
    // itself has to take the reading view with it. Otherwise a track with no
    // lyrics leaves a fullscreen page laid out around a panel that is not
    // there any more.
    function test_a_track_without_lyrics_leaves_the_reading_view_data() {
        return fullScreenRows()
    }

    function test_a_track_without_lyrics_leaves_the_reading_view(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = openLyrics(host)
        enterReading(host)
        verify(page.readingView, row.tag + ": the reading view did not open")

        page.lyricsState = "unavailable"
        verify(!page.showLyrics,
               row.tag + ": the panel stayed open on a track that has no lyrics")
        verify(!page.readingView,
               row.tag + ": the page is still in the reading view with no panel open")
        // Asked before settlePage(), which waits on this among other things.
        tryVerify(function () { return page.readingness === 0 }, 3000,
                  row.tag + ": the page is still drawing the reading view")
        settlePage(page)
        waitForRendering(host.contentItem)

        // Only the panel closed. Fullscreen is the chrome row's button and
        // nothing here is allowed to press it.
        verify(host.fullScreen, row.tag + ": closing the panel also left fullscreen")
        var art = findChild(page, "nowPlayingArt")
        verify(art && art.visible, row.tag + ": the artwork did not come back")
    }

    // And it is reversible: leaving fullscreen puts every number back exactly
    // where it was, rather than leaving the page in a third state.
    function test_leaving_fullscreen_puts_the_panel_back_data() { return fullScreenRows() }

    function test_leaving_fullscreen_puts_the_panel_back(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = openLyrics(host)
        var docked = panelShape(page)

        enterReading(host)
        host.fullScreen = false
        verify(!page.readingView,
               row.tag + ": leaving fullscreen did not leave the reading view")
        // Asked before settlePage(), which waits on this among other things and
        // would otherwise report a page stuck in the reading view as "never
        // settled" without saying what it was stuck in.
        tryVerify(function () { return page.readingness === 0 }, 3000,
                  row.tag + ": the page is still drawing the reading view "
                  + "after leaving fullscreen")
        settlePage(page)
        waitForRendering(host.contentItem)

        var back = panelShape(page)
        compare(back.size, docked.size, row.tag + ": the type did not come back")
        compare(back.drawn, docked.drawn,
                row.tag + ": the painted type did not come back")
        verify(Math.abs(back.w - docked.w) <= 0.5 && Math.abs(back.h - docked.h) <= 0.5,
               row.tag + ": the panel came back at " + back.w.toFixed(1) + "x"
               + back.h.toFixed(1) + " where it was " + docked.w.toFixed(1) + "x"
               + docked.h.toFixed(1))
        verify(Math.abs(back.info - docked.info) <= 0.5,
               row.tag + ": the text column came back at " + back.info.toFixed(1)
               + " where it was " + docked.info.toFixed(1))
    }

    // The credits tab is the same slot and gets the same reading view. Its
    // contents are tests/qml/tst_credits.qml's business; this is the geometry.
    function test_credits_get_the_same_reading_view_data() { return fullScreenRows() }

    function test_credits_get_the_same_reading_view(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = openLyrics(host)
        enterReading(host)
        var withLyrics = panelShape(page)

        page.showCredits = true
        settlePage(page)
        waitForRendering(host.contentItem)
        verify(!page.showLyrics,
               row.tag + ": opening the credits did not close the lyrics")
        verify(page.readingView, row.tag + ": the credits are not the reading view")

        var withCredits = panelShape(page)
        verify(Math.abs(withCredits.w - withLyrics.w) <= 0.5
               && Math.abs(withCredits.h - withLyrics.h) <= 0.5,
               row.tag + ": the credits got " + withCredits.w.toFixed(1) + "x"
               + withCredits.h.toFixed(1) + " where the lyrics got "
               + withLyrics.w.toFixed(1) + "x" + withLyrics.h.toFixed(1))

        var panel = findChild(page, "nowPlayingCreditsPanel")
        verify(panel && panel.visible, row.tag + ": the credits panel did not open")
        var art = findChild(page, "nowPlayingArt")
        verify(art && !art.visible,
               row.tag + ": the artwork is still drawn behind the credits")

        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0,
               reportFor("the credits reading view overflows", row, faults))
    }

    // ── the volume ───────────────────────────────────────────────────────
    //
    // The user: "in the full screen with the lyrics, the volume bar is in a
    // really weird space. Generally, it looking like a second scrub bar and
    // being almost the same length isnt doing it for me". It was a full-width
    // row two blocks under the seek bar, so it was a second bar of almost the
    // same length at every width, not only in the reading view.
    //
    // It is a short fixed-width cluster now - the mute/level speaker, the
    // percentage stacked under it and the output picker beside the pair, 78px
    // of them - with two homes: the
    // right-hand end of the transport row where the column can carry it, and a
    // short right-aligned row of its own where it cannot. The cases below hold
    // both homes to the same promises.
    //
    // The slider is not in it at all any more. "it can also go into its hover
    // to show bar state, no? also I want that hovered bar to be vertical not
    // horizontal" - so it comes up over the page, upright, when the speaker or
    // the readout is pointed at. tst_output_picker.qml drives that hover; what
    // is measured here is the row the hover leaves behind.

    // The outermost block the volume is living in right now. This is what the
    // fold and the fade are asked about, so it has to be the block the page
    // would fold, not something inside it.
    function volumeHome(page) {
        var riding = findChild(page, "nowPlayingVolumeCluster")
        var ownRow = findChild(page, "nowPlayingVolumeRow")
        verify(riding, "the transport row's volume cluster was not found")
        verify(ownRow, "the volume's own row was not found")
        verify(riding.visible !== ownRow.visible,
               "the volume is showing in "
               + (riding.visible ? "both of its homes" : "neither of its homes"))
        compare(riding.visible, page.volumeInTransport,
                "the volume is not in the home the page says it is in")
        return riding.visible ? riding : ownRow
    }

    // The three controls themselves, wherever they are. On the transport row
    // the cluster is the home; on its own row the home is the full-width line
    // it sits at the right-hand end of.
    function volumeCluster(page) {
        var home = volumeHome(page)
        if (home.objectName === "nowPlayingVolumeCluster") return home
        var own = findChild(home, "nowPlayingVolumeOwnCluster")
        verify(own, "the volume's own row has no cluster in it")
        return own
    }

    // The flyout the live cluster reveals. A Popup is not an Item, so it is
    // not among the cluster's `children` and no tree walk will find it: the
    // cluster hands it over through an alias instead.
    function volumeFlyoutIn(page) {
        var f = volumeCluster(page).flyout
        verify(f, "the live cluster has no volume flyout")
        return f
    }

    function volumePercentIn(page) {
        var t = findChild(volumeCluster(page), "nowPlayingVolumePercent")
        verify(t, "the volume readout was not found")
        return t
    }

    // An item's box in page coordinates, and whether two of them meet. The half
    // pixel keeps two boxes that merely touch from reading as an overlap.
    function boxIn(page, item) {
        var p = item.mapToItem(page, 0, 0)
        return { x: p.x, y: p.y, w: item.width, h: item.height }
    }

    function boxesMeet(a, b) {
        return a.x < b.x + b.w - 0.5 && b.x < a.x + a.w - 0.5
            && a.y < b.y + b.h - 0.5 && b.y < a.y + a.h - 0.5
    }

    readonly property var transportNames: ["nowPlayingShuffle", "nowPlayingPrevious",
                                           "nowPlayingPlayButton", "nowPlayingNext",
                                           "nowPlayingRepeat"]

    // Every resting size the page is measured at, windowed and in the reading
    // view: the complaint was about the reading view and then "generally", so
    // both get the same cases.
    function volumeRows() {
        var rows = []
        var win = sizeRows()
        for (var i = 0; i < win.length; i++)
            rows.push({ tag: win[i].tag, w: win[i].w, h: win[i].h, reading: false })
        // sizeRows() stops at 1280, and 1280 less the sidebar lays the page out
        // side by side on a 480px column - too narrow for the cluster. The
        // user's monitor is 1920, so a maximised window is where the volume
        // rides the transport row outside the reading view, and without this
        // row nothing windowed would ever measure that.
        rows.push({ tag: "1920x1200", w: 1920, h: 1200, reading: false })
        var fs = fullScreenRows()
        for (var j = 0; j < fs.length; j++)
            rows.push({ tag: fs[j].tag + " reading", w: fs[j].w, h: fs[j].h,
                        reading: true })
        // Fullscreen with nothing open, which is a third state and not either of
        // the two above: the sidebar is gone so the page has the whole screen,
        // but there is no panel, so the page is side by side wherever it is wide
        // enough and the artwork takes 420 of the width the column would
        // otherwise have. The user named it separately - "also in full screen
        // now playing and in full screen" - and nothing measured it.
        for (var k = 0; k < fs.length; k++)
            rows.push({ tag: fs[k].tag + " fullscreen", w: fs[k].w, h: fs[k].h,
                        reading: false, full: true })
        rows.push({ tag: "640x600 fullscreen", w: 640, h: 600,
                    reading: false, full: true })
        // fullScreenRows() starts at 1280, because the reading view is a thing
        // you enter on a monitor. The volume's own arithmetic is the one part of
        // it that can still change answer at a small size, so the smallest
        // window Main.qml allows gets a reading row here and only here: at 640
        // fullscreen the column is 544 against the 532 the transport row needs,
        // so even the narrowest reading view carries the cluster on the row and
        // the second row of the stack costs the words nothing.
        rows.push({ tag: "640x600 reading", w: 640, h: 600, reading: true })
        return rows
    }

    function volumeHost(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        if (row.reading) { openLyrics(host); enterReading(host) }
        else if (row.full) { host.fullScreen = true; settlePage(host.page) }
        else settlePage(host.page)
        waitForRendering(host.contentItem)
        return host
    }

    // The complaint itself: nothing in the volume reads as a second scrub bar.
    // It is stronger than it was, because there is no horizontal bar left in
    // the row at all - three controls and a readout, 78px of them, against a
    // seek bar that is the width of the column.
    function test_the_volume_is_not_a_second_scrub_bar_data() { return volumeRows() }

    function test_the_volume_is_not_a_second_scrub_bar(row) {
        var host = volumeHost(row)
        var page = host.page
        var cluster = volumeCluster(page)
        var seek    = findChild(page, "nowPlayingSeekBar")
        verify(seek, "the seek bar was not found")

        // Nothing drawn in the row is a horizontal bar: the only slider in
        // this page is in a popup that is not open.
        var strays = collectVisibleNamed(page, "volumeSliderHandle", [])
        compare(strays.length, 0,
                row.tag + ": the page draws " + strays.length
                + " slider(s) at rest, which is the bar coming back")
        verify(cluster.width <= seek.width / 2,
                row.tag + ": the cluster is " + cluster.width.toFixed(1)
                + "px against a " + seek.width.toFixed(1)
                + "px seek bar, which is the second-scrub-bar look again")

        // And the cluster as a whole is the fixed object the transport row's
        // arithmetic is written against. The page computes that width from
        // parts it does not own - PlayerBar.OutputPicker is 32 square at size
        // 20 because it rounds `size + 12` up - so the sum is measured here
        // rather than trusted.
        compare(cluster.implicitWidth, page.volumeClusterWidth,
                row.tag + ": the cluster measures "
                + cluster.implicitWidth.toFixed(1)
                + " where the page budgeted " + page.volumeClusterWidth)
        compare(cluster.width, page.volumeClusterWidth,
                row.tag + ": the cluster was laid out at "
                + cluster.width.toFixed(1) + "px")

        // Flush with the right-hand edge of the text column in both homes, so
        // it reads as parked rather than floating.
        var right = cluster.mapToItem(page, cluster.width, 0).x
        var info  = findChild(page, "nowPlayingInfoColumn")
        var infoRight = info.mapToItem(page, info.width, 0).x
        verify(Math.abs(right - infoRight) <= 0.5,
               row.tag + ": the cluster ends at " + right.toFixed(1)
               + " where the column ends at " + infoRight.toFixed(1))
    }

    // The regression most likely to slip past the eye. The cluster is a fixed
    // object that the transport buttons are placed against, so anything in it
    // that measures itself walks them sideways - and the percentage runs from
    // "0%" to "100%". It carried `width: 36` for that already and the 36 never
    // took, because a Text has an implicit width of its own and the layout
    // reads that instead.
    function test_the_play_button_does_not_move_with_the_volume_text_data() {
        return volumeRows()
    }

    function test_the_play_button_does_not_move_with_the_volume_text(row) {
        var host = volumeHost(row)
        var page = host.page
        var play = findChild(page, "nowPlayingPlayButton")
        verify(play, "the play button was not found")

        function centre() {
            waitForRendering(host.contentItem)
            return play.mapToItem(page, play.width / 2, 0).x
        }

        var seen = []
        var volumes = [0.09, 0.5, 1.0]
        for (var i = 0; i < volumes.length; i++) {
            player.setVolume(volumes[i])
            seen.push({ at: Math.round(volumes[i] * 100) + "%", x: centre() })
        }
        // And muted, which is the one that reads "0%" whatever the volume is.
        player.setMuted(true)
        seen.push({ at: "muted", x: centre() })
        player.setMuted(false)

        for (var j = 1; j < seen.length; j++)
            verify(Math.abs(seen[j].x - seen[0].x) <= 0.01,
                   row.tag + ": the play button sits at " + seen[j].x.toFixed(2)
                   + " at " + seen[j].at + " and at " + seen[0].x.toFixed(2)
                   + " at " + seen[0].at + " - it is drifting with the volume text")
    }

    // Wherever it is, it is clear of the buttons. A cluster that overlapped the
    // repeat button, or hung off the end of the column, would be worse than the
    // row it replaced.
    function test_the_volume_clears_the_transport_buttons_data() { return volumeRows() }

    function test_the_volume_clears_the_transport_buttons(row) {
        var host = volumeHost(row)
        var page = host.page
        var cluster = volumeCluster(page)
        var clusterBox = boxIn(page, cluster)

        for (var i = 0; i < transportNames.length; i++) {
            var btn = findChild(page, transportNames[i])
            verify(btn, row.tag + ": " + transportNames[i] + " was not found")
            verify(btn.visible, row.tag + ": " + transportNames[i] + " is not visible")
            var b = boxIn(page, btn)
            verify(!boxesMeet(clusterBox, b),
                   row.tag + ": the volume cluster at " + clusterBox.x.toFixed(1)
                   + "," + clusterBox.y.toFixed(1) + " " + clusterBox.w.toFixed(1)
                   + "x" + clusterBox.h.toFixed(1) + " runs into "
                   + transportNames[i] + " at " + b.x.toFixed(1) + ","
                   + b.y.toFixed(1) + " " + b.w.toFixed(1) + "x" + b.h.toFixed(1))
        }

        // And nothing anywhere on the page is hanging out of its parent, which
        // is where a cluster that did not fit would show up.
        var faults = collectOverflow(page, "NowPlayingPage", [])
        verify(faults.length === 0,
               reportFor("the page overflows with the volume cluster", row, faults))
    }

    // The narrow fallback, stated. Below transportWithVolumeWidth the transport
    // row cannot carry the cluster without eating into the buttons, so the
    // cluster drops to a row of its own - at the same short width, pushed right
    // rather than stretched back across the column. The transport row is then
    // exactly what it was before any of this, play button in the middle.
    function test_the_volume_drops_to_its_own_row_when_the_column_is_narrow_data() {
        return volumeRows()
    }

    function test_the_volume_drops_to_its_own_row_when_the_column_is_narrow(row) {
        var host = volumeHost(row)
        var page = host.page
        var home = volumeHome(page)
        var trow = findChild(page, "nowPlayingTransportRow")
        var play = findChild(page, "nowPlayingPlayButton")
        verify(trow && play, row.tag + ": the transport row was not found")

        // The buttons, the cluster, its counterweight and two more gaps.
        var needed = page.transportMinWidth + 2 * page.transportSpacing
                   + 2 * page.volumeClusterWidth
        compare(page.transportWithVolumeWidth, needed,
                row.tag + ": the page's own budget does not add up")
        // The page decides off the width the column settles at, which is the
        // width it has here and only here: at rest the two are the same number,
        // and the case is written to say so rather than to assume it.
        compare(page.settledInfoWidth, page.infoWidth,
                row.tag + ": the column has not settled")
        compare(page.volumeInTransport, page.settledInfoWidth >= needed,
                row.tag + ": at " + page.infoWidth.toFixed(1)
                + "px of column the volume is in the wrong home")

        // Either way, the play button is in the middle of the column. That is
        // what the counterweight at the other end of the row is for, and it is
        // also why the row asks for 532 before it will take the cluster at all:
        // where the column cannot pay for both, the volume moves instead of the
        // play button.
        var playCentre = play.mapToItem(trow, play.width / 2, 0).x
        verify(Math.abs(playCentre - trow.width / 2) <= 0.5,
               row.tag + ": the play button is at " + playCentre.toFixed(1)
               + " in a " + trow.width.toFixed(1) + "px row")
        // ...and the shuffle button is still flush with the left-hand edge of
        // the column, where the title and the seek bar start. The counterweight
        // goes after it for exactly that reason; in front of it the row would
        // have 78px of nothing before the first control.
        var shuffle = findChild(page, "nowPlayingShuffle")
        var shuffleX = shuffle.mapToItem(trow, 0, 0).x
        verify(Math.abs(shuffleX) <= 0.5,
               row.tag + ": the shuffle button starts at " + shuffleX.toFixed(1)
               + " instead of the edge of the column")

        if (page.volumeInTransport) {
            compare(home.objectName, "nowPlayingVolumeCluster",
                    row.tag + ": the column has room for the cluster on the row")
            // The row really does hold everything it was budgeted for.
            verify(trow.width + 0.5 >= needed,
                   row.tag + ": the transport row is " + trow.width.toFixed(1)
                   + "px and needs " + needed)
            verify(trow.implicitWidth <= trow.width + 0.5,
                   row.tag + ": the transport row wants "
                   + trow.implicitWidth.toFixed(1) + " and has "
                   + trow.width.toFixed(1))
            // And the counterweight really is the cluster's width, which is the
            // whole mechanism the centring rests on.
            var weight = findChild(page, "nowPlayingTransportWeight")
            verify(weight && weight.visible,
                   row.tag + ": the counterweight is not there")
            compare(weight.width, page.volumeClusterWidth,
                    row.tag + ": the counterweight is " + weight.width.toFixed(1)
                    + " against a " + page.volumeClusterWidth + "px cluster")
        } else {
            compare(home.objectName, "nowPlayingVolumeRow",
                    row.tag + ": the column is too narrow to carry the cluster")
            verify(home.visible, row.tag + ": the volume's own row is not showing")
            // Nothing was taken from the transport: it is the row it always was,
            // counterweight and all out of the way.
            var idle = findChild(page, "nowPlayingTransportWeight")
            verify(idle && !idle.visible,
                   row.tag + ": the counterweight is holding width in a row "
                   + "with no cluster to balance")
            verify(Math.abs(trow.implicitWidth - page.transportMinWidth) <= 0.5,
                   row.tag + ": the transport row wants "
                   + trow.implicitWidth.toFixed(1) + " where the page budgets "
                   + page.transportMinWidth)
            // And the fallback is a short right-aligned cluster, not the
            // full-width bar it replaced.
            var cluster = volumeCluster(page)
            verify(cluster.width < home.width,
                   row.tag + ": the fallback row's cluster fills the whole "
                   + home.width.toFixed(1) + "px line again")
            var gap = home.width - (cluster.mapToItem(home, cluster.width, 0).x)
            verify(Math.abs(gap) <= 0.5,
                   row.tag + ": the fallback cluster is " + gap.toFixed(1)
                   + "px short of the right-hand edge")
        }
    }

    // ── the volume after the window has moved ────────────────────────────
    //
    // The cases above measure a window born at its size. These arrive at one,
    // so the cluster changes home in the step that resizes the transport row.
    function volumeMoveRows() {
        // Each pair is a size that puts the volume on its own row, then one
        // that carries it on the transport row. 640 is the narrowest window
        // Main.qml allows, and the only one here with the row's 8px gap.
        var pairs = [
            [{ tag: "640 windowed", w: 640, h: 600 },
             { tag: "640 fullscreen", w: 640, h: 600, full: true }],
            [{ tag: "840", w: 840, h: 1200 }, { tag: "860", w: 860, h: 1200 }],
            [{ tag: "640", w: 640, h: 1200 }, { tag: "900", w: 900, h: 1200 }]
        ]
        var rows = []
        for (var i = 0; i < pairs.length; i++) {
            var own = pairs[i][0], riding = pairs[i][1]
            rows.push({ tag: own.tag + " to " + riding.tag,
                        from: own, to: riding, riding: true })
            rows.push({ tag: riding.tag + " to " + own.tag,
                        from: riding, to: own, riding: false })
        }
        return rows
    }

    // A frame is asked for and then waited on. With none pending,
    // waitForRendering() on Qt 6.4 sits out its five seconds.
    function settleVolumeHost(host) {
        settlePage(host.page)
        host.update()
        waitForRendering(host.contentItem)
    }

    // Each pair differs in exactly one of width and fullscreen, so every move
    // is a single assignment.
    function moveVolumeHost(host, to) {
        host.fullScreen = to.full === true
        host.width = to.w
        wait(0)
        settleVolumeHost(host)
    }

    function checkVolumeInPlace(page, where, riding) {
        compare(page.volumeInTransport, riding,
                where + ": the volume is in the wrong home")
        var cluster = volumeCluster(page)
        var info    = findChild(page, "nowPlayingInfoColumn")
        var weight  = findChild(page, "nowPlayingTransportWeight")
        var play    = findChild(page, "nowPlayingPlayButton")
        verify(info && weight && play, where + ": the transport row was not found")

        var infoBox = boxIn(page, info)
        var clusterBox = boxIn(page, cluster)
        var right = clusterBox.x + clusterBox.w
        verify(Math.abs(right - (infoBox.x + infoBox.w)) <= 0.5,
               where + ": the cluster ends at " + right.toFixed(1)
               + " where the column ends at " + (infoBox.x + infoBox.w).toFixed(1))

        compare(weight.visible, riding,
                where + ": the counterweight is " + (riding ? "missing" : "still there"))
        if (riding)
            compare(weight.width, cluster.width,
                    where + ": the counterweight is " + weight.width.toFixed(1)
                    + " against a " + cluster.width.toFixed(1) + "px cluster")

        // The row reads left to right with nothing on top of anything. Left
        // edges are compared because the counterweight has no height to box.
        var names = ["nowPlayingShuffle"]
        if (riding) names.push("nowPlayingTransportWeight")
        names.push("nowPlayingPrevious", "nowPlayingPlayButton",
                   "nowPlayingNext", "nowPlayingRepeat")
        if (riding) names.push("nowPlayingVolumeCluster")
        var edge = infoBox.x, before = "the edge of the column"
        for (var i = 0; i < names.length; i++) {
            var item = findChild(page, names[i])
            verify(item && item.visible, where + ": " + names[i] + " is not showing")
            var b = boxIn(page, item)
            verify(b.x >= edge - 0.5,
                   where + ": " + names[i] + " starts at " + b.x.toFixed(1)
                   + " and " + before + " ends at " + edge.toFixed(1))
            // On its own row the cluster sits under the buttons, clear of them.
            verify(riding || !boxesMeet(clusterBox, b),
                   where + ": the volume cluster runs into " + names[i])
            edge = b.x + b.w
            before = names[i]
        }
        verify(edge <= infoBox.x + infoBox.w + 0.5,
               where + ": the row ends at " + edge.toFixed(1)
               + " in a column that ends at " + (infoBox.x + infoBox.w).toFixed(1))

        var centre = play.mapToItem(page, play.width / 2, 0).x
        verify(Math.abs(centre - (infoBox.x + infoBox.w / 2)) <= 0.5,
               where + ": the play button is at " + centre.toFixed(1)
               + " in a column centred on " + (infoBox.x + infoBox.w / 2).toFixed(1))
    }

    function test_the_volume_is_in_place_after_the_window_moves_data() {
        return volumeMoveRows()
    }

    function test_the_volume_is_in_place_after_the_window_moves(row) {
        // Born in the state the row starts from, so the first thing measured
        // after a move is the move the row is named for.
        var host = createTemporaryObject(nowPlayingHost, testCase,
                                         { width: row.from.w, height: row.from.h,
                                           fullScreen: row.from.full === true })
        verify(host, "host window was not created")
        host.visible = true
        var page = host.page
        settleVolumeHost(host)
        checkVolumeInPlace(page, row.from.tag + ", before moving", !row.riding)

        moveVolumeHost(host, row.to)
        checkVolumeInPlace(page, row.tag, row.riding)

        moveVolumeHost(host, row.from)
        checkVolumeInPlace(page, row.tag + " and back", !row.riding)
    }

    // The cost of writing the cluster once and placing it twice: two mute
    // buttons, two readouts, two output pickers and two flyouts exist, and
    // only one of each may be on screen. A control that is drawn twice is a
    // second focus ring, a second thing to click, and - because Qt only keeps
    // an item out of the tab chain while it is really invisible - a tab stop
    // on a control the user cannot see.
    //
    // Counted rather than looked up by name: the live name is handed to
    // whichever copy is showing, so a page showing both would answer a
    // by-name lookup perfectly well and say nothing.
    // Whether an item is anywhere under `ancestor`. Not `item.parent ===`: the
    // speaker and the readout are a row deeper than the picker beside them now,
    // because they live in the stack rather than directly in the cluster, and
    // what the case below is asking is which of the two clusters an on-screen
    // control belongs to - which is a question about the subtree and not about
    // one hop.
    function isInside(item, ancestor) {
        var p = item
        while (p) {
            if (p === ancestor) return true
            p = p.parent
        }
        return false
    }

    function collectVisibleNamed(item, name, out) {
        if (!item || item.visible === false) return out
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; i++)
            collectVisibleNamed(kids[i], name, out)
        return out
    }

    function test_only_one_set_of_volume_controls_is_on_screen_data() {
        return volumeRows()
    }

    function test_only_one_set_of_volume_controls_is_on_screen(row) {
        var host = volumeHost(row)
        var page = host.page

        var names = ["nowPlayingMuteButton", "nowPlayingVolumePercent",
                     "nowPlayingOutputButton"]
        for (var i = 0; i < names.length; i++) {
            var shown = collectVisibleNamed(page, names[i], [])
            compare(shown.length, 1,
                    row.tag + ": " + shown.length + " of " + names[i]
                    + " are on screen")
            verify(isInside(shown[0], volumeCluster(page)),
                   row.tag + ": the " + names[i]
                   + " on screen is not the one in the live cluster")
        }

        // And the live mute button is still the keyboard control it was: it
        // takes focus, and Return and Space still mute. It came across from the
        // old row with its handlers and its focus ring and nothing here is
        // allowed to have dropped them.
        var mute = findChild(page, "nowPlayingMuteButton")
        verify(mute.activeFocusOnTab,
               row.tag + ": the mute button has left the tab chain")
        mute.forceActiveFocus()
        verify(mute.activeFocus, row.tag + ": the mute button cannot take focus")
        verify(!player.muted, row.tag + ": the fixture starts muted")
        keyClick(Qt.Key_Return)
        verify(player.muted, row.tag + ": Return on the mute button did nothing")
        keyClick(Qt.Key_Space)
        verify(!player.muted, row.tag + ": Space on the mute button did nothing")
    }

    // ── where the volume's two homes change over ─────────────────────────
    //
    // The cluster went from 226px to 106 when the slider left it for a flyout,
    // and from 106 to 78 when the speaker was stacked over the readout. That
    // takes transportWithVolumeWidth from 828 to 588 to 532, and each step moves
    // the widths at which the transport row can carry the cluster. The user has
    // accepted that there is a band where the volume drops to a row of its own;
    // what they have not accepted is one nobody measured. These are the measured
    // edges, at the 1200px height the user's monitors give and behind Main.qml's
    // 220px sidebar, so the numbers are window widths and not page widths.
    //
    //    600 - 847   its own row   (stacked, the column is the whole page)
    //    848 - 1219  rides the transport row
    //   1220 - 1331  its own row   (side by side, the column is only 433-531)
    //   1332 and up  rides the transport row
    //
    // The 1220 edge is not the volume's: that is where the page stops stacking
    // and hands most of its width to the artwork, and it has sat at 1220 through
    // both changes. The two that moved this time are 904 -> 848 and 1388 ->
    // 1332, both of them down by 56, which is twice the 28px the cluster lost -
    // the cluster is charged for twice over, once at each end of the row,
    // because the counterweight that keeps the play button centred is its width.
    // (The step before moved the same two edges down by 240, twice 120.)
    //
    // One window, resized, and read without settling the restack on purpose.
    // Both sides of volumeInTransport are closed-form - settledInfoWidth at
    // one end and gapFor(settledInfoWidth) at the other - so the answer at a
    // width does not depend on how the page got to it, and that is worth
    // pinning as much as the numbers are. It did depend on it until this
    // change: the threshold was built out of the *live* transportSpacing, so
    // a 1920 window dragged down to 840 answered 840 with the 524 it was
    // passing through and put the cluster on a row that a window born at 840
    // does not give it.
    //
    // The one turn of the event loop is not the restack: a Window's own width
    // property moves on assignment and the items inside it only on the next
    // turn, so without it every probe below would be answered about the width
    // before.
    function widthAnswer(host, w) {
        host.width = w
        wait(0)
        return host.page.volumeInTransport
    }

    function firstWidthWhere(host, lo, hi, want) {
        // Monotone inside [lo, hi] by construction: each call below is given
        // a range with exactly one edge in it.
        verify(widthAnswer(host, lo) !== want,
               "the search started at " + lo
               + " already on the answer it was looking for")
        while (lo < hi) {
            var mid = Math.floor((lo + hi) / 2)
            if (widthAnswer(host, mid) === want) hi = mid
            else lo = mid + 1
        }
        compare(widthAnswer(host, lo), want,
                "the search landed at " + lo + " without finding the edge")
        compare(widthAnswer(host, lo - 1), !want,
                "the width below " + lo + " gives the same answer, so "
                + lo + " is not an edge")
        return lo
    }

    function test_the_volume_changes_home_at_the_measured_widths() {
        var host = showHost(nowPlayingHost, 1920, 1200)
        var page = host.page

        // The arithmetic the edges come out of, measured rather than trusted:
        // the page adds up parts it does not own. Asked of a wide window,
        // because the transport's own gap tightens to 8 in a column under
        // 344px and the sum goes to 524 with it.
        compare(page.volumeStackWidth, 36, "the stack's budget")
        compare(page.volumeClusterWidth, 78, "the cluster's budget")
        compare(page.transportSpacing, 16, "the transport's resting gap")
        compare(page.transportWithVolumeWidth, 532,
                "what the transport row has to have to carry the cluster")

        verify(!widthAnswer(host, 600),
               "the narrowest window should use the own row")
        var up1 = firstWidthWhere(host, 601, 1219, true)
        compare(up1, 848, "the stacked column picks the volume up at " + up1)

        var down = firstWidthWhere(host, up1 + 1, 1300, false)
        compare(down, 1220, "the page goes side by side at " + down)

        var up2 = firstWidthWhere(host, down + 1, 1700, true)
        compare(up2, 1332, "the side-by-side column picks it up at " + up2)

        // And it stays picked up from there to the user's own maximised
        // window, which is the width that mattered to them.
        verify(widthAnswer(host, 1920),
               "a maximised window on a 1920 monitor does not carry the volume")
    }

    // ── the volume moves without the mouse ───────────────────────────────
    //
    // Three things set the volume from outside this page: the sleep timer's
    // fade (qml/Main.qml calls player.setVolume on a timer), MPRIS
    // (src/mpris/MprisPlayer.cpp), and the Up/Down shortcuts, which are
    // application-wide. The readout and the slider are both bound to the
    // player rather than to each other, and this is what says so.
    function test_the_volume_follows_a_change_from_outside_data() {
        return [{ tag: "riding the transport row", w: 1920, h: 1200 },
                { tag: "on its own row",           w: 1280, h: 1200 }]
    }

    function test_the_volume_follows_a_change_from_outside(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var page = host.page
        settlePage(page)
        waitForRendering(host.contentItem)

        var pct = volumePercentIn(page)
        compare(pct.text, "70%", row.tag + ": the fixture did not start at 70%")

        // The flyout has to follow it while it is open, which is the case the
        // sleep timer's fade actually meets: it runs while the page is up.
        var flyout = volumeFlyoutIn(page)
        var mute = findChild(volumeCluster(page), "nowPlayingMuteButton")
        var p = mute.mapToItem(host.contentItem, mute.width / 2, mute.height / 2)
        mouseMove(host.contentItem, p.x, p.y)
        tryVerify(function () { return flyout.visible }, 2000,
                  row.tag + ": the flyout did not open")
        var handle = findChild(flyout.slider, "volumeSliderHandle")
        verify(handle, row.tag + ": the flyout slider has no handle")
        var wasY = handle.mapToItem(flyout.slider, 0, 0).y

        // What the sleep timer does, a step at a time.
        player.setVolume(0.33)
        wait(0)
        compare(pct.text, "33%", row.tag + ": the readout did not follow")
        compare(flyout.slider.value.toFixed(2), "0.33",
                row.tag + ": the open flyout did not follow")
        var nowY = handle.mapToItem(flyout.slider, 0, 0).y
        verify(nowY > wasY + 1,
               row.tag + ": the handle sat at " + wasY.toFixed(1)
               + " and is now at " + nowY.toFixed(1)
               + ", so turning the volume down did not move it down")

        // And muting from outside - Ctrl+M, or MPRIS - reads as silence in
        // both of them rather than only in the icon.
        player.setMuted(true)
        wait(0)
        compare(pct.text, "0%", row.tag + ": a muted player still reads loud")
        compare(flyout.slider.value, 0, row.tag + ": the flyout still reads loud")
        player.setMuted(false)
        wait(0)
        compare(pct.text, "33%", row.tag + ": unmuting lost the level")
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
    // The two ends of this pill are padded differently on purpose, and this is
    // the end that is NOT the clock's. The leading side lines the glyph up with
    // the cap (see the concentricity case below); the trailing side ends in
    // text, which has no round outline to line up with, so it keeps the corner
    // radius and the pill is tighter at the icon than at the label.
    //
    // This case used to assert the opposite - that BOTH ends pad by the corner
    // radius - from an argument about the clearance at the content's own top
    // corner. The user looked at the result and said the spacing was still
    // wrong, so the rule was wrong, and asserting it here only made it harder
    // to change.
    function test_sleep_timer_pill_pads_its_text_end_data() {
        return [
            { tag: "idle",         active: false, atEnd: false, left: 0 },
            { tag: "counting",     active: true,  atEnd: false, left: 600 },
            { tag: "end of track", active: true,  atEnd: true,  left: 0 }
        ]
    }

    function test_sleep_timer_pill_pads_its_text_end(row) {
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
        var lead  = content.mapToItem(pill, 0, 0).x
        var trail = pill.width - (lead + content.width)

        fuzzyCompare(trail, r, 0.5,
                     row.tag + ": the label end pads " + trail.toFixed(1)
                     + "px beside a " + r.toFixed(1) + "px corner")
        verify(lead < trail - 0.5,
               row.tag + ": the pill pads " + lead.toFixed(1)
               + "px at the clock and " + trail.toFixed(1) + "px at the label, "
               + "so the two ends are the same and the clock is not sitting in "
               + "its cap")
        verify(content.height <= pill.height - 2,
               row.tag + ": the content is " + content.height.toFixed(1)
               + "px in a " + pill.height + "px pill, with nothing above or below it")
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
        var label = findChild(host.page, "nowPlayingSleepTimerLabel")
        verify(label, "the countdown label was not found")

        // Settle before taking the baseline. The pill has just come out of its
        // idle "Sleep Timer" state, which is a different width, and
        // Layout.preferredWidth needs a polish pass to land. Capturing `first`
        // one wait(0) after the flip pinned the *idle* width, so every later
        // sample disagreed with it and the case failed somewhere in the middle
        // of the sweep rather than at the start - which is what a real jitter
        // would look like, and it was not one. It passed alone and failed in a
        // full run, because tst_qml runs every QML file in one process and the
        // timing differs under load.
        //
        // Third attempt at this, so the reasoning is written down. The
        // baseline and the samples must be taken THE SAME WAY, and twice they
        // were not:
        //   1. baseline after one wait(0), samples after wait(0)  -> baseline
        //      pinned the idle width and every later sample disagreed.
        //   2. baseline from a poll loop that stopped when two reads matched,
        //      samples after waitForRendering -> the poll loop cannot tell a
        //      settled width from a STALE one, because an unchanged value
        //      reads as two equal polls either way. On macOS that latched 124
        //      and the real 10:00 width was 94, deterministically, failing on
        //      the very first sample - which is seconds[0], the same 600 the
        //      baseline was taken at. Found by the Mac; on Linux the same bug
        //      only showed up under full-suite load.
        // So: one rendered frame for the baseline, exactly as for the samples.
        host.sleepTimeLeft = seconds[0]
        waitForRendering(pill)
        var first = pill.width
        // ...and prove the baseline itself is not stale, rather than assuming
        // a rendered frame is enough. A width still on its way to somewhere
        // else moves between two frames; a settled one does not. This is the
        // assertion that would have caught both earlier attempts.
        waitForRendering(pill)
        compare(pill.width, first,
                "the pill was still settling when the baseline was taken: "
                + pill.width.toFixed(1) + " one frame after " + first.toFixed(1))
        // And it must be reserving, not merely stable: a pill that had stopped
        // reserving entirely would hold one width here too, by being wrong the
        // same way every time.
        verify(first >= pill.height + label.implicitWidth,
               "the pill is stable but no longer reserves room for the digits")

        for (var i = 0; i < seconds.length; i++) {
            host.sleepTimeLeft = seconds[i]
            // waitForRendering, not wait(0). The claim being tested is about
            // what the user sees, and what the user sees is frames. wait(0)
            // returns in the middle of a turn, between the text changing and
            // the width binding that depends on it re-evaluating, so it can
            // read a width that no frame was ever painted with - which is
            // exactly what it did: 87 against a settled 119, intermittently,
            // only under full-suite load, and never once in isolation.
            //
            // That is the second time this case has reported a jitter that did
            // not exist. The first was the baseline being taken before the pill
            // came out of idle, fixed above. Sampling a rendered frame answers
            // the real question, and still fails on a pill that genuinely
            // breathes, because a real jitter survives into the frame.
            waitForRendering(pill)
            compare(pill.width, first,
                    "the pill resized at \"" + label.text + "\": "
                    + pill.width.toFixed(1) + " against " + first.toFixed(1))
        }
    }

    // The clock and the pill's left cap are two circles, and the user drew the
    // gap they wanted between them twice: first "the clock icon is weirdly
    // spaced at the top and bottom in relation to how it's spaced on the left
    // in a fully rounded pill", then, over a screenshot, "the spacing from the
    // very left of the pill to the left border of the clock, and then the
    // padding on the top and bottom of the clock icon, so that the circular
    // outline of the pill aligns with the circular outline of the clock icon
    // with some padding."
    //
    // That is concentricity: the glyph's centre on the centre of the cap's
    // arc, which makes the ring of air around the clock the same width all the
    // way round the left end. Measured off a render of the pill before this
    // was fixed, the clock's painted rim sat 16px from the pill's left edge
    // and 4px from its top - so the three gaps this checks were 14 / 2 / 2
    // taken on the glyph's box.
    //
    // The box, not the paint: VectorIcon draws its glyph inside its own item
    // at a fixed inset, so an equal box gap is an equal paint gap, and the box
    // is what layout can be held to.
    function test_sleep_timer_glyph_is_concentric_with_the_cap_data() {
        return [
            { tag: "idle",         active: false, atEnd: false, left: 0 },
            { tag: "counting",     active: true,  atEnd: false, left: 600 },
            { tag: "end of track", active: true,  atEnd: true,  left: 0 }
        ]
    }

    function test_sleep_timer_glyph_is_concentric_with_the_cap(row) {
        var host = showHost(nowPlayingHost, 1280, 1200)
        host.sleepTimerActive      = row.active
        host.sleepStopAtEndOfTrack = row.atEnd
        host.sleepTimeLeft         = row.left
        wait(0)
        var pill = findChild(host.page, "nowPlayingSleepTimerButton")
        var icon = findChild(host.page, "nowPlayingSleepTimerIcon")
        verify(pill && icon, "the sleep timer pill or its clock was not found")

        var at    = icon.mapToItem(pill, 0, 0)
        var left  = at.x
        var top   = at.y
        var bot   = pill.height - (at.y + icon.height)

        // Square, or there is no circle to be concentric with.
        fuzzyCompare(icon.width, icon.height, 0.5,
                     row.tag + ": the clock's box is " + icon.width.toFixed(1)
                     + "x" + icon.height.toFixed(1) + ", so it is not drawn round")
        // Centred vertically, which is the easy half.
        fuzzyCompare(top, bot, 0.5,
                     row.tag + ": the clock sits " + top.toFixed(1)
                     + "px below the top and " + bot.toFixed(1) + "px above the bottom")
        // And the half that was wrong: the leading gap is the same ring.
        fuzzyCompare(left, top, 0.5,
                     row.tag + ": " + left.toFixed(1) + "px from the pill's left edge "
                     + "against " + top.toFixed(1) + "px above the clock, so the cap's "
                     + "arc and the clock's rim are not concentric")
        // The gap is a gap: a clock that filled the pill would satisfy every
        // line above with nothing around it at all.
        verify(top >= 4,
               row.tag + ": only " + top.toFixed(1)
               + "px of air around a clock in a " + pill.height + "px pill")
        // The glyph is drawn at the size it is declared at. In a RowLayout the
        // layout imposes a child's implicit size over any plain width/height,
        // and VectorIcon's implicit size is 24 - which is how a clock meant to
        // be 12 came to be painted at 24 in a 28px pill, 2px clear of the top
        // and 14px clear of the side. The same trap as the pill's own
        // implicitWidth, one level down.
        verify(icon.width <= pill.height - 8,
               row.tag + ": the clock is " + icon.width.toFixed(1)
               + "px in a " + pill.height + "px pill, which is the layout "
               + "imposing VectorIcon's implicit 24 over the size asked for")
    }

    // What a colour actually lands on the screen as. The sleep timer pill's
    // counting fill is the accent at an alpha, and its hover is the same accent
    // at a higher one, so r/g/b are identical in both states and only the
    // compositing tells them apart. Over Theme.bg because that is what the Now
    // Playing page draws behind the pill - checked against a grab, where the
    // counting fill came out (7,41,53) and this returns (7,41,53).
    function colorOverBg(c) {
        var g = Theme.bg
        return Qt.rgba(g.r + (c.r - g.r) * c.a,
                       g.g + (c.g - g.g) * c.a,
                       g.b + (c.b - g.b) * c.a,
                       1)
    }

    // Max channel difference between two colours once they are on the screen,
    // 0..255. "Did it change" is a question about what a user can see, so the
    // answer wants a scale with a threshold on it.
    function colorDelta(a, b) {
        var x = colorOverBg(a), y = colorOverBg(b)
        return Math.round(255 * Math.max(Math.abs(x.r - y.r),
                                         Math.abs(x.g - y.g),
                                         Math.abs(x.b - y.b)))
    }

    // The pill opens a popup, and until now it was the only control in this row
    // that gave no sign of being a control. The user: "this button still has
    // the wrong spacing and should also have a hover."
    //
    // Both states, because the counting pill is already tinted and a hover that
    // only shows up on the idle one is half a hover.
    function test_sleep_timer_pill_answers_the_pointer_data() {
        return [
            { tag: "idle",     active: false, left: 0 },
            { tag: "counting", active: true,  left: 600 }
        ]
    }

    function test_sleep_timer_pill_answers_the_pointer(row) {
        var host = showHost(nowPlayingHost, 1280, 1200)
        host.sleepTimerActive      = row.active
        host.sleepStopAtEndOfTrack = false
        host.sleepTimeLeft         = row.left
        wait(0)
        var pill = findChild(host.page, "nowPlayingSleepTimerButton")
        verify(pill, "the sleep timer pill was not found")
        waitForRendering(pill)

        // The two colours the pill is built from, read off the pill rather than
        // sampled while the pointer is somewhere - the same way the
        // ChromeButton hover is checked in tst_reduced_motion.qml. Sampling was
        // tried first and it is how this case nearly shipped vacuous: the
        // pointer is wherever the last case left it, which is the middle of
        // this very pill, so the "resting" sample came back as the hover colour
        // and the test compared it against itself.
        var restFill    = pill.restFill
        var hoverFill   = pill.hoverFill
        var restBorder  = pill.restBorder
        var hoverBorder = pill.hoverBorder

        // The design claim, before any pointer is involved: a hover nobody can
        // see is not one. The floor is 12 of 255 on the ground the pill is
        // drawn on, which this pill clears by a long way in both states - the
        // idle fill steps 30 -> 56 and the counting fill 53 -> 73 in the blue,
        // both off a grab. It is set where it is because the obvious token for
        // the counting state, accentWash, steps 6, and a guard that let that
        // through would be agreeing with a hover nobody can find. Written at 6
        // first, which accentWash passed exactly.
        verify(colorDelta(hoverFill, restFill) >= 12
               || colorDelta(hoverBorder, restBorder) >= 12,
               row.tag + ": the hover is " + hoverFill + " against a resting "
               + restFill + " and " + hoverBorder + " against " + restBorder
               + ", which is not a change anyone will find")

        // How long a pointer move needs before the colour it causes can be
        // read: the fade is Theme.dur(100), and the hover is only delivered
        // when the scene next draws. tryVerify is no use for it - it polls a
        // property without ever letting a frame out, and an unflushed hover
        // looks exactly like a control that has none.
        var settle = Theme.dur(100) + 240

        // Park the pointer off the pill, in TWO moves. The first synthesized
        // move into a freshly shown window does not land - the window takes it
        // as the pointer arriving at a position it is already at - and a park
        // that did not land leaves the pill hovered for the rest of the case.
        mouseMove(pill, -40, -40)
        wait(settle)
        mouseMove(pill, -60, -60)
        wait(settle)
        compare(colorDelta(pill.color, restFill), 0,
                row.tag + ": the pointer was parked off the pill and it is still "
                + pill.color + " rather than its resting " + restFill)

        // Addressed to the pill, which is how tst_layout_pages.qml hovers a
        // track row. The same move addressed to the window's contentItem, at
        // the point the pill maps to, reaches nothing.
        mouseMove(pill, Math.round(pill.width / 2), Math.round(pill.height / 2))
        wait(settle)
        compare(colorDelta(pill.color, hoverFill), 0,
                row.tag + ": under the pointer the pill is " + pill.color
                + " rather than its hover fill " + hoverFill)
        compare(colorDelta(pill.border.color, hoverBorder), 0,
                row.tag + ": under the pointer the border is " + pill.border.color
                + " rather than its hover border " + hoverBorder)

        // And it lets go again, rather than latching the first time it is
        // touched.
        mouseMove(pill, -40, -40)
        wait(settle)
        compare(colorDelta(pill.color, restFill), 0,
                row.tag + ": the pill kept " + pill.color
                + " after the pointer left, against a resting " + restFill)
        compare(colorDelta(pill.border.color, restBorder), 0,
                row.tag + ": the border kept " + pill.border.color
                + " after the pointer left, against a resting " + restBorder)
    }

    // The one glyph in a control, if it has one: VectorIcon is the only thing
    // in this app that carries a _pathFor, which is how collectOverflow above
    // recognises one too.
    function findGlyph(item) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            if (typeof c._pathFor === "function") return c
            var found = findGlyph(c)
            if (found) return found
        }
        return null
    }

    // The sleep timer popup's primary action. "Start" was a 12px accent word
    // at the end of the custom slider's label row, with a hit target the size
    // of the word, in a popup where every other action - six duration chips,
    // "Stop at End of Track", "Cancel Sleep Timer" - is a full-width box. The
    // user: "make the start button in the menu a little bit more present and
    // maybe with a play icon or something and bigger and more prominent."
    //
    // "Primary" is not a thing a layout test can read, so this asks the three
    // questions it stands for here: is it as wide as the popup lets anything
    // be, is it taller than the options it is the primary among, and does it
    // carry a mark rather than being bare type. The old word failed all three,
    // measured by putting it back: 30px wide where the popup offers 236, 17px
    // tall against a 28px duration chip, and no glyph at all.
    function test_sleep_timer_start_is_the_primary_action_in_the_popup() {
        var host = showHost(nowPlayingHost, 960, 1200)
        var popup = findChild(host.page, "nowPlayingSleepTimerPopup")
        verify(popup, "the sleep timer popup was not found")
        popup.open()
        tryVerify(function() { return popup.visible }, 2000,
                  "the sleep timer popup never opened")
        waitForRendering(host.contentItem)

        var start = findChild(host.page, "nowPlayingSleepTimerStart")
        verify(start, "the popup has no Start control to find")
        verify(start.visible && start.width > 0 && start.height > 0,
               "the Start control is not on screen")

        var option = findChild(host.page, "nowPlayingSleepOption")
        verify(option, "the duration options were not found")

        // Full width, which in a Popup is availableWidth: the padding is the
        // popup's and nothing in it is meant to be inset further.
        verify(start.width >= popup.availableWidth - 0.5,
               "Start is " + start.width.toFixed(1) + "px wide in a popup that "
               + "offers " + popup.availableWidth.toFixed(1)
               + ", so it is not the full-width action every other row is")

        // Taller than what it is primary among, by enough to see. The chips
        // are 28 and the two full-width rows 32; a button that merely matched
        // them would be one more row.
        verify(start.height >= option.height + 8,
               "Start is " + start.height.toFixed(1) + "px tall against a "
               + option.height.toFixed(1) + "px duration chip, which is not a "
               + "button that stands out from the options above it")

        var glyph = findGlyph(start)
        verify(glyph, "Start carries no glyph")
        verify(glyph.name.length > 0 && glyph.width > 0 && glyph.height > 0,
               "Start's glyph is \"" + glyph.name + "\" at "
               + glyph.width.toFixed(1) + "x" + glyph.height.toFixed(1)
               + ", which draws nothing")

        // And it still starts the timer the slider is showing. The control
        // moved out of that row, so the wiring is worth re-asking.
        compare(host.lastSleepMinutes, -1, "nothing should have started yet")
        mouseClick(start, Math.round(start.width / 2),
                   Math.round(start.height / 2))
        tryVerify(function() { return host.sleepTimerActive }, 2000,
                  "clicking Start did not start the sleep timer")
        compare(host.lastSleepMinutes, 20,
                "Start asked for " + host.lastSleepMinutes
                + " minutes, not the 20 the custom slider was showing")
        compare(host.lastSleepAtEnd, false,
                "Start asked for the end-of-track timer, which is the row above it")
        tryVerify(function() { return !popup.visible }, 2000,
                  "the popup stayed open after Start was clicked")
    }

    // ── the sleep timer popup's edge behaviour ───────────────────────────

    // The popup hangs off the pill and used to open downwards unconditionally.
    // At the 600px window minimum there is not that much window under the pill,
    // so it ran off the bottom of the screen - and 7931658, which gave it a
    // Start button, made it taller and so made it worse. It flips above the
    // pill now when it has to.

    // Where a popup actually sits. Its own x/y are in its `parent`'s
    // coordinates - the pill's, here - so they say nothing about whether it is
    // on screen; this is the same rectangle in window coordinates.
    function popupRectInWindow(host, popup) {
        var p = popup.parent.mapToItem(host.contentItem, popup.x, popup.y)
        return { x: p.x, y: p.y, w: popup.width, h: popup.height,
                 right: p.x + popup.width, bottom: p.y + popup.height }
    }

    function openSleepTimerPopup(host) {
        var popup = findChild(host.page, "nowPlayingSleepTimerPopup")
        verify(popup, "the sleep timer popup was not found")
        popup.open()
        tryVerify(function() { return popup.visible }, 2000,
                  "the sleep timer popup never opened")
        waitForRendering(host.contentItem)
        verify(popup.width > 0 && popup.height > 0,
               "the sleep timer popup measured "
               + popup.width.toFixed(1) + "x" + popup.height.toFixed(1))
        return popup
    }

    function test_sleep_timer_popup_stays_in_the_window_data() { return sizeRows() }

    // The case that encodes the bug: wherever the pill ends up, the whole
    // popup is inside the window. Which side of the pill it opens on is the
    // next case down; this one does not care, it only cares that all of it is
    // reachable.
    function test_sleep_timer_popup_stays_in_the_window(row) {
        var host = showHost(nowPlayingHost, row.w, row.h)
        var winW = host.contentItem.width
        var winH = host.contentItem.height
        var popup = openSleepTimerPopup(host)
        var r = popupRectInWindow(host, popup)
        var where = " - the popup is " + r.w.toFixed(1) + "x" + r.h.toFixed(1)
                  + " and covers y " + r.y.toFixed(1) + " to " + r.bottom.toFixed(1)
                  + " in a window " + winH.toFixed(1) + "px tall"
        verify(r.bottom <= winH + 0.5,
               "the sleep timer popup hangs " + (r.bottom - winH).toFixed(1)
               + "px off the BOTTOM of the window at " + row.tag + where)
        // Worse than hanging off the bottom: the title and the rows read first
        // are the ones that go.
        verify(r.y >= -0.5,
               "the sleep timer popup hangs " + (-r.y).toFixed(1)
               + "px off the TOP of the window at " + row.tag + where)
        verify(r.x >= -0.5 && r.right <= winW + 0.5,
               "the sleep timer popup sticks out sideways at " + row.tag
               + ": it covers x " + r.x.toFixed(1) + " to " + r.right.toFixed(1)
               + " in a window " + winW.toFixed(1) + "px wide")
    }

    // Which side, and the gap, in both directions - because it is meant to be
    // one rule rather than two, and the pill stays the anchor either way.
    function test_sleep_timer_popup_opens_below_where_there_is_room() {
        var host = showHost(nowPlayingHost, 960, 1200)
        var pill = findChild(host.page, "nowPlayingSleepTimerButton")
        verify(pill, "the sleep timer pill was not found")
        var popup = openSleepTimerPopup(host)
        var r = popupRectInWindow(host, popup)
        var p = pill.mapToItem(host.contentItem, 0, 0)
        var roomBelow = host.contentItem.height - (p.y + pill.height)
        verify(roomBelow >= popup.height + 6,
               "960x1200 was picked because the popup fits under the pill "
               + "there, but there are only " + roomBelow.toFixed(1)
               + "px under it for a " + popup.height.toFixed(1) + "px popup")
        verify(r.y >= p.y + pill.height,
               "with " + roomBelow.toFixed(1) + "px of window under the pill "
               + "the popup should still open downwards, but its top is at "
               + r.y.toFixed(1) + " and the pill ends at "
               + (p.y + pill.height).toFixed(1))
        fuzzyCompare(r.y - (p.y + pill.height), 6, 0.5,
                     "the popup opened below the pill but not 6px below it")
    }

    function test_sleep_timer_popup_flips_above_when_it_must() {
        var host = showHost(nowPlayingHost, 960, 600)
        var pill = findChild(host.page, "nowPlayingSleepTimerButton")
        verify(pill, "the sleep timer pill was not found")
        var popup = openSleepTimerPopup(host)
        var r = popupRectInWindow(host, popup)
        var p = pill.mapToItem(host.contentItem, 0, 0)
        var roomBelow = host.contentItem.height - (p.y + pill.height)
        verify(roomBelow < popup.height + 6,
               "960x600 was picked because the popup does NOT fit under the "
               + "pill there, but there are " + roomBelow.toFixed(1)
               + "px under it for a " + popup.height.toFixed(1) + "px popup, "
               + "so this case no longer measures the flip")
        verify(r.bottom <= p.y + 0.5,
               "there are only " + roomBelow.toFixed(1) + "px of window under "
               + "the pill and the popup is " + popup.height.toFixed(1)
               + "px tall, so it should open above the pill - but it ends at "
               + r.bottom.toFixed(1) + " and the pill starts at "
               + p.y.toFixed(1))
        fuzzyCompare(p.y - r.bottom, 6, 0.5,
                     "the popup opened above the pill but not 6px above it")
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
