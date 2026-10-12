// AlbumPage's row "Other versions" and what its facts line says of a Dolby
// Atmos only product. Tidal lists every product of a record under its own id,
// and its own album page names the others. The stub bridge is the one from
// tests/TestStubs.h. Every id, title and name is invented.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "AlbumVersions"
    when: windowShown
    width: 1000
    height: 950
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible, so a shown row would read as hidden.
    visible: true

    readonly property int albumId:      900400001   // explicit, hi-res stereo
    readonly property int cleanId:      900400002   // clean, hi-res stereo
    readonly property int atmosId:      900400003   // explicit, Dolby Atmos only
    readonly property int cleanAtmosId: 900400004   // clean, Dolby Atmos only
    readonly property int plainId:      900400005   // explicit, 16-bit stereo
    readonly property int otherAlbumId: 900400050

    readonly property var stereo:   ["STEREO"]
    readonly property var atmos:    ["DOLBY_ATMOS"]
    readonly property var lossless: ["LOSSLESS"]
    readonly property var hiRes:    ["LOSSLESS", "HIRES_LOSSLESS"]

    Component { id: holderC; Item { } }
    Component { id: albumC;  AlbumPage { anchors.fill: parent } }

    // A host with a router in it: a card opens its album through
    // Window.window.navigate(), which the harness's own window does not have.
    Component {
        id: winHostC
        Window {
            width: 960
            height: 900
            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}
            property alias page: hostedAlbum
            AlbumPage { id: hostedAlbum; anchors.fill: parent }
        }
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

    // One product of the record, with the keys TidalBridge::albumToMap writes.
    function product(id, explicit_, modes, tags) {
        return { id: id, title: "Salzwiesen", artists: "Marit Solvang", artistId: 900400900,
                 coverUrl: "cover-" + id, coverUrl640: "cover-" + id, year: "2031",
                 releaseDate: "2031-03-14", numTracks: 9, duration: 2140, type: "ALBUM",
                 quality: modes[0] === "DOLBY_ATMOS" ? "LOW" : "LOSSLESS",
                 explicit_: explicit_, audioModes: modes, mediaTags: tags }
    }

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 900410001 + i, title: "Stück " + (i + 1), artists: "Marit Solvang",
                       artistId: 900400900, duration: 215, durationStr: "3:35" })
        return out
    }

    // The clean hi-res one and the two Dolby Atmos ones: what Tidal lists for
    // an explicit hi-res album.
    function theOtherThree() {
        return [ product(testCase.cleanId,      false, testCase.stereo, testCase.hiRes),
                 product(testCase.atmosId,      true,  testCase.atmos,  testCase.atmos),
                 product(testCase.cleanAtmosId, false, testCase.atmos,  testCase.atmos) ]
    }

    // Opens a page on `album` with `n` tracks. The versions were stored first.
    function openAlbum(album, n, width) {
        bridge.setAlbumForTest(album, makeTracks(n === undefined ? 3 : n))
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = width || 960
        holder.height = 900
        var page = createTemporaryObject(albumC, holder, {})
        verify(page, "the album page was not created")
        page.albumId = album.id
        settle(page)
        return page
    }

    function openExplicitHiRes(n, width) {
        return openAlbum(product(testCase.albumId, true, testCase.stereo, testCase.hiRes), n, width)
    }

    function rowOf(page) {
        var row = findChild(page, "albumOtherVersions")
        verify(row, "the album page has no Other versions row at all")
        return row
    }

    function cardsOf(row) {
        var list = findChild(row, "sectionList")
        verify(list, "the row has no list of cards")
        var out = []
        for (var i = 0; i < list.count; ++i) {
            var card = list.itemAtIndex(i)
            verify(card, "card " + i + " of the row was not drawn")
            out.push(card)
        }
        return out
    }

    function textsOf(row, name) {
        var cards = cardsOf(row)
        var out = []
        for (var i = 0; i < cards.length; ++i) out.push(findChild(cards[i], name).text)
        return out
    }

    function word(source) { return qsTranslate("AlbumPage", source) }
    // The two words carry a note for the translator, which is part of their key.
    readonly property string explicitWord:
        qsTranslate("AlbumPage", "Explicit", "a version of an album with its lyrics as recorded")
    readonly property string cleanWord:
        qsTranslate("AlbumPage", "Clean", "a version of an album with its lyrics edited")

    function cleanup() {
        bridge.resetForTest()
        bridge.resetOtherVersionsForTest()
        player.playTracks([], 0)
        player.setPlaybackSource("", "", "")
    }

    // ── the row ──────────────────────────────────────────────────────────────

    function test_the_row_names_the_other_versions() {
        bridge.setOtherVersionsForTest(theOtherThree())
        var page = openExplicitHiRes()

        compare(bridge.otherVersionsFetchesForTest(), 1,
                "the page did not ask for the other versions of its album exactly once")
        compare(bridge.lastOtherVersionsFetchedForTest(), testCase.albumId,
                "the page asked for the versions of another album")

        var row = rowOf(page)
        compare(row.visible, true, "Tidal named three other versions and the page shows no row")
        compare(row.title, word("Other versions"))
        compare(textsOf(row, "cardTitle"), ["Salzwiesen", "Salzwiesen", "Salzwiesen"])

        // The page's album is explicit and one of the others is clean, so each
        // card says which it is, then Dolby Atmos or its quality.
        var sep = " • "
        compare(textsOf(row, "cardSubtitle"),
                [ testCase.cleanWord    + sep + player.qualityLabel("HI_RES_LOSSLESS"),
                  testCase.explicitWord + sep + word("Dolby Atmos"),
                  testCase.cleanWord    + sep + word("Dolby Atmos") ])
    }

    // Versions that are all explicit, or all clean, differ in their sound alone.
    function test_versions_that_agree_on_explicit_name_only_the_sound() {
        bridge.setOtherVersionsForTest([
            product(testCase.atmosId, true, testCase.atmos,  testCase.atmos),
            product(testCase.plainId, true, testCase.stereo, testCase.lossless) ])
        var page = openExplicitHiRes()

        var row = rowOf(page)
        compare(row.visible, true)
        compare(textsOf(row, "cardSubtitle"),
                [ word("Dolby Atmos"), player.qualityLabel("LOSSLESS") ])
    }

    // The album on the page counts: clean, while every other version is
    // explicit, still makes the cards say so.
    function test_the_album_on_the_page_decides_with_the_others() {
        bridge.setOtherVersionsForTest([
            product(testCase.albumId, true, testCase.stereo, testCase.hiRes),
            product(testCase.atmosId, true, testCase.atmos,  testCase.atmos) ])
        var page = openAlbum(product(testCase.cleanId, false, testCase.stereo, testCase.hiRes))

        compare(textsOf(rowOf(page), "cardSubtitle"),
                [ testCase.explicitWord + " • " + player.qualityLabel("HI_RES_LOSSLESS"),
                  testCase.explicitWord + " • " + word("Dolby Atmos") ])
    }

    function test_no_row_when_tidal_names_no_other_version() {
        bridge.setOtherVersionsForTest([])
        var page = openExplicitHiRes()

        compare(bridge.lastOtherVersionsFetchedForTest(), testCase.albumId,
                "the page never asked for the other versions of its album")
        var row = rowOf(page)
        compare(row.visible, false, "a row with no card in it is on the page")

        // The end of the page is what it was: the last track and a margin.
        var list = findChild(page, "albumTracksList")
        compare(list.count, 3)
        compare(list.footerItem.height, 32)
    }

    // The request failing says nothing and leaves the rest of the page alone.
    function test_a_failed_request_shows_no_row_and_says_nothing() {
        bridge.setOtherVersionsForTest(theOtherThree(), "server replied: Not Found")
        var page = openExplicitHiRes()

        compare(bridge.lastOtherVersionsFetchedForTest(), testCase.albumId,
                "the page never asked for the other versions of its album")
        compare(rowOf(page).visible, false, "a refused request left a row on the page")

        compare(page.loadError, "", "the refusal was taken for the album's own")
        compare(page.loadFailed, false)
        compare(page.loading, false)
        compare(findChild(page, "albumLoadError").visible, false,
                "the page says the album is not available")
        var list = findChild(page, "albumTracksList")
        compare(list.visible, true)
        compare(list.count, 3, "the tracks went with the refused request")
        compare(page.albumData.title, "Salzwiesen")
    }

    // ── an answer that comes late ────────────────────────────────────────────

    function test_a_late_answer_for_the_album_left_is_ignored() {
        bridge.setOtherVersionsForTest(theOtherThree())
        bridge.setDeferOtherVersionsForTest(true)
        var page = openExplicitHiRes()
        compare(bridge.pendingOtherVersionsForTest(), 1, "the first answer was not held")
        var row = rowOf(page)
        compare(row.visible, false)

        // The next album has no other version and is answered at once.
        bridge.setDeferOtherVersionsForTest(false)
        bridge.setOtherVersionsForTest([])
        bridge.setAlbumForTest({ id: testCase.otherAlbumId, title: "Priel", artists: "Marit Solvang",
                                 quality: "LOSSLESS", numTracks: 2 }, makeTracks(2))
        page.albumId = testCase.otherAlbumId
        settle(page)
        compare(bridge.lastOtherVersionsFetchedForTest(), testCase.otherAlbumId)
        compare(row.visible, false)

        bridge.flushOtherVersionsForTest()
        settle(page)
        compare(page.otherVersions.length, 0,
                "the versions of the album left were put under the one on the page")
        compare(row.visible, false)
    }

    // Until the next album's answer is in, the row of the one left is gone.
    function test_the_row_goes_with_the_album_it_belongs_to() {
        bridge.setOtherVersionsForTest(theOtherThree())
        var page = openExplicitHiRes()
        var row = rowOf(page)
        compare(row.visible, true)

        bridge.setDeferOtherVersionsForTest(true)
        bridge.setAlbumForTest({ id: testCase.otherAlbumId, title: "Priel", artists: "Marit Solvang",
                                 quality: "LOSSLESS", numTracks: 2 }, makeTracks(2))
        page.albumId = testCase.otherAlbumId
        settle(page)
        compare(bridge.pendingOtherVersionsForTest(), 1)
        compare(row.visible, false,
                "the versions of the album left stayed under the next one while it loaded")
    }

    // ── what a card does ─────────────────────────────────────────────────────

    function test_a_click_on_a_card_opens_that_version() {
        bridge.setOtherVersionsForTest(theOtherThree())
        bridge.setAlbumForTest(product(testCase.albumId, true, testCase.stereo, testCase.hiRes),
                               makeTracks(3))
        var win = createTemporaryObject(winHostC, testCase)
        verify(win, "the host window was not created")
        win.show()
        verify(waitForRendering(win.contentItem), "the host window drew no frame")
        win.page.albumId = testCase.albumId
        settle(win.page)

        var cards = cardsOf(rowOf(win.page))
        compare(cards.length, 3)
        var art = findChild(cards[1], "cardArt")
        verify(art, "the card has no artwork to click")
        var at = art.mapToItem(win.contentItem, art.width / 2, art.height / 2)
        verify(at.y > 0 && at.y < win.height, "the row is outside the window: y " + at.y)
        mouseClick(art, art.width / 2, art.height / 2)

        compare(win.navCalls.length, 1, "the click opened nothing")
        compare(win.navCalls[0].page, "album")
        compare(win.navCalls[0].params.albumId, testCase.atmosId)
    }

    // A card's play button plays that version and says where it plays from.
    function test_playing_a_card_plays_that_version() {
        bridge.setOtherVersionsForTest(theOtherThree())
        var page = openExplicitHiRes()
        var row = rowOf(page)

        row.itemPlayClicked(0, row.items[0])

        compare(bridge.lastAlbumTracksFetchedForTest(), testCase.cleanId)
        compare(player.sourceType, "album")
        compare(player.sourceId, "" + testCase.cleanId)
        compare(player.queueTracks.length, 3)
    }

    // ── where the row sits ───────────────────────────────────────────────────

    // Below the last track, inside the list's content, and reached by the end
    // of the page: the list has to follow a footer that grew after it was laid
    // out.
    function test_the_row_is_the_end_of_the_page() {
        bridge.setOtherVersionsForTest(theOtherThree())
        bridge.setDeferOtherVersionsForTest(true)
        var page = openExplicitHiRes(14)
        var list = findChild(page, "albumTracksList")
        compare(list.count, 14)
        var before = list.contentHeight

        bridge.flushOtherVersionsForTest()
        settle(page)
        var row = rowOf(page)
        compare(row.visible, true)
        verify(row.height > 200, "the row was laid out at no height: " + row.height)
        compare(row.width, list.width)
        tryVerify(function () { return list.contentHeight >= before + row.height }, 2000,
                  "the list did not grow by the row: " + before + " to " + list.contentHeight
                  + " for a row of " + row.height)

        list.positionViewAtEnd()
        settle(page)
        verify(list.atYEnd, "the list is not at its end after being sent there")

        var lastTrack = list.itemAtIndex(13)
        verify(lastTrack, "the last track is not drawn at the end of the page")
        var trackBottom = lastTrack.mapToItem(page, 0, lastTrack.height).y
        var rowTop      = row.mapToItem(page, 0, 0).y
        var rowBottom   = row.mapToItem(page, 0, row.height).y
        verify(rowTop >= trackBottom,
               "the row starts at " + rowTop + ", over the last track, which ends at " + trackBottom)
        verify(rowBottom <= page.height,
               "the row ends at " + rowBottom + ", below the page's " + page.height)
        verify(rowBottom >= page.height - 64,
               "the page ends " + (page.height - rowBottom) + " below the row")

        // Each card is whole and inside the row.
        var cards = cardsOf(row)
        compare(cards.length, 3)
        for (var i = 0; i < cards.length; ++i) {
            var top    = cards[i].mapToItem(page, 0, 0).y
            var bottom = cards[i].mapToItem(page, 0, cards[i].height).y
            compare(cards[i].width, 160)
            verify(cards[i].height > 160, "card " + i + " has no room for its two lines")
            verify(top >= rowTop && bottom <= rowBottom,
                   "card " + i + " (" + top + " to " + bottom + ") leaves the row ("
                   + rowTop + " to " + rowBottom + ")")
        }
    }

    // ── the wheel over the row ───────────────────────────────────────────────

    // One notch of the wheel with the pointer on the cards. Positive is up.
    function wheelOver(row, notches, modifiers) {
        var list = findChild(row, "sectionList")
        verify(list, "the row has no list of cards")
        mouseWheel(list, list.width / 2, list.height / 2, 0, 120 * notches,
                   Qt.NoButton, modifiers === undefined ? Qt.NoModifier : modifiers)
        wait(50)
    }

    // A short record fits the page whole, and the wheel over the row has
    // nowhere to take it.
    function test_the_wheel_over_the_row_leaves_a_page_that_fits_alone() {
        bridge.setOtherVersionsForTest(theOtherThree())
        var page = openExplicitHiRes(2)
        var list = findChild(page, "albumTracksList")
        var row = rowOf(page)
        compare(row.visible, true)
        verify(list.contentHeight <= list.height,
               "the fixture does not fit the page: " + list.contentHeight + " in " + list.height)
        var art = findChild(page, "heroArt")
        var top = list.contentY
        var artY = art.mapToItem(page, 0, 0).y

        wheelOver(row, -1)
        compare(list.contentY, top, "a notch down moved a page that fits")
        wheelOver(row, 1)
        compare(list.contentY, top, "a notch up moved a page that fits")
        compare(art.mapToItem(page, 0, 0).y, artY, "the hero is no longer where it was")
    }

    // A long record: the wheel over the row stops at the end of the page. A
    // modifier that is not the row's leaves the wheel the page's.
    function test_the_wheel_over_the_row_stops_at_the_end_of_the_page_data() {
        return [ { tag: "plain",     modifiers: Qt.NoModifier },
                 { tag: "with Ctrl", modifiers: Qt.ControlModifier } ]
    }
    function test_the_wheel_over_the_row_stops_at_the_end_of_the_page(data) {
        bridge.setOtherVersionsForTest(theOtherThree())
        var page = openExplicitHiRes(14)
        var list = findChild(page, "albumTracksList")
        var row = rowOf(page)
        list.positionViewAtEnd()
        settle(page)
        verify(list.atYEnd, "the list is not at its end after being sent there")
        var end = list.contentY
        var rowBottom = row.mapToItem(page, 0, row.height).y

        wheelOver(row, -1, data.modifiers)
        wheelOver(row, -1, data.modifiers)
        compare(list.contentY, end, "the wheel took the page past its end")
        compare(row.mapToItem(page, 0, row.height).y, rowBottom)
    }

    // And it scrolls the page: up from the end, by what the wheel asked for.
    function test_the_wheel_over_the_row_scrolls_the_page() {
        bridge.setOtherVersionsForTest(theOtherThree())
        var page = openExplicitHiRes(14)
        var list = findChild(page, "albumTracksList")
        var row = rowOf(page)
        list.positionViewAtEnd()
        settle(page)
        var end = list.contentY

        wheelOver(row, 1)
        verify(list.contentY < end, "a notch up over the row left the page where it was")
        verify(list.contentY >= list.originY, "the wheel took the page above its top")
    }

    // The wheel that moves the cards of such a row on every page moves them
    // here and leaves the page: Shift held, or a swipe more sideways than up
    // or down. Five cards do not fit a narrow pane.
    function test_the_wheel_that_is_the_rows_moves_its_cards_data() {
        return [ { tag: "Shift held",              dx: 0,    dy: -120, modifiers: Qt.ShiftModifier },
                 { tag: "more sideways than down", dx: -120, dy: -30,  modifiers: Qt.NoModifier } ]
    }
    function test_the_wheel_that_is_the_rows_moves_its_cards(data) {
        var five = theOtherThree()
        five.push(product(testCase.plainId,     true,  testCase.stereo, testCase.lossless))
        five.push(product(testCase.plainId + 1, false, testCase.stereo, testCase.lossless))
        bridge.setOtherVersionsForTest(five)
        var page = openExplicitHiRes(14, 700)
        var list = findChild(page, "albumTracksList")
        var row = rowOf(page)
        var cards = findChild(row, "sectionList")
        verify(row.overflows, "five cards fit the pane, so nothing can move")
        list.positionViewAtEnd()
        settle(page)
        var end = list.contentY
        var start = cards.contentX

        mouseWheel(cards, cards.width / 2, cards.height / 2, data.dx, data.dy,
                   Qt.NoButton, data.modifiers)
        wait(50)
        verify(cards.contentX > start, "the cards stayed where they were")
        compare(list.contentY, end, "the page moved with the cards")
    }

    // The page's own wheel handling lies over the cards and must not take
    // their hover: it is what shows a card's play button.
    function test_a_card_of_the_row_still_hovers() {
        bridge.setOtherVersionsForTest(theOtherThree())
        var page = openExplicitHiRes()
        var card = cardsOf(rowOf(page))[0]
        var art = findChild(card, "cardArt")
        var play = findChild(card, "cardPlayButton")
        verify(play, "the card has no play button")
        compare(play.visible, false)

        var p = art.mapToItem(page, art.width / 2, art.height / 2)
        mouseMove(page, p.x, p.y)
        settle(page)
        verify(play.visible, "a card of the row never sees the hover")

        mouseMove(page, -20, -20)
        settle(page)
    }

    // ── the facts line ───────────────────────────────────────────────────────

    function factsOf(page) {
        var facts = findChild(page, "albumFacts")
        verify(facts, "the album page's facts line has no name to find it by")
        return facts.text
    }

    // Tidal lists a Dolby Atmos only product as low quality. The page names
    // the product and says how it plays here.
    function test_an_atmos_only_album_says_so_and_how_it_plays() {
        var page = openAlbum(product(testCase.atmosId, true, testCase.atmos, testCase.atmos))

        var facts = factsOf(page).split(" • ")
        compare(facts[facts.length - 1], word("Dolby Atmos, plays in stereo"))
        verify(facts.indexOf(player.qualityLabel("LOW")) === -1,
               "the facts line calls a Dolby Atmos album low quality: " + factsOf(page))
    }

    function test_a_stereo_album_names_its_quality_as_before_data() {
        return [
            { tag: "lossless",  quality: "LOSSLESS", modes: ["STEREO"] },
            { tag: "low",       quality: "LOW",      modes: ["STEREO"] },
            { tag: "both modes", quality: "LOSSLESS", modes: ["STEREO", "DOLBY_ATMOS"] },
            { tag: "no modes",  quality: "LOW",      modes: [] }
        ]
    }
    function test_a_stereo_album_names_its_quality_as_before(data) {
        var album = product(testCase.albumId, true, testCase.stereo, testCase.lossless)
        album.quality    = data.quality
        album.audioModes = data.modes
        var page = openAlbum(album)

        var facts = factsOf(page).split(" • ")
        compare(facts[facts.length - 1], player.qualityLabel(data.quality))
    }
}
