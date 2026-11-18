// Undo for account writes and the queue. A write is said and offered back
// only once Tidal said yes and a read-back shows it; Ctrl+Z walks a short
// history of those, newest first. Every write here goes to the stub bridge.

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Undo"
    when: windowShown
    visible: true
    width: 1000
    height: 700

    Component { id: favC;   ContextMenu.FavoriteAction { } }
    Component { id: queueC; QueuePanel { anchors.fill: parent } }
    Component { id: appC;   Main { } }

    ToastHost { id: toastHost; anchors.fill: parent; z: 10 }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        Toasts.dismiss()
        Edits.clearHistory()
        // Short waits: the backoff is the same shape, only quicker.
        Edits.retryDelaysMs = [20, 20, 20, 20]
    }

    function cleanup() {
        Edits.answerDuplicates("cancel")
        bridge.useCatalogueForTest("")
        Edits.retryDelaysMs = [500, 1000, 2000, 4000]
        Edits.clearHistory()
    }

    // Waits out every read-back and undo still going.
    function settleEdits() {
        wait(150)
    }

    // ── each change: confirmed, undone, confirmed again ──────────────────

    function test_favourites_data() {
        return [
            { tag: "like a track",     kind: "track",  id: 9101, on: true,
              set: "setTrackFavoriteForTest",  is: "isTrackFavorite",
              done: "Added to your liked tracks", undone: "Removed from your liked tracks" },
            { tag: "unlike a track",   kind: "track",  id: 9101, on: false,
              set: "setTrackFavoriteForTest",  is: "isTrackFavorite",
              done: "Removed from your liked tracks", undone: "Back in your liked tracks" },
            { tag: "save an album",    kind: "album",  id: 4242, on: true,
              set: "setAlbumFavoriteForTest",  is: "isAlbumFavorite",
              done: "Album saved to your collection", undone: "Album removed from your collection" },
            { tag: "remove an album",  kind: "album",  id: 4242, on: false,
              set: "setAlbumFavoriteForTest",  is: "isAlbumFavorite",
              done: "Album removed from your collection", undone: "Album back in your collection" },
            { tag: "follow an artist", kind: "artist", id: 777,  on: true,
              set: "setArtistFavoriteForTest", is: "isArtistFavorite",
              done: "You now follow this artist", undone: "You no longer follow this artist" },
            { tag: "unfollow",         kind: "artist", id: 777,  on: false,
              set: "setArtistFavoriteForTest", is: "isArtistFavorite",
              done: "You no longer follow this artist", undone: "You follow this artist again" },
            { tag: "save a mix",       kind: "mix",    id: "0a1b2c", on: true,
              set: "setMixFavoriteForTest",    is: "isMixFavorite",
              done: "Mix saved to your collection", undone: "Mix removed from your collection" },
            { tag: "remove a mix",     kind: "mix",    id: "0a1b2c", on: false,
              set: "setMixFavoriteForTest",    is: "isMixFavorite",
              done: "Mix removed from your collection", undone: "Mix back in your collection" }
        ]
    }

    function test_favourites(row) {
        bridge[row.set](row.id, !row.on)
        var fav = createTemporaryObject(favC, testCase)
        var toggles = { track: "toggleTrack", album: "toggleAlbum",
                        artist: "toggleArtist", mix: "toggleMix" }
        fav[toggles[row.kind]](row.id, !row.on)
        settleEdits()
        compare(bridge[row.is](row.id), row.on, "the write did not land")
        compare(Toasts.text, row.done)
        verify(Toasts.actionLabel.length > 0, "a confirmed change offered no Undo")
        compare(Edits.count, 1)

        // Ctrl+Z's path, after the notice has gone.
        Toasts.dismiss()
        Edits.undoLast()
        settleEdits()
        compare(bridge[row.is](row.id), !row.on, "the undo did not land")
        compare(Toasts.text, row.undone, "the undo did not say what it undid")
        compare(Toasts.actionLabel, "", "an undo offered Undo")
        compare(Edits.count, 0)
        verify(!Edits.undoing)
    }

    function test_the_notice_waits_for_the_read_back() {
        bridge.setTrackFavoriteForTest(9101, false)
        bridge.setReadBackLagForTest(2)
        Edits.retryDelaysMs = [60, 60, 60, 60]
        Edits.setFavorite("track", 9101, true)
        verify(!Toasts.shown, "the notice came before Tidal showed the like")
        compare(Edits.count, 0, "Undo was on offer before Tidal showed the like")
        tryVerify(function () { return Toasts.shown }, 2000, "the like was never confirmed")
        compare(Toasts.text, "Added to your liked tracks")
        // One read at once, two that lagged behind.
        compare(bridge.readBacksForTest(), 3)
        compare(Edits.count, 1)
    }

    function test_a_refused_write_says_so_and_offers_nothing() {
        bridge.setTrackFavoriteForTest(9101, true)
        bridge.setFavoriteOkForTest(false)
        var fav = createTemporaryObject(favC, testCase)
        fav.toggleTrack(9101, true)
        settleEdits()
        compare(Toasts.text, "Could not unlike the track")
        compare(Toasts.actionLabel, "")
        compare(fav.lastMessage, "Could not unlike the track")
        compare(Edits.count, 0)
        compare(bridge.readBacksForTest(), 0, "a refused write was read back")
    }

    function test_a_write_tidal_never_shows_is_reported_and_reloaded() {
        bridge.setTrackFavoriteForTest(9101, false)
        bridge.setReadBackLagForTest(-1)
        Edits.setFavorite("track", 9101, true)
        // The reload comes last. Waited for: a fixed wait ran out on a slow runner.
        tryVerify(function () { return bridge.favoriteReloadsForTest().length > 0 }, 5000,
                  "the write was never given up on")
        compare(Toasts.text, Edits.unconfirmedText)
        compare(Toasts.actionLabel, "", "an unconfirmed change offered Undo")
        compare(Edits.count, 0)
        compare(bridge.readBacksForTest(), 5, "not every read-back went out")
        compare(bridge.favoriteReloadsForTest(), ["track"], "the view was not reloaded from Tidal")
    }

    function test_an_undo_tidal_never_shows_is_reported() {
        bridge.setAlbumFavoriteForTest(4242, true)
        Edits.setFavorite("album", 4242, false)
        settleEdits()
        compare(Edits.count, 1)
        bridge.setReadBackLagForTest(-1)
        Edits.undoLast()
        tryVerify(function () { return !Edits.undoing }, 5000, "the undo never finished")
        compare(Toasts.text, Edits.unconfirmedText)
        compare(bridge.favoriteReloadsForTest(), ["album"])
        verify(!Edits.undoing)
        compare(Edits.count, 0, "an undo that failed went back on the list")
    }

    function test_an_undo_the_server_refuses_is_reported() {
        bridge.setArtistFavoriteForTest(777, true)
        Edits.setFavorite("artist", 777, false)
        settleEdits()
        bridge.setFavoriteOkForTest(false)
        Edits.undoLast()
        settleEdits()
        compare(Toasts.text, Edits.undoFailedText)
        verify(!Edits.undoing)
    }

    // ── playlists ────────────────────────────────────────────────────────

    function test_add_to_a_playlist_then_undo() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        Edits.addToPlaylist("pl-1", "Tape", 13)
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13])
        compare(Toasts.text, "Added to “Tape”")
        compare(Edits.count, 1)
        Edits.undoLast()
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12], "the undo did not take it out")
        compare(Toasts.text, "Taken out of “Tape” again")
    }

    // ── a track the playlist holds already: asked first ──────────────────

    function test_a_track_already_there_is_asked_about_first() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        Edits.addToPlaylist("pl-1", "Tape", 12)
        settleEdits()
        compare(bridge.addToPlaylistCallsForTest(), 0, "the add went out before the answer")
        compare(bridge.lastRestoredForTest(), "", "the add went out before the answer")
        var q = Edits.duplicateQuestion
        verify(q, "nothing was asked")
        compare(q.title, "Tape")
        compare(q.dupes, 1)
        compare(q.total, 1)
        compare(q.fresh, null, "a lone track offered to add only the new ones")

        Edits.answerDuplicates("cancel")
        settleEdits()
        compare(Edits.duplicateQuestion, null)
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12], "a turned-down add was written")
        compare(Edits.count, 0)
        verify(!Toasts.shown, "a turned-down add said something")
    }

    function test_add_anyway_adds_it_again_and_undo_takes_one_out() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        var said = null
        Edits.addToPlaylist("pl-1", "Tape", 12, function (ok, message) { said = message })
        settleEdits()
        Edits.answerDuplicates("all")
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 12], "Add anyway did not add it")
        compare(Toasts.text, "Added to “Tape”")
        compare(said, "Added to “Tape”")
        compare(Edits.count, 1)
        Edits.undoLast()
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12], "the undo did not take the second one out")
        compare(Toasts.text, "Taken out of “Tape” again")
    }

    function test_several_some_there_add_only_the_new_ones() {
        verify(bridge.useCatalogueForTest("en"), "the English catalogue did not load")
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 13, 14])
        settleEdits()
        var q = Edits.duplicateQuestion
        verify(q, "nothing was asked")
        compare(q.dupes, 1)
        compare(q.total, 3)
        verify(q.fresh, "no way to add only the new ones")
        Edits.answerDuplicates("new")
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13, 14])
        compare(Toasts.text, "2 tracks added to “Tape”")
        Edits.undoLast()
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12], "the undo left some behind")
        compare(Toasts.text, "Taken out of “Tape” again")
    }

    function test_several_some_there_add_all() {
        verify(bridge.useCatalogueForTest("en"), "the English catalogue did not load")
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 13, 14])
        settleEdits()
        Edits.answerDuplicates("all")
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 12, 13, 14])
        compare(Toasts.text, "3 tracks added to “Tape”")
        Edits.undoLast()
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12])
    }

    function test_several_none_there_are_added_without_asking() {
        verify(bridge.useCatalogueForTest("en"), "the English catalogue did not load")
        bridge.setServerPlaylistForTest("pl-1", [11])
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 13])
        settleEdits()
        compare(Edits.duplicateQuestion, null, "a question with nothing to ask")
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13])
        compare(Toasts.text, "2 tracks added to “Tape”")
    }

    // An album or a whole queue goes out a hundred tracks a write, in order,
    // not one write per track.
    function test_a_long_add_goes_out_a_hundred_at_a_time() {
        bridge.setServerPlaylistForTest("pl-1", [])
        var ids = []
        for (var i = 0; i < 250; i++) ids.push(5000 + i)
        Edits.addTracksToPlaylist("pl-1", "Tape", ids)
        settleEdits()
        compare(bridge.addWritesForTest().join(","), "100,100,50",
                "the add did not go out in writes of a hundred")
        compare(bridge.serverPlaylistForTest("pl-1"), ids, "the tracks landed out of order")
    }

    // Undoing a long add is one read, one removal of all its rows and one
    // read-back, not three requests per track: Tidal rate-limits the account.
    function test_undoing_a_long_add_takes_a_few_requests() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        var ids = []
        for (var i = 0; i < 250; i++) ids.push(5000 + i)
        Edits.addTracksToPlaylist("pl-1", "Tape", ids)
        settleEdits()
        compare(Edits.count, 1)
        var reads = bridge.readBacksForTest()
        var removals = bridge.removeFromPlaylistCallsForTest()
        Edits.undoLast()
        tryVerify(function () { return !Edits.undoing }, 10000, "the undo never finished")
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12], "the undo left some behind")
        compare(Toasts.text, "Taken out of “Tape” again")
        var requests = bridge.readBacksForTest() - reads
                     + bridge.removeFromPlaylistCallsForTest() - removals
                     + bridge.removeWritesForTest().length
        verify(requests <= 5, "the undo took " + requests + " requests")
        compare(bridge.removeWritesForTest().length, 1, "the rows did not go in one removal")
        compare(bridge.removeWritesForTest()[0].split(",").length, 250)
    }

    // A track listed twice in the add, and held before it: the undo takes the
    // last rows holding it, as many as were added, and leaves the rest.
    function test_undoing_an_add_with_duplicates_takes_the_last_rows() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12, 13, 12, 14])
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 15, 12])
        settleEdits()
        Edits.answerDuplicates("all")
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13, 12, 14, 12, 15, 12])
        // Moved on another device since: 15 now sits first.
        bridge.setServerPlaylistForTest("pl-1", [15, 11, 12, 13, 12, 14, 12, 12])
        Edits.undoLast()
        settleEdits()
        compare(bridge.removeWritesForTest(), ["0,6,7"])
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13, 12, 14])
        compare(Toasts.text, "Taken out of “Tape” again")
    }

    // Tidal refuses the removal: a stale version, or any other no. Nothing is
    // said to be undone, and the page reads the playlist again.
    function test_an_undo_of_an_add_tidal_refuses_says_so_data() {
        return [ { tag: "stale", answer: "stale" }, { tag: "refused", answer: "fail" } ]
    }
    function test_an_undo_of_an_add_tidal_refuses_says_so(row) {
        bridge.setServerPlaylistForTest("pl-1", [11])
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 13])
        settleEdits()
        compare(Edits.count, 1)
        bridge.setRemoveAnswerForTest(row.answer)
        var changed = []
        var conn = function (uuid) { changed.push(uuid) }
        Edits.playlistChanged.connect(conn)
        Edits.undoLast()
        tryVerify(function () { return !Edits.undoing }, 5000, "the undo never finished")
        Edits.playlistChanged.disconnect(conn)
        compare(bridge.removeWritesForTest(), ["1,2"])
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13])
        compare(Toasts.text, Edits.undoFailedText)
        compare(changed, ["pl-1"], "the page was not told to read the playlist again")
        verify(!Edits.undoing)
    }

    // The removal went through but no read-back shows it.
    function test_an_undo_of_an_add_tidal_never_shows_is_reported() {
        bridge.setServerPlaylistForTest("pl-1", [11])
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 13])
        settleEdits()
        // Seeded again, so the undo's own read sees the add.
        bridge.setServerPlaylistForTest("pl-1", [11, 12, 13])
        bridge.setReadBackLagForTest(-1)
        Edits.undoLast()
        tryVerify(function () { return !Edits.undoing }, 5000, "the undo never finished")
        compare(bridge.removeWritesForTest(), ["1,2"])
        compare(Toasts.text, Edits.unconfirmedText)
        verify(!Edits.undoing)
    }

    // Add all: the write that holds a duplicate asks Tidal to add it again.
    function test_add_all_sends_the_duplicates_as_duplicates() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 13, 14])
        settleEdits()
        Edits.answerDuplicates("all")
        settleEdits()
        compare(bridge.addWritesForTest().join(","), "3+", "the duplicate was sent to be skipped")
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 12, 13, 14])
    }

    // The question as DuplicateAddDialog puts it, and its buttons.
    Component { id: dupDialogC; DuplicateAddDialog { } }

    function dialogButton(dialog, name) {
        var b = findChild(dialog.contentItem, name)
        verify(b && b.visible, "the dialog has no " + name)
        return b
    }

    function test_the_dialog_asks_about_one_track() {
        var dialog = createTemporaryObject(dupDialogC, testCase)
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        Edits.addToPlaylist("pl-1", "Tape", 12)
        settleEdits()
        tryVerify(function () { return dialog.opened }, 2000, "the dialog did not open")
        compare(dialog.heading, "Already in “Tape”")
        compare(dialog.text, "Add anyway?")
        compare(dialogButton(dialog, "confirmDialogConfirm").text, "Add anyway")
        verify(!findChild(dialog.contentItem, "confirmDialogAlt").visible,
               "a lone track offered a choice it has not got")
        var add = dialogButton(dialog, "confirmDialogConfirm")
        mouseClick(add, add.width / 2, add.height / 2)
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 12])
        verify(!dialog.visible, "the dialog stayed up")
    }

    function test_the_dialog_cancel_adds_nothing() {
        var dialog = createTemporaryObject(dupDialogC, testCase)
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        Edits.addToPlaylist("pl-1", "Tape", 12)
        settleEdits()
        tryVerify(function () { return dialog.opened }, 2000, "the dialog did not open")
        var cancel = dialogButton(dialog, "confirmDialogCancel")
        mouseClick(cancel, cancel.width / 2, cancel.height / 2)
        settleEdits()
        compare(Edits.duplicateQuestion, null, "the question outlived the dialog")
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12])
    }

    function test_the_dialog_asks_about_several() {
        var dialog = createTemporaryObject(dupDialogC, testCase)
        bridge.setServerPlaylistForTest("pl-1", [11, 12, 13])
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 13, 14, 15])
        settleEdits()
        tryVerify(function () { return dialog.opened }, 2000, "the dialog did not open")
        compare(dialog.heading, "Some are already in “Tape”")
        compare(dialog.text, "2 of these 4 tracks are in it already.")
        compare(dialogButton(dialog, "confirmDialogConfirm").text, "Add all")
        var fresh = dialogButton(dialog, "confirmDialogAlt")
        compare(fresh.text, "Add new ones")
        mouseClick(fresh, fresh.width / 2, fresh.height / 2)
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13, 14, 15])
    }

    function test_the_dialog_in_german() {
        verify(bridge.useCatalogueForTest("de"), "the German catalogue did not load")
        var dialog = createTemporaryObject(dupDialogC, testCase)
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        Edits.addToPlaylist("pl-1", "Tape", 12)
        settleEdits()
        tryVerify(function () { return dialog.opened }, 2000, "the dialog did not open")
        compare(dialog.heading, "Schon in „Tape“")
        compare(dialog.text, "Trotzdem hinzufügen?")
        compare(dialogButton(dialog, "confirmDialogConfirm").text, "Trotzdem hinzufügen")
        Edits.answerDuplicates("cancel")
        Edits.addTracksToPlaylist("pl-1", "Tape", [12, 13, 14])
        settleEdits()
        tryVerify(function () { return dialog.opened }, 2000, "the dialog did not open again")
        compare(dialog.heading, "Einige sind schon in „Tape“")
        compare(dialog.text, "1 von diesen 3 Titeln ist schon darin.")
        compare(dialogButton(dialog, "confirmDialogConfirm").text, "Alle hinzufügen")
        compare(dialogButton(dialog, "confirmDialogAlt").text, "Nur neue hinzufügen")
        // Three German answers in a row still fit inside the dialog.
        var cancel = dialogButton(dialog, "confirmDialogCancel")
        var all = dialogButton(dialog, "confirmDialogConfirm")
        var left = cancel.mapToItem(dialog.contentItem, 0, 0).x
        var right = all.mapToItem(dialog.contentItem, all.width, 0).x
        verify(left >= 0 && right <= dialog.contentItem.width + 0.5,
               "the buttons run from " + left + " to " + right + " in a "
               + dialog.contentItem.width + " px dialog")
        Edits.answerDuplicates("cancel")
        bridge.useCatalogueForTest("")
    }

    function test_remove_from_a_playlist_then_undo() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12, 13])
        var written = null
        Edits.removeFromPlaylist("pl-1", "Tape", 12, 1, 1, function (ok, stale, index) {
            written = { ok: ok, index: index }
        })
        compare(written.ok, true, "the page was not told the row went")
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 13])
        compare(Toasts.text, "Removed from “Tape”")
        Edits.undoLast()
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13], "the track is not back at its row")
        compare(Toasts.text, "Put back in “Tape”")
        compare(bridge.lastRestoredForTest(), "pl-1 12 1")
    }

    // The playlist shrank since: the old row is past its end, so the track
    // goes back last.
    function test_put_back_is_clamped_to_the_list_as_it_is_now() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12, 13, 14])
        Edits.removeFromPlaylist("pl-1", "Tape", 14, 3, 1, null)
        settleEdits()
        bridge.setServerPlaylistForTest("pl-1", [11])
        Edits.undoLast()
        settleEdits()
        compare(bridge.lastRestoredForTest(), "pl-1 14 1")
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 14])
    }

    // Two removals, then two undos: each row back where it was.
    function test_two_quick_removals_undo_newest_first() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12, 13, 14, 15])
        Edits.removeFromPlaylist("pl-1", "Tape", 12, 1, 1, null)
        Edits.removeFromPlaylist("pl-1", "Tape", 14, 2, 1, null)
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 13, 15])
        compare(Edits.count, 2)
        Edits.undoLast()
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 13, 14, 15], "14 did not come back first")
        Edits.undoLast()
        settleEdits()
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 12, 13, 14, 15])
    }

    function test_a_removal_tidal_never_shows_reloads_the_playlist() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12])
        bridge.setReadBackLagForTest(-1)
        var changed = []
        var conn = function (uuid) { changed.push(uuid) }
        Edits.playlistChanged.connect(conn)
        Edits.removeFromPlaylist("pl-1", "Tape", 12, 1, 1, null)
        tryVerify(function () { return changed.length > 0 }, 5000, "the removal was never given up on")
        Edits.playlistChanged.disconnect(conn)
        compare(Toasts.text, Edits.unconfirmedText)
        compare(Edits.count, 0)
        compare(changed, ["pl-1"], "the page was not told to read the playlist again")
    }

    // ── the queue ────────────────────────────────────────────────────────

    function test_clearing_the_queue_is_undone_by_ctrl_z() {
        var tracks = [{ id: 7100, title: "Song 1" }, { id: 7101, title: "Song 2" }]
        player.setQueueForTest([{ id: 1, title: "Now" }], 0)
        player.setManualForTest(tracks)
        var panel = createTemporaryObject(queueC, testCase, { open: true })
        panel.clearQueue()
        compare(player.manualCount, 0)
        Toasts.dismiss()
        Edits.undoLast()
        compare(player.manualCount, 2, "Ctrl+Z did not bring the queue back")
        compare(Toasts.text, "Queue put back")
    }

    // ── the history ──────────────────────────────────────────────────────

    function test_nothing_to_undo() {
        Edits.undoLast()
        compare(Toasts.text, "Nothing to undo")
        compare(Toasts.actionLabel, "")
    }

    function test_the_history_keeps_ten() {
        for (var i = 0; i < 12; i++) Edits.recordLocal("change " + i, function () { }, "undone")
        compare(Edits.count, 10)
        var runs = []
        Edits.clearHistory()
        for (var j = 0; j < 12; j++) {
            (function (k) { Edits.recordLocal("change " + k, function () { runs.push(k) }, "undone") })(j)
        }
        for (var n = 0; n < 11; n++) Edits.undoLast()
        compare(runs, [11, 10, 9, 8, 7, 6, 5, 4, 3, 2], "not newest first, or the oldest were kept")
        compare(Toasts.text, "Nothing to undo")
    }

    // The toast's Undo and Ctrl+Z are one list: what one took back the other
    // cannot take again.
    function test_the_toast_undo_takes_it_off_the_list() {
        var runs = 0
        Edits.recordLocal("Queue cleared", function () { runs++ }, "Queue put back")
        Toasts.runAction()
        compare(runs, 1)
        Edits.undoLast()
        compare(runs, 1, "Ctrl+Z ran it again")
        compare(Toasts.text, "Nothing to undo")
    }

    // Refused, not queued: a second undo on one playlist while the first is
    // unconfirmed could put a row back at the wrong place.
    function test_ctrl_z_while_an_undo_is_confirming_is_refused() {
        bridge.setServerPlaylistForTest("pl-1", [11, 12, 13])
        Edits.removeFromPlaylist("pl-1", "Tape", 12, 1, 1, null)
        Edits.removeFromPlaylist("pl-1", "Tape", 13, 1, 1, null)
        settleEdits()
        compare(Edits.count, 2)
        bridge.setReadBackLagForTest(2)
        Edits.retryDelaysMs = [80, 80, 80, 80]
        Edits.undoLast()
        verify(Edits.undoing, "the undo did not wait for its read-back")
        Edits.undoLast()
        compare(Toasts.text, "Still undoing the last change")
        compare(Edits.count, 1, "the refused undo took an entry")
        tryVerify(function () { return !Edits.undoing }, 3000)
        compare(Toasts.text, "Put back in “Tape”")
        compare(bridge.serverPlaylistForTest("pl-1"), [11, 13])
    }

    // ── Ctrl+Z in the window ─────────────────────────────────────────────

    function showApp() {
        auth.setStateForTest(2)
        var win = createTemporaryObject(appC, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        win.requestActivate()
        win.update()
        verify(waitForRendering(win.contentItem))
        return win
    }

    function test_ctrl_z_undoes_in_the_window() {
        var win = showApp()
        var runs = 0
        Edits.recordLocal("Queue cleared", function () { runs++ }, "Queue put back")
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(runs, 1, "Ctrl+Z did not undo")
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(Toasts.text, "Nothing to undo")
    }

    function test_ctrl_z_in_a_text_field_is_the_field_s() {
        var win = showApp()
        var runs = 0
        Edits.recordLocal("Queue cleared", function () { runs++ }, "Queue put back")
        keyClick(Qt.Key_F, Qt.ControlModifier)
        tryVerify(function () { return win.isTypingContext(win.activeFocusItem) }, 1000)
        var field = win.activeFocusItem
        keyClick(Qt.Key_A)
        keyClick(Qt.Key_B)
        compare(field.text, "ab")
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(runs, 0, "Ctrl+Z in a text field undid an account change")
        verify(field.text !== "ab", "the field did not get its own undo")
    }
}
