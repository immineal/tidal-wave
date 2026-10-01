// The rebuilt sidebar: sections D and E of HANDOFF.md, S1-S10 and L2-L4 of
// docs/SPEC-0.4.0.md.
//
// The host below mirrors Main.qml exactly — a RowLayout holding the SideBar and
// the content pane — because half of what is tested here is how the two relate:
// the rail must *overlay* the page when it hover-expands rather than push it
// sideways, and only a host with a real content pane next to it can tell those
// two apart.
//
// `library` and `pins` are the stubs from tests/TestStubs.h. The ordering of
// `library.entries` (pinned, then recently played, then A-Z) is the data layer's
// contract and is covered by tst_library; what is asserted here is that the QML
// draws what it is handed, draws the block break between the pinned rows and the
// rest, and never duplicates a pinned row below.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "SideBar"
    when: windowShown

    // Prefs::railBreakpoint and Prefs::railWidth, repeated here so a silent
    // change to either is a test failure rather than a tautology.
    readonly property int railBreak: 820
    readonly property int railWidth: 68
    readonly property int minSidebar: 190
    readonly property int maxSidebar: 420
    readonly property int defaultSidebar: 220

    // ── fixtures ─────────────────────────────────────────────────────────

    // Two pinned rows first, then four unpinned ones, which is the shape the
    // data layer hands over: pinned, then recently played, then A-Z.
    function makeEntries() {
        return [
            { kind: "playlist", id: "p1",  title: "Pinned Mix Tape",  subtitle: "",             imageUrl: "cdn/p1.jpg", pinned: true,  trackCount: 12 },
            { kind: "album",    id: "a1",  title: "Pinned Album",     subtitle: "Pin Artist",   imageUrl: "cdn/a1.jpg", pinned: true,  trackCount: 9  },
            { kind: "album",    id: "a2",  title: "Aquarium",         subtitle: "Aqua Artist",  imageUrl: "cdn/a2.jpg", pinned: false, trackCount: 11 },
            { kind: "artist",   id: "ar1", title: "Boards of Canada", subtitle: "",             imageUrl: "cdn/ar1.jpg", pinned: false, trackCount: 0 },
            { kind: "mix",      id: "m1",  title: "Daily Discovery",  subtitle: "Your mix",     imageUrl: "cdn/m1.jpg", pinned: false, trackCount: 0 },
            { kind: "playlist", id: "p2",  title: "Evening Drive",    subtitle: "",             imageUrl: "cdn/p2.jpg", pinned: false, trackCount: 31 }
        ]
    }

    // Songs only live in the search index, never in the library list, so they
    // are handed to the stub separately.
    function makeTracks() {
        return [
            { kind: "track", id: "t1", title: "Everything In Its Right Place", subtitle: "Radiohead", imageUrl: "cdn/t1.jpg", pinned: false, albumId: 55 }
        ]
    }

    function makePins() {
        return [
            { kind: "playlist", id: "p1", title: "Pinned Mix Tape", subtitle: "", imageUrl: "cdn/p1.jpg" },
            { kind: "album",    id: "a1", title: "Pinned Album",    subtitle: "Pin Artist", imageUrl: "cdn/a1.jpg" }
        ]
    }

    function init() {
        prefs.setSidebarWidthForTest(defaultSidebar)
        app.setReducedMotionForTest(false)
        auth.setUsernameForTest("linus")
        library.setEntriesForTest(makeEntries())
        library.setTracksForTest(makeTracks())
        library.resetCallsForTest()
        pins.setItemsForTest(makePins())
        bridge.resetForTest()
    }

    // ── helpers ──────────────────────────────────────────────────────────

    // Layouts resize in the polish phase, so give the scene a frame plus one
    // turn of the event loop for the synchronous stub bindings.
    function settle(item) {
        wait(1)
        waitForRendering(item, 2000)
    }

    function showHost(w, h) {
        var host = createTemporaryObject(shellHost, testCase)
        verify(host, "host window was not created")
        host.width = w
        host.height = h
        host.visible = true
        waitForRendering(host.contentItem, 2000)
        // Park the pointer over the page. A freshly shown window inherits
        // whatever position the last synthesized event left behind, and under
        // the offscreen platform that is often inside the rail, which would
        // hover-expand the sidebar before the test had asked for anything.
        mouseMove(host.contentItem, w - 8, h - 8)
        wait(1)
        // The window is built at one width and resized to the test's, so the
        // panel is mid-slide at this point. Every test wants a settled sidebar
        // to start from.
        tryVerify(function () {
            return host.sidebar.panelWidth === host.sidebar.targetWidth
        }, 2000, "the sidebar never settled at " + w + "px")
        return host
    }

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

    // Only the ones actually on screen: a hidden subtree is not "shown".
    function collectVisibleByName(item, name, out) {
        if (item.visible === false) return out
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) collectVisibleByName(kids[i], name, out)
        return out
    }

    function chipFor(sidebar, kind) {
        var chips = collectByName(sidebar, "finderChip", [])
        for (var i = 0; i < chips.length; ++i)
            if (chips[i].kind === kind) return chips[i]
        return null
    }

    // The rows the list is actually showing, by id, in order.
    function rowIds(sidebar) {
        var out = []
        for (var i = 0; i < sidebar.rows.length; ++i) out.push(sidebar.rows[i].id)
        return out
    }

    Component {
        id: shellHost
        Window {
            id: win
            width: 960
            height: 700
            color: "black"

            property alias sidebar: sb
            property alias content: contentPane

            RowLayout {
                anchors.fill: parent
                spacing: 0

                SideBar {
                    id: sb
                    // Exactly the three lines Main.qml uses. z lifts the rail
                    // above the content so the overlay is on top of the page
                    // and not behind it.
                    z: 2
                    hostWidth: win.width
                    Layout.preferredWidth: sb.reservedWidth
                    Layout.fillHeight: true
                }

                Item {
                    id: contentPane
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
            }
        }
    }

    // ── L2: rail below 820, full sidebar above ───────────────────────────

    function test_rail_below_the_breakpoint_data() {
        return [
            { tag: "640",  w: 640,  rail: true  },
            { tag: "819",  w: 819,  rail: true  },
            { tag: "820",  w: 820,  rail: false },
            { tag: "960",  w: 960,  rail: false },
            { tag: "1280", w: 1280, rail: false }
        ]
    }

    function test_rail_below_the_breakpoint(row) {
        var host = showHost(row.w, 700)
        var sb = host.sidebar
        compare(sb.compact, row.rail, "rail state at a " + row.tag + "px window")
        compare(sb.reservedWidth, row.rail ? railWidth : defaultSidebar,
                "the width the layout reserves at " + row.tag)
        // The collapse is animated, so give the slide its 170ms.
        tryCompare(sb, "panelWidth", row.rail ? railWidth : defaultSidebar, 2000,
                   "the width the panel draws at " + row.tag)
        // The page gets everything the sidebar did not take.
        compare(host.content.width, row.w - sb.reservedWidth, "content pane width")
    }

    // S9: logo, nav icons, pinned covers, settings gear. Nothing else.
    function test_rail_shows_only_logo_nav_pins_and_gear() {
        var host = showHost(640, 700)
        var sb = host.sidebar
        verify(sb.compact, "a 640px window must give the rail")
        tryCompare(sb, "panelWidth", railWidth, 2000, "the rail never finished collapsing")

        verify(findByName(sb, "sidebarLogo").visible, "the logo is missing from the rail")
        verify(findByName(sb, "sidebarSettingsGear").visible, "the gear is missing from the rail")

        var navIcons = collectVisibleByName(sb, "navIcon", [])
        compare(navIcons.length, 3, "the rail shows Home, Search and Collection")
        compare(collectVisibleByName(sb, "navLabel", []).length, 0,
                "the rail must not show nav labels")

        var covers = collectVisibleByName(sb, "railPinCover", [])
        compare(covers.length, 6, "every library row wants a cover in the rail")

        verify(!findByName(sb, "sidebarFinder").visible, "the finder must hide in the rail")
        verify(!findByName(sb, "sidebarLibraryList").visible, "the library list must hide in the rail")
        // S10 again, from the other side: no user icon down there, and the
        // username has no room in a 68px rail either.
        verify(!findByName(sb, "sidebarAccountName").visible,
               "the rail footer carries the gear alone")
        compare(collectVisibleByName(sb, "sidebarAvatar", []).length, 0,
                "the avatar was dropped on purpose")
    }

    // ── L4: hover-expand overlays the page, it does not displace it ──────

    function test_hovering_the_rail_expands_it_over_the_page() {
        var host = showHost(640, 700)
        var sb = host.sidebar
        verify(sb.compact, "fixture should be in the rail")

        var contentX0 = host.content.x
        var contentW0 = host.content.width

        mouseMove(host.contentItem, railWidth / 2, 300)
        tryCompare(sb, "panelWidth", defaultSidebar, 2000,
                   "the rail did not expand to the full sidebar on hover")

        verify(sb.overlaying, "an expanded rail is an overlay")
        compare(sb.reservedWidth, railWidth,
                "the layout slot must stay at the rail width while overlaying")
        compare(host.content.x, contentX0, "the page moved sideways under the overlay")
        compare(host.content.width, contentW0, "the page was resized by the overlay")

        // It really is drawn on top of the page, not squeezed beside it.
        var panel = findByName(sb, "sidebarPanel")
        var panelRight = panel.mapToItem(host.contentItem, panel.width, 0).x
        verify(panelRight > host.content.x,
               "the expanded panel stops short of the page instead of covering it")

        // It is the ordinary sidebar, not a second design.
        verify(findByName(sb, "sidebarFinder").visible, "the overlay must show the finder")
        verify(findByName(sb, "sidebarLibraryList").visible, "the overlay must show the library")
        verify(findByName(sb, "sidebarAccountName").visible, "the overlay must show the account")
        compare(collectVisibleByName(sb, "navLabel", []).length, 3,
                "the overlay is the full sidebar, labels and all")

        mouseMove(host.contentItem, 600, 300)
    }

    function test_leaving_the_rail_collapses_it() {
        var host = showHost(640, 700)
        var sb = host.sidebar

        mouseMove(host.contentItem, railWidth / 2, 300)
        tryCompare(sb, "panelWidth", defaultSidebar, 2000, "the rail did not expand")

        mouseMove(host.contentItem, 600, 300)
        tryCompare(sb, "panelWidth", railWidth, 2000, "the rail did not slide back")
        verify(!sb.overlaying, "nothing should be overlaying once the pointer left")
        verify(!findByName(sb, "sidebarFinder").visible, "the finder stayed behind")
    }

    // Above the breakpoint there is nothing to hover-expand: the sidebar is
    // already the full sidebar and must never start overlaying the page.
    function test_a_wide_window_never_overlays() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        var contentW0 = host.content.width

        mouseMove(host.contentItem, 40, 300)
        wait(300)
        verify(!sb.overlaying, "a full sidebar must not turn into an overlay")
        compare(sb.panelWidth, defaultSidebar, "hovering must not resize the sidebar")
        compare(host.content.width, contentW0, "the page was disturbed by a hover")

        mouseMove(host.contentItem, 900, 300)
    }

    // ── L3: the border is a drag handle ──────────────────────────────────

    function test_drag_handle_resizes_and_clamps() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        var handle = findByName(sb, "sidebarDragHandle")
        verify(handle, "the sidebar border is not a drag handle")
        verify(handle.visible && handle.enabled, "the drag handle is not live")
        compare(handle.cursorShape, Qt.SplitHCursor, "the handle wants a resize cursor")

        // Driven through the host's content item so the coordinates stay put
        // while the handle itself travels with the panel's edge.
        mousePress(host.contentItem, defaultSidebar, 300)
        mouseMove(host.contentItem, defaultSidebar + 80, 300)
        tryCompare(sb, "expandedWidth", defaultSidebar + 80, 1000,
                   "dragging the border did not widen the sidebar")
        compare(sb.panelWidth, defaultSidebar + 80, "the panel did not follow the drag")

        // Past the far end it stops at Prefs::maxSidebarWidth, and the pointer
        // running on does not bank extra width it would give back later.
        mouseMove(host.contentItem, 1240, 300)
        tryCompare(sb, "expandedWidth", maxSidebar, 1000, "the sidebar blew past its maximum")

        mouseMove(host.contentItem, 4, 300)
        tryCompare(sb, "expandedWidth", minSidebar, 1000, "the sidebar shrank past its minimum")

        mouseRelease(host.contentItem, 4, 300)
        compare(sb.expandedWidth, minSidebar, "the clamp was undone on release")
        compare(prefs.sidebarWidth, minSidebar, "the dragged width was not written to prefs")
    }

    // L3: and it survives the app being torn down and built again.
    function test_dragged_width_persists() {
        var host = showHost(1280, 700)
        mousePress(host.contentItem, defaultSidebar, 300)
        mouseMove(host.contentItem, 300, 300)
        mouseRelease(host.contentItem, 300, 300)
        compare(prefs.sidebarWidth, 300, "the drag was not persisted")
        host.destroy()
        wait(1)

        var again = showHost(1280, 700)
        compare(again.sidebar.expandedWidth, 300, "the stored width was not picked up")
        compare(again.sidebar.reservedWidth, 300, "the layout did not honour the stored width")
    }

    // There is no manual toggle: compact mode is entered by window width alone
    // (L4), and the panel-left glyph was dropped on purpose.
    function test_no_manual_collapse_button() {
        var host = showHost(1280, 700)
        compare(collectByName(host.sidebar, "sidebarToggle", []).length, 0,
                "the sidebar grew a manual toggle button")
    }

    // ── S1/S2/S3: one flat library list ──────────────────────────────────

    function test_library_list_is_flat_and_typed() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        compare(rowIds(sb).join(","), "p1,a1,a2,ar1,m1,p2",
                "the list must show what the data layer ordered, untouched")

        var rows = collectByName(sb, "libraryRow", [])
        verify(rows.length >= 4, "the library list drew no rows")
        for (var i = 0; i < rows.length; ++i) {
            var icon = findByName(rows[i], "libraryRowIcon")
            verify(icon, "a library row has no type icon")
            compare(icon.name, rows[i].kind, "the row's type icon does not match its kind")
        }
    }

    // S3: the 30-item fetch is the reported "new playlists don't show up" bug.
    // The sidebar must now read library.entries and nothing else.
    function test_sidebar_never_fetches_playlists_itself() {
        var host = showHost(1280, 700)
        settle(host.contentItem)
        compare(bridge.userPlaylistFetchCountForTest(), 0,
                "SideBar.loadPlaylists is back, and with it the 30-item cap")
    }

    // S2/P5: the pinned rows come first, a block break separates them from the
    // rest, and a pinned item is never repeated below.
    function test_pinned_block_is_broken_out_and_never_duplicated() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        var rows = collectByName(sb, "libraryRow", [])
        var seen = ({})
        var firstUnpinned = -1
        for (var i = 0; i < rows.length; ++i) {
            verify(!seen[rows[i].kind + ":" + rows[i].itemId],
                   "\"" + rows[i].title + "\" appears twice in the sidebar")
            seen[rows[i].kind + ":" + rows[i].itemId] = true
            if (!rows[i].pinned && firstUnpinned < 0) firstUnpinned = i
            if (firstUnpinned >= 0) verify(!rows[i].pinned,
                   "a pinned row turned up below the block break")
        }
        compare(firstUnpinned, 2, "both fixture pins belong above the break")

        var breaks = collectVisibleByName(sb, "pinnedBlockBreak", [])
        compare(breaks.length, 1, "exactly one break between the pinned block and the list")
        compare(breaks[0].rowIndex, firstUnpinned, "the break sits at the wrong row")
    }

    // With nothing pinned there is no block, so there is nothing to break.
    function test_no_block_break_without_pins() {
        var entries = makeEntries()
        for (var i = 0; i < entries.length; ++i) entries[i].pinned = false
        library.setEntriesForTest(entries)
        pins.setItemsForTest([])

        var host = showHost(1280, 700)
        settle(host.contentItem)
        compare(collectVisibleByName(host.sidebar, "pinnedBlockBreak", []).length, 0,
                "a break was drawn with no pinned block above it")
    }

    // ── S5: the search field ─────────────────────────────────────────────

    function test_search_field_filters_the_list() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        var finder = findByName(sb, "sidebarFinder")
        verify(finder, "there is no search field above the library list")
        settle(host.contentItem)

        // It sits below the divider under Home/Search/Collection and above the
        // list, which is the whole of where S5 puts it.
        var divider = findByName(sb, "sidebarNavDivider")
        var list = findByName(sb, "sidebarLibraryList")
        verify(finder.mapToItem(sb, 0, 0).y > divider.mapToItem(sb, 0, 0).y,
               "the finder must sit below the nav divider")
        verify(finder.mapToItem(sb, 0, 0).y < list.mapToItem(sb, 0, 0).y,
               "the finder must sit above the library list")

        finder.query = "even"
        tryCompare(sb, "searching", true, 1000, "typing did not put the sidebar into search")
        tryVerify(function() { return rowIds(sb).join(",") === "p2" }, 2000,
                  "the search did not narrow the list to Evening Drive")
        compare(library.lastQueryForTest(), "even", "the query was not handed to library.search")

        finder.query = ""
        tryCompare(sb, "searching", false, 1000, "clearing the field did not restore the list")
        tryVerify(function() { return rowIds(sb).join(",") === "p1,a1,a2,ar1,m1,p2" }, 2000,
                  "the full library did not come back")
    }

    // S6: songs answer from the index too, and they are search-only — a song
    // never shows up in the plain library list.
    function test_search_reaches_songs() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)
        verify(rowIds(sb).indexOf("t1") === -1, "a song leaked into the library list")

        findByName(sb, "sidebarFinder").query = "right place"
        tryVerify(function() { return rowIds(sb).join(",") === "t1" }, 2000,
                  "the search did not reach the song index")
    }

    // ── S8: the type filter chips ────────────────────────────────────────

    function test_chips_are_icons_only_and_sit_with_the_field() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        var finder = findByName(sb, "sidebarFinder")
        settle(host.contentItem)

        var chips = collectByName(sb, "finderChip", [])
        compare(chips.length, 5, "songs / albums / artists / playlists / mixes")
        var kinds = []
        for (var i = 0; i < chips.length; ++i) {
            kinds.push(chips[i].kind)
            verify(findByName(chips[i], "finderChipIcon"), "a chip has no icon")
            compare(collectByName(chips[i], "finderChipLabel", []).length, 0,
                    "the chips are icons only, always; the labels go in tooltips")
            verify(chips[i].label.length > 0, "a chip has no name for its tooltip")
        }
        compare(kinds.join(","), "track,album,artist,playlist,mix", "chip order")

        // One unit with the field, not loose pills floating under it: the chips
        // live inside the field's own rounded container.
        var field = findByName(finder, "finderField")
        verify(field, "the finder has no input field")
        compare(finder.radius, Theme.radiusField, "the field wants the generous rounding")
        for (i = 0; i < chips.length; ++i) {
            var topLeft = chips[i].mapToItem(finder, 0, 0)
            verify(topLeft.x >= -0.5 && topLeft.x + chips[i].width <= finder.width + 0.5,
                   "a chip hangs out of the finder")
            verify(topLeft.y >= -0.5 && topLeft.y + chips[i].height <= finder.height + 0.5,
                   "a chip sits outside the finder instead of inside it")
        }
        // And they are narrow, which is the point of dropping the labels.
        verify(chips[0].width <= 40, "the chips are back to being too big: "
               + chips[0].width.toFixed(1) + "px")
    }

    function test_chips_filter_the_list() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        var artistChip = chipFor(sb, "artist")
        verify(artistChip, "there is no artists chip")
        mouseClick(artistChip, artistChip.width / 2, artistChip.height / 2)
        tryVerify(function() { return rowIds(sb).join(",") === "ar1" }, 2000,
                  "the artists chip did not filter the library list")
        verify(artistChip.selected, "a clicked chip should read as selected")

        // A second kind adds to the filter rather than replacing it.
        var mixChip = chipFor(sb, "mix")
        mouseClick(mixChip, mixChip.width / 2, mixChip.height / 2)
        tryVerify(function() { return rowIds(sb).join(",") === "ar1,m1" }, 2000,
                  "a second chip should widen the filter, not replace it")

        // Clicking it again takes it back out, and with nothing selected the
        // whole library is back.
        mouseClick(artistChip, artistChip.width / 2, artistChip.height / 2)
        mouseClick(mixChip, mixChip.width / 2, mixChip.height / 2)
        tryVerify(function() { return rowIds(sb).join(",") === "p1,a1,a2,ar1,m1,p2" }, 2000,
                  "deselecting every chip should show everything again")
    }

    // The chips narrow a search too, not just the idle list.
    function test_chips_narrow_a_search() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        var albumChip = chipFor(sb, "album")
        mouseClick(albumChip, albumChip.width / 2, albumChip.height / 2)
        findByName(sb, "sidebarFinder").query = "a"
        tryVerify(function() { return library.lastKindsForTest().join(",") === "album" }, 2000,
                  "the selected kinds were not passed to library.search")
        var ids = rowIds(sb)
        for (var i = 0; i < sb.rows.length; ++i)
            compare(sb.rows[i].kind, "album", "a non-album survived the albums chip")
    }

    // The chips are icons at every width, so all five have to stand side by
    // side however narrow the sidebar is dragged. The arithmetic, measured off
    // LibraryFinder: the finder is the panel less SideBar's 12px margin on
    // each side, and inside it the strip keeps a 4px inset left and right with
    // 2px between chips, so five full-size 30px chips want
    // 4 + 5*30 + 4*2 + 4 = 166px of finder, i.e. a 190px sidebar. Below that
    // something has to give, and the one thing that may never give is the
    // fifth chip sliding under the finder's clip.
    function test_chips_fit_at_every_sidebar_width_data() {
        return [
            { tag: "190", w: 190 },
            { tag: "200", w: 200 },
            { tag: "220", w: 220 },
            { tag: "268", w: 268 },
            { tag: "320", w: 320 },
            { tag: "420", w: 420 }
        ]
    }

    // The floor the chips may shrink to and still be worth aiming at. These
    // are below the 32px touch target on purpose: the chips are a dense
    // desktop control driven by a pointer, and they were already 30x24 before
    // anything shrank. 26 is where a 15px icon runs out of breathing room.
    readonly property int minChipWidth:  26
    readonly property int minChipHeight: 24

    function test_chips_fit_at_every_sidebar_width(row) {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        prefs.setSidebarWidthForTest(row.w)
        tryCompare(sb, "panelWidth", row.w, 2000,
                   "the sidebar never settled at " + row.tag + "px")
        settle(host.contentItem)

        var finder = findByName(sb, "sidebarFinder")
        verify(finder && finder.visible, "the finder is not showing at " + row.tag)
        var strip = findByName(finder, "finderChips")
        verify(strip, "the finder has no chip strip")

        var chips = collectVisibleByName(finder, "finderChip", [])
        compare(chips.length, 5, "all five chips must still be on screen at " + row.tag)

        var prevRight = -1
        for (var i = 0; i < chips.length; ++i) {
            var c = chips[i]
            var where = "the " + c.kind + " chip at a " + row.tag + "px sidebar"

            verify(c.width >= minChipWidth && c.height >= minChipHeight,
                   where + " shrank to " + c.width.toFixed(1) + "x"
                   + c.height.toFixed(1) + ", past the " + minChipWidth + "x"
                   + minChipHeight + " floor")

            // Inside the finder block, which is the item that clips: anything
            // past its right edge is the bug from the screenshot.
            var at = c.mapToItem(finder, 0, 0)
            verify(at.x >= -0.5,
                   where + " starts at " + at.x.toFixed(1) + ", left of the finder")
            verify(at.x + c.width <= finder.width + 0.5,
                   where + " spans " + at.x.toFixed(1) + ".."
                   + (at.x + c.width).toFixed(1) + " in a finder only "
                   + finder.width.toFixed(1) + " wide")

            // And inside the strip that holds it, so the row cannot overflow
            // its own block even if the block itself grew.
            var inStrip = c.mapToItem(strip, 0, 0)
            verify(inStrip.x >= -0.5 && inStrip.x + c.width <= strip.width + 0.5,
                   where + " hangs out of the chip strip")

            // In order and not stacked on top of one another.
            verify(at.x >= prevRight,
                   where + " overlaps the chip before it")
            prevRight = at.x + c.width
        }

        // The field above them survives the same squeeze: the placeholder may
        // elide, but neither the magnifier nor the clear button may be cut.
        finder.query = "a"
        settle(host.contentItem)
        var field = findByName(finder, "finderField")
        var marks = [findByName(finder, "finderSearchIcon"), findByName(finder, "finderClear")]
        for (i = 0; i < marks.length; ++i) {
            verify(marks[i] && marks[i].visible,
                   "the finder lost one of its field marks at " + row.tag)
            var m = marks[i].mapToItem(finder, 0, 0)
            verify(m.x >= -0.5 && m.x + marks[i].width <= finder.width + 0.5,
                   marks[i].objectName + " spans " + m.x.toFixed(1) + ".."
                   + (m.x + marks[i].width).toFixed(1) + " in a finder "
                   + finder.width.toFixed(1) + " wide at " + row.tag)
        }
        var input = findByName(field, "finderInput")
        verify(input && input.width > 0,
               "the search field was squeezed out of existence at " + row.tag)
        finder.query = ""
    }

    // ── S10: the footer ──────────────────────────────────────────────────

    function test_footer_shows_the_username_and_no_avatar() {
        auth.setUsernameForTest("linus")
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        var name = findByName(sb, "sidebarAccountName")
        verify(name && name.visible, "the footer has no account name")
        compare(name.text, "linus", "the footer must show the username, not the email")
        verify(name.text.indexOf("@") === -1, "that looks like an email address")
        compare(collectByName(sb, "sidebarAvatar", []).length, 0,
                "the avatar icon was dropped on purpose")
        verify(findByName(sb, "sidebarSettingsGear").visible, "the gear stays")
    }

    // I4: the Settings panel shows the real version, not v0.1-alpha.
    function test_settings_shows_the_real_version() {
        var host = showHost(1280, 700)
        host.sidebar.openSettings()
        wait(1)
        var line = findByName(host.sidebar.settingsPanel.contentItem, "settingsVersion")
        verify(line, "the Settings panel has no version line")
        verify(line.text.indexOf(prefs.appVersion()) !== -1,
               "the version line says \"" + line.text + "\"")
        verify(line.text.indexOf("0.1-alpha") === -1, "the hardcoded version is back")
        host.sidebar.settingsPanel.close()
    }

    // ── X6: reduced motion ───────────────────────────────────────────────

    function test_reduced_motion_skips_the_slide() {
        app.setReducedMotionForTest(true)
        var host = showHost(640, 700)
        var sb = host.sidebar
        verify(sb.reduceMotion, "the sidebar ignored the platform's reduced-motion setting")

        mouseMove(host.contentItem, railWidth / 2, 300)
        // No animation to wait out: the expansion is there on the next frame.
        wait(1)
        compare(sb.panelWidth, defaultSidebar, "the expansion should be instant, not animated")

        mouseMove(host.contentItem, 600, 300)
        wait(1)
        compare(sb.panelWidth, railWidth, "the collapse should be instant too")
    }

    // ── the sidebar holds at every width it has to ───────────────────────

    function test_nothing_overflows_data() {
        return [
            { tag: "640",  w: 640  },
            { tag: "820",  w: 820  },
            { tag: "960",  w: 960  },
            { tag: "1280", w: 1280 }
        ]
    }

    function test_nothing_overflows(row) {
        var host = showHost(row.w, 700)
        settle(host.contentItem)
        // Walked from the panel, not from the SideBar item: the panel is wider
        // than its slot on purpose while it overlays (L4), and that is the one
        // overflow in the app that is a feature.
        var faults = audit(findByName(host.sidebar, "sidebarPanel"), "SideBar@" + row.tag, [])
        verify(faults.length === 0, faults.join("\n  "))
    }

    // Hit targets and focus rings are drawn a few px outside their item on
    // purpose, so an overflow only counts past that.
    readonly property real overflowSlack: 8

    function audit(item, label, out) {
        // A scrolling view is meant to be taller than its viewport.
        if (item.contentWidth !== undefined && item.contentWidth > item.width + 1) return out
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number" || c.width <= 0) continue
            var here = label + " > " + (c.objectName.length > 0 ? c.objectName : ("" + c).split("(")[0])
            // Mapped rather than read off x and width: a Shape drawn at its
            // design size and scaled down by a transform, which is how both
            // VectorIcon and the app mark are built, is only as wide as the
            // transform leaves it while its own `width` still says 24 or 64.
            var l = c.mapToItem(item, 0, 0).x
            var r = c.mapToItem(item, c.width, 0).x
            if (r < l) { var swap = l; l = r; r = swap }
            if (l < -overflowSlack || r > item.width + overflowSlack)
                out.push(here + " spans " + l.toFixed(1) + ".." + r.toFixed(1)
                         + " in a parent " + item.width.toFixed(1) + " wide")
            if (c.truncated !== undefined && c.elide === Text.ElideNone
                    && ("" + c.text).length > 0 && c.truncated)
                out.push(here + ": \"" + c.text + "\" is clipped with no elide mode")
            audit(c, here, out)
        }
        return out
    }
}
