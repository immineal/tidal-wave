// The one toast: a confirmation drawn by ToastHost, with Undo on the actions
// that take something away. Undo goes back through the same bridge and player
// calls the forward action used, so the stubs record what it sent.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Toasts"
    when: windowShown
    // TestCase declares visible: false, which would leave every child
    // unrendered and stop a synthesized click arriving.
    visible: true
    width: 1000
    height: 700

    Component { id: favC;   ContextMenu.FavoriteAction { } }
    Component { id: queueC; QueuePanel { anchors.fill: parent } }

    ToastHost { id: toastHost; anchors.fill: parent; z: 10 }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        player.resetQueueCallsForTest()
        Toasts.dismiss()
        Toasts.plainMs = 4000
        Toasts.actionMs = 8000
    }

    function clickOn(item) {
        var p = item.mapToItem(testCase, item.width / 2, item.height / 2)
        mouseClick(testCase, p.x, p.y)
    }

    function makeTracks(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 7100 + i, title: "Song " + (i + 1), artists: "Kestrel Arcade",
                       durationStr: "3:00", coverUrl: "", coverUrl80: "" })
        return out
    }

    // ── the host ─────────────────────────────────────────────────────────

    function test_a_plain_message_has_no_action_and_takes_no_focus() {
        Toasts.show("Saved")
        tryVerify(function () { return toastHost.card.visible }, 1000, "the toast never showed")
        verify(!toastHost.actionButton.visible, "a plain message offered an action")
        verify(!toastHost.actionButton.activeFocus && !toastHost.card.activeFocus,
               "the toast took focus")
    }

    function test_it_goes_away_by_itself() {
        Toasts.plainMs = 200
        Toasts.show("Saved")
        tryVerify(function () { return toastHost.card.visible }, 1000)
        tryVerify(function () { return !toastHost.card.visible }, 3000,
                  "the toast stayed on screen")
    }

    // Undo has to stay in reach while the pointer is on its way to it.
    function test_the_pointer_on_it_holds_it() {
        Toasts.actionMs = 300
        Toasts.undoable("Gone", function () { })
        tryVerify(function () { return toastHost.card.visible }, 1000)
        var c = toastHost.card
        var p = c.mapToItem(testCase, Theme.space4, c.height / 2)
        mouseMove(testCase, p.x, p.y)
        wait(800)
        verify(toastHost.card.visible, "the toast left from under the pointer")
        mouseMove(testCase, 2, 2)
        tryVerify(function () { return !toastHost.card.visible }, 3000,
                  "the toast stayed after the pointer left")
    }

    function test_undo_runs_once_and_closes_it() {
        var runs = 0
        Toasts.undoable("Gone", function () { runs++ })
        tryVerify(function () { return toastHost.actionButton.visible }, 1000,
                  "an undoable message showed no Undo")
        clickOn(toastHost.actionButton)
        compare(runs, 1, "Undo did not run, or ran twice")
        verify(!Toasts.shown, "the toast stayed after its Undo")
        Toasts.runAction()
        compare(runs, 1, "a second Undo ran the action again")
    }

    function test_undo_works_from_the_keyboard() {
        var runs = 0
        Toasts.undoable("Gone", function () { runs++ })
        tryVerify(function () { return toastHost.actionButton.visible }, 1000)
        verify(toastHost.actionButton.activeFocusOnTab, "Undo is not a tab stop")
        toastHost.actionButton.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(runs, 1, "Return on Undo did nothing")
    }

    // A newer message replaces the older one, Undo included.
    function test_a_new_message_drops_the_old_undo() {
        var runs = 0
        Toasts.undoable("Gone", function () { runs++ })
        Toasts.show("Added to queue")
        verify(!toastHost.actionButton.visible, "the old Undo hung on")
        Toasts.runAction()
        compare(runs, 0, "Undo acted on a message no longer on screen")
    }

    // ── the four take-aways ──────────────────────────────────────────────

    function test_unlike_offers_undo_and_undo_likes_again() {
        bridge.setTrackFavoriteForTest(9101, true)
        var fav = createTemporaryObject(favC, testCase)
        fav.toggleTrack(9101, true)
        tryVerify(function () { return !bridge.isTrackFavorite(9101) }, 1000,
                  "the unlike never landed")
        verify(Toasts.shown && Toasts.actionLabel.length > 0, "an unlike offered no Undo")
        Toasts.runAction()
        tryVerify(function () { return bridge.isTrackFavorite(9101) }, 1000,
                  "Undo did not like the track again")
        compare(bridge.lastFavoriteCallForTest(), "addTrack:9101")
    }

    function test_removing_an_album_offers_undo() {
        bridge.setAlbumFavoriteForTest(4242, true)
        var fav = createTemporaryObject(favC, testCase)
        fav.toggleAlbum(4242, true)
        tryVerify(function () { return !bridge.isAlbumFavorite(4242) }, 1000)
        verify(Toasts.actionLabel.length > 0, "removing an album offered no Undo")
        Toasts.runAction()
        tryVerify(function () { return bridge.isAlbumFavorite(4242) }, 1000,
                  "Undo did not put the album back")
    }

    function test_unfollow_offers_undo() {
        bridge.setArtistFavoriteForTest(777, true)
        var fav = createTemporaryObject(favC, testCase)
        fav.toggleArtist(777, true)
        tryVerify(function () { return !bridge.isArtistFavorite(777) }, 1000)
        verify(Toasts.actionLabel.length > 0, "an unfollow offered no Undo")
        Toasts.runAction()
        tryVerify(function () { return bridge.isArtistFavorite(777) }, 1000,
                  "Undo did not follow the artist again")
    }

    // A refusal is a plain message: there is nothing to undo.
    function test_a_refused_unlike_offers_no_undo() {
        bridge.setTrackFavoriteForTest(9101, true)
        bridge.setFavoriteOkForTest(false)
        var fav = createTemporaryObject(favC, testCase)
        fav.toggleTrack(9101, true)
        tryVerify(function () { return Toasts.shown }, 1000, "the refusal said nothing")
        compare(Toasts.actionLabel, "", "a refusal offered Undo")
    }

    function test_clearing_the_queue_offers_undo_in_the_same_order() {
        var tracks = makeTracks(3)
        player.setQueueForTest([{ id: 1, title: "Now" }], 0)
        player.setManualForTest(tracks)
        var panel = createTemporaryObject(queueC, testCase, { open: true })
        verify(panel)
        panel.clearQueue()
        compare(player.manualCount, 0, "Clear left the queue as it was")
        verify(Toasts.actionLabel.length > 0, "clearing the queue offered no Undo")
        Toasts.runAction()
        compare(player.manualCount, 3, "Undo did not bring the queue back")
        var back = player.queueManual
        for (var i = 0; i < 3; ++i)
            compare(back[i].title, tracks[i].title, "Undo changed the order")
    }
}
