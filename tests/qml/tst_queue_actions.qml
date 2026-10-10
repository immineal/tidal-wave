// The two ways into the queue: Play next goes to the front of the manual
// queue, Add to queue to its end. Both are offered on a track row's menu, a
// media card's menu and the hero header of the detail pages, and checked
// here against the same rules. The player stub from tests/TestStubs.h keeps
// its manual queue (queueManual) apart from the context and records every
// queue call (queueCalls), so a test can count calls and their arguments.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "QueueActions"
    when: windowShown
    width: 1000
    height: 700
    // TestCase declares visible: false, which would leave every child
    // unrendered, and a ToolTip never shows for an item in no window.
    visible: true

    Component { id: holderC;    Item { } }
    Component { id: ctxMenuC;   ContextMenu { } }
    Component { id: trackRowC;  TrackRow  { } }
    Component { id: mediaCardC; MediaCard { } }
    Component { id: albumC;     AlbumPage { anchors.fill: parent } }

    // ── fixtures ─────────────────────────────────────────────────────────

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i) {
            out.push({
                id:          8000 + i,
                title:       "Track " + (i + 1),
                artists:     "The Band",
                albumTitle:  "Fever Dream",
                durationStr: "3:21",
                coverUrl80:  "",
                albumId:     42,
                artistId:    7
            })
        }
        return out
    }

    function endsWith(haystack, needle) {
        return ("" + haystack).slice(-needle.length) === needle
    }

    function titlesOf(list) {
        var out = []
        for (var i = 0; i < list.length; ++i) out.push(list[i].title)
        return out.join(",")
    }

    // A MenuItem reports visible: false while its menu is shut, so whether it
    // is offered has to be asked of an open menu.
    function openCardMenu(card) {
        card.pinMenu.showPin(10, 10, card.pinKind, card.itemId,
                             card.title, card.subtitle, card.coverUrl)
        tryVerify(function () { return card.pinMenu.visible }, 2000, "the card menu did not open")
        return card.pinMenu
    }

    function openHeroMenu(page) {
        page.showHeroPinMenu(10, 10)
        tryVerify(function () { return page.pinMenu.visible }, 2000, "the hero menu did not open")
        return page.pinMenu
    }

    function indexOfItem(menu, entry) {
        for (var i = 0; i < menu.count; ++i)
            if (menu.itemAt(i) === entry) return i
        return -1
    }

    function settle(item) {
        wait(1)
        waitForRendering(item, 2000)
    }

    function makeHolder() {
        var holder = createTemporaryObject(holderC, testCase,
                                           { width: testCase.width, height: testCase.height })
        verify(holder, "holder was not created")
        return holder
    }

    // An album page carrying `n` tracks. The id is assigned first: it triggers
    // the load, and the stub answers synchronously with an empty list, which
    // would otherwise wipe the tracks straight back out again.
    function makeAlbumPage(n) {
        var holder = makeHolder()
        var page = createTemporaryObject(albumC, holder, {})
        verify(page, "the album page was not created")
        page.albumId = 42
        page.albumData = { title: "Fever Dream", artists: "The Band", coverUrl: "cdn/42.jpg" }
        page.tracks = makeTracks(n)
        settle(holder)
        return page
    }

    function makeRow(track) {
        var holder = makeHolder()
        var row = createTemporaryObject(trackRowC, holder, {
            width: 800, trackData: track, title: track.title, artists: track.artists
        })
        verify(row, "the track row was not created")
        settle(holder)
        return row
    }

    function makeCard() {
        var holder = makeHolder()
        var card = createTemporaryObject(mediaCardC, holder, {
            mediaType: "album", itemId: "42", title: "Fever Dream", subtitle: "The Band"
        })
        verify(card, "the card was not created")
        settle(holder)
        return card
    }

    function init() {
        app.setReducedMotionForTest(true)
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
        player.resetQueueCallsForTest()
        pins.setItemsForTest([])
        // The confirmation is one shared tool tip, so a leftover from the last
        // test would pass for the next one's confirmation.
        testCase.ToolTip.toolTip.close()
    }

    // ── both actions are offered, everywhere ─────────────────────────────

    function test_a_track_row_offers_both_actions() {
        var row = makeRow(makeTracks(1)[0])
        row.openMenu()
        var menu = row.rowMenu
        verify(menu, "the row built no menu")

        verify(menu.playNextItem.visible,   "a row offers no Play next")
        verify(menu.addToQueueItem.visible, "a row offers no Add to queue")
        verify(endsWith(menu.playNextItem.text,
                        qsTr("Play next", "verb, play this right after the current track")),
               "wrong Play next label: " + menu.playNextItem.text)
        verify(endsWith(menu.addToQueueItem.text,
                        qsTr("Add to queue", "verb, put this at the end of the queue")),
               "wrong Add to queue label: " + menu.addToQueueItem.text)

        // The more common intent sits first.
        verify(indexOfItem(menu, menu.playNextItem) < indexOfItem(menu, menu.addToQueueItem),
               "Add to queue is listed above Play next")
        menu.close()
    }

    function test_a_media_card_offers_both_actions() {
        var menu = openCardMenu(makeCard())
        verify(menu.playNextItem.visible,   "a card offers no Play next")
        verify(menu.addToQueueItem.visible, "a card offers no Add to queue")
        compare(menu.playNextItem.text,
                qsTr("Play next", "verb, play this right after the current track"))
        compare(menu.addToQueueItem.text,
                qsTr("Add to queue", "verb, put this at the end of the queue"))
        verify(indexOfItem(menu, menu.playNextItem) < indexOfItem(menu, menu.addToQueueItem),
               "Add to queue is listed above Play next")
        menu.close()
    }

    function test_a_page_header_offers_both_actions() {
        var menu = openHeroMenu(makeAlbumPage(4))
        verify(menu.playNextItem.visible,   "an album header offers no Play next")
        verify(menu.addToQueueItem.visible, "an album header offers no Add to queue")
        menu.close()
    }

    // A sidebar row has a thing to pin and no tracklist behind it, so it
    // offers neither action.
    function test_nothing_to_queue_offers_neither_action() {
        var holder = makeHolder()
        var menu = createTemporaryObject(ctxMenuC, holder, {})
        verify(menu, "the menu was not created")
        verify(menu.trackSource === null, "the bare menu invented a tracklist")

        menu.showPin(10, 10, "album", "42", "Fever Dream", "The Band", "")
        tryVerify(function () { return menu.visible }, 2000, "the menu did not open")
        verify(menu.pinItem.visible,          "the pin item vanished with the queue items")
        verify(!menu.playNextItem.visible,    "a menu with no tracklist offered Play next")
        verify(!menu.addToQueueItem.visible,  "a menu with no tracklist offered Add to queue")
        menu.close()
    }

    // ── each action calls its own player method, once ────────────────────

    function test_play_next_calls_playNext_once() {
        var track = makeTracks(1)[0]
        var row = makeRow(track)
        row.openMenu()
        row.rowMenu.playNextItem.triggered()
        row.rowMenu.close()

        compare(player.queueCalls.join("|"), "playNext 1",
                "Play next did not call playNext exactly once")
        compare(titlesOf(player.queueManual), "Track 1")
    }

    function test_add_to_queue_calls_addToQueue_once() {
        var track = makeTracks(1)[0]
        var row = makeRow(track)
        row.openMenu()
        row.rowMenu.addToQueueItem.triggered()
        row.rowMenu.close()

        compare(player.queueCalls.join("|"), "addToQueue 1",
                "Add to queue did not call addToQueue exactly once")
        compare(titlesOf(player.queueManual), "Track 1")
    }

    // ── a whole album goes in as a block, in order ───────────────────────

    function test_play_next_on_an_album_passes_every_track_in_order() {
        var page = makeAlbumPage(4)
        page.pinMenu.playNextItem.triggered()

        compare(player.queueCalls.join("|"), "playNext 4",
                "the header queued one track, or called the player more than once")
        compare(titlesOf(player.queueManual), "Track 1,Track 2,Track 3,Track 4")
    }

    function test_add_to_queue_on_an_album_appends_every_track_in_order() {
        var page = makeAlbumPage(4)
        player.setManualForTest([{ id: 1, title: "Already queued" }])
        page.pinMenu.addToQueueItem.triggered()

        compare(player.queueCalls.join("|"), "addToQueue 4")
        compare(titlesOf(player.queueManual),
                "Already queued,Track 1,Track 2,Track 3,Track 4",
                "Add to queue did not append at the end, in order")
    }

    function test_play_next_on_an_album_goes_to_the_front() {
        var page = makeAlbumPage(2)
        player.setManualForTest([{ id: 1, title: "Already queued" }])
        page.pinMenu.playNextItem.triggered()

        compare(titlesOf(player.queueManual), "Track 1,Track 2,Already queued",
                "Play next did not reach the front of the manual queue")
    }

    // ── a tile stands for a tracklist it has to go and fetch ────────────

    function test_a_tile_has_a_tracklist_for_every_kind_that_owns_one_data() {
        return [
            { tag: "album",    kind: "album",    queueable: true  },
            { tag: "playlist", kind: "playlist", queueable: true  },
            { tag: "mix",      kind: "mix",      queueable: true  },
            // An artist is not a tracklist: the only list available is their top
            // ten, which nobody chose. Pinning an artist is unaffected.
            { tag: "artist",   kind: "artist",   queueable: false },
            { tag: "track",    kind: "track",    queueable: false }
        ]
    }

    function test_a_tile_has_a_tracklist_for_every_kind_that_owns_one(data) {
        var holder = makeHolder()
        var card = createTemporaryObject(mediaCardC, holder, {
            mediaType: data.kind, itemId: "42", title: "Fever Dream"
        })
        settle(holder)
        compare(card.pinMenu.trackSource !== null, data.queueable,
                data.kind + " tile: wrong idea of whether it has tracks")
    }

    // A tile carries an id, so its tracklist arrives later. The whole list
    // still has to go in, in order, whenever it lands.
    function test_a_late_tracklist_is_queued_whole_and_in_order() {
        var card = makeCard()
        card.pinMenu.trackSource = function (cb) {
            lateAnswer.deliver = function () { cb(testCase.makeTracks(3)) }
            lateAnswer.restart()
        }

        card.pinMenu.addToQueueItem.triggered()
        compare(player.queueCalls.join("|"), "", "the player was called before the fetch answered")

        tryVerify(function () { return player.queueCalls.length > 0 }, 2000,
                  "the late tracklist never reached the player")
        compare(player.queueCalls.join("|"), "addToQueue 3")
        compare(titlesOf(player.queueManual), "Track 1,Track 2,Track 3")
    }

    Timer {
        id: lateAnswer
        interval: 30
        property var deliver: null
        onTriggered: if (deliver) deliver()
    }

    function test_nothing_fetched_queues_nothing() {
        var page = makeAlbumPage(0)
        page.pinMenu.addToQueueItem.triggered()
        compare(player.queueCalls.join("|"), "", "an empty album still called the player")
        compare(player.queueManual.length, 0)
    }

    // ── neither action disturbs what is playing ──────────────────────────

    function test_queueing_never_changes_the_current_track() {
        var page = makeAlbumPage(3)
        player.setCurrentTrackForTest({ id: 99, title: "Still playing" })
        var spy = currentTrackSpy
        spy.clear()

        page.pinMenu.playNextItem.triggered()
        page.pinMenu.addToQueueItem.triggered()

        compare(player.currentTrack.title, "Still playing",
                "queueing moved the player off the current track")
        compare(spy.count, 0, "queueing emitted currentTrackChanged")
    }

    // The context is the album or playlist the user started from, and only
    // playTracks() may replace it.
    function test_queueing_never_touches_the_context() {
        var page = makeAlbumPage(3)
        player.setQueueForTest(makeTracks(2), 0)
        var before = titlesOf(player.queueContext)

        page.pinMenu.addToQueueItem.triggered()

        compare(titlesOf(player.queueContext), before, "queueing rewrote the context")
    }

    SignalSpy { id: currentTrackSpy; target: player; signalName: "currentTrackChanged" }

    // ── the confirmation ─────────────────────────────────────────────────

    // The confirmation is the app's own transient: it never takes focus,
    // never blocks, and times out on its own.
    function test_queueing_confirms_and_the_confirmation_goes_away() {
        var page = makeAlbumPage(4)
        var tip = testCase.ToolTip.toolTip
        verify(tip, "there is no shared tool tip to confirm with")

        page.pinMenu.addToQueueItem.triggered()

        tryVerify(function () { return tip.visible }, 2000, "queueing gave no confirmation")
        compare(tip.text, qsTr("%n track(s) added to queue", "queue confirmation", 4))
        verify(!tip.activeFocus, "the confirmation took focus")
        verify(!tip.modal, "the confirmation blocked the window")

        tryVerify(function () { return !tip.visible }, 5000,
                  "the confirmation never went away on its own")
    }

    // A row confirms the same way a header does, so the feedback does not
    // depend on which menu the action was taken from.
    function test_a_row_confirms_too() {
        var row = makeRow(makeTracks(1)[0])
        var tip = testCase.ToolTip.toolTip
        row.openMenu()
        row.rowMenu.addToQueueItem.triggered()
        row.rowMenu.close()

        tryVerify(function () { return tip.visible }, 2000, "a row queued without a word")
        compare(tip.text, qsTr("%n track(s) added to queue", "queue confirmation", 1))
    }

    function test_the_confirmation_names_the_action() {
        var page = makeAlbumPage(2)
        var tip = testCase.ToolTip.toolTip

        page.pinMenu.playNextItem.triggered()
        tryVerify(function () { return tip.visible }, 2000, "Play next gave no confirmation")
        compare(tip.text, qsTr("%n track(s) added to play next", "queue confirmation", 2))
        tryVerify(function () { return !tip.visible }, 5000, "the confirmation never went away")
    }
}
