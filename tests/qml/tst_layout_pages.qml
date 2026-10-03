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
// The grid tests below do not use that list. A card clipped at the window edge
// is the one thing that may never happen, and the widths that did it were not
// the round ones, so those sweep 640 to 3840 instead.
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
    Component { id: mediaCardC;  MediaCard      { } }
    Component { id: sectionC;    HorizontalSection { anchors.fill: parent } }

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

    // The deliberate overdraws, each named rather than inferred from clipping
    // so that nothing else picks the exemption up:
    //
    //   * the ring that rounds an artist's artwork is wider than the art on
    //     purpose, and the art box clips it back;
    //   * Collection's travelling tab highlight is one pill, drawn as a slice
    //     inside each chip - every chip holds the *whole* pill and shows the
    //     part of it that is over itself, so the box of a chip that the pill is
    //     not on sits wherever the pill is, with nothing of it on screen;
    //   * and the accent-ink copy of a chip's label is positioned inside that
    //     same clip, so it starts left of its window whenever the pill covers
    //     the right-hand part of the chip.
    function drawnOutsideOnPurpose(item) {
        return item.objectName === "cardArtCorners"
            || item.objectName === "collectionTabPillSlice"
            || item.objectName === "collectionTabInkLabel"
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
            if (drawnOutsideOnPurpose(c)) continue

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

    // The travelling tab highlight as it is drawn, in the tab row's own
    // coordinates. Every chip holds the whole pill and shows the part of it
    // that is over itself, in a window that starts 2px outside the chip - which
    // is where that 2 comes from - so any chip's slice reports the whole pill.
    function drawnPill(tabs) {
        var chip = tabs.children[0]
        if (!chip) return null
        var slice = findByName(chip, "collectionTabPillSlice")
        if (!slice) return null
        return { x: chip.x + slice.x - 2, y: chip.y + slice.y - 2,
                 w: slice.width, h: slice.height }
    }

    function pillSays(tabs) {
        var p = drawnPill(tabs)
        if (!p) return "there is no pill"
        return p.x.toFixed(1) + "," + p.y.toFixed(1) + " " + p.w.toFixed(1) + "x" + p.h.toFixed(1)
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

    // L6: the tab highlight is one pill that travels, and where it comes to
    // rest is a layout question - the chips are text-width, and at 640 the row
    // wraps onto a second line, which is the one place a highlight aimed with
    // an index times a constant would land on nothing.
    //
    // The widths are swept because the five chips are five different widths -
    // each is its label plus its count - and the pill has to be each of them in
    // turn; 640 is the one that wraps, and the wrap is what makes the pill's y
    // worth asserting at all.
    function test_collection_tab_pill_lands_on_the_chip() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(collectionC, w)
            fillCollection(page, 0)
            settle(page)

            var tabs = findByName(page, "collectionTabsRow")
            verify(tabs, "@" + w + ": the tab row was not found")

            var wrapped = false
            for (var tab = 0; tab < 5; ++tab) {
                page.activeTab = tab
                var chip = tabs.children[tab]
                verify(chip, "@" + w + ": chip " + tab + " was not built")
                if (chip.y > 1) wrapped = true

                // tryVerify, because the pill is still travelling when the tab
                // is set: this case is about where it stops. Exactly on the
                // chip and not within a pixel of it - a pill that stops a
                // fraction short leaves a sliver of the resting surface down
                // one edge of the chip, and it is the ink check below that
                // would go on to fail by a pixel and read as a different bug.
                tryVerify(function () {
                    var c = tabs.children[tab]
                    var p = drawnPill(tabs)
                    return p && Math.abs(p.x - c.x) < 0.01 && Math.abs(p.w - c.width)  < 0.01
                        && Math.abs(p.y - c.y) < 0.01 && Math.abs(p.h - c.height) < 0.01
                }, 2000,
                "@" + w + ": the pill stopped at " + pillSays(tabs)
                + " with chip " + tab + " at "
                + chip.x.toFixed(1) + "," + chip.y.toFixed(1) + " "
                + chip.width.toFixed(1) + "x" + chip.height.toFixed(1))

                // The accent's ink copy covers the chip exactly when the pill
                // does, which is what keeps the label on the fill its ink was
                // chosen for; off the chip it is not drawn at all.
                var ink = findByName(chip, "collectionTabInk")
                verify(ink, "@" + w + ": chip " + tab + " has no accent-ink copy")
                compare(Math.round(ink.width),  Math.round(chip.width),
                        "@" + w + ": the ink does not cover the chip the pill is on")
                compare(Math.round(ink.height), Math.round(chip.height),
                        "@" + w + ": the ink does not cover the chip the pill is on")
                var other = tabs.children[(tab + 2) % 5]
                var otherInk = findByName(other, "collectionTabInk")
                verify(!otherInk.visible || otherInk.width < 1,
                       "@" + w + ": a chip the pill is nowhere near is drawing accent ink")
            }
            if (w === 640)
                verify(wrapped, "@640 the tab row no longer wraps, so the second line is untested")
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

    // ── L13 revised: the row holds still while the window moves ─────────────
    //
    // Cards used to be sized from the row width so the row always ended on a
    // deliberate sliver of the next one. That made every card resize
    // continuously while the window was dragged, which the user found far
    // noisier than a clean cut. Cards are a fixed size now and the row clips;
    // the scrollbar carries the "there is more" cue instead.
    function test_horizontal_section_cards_do_not_resize_with_the_window() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1600, height: 320 })
        var sec = createTemporaryObject(sectionC, holder, { items: makeAlbums(14) })
        verify(sec, "the section was not created")
        settle(holder)

        var sizes = {}
        // One pixel at a time: a size that only twitches between round numbers
        // is exactly the thing being complained about.
        for (var w = 640; w <= 1600; w += 1) {
            holder.width = w
            sizes[sec.cardSize] = true
        }
        settle(holder)
        compare(Object.keys(sizes).length, 1,
                "the card size changed while the window was resized: "
                + Object.keys(sizes).join(", "))
    }

    // A thumbnail in a list is drawn at 36px and the cover URL serves 320, so
    // without a sourceSize every row of a long list holds a full-size decoded
    // image. The budget is the box doubled, for a 2x screen, and it has to
    // name both dimensions: a width-only sourceSize reaches the image provider
    // as 72x0, which QSize::isValid() accepts and QImageReader::setScaledSize()
    // turns into nothing at all.
    function test_a_list_thumbnail_decodes_at_the_size_it_is_drawn() {
        var row = makeRow(900)
        var cover = findByName(row, "trackRowCover")
        verify(cover, "the row has no cover image")
        var box = cover.width
        verify(box > 0, "the cover box collapsed")

        compare(cover.sourceSize.width, cover.sourceSize.height,
                "a square cover was asked for at " + cover.sourceSize.width
                + "x" + cover.sourceSize.height + ", which stretches it")
        verify(cover.sourceSize.width >= box,
               "the cover decodes at " + cover.sourceSize.width
               + " for a box of " + box + ", which is softer than the screen")
        verify(cover.sourceSize.width <= 2 * box,
               "the cover decodes at " + cover.sourceSize.width
               + " for a box of " + box + ": more than a 2x screen can show")
    }

    // A card's hover affordances have to survive being put in a row. Hover
    // delivery stops at the first item that takes it, and the topmost child of
    // a section covers every card in it, so one stray hoverEnabled MouseArea
    // over the whole row silently kills the wash, the play button and the
    // pointing-hand cursor on every card on the home page.
    function test_a_card_inside_a_row_still_hovers() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 320 })
        var sec = createTemporaryObject(sectionC, holder, { items: makeAlbums(4) })
        verify(sec, "the section was not created")
        settle(holder)

        var art = findByName(sec, "cardArt")
        verify(art, "the row drew no card")
        var p = art.mapToItem(holder, art.width / 2, art.height / 2)
        mouseMove(holder, p.x, p.y)
        settle(holder)

        var play = findByName(sec, "cardPlayButton")
        verify(play, "the card has no play button")
        verify(play.visible,
               "a card inside a row never sees the hover, so it shows neither "
               + "its play button nor a pointing hand")

        mouseMove(holder, -20, -20)
        settle(holder)
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
        var pill = createTemporaryObject(pillC, holder, { text: "Zufallswiedergabe (lang)", icon: "shuffle" })
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

    // ── the grid may never clip a card ─────────────────────────────────────

    // Three deliberately awkward covers, inline so the test carries them: 4:1,
    // 1:4 and square. Nothing about the shape of a cover may reach the layout,
    // and the only way to show that is to hand the cards shapes that differ.
    readonly property var coverShapes: [
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAAAQCAIAAAAphe5+AAAAMElEQVR4"
      + "nO3PUQ0AAAiEUDX1xTeEH8yNlwA6SX02dMCVAzQHaA7QHKA5QHOA5gBtAcG/AYhY2ShCAAAAAElFTkSuQmCC",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAABACAIAAACcH2DBAAAAKElEQVR4"
      + "nO3LMREAAAjEMED1y0cDK5fOTSepS3O6AQAAAAAAAAB4BBZUnAHo3pX5/QAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKUlEQVR4"
      + "nO3NMQEAAAjDMED15GMCvlRA00nqs3m9AwAAAAAAAAAAgMMWm14BqD+TOGcAAAAASUVORK5CYII="
    ]

    // A card's cover comes from the image://tidal provider, which the stubs
    // answer with a blank square. Assigning over it is the point: it is the
    // only way to put covers of three different shapes in one row.
    function giveCardsDifferentCovers(container, count) {
        var given = 0
        for (var i = 0; i < count; ++i) {
            var d = container.itemAtIndex(i)
            if (!d) continue
            var img = findByName(d, "cardImage")
            if (!img) continue
            img.source = coverShapes[i % coverShapes.length]
            given++
        }
        return given
    }

    // The absolute one. Two sweeps, because they catch different things.
    //
    // The first runs the page's own grid arithmetic at every single pixel from
    // 640 to 3840. It is cheap enough to be exhaustive, and exhaustive is the
    // point: the widths that used to break were never the round ones.
    //
    // The second resizes one live page across the same range and measures the
    // cards that come out of it, which is the only way to catch the GridView or
    // a delegate disagreeing with the arithmetic above it.
    function test_collection_grid_never_clips_a_card() {
        var page = makePane(collectionC, 1000)
        fillCollection(page, 1)
        settle(page)

        for (var w = 640; w <= 3840; ++w) {
            var cols  = page.gridColumns(w)
            var cell  = page.gridCell(w)
            var left  = page.gridLeft(w)
            var right = page.gridRight(w)

            verify(cols >= 1, "@" + w + ": " + cols + " columns")
            verify(cell >= page.gridMinCell,
                   "@" + w + ": cells of " + cell + ", under the " + page.gridMinCell
                   + " a cover plus two lines needs")
            verify(left >= page.gridEdge && right >= page.gridEdge,
                   "@" + w + ": insets of " + left + " and " + right + " eat into the pane inset")
            // The guarantee: the columns and the two insets are exactly the
            // pane, so the last column cannot be sitting past the right edge.
            compare(left + cols * cell + right, w,
                    "@" + w + ": " + cols + " x " + cell + " between insets of " + left
                    + " and " + right + " does not add up to " + w)
            verify(Math.abs(left - right) <= 1,
                   "@" + w + ": the two outer gutters are " + left + " and " + right)
            verify(page.gridCardSize(cell) <= cell - 1,
                   "@" + w + ": a " + page.gridCardSize(cell) + "px card in a " + cell + "px cell")
        }

        // Now the real thing, resized rather than rebuilt: a card built at one
        // width and then shown at another is exactly how the broken ones got
        // made. 48 albums so even a 3840px pane has a full row to measure.
        var holder = createTemporaryObject(holderC, testCase, { width: 640, height: paneHeight })
        var live = createTemporaryObject(collectionC, holder, {})
        verify(live, "the page was not created")
        live.activeTab = 1
        live.filteredAlbums = makeAlbums(48)
        settle(holder)

        var grid = findByName(live, "collectionAlbumsGrid")
        verify(grid, "the albums grid was not found")

        for (w = 640; w <= 3840; w += 7) {
            holder.width = w
            settle(holder)

            var leftGutter = Number.MAX_VALUE
            var rightEdge  = -Number.MAX_VALUE
            var seen = 0
            for (var k = 0; k < 48; ++k) {
                var d = grid.itemAtIndex(k)
                if (!d) continue
                var art = findByName(d, "cardArt")
                if (!art) continue
                var x = art.mapToItem(grid, 0, 0).x
                verify(x >= -0.5,
                       "@" + w + ": card " + k + " starts at " + x.toFixed(1))
                verify(x + art.width <= grid.width + 0.5,
                       "@" + w + ": card " + k + " ends at " + (x + art.width).toFixed(1)
                       + " in a viewport " + grid.width.toFixed(1) + " wide")
                if (x < leftGutter) leftGutter = x
                if (x + art.width > rightEdge) rightEdge = x + art.width
                seen++
            }
            verify(seen >= grid.columns, "@" + w + ": only " + seen + " cards were realized")
            verify(Math.abs(leftGutter - (grid.width - rightEdge)) <= 1,
                   "@" + w + ": the gutters are " + leftGutter.toFixed(1) + " on the left and "
                   + (grid.width - rightEdge).toFixed(1) + " on the right")
        }
    }

    // ── one row, one art box, one baseline ─────────────────────────────────

    // The art box used to be a ColumnLayout child carrying a plain height, and
    // a layout only reads that the first time it measures a child: a card built
    // while its grid was still settling kept the stale box and drew its title
    // across its cover. Covers of three different shapes go in to prove the
    // other half of it, that nothing about the picture can move the layout.
    function test_grid_cards_share_a_box_and_a_baseline() {
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var page = makePane(collectionC, w)
            fillCollection(page, 1)
            settle(page)

            var grid = findByName(page, "collectionAlbumsGrid")
            verify(grid, "the albums grid was not found")
            verify(giveCardsDifferentCovers(grid, 12) > 1,
                   "@" + w + ": the covers were not replaced")
            settle(page)

            var cols = grid.columns
            var ref = null
            for (var k = 0; k < cols; ++k) {
                var d = grid.itemAtIndex(k)
                verify(d, "@" + w + ": card " + k + " of the first row is missing")
                var art   = findByName(d, "cardArt")
                var title = findByName(d, "cardTitle")
                verify(art && title, "@" + w + ": card " + k + " has no art box or title")

                var here = {
                    aw: art.width, ah: art.height,
                    ay: art.mapToItem(grid, 0, 0).y,
                    ty: title.mapToItem(grid, 0, 0).y
                }
                verify(here.aw === here.ah,
                       "@" + w + ": card " + k + "'s art is " + here.aw + "x" + here.ah
                       + " rather than square")
                if (!ref) { ref = here; continue }
                compare(here.aw, ref.aw, "@" + w + ": card " + k + "'s art is a different width")
                compare(here.ah, ref.ah, "@" + w + ": card " + k + "'s art is a different height")
                compare(here.ay, ref.ay, "@" + w + ": card " + k + "'s art sits at a different height")
                compare(here.ty, ref.ty, "@" + w + ": card " + k + "'s title is off the baseline")
            }
        }
    }

    // The same for a horizontal row, which is where the QA screenshot came
    // from: four cards of one album, the third of them smaller and lower.
    function test_section_cards_share_a_box_and_a_baseline() {
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
            verify(giveCardsDifferentCovers(list, 14) > 1,
                   "@" + w + ": the covers were not replaced")
            settle(page)

            var ref = null
            for (var k = 0; k < 6; ++k) {
                var d = list.itemAtIndex(k)
                if (!d) continue
                var art   = findByName(d, "cardArt")
                var title = findByName(d, "cardTitle")
                verify(art && title, "@" + w + ": card " + k + " has no art box or title")
                var here = {
                    aw: art.width, ah: art.height,
                    ay: art.mapToItem(list, 0, 0).y,
                    ty: title.mapToItem(list, 0, 0).y
                }
                verify(here.aw === here.ah,
                       "@" + w + ": card " + k + "'s art is " + here.aw + "x" + here.ah)
                if (!ref) { ref = here; continue }
                compare(here.aw, ref.aw, "@" + w + ": card " + k + "'s art is a different width")
                compare(here.ah, ref.ah, "@" + w + ": card " + k + "'s art is a different height")
                compare(here.ay, ref.ay, "@" + w + ": card " + k + "'s art sits at a different height")
                compare(here.ty, ref.ty, "@" + w + ": card " + k + "'s title is off the baseline")
            }
            verify(ref, "@" + w + ": no card in the row was realized")
        }
    }

    // ── the artist card is a disc, and the hover has to know it ─────────────

    // Everything the hover draws has to stay on the circle: the wash, the play
    // button and the focus ring. The button used to be anchored to the bottom
    // right of the bounding box, which on a disc is a corner that is not there.
    function test_artist_card_hover_stays_in_the_circle() {
        var holder = createTemporaryObject(holderC, testCase, { width: 400, height: 320 })
        var card = createTemporaryObject(mediaCardC, holder, {
            x: 40, y: 40, cardSize: 160, mediaType: "artist",
            title: "Ein langer Interpretenname", subtitle: "Artist"
        })
        verify(card, "the card was not created")
        settle(holder)

        var art = findByName(card, "cardArt")
        verify(art, "the art box was not found")
        compare(art.width, art.height, "an artist's art box is not square")
        compare(art.radius, art.width / 2, "an artist's art box is not a disc")

        var cx = art.width / 2
        var cy = art.height / 2
        var r  = art.width / 2

        var scrim = findByName(card, "cardScrim")
        verify(scrim, "the wash was not found")
        compare(scrim.radius, art.radius, "the wash is not the same shape as the art")
        compare(scrim.width, art.width, "the wash is not the size of the art")

        var ring = findByName(card, "cardFocusRing")
        verify(ring, "the focus ring was not found")
        compare(ring.radius, art.radius, "the focus ring is not the same shape as the art")

        mouseMove(holder, 40 + cx, 40 + cy)
        settle(holder)

        var play = findByName(card, "cardPlayButton")
        verify(play, "the play button was not found")
        verify(play.visible, "the play button did not appear on hover")

        // Dead centre of the art, and far enough inside it that the whole
        // button is on the disc rather than straddling its edge.
        var p = play.mapToItem(art, play.width / 2, play.height / 2)
        var off = Math.sqrt(Math.pow(p.x - cx, 2) + Math.pow(p.y - cy, 2))
        var reach = Math.max(play.width, play.height) / 2
        verify(off + reach <= r + 0.5,
               "the play button reaches " + (off + reach).toFixed(1)
               + " from the middle of a circle of " + r.toFixed(1))

        mouseMove(holder, -20, -20)
        settle(holder)
    }

    // A square card keeps the corner the hover was designed around.
    function test_album_card_keeps_its_corner_play_button() {
        var holder = createTemporaryObject(holderC, testCase, { width: 400, height: 320 })
        var card = createTemporaryObject(mediaCardC, holder, {
            x: 40, y: 40, cardSize: 160, mediaType: "album",
            title: "Ein langer Albumtitel", subtitle: "Interpret"
        })
        verify(card, "the card was not created")
        settle(holder)

        var art = findByName(card, "cardArt")
        verify(art.radius < art.width / 2, "an album's art box was drawn as a disc")

        mouseMove(holder, 40 + art.width / 2, 40 + art.height / 2)
        settle(holder)

        var play = findByName(card, "cardPlayButton")
        verify(play.visible, "the play button did not appear on hover")
        var p = play.mapToItem(art, 0, 0)
        verify(p.x + play.width > art.width * 0.6 && p.y + play.height > art.height * 0.6,
               "the play button left the bottom right corner (" + p.x.toFixed(1)
               + "," + p.y.toFixed(1) + ")")

        mouseMove(holder, -20, -20)
        settle(holder)
    }

    // The collection grid's dead space, measured rather than reasoned about.
    //
    // A ~200px empty gutter was reported at "some very specific window
    // widths". Two explanations have now died against numbers: an exact-fit
    // rounding theory, and a sweep of the grid's own arithmetic
    // (gridSpace/gridColumns/gridCell/gridLeft/gridRight) which showed the
    // total margin cannot exceed 2*gridEdge plus a rounding remainder smaller
    // than the column count - about 60px - at any pane width from 320 to 2400.
    //
    // So this stops arguing and measures the live GridView instead, which is
    // the only thing that can see the difference between what the arithmetic
    // says and what the item actually lays out. It asserts the bound the
    // arithmetic promises; if the gutter is real, this is what will print the
    // width it happens at and the four numbers that explain it.
    //
    // The grid is filled with enough albums to span several rows at every
    // width tested, so empty space on the right cannot simply be "ran out of
    // items" - that would be a short collection, not a layout defect.
    function test_the_collection_grid_leaves_no_dead_gutter_data() {
        var rows = []
        for (var w = 640; w <= 2000; w += 8)
            rows.push({ tag: "w=" + w, w: w })
        return rows
    }

    function test_the_collection_grid_leaves_no_dead_gutter(row) {
        var host = createTemporaryObject(holderC, testCase,
                                         { width: row.w, height: 900 })
        var page = createTemporaryObject(collectionC, host)
        page.activeTab = 1
        page.filteredAlbums = makeAlbums(60)
        settle(page)

        var grid = findByName(page, "collectionAlbumsGrid")
        verify(grid, row.tag + ": the albums grid was not found")
        if (grid.width <= 0) return          // tab not realised at this size

        var dead = grid.leftMargin + grid.rightMargin
        // What the arithmetic promises: two edge insets, plus a remainder that
        // is split between them and is always smaller than the column count.
        var bound = 2 * page.gridEdge + page.gridColumns(grid.width) + 1
        verify(dead <= bound,
               row.tag + ": " + dead.toFixed(0) + "px of dead margin, bound "
               + bound.toFixed(0) + "  [grid.width=" + grid.width.toFixed(0)
               + " left=" + grid.leftMargin.toFixed(0)
               + " right=" + grid.rightMargin.toFixed(0)
               + " cell=" + grid.cellWidth.toFixed(0)
               + " cols=" + page.gridColumns(grid.width) + "]")

        // ...and the cells must actually fill the space the margins leave,
        // which is the half the margin arithmetic alone cannot see: a grid
        // that lays out fewer columns than were budgeted for leaves the
        // difference empty on the right without either margin growing.
        var cols = page.gridColumns(grid.width)
        var used = cols * grid.cellWidth
        var avail = grid.width - grid.leftMargin - grid.rightMargin
        compare(used, avail,
                row.tag + ": the grid budgeted " + cols + " columns of "
                + grid.cellWidth.toFixed(0) + " = " + used.toFixed(0)
                + " but has " + avail.toFixed(0) + "px between its margins");
    }
}
