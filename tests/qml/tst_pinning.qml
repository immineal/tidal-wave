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

    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
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

    // ── what a tile hands the store, per kind ────────────────────────────
    //
    // A pin row is written to QSettings and read back in some later session, so
    // the only thing worth putting in its subtitle is a datum Tidal sent. An
    // album tile's subtitle is its artists and a mix tile's is Tidal's own:
    // both are facts, both keep. An artist tile's is the word qsTr("Artist"),
    // and a playlist tile's is qsTr("%n track(s)") over a cached count - app
    // text, not data - so neither may be stored. Frozen, the playlist one is
    // wrong twice over: the wrong language after the app's locale changes, and
    // the wrong number as soon as a track is added to the playlist.
    //
    // MediaCard.pinSubtitle is the property that draws this line, and until
    // this test nothing asserted it for any kind - which is how the playlist
    // case got in. Driven through the tile's real right-click area and the real
    // menu entry, so what is asserted is what the app stores, not what this
    // file passes along.
    function test_a_tile_pins_data_and_not_app_text_data() {
        return [
            { tag: "album keeps its artists",
              kind: "album",    id: "42",      drawn: "The Band",
              stored: "The Band" },
            { tag: "mix keeps Tidal's own subtitle",
              kind: "mix",      id: "mix-1",   drawn: "Your mix",
              stored: "Your mix" },
            { tag: "artist stores no type label",
              kind: "artist",   id: "7",       drawn: qsTr("Artist"),
              stored: "" },
            { tag: "playlist stores no track count",
              kind: "playlist", id: "uuid-p1", drawn: qsTr("%n track(s)", "", 31),
              stored: "" }
        ]
    }

    function test_a_tile_pins_data_and_not_app_text(data) {
        var host = showHost(1280)
        var card = createTemporaryObject(mediaCardC, host.pane, {
            mediaType: data.kind, itemId: data.id, title: "Whatever",
            subtitle: data.drawn, coverUrl: "cdn/" + data.id + ".jpg"
        })
        verify(card, "the card was not created")
        settle(host.contentItem)

        // The tile still draws what it was given; this is about what it stores.
        compare(card.subtitle, data.drawn, "the tile stopped drawing its subtitle")

        rightClickItem(host, card)
        var menu = card.pinMenu
        tryVerify(function () { return menu.visible }, 2000, "a card offers no context menu")
        menu.pinItem.triggered()
        verify(pins.isPinned(data.kind, data.id), "pinning from a card did not reach PinStore")

        compare(pins.items[0].subtitle, data.stored,
                "a " + data.kind + " tile stored the wrong subtitle")
        // The fields that are facts are still there, so this is a rule about
        // one field and not a tile that stopped describing itself.
        compare(pins.items[0].title, "Whatever", "the card pinned the wrong title")
        compare(pins.items[0].imageUrl, "cdn/" + data.id + ".jpg",
                "the card pinned no artwork")
        menu.close()
    }

    // Where a pinned row's text actually comes from, written down because the
    // repo has guessed it wrong twice in two days and in both directions.
    //
    // A pinned row is a *library* row that PinStore moved to the front of the
    // list. The model is `library.entriesForKinds()`, the delegate reads it
    // through `modelData`, and nothing in qml/ reads `pins.items` at all - so a
    // pin's stored title, subtitle and artwork are never drawn anywhere,
    // including in the hover tooltip that is the only place a row's subtitle
    // reaches the screen.
    //
    // That is what makes the frozen track count the test above is about a latent
    // defect rather than a visible one, and it is also why nothing had to be
    // migrated to make the pinned block read correctly. Asserted with the two
    // sources deliberately disagreeing: this pin carries a title, a subtitle and
    // an artwork url that no library row has.
    function test_a_pinned_row_draws_the_library_row_not_the_pin() {
        setPins([{ kind: "album", id: "42", title: "A title only the pin has",
                   subtitle: "A subtitle only the pin has",
                   imageUrl: "cdn/only-the-pin.jpg" }])

        var host = showHost(1280)
        var sb = host.sidebar
        settle(host.contentItem)

        var row = rowFor(sb, "42")
        verify(row, "the pinned album has no sidebar row")
        verify(row.pinned, "the row did not come through as pinned")

        compare(row.title, "Fever Dream", "the row drew the pin's title")
        compare(row.modelData.subtitle, "The Band", "the row drew the pin's subtitle")
        compare(row.modelData.imageUrl, "cdn/42.jpg", "the row drew the pin's artwork")

        // The tooltip is on every row deliberately - in the collapsed rail the
        // title is not on screen at all - so it is the one draw site a stored
        // pin subtitle could ever have reached, and it does not read it.
        var box = findByName(row, "libraryRowTitle").parent
        verify(box, "the row has no content box to carry the tooltip")
        compare(box.ToolTip.text, "Fever Dream · The Band",
                "the row tooltip is not built from the library row")
    }

    // ── Collection's grids, which could not pin at all ───────────────────
    //
    // The album and the artist delegate each declared a right-click MouseArea
    // *after* the MediaCard, so the tile's own menu never opened and its Pin
    // entry was unreachable: an album or an artist could be pinned from its
    // page or from the sidebar, and not from the library view that lists
    // them. Both bespoke menus are gone and the tiles use the one shared
    // ContextMenu, which is what these two cases hold in place.
    //
    // StubBridge's searchFavoriteAlbums/Artists return nothing, so the page's
    // filtered lists are written straight onto it. The tab is set first:
    // changing it is what calls updateFilteredContent(), which would wipe
    // them.
    function makeCollection(host, tab, items) {
        var page = createTemporaryObject(collectionC, host.pane)
        verify(page, "CollectionPage was not created")
        page.activeTab = tab
        if (tab === 1) page.filteredAlbums  = items
        else           page.filteredArtists = items
        settle(host.contentItem)
        return page
    }

    // The tiles on the page, found through the right-click area every
    // MediaCard declares; its parent is the card.
    function cardsOn(page) {
        var areas = collectVisibleByName(page, "cardMenuArea", [])
        var out = []
        for (var i = 0; i < areas.length; ++i) out.push(areas[i].parent)
        return out
    }

    function test_collection_album_grid_can_pin() {
        var host = showHost(1280)
        var page = makeCollection(host, 1, [
            { id: 42, title: "Fever Dream", artists: "The Band", coverUrl: "cdn/42.jpg" }
        ])
        var cards = cardsOn(page)
        compare(cards.length, 1, "the albums grid drew no tile")

        rightClickItem(host, cards[0])
        var menu = cards[0].pinMenu
        tryVerify(function () { return menu.visible }, 2000,
                  "right-clicking an album in Collection opens no menu")
        verify(menu.pinItem.visible, "the album tile offers no Pin entry")
        compare(menu.pinItem.text, qsTr("Pin", "verb, pin to the sidebar"))

        menu.pinItem.triggered()
        verify(pins.isPinned("album", "42"),
               "pinning an album from Collection did not reach PinStore")
        compare(pins.items[0].title, "Fever Dream")
        menu.close()

        // And the rest of the one menu is here too, destructive entry last,
        // every row carrying an icon.
        rightClickItem(host, cards[0])
        tryVerify(function () { return menu.visible }, 2000, "the menu did not reopen")
        compare(menu.pinItem.text, qsTr("Unpin"), "the label must follow the pin state")
        verify(menu.playNextItem.visible, "an album tile must still offer Play next")
        verify(menu.addToQueueItem.visible, "an album tile must still offer Add to queue")
        compare(menu.removeItem.text, qsTr("Remove from library"))
        verify(menu.removeItem.danger, "removing from the library is destructive")
        compare(menu.removeItem.iconName, "trash")
        verify(!menu.pinItem.danger, "pinning is not destructive")
        // Pin is the row that proves the icon is not merely decoration: the
        // filled pin is the one already stuck in, so it is the row that pulls
        // it out, and the glyph has to follow the label rather than sit fixed.
        compare(menu.pinItem.iconName, "pin-filled",
                "the Unpin row must draw the state it is in")
        verify(menu.playNextItem.iconName !== "" && menu.addToQueueItem.iconName !== "",
               "every entry of this menu carries an icon, not only the destructive one")
        menu.close()
    }

    function test_collection_artist_grid_can_pin() {
        var host = showHost(1280)
        var page = makeCollection(host, 2, [
            { id: 7, name: "Boards of Canada", coverUrl: "cdn/7.jpg" }
        ])
        var cards = cardsOn(page)
        compare(cards.length, 1, "the artists grid drew no tile")

        rightClickItem(host, cards[0])
        var menu = cards[0].pinMenu
        tryVerify(function () { return menu.visible }, 2000,
                  "right-clicking an artist in Collection opens no menu")
        verify(menu.pinItem.visible, "the artist tile offers no Pin entry")
        menu.pinItem.triggered()
        verify(pins.isPinned("artist", "7"),
               "pinning an artist from Collection did not reach PinStore")
        menu.close()

        rightClickItem(host, cards[0])
        tryVerify(function () { return menu.visible }, 2000, "the menu did not reopen")
        compare(menu.removeItem.text, qsTr("Unfollow artist"))
        verify(menu.removeItem.danger)
        // An artist is not a tracklist: "queue this artist" has no honest
        // meaning, so those two rows stay away.
        verify(!menu.playNextItem.visible, "an artist tile should offer no Play next")
        verify(!menu.addToQueueItem.visible, "an artist tile should offer no Add to queue")
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
    // A block of two, which is both the smallest block that can be dragged at
    // all and the size every account reaches first: PinStore seeds one pin, so
    // the second pin the user makes is where reordering becomes possible.
    //
    // One gesture, three times, and the only thing that differs is where inside
    // the handle the pointer came down — which is not something anyone can see,
    // choose, or be told about.
    //
    // It used to decide whether the drop counted. pinSlotAt() *clamps* its
    // target into the block, so the indicator always points at a legal slot,
    // but the bounds were measured against the pointer: the press's own place
    // in the row it grabbed, plus the travel, against the block's pixel extent.
    // The two disagree by however far into the row the press landed, and the
    // block is only pinnedCount rows tall — 88px here — so a press in the
    // middle of the row and a pull of a row and a half put the pointer past the
    // block's bottom edge while the indicator was still pointing at the bottom
    // slot. The drop was then thrown away with nothing said: a line drawn where
    // the row was going to land, and a row that stayed where it was.
    //
    // It took a block of two to show. The three-pin fixture above has 132px to
    // play with, which swallows the same gesture whole.
    function test_a_block_of_two_swaps_wherever_the_handle_was_grabbed_data() {
        return [
            { tag: "grabbed at the top",    grab: 4  },
            { tag: "grabbed in the middle", grab: 22 },
            { tag: "grabbed at the bottom", grab: 36 }
        ]
    }

    function test_a_block_of_two_swaps_wherever_the_handle_was_grabbed(row) {
        setPins([pinRow("mix",   "mix-1", "Daily Discovery"),
                 pinRow("album", "43",    "Aquarium")])

        var host = showHost(1280)
        var sb = host.sidebar
        settle(host.contentItem)

        compare(sb.pinnedCount, 2, "two fixture pins belong above the break")
        compare(rowIds(sb).join(","), "mix-1,43,7,uuid-p1,42,uuid-p2", "the starting order")

        var rowHeight = rowHeightOf(sb)
        var top = rowFor(sb, "mix-1")
        verify(top, "the row to drag was never drawn")
        // Aimed in the *row's* coordinates and not the handle's: the handle
        // inflates its hit area by 5px on every side, so its own lower edge is
        // inside the row below, where a press is a press on that row.
        var at = pointIn(host, top, top.width - 22, row.grab)
        mousePress(host.contentItem, at.x, at.y)
        // A row and a half: far enough that the row being dragged is past the
        // one it is changing places with, which is how far a hand takes it.
        mouseMove(host.contentItem, at.x, at.y + 1.5 * rowHeight)
        wait(1)
        // Whatever the pointer did, this is where the sidebar had decided the
        // row would land, because pinSlotAt() clamps into the block.
        compare(sb.pinDragTo, 1, "the bottom slot is the only place a block of two can send it")
        var promised = findByName(sb, "pinDropIndicator").visible
        mouseRelease(host.contentItem, at.x, at.y + 1.5 * rowHeight)
        settle(host.contentItem)

        // The store, because the store is the order and the rows are a reading
        // of it: a drop that moves the rows and not the pins is undone by the
        // next rebuild, and one that moves neither is this bug.
        compare(pinIds().join(","), "43,mix-1",
                "the drop was thrown away — the target was slot 1 and the pins did not move"
                + " (the indicator was " + (promised ? "still up" : "already dark")
                + " when the pointer came up)")
        compare(pins.items.length, 2, "the drop added or dropped a pin")
        compare(pinsSpy.count, 1, "one drop is one write")
        tryVerify(function () { return rowIds(sb).join(",") === "43,mix-1,7,uuid-p1,42,uuid-p2" },
                  2000, "the visible order did not follow the drop")
        compare(sb.pinnedCount, 2, "the block changed size over a reorder")
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

    // Two drops in a row, with nothing in between - which is what arranging a
    // pinned block actually looks like: one drag, then the next, as fast as the
    // pointer can be aimed.
    //
    // The first drop is what breaks the second. It reorders the pins, the list
    // animates the reorder (SideBar's move/displaced transitions), and for the
    // length of that travel a row's `index` is already its new one while its `y`
    // is still its old one. The drag is written in indices - `pinDragFrom` is one
    // and pinSlotAt() returns one - so a press read off the drawn position alone
    // put the gesture in the wrong frame by as much as the whole travel, and the
    // release was abandoned as "outside the block". Nothing said so: the pins
    // simply did not move.
    //
    // Deliberately no settle() between the two drags, and that is not a race:
    // the model moves the row synchronously inside the first release, while the
    // view repositions it on its next polish, so the press below always lands on
    // a row whose index and drawn place disagree. Waiting is exactly what hid
    // this - test_drag_reorders_the_pinned_block waits, and passes either way.
    function test_a_second_drag_lands_while_the_first_is_still_travelling() {
        setPins([pinRow("playlist", "uuid-p1", "Evening Drive"),
                 pinRow("album",    "43",      "Aquarium"),
                 pinRow("mix",      "mix-1",   "Daily Discovery")])

        var host = showHost(1280)
        var sb = host.sidebar
        settle(host.contentItem)
        var rowHeight = rowHeightOf(sb)

        // One drag of the top row, two slots down, in the shape the passing
        // test uses.
        function dragBy(id, slots) {
            var row = rowFor(sb, id)
            verify(row, "the row \"" + id + "\" was never drawn")
            var grip = findByName(row, "pinDragArea")
            verify(grip && grip.enabled, "the row \"" + id + "\" has no live drag handle")
            var at = pointIn(host, grip, grip.width / 2, grip.height / 2)
            // Where the row was drawn and which slot it says it is in, as the
            // press sees them. Kept for the failure message below, which is
            // about the two disagreeing.
            var drawnY = row.y
            var index = row.index
            mousePress(host.contentItem, at.x, at.y)
            mouseMove(host.contentItem, at.x, at.y + slots * rowHeight)
            wait(1)
            var landed = sb.pinDragTo
            var ok = sb.pinDropValid
            mouseRelease(host.contentItem, at.x, at.y + slots * rowHeight)
            return { to: landed, valid: ok, drawnY: drawnY, index: index }
        }

        var first = dragBy("uuid-p1", 2)
        compare(first.to, 2, "the first drag did not reach the bottom of the block")
        compare(pinIds().join(","), "43,mix-1,uuid-p1", "the first drop did not reorder the pins")

        // The state the second drag begins in: the row is at index 2 and still
        // drawn at the top. Recorded rather than waited out - this is the whole
        // point of the case, so if it ever stops being true the message below
        // says which half changed.
        var moved = rowFor(sb, "uuid-p1")
        verify(moved, "the row that was just dropped is no longer drawn")
        compare(moved.index, 2, "the model did not move the row inside the release")

        // Straight back up, two slots, with the travel still in flight.
        var second = dragBy("uuid-p1", -2)
        verify(second.valid,
               "the second drop was read as outside the pinned block: the row is at "
               + "index " + second.index + ", which is slot " + (second.index * rowHeight)
               + ", but it was drawn at y " + second.drawnY.toFixed(1)
               + " and the drag was measured against that")
        compare(second.to, 0, "the second drag did not reach the top of the block")
        settle(host.contentItem)
        compare(pinIds().join(","), "uuid-p1,43,mix-1",
                "the second drop did nothing: a drag begun while the list is still "
                + "travelling is silently abandoned")
        compare(pinsSpy.count, 2, "two drops are two writes")
    }

    // The library arriving under a live drag. It arrives in pages over several
    // seconds in the app, so this is ordinary: a page lands while the pointer is
    // down, and past the keyed diff's cap SideBar refills the model wholesale
    // rather than moving rows one at a time. A refill is libModel.clear(), which
    // releases every delegate - including the one holding the pointer grab - and
    // a broken grab is onCanceled, so the drag ended with nothing said and
    // nothing moved.
    //
    // This one only tells the truth when the machine is busy, which is worth
    // knowing before trusting its green. Run on an idle box it passes either
    // way: the released delegates are still waiting on deleteLater when the drop
    // arrives, so the gesture survives by luck. Run with eight spinners on
    // twelve cores, and with another of this file's drags having been through the
    // same process first, it failed ten times out of ten without SideBar's hold
    // and passed ten times out of ten with it.
    function test_the_library_arriving_mid_drag_does_not_lose_the_drop() {
        setPins([pinRow("playlist", "uuid-p1", "Evening Drive"),
                 pinRow("album",    "43",      "Aquarium"),
                 pinRow("mix",      "mix-1",   "Daily Discovery")])

        var host = showHost(1280)
        var sb = host.sidebar
        settle(host.contentItem)
        var rowHeight = rowHeightOf(sb)

        var grip = findByName(rowFor(sb, "uuid-p1"), "pinDragArea")
        var from = pointIn(host, grip, grip.width / 2, grip.height / 2)
        mousePress(host.contentItem, from.x, from.y)
        mouseMove(host.contentItem, from.x, from.y + 2 * rowHeight)
        wait(1)
        compare(sb.pinDragTo, 2, "the drag never reached the bottom of the block")

        // A whole page of the library lands. Far more than the diff's cap, so
        // this is the wholesale refill and not a handful of moves.
        var flood = baseEntries()
        for (var i = 0; i < 60; ++i)
            flood.push({ kind: "album", id: "flood-" + i, title: "Flood " + i,
                         subtitle: "", imageUrl: "", trackCount: 1 })
        var pinned = []
        var rest = []
        for (i = 0; i < flood.length; ++i) {
            var at = pins.indexOf(flood[i].kind, flood[i].id)
            flood[i].pinned = at >= 0
            if (at >= 0) { flood[i].pinAt = at; pinned.push(flood[i]) }
            else                              rest.push(flood[i])
        }
        pinned.sort(function (a, b) { return a.pinAt - b.pinAt })
        library.setEntriesForTest(pinned.concat(rest))
        wait(1)

        verify(sb.pinDragging, "the library arriving cancelled the drag outright")
        compare(sb.pinnedCount, 3, "the block changed size under the pointer")

        mouseRelease(host.contentItem, from.x, from.y + 2 * rowHeight)
        settle(host.contentItem)

        compare(pinIds().join(","), "43,mix-1,uuid-p1",
                "the drop was lost because the library arrived while it was being made")
        verify(!sb.pinDragging, "the sidebar still thinks a drag is in progress")
        verify(!findByName(sb, "pinDropIndicator").visible,
               "the drop indicator outlived the drag")
        tryVerify(function () { return rowIds(sb).join(",") === "43,mix-1,uuid-p1,7,42,uuid-p2" },
                  2000, "the visible order did not follow the drop")

        // And the list is listening again: what is held for the length of a drag
        // is held for the length of a drag and no longer.
        var more = baseEntries()
        for (i = 0; i < 60; ++i)
            more.push({ kind: "album", id: "late-" + i, title: "Late " + i,
                        subtitle: "", imageUrl: "", trackCount: 1 })
        library.setEntriesForTest(more)
        tryVerify(function () { return sb.rows.length === 66 }, 2000,
                  "the sidebar stopped taking rows after a drag")
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
