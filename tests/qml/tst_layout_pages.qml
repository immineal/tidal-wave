// Layout regression tests for section C of the handoff (L6, L7, L11, L12, L13).
//
// Every page is built at the four widths the layout audit used:
//   640  the new minimum window width, "usable" rather than pretty
//   820  Prefs::railBreakpoint, where the sidebar collapses to the rail
//   960  half of one of the user's 1920x1200 monitors, the width that has to
//        be *correct*, not merely usable
//   1280 a comfortable width, to catch things that only break when wide
// The width is applied to the page itself, i.e. to the content pane. The real
// pane is narrower than the window by the sidebar, so a page that passes at
// 640 here is still fine in a 640 window.
//
// Two blanket assertions run over every page at every width:
//   * no visible child sticks out of its parent horizontally, and
//   * no visible Text reports itself truncated unless it has an elide mode,
//     i.e. nothing is silently clipped.
// On top of that each of L6/L7/L11/L12/L13 has its own named test.
//
// The auth/bridge/player/downloader/cast/app globals are the stubs from
// tests/TestStubs.h and return empty results, so every page is filled with
// test data by hand after it is created. The stubs answer synchronously, so a
// property that a loadX() overwrites (tracks, albumData, …) must be assigned
// *after* the id that triggers the load.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "LayoutPages"
    when: windowShown
    width: 1400
    height: 1000
    // TestCase declares visible: false, which makes every child report
    // visible == false and would make the audit below skip the whole tree
    // (and would stop the hover test ever delivering a mouse event).
    visible: true

    readonly property var widths: [640, 820, 960, 1280]
    readonly property int paneHeight: 760

    // Hit targets and focus rings are drawn a few px outside their item on
    // purpose (anchors.margins: -4 in TrackRow, SearchBar, HorizontalSection),
    // so the overflow check allows that much and no more.
    readonly property int overflowSlack: 8

    // ── helpers ─────────────────────────────────────────────────────────────

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: albumC;      AlbumPage      { anchors.fill: parent } }
    Component { id: playlistC;   PlaylistPage   { anchors.fill: parent } }
    Component { id: mixC;        MixPage        { anchors.fill: parent } }
    Component { id: artistC;     ArtistPage     { anchors.fill: parent } }
    Component { id: trackRowC;   TrackRow       { } }
    Component { id: pillC;       PillButton     { } }

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i) {
            out.push({
                id:          1000 + i,
                title:       "Ein ziemlich langer Tracktitel Nummer " + (i + 1),
                artists:     "Erster Interpret, Zweiter Interpret, Dritter Interpret",
                albumTitle:  "Ein ziemlich langer Albumtitel Nummer " + (i + 1),
                durationStr: "4:07",
                coverUrl:    "",
                coverUrl80:  "",
                albumId:     42,
                artistId:    7,
                popularity:  73
            })
        }
        return out
    }

    function makeAlbums(n) {
        var out = []
        for (var i = 0; i < n; ++i) {
            out.push({
                id:        200 + i,
                title:     "Ein ziemlich langer Albumtitel Nummer " + (i + 1),
                artists:   "Erster Interpret und noch ein zweiter",
                year:      "2019",
                coverUrl:  "",
                type:      "ALBUM",
                numTracks: 12
            })
        }
        return out
    }

    function makeArtists(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 300 + i, name: "Ein langer Interpretenname " + (i + 1), coverUrl: "" })
        return out
    }

    function makePlaylists(n) {
        var out = []
        for (var i = 0; i < n; ++i) {
            out.push({
                id: 400 + i, uuid: "uuid-" + i,
                title: "Eine ziemlich lange Wiedergabeliste " + (i + 1),
                description: "Eine Beschreibung, die über mehrere Zeilen laufen kann.",
                coverUrl: "", numTracks: 24, duration: 5400, type: "USER"
            })
        }
        return out
    }

    function makeMixes(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: "mix-" + i, title: "Mein Mix Nummer " + (i + 1),
                       subtitle: "Mit vielen verschiedenen Interpreten", coverUrl: "" })
        return out
    }

    function makePane(comp, w) {
        var holder = createTemporaryObject(holderC, testCase, { width: w, height: paneHeight })
        verify(holder, "holder was not created")
        var page = createTemporaryObject(comp, holder, {})
        verify(page, "page was not created")
        settle(holder)
        return page
    }

    // Layouts resize in the polish phase, so give the window a frame (plus one
    // event-loop turn for the bindings the stubs resolve synchronously).
    function settle(item) {
        wait(1)
        waitForRendering(item, 2000)
    }

    function describe(item) {
        return (item.objectName && item.objectName.length > 0) ? item.objectName : ("" + item)
    }

    // A horizontally scrollable view is *meant* to be wider than its viewport,
    // so its content is not an overflow. Nothing inside it is checked either:
    // off-screen delegates are the whole point of the thing.
    function scrollsHorizontally(item) {
        return item.contentWidth !== undefined && item.contentX !== undefined
               && item.contentWidth > item.width + 1
    }

    function isText(item) {
        return item.truncated !== undefined && item.elide !== undefined && item.text !== undefined
    }

    // Recursive: nothing visible leaves its parent's horizontal bounds, and no
    // Text without an elide mode is truncated.
    function audit(item, label) {
        if (scrollsHorizontally(item))
            return
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || c.visible === undefined || !c.visible) continue
            if (c.width === undefined || c.width <= 0) continue

            verify(c.x + c.width <= item.width + overflowSlack,
                   label + ": " + describe(c) + " ends at " + (c.x + c.width).toFixed(1)
                   + " inside a parent " + item.width.toFixed(1) + " wide")
            verify(c.x >= -overflowSlack,
                   label + ": " + describe(c) + " starts at " + c.x.toFixed(1))

            if (isText(c) && c.elide === Text.ElideNone && ("" + c.text).length > 0)
                verify(!c.truncated,
                       label + ": \"" + c.text + "\" is clipped and has no elide mode")

            audit(c, label)
        }
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

    // ── L11 / blanket audit: the four hero pages ────────────────────────────

    function test_album_page_fits() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(albumC, w)
            page.albumId = 42
            page.albumData = {
                title: "Ein ziemlich langer Albumtitel mit Zusatz (Deluxe Edition)",
                artists: "Erster Interpret, Zweiter Interpret, Dritter Interpret",
                year: "2019", numTracks: 14, duration: 3842,
                quality: "HI_RES_LOSSLESS", artistId: 7, coverUrl: "", coverUrl640: ""
            }
            page.tracks = makeTracks(8)
            settle(page)
            audit(page, "AlbumPage @" + w)
        }
    }

    function test_playlist_page_fits() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(playlistC, w)
            page.playlistType = "USER"   // worst case: the Edit pill shows too
            page.playlistTitle = "Eine ziemlich lange Wiedergabeliste für den Herbst"
            page.playlistDescription = "Eine Beschreibung, die ohne Weiteres über "
                + "mehrere Zeilen laufen kann und trotzdem nicht aus der Seite laufen darf."
            page.playlistDuration = 7322
            page.playlistUuid = "uuid-test"
            page.tracks = makeTracks(8)
            settle(page)
            audit(page, "PlaylistPage @" + w)
        }
    }

    function test_mix_page_fits() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(mixC, w)
            page.mixId = "mix-test"
            page.title = "Mein ganz persönlicher Mix für lange Abende"
            page.subtitle = "Mit Erstem Interpret, Zweitem Interpret und vielen weiteren"
            page.tracks = makeTracks(8)
            settle(page)
            audit(page, "MixPage @" + w)
        }
    }

    function test_artist_page_fits() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(artistC, w)
            page.artistId = 7
            page.artistData = {
                name: "Ein ausgesprochen langer Interpretenname",
                bio: "Eine kurze Biografie mit mehreren Sätzen, damit der Textblock "
                   + "wirklich umbricht und nicht aus der Seite läuft.",
                coverUrl750: "",
                similarArtists: makeArtists(8)
            }
            page.topTracks = makeTracks(6)
            page.albums = makeAlbums(12)
            settle(page)
            audit(page, "ArtistPage @" + w)
        }
    }

    // ── L6 / L12: CollectionPage, all five tabs ─────────────────────────────

    function fillCollection(page, tab) {
        page.activeTab = tab           // this calls updateFilteredContent(), which
        page.filteredTracks    = makeTracks(8)     // wipes the lists, so fill after
        page.filteredAlbums    = makeAlbums(12)
        page.filteredArtists   = makeArtists(12)
        page.filteredPlaylists = makePlaylists(12)
        page.mixes             = makeMixes(10)
    }

    function test_collection_page_fits() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(collectionC, w)
            for (var tab = 0; tab < 5; ++tab) {
                fillCollection(page, tab)
                settle(page)
                audit(page, "CollectionPage tab " + tab + " @" + w)
            }
        }
    }

    // L6: the header needed ~1083px against a 740px pane. The search field now
    // sits on its own row under the tabs and stretches to the pane width.
    function test_collection_search_is_on_its_own_row() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(collectionC, w)
            fillCollection(page, 0)
            settle(page)

            var tabs   = findByName(page, "collectionTabsRow")
            var search = findByName(page, "collectionSearch")
            verify(tabs,   "the tab row was not found")
            verify(search, "the search field was not found")

            var tabsBottom = tabs.mapToItem(page, 0, tabs.height).y
            var searchTop  = search.mapToItem(page, 0, 0).y
            verify(searchTop >= tabsBottom - 1,
                   "@" + w + ": the search field is still on the tab row (tabs end at "
                   + tabsBottom.toFixed(1) + ", field starts at " + searchTop.toFixed(1) + ")")
            verify(search.width > 220,
                   "@" + w + ": the search field kept a fixed width (" + search.width.toFixed(1) + ")")
        }
    }

    // L12: the grid used a fixed 184px cell, which left up to 140px of ragged
    // gutter in a 740px pane. The cells now split the pane evenly.
    function test_collection_grid_fills_the_pane() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(collectionC, w)
            fillCollection(page, 1)
            settle(page)

            var grid = findByName(page, "collectionAlbumsGrid")
            verify(grid, "the albums grid was not found")

            var avail = grid.width - grid.leftMargin - grid.rightMargin
            var cols  = Math.floor(avail / grid.cellWidth)
            verify(cols >= 1, "@" + w + ": the grid has no room for a cell")
            verify(grid.cellWidth >= 140,
                   "@" + w + ": cells shrank to " + grid.cellWidth + ", a cover plus two "
                   + "lines of text stops reading below 140")
            // Whole columns, so the leftover can only be the rounding remainder.
            verify(avail - cols * grid.cellWidth < cols + 1,
                   "@" + w + ": " + (avail - cols * grid.cellWidth).toFixed(1)
                   + "px of ragged gutter is left over")
        }
    }

    // ── L13: HorizontalSection peeks at the next card ───────────────────────

    function test_horizontal_section_peeks() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(artistC, w)
            page.artistId = 7
            page.artistData = { name: "Interpret", bio: "", coverUrl750: "", similarArtists: [] }
            page.topTracks = []
            page.albums = makeAlbums(14)
            settle(page)

            var list = findByName(page, "sectionList")
            verify(list, "the section's list was not found")
            verify(list.contentWidth > list.width,
                   "@" + w + ": 14 cards fit without scrolling, so there is nothing to peek at")

            // The card straddling the right edge: it must show enough of itself
            // to read as "there is more", and not so much that it looks like a
            // card that simply got cut.
            var edge = list.contentX + list.width
            var peek = -1
            var card = -1
            for (var k = 0; k < 14; ++k) {
                var d = list.itemAtIndex(k)
                if (!d) continue
                if (d.x < edge && d.x + d.width > edge) {
                    peek = edge - d.x
                    card = d.width
                    break
                }
            }
            verify(peek > 0, "@" + w + ": no card straddles the right edge")
            verify(peek >= card * 0.2 && peek <= card * 0.8,
                   "@" + w + ": the peek is " + peek.toFixed(1) + " of a " + card.toFixed(1)
                   + "px card, which reads as an arbitrary clip rather than a hint")
        }
    }

    // ── L7: TrackRow columns and the hover jitter ───────────────────────────

    function makeRow(w) {
        var holder = createTemporaryObject(holderC, testCase, { width: 1300, height: 120 })
        var t = makeTracks(1)[0]
        var row = createTemporaryObject(trackRowC, holder, {
            width: w, trackNum: 1, title: t.title, artists: t.artists,
            albumTitle: t.albumTitle, durationStr: t.durationStr,
            showPopularity: true, trackData: t
        })
        verify(row, "the row was not created")
        settle(holder)
        return row
    }

    function test_trackrow_hides_album_below_640() {
        var wide = makeRow(700)
        var album = findByName(wide, "trackAlbumColumn")
        verify(album, "the album column was not found")
        verify(album.visible, "the album column is hidden at a row width of 700")

        var narrow = makeRow(639)
        verify(!findByName(narrow, "trackAlbumColumn").visible,
               "the album column still shows at a row width of 639")
    }

    function test_trackrow_hides_popularity_below_560() {
        var wide = makeRow(600)
        var pop = findByName(wide, "trackPopularityColumn")
        verify(pop, "the popularity column was not found")
        verify(pop.visible, "popularity is hidden at a row width of 600")

        var narrow = makeRow(559)
        verify(!findByName(narrow, "trackPopularityColumn").visible,
               "popularity still shows at a row width of 559")
    }

    function test_trackrow_fits_at_every_width() {
        for (var i = 0; i < widths.length; ++i) {
            // The pages hand TrackRow the list width less a 16px inset per side.
            var row = makeRow(widths[i] - 32)
            audit(row, "TrackRow @" + (widths[i] - 32))
        }
    }

    // The hover buttons used to be laid out only while hovered, so the title
    // resized under the pointer. Their space is reserved now, hovered or not.
    function test_trackrow_title_does_not_move_on_hover() {
        var row = makeRow(900)
        var title = findByName(row, "trackTitle")
        verify(title, "the title was not found")

        var x0 = title.mapToItem(row, 0, 0).x
        var w0 = title.width

        mouseMove(row, row.width / 2, row.height / 2)
        settle(row)
        verify(row.hovered, "the row did not register the hover")

        compare(title.mapToItem(row, 0, 0).x, x0, "the title moved when hovered")
        compare(title.width, w0, "the title resized when hovered")

        mouseMove(row, -20, -20)
        settle(row)
    }

    // ── L11: PillButton sizes to its label ──────────────────────────────────

    function test_pillbutton_fits_a_german_label() {
        var holder = createTemporaryObject(holderC, testCase, { width: 600, height: 80 })
        // 24 characters, about what German turns a two word button label into.
        var pill = createTemporaryObject(pillC, holder, { text: "Zufallswiedergabe (lang)", glyph: "⇌" })
        verify(pill, "the pill was not created")
        settle(holder)

        var label = findByName(pill, "pillLabel")
        verify(label, "the pill's label was not found")
        verify(!label.truncated, "the pill's label is clipped")
        verify(pill.width >= label.implicitWidth + 24,
               "the pill is " + pill.width.toFixed(1) + " wide for a label of "
               + label.implicitWidth.toFixed(1) + ", leaving no padding")
        verify(pill.width > 120, "the pill is still stuck at the old fixed 120px")
        audit(pill, "PillButton")
    }
}
