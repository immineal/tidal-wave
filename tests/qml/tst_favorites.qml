// A favourite the server refuses, at every place a user can ask for one.
// The like, save and follow states are read back out of the bridge, which
// only writes its caches when the server says yes. So on a refusal the state
// must not move, and the refusal must be reported. Each site is also checked
// for the call it sends, since the helper picks add or remove from the state.
// StubBridge's refusal switch is pinned by test_the_stub_can_refuse_at_all.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Favorites"
    when: windowShown
    // TestCase declares visible: false, which would leave every child
    // unrendered, and a ToolTip never shows for an item in no window.
    visible: true
    width: 1280
    height: 900

    // ── fixtures ─────────────────────────────────────────────────────────
    //
    // One id per kind, and all three different from each other, so a message or
    // a call recorded against the wrong kind cannot pass by coincidence.
    readonly property int trackId:  9101
    readonly property int albumId:  4242
    readonly property int artistId: 777
    // A mix id is 30 lowercase hex characters. Invented, like everything
    // else here.
    readonly property string mixId: "0a1b2c3d4e5f60718293a4b5c6d7e8"

    function makeTrack() {
        return {
            id: testCase.trackId,
            title: "Ein Lied mit einem ziemlich langen Titel",
            artists: "Erster Interpret",
            albumTitle: "Ein Album",
            durationStr: "4:07",
            coverUrl: "", coverUrl80: "",
            albumId: 55, artistId: testCase.artistId,
            popularity: 73
        }
    }

    function makeAlbumRow() {
        return { id: testCase.albumId, title: "Winterabend",
                 artists: "Erster Interpret", coverUrl: "cdn/4242.jpg" }
    }

    function makeArtistRow() {
        return { id: testCase.artistId, name: "Erster Interpret",
                 coverUrl: "cdn/777.jpg" }
    }

    // The strings the shared helper can say, with the context of the file the
    // inline component is declared in, ContextMenu.qml. Written out here, so
    // swapping two of them in the helper is a failure.
    readonly property string likeFailed:     qsTranslate("ContextMenu", "Could not like the song",
                                                "shown when adding a track to favourites failed")
    readonly property string unlikeFailed:   qsTranslate("ContextMenu", "Could not unlike the song",
                                                "shown when removing a track from favourites failed")
    readonly property string saveFailed:     qsTranslate("ContextMenu", "Could not save the album",
                                                "shown when saving an album to the library failed")
    readonly property string unsaveFailed:   qsTranslate("ContextMenu", "Could not remove the album from your library",
                                                "shown when removing an album from the library failed")
    readonly property string followFailed:   qsTranslate("ContextMenu", "Could not follow the artist",
                                                "shown when following an artist failed")
    readonly property string unfollowFailed: qsTranslate("ContextMenu", "Could not unfollow the artist",
                                                "shown when unfollowing an artist failed")
    readonly property string mixSaveFailed:   qsTranslate("ContextMenu", "Could not save the mix",
                                                "shown when saving a mix to the library failed")
    readonly property string mixUnsaveFailed: qsTranslate("ContextMenu", "Could not remove the mix from your library",
                                                "shown when removing a mix from the library failed")

    // ── hosts ────────────────────────────────────────────────────────────

    Component { id: holderC;     Item { } }
    Component { id: playerBarC;  PlayerBar      { } }
    Component { id: trackRowC;   TrackRow       { } }
    Component { id: albumC;      AlbumPage      { anchors.fill: parent } }
    Component { id: artistC;     ArtistPage     { anchors.fill: parent } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: mixC;        MixPage        { anchors.fill: parent } }

    // NowPlayingPage reaches its sleep timer and fullscreen toggle through
    // Window.window, so it cannot be instantiated bare. Being a separate
    // window, its tool tip is not testCase.ToolTip.toolTip.
    Component {
        id: nowPlayingHost
        Window {
            id: npWin
            width: 1100; height: 900
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) { sleepTimerActive = true }
            function cancelSleepTimer() { sleepTimerActive = false }
            function formatSleepTime(seconds) { return "0:30" }
            function navigate(page, params) {}
            function goBack() {}
            property bool fullScreen: false
            function toggleFullScreen() { fullScreen = !fullScreen }
            property alias page: np
            NowPlayingPage { id: np; width: npWin.width; height: npWin.height }
        }
    }

    function makeHolder(w, h) {
        var holder = createTemporaryObject(holderC, testCase,
                                           { width: w || 1200, height: h || 700 })
        verify(holder, "the holder was not created")
        return holder
    }

    function settle(item) {
        wait(0)
        waitForRendering(item)
    }

    function makeBar() {
        var holder = makeHolder(1200, 120)
        var bar = createTemporaryObject(playerBarC, holder, { width: 1200 })
        verify(bar, "the player bar was not created")
        settle(holder)
        return bar
    }

    function makeRow() {
        var holder = makeHolder(1300, 120)
        var t = makeTrack()
        var row = createTemporaryObject(trackRowC, holder, {
            width: 1300, trackData: t, title: t.title, artists: t.artists
        })
        verify(row, "the track row was not created")
        settle(holder)
        return row
    }

    // A mix page showing one mix, with its tracks already in hand. The hero
    // lives in the ListView's header, which needs a big enough holder and a
    // visible TestCase to be instantiated.
    function makeMixPage() {
        var holder = makeHolder()
        var page = createTemporaryObject(mixC, holder, {})
        verify(page, "the mix page was not created")
        page.title    = "Weit hinter dem Horizont"
        page.subtitle = "Radio"
        page.mixId    = testCase.mixId
        page.tracks   = [makeTrack()]
        settle(holder)
        return page
    }

    function makeAlbumPage() {
        var holder = makeHolder()
        var page = createTemporaryObject(albumC, holder, {})
        verify(page, "the album page was not created")
        page.albumId = testCase.albumId
        page.albumData = { title: "Winterabend", artists: "Erster Interpret",
                           coverUrl: "cdn/4242.jpg" }
        page.tracks = [makeTrack()]
        settle(holder)
        return page
    }

    function makeArtistPage() {
        var holder = makeHolder()
        var page = createTemporaryObject(artistC, holder, {})
        verify(page, "the artist page was not created")
        page.artistId = testCase.artistId
        page.artistData = { id: testCase.artistId, name: "Erster Interpret",
                            picture: "cdn/777.jpg" }
        page.topTracks = [makeTrack()]
        settle(holder)
        return page
    }

    // Tab 1 is Albums, tab 2 Artists. The rows come from the bridge's own
    // favourites lists, so that a removal the stub accepts takes the tile
    // out. A list assigned by hand would keep every tile.
    function makeCollection(tab) {
        var holder = makeHolder(1280, 800)
        var page = createTemporaryObject(collectionC, holder, {})
        verify(page, "the collection page was not created")
        page.activeTab = tab
        settle(holder)
        return page
    }

    function makeNowPlaying() {
        var host = createTemporaryObject(nowPlayingHost, testCase,
                                         { width: 1100, height: 900 })
        verify(host, "the Now Playing host window was not created")
        host.visible = true
        waitForRendering(host.contentItem)
        return host
    }

    // The tiles on a collection grid, found through the right-click area
    // every MediaCard declares. Its parent is the card.
    function cardsOn(page) {
        var out = []
        collectNamed(page, "cardMenuArea", out)
        var cards = []
        for (var i = 0; i < out.length; ++i) cards.push(out[i].parent)
        return cards
    }

    function collectNamed(item, objectName, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            if (c.objectName === objectName) out.push(c)
            collectNamed(c, objectName, out)
        }
        return out
    }

    function named(item, objectName) {
        var out = []
        collectNamed(item, objectName, out)
        return out.length > 0 ? out[0] : null
    }

    function menuItemNamed(menu, objectName) {
        for (var i = 0; i < menu.count; ++i) {
            var it = menu.itemAt(i)
            if (it && it.objectName === objectName) return it
        }
        return null
    }

    function clickCenter(item) {
        mouseClick(item, Math.round(item.width / 2), Math.round(item.height / 2))
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        player.setCurrentTrackForTest({})
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        pins.setItemsForTest([])
        library.setEntriesForTest([])
        // Clears the three favourite maps, the refusal switch and the call log.
        bridge.resetForTest()
        bridge.setFavoriteAlbumsForTest([])
        bridge.setFavoriteArtistsForTest([])
        bridge.setFavoriteTracksListForTest([])
        bridge.setUserPlaylistsForTest([])
        bridge.setMixFavoriteForTest(testCase.mixId, false)
        // One shared tool tip serves the whole window, so a leftover from the
        // last test would pass for the next one's message.
        testCase.ToolTip.toolTip.close()
    }

    // ── the fixture itself ───────────────────────────────────────────────

    // Everything below asks the stub to refuse. If the switch stopped
    // refusing, the state half of those tests would still pass, so the switch
    // gets its own test against the bridge alone.
    function test_the_stub_can_refuse_at_all() {
        var answers = []
        bridge.setFavoriteOkForTest(false)
        bridge.addTrackFavorite(testCase.trackId, function (ok) { answers.push(ok) })
        tryVerify(function () { return answers.length === 1 }, 2000,
                  "a refused add never answered at all")
        compare(answers[0], false, "the refusal switch answered true")
        compare(bridge.isTrackFavorite(testCase.trackId), false,
                "a refused add wrote the cache anyway, so no test here can tell "
                + "a refusal from a success")

        // And the other way, so a switch that always answers false fails too.
        bridge.setFavoriteOkForTest(true)
        bridge.addTrackFavorite(testCase.trackId, function (ok) { answers.push(ok) })
        tryVerify(function () { return answers.length === 2 }, 2000,
                  "an accepted add never answered")
        compare(answers[1], true, "the switch refuses even when told not to")
        compare(bridge.isTrackFavorite(testCase.trackId), true,
                "an accepted add did not write the cache")
    }

    // A removal has to take the row out of the list the grids draw from as
    // well as flip the id map, or the tile tests below could not fail.
    function test_an_accepted_removal_empties_the_grid_list() {
        bridge.setFavoriteAlbumsForTest([makeAlbumRow()])
        compare(bridge.searchFavoriteAlbums("").length, 1, "the fixture seeded no album")
        bridge.removeAlbumFavorite(testCase.albumId, function (ok) {})
        tryVerify(function () { return bridge.searchFavoriteAlbums("").length === 0 }, 2000,
                  "an accepted removal left the album in the list the grid reads")
    }

    // ── PlayerBar: the heart on the bar ──────────────────────────────────

    function test_the_bar_reports_a_refused_like() {
        player.setCurrentTrackForTest(makeTrack())
        var bar = makeBar()
        var btn = named(bar, "playerLikeButton")
        verify(btn, "the bar drew no like button")
        compare(bar.isLiked, false, "the fixture starts with the song already liked")
        compare(btn.icon, "heart", "an unliked song must not draw a filled heart")

        bridge.setFavoriteOkForTest(false)
        clickCenter(btn)

        tryVerify(function () { return bar.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused like from the bar said nothing at all")
        compare(bar.favoriteAction.lastMessage, testCase.likeFailed,
                "the bar said the wrong thing about a refused like")
        compare(bridge.lastFavoriteCallForTest(), "addTrack:" + testCase.trackId,
                "the bar sent the wrong call")
        // Nothing is set optimistically, so nothing may have moved.
        compare(bar.isLiked, false, "a refused like filled the heart anyway")
        compare(btn.icon, "heart", "a refused like drew a filled heart")
    }

    function test_the_bar_says_nothing_when_the_like_lands() {
        player.setCurrentTrackForTest(makeTrack())
        var bar = makeBar()
        var btn = named(bar, "playerLikeButton")
        verify(btn, "the bar drew no like button")

        clickCenter(btn)

        tryVerify(function () { return bar.isLiked }, 2000,
                  "an accepted like never filled the heart")
        compare(btn.icon, "heart-filled", "the filled heart is the confirmation")
        compare(bar.favoriteAction.lastMessage, "",
                "the bar reported a successful like as a failure")
        compare(bridge.lastFavoriteCallForTest(), "addTrack:" + testCase.trackId,
                "the bar sent the wrong call")
    }

    function test_the_bar_reports_a_refused_unlike_differently() {
        bridge.setTrackFavoriteForTest(testCase.trackId, true)
        player.setCurrentTrackForTest(makeTrack())
        var bar = makeBar()
        var btn = named(bar, "playerLikeButton")
        verify(btn, "the bar drew no like button")
        compare(bar.isLiked, true, "the fixture did not start from a liked song, "
                + "so there is no unlike to refuse")

        bridge.setFavoriteOkForTest(false)
        clickCenter(btn)

        tryVerify(function () { return bar.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused unlike from the bar said nothing at all")
        compare(bar.favoriteAction.lastMessage, testCase.unlikeFailed,
                "a refused unlike must not be reported as a refused like")
        compare(bridge.lastFavoriteCallForTest(), "removeTrack:" + testCase.trackId,
                "a liked song's heart must send a remove, not an add")
        compare(bar.isLiked, true, "a refused unlike emptied the heart anyway")
        compare(btn.icon, "heart-filled", "a refused unlike drew an empty heart")
    }

    // The message has to reach the screen as well as the property the other
    // tests read. ToolTip.show() writes to the one shared tool tip of the
    // anchor's window, which here is this TestCase's.
    function test_a_refusal_reaches_the_screen_and_goes_away() {
        player.setCurrentTrackForTest(makeTrack())
        var bar = makeBar()
        var btn = named(bar, "playerLikeButton")
        var tip = testCase.ToolTip.toolTip
        verify(tip, "there is no shared tool tip to say anything with")
        verify(!tip.visible, "the tool tip was already up before the press")

        bridge.setFavoriteOkForTest(false)
        clickCenter(btn)

        tryVerify(function () { return tip.visible }, 2000,
                  "a refused like never reached the screen")
        compare(tip.text, testCase.likeFailed, "the tool tip said something else")
        verify(!tip.activeFocus, "the refusal took focus")
        verify(!tip.modal, "the refusal blocked the window")
        tryVerify(function () { return !tip.visible }, 5000,
                  "the refusal never went away on its own")
    }

    function test_an_accepted_like_puts_nothing_on_the_screen() {
        player.setCurrentTrackForTest(makeTrack())
        var bar = makeBar()
        var btn = named(bar, "playerLikeButton")
        var tip = testCase.ToolTip.toolTip

        clickCenter(btn)

        tryVerify(function () { return bar.isLiked }, 2000,
                  "an accepted like never filled the heart")
        // A tool tip comes up only after the attached delay of the item it is
        // anchored to, and the longest one in this app is 600ms. The wait has to
        // outlast it, or the check passes while the tool tip is on its way.
        wait(1200)
        verify(!tip.visible, "a successful like put a tool tip on the screen: "
               + tip.text)
    }

    // ── TrackRow: Like / Unlike in the row menu ──────────────────────────

    function test_the_row_menu_reports_a_refused_like() {
        var row = makeRow()
        row.openMenu()
        var menu = row.rowMenu
        verify(menu, "the row built no menu")
        var item = menuItemNamed(menu, "likeMenuItem")
        verify(item, "the row menu has no Like entry")
        compare(item.text, qsTranslate("TrackRow", "Like", "verb, add to favourites"),
                "the fixture starts from a liked song, so this is not a Like")

        bridge.setFavoriteOkForTest(false)
        item.triggered()
        menu.close()

        tryVerify(function () { return row.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused like from the row menu said nothing at all")
        compare(row.favoriteAction.lastMessage, testCase.likeFailed,
                "the row said the wrong thing about a refused like")
        compare(bridge.lastFavoriteCallForTest(), "addTrack:" + testCase.trackId,
                "the row sent the wrong call")
        compare(row.isLiked, false, "a refused like marked the row as liked")
    }

    function test_the_row_menu_reports_a_refused_unlike() {
        bridge.setTrackFavoriteForTest(testCase.trackId, true)
        var row = makeRow()
        compare(row.isLiked, true, "the fixture did not start from a liked song")
        row.openMenu()
        var menu = row.rowMenu
        var item = menuItemNamed(menu, "likeMenuItem")
        verify(item, "the row menu has no Unlike entry")
        compare(item.text, qsTranslate("TrackRow", "Unlike", "verb, remove from favourites"),
                "a liked row must offer the undo")

        bridge.setFavoriteOkForTest(false)
        item.triggered()
        menu.close()

        tryVerify(function () { return row.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused unlike from the row menu said nothing at all")
        compare(row.favoriteAction.lastMessage, testCase.unlikeFailed,
                "a refused unlike must not be reported as a refused like")
        compare(bridge.lastFavoriteCallForTest(), "removeTrack:" + testCase.trackId,
                "a liked row must send a remove, not an add")
        compare(row.isLiked, true, "a refused unlike un-liked the row anyway")
    }

    function test_the_row_menu_says_nothing_when_the_like_lands() {
        var row = makeRow()
        row.openMenu()
        var item = menuItemNamed(row.rowMenu, "likeMenuItem")
        item.triggered()
        row.rowMenu.close()

        tryVerify(function () { return row.isLiked }, 2000,
                  "an accepted like never reached the row")
        compare(row.favoriteAction.lastMessage, "",
                "the row reported a successful like as a failure")
    }

    // ── AlbumPage: the Save pill ─────────────────────────────────────────

    function test_the_album_page_reports_a_refused_save() {
        var page = makeAlbumPage()
        var pill = named(page, "albumSavePill")
        verify(pill, "the album hero drew no Save pill")
        compare(page.isSaved, false, "the fixture starts with the album already saved")
        compare(pill.text, qsTranslate("AlbumPage", "Save",
                                       "verb, add album to the library"))

        bridge.setFavoriteOkForTest(false)
        clickCenter(pill)

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused save said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.saveFailed,
                "the album page said the wrong thing about a refused save")
        compare(bridge.lastFavoriteCallForTest(), "addAlbum:" + testCase.albumId,
                "the album page sent the wrong call")
        compare(page.isSaved, false, "a refused save marked the album as saved")
        compare(pill.text, qsTranslate("AlbumPage", "Save",
                                       "verb, add album to the library"),
                "a refused save turned the pill into Saved")
    }

    function test_the_album_page_says_nothing_when_the_save_lands() {
        var page = makeAlbumPage()
        var pill = named(page, "albumSavePill")

        clickCenter(pill)

        tryVerify(function () { return page.isSaved }, 2000,
                  "an accepted save never reached the pill")
        compare(pill.text, qsTranslate("AlbumPage", "Saved",
                                       "state, album is in the library"),
                "the pill reading Saved is the confirmation")
        compare(page.favoriteAction.lastMessage, "",
                "the album page reported a successful save as a failure")
    }

    function test_the_album_page_reports_a_refused_removal() {
        bridge.setAlbumFavoriteForTest(testCase.albumId, true)
        var page = makeAlbumPage()
        var pill = named(page, "albumSavePill")
        compare(page.isSaved, true, "the fixture did not start from a saved album, "
                + "so there is no removal to refuse")

        bridge.setFavoriteOkForTest(false)
        clickCenter(pill)

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused removal said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.unsaveFailed,
                "a refused removal must not be reported as a refused save")
        compare(bridge.lastFavoriteCallForTest(), "removeAlbum:" + testCase.albumId,
                "a saved album's pill must send a remove, not an add")
        compare(page.isSaved, true, "a refused removal un-saved the album anyway")
    }

    // ── MixPage: the Save pill ───────────────────────────────────────────
    // The pill reads its state back out of the bridge and never writes it,
    // so a refusal has nothing to undo, only something to say.

    function test_the_mix_page_draws_a_save_pill_at_all() {
        var page = makeMixPage()
        var pill = named(page, "mixSavePill")
        verify(pill, "the mix hero drew no Save pill, so a mix still cannot be saved")
        verify(pill.width > 0 && pill.height > 0, "the Save pill has no size")
        compare(pill.enabled, true, "the pill is dead on a page that knows its mix")
    }

    function test_the_mix_page_reports_a_refused_save() {
        var page = makeMixPage()
        var pill = named(page, "mixSavePill")
        compare(page.isSaved, false, "the fixture starts with the mix already saved")
        compare(pill.text, qsTranslate("MixPage", "Save", "verb, add mix to the library"))

        bridge.setFavoriteOkForTest(false)
        clickCenter(pill)

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused save said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.mixSaveFailed,
                "the mix page said the wrong thing about a refused save")
        compare(bridge.lastFavoriteCallForTest(), "addMix:" + testCase.mixId,
                "the mix page sent the wrong call")
        compare(page.isSaved, false, "a refused save marked the mix as saved")
        compare(pill.text, qsTranslate("MixPage", "Save", "verb, add mix to the library"),
                "a refused save turned the pill into Saved")
    }

    function test_the_mix_page_says_nothing_when_the_save_lands() {
        var page = makeMixPage()
        var pill = named(page, "mixSavePill")

        clickCenter(pill)

        tryVerify(function () { return page.isSaved }, 2000,
                  "an accepted save never reached the pill")
        compare(pill.text, qsTranslate("MixPage", "Saved", "state, mix is in the library"),
                "the pill reading Saved is the confirmation")
        compare(page.favoriteAction.lastMessage, "",
                "the mix page reported a successful save as a failure")
    }

    // A mix that is already saved has to offer the way back out, and the
    // press has to send a remove.
    function test_an_already_saved_mix_offers_the_way_out() {
        bridge.setMixFavoriteForTest(testCase.mixId, true)
        var page = makeMixPage()
        var pill = named(page, "mixSavePill")
        compare(page.isSaved, true,
                "a mix already in the account's favourites read as unsaved")
        compare(pill.text, qsTranslate("MixPage", "Saved", "state, mix is in the library"))

        clickCenter(pill)

        tryVerify(function () { return !page.isSaved }, 2000,
                  "the mix could not be unsaved, which is the whole complaint")
        compare(bridge.lastFavoriteCallForTest(), "removeMix:" + testCase.mixId,
                "a saved mix's pill must send a remove, not an add")
        compare(page.favoriteAction.lastMessage, "",
                "an accepted removal was reported as a failure")
    }

    function test_the_mix_page_reports_a_refused_removal() {
        bridge.setMixFavoriteForTest(testCase.mixId, true)
        var page = makeMixPage()
        var pill = named(page, "mixSavePill")
        compare(page.isSaved, true, "the fixture did not start from a saved mix, "
                + "so there is no removal to refuse")

        bridge.setFavoriteOkForTest(false)
        clickCenter(pill)

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused removal said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.mixUnsaveFailed,
                "a refused removal must not be reported as a refused save")
        compare(bridge.lastFavoriteCallForTest(), "removeMix:" + testCase.mixId,
                "a saved mix's pill must send a remove, not an add")
        compare(page.isSaved, true, "a refused removal unsaved the mix anyway")
    }

    // A page that does not know which mix it is has nothing to save, and must
    // not send a call for the empty id.
    function test_a_mix_page_with_no_id_cannot_be_saved() {
        var holder = makeHolder()
        var page = createTemporaryObject(mixC, holder, {})
        settle(holder)
        var pill = named(page, "mixSavePill")
        verify(pill, "the hero drew no Save pill")
        compare(pill.enabled, false, "the pill is live on a page with no mix")
        compare(page.isSaved, false)
    }

    // Saving and pinning are two different things. The pill is Tidal's own
    // favourites list, shared with every other client. The right-click menu
    // is PinStore, which is local to this machine.
    function test_saving_a_mix_is_not_pinning_it() {
        var page = makeMixPage()
        var pill = named(page, "mixSavePill")

        clickCenter(pill)
        tryVerify(function () { return page.isSaved }, 2000, "the save never landed")

        page.showHeroPinMenu(10, 10)
        tryVerify(function () { return page.pinMenu.visible }, 2000, "no hero pin menu")
        var pin = page.pinMenu.pinItem
        verify(pin, "the hero menu has no pin entry")
        compare(pin.text, qsTranslate("ContextMenu", "Pin", "verb, pin to the sidebar"),
                "saving the mix also pinned it, which is a different list entirely")
        verify(pin.text !== pill.text, "the pin entry and the Save pill read the same")
        verify(pin.iconName !== pill.icon,
               "the pin and the favourite draw the same glyph")
        page.pinMenu.close()

        // And the other way: the local pin must not touch the account.
        compare(bridge.lastFavoriteCallForTest(), "addMix:" + testCase.mixId,
                "something other than the pill talked to the favourites API")
    }

    // ── ArtistPage: the Follow pill ──────────────────────────────────────

    function test_the_artist_page_reports_a_refused_follow() {
        var page = makeArtistPage()
        var pill = named(page, "artistFollowPill")
        verify(pill, "the artist hero drew no Follow pill")
        compare(page.isFollowing, false, "the fixture starts already following")
        compare(pill.text, qsTranslate("ArtistPage", "Follow"))

        bridge.setFavoriteOkForTest(false)
        clickCenter(pill)

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused follow said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.followFailed,
                "the artist page said the wrong thing about a refused follow")
        compare(bridge.lastFavoriteCallForTest(), "addArtist:" + testCase.artistId,
                "the artist page sent the wrong call")
        compare(page.isFollowing, false, "a refused follow marked the artist as followed")
        compare(pill.text, qsTranslate("ArtistPage", "Follow"),
                "a refused follow turned the pill into Following")
    }

    function test_the_artist_page_says_nothing_when_the_follow_lands() {
        var page = makeArtistPage()
        var pill = named(page, "artistFollowPill")

        clickCenter(pill)

        tryVerify(function () { return page.isFollowing }, 2000,
                  "an accepted follow never reached the pill")
        compare(pill.text, qsTranslate("ArtistPage", "Following"),
                "the pill reading Following is the confirmation")
        compare(page.favoriteAction.lastMessage, "",
                "the artist page reported a successful follow as a failure")
    }

    function test_the_artist_page_reports_a_refused_unfollow() {
        bridge.setArtistFavoriteForTest(testCase.artistId, true)
        var page = makeArtistPage()
        var pill = named(page, "artistFollowPill")
        compare(page.isFollowing, true, "the fixture did not start from a followed "
                + "artist, so there is no unfollow to refuse")

        bridge.setFavoriteOkForTest(false)
        clickCenter(pill)

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused unfollow said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.unfollowFailed,
                "a refused unfollow must not be reported as a refused follow")
        compare(bridge.lastFavoriteCallForTest(), "removeArtist:" + testCase.artistId,
                "a followed artist's pill must send a remove, not an add")
        compare(page.isFollowing, true, "a refused unfollow stopped following anyway")
    }

    // ── NowPlayingPage: the heart among the transport controls ───────────

    function test_now_playing_reports_a_refused_like() {
        player.setCurrentTrackForTest(makeTrack())
        var host = makeNowPlaying()
        var page = host.page
        var btn = named(page, "nowPlayingLikeButton")
        verify(btn, "Now Playing drew no like button")
        compare(page.isLiked, false, "the fixture starts with the song already liked")

        bridge.setFavoriteOkForTest(false)
        clickCenter(btn)

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused like on Now Playing said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.likeFailed,
                "Now Playing said the wrong thing about a refused like")
        compare(bridge.lastFavoriteCallForTest(), "addTrack:" + testCase.trackId,
                "Now Playing sent the wrong call")
        compare(page.isLiked, false, "a refused like filled the heart anyway")
        compare(btn.icon, "heart", "a refused like drew a filled heart")
    }

    function test_now_playing_reports_a_refused_unlike() {
        bridge.setTrackFavoriteForTest(testCase.trackId, true)
        player.setCurrentTrackForTest(makeTrack())
        var host = makeNowPlaying()
        var page = host.page
        var btn = named(page, "nowPlayingLikeButton")
        compare(page.isLiked, true, "the fixture did not start from a liked song")

        bridge.setFavoriteOkForTest(false)
        clickCenter(btn)

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused unlike on Now Playing said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.unlikeFailed,
                "a refused unlike must not be reported as a refused like")
        compare(bridge.lastFavoriteCallForTest(), "removeTrack:" + testCase.trackId,
                "a liked song's heart must send a remove, not an add")
        compare(page.isLiked, true, "a refused unlike emptied the heart anyway")
    }

    function test_now_playing_says_nothing_when_the_like_lands() {
        player.setCurrentTrackForTest(makeTrack())
        var host = makeNowPlaying()
        var page = host.page
        var btn = named(page, "nowPlayingLikeButton")

        clickCenter(btn)

        tryVerify(function () { return page.isLiked }, 2000,
                  "an accepted like never filled the heart")
        compare(btn.icon, "heart-filled", "the filled heart is the confirmation")
        compare(page.favoriteAction.lastMessage, "",
                "Now Playing reported a successful like as a failure")
    }

    // ── CollectionPage: the two grids' Remove rows ───────────────────────
    // These two sites are removals only: a tile in these grids is in the
    // library by definition, so the host hands the helper true at both.

    function test_the_collection_album_grid_reports_a_refused_removal() {
        bridge.setFavoriteAlbumsForTest([makeAlbumRow()])
        var page = makeCollection(1)
        var cards = cardsOn(page)
        compare(cards.length, 1, "the albums grid drew no tile")
        var menu = cards[0].pinMenu
        verify(menu, "the album tile has no menu")

        bridge.setFavoriteOkForTest(false)
        menu.removeItem.triggered()

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused removal from the albums grid said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.unsaveFailed,
                "the albums grid said the wrong thing about a refused removal")
        compare(bridge.lastFavoriteCallForTest(), "removeAlbum:" + testCase.albumId,
                "the albums grid sent the wrong call")
        compare(cardsOn(page).length, 1,
                "a refused removal took the tile out of the grid anyway")
    }

    function test_the_collection_album_grid_says_nothing_when_it_lands() {
        bridge.setFavoriteAlbumsForTest([makeAlbumRow()])
        var page = makeCollection(1)
        var cards = cardsOn(page)
        compare(cards.length, 1, "the albums grid drew no tile")

        cards[0].pinMenu.removeItem.triggered()

        tryVerify(function () { return cardsOn(page).length === 0 }, 2000,
                  "an accepted removal left the tile in the grid")
        compare(page.favoriteAction.lastMessage, "",
                "the albums grid reported a successful removal as a failure")
    }

    function test_the_collection_artist_grid_reports_a_refused_unfollow() {
        bridge.setFavoriteArtistsForTest([makeArtistRow()])
        var page = makeCollection(2)
        var cards = cardsOn(page)
        compare(cards.length, 1, "the artists grid drew no tile")
        var menu = cards[0].pinMenu
        verify(menu, "the artist tile has no menu")

        bridge.setFavoriteOkForTest(false)
        menu.removeItem.triggered()

        tryVerify(function () { return page.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refused unfollow from the artists grid said nothing at all")
        compare(page.favoriteAction.lastMessage, testCase.unfollowFailed,
                "the artists grid said the wrong thing about a refused unfollow")
        compare(bridge.lastFavoriteCallForTest(), "removeArtist:" + testCase.artistId,
                "the artists grid sent the wrong call")
        compare(cardsOn(page).length, 1,
                "a refused unfollow took the tile out of the grid anyway")
    }

    function test_the_collection_artist_grid_says_nothing_when_it_lands() {
        bridge.setFavoriteArtistsForTest([makeArtistRow()])
        var page = makeCollection(2)
        compare(cardsOn(page).length, 1, "the artists grid drew no tile")

        cardsOn(page)[0].pinMenu.removeItem.triggered()

        tryVerify(function () { return cardsOn(page).length === 0 }, 2000,
                  "an accepted unfollow left the tile in the grid")
        compare(page.favoriteAction.lastMessage, "",
                "the artists grid reported a successful unfollow as a failure")
    }

    // ── the shared helper's own edges ────────────────────────────────────

    // A row whose payload carried no usable id offers the action but must not
    // send anything, the way every other id-keyed action on the row behaves.
    function test_a_missing_id_sends_nothing_and_says_nothing() {
        var bar = makeBar()
        bridge.setFavoriteOkForTest(false)
        bar.favoriteAction.toggleTrack(0, false, bar)
        bar.favoriteAction.toggleAlbum(0, false, bar)
        bar.favoriteAction.toggleArtist(0, false, bar)
        wait(100)
        compare(bridge.favoriteCallsForTest(), 0,
                "an id of 0 reached the bridge: " + bridge.lastFavoriteCallForTest())
        compare(bar.favoriteAction.lastMessage, "",
                "an id of 0 produced a message for something that was never asked")
    }

    // The message is recorded even with no anchor to draw it on. A grid tile can
    // be destroyed between the press and the reply, and the record of what
    // happened must not depend on the tool tip having had somewhere to go.
    function test_a_refusal_without_an_anchor_is_still_recorded() {
        var bar = makeBar()
        bridge.setFavoriteOkForTest(false)
        bar.favoriteAction.toggleTrack(testCase.trackId, false, null)
        tryVerify(function () { return bar.favoriteAction.lastMessage.length > 0 }, 2000,
                  "a refusal with no anchor was dropped entirely")
        compare(bar.favoriteAction.lastMessage, testCase.likeFailed)
    }

    // A reply that never arrives leaves the callback's argument undefined,
    // which has to count as refused.
    function test_an_undefined_answer_counts_as_refused() {
        var bar = makeBar()
        bar.favoriteAction._refused(undefined, bar, "nope")
        compare(bar.favoriteAction.lastMessage, "nope",
                "an undefined answer was taken for a success")
        bar.favoriteAction._refused(true, bar, "nope again")
        compare(bar.favoriteAction.lastMessage, "nope",
                "a true answer was taken for a failure")
    }

    // The record belongs to the press in flight: a refusal followed by a
    // success must not leave the old message standing.
    function test_a_new_press_clears_the_last_refusal() {
        player.setCurrentTrackForTest(makeTrack())
        var bar = makeBar()
        var btn = named(bar, "playerLikeButton")

        bridge.setFavoriteOkForTest(false)
        clickCenter(btn)
        tryVerify(function () { return bar.favoriteAction.lastMessage.length > 0 }, 2000,
                  "the first, refused press said nothing")

        bridge.setFavoriteOkForTest(true)
        clickCenter(btn)
        tryVerify(function () { return bar.isLiked }, 2000,
                  "the second press never landed")
        compare(bar.favoriteAction.lastMessage, "",
                "the refusal from the first press outlived it")
    }
}
