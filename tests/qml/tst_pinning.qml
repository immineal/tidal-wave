// The pinning interface: section F of HANDOFF.md, P1-P6 of docs/SPEC-0.4.0.md.
//
// `pins` and `library` are the stubs from tests/TestStubs.h. The one thing the
// stubs do not do is wire the two together: the real LibraryIndex connects to
// PinStore::changed and rebuilds its rows from it (pinned first, in pin order,
// every row flagged `pinned`, and no row listed twice). applyPins() below
// mirrors that contract and nothing else, so a pin made on a page header
// travels into the sidebar here the way it does in the app, and P5 is asserted
// against the same rule tst_library pins down on the C++ side.
//
// The host mirrors Main.qml — a RowLayout of the SideBar and a content pane —
// because half of these tests pin something on a page and then look for it in
// the sidebar, which needs both on screen at once.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Pinning"
    when: windowShown

    readonly property int railWidth: 68
    // SideBar.libRowHeight, read off the sidebar rather than written down.
    // The drag arithmetic below is in whole rows, and the row has already
    // changed height once (34 -> 44, for a bigger cover): a copy of the
    // number here makes every such change a failure in this file instead of
    // a test of the thing it is actually about.
    function rowHeightOf(sb) { return sb.libRowHeight }

    // ── fixtures ─────────────────────────────────────────────────────────

    // The library with nothing pinned: six rows, A-Z, which is what the data
    // layer hands over when no pin and no play has happened yet. Album and
    // artist ids are numeric strings because that is what the pages build
    // their pin id from.
    function baseEntries() {
        return [
            { kind: "album",    id: "43",      title: "Aquarium",         subtitle: "Aqua Band",  imageUrl: "cdn/43.jpg",  trackCount: 11 },
            { kind: "artist",   id: "7",       title: "Boards of Canada", subtitle: "",           imageUrl: "cdn/7.jpg",   trackCount: 0  },
            { kind: "mix",      id: "mix-1",   title: "Daily Discovery",  subtitle: "Your mix",   imageUrl: "cdn/m1.jpg",  trackCount: 0  },
            { kind: "playlist", id: "uuid-p1", title: "Evening Drive",    subtitle: "",           imageUrl: "cdn/p1.jpg",  trackCount: 31 },
            { kind: "album",    id: "42",      title: "Fever Dream",      subtitle: "The Band",   imageUrl: "cdn/42.jpg",  trackCount: 14 },
            { kind: "playlist", id: "uuid-p2", title: "Golden Hour",      subtitle: "",           imageUrl: "cdn/p2.jpg",  trackCount: 9  }
        ]
    }

    // A song, so the sidebar can be asked what it offers on one. Songs only
    // ever reach the list through a search.
    function makeTracks() {
        return [
            { kind: "track", id: "t1", title: "Zodiac Shift", subtitle: "Radiohead", imageUrl: "cdn/t1.jpg", albumId: 42 }
        ]
    }

    // The LibraryIndex contract, in the few lines of it these tests depend on.
    function applyPins() {
        var base = baseEntries()
        var pinned = []
        var rest = []
        for (var i = 0; i < base.length; ++i) {
            var row = base[i]
            var at = pins.indexOf(row.kind, row.id)
            row.pinned = at >= 0
            if (at >= 0) { row.pinAt = at; pinned.push(row) }
            else                            rest.push(row)
        }
        pinned.sort(function (a, b) { return a.pinAt - b.pinAt })
        library.setEntriesForTest(pinned.concat(rest))
    }

    Connections {
        target: pins
        function onChanged() { testCase.applyPins() }
    }

    SignalSpy { id: pinsSpy; target: pins; signalName: "changed" }

    function init() {
        prefs.setSidebarWidthForTest(220)
        app.setReducedMotionForTest(true)   // no slide to wait out
        auth.setUsernameForTest("linus")
        pins.setItemsForTest([])            // fires applyPins() through the Connections
        library.setTracksForTest(makeTracks())
        library.resetCallsForTest()
        applyPins()
        pinsSpy.clear()
    }

    function setPins(list) {
        pins.setItemsForTest(list)
        applyPins()
        pinsSpy.clear()
    }

    function pinRow(kind, id, title) {
        return { kind: kind, id: id, title: title, subtitle: "", imageUrl: "cdn/" + id + ".jpg" }
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function settle(item) {
        wait(1)
        waitForRendering(item, 2000)
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

    function collectVisibleByName(item, name, out) {
        if (item.visible === false) return out
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) collectVisibleByName(kids[i], name, out)
        return out
    }

    function rowIds(sidebar) {
        var out = []
        for (var i = 0; i < sidebar.rows.length; ++i) out.push(sidebar.rows[i].id)
        return out
    }

    function pinIds() {
        var out = []
        for (var i = 0; i < pins.items.length; ++i) out.push(pins.items[i].id)
        return out
    }

    function rowFor(sidebar, id) {
        var rows = collectByName(sidebar, "libraryRow", [])
        for (var i = 0; i < rows.length; ++i)
            if (rows[i].itemId === id) return rows[i]
        return null
    }

    // Events go through the window's content item, never through the item
    // being dragged: a dragged row travels with the pointer, so coordinates
    // taken against it would chase themselves.
    function pointIn(host, item, dx, dy) {
        return item.mapToItem(host.contentItem, dx, dy)
    }

    function rightClickItem(host, item) {
        var p = pointIn(host, item, item.width / 2, item.height / 2)
        mouseClick(host.contentItem, p.x, p.y, Qt.RightButton)
        wait(1)
    }

    // ── hosts ────────────────────────────────────────────────────────────

    Component {
        id: shellHost
        Window {
            id: win
            width: 1280
            height: 800
            color: "black"

            property alias sidebar: sb
            property alias pane: contentPane

            RowLayout {
                anchors.fill: parent
                spacing: 0

                SideBar {
                    id: sb
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

    Component { id: albumC;     AlbumPage    { anchors.fill: parent } }
    Component { id: playlistC;  PlaylistPage { anchors.fill: parent } }
    Component { id: mixC;       MixPage      { anchors.fill: parent } }
    Component { id: artistC;    ArtistPage   { anchors.fill: parent } }
    Component { id: mediaCardC; MediaCard    { } }

    function showHost(w) {
        var host = createTemporaryObject(shellHost, testCase)
        verify(host, "host window was not created")
        host.width = w
        host.visible = true
        waitForRendering(host.contentItem, 2000)
        // Park the pointer away from the rail, which would otherwise
        // hover-expand before the test asked for anything.
        mouseMove(host.contentItem, w - 8, host.height - 8)
        tryVerify(function () {
            return host.sidebar.panelWidth === host.sidebar.targetWidth
        }, 2000, "the sidebar never settled")
        settle(host.contentItem)
        return host
    }

    // Builds one of the four hero pages, filled in, inside the host's pane.
    function makePage(host, kind) {
        var page
        switch (kind) {
        case "album":
            page = createTemporaryObject(albumC, host.pane)
            page.albumId = 42
            page.albumData = { title: "Fever Dream", artists: "The Band", year: "2019",
                               numTracks: 14, duration: 2400, coverUrl: "cdn/42.jpg",
                               coverUrl640: "", artistId: 7 }
            break
        case "playlist":
            page = createTemporaryObject(playlistC, host.pane)
            page.playlistUuid = "uuid-p1"
            page.playlistTitle = "Evening Drive"
            page.coverUrl = "cdn/p1.jpg"
            break
        case "mix":
            page = createTemporaryObject(mixC, host.pane)
            page.mixId = "mix-1"
            page.title = "Daily Discovery"
            page.subtitle = "Your mix"
            page.coverUrl = "cdn/m1.jpg"
            break
        case "artist":
            page = createTemporaryObject(artistC, host.pane)
            page.artistId = 7
            page.artistData = { name: "Boards of Canada", coverUrl: "cdn/7.jpg", coverUrl750: "" }
            break
        }
        verify(page, "the " + kind + " page was not created")
        settle(page)
        return page
    }

    // What a pin made from this page should look like.
    function pageTarget(kind) {
        switch (kind) {
        case "album":    return { id: "42",      title: "Fever Dream" }
        case "playlist": return { id: "uuid-p1", title: "Evening Drive" }
        case "mix":      return { id: "mix-1",   title: "Daily Discovery" }
        case "artist":   return { id: "7",       title: "Boards of Canada" }
        }
        return null
    }

    // ── P2: the menu, and the label that follows the state ───────────────

    function test_sidebar_row_offers_pin_then_unpin() {
        var host = showHost(1280)
        var sb = host.sidebar

        var row = rowFor(sb, "42")
        verify(row, "the library list never drew the Fever Dream row")
        rightClickItem(host, row)

        var menu = sb.pinMenu
        tryVerify(function () { return menu.visible }, 2000,
                  "right-clicking a library row opened no menu")
        verify(menu.pinItem.visible, "the menu offers nothing to pin")
        compare(menu.pinItem.text, qsTr("Pin", "verb, pin to the sidebar"),
                "an unpinned row must be offered Pin")

        menu.pinItem.triggered()
        verify(pins.isPinned("album", "42"), "Pin did not reach PinStore")
        menu.close()
        settle(host.contentItem)

        // Same row, now pinned: the label has to say so.
        row = rowFor(sb, "42")
        verify(row, "the pinned row vanished from the sidebar")
        rightClickItem(host, row)
        tryVerify(function () { return menu.visible }, 2000, "the menu did not reopen")
        compare(menu.pinItem.text, qsTr("Unpin"), "a pinned row must be offered Unpin")

        menu.pinItem.triggered()
        verify(!pins.isPinned("album", "42"), "Unpin did not reach PinStore")
        menu.close()
    }

    function test_media_card_offers_pin_and_unpin() {
        var host = showHost(1280)
        var card = createTemporaryObject(mediaCardC, host.pane, {
            mediaType: "album", itemId: "42", title: "Fever Dream",
            subtitle: "The Band", coverUrl: "cdn/42.jpg"
        })
        verify(card, "the card was not created")
        settle(host.contentItem)

        rightClickItem(host, card)
        var menu = card.pinMenu
        tryVerify(function () { return menu.visible }, 2000, "a card offers no context menu")
        compare(menu.pinItem.text, qsTr("Pin", "verb, pin to the sidebar"), "card menu label")
        menu.pinItem.triggered()
        verify(pins.isPinned("album", "42"), "pinning from a card did not reach PinStore")
        compare(pins.items[0].title, "Fever Dream", "the card pinned the wrong title")
        compare(pins.items[0].imageUrl, "cdn/42.jpg", "the card pinned no artwork")
        menu.close()

        rightClickItem(host, card)
        tryVerify(function () { return menu.visible }, 2000, "the card menu did not reopen")
        compare(menu.pinItem.text, qsTr("Unpin"), "the card label must follow the pin state")
        menu.pinItem.triggered()
        verify(!pins.isPinned("album", "42"), "unpinning from a card did not reach PinStore")
        menu.close()
    }

    // ── P1: the four kinds, and only those four ──────────────────────────

    function test_page_headers_pin_all_four_kinds_data() {
        return [
            { tag: "album",    kind: "album"    },
            { tag: "playlist", kind: "playlist" },
            { tag: "mix",      kind: "mix"      },
            { tag: "artist",   kind: "artist"   }
        ]
    }

    function test_page_headers_pin_all_four_kinds(row) {
        var host = showHost(1280)
        var page = makePage(host, row.kind)
        var want = pageTarget(row.kind)

        var hero = findByName(page, "heroPinArea")
        verify(hero, "the " + row.kind + " hero header is not a pin target")
        rightClickItem(host, hero)

        var menu = page.pinMenu
        tryVerify(function () { return menu.visible }, 2000,
                  "the " + row.kind + " hero opened no menu")
        compare(menu.pinItem.text, qsTr("Pin", "verb, pin to the sidebar"),
                "the " + row.kind + " hero must offer Pin")
        menu.pinItem.triggered()
        menu.close()

        verify(pins.isPinned(row.kind, want.id),
               "the " + row.kind + " hero did not pin " + want.id)
        compare(pins.items[0].title, want.title, "the wrong title was pinned")

        rightClickItem(host, hero)
        tryVerify(function () { return menu.visible }, 2000, "the hero menu did not reopen")
        compare(menu.pinItem.text, qsTr("Unpin"), "the hero label must follow the pin state")
        menu.pinItem.triggered()
        menu.close()
        verify(!pins.isPinned(row.kind, want.id), "the hero could not unpin again")
    }

    // PinStore::isValidKind is the authority and a song is not on it, so there
    // is nothing to offer and no menu to show.
    function test_a_song_cannot_be_pinned() {
        var host = showHost(1280)
        var sb = host.sidebar

        var card = createTemporaryObject(mediaCardC, host.pane, {
            mediaType: "track", itemId: "t1", title: "Zodiac Shift", subtitle: "Radiohead"
        })
        settle(host.contentItem)
        rightClickItem(host, card)
        wait(50)
        verify(!card.pinMenu.visible, "a song tile offered a pin menu")

        // And the same from the sidebar, where a song only ever appears as a
        // search result.
        findByName(sb, "sidebarFinder").query = "zodiac"
        tryVerify(function () { return rowIds(sb).join(",") === "t1" }, 2000,
                  "the search did not reach the song index")
        settle(host.contentItem)

        var row = rowFor(sb, "t1")
        verify(row, "the song row was never drawn")
        rightClickItem(host, row)
        wait(50)
        verify(!sb.pinMenu.visible, "a song row offered a pin menu")
        compare(pins.items.length, 0, "a song reached PinStore")
    }

    // ── P3/P5: the pinned block, live, and never duplicated ──────────────

    function test_pinning_on_a_page_moves_the_row_into_the_pinned_block() {
        var host = showHost(1280)
        var sb = host.sidebar
        var page = makePage(host, "album")

        compare(rowIds(sb).join(","), "43,7,mix-1,uuid-p1,42,uuid-p2",
                "the fixture should start out A-Z with nothing pinned")
        compare(collectVisibleByName(sb, "pinnedBlockBreak", []).length, 0,
                "a break was drawn with no pinned block above it")

        rightClickItem(host, findByName(page, "heroPinArea"))
        tryVerify(function () { return page.pinMenu.visible }, 2000, "no hero menu")
        page.pinMenu.pinItem.triggered()
        page.pinMenu.close()
        settle(host.contentItem)

        // P3: the block is above the list, and it updated without anyone
        // touching the sidebar.
        tryVerify(function () { return rowIds(sb)[0] === "42" }, 2000,
                  "the pin did not reach the sidebar's pinned block")
        compare(sb.pinnedCount, 1, "exactly one row belongs above the break")

        // P5: once, and only in the block.
        var rows = collectByName(sb, "libraryRow", [])
        var seen = ({})
        var below = 0
        for (var i = 0; i < rows.length; ++i) {
            var key = rows[i].kind + ":" + rows[i].itemId
            verify(!seen[key], "\"" + rows[i].title + "\" is in the sidebar twice")
            seen[key] = true
            if (!rows[i].pinned) below++
            if (rows[i].itemId === "42") verify(rows[i].pinned, "the pinned row reads as unpinned")
        }
        compare(below, 5, "the pinned row was left in the list below as well")

        var breaks = collectVisibleByName(sb, "pinnedBlockBreak", [])
        compare(breaks.length, 1, "the pinned block wants exactly one break under it")
        compare(breaks[0].rowIndex, 1, "the break sits at the wrong row")

        // Unpinning puts it back where the alphabet wants it: between
        // "Evening Drive" and "Golden Hour".
        rightClickItem(host, findByName(page, "heroPinArea"))
        tryVerify(function () { return page.pinMenu.visible }, 2000, "no hero menu the second time")
        compare(page.pinMenu.pinItem.text, qsTr("Unpin"), "the hero should offer Unpin now")
        page.pinMenu.pinItem.triggered()
        page.pinMenu.close()
        settle(host.contentItem)

        tryVerify(function () { return rowIds(sb).join(",") === "43,7,mix-1,uuid-p1,42,uuid-p2" },
                  2000, "unpinning did not return the row to its alphabetical place")
        compare(sb.pinnedCount, 0, "the pinned block should be empty again")
        compare(collectVisibleByName(sb, "pinnedBlockBreak", []).length, 0,
                "the break outlived the block")
    }

    // ── P4: drag to reorder inside the pinned block ──────────────────────

    function test_drag_reorders_the_pinned_block() {
        setPins([pinRow("playlist", "uuid-p1", "Evening Drive"),
                 pinRow("album",    "43",      "Aquarium"),
                 pinRow("mix",      "mix-1",   "Daily Discovery")])

        var host = showHost(1280)
        var sb = host.sidebar
        settle(host.contentItem)

        compare(sb.pinnedCount, 3, "three fixture pins belong above the break")
        compare(rowIds(sb).join(","), "uuid-p1,43,mix-1,7,42,uuid-p2", "the starting order")

        var row = rowFor(sb, "uuid-p1")
        var grip = findByName(row, "pinDragArea")
        verify(grip, "a pinned row has no drag affordance")
        verify(grip.enabled, "the drag affordance is dead")

        var rowHeight = rowHeightOf(sb)
        var from = pointIn(host, grip, grip.width / 2, grip.height / 2)
        mousePress(host.contentItem, from.x, from.y)
        mouseMove(host.contentItem, from.x, from.y + rowHeight)
        wait(1)
        // A clear drop indicator, inside the block, while the drag is live.
        var marker = findByName(sb, "pinDropIndicator")
        verify(marker, "there is no drop indicator")
        verify(marker.visible, "the drop indicator never showed")
        compare(sb.pinDragTo, 1, "one row of travel is one slot")

        mouseMove(host.contentItem, from.x, from.y + 2 * rowHeight)
        wait(1)
        compare(sb.pinDragTo, 2, "two rows of travel is two slots")

        mouseRelease(host.contentItem, from.x, from.y + 2 * rowHeight)
        settle(host.contentItem)

        // pins.move(0, 2) and nothing else: a swap would have left Daily
        // Discovery in the middle.
        compare(pinIds().join(","), "43,mix-1,uuid-p1", "pins.move was called with the wrong pair")
        compare(pins.items.length, 3, "the drop added or dropped a pin")
        compare(pinsSpy.count, 1, "one drop is one write")
        tryVerify(function () { return rowIds(sb).join(",") === "43,mix-1,uuid-p1,7,42,uuid-p2" },
                  2000, "the visible order did not follow the drop")
        compare(sb.pinnedCount, 3, "the block changed size over a reorder")
        verify(!findByName(sb, "pinDropIndicator").visible, "the drop indicator outlived the drag")
    }

    // The drag is confined to the block: a row dropped over the ordinary
    // library list below is not reordered, and is certainly not unpinned.
    function test_a_drop_outside_the_pinned_block_changes_nothing() {
        setPins([pinRow("playlist", "uuid-p1", "Evening Drive"),
                 pinRow("album",    "43",      "Aquarium"),
                 pinRow("mix",      "mix-1",   "Daily Discovery")])

        var host = showHost(1280)
        var sb = host.sidebar
        settle(host.contentItem)

        var grip = findByName(rowFor(sb, "uuid-p1"), "pinDragArea")
        var rowHeight = rowHeightOf(sb)
        var from = pointIn(host, grip, grip.width / 2, grip.height / 2)

        mousePress(host.contentItem, from.x, from.y)
        mouseMove(host.contentItem, from.x, from.y + 4 * rowHeight)   // two rows past the break
        wait(1)
        verify(!findByName(sb, "pinDropIndicator").visible,
               "the indicator should go dark once the pointer leaves the block")
        mouseRelease(host.contentItem, from.x, from.y + 4 * rowHeight)
        settle(host.contentItem)

        compare(pinIds().join(","), "uuid-p1,43,mix-1", "a drop below the block reordered the pins")
        compare(pinsSpy.count, 0, "a drop below the block wrote to PinStore")
        verify(pins.isPinned("playlist", "uuid-p1"), "a drop below the block unpinned the row")
        compare(rowIds(sb).join(","), "uuid-p1,43,mix-1,7,42,uuid-p2", "the list reordered anyway")

        // Sideways, out of the sidebar entirely: same answer.
        mousePress(host.contentItem, from.x, from.y)
        mouseMove(host.contentItem, from.x + 600, from.y + rowHeight)
        wait(1)
        mouseRelease(host.contentItem, from.x + 600, from.y + rowHeight)
        settle(host.contentItem)

        compare(pinIds().join(","), "uuid-p1,43,mix-1", "a drop onto the page reordered the pins")
        compare(pinsSpy.count, 0, "a drop onto the page wrote to PinStore")
    }

    // An unpinned row is not draggable at all: there is no reordering the
    // alphabet, and nothing can be dragged up into the block.
    function test_rows_below_the_block_have_no_drag_handle() {
        setPins([pinRow("playlist", "uuid-p1", "Evening Drive")])

        var host = showHost(1280)
        var sb = host.sidebar
        settle(host.contentItem)

        var plain = rowFor(sb, "42")
        verify(plain, "the Fever Dream row was never drawn")
        var grip = findByName(plain, "pinDragArea")
        verify(!grip || !grip.enabled, "an unpinned row can be dragged")
    }

    // ── S9: the rail ─────────────────────────────────────────────────────

    // The rail shows the pinned covers and nothing else of the library, so a
    // right-click there can only mean the one thing: unpin.
    function test_right_clicking_a_rail_cover_offers_unpin() {
        setPins([pinRow("playlist", "uuid-p1", "Evening Drive"),
                 pinRow("album",    "43",      "Aquarium")])

        var host = showHost(640)
        var sb = host.sidebar
        verify(sb.compact, "a 640px window must give the rail")
        settle(host.contentItem)

        var covers = collectVisibleByName(sb, "railPinCover", [])
        compare(covers.length, 6, "every library row wants a cover in the rail")

        rightClickItem(host, covers[0])
        var menu = sb.pinMenu
        tryVerify(function () { return menu.visible }, 2000, "a rail cover offered no menu")
        compare(menu.pinItem.text, qsTr("Unpin"), "a rail cover is pinned by definition")
        menu.pinItem.triggered()
        menu.close()
        settle(host.contentItem)

        verify(!pins.isPinned("playlist", "uuid-p1"), "unpinning from the rail did nothing")
        tryVerify(function () {
            return collectVisibleByName(sb, "railPinCover", []).length === 6
        }, 2000, "the rail kept the cover of an unpinned item")
    }
}
