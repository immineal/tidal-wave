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
//
// The library list is *one* list in both shapes of the sidebar. It used to be
// two that swapped at a threshold, which is why expanding the rail made the
// covers blink out and the rows blink in. Several tests below exist only to
// pin that down: the cover is one size everywhere, it is the same object before
// and after an expansion, and it only ever moves.
//
// The last test here is not about the sidebar at all. The sidebar hands the
// page ~150px back when it collapses, so the content pane gets *wider* as the
// window gets narrower, and anything on a page that switches on the pane's
// width un-hides itself on the way down. That has to be swept a pixel at a
// time: the bug lives between the round numbers.

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
    // SideBar.coverSize, read off the sidebar rather than repeated: the
    // widths above are contract numbers that must not drift silently, but the
    // cover is a design decision that has already moved once (26 -> 36, so
    // the type badge in its corner is legible), and a copy of it here only
    // means this file has to be edited the next time it moves.
    function coverSizeOf(sb) { return sb.coverSize }

    // ── fixtures ─────────────────────────────────────────────────────────

    // Two pinned rows first, then four unpinned ones, which is the shape the
    // data layer hands over: pinned, then recently played, then A-Z.
    function makeEntries() {
        return [
            { kind: "playlist", id: "p1",  title: "Pinned Mix Tape",  subtitle: "",             imageUrl: "cdn/p1.jpg", pinned: true,  trackCount: 12 },
            { kind: "album",    id: "a1",  title: "Pinned Album",     subtitle: "Pin Artist",   imageUrl: "cdn/a1.jpg", pinned: true,  trackCount: 9  },
            { kind: "album",    id: "a2",  title: "Aquarium",         subtitle: "Aqua Artist",  imageUrl: "cdn/a2.jpg", pinned: false, trackCount: 11 },
            // No artwork on purpose: a bare row still has to say what it is.
            { kind: "artist",   id: "ar1", title: "Boards of Canada", subtitle: "",             imageUrl: "",           pinned: false, trackCount: 0 },
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

    // Whether the list is showing that kind and nothing else, which is what a
    // single chip means. Non-empty is part of it: an empty list trivially
    // contains no other kind.
    function onlyKind(sidebar, kind) {
        if (sidebar.rows.length === 0) return false
        for (var i = 0; i < sidebar.rows.length; ++i)
            if (sidebar.rows[i].kind !== kind) return false
        return true
    }

    function kindsShown(sidebar) {
        var seen = []
        for (var i = 0; i < sidebar.rows.length; ++i)
            if (seen.indexOf(sidebar.rows[i].kind) < 0) seen.push(sidebar.rows[i].kind)
        return seen.length === 0 ? "an empty list" : seen.join("+")
    }

    // The rows the list is actually showing, by id, in order.
    function rowIds(sidebar) {
        var out = []
        for (var i = 0; i < sidebar.rows.length; ++i) out.push(sidebar.rows[i].id)
        return out
    }

    // The ids makeEntries() hands over, in order. Looked up by id rather than
    // by position, because the identity tests have to be sure they are holding
    // the same row's cover before and after an expansion, and the order the
    // scene graph lists children in is not the model's.
    readonly property var fixtureIds: ["p1", "a1", "a2", "ar1", "m1", "p2"]

    function rowItemFor(sidebar, id) {
        var rows = collectByName(sidebar, "libraryRow", [])
        for (var i = 0; i < rows.length; ++i)
            if (rows[i].itemId === id) return rows[i]
        return null
    }

    // The cover tile of one library row. Still called railPinCover: it is the
    // name tests/qml/tst_pinning.qml reaches for, from when the rail had a
    // strip of covers of its own.
    function coverFor(sidebar, id) {
        var row = rowItemFor(sidebar, id)
        return row ? findByName(row, "railPinCover") : null
    }

    // The ring is a child of the cover rather than the cover's own `border`,
    // because a Rectangle paints its border under its own children and the
    // artwork fills the whole box: as the cover's border it was painted and
    // then covered over on every row that had a cover at all.
    function ringFor(sidebar, id) {
        var cover = coverFor(sidebar, id)
        return cover ? findByName(cover, "libraryRowRing") : null
    }

    // Whether the ring is painted after the artwork. Qt draws siblings in
    // child order, so this is the whole of what made the old ring invisible,
    // and a width assertion alone would not have caught it.
    function ringIsOverTheArt(sidebar, id) {
        var cover = coverFor(sidebar, id)
        if (!cover) return false
        var art = -1, ring = -1
        for (var i = 0; i < cover.children.length; i++) {
            var n = cover.children[i].objectName
            if (n === "libraryRowArt")      art  = i
            if (n === "libraryRowRing")     ring = i
        }
        return art >= 0 && ring > art
    }

    // Every cover, keyed by row id, so two snapshots can be compared object
    // by object.
    function coverMap(sidebar) {
        var out = ({})
        for (var i = 0; i < fixtureIds.length; ++i)
            out[fixtureIds[i]] = coverFor(sidebar, fixtureIds[i])
        return out
    }

    function expandTheRail(host) {
        mouseMove(host.contentItem, railWidth / 2, 300)
        tryCompare(host.sidebar, "panelWidth", defaultSidebar, 2000,
                   "the rail did not expand on hover")
        settle(host.contentItem)
    }

    function collapseTheRail(host) {
        mouseMove(host.contentItem, host.width - 8, host.height - 8)
        tryCompare(host.sidebar, "panelWidth", railWidth, 2000,
                   "the rail did not slide back")
        settle(host.contentItem)
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
            property alias page: pageLoader

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
                    // Empty unless a test puts a page in it. The hero sweep
                    // needs a real page in a real pane beside a real sidebar:
                    // the whole bug is in how the two share the window.
                    Loader { id: pageLoader; anchors.fill: parent }
                }
            }
        }
    }

    Component { id: albumC;    AlbumPage    { anchors.fill: parent } }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }
    Component { id: mixC;      MixPage      { anchors.fill: parent } }
    Component { id: artistC;   ArtistPage   { anchors.fill: parent } }

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

    // S9: logo, nav icons, covers, settings gear. Nothing else. The library
    // list itself stays - it is the same list the open sidebar shows, with its
    // labels faded out - but nothing textual in it may be on screen.
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
        verify(findByName(sb, "sidebarLibraryList").visible,
               "the rail's covers are the library list, so it may not be hidden")
        compare(collectVisibleByName(sb, "libraryRowTitle", []).length, 0,
                "the rail must not show row titles")
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
            compare(icon.name, sb.glyphFor(rows[i].kind),
                    "the row's type icon does not match its kind")
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

    // ── S9 amended: one set of covers that moves ─────────────────────────

    // The user's complaint in one assertion: the cover is the same size in the
    // rail as it is beside a title, so nothing has to resize when the panel
    // slides. The rail used to draw them at 40, which is far too big to sit
    // next to a label.
    function test_the_covers_are_one_size_in_both_shapes() {
        var host = showHost(640, 700)
        var sb = host.sidebar
        var panel = findByName(sb, "sidebarPanel")
        settle(host.contentItem)

        var railX = Math.round((railWidth - coverSizeOf(sb)) / 2)
        for (var i = 0; i < fixtureIds.length; ++i) {
            var c = coverFor(sb, fixtureIds[i])
            verify(c, "the rail has no cover for " + fixtureIds[i])
            compare(c.width, coverSizeOf(sb), "the rail cover of " + fixtureIds[i])
            compare(c.height, coverSizeOf(sb), "the rail cover of " + fixtureIds[i])
            compare(Math.round(c.mapToItem(panel, 0, 0).x), railX,
                    "the rail cover of " + fixtureIds[i] + " is not centred in the rail")
        }

        expandTheRail(host)
        for (i = 0; i < fixtureIds.length; ++i) {
            c = coverFor(sb, fixtureIds[i])
            verify(c, "the open sidebar lost the cover for " + fixtureIds[i])
            compare(c.width, coverSizeOf(sb),
                    "the cover of " + fixtureIds[i] + " resized when the sidebar opened")
            compare(c.height, coverSizeOf(sb),
                    "the cover of " + fixtureIds[i] + " resized when the sidebar opened")
            // It does not slide any more, and that is the point. A 36px
            // cover centred in the 68px rail has its left edge on 16, which
            // is the sidebar's content inset -- the same place the open list
            // puts it. So the artwork holds still and the labels arrive
            // beside it, instead of every cover in the list drifting
            // sideways every time the rail opens.
            compare(Math.round(c.mapToItem(panel, 0, 0).x), sb.coverLeft,
                    "the cover of " + fixtureIds[i]
                    + " is not on the sidebar's content inset once open")
        }
        collapseTheRail(host)

        // And the same size again on a window that was never in the rail at
        // all, so the number is one number and not two that happen to agree.
        var wide = showHost(1280, 700)
        settle(wide.contentItem)
        compare(coverFor(wide.sidebar, "p1").width, coverSizeOf(wide.sidebar),
                "a sidebar that never saw the rail draws a different cover")
    }

    // The point of merging the two lists. Expanding must *move* the covers,
    // not throw one set away and build another, so the same QML object has to
    // come back out of the tree afterwards - including while the slide is
    // still running, which is the frame the old build drew empty.
    function test_expanding_moves_the_covers_rather_than_rebuilding_them() {
        var host = showHost(640, 700)
        var sb = host.sidebar
        var panel = findByName(sb, "sidebarPanel")
        settle(host.contentItem)

        var before = coverMap(sb)
        var beforeX = ({})
        for (var i = 0; i < fixtureIds.length; ++i) {
            verify(before[fixtureIds[i]], "no cover for " + fixtureIds[i] + " to start from")
            beforeX[fixtureIds[i]] = before[fixtureIds[i]].mapToItem(panel, 0, 0).x
        }

        // Mid-slide. The panel is between the two widths here, which is where
        // the swap used to happen.
        mouseMove(host.contentItem, railWidth / 2, 300)
        tryVerify(function () {
            return sb.panelWidth > railWidth && sb.panelWidth < defaultSidebar
        }, 2000, "the slide was never caught in flight")
        var midWidth = sb.panelWidth
        for (i = 0; i < fixtureIds.length; ++i) {
            var mid = coverFor(sb, fixtureIds[i])
            verify(mid === before[fixtureIds[i]],
                   "the cover of " + fixtureIds[i] + " was rebuilt at " + midWidth + "px")
            compare(mid.width, coverSizeOf(sb),
                    "the cover of " + fixtureIds[i] + " resized mid-slide")
            verify(mid.visible, "the cover of " + fixtureIds[i] + " blinked out mid-slide")
        }

        tryCompare(sb, "panelWidth", defaultSidebar, 2000, "the rail did not finish expanding")
        settle(host.contentItem)

        var after = coverMap(sb)
        for (i = 0; i < fixtureIds.length; ++i) {
            var id = fixtureIds[i]
            verify(after[id] === before[id],
                   "the cover of " + id + " is a different object once the sidebar is open")
            // No travel assertion: at the current cover size the rail centre
            // and the open list's inset are the same x, so the cover holds
            // still through the slide. Identity is what this test is for --
            // one item in both shapes, never two sets swapping -- and that
            // is what the line above checks at every step of the way.
            verify(after[id].visible, "the cover of " + id + " did not survive the slide")
        }

        // And back: closing it is the same journey in reverse, not a second
        // teardown.
        collapseTheRail(host)
        var home = coverMap(sb)
        for (i = 0; i < fixtureIds.length; ++i) {
            id = fixtureIds[i]
            verify(home[id] === before[id],
                   "the cover of " + id + " was rebuilt on the way back to the rail")
            compare(Math.round(home[id].mapToItem(panel, 0, 0).x), Math.round(beforeX[id]),
                    "the cover of " + id + " did not come home")
        }
    }

    // The corner badge has to sit *inside* the cover's rounded corner, not
    // flush with the box the corner is drawn in.
    //
    // Flush, a crescent of cover showed past the badge wherever the two radii
    // disagreed, and it read as a stray speck rather than as an edge. It is
    // worse with artwork, because an Image is clipped to its parent's
    // bounding box and never to its rounded outline, so the art reaches the
    // square corner the badge's own arc has curved away from.
    //
    // Asserted as geometry rather than as a number of pixels, so it holds at
    // whatever size the cover is next drawn at: the badge's furthest point,
    // which is its outer corner pushed back along the diagonal by its own
    // radius, has to fall inside the cover's rounded outline, which is its
    // corner pushed back the same way by the cover's radius. That inequality
    // is what "no sliver at any size" means.
    function roundedInset(radius) { return radius * (1 - Math.SQRT1_2) }

    function checkBadgeClearsTheCorner(badge, glyph, cover, where) {
        var at = badge.mapToItem(cover, 0, 0)
        // The badge is in the bottom right, so those are the two edges that
        // can show a sliver.
        var badgeRight  = at.x + badge.width
        var badgeBottom = at.y + badge.height
        verify(badgeRight <= cover.width - 0.5 && badgeBottom <= cover.height - 0.5,
               where + ": the badge is flush with the cover's edge at "
               + badgeRight.toFixed(1) + "," + badgeBottom.toFixed(1)
               + " in a " + cover.width + "px cover")

        // Measured from the cover's corner, along the diagonal.
        var badgeOut = Math.min(cover.width - badgeRight, cover.height - badgeBottom)
                       + roundedInset(badge.radius)
        var coverOut = roundedInset(cover.radius)
        verify(badgeOut >= coverOut - 0.01,
               where + ": the badge reaches " + badgeOut.toFixed(2)
               + " of the corner, inside the cover's own " + coverOut.toFixed(2)
               + ", so a sliver of cover shows past it")

        // And the glyph went with it, rather than being left behind in the
        // corner the badge has moved out of.
        var g = glyph.mapToItem(cover, 0, 0)
        verify(g.x >= at.x - 0.5 && g.y >= at.y - 0.5
                   && g.x + glyph.width  <= at.x + badge.width  + 0.5
                   && g.y + glyph.height <= at.y + badge.height + 0.5,
               where + ": the type glyph is not inside its badge")
    }

    // Covers, not type glyphs, in the open sidebar too - which is the decision
    // this reverses. The type stays readable: artwork carries a corner mark,
    // and a row with no artwork is the glyph at full size.
    function test_every_row_shows_artwork_and_still_says_what_it_is_data() {
        return [
            { tag: "rail", w: 640,  wide: false },
            { tag: "open", w: 1280, wide: true  }
        ]
    }

    function test_every_row_shows_artwork_and_still_says_what_it_is(data) {
        var host = showHost(data.w, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        var rows = collectByName(sb, "libraryRow", [])
        compare(rows.length, 6, "every fixture row wants a row item at " + data.tag)

        for (var i = 0; i < rows.length; ++i) {
            var r     = rows[i]
            var where = "\"" + r.title + "\" at " + data.tag

            var cover = findByName(r, "railPinCover")
            verify(cover && cover.visible, where + " has no cover")
            compare(cover.width, coverSizeOf(sb), where + " has the wrong cover size")

            var art   = findByName(r, "libraryRowArt")
            var glyph = findByName(r, "libraryRowIcon")
            var badge = findByName(r, "libraryRowTypeBadge")
            verify(art,   where + " has no artwork item")
            verify(glyph, where + " has no type glyph")
            verify(badge, where + " has no type badge")

            var hasArt = (r.modelData.imageUrl || "").length > 0
            compare(art.visible, hasArt, where + ": the artwork does not match the row")
            compare(badge.visible, hasArt,
                    where + ": the corner mark belongs on artwork and nowhere else")
            // Either way the type is on screen, which is the whole point of
            // keeping it after the glyph stopped being the row's leading item.
            verify(glyph.visible, where + ": the type is not discoverable")
            compare(glyph.name, sb.glyphFor(r.kind), where + ": the wrong type glyph")
            // Inside the cover, in both arrangements.
            var at = glyph.mapToItem(cover, 0, 0)
            verify(at.x >= -0.5 && at.x + glyph.width <= cover.width + 0.5
                   && at.y >= -0.5 && at.y + glyph.height <= cover.height + 0.5,
                   where + ": the type glyph hangs off the cover")

            if (hasArt) checkBadgeClearsTheCorner(badge, glyph, cover, where)
        }

        // The title is the other half of the row, and only when there is room
        // for it.
        compare(collectVisibleByName(sb, "libraryRowTitle", []).length,
                data.wide ? 6 : 0, "row titles at " + data.tag)
    }

    // QA: "if I click any of the filter pills in the find in library search, it
    // shows up stuff, but if I press the songs, it just says nothing saved yet."
    //
    // The library's `entries` property holds the four browsable kinds and leaves
    // songs out on purpose - a library has thousands of them and they would bury
    // everything else - so the no-query path, which used to filter `entries` in
    // QML, could never answer the Tracks chip. The same chip worked the moment
    // anything was typed, because search() visits the track entries too, which
    // is why this looked like a filter bug rather than a missing list.
    function test_the_tracks_chip_shows_songs_with_nothing_typed() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        // Every other chip first, so a failure here is about songs rather than
        // about chips in general - those four were never broken.
        var kinds = ["album", "artist", "playlist", "mix"]
        for (var k = 0; k < kinds.length; ++k) {
            var chip = chipFor(sb, kinds[k])
            verify(chip, "there is no " + kinds[k] + " chip")
            mouseClick(chip, chip.width / 2, chip.height / 2)
            // Waiting on "the list is non-empty" would wait for nothing: the
            // unfiltered list is already non-empty, so the condition is true
            // before the chip has had any effect. The condition has to be the
            // filtered shape itself.
            tryVerify(function () { return onlyKind(sb, kinds[k]) }, 2000,
                      "the " + kinds[k] + " chip did not filter the list down to "
                      + kinds[k] + "; got " + kindsShown(sb))
            mouseClick(chip, chip.width / 2, chip.height / 2)   // off again
            settle(host.contentItem)
        }

        var tracks = chipFor(sb, "track")
        verify(tracks, "there is no tracks chip")
        mouseClick(tracks, tracks.width / 2, tracks.height / 2)
        tryVerify(function () { return onlyKind(sb, "track") }, 2000,
                  "the Tracks chip found no songs with no query typed; got "
                  + kindsShown(sb))
        compare(rowIds(sb).join(","), "t1",
                "the Tracks chip showed something other than the fixture's song")
        mouseClick(tracks, tracks.width / 2, tracks.height / 2)

        // And no chip at all is still the whole browsable library, which must
        // not have grown songs: keeping them out of it is the reason this needed
        // a separate call in the first place. Waited for rather than asserted,
        // because the chip going off is a click to be processed - asserting
        // straight after the click tests whether the click has landed yet, which
        // is not the question.
        tryVerify(function () { return sb.rows.length === makeEntries().length },
                  2000, "clearing the chips did not restore the whole library; got "
                  + kindsShown(sb))
        for (var m = 0; m < sb.rows.length; ++m)
            verify(sb.rows[m].kind !== "track",
                   "songs leaked into the unfiltered library list")
    }

    // QA: crossing the breakpoint outwards left "a black bar where it will
    // expand to". The slot the layout reserves used to jump to the full width
    // the instant `compact` flipped, while the panel animated into it over
    // 170ms, and for those frames the difference painted the page. The
    // invariant that fixes it is that the slot never runs ahead of the panel,
    // so this samples the whole slide rather than one frame of it.
    function test_the_slot_never_runs_ahead_of_the_panel() {
        var host = showHost(railBreak - 60, 700)
        var sb = host.sidebar
        settle(host.contentItem)
        compare(sb.panelWidth, railWidth, "the sidebar did not start as a rail")

        // The window's new width reaches the sidebar through Window.width, which
        // the platform delivers on its own schedule, so `compact` is not false
        // on the line after the assignment. The invariant below holds either
        // way, and compact is asserted once the slide has finished.
        host.width = railBreak + 60

        // Every frame from the resize until the panel has arrived. A gap of one
        // pixel is a gap: this is the bug, not a tolerance.
        var sawSlide = false
        for (var i = 0; i < 200; i++) {
            verify(sb.reservedWidth <= sb.panelWidth,
                   "the layout reserved " + sb.reservedWidth
                   + " while the panel was only " + sb.panelWidth + " wide")
            if (sb.panelWidth > railWidth && sb.panelWidth < defaultSidebar)
                sawSlide = true
            if (sb.panelWidth === defaultSidebar && i > 4) break
            wait(4)
        }
        compare(sb.compact, false, "the sidebar stayed compact past the breakpoint")
        compare(sb.panelWidth, defaultSidebar, "the panel never reached full width")
        compare(sb.reservedWidth, defaultSidebar, "the slot did not end up the panel's width")

        // And the same going back in, where the panel is the one that has to
        // not run ahead: the page must not be uncovered before the panel has
        // left it.
        host.width = railBreak - 60
        for (var j = 0; j < 200; j++) {
            verify(sb.reservedWidth <= sb.panelWidth,
                   "going narrow, the slot was " + sb.reservedWidth
                   + " against a panel of " + sb.panelWidth)
            if (sb.panelWidth === railWidth && j > 4) break
            wait(4)
        }
        compare(sb.panelWidth, railWidth, "the panel did not return to the rail")
        verify(sawSlide, "the panel snapped instead of sliding")
    }

    // The slide itself still has to exist: it is the hover overlay, where the
    // panel is wider than its slot and so has nothing to leave a hole in.
    function test_the_hover_overlay_still_slides() {
        var host = showHost(railBreak - 60, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        mouseMove(host.contentItem, railWidth / 2, 300)
        // Caught mid-slide: strictly between the two widths, which is only
        // possible if the Behavior ran.
        var sawMidSlide = false
        for (var i = 0; i < 40 && !sawMidSlide; i++) {
            if (sb.panelWidth > railWidth && sb.panelWidth < defaultSidebar)
                sawMidSlide = true
            wait(4)
        }
        verify(sawMidSlide, "the hover overlay snapped open instead of sliding")
        tryCompare(sb, "panelWidth", defaultSidebar, 2000,
                   "the overlay did not finish opening")
        collapseTheRail(host)
    }

    // P3/P4 through the merge: the pinned ring survives in both shapes, and
    // the grip still reorders the block.
    function test_the_pinned_block_survives_the_merged_list() {
        var host = showHost(640, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        // A pinned cover is ringed in the rail, which is the only thing left
        // telling it apart in a strip of bare artwork.
        verify(ringFor(sb, "p1").visible, "a pinned rail cover lost its ring")
        verify(ringFor(sb, "a1").visible, "a pinned rail cover lost its ring")
        verify(!ringFor(sb, "a2").visible, "an unpinned rail cover grew a ring")
        // And it is painted over the artwork, not under it.
        verify(ringIsOverTheArt(sb, "p1"), "the ring went back under the cover art")
        compare(collectVisibleByName(sb, "pinnedBlockBreak", []).length, 1,
                "the rail wants the same one break the open sidebar draws")
        // Nothing is draggable in a 68px strip: there is no grip to aim at.
        compare(collectVisibleByName(sb, "pinDragGrip", []).length, 0,
                "the rail offered a drag grip")

        expandTheRail(host)
        verify(ringFor(sb, "p1").visible, "the ring was lost on the way out")
        compare(collectVisibleByName(sb, "pinDragGrip", []).length, 2,
                "both pinned rows want a grip once the sidebar is open")
        collapseTheRail(host)

        // And the drag itself, on a window wide enough to have no rail at all.
        var wide = showHost(1280, 700)
        var wsb  = wide.sidebar
        settle(wide.contentItem)
        compare(wsb.pinnedCount, 2, "both fixture pins belong above the break")

        var grip = findByName(rowItemFor(wsb, "p1"), "pinDragArea")
        verify(grip && grip.enabled, "the pinned row lost its drag handle")
        var from = grip.mapToItem(wide.contentItem, grip.width / 2, grip.height / 2)
        mousePress(wide.contentItem, from.x, from.y)
        mouseMove(wide.contentItem, from.x, from.y + wsb.libRowHeight)
        wait(1)
        compare(wsb.pinDragTo, 1, "one row of travel is one slot")
        verify(findByName(wsb, "pinDropIndicator").visible, "the drop indicator never showed")
        mouseRelease(wide.contentItem, from.x, from.y + wsb.libRowHeight)
        settle(wide.contentItem)
        compare(pins.items[0].id, "a1", "the drop did not reorder PinStore")
        compare(pins.items[1].id, "p1", "the drop did not reorder PinStore")
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

        // The row says what it is instead of leaving a gear to imply it, and
        // the name is the second line rather than the subject of the row.
        var label = findByName(sb, "sidebarSettingsLabel")
        verify(label && label.visible, "the footer row has no Settings label")
        compare(label.text, qsTranslate("SettingsPanel", "Settings"),
                "the footer should reuse the panel's own word")
        verify(label.mapToItem(sb, 0, 0).y < name.mapToItem(sb, 0, 0).y,
               "the account name should sit under the Settings label")
    }

    // The whole row is the target now, not a 28px gear at the end of it.
    function test_the_footer_row_opens_settings() {
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)
        verify(!sb.settingsPanel.visible, "the panel was already open")

        var row = findByName(sb, "sidebarSettingsRow")
        verify(row && row.visible, "the footer has no row")
        verify(row.width > 150, "the footer row is " + row.width.toFixed(0)
               + " wide, so it is still a button and not a row")

        // Well away from the gear, where the old layout had inert text.
        var p = row.mapToItem(host.contentItem, row.width - 24, row.height / 2)
        mouseClick(host.contentItem, p.x, p.y)
        tryVerify(function () { return sb.settingsPanel.visible }, 2000,
                  "clicking the row did not open Settings")
        sb.settingsPanel.close()
    }

    // The sidebar can be dragged down to 190, and a long display name has to
    // give way there rather than pushing the row wider or wrapping onto a
    // third line.
    function test_a_long_account_name_elides_at_the_narrowest_sidebar() {
        auth.setUsernameForTest("Ein ziemlich langer Anzeigename fuer das Konto")
        prefs.setSidebarWidthForTest(minSidebar)
        var host = showHost(1280, 700)
        var sb = host.sidebar
        settle(host.contentItem)

        var name = findByName(sb, "sidebarAccountName")
        verify(name && name.visible, "the footer has no account name")
        compare(name.elide, Text.ElideRight, "the account name does not elide")
        compare(name.wrapMode, Text.NoWrap, "the account name wraps")
        verify(name.mapToItem(sb, 0, 0).x + name.width <= sb.panelWidth + 0.5,
               "the account name runs past the sidebar at " + minSidebar + "px")
        prefs.setSidebarWidthForTest(defaultSidebar)
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

    // ── the sidebar's collapse must not make the page flicker ────────────
    //
    // The pane's width is *not* a rising function of the window's. Above
    // Prefs::railBreakpoint the pane is the window less the full sidebar;
    // below it the sidebar collapses and hands ~150px back, so a 819px window
    // gives the page a wider pane than an 821px one does. Anything on a page
    // that switches on the pane's width therefore un-hides itself while the
    // window is being dragged *narrower*, which is what the user saw: the
    // track rows' album column dropped out, and then came back a moment later
    // when the sidebar went away.
    //
    // Swept a pixel at a time, because every threshold involved is an odd
    // number that no round-number sweep lands on.

    readonly property int sweepFrom: 960
    readonly property int sweepTo:   700

    // Is anything of this kind on screen? Keyed by a path of names with no
    // indices, and OR-ed across every item that shares a path, because a list
    // shuffles its delegates around under a resize and keying on a delegate's
    // position would read that shuffle as things appearing and disappearing.
    // What is being asked is "does the page still show its album column", not
    // "does row four still show it".
    function visSnapshot(item, path, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c  = kids[i]
            var nm = (c.objectName && c.objectName.length > 0)
                     ? c.objectName : ("" + c).split("(")[0].split("_QML")[0]
            var here = path + "/" + nm
            var vis  = (c.visible !== false) && c.width > 0.5 && c.height > 0.5
            out[here] = (out[here] === true) || vis
            if (c.visible !== false) visSnapshot(c, here, out)
        }
        return out
    }

    // Drags the window from `from` to `to` a pixel at a time and reports every
    // element that changed visibility more than once on the way.
    function sweepFaults(host, page, from, to) {
        var step = from < to ? 1 : -1
        var seen = ({})
        var flips = ({})
        var marks = ({})
        for (var w = from; ; w += step) {
            host.width = w
            wait(1)
            var now = visSnapshot(page, "", ({}))
            for (var k in seen) if (!(k in now)) now[k] = false
            for (var k2 in now) {
                if (!(k2 in seen)) { seen[k2] = now[k2]; flips[k2] = 0; marks[k2] = []; continue }
                if (seen[k2] !== now[k2]) {
                    flips[k2] += 1
                    marks[k2].push(w + (now[k2] ? " on" : " off"))
                    seen[k2] = now[k2]
                }
            }
            if (w === to) break
        }
        var faults = []
        for (var key in flips)
            if (flips[key] > 1)
                faults.push(key + " flipped " + flips[key] + " times ("
                            + marks[key].join(", ") + ")")
        return faults
    }

    function makeSweepTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 900 + i, title: "Ein Tracktitel Nummer " + (i + 1),
                       artists: "Die Band", albumTitle: "Ein Albumtitel",
                       durationStr: "3:20", duration: 200,
                       coverUrl: "", coverUrl80: "", albumId: 42 })
        return out
    }

    function loadSweepPage(host, which) {
        var page
        if (which === "album") {
            host.page.sourceComponent = albumC
            page = host.page.item
            page.albumId   = 42
            page.albumData = { title: "Fever Dream", artists: "Die Band",
                               releaseDate: "2021-01-01", numTracks: 10, duration: 2400,
                               quality: "HI_RES_LOSSLESS", artistId: 7,
                               coverUrl: "", coverUrl640: "" }
            page.tracks = makeSweepTracks(10)
        } else if (which === "playlist") {
            host.page.sourceComponent = playlistC
            page = host.page.item
            page.playlistUuid  = "uuid-1"
            page.playlistTitle = "Eine Playlist"
            page.coverUrl      = ""
            page.tracks        = makeSweepTracks(10)
        } else if (which === "mix") {
            host.page.sourceComponent = mixC
            page = host.page.item
            page.mixId    = "m1"
            page.title    = "Daily Discovery"
            page.subtitle = "Mit vielen verschiedenen Interpreten"
            page.coverUrl = ""
            page.tracks   = makeSweepTracks(10)
        } else {
            host.page.sourceComponent = artistC
            page = host.page.item
            page.artistId   = 7
            page.artistData = { name: "Ein Interpret", bio: "", coverUrl750: "",
                                similarArtists: [] }
            page.topTracks  = makeSweepTracks(10)
        }
        return page
    }

    function test_the_hero_pages_do_not_flicker_as_the_sidebar_collapses_data() {
        return [
            { tag: "album",    which: "album"    },
            { tag: "playlist", which: "playlist" },
            { tag: "mix",      which: "mix"      },
            { tag: "artist",   which: "artist"   }
        ]
    }

    function test_the_hero_pages_do_not_flicker_as_the_sidebar_collapses(data) {
        // The slide would otherwise trail the window by up to its 170ms and
        // every reading would be of a pane that had not caught up yet.
        app.setReducedMotionForTest(true)

        var host = showHost(sweepFrom, 760)
        var page = loadSweepPage(host, data.which)
        verify(page, "the " + data.tag + " page was never built")
        waitForRendering(host.contentItem, 2000)
        settle(host.contentItem)

        // The hero artwork was where this was first reported ("it doesn't
        // show the album"), so it is worth recording that it is not the thing
        // that moves: the square cover is a fixed size in a RowLayout that
        // never squeezes it, and it is the album column of the track rows
        // below that comes and goes. ArtistPage has no square cover at all -
        // its hero art is the full-bleed backdrop.
        var art = findByName(page, "heroArt")
        var artWidth = art ? art.width : 0
        if (art) verify(art.visible, "the " + data.tag + " hero art started out hidden")

        var down = sweepFaults(host, page, sweepFrom, sweepTo)
        verify(down.length === 0,
               "dragging the " + data.tag + " page from " + sweepFrom + " to " + sweepTo
               + "px:\n  " + down.join("\n  "))

        if (art) {
            verify(art.visible, "the " + data.tag + " hero art was dropped on the way down")
            compare(art.width, artWidth, "the " + data.tag + " hero art resized on the way down")
        }

        var up = sweepFaults(host, page, sweepTo, sweepFrom)
        verify(up.length === 0,
               "dragging the " + data.tag + " page from " + sweepTo + " to " + sweepFrom
               + "px:\n  " + up.join("\n  "))
    }

    // The same audit, run on the frames *between* the two widths. Nothing may
    // rely on the panel clipping it there: a Shape ignores an ancestor's clip,
    // and the sidebar is full of them (every VectorIcon is one), so anything
    // that overflows mid-slide really is drawn over the page.
    function test_nothing_overflows_mid_slide_data() {
        return [
            { tag: "88",  w: 88  },
            { tag: "106", w: 106 },
            { tag: "144", w: 144 },
            { tag: "182", w: 182 },
            { tag: "210", w: 210 }
        ]
    }

    function test_nothing_overflows_mid_slide(row) {
        var host = showHost(640, 700)
        var sb = host.sidebar
        // Pinned straight to one frame of the slide. This drops the binding to
        // targetWidth, which is the point: the panel holds still at a width it
        // would otherwise only pass through.
        sb.panelWidth = row.w
        tryCompare(sb, "panelWidth", row.w, 2000,
                   "the panel never settled at " + row.tag + "px")
        settle(host.contentItem)

        var faults = audit(findByName(sb, "sidebarPanel"), "SideBar mid-slide@" + row.tag, [])
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
