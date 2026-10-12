// ArtistPage's three release rows: which release lands in which, and that a
// record with several products is one card. The stub bridge answers through
// the app's own rule (api/RecordVersions.h), whose cases are in
// tests/tst_record_versions.cpp. Every id, title and cover is invented.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ArtistDiscography"
    when: windowShown
    width: 1000
    height: 800
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible, so a shown section would read as hidden.
    visible: true

    readonly property int artistId: 900000031

    Component { id: holderC; Item { } }
    Component { id: artistC; ArtistPage { anchors.fill: parent } }

    function makePage(width) {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = width || 960
        holder.height = 700
        var page = createTemporaryObject(artistC, holder, {})
        verify(page, "the page was not created")
        return page
    }

    // Asks the item's window for a frame and waits for it. A window with
    // nothing new to draw swaps no frame, and waitForRendering() alone would
    // run out its timeout and return false.
    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function settle(item) {
        frame(item)
        wait(1)
    }

    function rel(id, title, type, numTracks, cover) {
        return { id: id, title: title, type: type, numTracks: numTracks,
                 coverUrl: cover, year: "2021", artists: "Eine Band",
                 featured: false }
    }

    // A record by somebody else that this artist guests on. Only the flag
    // differs: the shape of a release does not say whose it is.
    function guest(id, title, type, numTracks, cover) {
        var r = rel(id, title, type, numTracks, cover)
        r.featured = true
        return r
    }

    // Opens the page on an artist whose releases are `albums`, and hands back
    // the three rows.
    function openWith(albums, width) {
        bridge.setArtistForTest({ id: testCase.artistId, name: "Eine Band" }, [], albums)
        var page = makePage(width)
        page.artistId = testCase.artistId
        settle(page)
        var out = {
            page:      page,
            albums:    findChild(page, "artistAlbumsSection"),
            singles:   findChild(page, "artistSinglesSection"),
            appearsOn: findChild(page, "artistAppearsOnSection")
        }
        verify(out.albums,    "the page has no Albums section at all")
        verify(out.singles,   "the page has no Singles & EPs section at all")
        verify(out.appearsOn, "the page has no Appears on section at all")
        return out
    }

    // One product of a record, with the keys TidalBridge::albumToMap writes
    // and a cover of its own.
    function product(id, title, type, numTracks, explicit_, modes, tags) {
        var r = rel(id, title, type, numTracks, "cover-" + id)
        r.explicit_  = explicit_
        r.audioModes = modes
        r.mediaTags  = tags
        r.duration   = 220 * numTracks
        return r
    }

    // Explicit and clean, each as 16-bit stereo, hi-res stereo and Dolby Atmos
    // only. The explicit hi-res stereo one is firstId + 4.
    function sixProducts(firstId, title, type, numTracks) {
        var atmos = ["DOLBY_ATMOS"], stereo = ["STEREO"]
        var lossless = ["LOSSLESS"], hiRes = ["LOSSLESS", "HIRES_LOSSLESS"]
        return [
            product(firstId,     title, type, numTracks, true,  atmos,  atmos),
            product(firstId + 1, title, type, numTracks, false, stereo, lossless),
            product(firstId + 2, title, type, numTracks, false, stereo, hiRes),
            product(firstId + 3, title, type, numTracks, true,  stereo, lossless),
            product(firstId + 4, title, type, numTracks, true,  stereo, hiRes),
            product(firstId + 5, title, type, numTracks, false, atmos,  atmos)
        ]
    }

    // What the cards of a row read, left to right.
    function cardTitles(section) {
        var list = findChild(section, "sectionList")
        verify(list, "the row has no list of cards")
        var out = []
        for (var i = 0; i < list.count; ++i) {
            var card = list.itemAtIndex(i)
            verify(card, "card " + i + " of the row was not drawn")
            out.push(findChild(card, "cardTitle").text)
        }
        return out
    }

    function idsOf(section) {
        var out = []
        for (var i = 0; i < section.items.length; ++i) out.push(section.items[i].id)
        return out
    }

    function cleanup() {
        bridge.resetHeadersForTest()
    }

    // ── the split ────────────────────────────────────────────────────────────

    function test_singles_and_eps_fill_their_own_row() {
        var s = openWith([
            rel(900010001, "Ein Album",   "ALBUM",  11, "11111111-0000-0000-0000-000000000000"),
            rel(900010002, "Eine Single", "SINGLE",  1, "22222222-0000-0000-0000-000000000000"),
            rel(900010003, "Eine EP",     "EP",      4, "33333333-0000-0000-0000-000000000000")
        ])

        compare(s.singles.visible, true,
                "the Singles & EPs row hid itself on an artist that has two")
        compare(idsOf(s.singles), [900010002, 900010003],
                "the Singles & EPs row holds the wrong releases")
        compare(idsOf(s.albums), [900010001],
                "the Albums row holds the wrong releases")

        // Visible is not enough: a row laid out at no size still answers true.
        verify(s.singles.width > 200 && s.singles.height > 50,
               "the Singles & EPs row was laid out at no size: "
               + s.singles.width + "x" + s.singles.height)
    }

    // The track count is only the fallback: a four-track EP filed as an EP
    // belongs in the singles row, where numTracks <= 3 would not put it.
    function test_a_four_track_ep_is_not_filed_as_an_album() {
        var s = openWith([
            rel(900011001, "Ein Album", "ALBUM", 11, "11111111-0000-0000-0000-000000000000"),
            rel(900011002, "Eine EP",   "EP",     4, "44444444-0000-0000-0000-000000000000")
        ])

        compare(idsOf(s.singles), [900011002],
                "a four-track EP was filed by its track count instead of its type")
        compare(idsOf(s.albums), [900011001])
    }

    function test_without_a_type_the_track_count_decides() {
        var s = openWith([
            rel(900012001, "Lang",  "", 9, "11111111-0000-0000-0000-000000000000"),
            rel(900012002, "Kurz",  "", 2, "22222222-0000-0000-0000-000000000000")
        ])

        compare(idsOf(s.albums),  [900012001])
        compare(idsOf(s.singles), [900012002])
    }

    // The heading names the albums only when there is a second row under it.
    // With no singles, the one row is the whole discography.
    function test_the_albums_heading_names_the_second_row() {
        var withSingles = openWith([
            rel(900013001, "Ein Album",   "ALBUM",  11, "11111111-0000-0000-0000-000000000000"),
            rel(900013002, "Eine Single", "SINGLE",  1, "22222222-0000-0000-0000-000000000000")
        ])
        var titleWithSingles = withSingles.albums.title

        var albumsOnly = openWith([
            rel(900013003, "Ein Album", "ALBUM", 11, "33333333-0000-0000-0000-000000000000")
        ])
        compare(albumsOnly.singles.visible, false,
                "the Singles & EPs row showed itself on an artist with none")
        verify(titleWithSingles !== albumsOnly.albums.title,
               "the albums heading reads the same ('" + titleWithSingles
               + "') whether or not there is a singles row under it")
    }

    // Guest appearances are other people's records, so they do not change the
    // heading over the artist's own releases.
    function test_the_appears_on_row_does_not_rename_the_albums_heading() {
        var albumsOnly = openWith([
            rel(900018001, "Ein Album", "ALBUM", 11, "11111111-0000-0000-0000-000000000000")
        ])
        var plainTitle = albumsOnly.albums.title

        var withGuests = openWith([
            rel(900018002, "Ein Album", "ALBUM", 11, "22222222-0000-0000-0000-000000000000"),
            guest(900018003, "Fremdes Album", "ALBUM", 12, "33333333-0000-0000-0000-000000000000")
        ])
        compare(withGuests.appearsOn.visible, true,
                "the Appears on row hid itself on an artist with a guest appearance")
        compare(withGuests.singles.visible, false)
        compare(withGuests.albums.title, plainTitle,
                "an Appears on row changed the heading over the artist's own albums, from '"
                + plainTitle + "' to '" + withGuests.albums.title + "'")
    }

    // The artist's own compilation is theirs and is long-form. With no track
    // count the fallback would read it as a single.
    function test_the_artists_own_compilation_is_an_album() {
        var s = openWith([
            rel(900024001, "Das Beste", "COMPILATION", 0,
                "cccccccc-0000-0000-0000-000000000000")
        ])

        compare(idsOf(s.albums), [900024001],
                "the artist's own compilation was filed under Singles & EPs")
        compare(s.singles.visible, false)
        compare(s.appearsOn.visible, false,
                "a release that is the artist's own landed in Appears on")
    }

    // ── the third row ────────────────────────────────────────────────────────

    // One guest appearance of each shape. None of them belongs in either row
    // of the artist's own releases.
    function test_guest_appearances_get_their_own_row() {
        var s = openWith([
            rel(900019001, "Ein Album",     "ALBUM",  11, "11111111-0000-0000-0000-000000000000"),
            rel(900019002, "Eine Single",   "SINGLE",  1, "22222222-0000-0000-0000-000000000000"),
            guest(900019003, "Fremdes Album", "ALBUM", 12, "33333333-0000-0000-0000-000000000000"),
            guest(900019004, "Fremde EP",     "EP",     5, "44444444-0000-0000-0000-000000000000"),
            guest(900019005, "Sammlung",      "COMPILATION", 20, "55555555-0000-0000-0000-000000000000")
        ])

        compare(idsOf(s.albums), [900019001],
                "a record the artist only guests on was filed under Albums")
        compare(idsOf(s.singles), [900019002],
                "a record the artist only guests on was filed under Singles & EPs")
        compare(idsOf(s.appearsOn), [900019003, 900019004, 900019005],
                "the Appears on row holds the wrong releases")

        compare(s.appearsOn.visible, true,
                "the Appears on row hid itself on an artist with three guest appearances")
        verify(s.appearsOn.title.length > 0
               && s.appearsOn.title !== s.albums.title
               && s.appearsOn.title !== s.singles.title,
               "the Appears on row has no heading of its own: '" + s.appearsOn.title + "'")
    }

    // The artist's own work comes first on the page.
    function test_the_appears_on_row_comes_last() {
        var s = openWith([
            rel(900020001, "Ein Album",   "ALBUM",  11, "11111111-0000-0000-0000-000000000000"),
            rel(900020002, "Eine Single", "SINGLE",  1, "22222222-0000-0000-0000-000000000000"),
            guest(900020003, "Fremdes Album", "ALBUM", 12, "33333333-0000-0000-0000-000000000000")
        ])

        var albumsY  = s.albums.mapToItem(s.page, 0, 0).y
        var singlesY = s.singles.mapToItem(s.page, 0, 0).y
        var guestsY  = s.appearsOn.mapToItem(s.page, 0, 0).y
        verify(albumsY < singlesY,
               "Singles & EPs is no longer under Albums: " + albumsY + " vs " + singlesY)
        verify(singlesY < guestsY,
               "Appears on is not last; it sits at " + guestsY
               + " with Singles & EPs at " + singlesY)
    }

    // Most artists guest on nothing, and a heading over an empty row is worse
    // than no row.
    function test_the_appears_on_row_hides_with_nothing_in_it() {
        var s = openWith([
            rel(900021001, "Ein Album", "ALBUM", 11, "11111111-0000-0000-0000-000000000000")
        ])
        compare(s.appearsOn.visible, false,
                "the Appears on row showed itself on an artist who guests on nothing")
    }

    // The widths tst_layout_pages.qml audits. At each, the row is laid out as
    // the Singles & EPs row above it is, and ends inside the page.
    function test_the_appears_on_row_is_laid_out_like_the_row_above_it() {
        var widths = [640, 820, 960, 1280]
        for (var i = 0; i < widths.length; ++i) {
            var w = widths[i]
            var releases = []
            for (var n = 0; n < 8; ++n) {
                releases.push(rel(900025100 + n, "Eine ziemlich lange Single Nummer " + n,
                                  "SINGLE", 1, "0000000" + n + "-1111-0000-0000-000000000000"))
                releases.push(guest(900025200 + n, "Ein ziemlich langes fremdes Album " + n,
                                    "ALBUM", 12, "0000000" + n + "-2222-0000-0000-000000000000"))
            }
            var s = openWith(releases, w)
            var at = " at " + w

            compare(s.appearsOn.items.length, 8)
            verify(s.appearsOn.width > 200 && s.appearsOn.height > 50,
                   "the Appears on row was laid out at no size" + at + ": "
                   + s.appearsOn.width + "x" + s.appearsOn.height)
            compare(s.appearsOn.x, s.singles.x,
                    "the Appears on row does not start where Singles & EPs starts" + at)
            compare(s.appearsOn.width, s.singles.width,
                    "the Appears on row is not as wide as Singles & EPs" + at)
            compare(s.appearsOn.height, s.singles.height,
                    "the Appears on row is not as tall as Singles & EPs" + at)
            compare(s.appearsOn.y, s.singles.y + s.singles.height,
                    "the Appears on row does not sit directly under Singles & EPs" + at)
            var right = s.appearsOn.mapToItem(s.page, s.appearsOn.width, 0).x
            verify(right <= s.page.width,
                   "the Appears on row ends at " + right + " on a page "
                   + s.page.width + " wide")
        }
    }

    // ── one card per record ──────────────────────────────────────────────────

    // Tidal lists the six products of a record under six ids. The page shows
    // the record once, and the card opens the explicit hi-res stereo product.
    function test_the_products_of_one_record_are_one_card() {
        var s = openWith(sixProducts(900015000, "Nachtfahrt", "ALBUM", 12).concat([
            rel(900015100, "Morgenrot", "ALBUM", 9, "cover-900015100")
        ]))

        compare(cardTitles(s.albums), ["Nachtfahrt", "Morgenrot"],
                "the Albums row does not show each record once")
        compare(idsOf(s.albums), [900015004, 900015100],
                "the card of the record does not open its explicit hi-res stereo product")
    }

    function test_the_products_of_one_single_are_one_card() {
        var s = openWith(sixProducts(900016000, "Nachtfahrt", "SINGLE", 1))

        compare(cardTitles(s.singles), ["Nachtfahrt"],
                "the Singles & EPs row does not show the single once")
        compare(idsOf(s.singles), [900016004])
    }

    function test_the_products_of_one_guest_appearance_are_one_card() {
        var products = sixProducts(900023000, "Sammlung", "COMPILATION", 20)
        for (var i = 0; i < products.length; ++i) products[i].featured = true
        var s = openWith(products)

        compare(cardTitles(s.appearsOn), ["Sammlung"],
                "the Appears on row does not show the record once")
        compare(idsOf(s.appearsOn), [900023004])
        compare(s.albums.visible, false,
                "a record by somebody else landed among the artist's own")
    }

    // A lead single often carries its album's title, and so does the record
    // by somebody else it was licensed onto. Each stays in its own row.
    function test_one_title_in_three_rows_is_three_cards() {
        var guests = sixProducts(900014200, "Nachtfahrt", "ALBUM", 12)
        for (var i = 0; i < guests.length; ++i) guests[i].featured = true
        var s = openWith(sixProducts(900014000, "Nachtfahrt", "ALBUM", 12)
                         .concat(sixProducts(900014100, "Nachtfahrt", "SINGLE", 1))
                         .concat(guests))

        compare(cardTitles(s.albums), ["Nachtfahrt"])
        compare(idsOf(s.albums), [900014004],
                "the album was collapsed into its lead single or into a guest appearance")
        compare(cardTitles(s.singles), ["Nachtfahrt"])
        compare(idsOf(s.singles), [900014104],
                "the lead single was collapsed into its album and is unreachable")
        compare(cardTitles(s.appearsOn), ["Nachtfahrt"])
        compare(idsOf(s.appearsOn), [900014204],
                "the guest appearance was collapsed into the artist's own album and is unreachable")
    }

    // Another title or another track count is another record, whatever the
    // artwork says.
    function test_an_edition_with_its_own_title_or_length_keeps_its_card() {
        var art = "88888888-0000-0000-0000-000000000000"
        var s = openWith([
            rel(900017001, "Nachtfahrt",          "ALBUM", 10, art),
            rel(900017002, "Nachtfahrt (Deluxe)", "ALBUM", 14, art),
            rel(900017003, "Nachtfahrt",          "ALBUM", 14, art)
        ])

        compare(cardTitles(s.albums), ["Nachtfahrt", "Nachtfahrt (Deluxe)", "Nachtfahrt"],
                "an edition with its own title or track count lost its card")
        compare(idsOf(s.albums), [900017001, 900017002, 900017003])
    }

    // The page works no row out itself: it files each entry where the bridge
    // says, whatever the type and the track count would suggest.
    function test_the_page_files_by_the_row_the_bridge_names() {
        var page = makePage()
        page.albums = [
            { id: 900026001, title: "Nach oben",  section: "s", type: "ALBUM",  numTracks: 12 },
            { id: 900026002, title: "Nach unten", section: "f", type: "SINGLE", numTracks: 1 },
            { id: 900026003, title: "Zur Seite",  section: "a", type: "SINGLE", numTracks: 1,
              featured: true }
        ]
        settle(page)

        compare(idsOf(findChild(page, "artistSinglesSection")), [900026001])
        compare(idsOf(findChild(page, "artistAppearsOnSection")), [900026002])
        compare(idsOf(findChild(page, "artistAlbumsSection")), [900026003])
    }

    // An entry that names no row is not dropped from the page.
    function test_an_entry_that_names_no_row_stays_with_the_albums() {
        var page = makePage()
        page.albums = [
            { id: 900027001, title: "Ohne Reihe", type: "SINGLE", numTracks: 1 }
        ]
        settle(page)

        compare(idsOf(findChild(page, "artistAlbumsSection")), [900027001],
                "an entry without a row is on no row of the page")
        compare(findChild(page, "artistSinglesSection").visible, false)
    }
}

