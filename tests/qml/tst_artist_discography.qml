// ArtistPage's three release rows: which release lands in which, and what the
// edition collapse may drop. Albums and Singles & EPs split by type, with the
// track count as a fallback. `featured` outranks both and sends a release to
// Appears on. dedupeEditions() keys on the row as well as on artwork and title.
// The request side, and where `featured` is set, is in
// tests/tst_artist_discography.cpp. Every id, title and cover is invented.

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

    // ── the edition collapse ─────────────────────────────────────────────────

    // A lead single often carries its album's artwork and title, so a collapse
    // on artwork and title alone would drop whichever came second.
    function test_a_single_sharing_its_album_artwork_and_title_is_kept() {
        var sharedArt = "99999999-0000-0000-0000-000000000000"
        var s = openWith([
            rel(900014001, "Nachtfahrt", "ALBUM",  10, sharedArt),
            rel(900014002, "Nachtfahrt", "SINGLE",  1, sharedArt)
        ])

        compare(idsOf(s.albums), [900014001],
                "the album was collapsed into its own lead single")
        compare(idsOf(s.singles), [900014002],
                "the lead single was collapsed into its album and is unreachable")
    }

    // What the collapse is for: Tidal lists every edition of a release under
    // its own id, and they are the same record.
    function test_editions_of_one_album_still_collapse() {
        var art = "88888888-0000-0000-0000-000000000000"
        var s = openWith([
            rel(900015001, "Nachtfahrt",                    "ALBUM", 10, art),
            rel(900015002, "Nachtfahrt (Deluxe Edition)",    "ALBUM", 14, art),
            rel(900015003, "Nachtfahrt (Deluxe) [Explicit]", "ALBUM", 14, art)
        ])

        compare(idsOf(s.albums), [900015001],
                "the editions of one album stopped collapsing into one row")
    }

    function test_editions_of_one_single_still_collapse() {
        var art = "77777777-0000-0000-0000-000000000000"
        var s = openWith([
            rel(900016001, "Nachtfahrt",            "SINGLE", 1, art),
            rel(900016002, "Nachtfahrt (Radio Edit)", "SINGLE", 1, art)
        ])

        compare(idsOf(s.singles), [900016001],
                "the editions of one single stopped collapsing into one row")
    }

    // A compilation often reuses the sleeve and title of the single licensed
    // onto it. Both stay reachable, each in its own row.
    function test_a_guest_appearance_sharing_artwork_and_title_is_kept() {
        var sharedArt = "aaaaaaaa-0000-0000-0000-000000000000"
        var s = openWith([
            rel(900022001, "Nachtfahrt", "ALBUM", 10, sharedArt),
            guest(900022002, "Nachtfahrt", "ALBUM", 10, sharedArt)
        ])

        compare(idsOf(s.albums), [900022001],
                "the artist's own album was collapsed into a record they only guest on")
        compare(idsOf(s.appearsOn), [900022002],
                "the guest appearance was collapsed into the artist's own album and is unreachable")
    }

    function test_editions_of_one_guest_appearance_still_collapse() {
        var art = "bbbbbbbb-0000-0000-0000-000000000000"
        var s = openWith([
            guest(900023001, "Sammlung",            "COMPILATION", 20, art),
            guest(900023002, "Sammlung (Explicit)", "COMPILATION", 20, art)
        ])

        compare(idsOf(s.appearsOn), [900023001],
                "the editions of one guest appearance stopped collapsing into one row")
    }

    // Different artwork is a different release, whatever the title says.
    function test_a_re_recording_with_its_own_artwork_still_shows() {
        var s = openWith([
            rel(900017001, "Nachtfahrt", "ALBUM", 10,
                "11111111-0000-0000-0000-000000000000"),
            rel(900017002, "Nachtfahrt (Neuaufnahme)", "ALBUM", 10,
                "22222222-0000-0000-0000-000000000000")
        ])

        compare(idsOf(s.albums), [900017001, 900017002],
                "a re-recording with its own artwork was collapsed into the original")
    }
}
