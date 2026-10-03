// A detail page opened with nothing but an id has to label itself.
//
// The complaint: "Playing from: <a mix>" in Now Playing opened a mix whose
// tracks were there but whose hero was blank - no title, no cover. That link
// navigates with `{ mixId: player.sourceId }` and nothing else, and MixPage's
// title/subtitle/coverUrl were filled only by whichever caller happened to have
// them in hand. The sidebar had them, so every other route in looked fine.
//
// So these tests never pass a title or a cover. They set the id, which is all
// the failing route sets, and then ask what the hero says. The playlist branch
// of that same link had the same hole and additionally sent `playlistType: ""`,
// which told the page a playlist the user owns is read-only.
//
// `bridge` is the stub from tests/TestStubs.h. It answers synchronously, so
// anything a load would overwrite must be assigned *before* the id that
// triggers the load, not after - the same rule tst_layout_pages.qml states.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "HeroFromId"
    when: windowShown
    width: 1000
    height: 800
    // TestCase declares visible: false, and an invisible tree never
    // instantiates the ListView header the hero lives in.
    visible: true

    Component { id: holderC;   Item { } }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }
    Component { id: mixC;      MixPage      { anchors.fill: parent } }

    function makeHolder() {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = 960
        holder.height = 700
        return holder
    }

    // A mix as `pages/mix` describes it in its MIX_HEADER module, with the
    // artwork already resolved to the URL the cover loads from. Invented, like
    // every fixture here: no id, title or image of the user's is in this file.
    function mixHeader(id, title) {
        return { id: id, title: title, subtitle: "Zwei Stunden Nachtmusik",
                 coverUrl: "cdn/" + id + ".jpg", mixType: "DISCOVERY_MIX" }
    }

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 7000 + i, title: "Stück " + (i + 1), artists: "Eine Band",
                       albumTitle: "Ein Album", durationStr: "3:21",
                       coverUrl: "", coverUrl80: "", albumId: 11, artistId: 3 })
        return out
    }

    function heroTitleOf(page) {
        var t = findChild(page, "heroTitle")
        verify(t, "the page has no hero title")
        return t.text
    }

    function heroCoverOf(page) {
        var c = findChild(page, "heroCover")
        verify(c, "the page has no hero cover")
        return c.source.toString()
    }

    function settle(item) {
        waitForRendering(item, 2000)
        wait(1)
    }

    function cleanup() {
        bridge.resetHeadersForTest()
    }

    // ── mix ──────────────────────────────────────────────────────────────

    // The reported bug, as the user hit it: the id alone, nothing else.
    function test_mix_opened_with_only_an_id_fills_its_own_hero() {
        bridge.setMixPageForTest(mixHeader("mx-1", "Meine Entdeckungen"), makeTracks(5))

        var holder = makeHolder()
        var page = createTemporaryObject(mixC, holder)
        page.mixId = "mx-1"
        settle(page)

        compare(heroTitleOf(page), "Meine Entdeckungen",
                "a mix opened by id alone showed a blank title")
        compare(heroCoverOf(page), "image://tidal/cdn/mx-1.jpg",
                "a mix opened by id alone showed no cover")
        compare(page.subtitle, "Zwei Stunden Nachtmusik",
                "the subtitle came from nowhere either")
        compare(page.tracks.length, 5, "the tracks did not load")
    }

    // The page has to ask about the mix it was opened with. Nothing else in
    // the stub would notice if it asked for another one.
    function test_mix_asks_about_the_id_it_was_opened_with() {
        bridge.setMixPageForTest(mixHeader("mx-2", "Neuzugänge"), makeTracks(2))

        var holder = makeHolder()
        var page = createTemporaryObject(mixC, holder)
        page.mixId = "mx-2"
        settle(page)

        compare(bridge.lastMixPageIdForTest(), "mx-2",
                "the page asked about some other mix")
        compare(bridge.mixPageFetchCountForTest(), 1,
                "opening one mix should be one request, not two")
    }

    // A video mix answers VIDEO_LIST where a normal mix answers TRACK_LIST, so
    // its track list reads as empty - which is how eight tiles once opened
    // blank. An unreadable track module may not cost the page its header: a
    // titled page over an empty list says something, a blank one says nothing.
    function test_mix_header_survives_a_track_list_it_cannot_read() {
        var header = mixHeader("mx-3", "Mein Video-Mix 1")
        header.mixType = "VIDEO_DAILY_MIX"
        bridge.setMixPageForTest(header, [])

        var holder = makeHolder()
        var page = createTemporaryObject(mixC, holder)
        page.mixId = "mx-3"
        settle(page)

        compare(page.tracks.length, 0, "the fixture was supposed to carry no tracks")
        compare(heroTitleOf(page), "Mein Video-Mix 1",
                "an empty track list threw the hero away with it")
    }

    // The other half: a response with tracks and no header leaves whatever the
    // caller passed standing, rather than blanking a good title with an empty
    // one. The sidebar does pass a title, and it must not flicker away.
    function test_mix_keeps_a_callers_title_when_the_response_has_no_header() {
        bridge.setMixPageForTest({}, makeTracks(3))

        var holder = makeHolder()
        var page = createTemporaryObject(mixC, holder)
        page.title = "Abendrunde"
        page.coverUrl = "cdn/cached.jpg"
        page.mixId = "mx-4"
        settle(page)

        compare(heroTitleOf(page), "Abendrunde",
                "a headerless response blanked the title the caller passed")
        compare(heroCoverOf(page), "image://tidal/cdn/cached.jpg",
                "a headerless response blanked the cover the caller passed")
        compare(page.tracks.length, 3, "the tracks did not load")
    }

    // And a request that fails outright must not blank it either.
    function test_mix_keeps_a_callers_title_when_the_request_fails() {
        bridge.setMixPageForTest(mixHeader("mx-5", "sollte nie ankommen"), makeTracks(4))
        bridge.setHeaderErrorForTest("network unreachable")

        var holder = makeHolder()
        var page = createTemporaryObject(mixC, holder)
        page.title = "Abendrunde"
        page.mixId = "mx-5"
        settle(page)

        compare(heroTitleOf(page), "Abendrunde",
                "a failed request blanked the title the caller passed")
        compare(page.loading, false, "a failed request left the page loading for ever")
    }

    // Main.qml reuses the loaded page when one mix navigates to another, so
    // the slow reply for the mix just left arrives into the page now showing a
    // different one. It must not retitle it.
    function test_a_reply_for_the_mix_just_left_does_not_retitle_the_one_now_open() {
        // The first request is the slow one: held, while the second is let
        // through at once. That ordering is the whole point - a stale reply
        // that lands *before* the good one is harmless, because the good one
        // overwrites it.
        bridge.setDeferHeaderRepliesForTest(true)
        bridge.setMixPageForTest(mixHeader("mx-6", "Erste Auswahl"), makeTracks(2))

        var holder = makeHolder()
        var page = createTemporaryObject(mixC, holder)
        page.mixId = "mx-6"
        settle(page)
        compare(bridge.pendingHeaderRepliesForTest(), 1, "the first reply was not held")

        bridge.setDeferHeaderRepliesForTest(false)
        bridge.setMixPageForTest(mixHeader("mx-7", "Zweite Auswahl"), makeTracks(4))
        page.mixId = "mx-7"
        settle(page)
        compare(heroTitleOf(page), "Zweite Auswahl", "the second mix never arrived")

        bridge.flushHeaderRepliesForTest()
        settle(page)

        compare(heroTitleOf(page), "Zweite Auswahl",
                "the mix the user left retitled the mix they are on")
        compare(page.coverUrl, "cdn/mx-7.jpg",
                "the mix the user left overwrote its cover")
        compare(page.tracks.length, 4,
                "the mix the user left overwrote its tracks")
        compare(page.loading, false, "the page never stopped loading")
    }

    // ── playlist ─────────────────────────────────────────────────────────

    // Same hole, one line above the mix one in NowPlayingPage's source: the
    // playlist branch navigates with the uuid and the player's cached name,
    // and sends `coverUrl: ""` outright.
    function test_playlist_opened_with_only_a_uuid_fills_its_own_hero() {
        bridge.setPlaylistForTest({ uuid: "pl-1", title: "Spätschicht",
                                    description: "Für lange Abende",
                                    numTracks: 12, duration: 3840,
                                    coverUrl: "cdn/pl-1.jpg", type: "USER" })

        var holder = makeHolder()
        var page = createTemporaryObject(playlistC, holder)
        page.playlistUuid = "pl-1"
        settle(page)

        compare(heroTitleOf(page), "Spätschicht",
                "a playlist opened by uuid alone showed a blank title")
        compare(heroCoverOf(page), "image://tidal/cdn/pl-1.jpg",
                "a playlist opened by uuid alone showed no cover")
        compare(page.playlistDescription, "Für lange Abende",
                "the description came from nowhere either")
        compare(page.playlistDuration, 3840, "the duration came from nowhere either")
        compare(bridge.lastPlaylistFetchedForTest(), "pl-1",
                "the page asked about some other playlist")
    }

    // Not cosmetic, this one. `playlistType` decides whether the page lets the
    // user edit the playlist, and the Now Playing link sent "", which reads as
    // EDITORIAL: the user's own playlist opened read-only.
    function test_playlist_opened_with_only_a_uuid_learns_that_it_is_editable() {
        bridge.setPlaylistForTest({ uuid: "pl-2", title: "Eigene Liste",
                                    description: "", numTracks: 3, duration: 600,
                                    coverUrl: "", type: "USER" })

        var holder = makeHolder()
        var page = createTemporaryObject(playlistC, holder)
        page.playlistUuid = "pl-2"
        settle(page)

        compare(page.playlistType, "USER",
                "the page never learned whose playlist this is")
        verify(page.isUserPlaylist,
               "a playlist the user owns opened read-only when reached by uuid")
    }

    function test_playlist_keeps_a_callers_title_when_the_request_fails() {
        bridge.setPlaylistForTest({ uuid: "pl-3", title: "sollte nie ankommen",
                                    description: "", numTracks: 0, duration: 0,
                                    coverUrl: "", type: "USER" })
        bridge.setHeaderErrorForTest("network unreachable")

        var holder = makeHolder()
        var page = createTemporaryObject(playlistC, holder)
        page.playlistTitle = "Spätschicht"
        page.coverUrl = "cdn/cached.jpg"
        page.playlistUuid = "pl-3"
        settle(page)

        compare(heroTitleOf(page), "Spätschicht",
                "a failed request blanked the title the caller passed")
        compare(heroCoverOf(page), "image://tidal/cdn/cached.jpg",
                "a failed request blanked the cover the caller passed")
    }

    // The same race on the playlist side.
    function test_a_reply_for_the_playlist_just_left_does_not_retitle_the_one_now_open() {
        bridge.setDeferHeaderRepliesForTest(true)
        bridge.setPlaylistForTest({ uuid: "pl-4", title: "Erste Liste", description: "",
                                    numTracks: 1, duration: 60,
                                    coverUrl: "cdn/pl-4.jpg", type: "USER" })

        var holder = makeHolder()
        var page = createTemporaryObject(playlistC, holder)
        page.playlistUuid = "pl-4"
        settle(page)
        compare(bridge.pendingHeaderRepliesForTest(), 1, "the first reply was not held")

        bridge.setDeferHeaderRepliesForTest(false)
        bridge.setPlaylistForTest({ uuid: "pl-5", title: "Zweite Liste", description: "",
                                    numTracks: 2, duration: 120,
                                    coverUrl: "cdn/pl-5.jpg", type: "EDITORIAL" })
        page.playlistUuid = "pl-5"
        settle(page)
        compare(heroTitleOf(page), "Zweite Liste", "the second playlist never arrived")

        bridge.flushHeaderRepliesForTest()
        settle(page)

        compare(heroTitleOf(page), "Zweite Liste",
                "the playlist the user left retitled the playlist they are on")
        compare(heroCoverOf(page), "image://tidal/cdn/pl-5.jpg",
                "the playlist the user left overwrote its cover")
        // And not its editability either, which is the half that would let the
        // user try to change a playlist that is not theirs.
        compare(page.playlistType, "EDITORIAL",
                "the playlist the user left overwrote its type")
    }
}
