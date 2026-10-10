// HomePage's rows: the three favourite rows follow the bridge's favourite
// signals, and every gap between two visible rows is the same. The signals
// are coalesced through a timer, so a test waits for a row after a signal.
// The rows carry no objectName: a row is found by the properties only a
// HorizontalSection has, and its heading is the first text inside it.

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "HomeRows"
    when: windowShown
    width: 1100
    height: 1500
    // TestCase declares visible: false, which would make every row below report
    // visible == false and leave nothing to measure.
    visible: true

    // The one place the gap is written down. Every other assertion compares a
    // gap against the first gap on the page.
    readonly property int rowGap: 32

    // Tall enough that the whole page fits without scrolling: a row out of
    // the viewport has no cards created, and two cases below read a card.
    readonly property int paneWidth: 1000
    readonly property int paneHeight: 1400

    Component { id: holderC; Item { } }
    Component { id: homeC;   HomePage { anchors.fill: parent } }

    // ── data ────────────────────────────────────────────────────────────────

    function makeAlbums(n, firstId) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: firstId + i, title: "Ein Albumtitel Nummer " + (i + 1),
                       artists: "Erster Interpret", coverUrl: "", type: "ALBUM",
                       numTracks: 12, year: "2019" })
        return out
    }

    function makeArtists(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 300 + i, name: "Ein Interpretenname " + (i + 1), coverUrl: "" })
        return out
    }

    function makePlaylists(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 400 + i, uuid: "uuid-" + i,
                       title: "Eine Wiedergabeliste " + (i + 1),
                       coverUrl: "", numTracks: 24, duration: 5400, type: "USER" })
        return out
    }

    function makeMixes(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: "mix-" + i, title: "Mein Mix Nummer " + (i + 1),
                       subtitle: "Mit vielen Interpreten", coverUrl: "" })
        return out
    }

    // ── harness ─────────────────────────────────────────────────────────────

    // One stub bridge serves the whole file, so each case starts from an empty
    // favourites cache. The setters emit, but no page exists yet to hear it.
    function init() {
        bridge.setFavoriteAlbumsForTest([])
        bridge.setFavoriteArtistsForTest([])
        bridge.setUserPlaylistsForTest([])
    }

    // Layouts resize in the polish phase, so give the window a frame (plus one
    // event-loop turn for the bindings the stubs resolve synchronously).
    function settle(item) {
        wait(1)
        waitForRendering(item, 2000)
    }

    function makeHome(props) {
        var holder = createTemporaryObject(holderC, testCase, { width: paneWidth, height: paneHeight })
        verify(holder, "the holder was not created")
        var page = createTemporaryObject(homeC, holder, {})
        verify(page, "HomePage was not created")
        // Component.onCompleted has already run loadContent(), and the stub
        // bridge answers every fetch synchronously with an empty list, so
        // nothing assigned here can be overwritten by a late callback.
        for (var k in props)
            page[k] = props[k]
        settle(holder)
        return page
    }

    // A HorizontalSection, which is the only thing on the page carrying all
    // three of these.
    function isRow(item) {
        return item.mediaType !== undefined && item.items !== undefined
               && item.cardSize !== undefined
    }

    // Depth first, so the rows come back in declaration order, which on this
    // page is also top to bottom.
    function collectRows(item, out, visibleOnly) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || c.visible === undefined) continue
            if (visibleOnly && !c.visible) continue
            if (isRow(c)) { out.push(c); continue }
            collectRows(c, out, visibleOnly)
        }
        return out
    }

    function visibleRows(page) { return collectRows(page, [], true) }
    function allRows(page)     { return collectRows(page, [], false) }

    function rowFor(rows, mediaType) {
        for (var i = 0; i < rows.length; ++i)
            if (rows[i].mediaType === mediaType) return rows[i]
        return null
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

    // The row's heading: the first visible text in it. The cards' own titles
    // come later in the tree than the header, so depth-first order picks the
    // heading and not a card.
    function headingOf(item) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || !c.visible) continue
            if (c.text !== undefined && c.font !== undefined && ("" + c.text).length > 0)
                return c
            var hit = headingOf(c)
            if (hit) return hit
        }
        return null
    }

    // The distance from the bottom of each visible row to the top of the next
    // row's heading, which is what a user reads as the gap between two rows.
    function rowGaps(page) {
        var rows = visibleRows(page)
        var gaps = []
        for (var i = 1; i < rows.length; ++i) {
            var heading = headingOf(rows[i])
            verify(heading, "the \"" + rows[i].title + "\" row has no heading to measure to")
            compare(heading.text, rows[i].title,
                    "the text measured as the \"" + rows[i].title + "\" heading is something else")
            var bottom = rows[i - 1].mapToItem(page, 0, rows[i - 1].height).y
            gaps.push(heading.mapToItem(page, 0, 0).y - bottom)
        }
        return gaps
    }

    function gapReport(page) {
        var rows = visibleRows(page)
        var gaps = rowGaps(page)
        var parts = []
        for (var i = 0; i < gaps.length; ++i)
            parts.push("\"" + rows[i].title + "\" → \"" + rows[i + 1].title + "\": "
                       + gaps[i].toFixed(1))
        return parts.join(", ")
    }

    function filledPage() {
        return makeHome({ mixes: makeMixes(5), recentAlbums: makeAlbums(6, 200),
                          playlists: makePlaylists(5), artists: makeArtists(5) })
    }

    // ── the double gap ──────────────────────────────────────────────────────

    function test_every_gap_between_rows_is_the_same() {
        var page = filledPage()

        var rows = visibleRows(page)
        compare(rows.length, 4, "the page should show four rows, not " + rows.length)

        var gaps = rowGaps(page)
        compare(gaps.length, 3, "three gaps between four rows")

        var first = gaps[0]
        for (var i = 1; i < gaps.length; ++i)
            verify(Math.abs(gaps[i] - first) <= 0.5,
                   "the gaps between the rows are not all the same: " + gapReport(page))
        verify(Math.abs(first - rowGap) <= 0.5,
               "the gaps are " + first.toFixed(1) + " where every gap on this page is "
               + rowGap + ": " + gapReport(page))
    }

    // An empty row is hidden, and the spacer above it has to hide with it, or
    // the two spacers around the missing row stack into a double gap.
    function test_an_empty_row_leaves_exactly_one_gap() {
        var page = makeHome({ mixes: makeMixes(5), recentAlbums: makeAlbums(6, 200),
                              playlists: [], artists: makeArtists(5) })

        // The row is hidden, and still on the page.
        var playlistRow = rowFor(allRows(page), "playlist")
        verify(playlistRow, "the Your Playlists row is not on the page at all")
        verify(!playlistRow.visible, "the Your Playlists row shows itself with no playlists in it")

        var rows = visibleRows(page)
        compare(rows.length, 3, "three rows should be left, not " + rows.length)

        var gaps = rowGaps(page)
        compare(gaps.length, 2, "two gaps between three rows")
        var first = gaps[0]
        verify(Math.abs(gaps[1] - first) <= 0.5,
               "the hidden row left its gap behind: " + gapReport(page))
        verify(Math.abs(first - rowGap) <= 0.5,
               "the gaps are " + first.toFixed(1) + " rather than " + rowGap
               + ": " + gapReport(page))
    }

    // ── the row that only updated on a restart ──────────────────────────────

    function test_saved_albums_row_follows_a_save() {
        var page = makeHome({ mixes: makeMixes(5) })
        compare(page.recentAlbums.length, 0,
                "the row already had albums in it, so nothing here can show a refresh")

        var albums = makeAlbums(3, 200)
        bridge.setFavoriteAlbumsForTest(albums)

        // The favourite signals are coalesced through a timer, so only a wait
        // can see the refresh.
        tryVerify(function() { return page.recentAlbums.length === 3 }, 2000,
                  "the Saved Albums row never picked up the saved albums")
        settle(page)

        var row = rowFor(visibleRows(page), "album")
        verify(row, "the Saved Albums row is not on the page")
        compare(row.items.length, 3, "the row was handed " + row.items.length + " albums")

        // Down to the card: a page property that no row reads would also pass
        // above.
        var list = findByName(row, "sectionList")
        verify(list, "the row's list was not found")
        var card = list.itemAtIndex(0)
        verify(card, "the first album's card was not created")
        var title = findByName(card, "cardTitle")
        verify(title, "the card has no title")
        compare(title.text, albums[0].title, "the card shows something else")
    }

    function test_saved_albums_row_follows_a_removal() {
        var page = makeHome({ mixes: makeMixes(5) })

        var albums = makeAlbums(3, 200)
        bridge.setFavoriteAlbumsForTest(albums)
        tryVerify(function() { return page.recentAlbums.length === 3 }, 2000,
                  "the Saved Albums row never picked up the saved albums")

        var dropped = albums[1]
        bridge.setFavoriteAlbumsForTest([albums[0], albums[2]])
        tryVerify(function() { return page.recentAlbums.length === 2 }, 2000,
                  "the album that left the favourites is still in the row")
        settle(page)

        var row = rowFor(visibleRows(page), "album")
        verify(row, "the Saved Albums row is not on the page")
        for (var i = 0; i < row.items.length; ++i)
            verify(row.items[i].id !== dropped.id,
                   "the unsaved album \"" + dropped.title + "\" is still in the row")
    }

    // Playlists and artists refresh off their own signals, and the playlist
    // row reads the bridge's playlist cache.
    function test_playlist_and_artist_rows_follow_the_bridge() {
        var page = makeHome({ mixes: makeMixes(5) })
        compare(page.playlists.length, 0, "the playlist row started out filled")
        compare(page.artists.length, 0, "the artist row started out filled")

        bridge.setUserPlaylistsForTest(makePlaylists(4))
        tryVerify(function() { return page.playlists.length === 4 }, 2000,
                  "the Your Playlists row never picked up the playlists")

        bridge.setFavoriteArtistsForTest(makeArtists(2))
        tryVerify(function() { return page.artists.length === 2 }, 2000,
                  "the Favorite Artists row never picked up the artists")

        // The album row as well, so all four rows are back for the gap check
        // below. A refresh rebuilds all three favourite rows at once.
        bridge.setFavoriteAlbumsForTest(makeAlbums(3, 200))
        tryVerify(function() { return page.recentAlbums.length === 3 }, 2000,
                  "the Saved Albums row never picked up the saved albums")
        settle(page)

        var rows = visibleRows(page)
        compare(rowFor(rows, "playlist").items.length, 4,
                "the playlist row does not show what the bridge holds")
        compare(rowFor(rows, "artist").items.length, 2,
                "the artist row does not show what the bridge holds")

        // Every row here was hidden while the page was built. The refresh has to
        // bring each one back with exactly one spacer above it.
        var gaps = rowGaps(page)
        compare(gaps.length, 3, "all four rows should be showing again")
        for (var i = 0; i < gaps.length; ++i)
            verify(Math.abs(gaps[i] - rowGap) <= 0.5,
                   "a refreshed row left the gaps wrong: " + gapReport(page))
    }
}
