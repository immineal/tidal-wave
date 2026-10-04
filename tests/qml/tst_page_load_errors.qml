// The four pages that still threw away the reason a fetch failed.
//
// 8ec30ed fixed this on AlbumPage and named the rest: ArtistPage (three
// callbacks), PlaylistPage (three), MixPage and RadioPage (one each) all read
// `if (!err)` or `if (err) return` and kept nothing. The trigger is the one the
// album report was traced to, in four more shapes: a record the favourites and
// pin lists go on naming while the endpoint that would describe it answers 404.
// An artist withdrawn from the catalogue, a playlist its owner deleted or made
// private, a mix that rotated out of the day's set, a station asked for from a
// delisted track - every one of them is a 404 that the page met with silence.
//
// Two groups, and the tests say which is which because the right answer differs:
//
//   ArtistPage has nothing of its own on screen. The hero is artistData and
//   every section below hides itself on an empty list, so a refusal left a page
//   that is blank from edge to edge - the reported symptom. It gets AlbumPage's
//   full-page panel, and its content is hidden rather than left behind it.
//
//   MixPage, PlaylistPage and RadioPage were handed a title by whoever
//   navigated to them, and that title is still correct. Covering it would throw
//   away the one true thing on screen, so these say why the *list* is empty and
//   keep their heading: the message goes in the list's footer, which on an empty
//   list sits exactly where the missing tracks would be.
//
// RadioPage is in the second group although 8ec30ed's note put it in the first.
// Both routes in set radioTitle - TrackRow's "Start radio" passes the track's
// title, Now Playing's "Playing from" passes player.sourceName - so a failed
// station is a correct heading over an empty rectangle, not a blank page. It is
// still the harshest of the three, because the list is the whole page: no
// artwork, no description, and the one pill hides itself when there is nothing
// to play.
//
// The other half of every case is the gate. The panel is on what the server
// said, never on the page being bare - an empty playlist, an artist with no
// releases in this region and a video mix whose track module this app cannot
// read are all pages with nothing in them and nothing wrong.
//
// And PlaylistPage's two folded conditions. `if (err || requested !== uuid)`
// put a refusal and a superseded request through the same door. They are not
// the same thing: a reply about the playlist the user has already left must
// change nothing on the one now open, including whether it is called refused.
// Folded, a slow 404 draws an error panel over whatever is on screen when it
// lands, so fast navigation manufactures failures. Two tests here hold a reply
// back and let the next page open first, which is the only way to reach it.
//
// `bridge` is the stub from tests/TestStubs.h, whose artist trio, track radio
// and playlist-tracks fetches could not fail at all until this file needed them
// to.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "PageLoadErrors"
    when: windowShown
    width: 1000
    height: 800
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible and never instantiates the list header and footer the two
    // hero pages keep their message in. Same reason tst_hero_from_id.qml and
    // tst_album_load_error.qml set it.
    visible: true

    // Invented, like every fixture here: no id, name or title of the owner's is
    // in this file.
    readonly property int deadArtistId: 900000011
    readonly property int liveArtistId: 900000012
    readonly property int deadTrackId:  900000021
    readonly property int liveTrackId:  900000022

    Component { id: holderC;   Item { } }
    Component { id: artistC;   ArtistPage   { anchors.fill: parent } }
    Component { id: radioC;    RadioPage    { anchors.fill: parent } }
    Component { id: mixC;      MixPage      { anchors.fill: parent } }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }

    function makeHolder() {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = 960
        holder.height = 700
        return holder
    }

    function makePage(c) {
        var holder = makeHolder()
        var page = createTemporaryObject(c, holder, {})
        verify(page, "the page was not created")
        return page
    }

    function settle(item) {
        waitForRendering(item, 2000)
        wait(1)
    }

    function makeTracks(n, base) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: base + i, title: "Stück " + (i + 1), artists: "Eine Band",
                       albumTitle: "Ein Album", durationStr: "3:21",
                       coverUrl: "", coverUrl80: "", albumId: 11, artistId: 3 })
        return out
    }

    // Asserted by objectName before the properties behind it, so a page that
    // says nothing fails on *that* rather than on a missing property name.
    function panelOf(page, objName) {
        var p = findChild(page, objName)
        verify(p, "the page has no " + objName + " panel at all")
        return p
    }

    // Visible and laid out, not merely visible. A direct child of a Layout that
    // sets `width`/`height` instead of Layout.preferredWidth/Height is laid out
    // at nothing, and an item of no size still answers `visible: true` - so a
    // message that cannot be read would pass a bare visibility check.
    function verifyMessageIsReadable(page, headingName, detailName) {
        var heading = findChild(page, headingName)
        verify(heading, "the failure message has no heading")
        verify(heading.text.length > 0, "the failure message says nothing")
        var detail = findChild(page, detailName)
        verify(detail, "the failure message has no second line")
        verify(heading.width > 100 && heading.height > 10,
               "the heading was laid out at no size: "
               + heading.width + "x" + heading.height)
        verify(detail.width > 100 && detail.height > 20,
               "the second line was laid out at no size: "
               + detail.width + "x" + detail.height)
    }

    function cleanup() {
        bridge.resetHeadersForTest()
    }

    // ── ArtistPage: the page that went blank ─────────────────────────────

    function test_an_artist_the_server_refuses_says_so() {
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(artistC)
        page.artistId = testCase.deadArtistId
        settle(page)

        compare(bridge.lastArtistFetchedForTest(), testCase.deadArtistId,
                "the page did not ask about the artist it was opened with")
        compare(bridge.lastArtistTopTracksFetchedForTest(), testCase.deadArtistId,
                "the page did not ask for that artist's top tracks")
        compare(bridge.lastArtistAlbumsFetchedForTest(), testCase.deadArtistId,
                "the page did not ask for that artist's discography")
        compare(page.loading, false,
                "a refused artist left the page loading for ever")

        var panel = panelOf(page, "artistLoadError")
        verify(panel.visible,
               "an artist that cannot be loaded drew its empty initial state and said nothing")
        verifyMessageIsReadable(page, "artistLoadErrorText", "artistLoadErrorDetail")

        var content = findChild(page, "artistContent")
        verify(content, "the artist page has no content view")
        compare(content.visible, false,
                "the blank hero stayed on screen underneath the failure")

        verify(page.loadError.length > 0,
               "the page threw away the reason the server gave")
        verify(page.loadFailed,
               "a page with no name, no tracks, no albums and a refusal did not call itself failed")
    }

    function test_an_artist_that_loads_shows_no_failure() {
        bridge.setArtistForTest({ id: testCase.liveArtistId, name: "Eine Band",
                                  bio: "", coverUrl: "cdn/art.jpg",
                                  coverUrl750: "cdn/art750.jpg" },
                                makeTracks(3, 7100),
                                [{ id: 500001, title: "Abendrunde", year: "2019",
                                   coverUrl: "cdn/alb.jpg", type: "ALBUM",
                                   numTracks: 9 }])

        var page = makePage(artistC)
        page.artistId = testCase.liveArtistId
        settle(page)

        compare(page.loadError, "", "a successful load reported an error")
        verify(!page.loadFailed, "a loaded artist called itself failed")
        compare(panelOf(page, "artistLoadError").visible, false,
                "the failure panel covered an artist that loaded")
        compare(findChild(page, "artistContent").visible, true,
                "the content was hidden on an artist that loaded")
        compare(page.topTracks.length, 3, "the top tracks did not load")
        compare(page.albums.length, 1, "the discography did not load")
    }

    // An empty answer is not a refusal. Tidal answers an artist page with no
    // albums at all where every release is blocked in the user's region, and
    // that page is right to be bare.
    function test_an_empty_artist_answer_without_an_error_is_not_a_failure() {
        var page = makePage(artistC)
        page.artistId = testCase.liveArtistId
        settle(page)

        compare(page.loadError, "", "an answer with no error reported one")
        verify(!page.loadFailed,
               "an empty but successful answer was reported to the user as a refusal")
        compare(panelOf(page, "artistLoadError").visible, false,
                "the failure panel was shown for an answer that carried no failure")
    }

    // Related Artists is a whole row of links from one artist page to another,
    // and Main.qml reuses the page item - so a refusal for the artist the user
    // has already left arrives into the page now showing a different one. It
    // must not condemn it. This is the shape that makes a *wrong* fix visible:
    // check the error before the staleness and a held 404 draws the panel over
    // an artist that is merely still bare.
    function test_a_failed_reply_for_the_artist_just_left_does_not_condemn_the_one_now_open() {
        bridge.setDeferHeaderRepliesForTest(true)
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(artistC)
        page.artistId = testCase.deadArtistId
        settle(page)
        compare(bridge.pendingHeaderRepliesForTest(), 3,
                "the first artist's three replies were not held")

        // The second artist answers with nothing and no error, which is the
        // legitimately-bare page above. That is what makes the stale 404 able to
        // do damage: everything loadFailed looks at is already empty, so the
        // reason is the only thing standing between the user and a lie.
        bridge.setDeferHeaderRepliesForTest(false)
        bridge.setHeaderErrorForTest("")
        page.artistId = testCase.liveArtistId
        settle(page)
        compare(page.loadError, "", "the second artist started out accused")

        bridge.flushHeaderRepliesForTest()
        settle(page)

        compare(page.loadError, "",
                "the artist the user left reported its failure against the one they are on")
        verify(!page.loadFailed,
               "a reply for the artist the user left called the current page failed")
        compare(panelOf(page, "artistLoadError").visible, false,
                "a superseded request drew an error panel")
        compare(findChild(page, "artistContent").visible, true,
                "a superseded request hid the page the user is looking at")
    }

    // ── RadioPage: a heading over nothing ────────────────────────────────

    function test_a_track_radio_the_server_refuses_says_so() {
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(radioC)
        page.radioTitle = "Erstes Stück"
        page.trackId = testCase.deadTrackId
        settle(page)

        compare(bridge.lastTrackRadioFetchedForTest(), testCase.deadTrackId,
                "the page did not ask about the track it was opened with")
        compare(page.loading, false,
                "a refused station left the page loading for ever")

        verify(panelOf(page, "radioLoadError").visible,
               "a station that cannot be built drew an empty list and said nothing")
        verifyMessageIsReadable(page, "radioLoadErrorText", "radioLoadErrorDetail")

        // The second group's distinguishing property: the heading the caller
        // handed over is still correct and still on screen.
        compare(page.radioTitle, "Erstes Stück",
                "the failure threw away the title the caller passed")
        verify(page.loadError.length > 0,
               "the page threw away the reason the server gave")
        verify(page.loadFailed,
               "a station with no tracks and a refusal did not call itself failed")
    }

    function test_a_track_radio_that_loads_shows_no_failure() {
        bridge.setTrackRadioForTest(makeTracks(4, 7200))

        var page = makePage(radioC)
        page.trackId = testCase.liveTrackId
        settle(page)

        compare(page.tracks.length, 4, "the station did not load")
        compare(page.loadError, "", "a successful load reported an error")
        verify(!page.loadFailed, "a loaded station called itself failed")
        compare(panelOf(page, "radioLoadError").visible, false,
                "the failure message covered a station that loaded")
    }

    function test_an_empty_station_without_an_error_is_not_a_failure() {
        var page = makePage(radioC)
        page.trackId = testCase.liveTrackId
        settle(page)

        compare(page.loadError, "", "an answer with no error reported one")
        verify(!page.loadFailed,
               "an empty but successful answer was reported to the user as a refusal")
        compare(panelOf(page, "radioLoadError").visible, false,
                "the failure message was shown for an answer that carried no failure")
    }

    // "Start radio" is on every row, including the rows of a station, so one
    // station opens another in the same reused page item.
    function test_a_failed_reply_for_the_station_just_left_does_not_condemn_the_one_now_open() {
        bridge.setDeferHeaderRepliesForTest(true)
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(radioC)
        page.trackId = testCase.deadTrackId
        settle(page)
        compare(bridge.pendingHeaderRepliesForTest(), 1,
                "the first station's reply was not held")

        bridge.setDeferHeaderRepliesForTest(false)
        bridge.setHeaderErrorForTest("")
        page.trackId = testCase.liveTrackId
        settle(page)
        compare(page.loadError, "", "the second station started out accused")

        bridge.flushHeaderRepliesForTest()
        settle(page)

        compare(page.loadError, "",
                "the station the user left reported its failure against the one they are on")
        compare(panelOf(page, "radioLoadError").visible, false,
                "a superseded request drew an error message")
    }

    // ── MixPage: keeps its title, says why the list is empty ─────────────

    function test_a_mix_the_server_refuses_says_why_and_keeps_its_title() {
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(mixC)
        page.title = "Abendrunde"
        page.coverUrl = "cdn/cached.jpg"
        page.mixId = "mx-dead-1"
        settle(page)

        compare(page.loading, false, "a refused mix left the page loading for ever")
        verify(panelOf(page, "mixLoadError").visible,
               "a mix that cannot be loaded drew an empty list and said nothing")
        verifyMessageIsReadable(page, "mixLoadErrorText", "mixLoadErrorDetail")

        // The hero is kept, which is the whole difference from ArtistPage.
        var heroTitle = findChild(page, "heroTitle")
        verify(heroTitle, "the mix page has no hero title")
        compare(heroTitle.text, "Abendrunde",
                "the failure threw away the title the caller passed")
        verify(page.loadError.length > 0,
               "the page threw away the reason the server gave")
        verify(page.loadFailed,
               "a mix with no tracks and a refusal did not call itself failed")
    }

    function test_a_mix_that_loads_shows_no_failure() {
        bridge.setMixPageForTest({ id: "mx-live-1", title: "Meine Entdeckungen",
                                   subtitle: "Zwei Stunden Nachtmusik",
                                   coverUrl: "cdn/mx.jpg",
                                   mixType: "DISCOVERY_MIX" },
                                 makeTracks(5, 7300))

        var page = makePage(mixC)
        page.mixId = "mx-live-1"
        settle(page)

        compare(page.tracks.length, 5, "the mix did not load")
        compare(page.loadError, "", "a successful load reported an error")
        verify(!page.loadFailed, "a loaded mix called itself failed")
        compare(panelOf(page, "mixLoadError").visible, false,
                "the failure message covered a mix that loaded")
    }

    // A video mix answers VIDEO_LIST where a normal mix answers TRACK_LIST, so
    // its track list reads as empty with no error anywhere - the case
    // tst_hero_from_id already holds the header half of. It must not be called
    // refused: the reply arrived and it was fine.
    function test_a_mix_whose_tracks_cannot_be_read_is_not_called_refused() {
        bridge.setMixPageForTest({ id: "mx-live-2", title: "Mein Video-Mix 1",
                                   subtitle: "", coverUrl: "",
                                   mixType: "VIDEO_DAILY_MIX" }, [])

        var page = makePage(mixC)
        page.mixId = "mx-live-2"
        settle(page)

        compare(page.tracks.length, 0, "the fixture was supposed to carry no tracks")
        compare(page.loadError, "", "an answer with no error reported one")
        verify(!page.loadFailed,
               "a track module this app cannot read was reported as a refusal")
        compare(panelOf(page, "mixLoadError").visible, false,
                "the failure message was shown for an answer that carried no failure")
    }

    function test_a_failed_reply_for_the_mix_just_left_does_not_condemn_the_one_now_open() {
        bridge.setDeferHeaderRepliesForTest(true)
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(mixC)
        page.mixId = "mx-dead-2"
        settle(page)
        compare(bridge.pendingHeaderRepliesForTest(), 1,
                "the first mix's reply was not held")

        // A header and no tracks, with no error: the video-mix case above, and
        // so a page where everything loadFailed reads is already empty.
        bridge.setDeferHeaderRepliesForTest(false)
        bridge.setHeaderErrorForTest("")
        bridge.setMixPageForTest({ id: "mx-live-3", title: "Zweite Auswahl",
                                   subtitle: "", coverUrl: "",
                                   mixType: "VIDEO_DAILY_MIX" }, [])
        page.mixId = "mx-live-3"
        settle(page)
        compare(page.loadError, "", "the second mix started out accused")

        bridge.flushHeaderRepliesForTest()
        settle(page)

        compare(page.loadError, "",
                "the mix the user left reported its failure against the one they are on")
        compare(panelOf(page, "mixLoadError").visible, false,
                "a superseded request drew an error message")
        compare(findChild(page, "heroTitle").text, "Zweite Auswahl",
                "the mix the user left retitled the one they are on")
    }

    // ── PlaylistPage: the two folded conditions ──────────────────────────

    function test_a_playlist_the_server_refuses_says_why_and_keeps_its_title() {
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(playlistC)
        page.playlistTitle = "Spätschicht"
        page.coverUrl = "cdn/cached.jpg"
        page.playlistUuid = "pl-dead-1"
        settle(page)

        compare(bridge.lastPlaylistTracksFetchedForTest(), "pl-dead-1",
                "the page did not ask for that playlist's tracks")
        compare(page.loading, false,
                "a refused playlist left the page loading for ever")

        verify(panelOf(page, "playlistLoadError").visible,
               "a playlist that cannot be loaded drew an empty list and said nothing")
        verifyMessageIsReadable(page, "playlistLoadErrorText", "playlistLoadErrorDetail")

        compare(findChild(page, "heroTitle").text, "Spätschicht",
                "the failure threw away the title the caller passed")
        verify(page.loadError.length > 0,
               "the page threw away the reason the server gave")
        verify(page.loadFailed,
               "a playlist with no tracks and a refusal did not call itself failed")
    }

    function test_a_playlist_that_loads_shows_no_failure() {
        bridge.setPlaylistForTest({ uuid: "pl-live-1", title: "Spätschicht",
                                    description: "Für lange Abende",
                                    numTracks: 4, duration: 900,
                                    coverUrl: "cdn/pl.jpg", type: "USER" })
        bridge.setPlaylistTracksForTest(makeTracks(4, 7400))

        var page = makePage(playlistC)
        page.playlistUuid = "pl-live-1"
        settle(page)

        compare(page.tracks.length, 4, "the playlist did not load")
        compare(page.loadError, "", "a successful load reported an error")
        verify(!page.loadFailed, "a loaded playlist called itself failed")
        compare(panelOf(page, "playlistLoadError").visible, false,
                "the failure message covered a playlist that loaded")
    }

    // The gate, in the shape that would hurt most. An empty playlist is an
    // ordinary thing to own - every playlist is empty for as long as it takes to
    // put the first song in - so a panel gated on the list being bare rather
    // than on the server's answer would call the user's own new playlist
    // unavailable.
    function test_an_empty_playlist_is_not_a_failed_one() {
        bridge.setPlaylistForTest({ uuid: "pl-live-2", title: "Neue Liste",
                                    description: "", numTracks: 0, duration: 0,
                                    coverUrl: "", type: "USER" })

        var page = makePage(playlistC)
        page.playlistUuid = "pl-live-2"
        settle(page)

        compare(page.tracks.length, 0, "the fixture was supposed to carry no tracks")
        compare(findChild(page, "heroTitle").text, "Neue Liste",
                "the empty playlist did not load its own header")
        compare(page.loadError, "", "an answer with no error reported one")
        verify(!page.loadFailed,
               "an empty playlist was reported to the user as unavailable")
        compare(panelOf(page, "playlistLoadError").visible, false,
                "the failure message was shown over a playlist with nothing wrong with it")
    }

    // ── superseded is not failed ─────────────────────────────────────────

    // loadPlaylistHeader() read `if (err || !p || requested !== uuid) return`:
    // one door for three different things. Only the middle one is a failure.
    //
    // Held reply for a playlist the user leaves, with a 404 frozen into it,
    // landing on a page now showing a real but empty playlist. The two
    // conditions kept apart, nothing happens. Checked in the other order - the
    // error first - the reason is recorded against a playlist that is merely
    // empty, and the panel goes up over the user's own list.
    function test_a_failed_reply_for_the_playlist_just_left_does_not_condemn_the_one_now_open() {
        bridge.setDeferHeaderRepliesForTest(true)
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(playlistC)
        page.playlistUuid = "pl-dead-2"
        settle(page)
        compare(bridge.pendingHeaderRepliesForTest(), 1,
                "the first playlist's header reply was not held")
        // The tracks half is not held, so the dead playlist has already been
        // told no. That is the state the user navigates out of.
        verify(page.loadError.length > 0,
               "the dead playlist's tracks fetch did not report its failure")

        bridge.setDeferHeaderRepliesForTest(false)
        bridge.setHeaderErrorForTest("")
        bridge.setPlaylistForTest({ uuid: "pl-live-3", title: "Zweite Liste",
                                    description: "", numTracks: 0, duration: 0,
                                    coverUrl: "", type: "USER" })
        bridge.setPlaylistTracksForTest([])
        page.playlistUuid = "pl-live-3"
        settle(page)
        compare(page.loadError, "",
                "opening a second playlist kept the first one's failure")
        compare(findChild(page, "heroTitle").text, "Zweite Liste",
                "the second playlist never arrived")

        bridge.flushHeaderRepliesForTest()
        settle(page)

        compare(page.loadError, "",
                "the playlist the user left reported its failure against the one they are on")
        verify(!page.loadFailed,
               "a superseded 404 called a real, empty playlist unavailable")
        compare(panelOf(page, "playlistLoadError").visible, false,
                "fast navigation manufactured an error panel")
        compare(findChild(page, "heroTitle").text, "Zweite Liste",
                "the playlist the user left retitled the one they are on")
    }

    // The same fold one function up, in reloadTracks(). That one is the top-up
    // for a song added to this playlist from a row on this very page, and it
    // runs on a page that is already right apart from one row - so a failed
    // top-up must stay silent. Recording the reason there would put "this
    // playlist could not be loaded" over a playlist the user can see, and over
    // the empty one they had just added their first song to.
    function test_a_failed_top_up_leaves_the_playlist_on_screen_alone() {
        bridge.setPlaylistForTest({ uuid: "pl-live-4", title: "Neue Liste",
                                    description: "", numTracks: 0, duration: 0,
                                    coverUrl: "", type: "USER" })

        var page = makePage(playlistC)
        page.playlistUuid = "pl-live-4"
        settle(page)
        compare(page.loadError, "", "the playlist did not open cleanly")

        // Now the tracks endpoint starts refusing, and the page asks it again.
        bridge.setHeaderErrorForTest("server replied: Not Found")
        page.reloadTracks()
        settle(page)

        compare(page.loadError, "",
                "a failed top-up accused a playlist that had opened cleanly")
        verify(!page.loadFailed,
               "a failed top-up called a real, empty playlist unavailable")
        compare(panelOf(page, "playlistLoadError").visible, false,
                "a failed top-up drew an error panel over a page that is correct")
        compare(findChild(page, "heroTitle").text, "Neue Liste",
                "a failed top-up blanked the hero")
    }

    // And the staleness half of the same statement, which until the stub grew
    // its own hold for the tracks reply could not be reached at all: the
    // function captures the uuid and then got a synchronous answer, so
    // `requested` could never differ from the uuid on screen.
    function test_a_superseded_top_up_does_not_overwrite_the_playlist_on_screen() {
        bridge.setPlaylistForTest({ uuid: "pl-live-5", title: "Erste Liste",
                                    description: "", numTracks: 1, duration: 60,
                                    coverUrl: "", type: "USER" })
        bridge.setPlaylistTracksForTest(makeTracks(1, 7500))

        var page = makePage(playlistC)
        page.playlistUuid = "pl-live-5"
        settle(page)
        compare(page.tracks.length, 1, "the first playlist did not load")

        // A top-up for pl-live-5 goes out and is held. Its payload is frozen
        // when the call is made, so it carries this one-track list.
        bridge.setDeferTrackRepliesForTest(true)
        page.reloadTracks()
        compare(bridge.pendingTrackRepliesForTest(), 1,
                "the top-up reply was not held")

        bridge.setDeferTrackRepliesForTest(false)
        bridge.setPlaylistForTest({ uuid: "pl-live-6", title: "Zweite Liste",
                                    description: "", numTracks: 5, duration: 900,
                                    coverUrl: "", type: "USER" })
        bridge.setPlaylistTracksForTest(makeTracks(5, 7600))
        page.playlistUuid = "pl-live-6"
        settle(page)
        compare(page.tracks.length, 5, "the second playlist did not load")

        bridge.flushTrackRepliesForTest()
        settle(page)

        compare(page.tracks.length, 5,
                "a top-up for the playlist the user left replaced the tracks on screen")
        compare(findChild(page, "heroTitle").text, "Zweite Liste",
                "the second playlist lost its header")
    }
}
