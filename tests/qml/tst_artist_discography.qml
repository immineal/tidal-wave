// ArtistPage's two discography rows: which release lands in which, and what
// the edition collapse may drop. The split is by type, with the track count
// as a fallback. dedupeEditions() keys on the section as well as on artwork
// and title, because a lead single often carries its album's artwork and
// title. The request side is in tests/tst_artist_discography.cpp.
// Every id, title and cover is invented.

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

    function makePage() {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = 960
        holder.height = 700
        var page = createTemporaryObject(artistC, holder, {})
        verify(page, "the page was not created")
        return page
    }

    function settle(item) {
        waitForRendering(item, 2000)
        wait(1)
    }

    function rel(id, title, type, numTracks, cover) {
        return { id: id, title: title, type: type, numTracks: numTracks,
                 coverUrl: cover, year: "2021", artists: "Eine Band" }
    }

    // Opens the page on an artist whose discography is `albums`, and hands back
    // the two sections.
    function openWith(albums) {
        bridge.setArtistForTest({ id: testCase.artistId, name: "Eine Band" }, [], albums)
        var page = makePage()
        page.artistId = testCase.artistId
        settle(page)
        var out = {
            page:    page,
            albums:  findChild(page, "artistAlbumsSection"),
            singles: findChild(page, "artistSinglesSection")
        }
        verify(out.albums,  "the page has no Albums section at all")
        verify(out.singles, "the page has no Singles & EPs section at all")
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
