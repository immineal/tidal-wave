// ArtistPage, PlaylistPage, MixPage and RadioPage keep the reason a fetch
// failed. ArtistPage has nothing of its own on screen, so it gets a full-page
// panel. The other three keep the heading their caller passed and say in the
// list's footer why the list is empty. The panel is gated on what the server
// said, never on the page being bare, and a reply for a page the user has
// left must change nothing. The bridge stub is from tests/TestStubs.h.

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
    // item invisible and never instantiates the list header and footer the
    // two hero pages keep their message in.
    visible: true

    // Invented, like every fixture here.
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
    // says nothing fails here and never on a missing property name.
    function panelOf(page, objName) {
        var p = findChild(page, objName)
        verify(p, "the page has no " + objName + " panel at all")
        return p
    }

    // Laid out as well as visible. A direct child of a Layout that sets width
    // and height in place of Layout.preferredWidth/Height is laid out at
    // nothing, and an item of no size still answers visible: true.
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

    // Related Artists links one artist page to another, and Main.qml reuses
    // the page item, so a refusal for the artist just left arrives into the
    // page now showing a different one. Staleness is checked before the error.
    function test_a_failed_reply_for_the_artist_just_left_does_not_condemn_the_one_now_open() {
        bridge.setDeferHeaderRepliesForTest(true)
        bridge.setHeaderErrorForTest("server replied: Not Found")

        var page = makePage(artistC)
        page.artistId = testCase.deadArtistId
        settle(page)
        compare(bridge.pendingHeaderRepliesForTest(), 3,
                "the first artist's three replies were not held")

        // The second artist answers with nothing and no error, the legitimately
        // bare page above. Everything loadFailed looks at is already empty, so
        // only the reason keeps the stale 404 from condemning it.
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

        // The heading the caller handed over is still correct and still on screen.
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

    // The radio entry is on every row, including the rows of a station, so
    // one station opens another in the same reused page item.
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

        // The hero is kept, unlike on ArtistPage.
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
    // its track list reads as empty with no error anywhere. It must not be
    // called refused.
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

    // ── PlaylistPage: keeps its title, says why the list is empty ────────

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

    // An empty playlist is an ordinary thing to own, so a panel gated on the
    // list being bare would call the user's own new playlist unavailable.
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

    // A held 404 for a playlist the user leaves lands on a page now showing
    // a real but empty playlist. Staleness is checked before the error, so
    // nothing happens.
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

    // reloadTracks() is the top-up for a song added from a row on this page,
    // and it runs on a page that is already right apart from one row, so a
    // failed top-up must stay silent.
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

    // The staleness half of the same guard. The stub holds the tracks reply,
    // so the requested uuid can differ from the one on screen when it lands.
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
