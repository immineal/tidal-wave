// A playlist's track count, after the user changes what is in it — and the two
// popups the counts are read in.
//
// The reported defect, in the owner's words: "if I create a new tape playlist and
// then add two songs to it, the two songs are in the playlist, but in the 'add to
// playlist' menu, it still says the playlist has zero tracks."
//
// The songs really did go in. The count is cached, in two separate lists, and
// `TidalBridge::addTracksToPlaylist` told the server and updated neither - so every
// place the number is drawn off a cache kept saying 0 until the next sign-in. There
// are three such places: this picker's row, the Collection grid's tile and the Home
// row's tile. The playlist page's own hero is not one of them, because it counts
// `tracks.length` and is live; the Search grid is not one either, because its
// playlists come straight off a search response.
//
// The removal direction had the mirror of the bug - every cached count one too high
// - and a second defect beside it: PlaylistPage discarded the server's answer, so a
// removal the server refused left the song in the list, correctly, and said nothing
// about it, which reads as a click that missed.
//
// Everything here runs against the stubs in tests/TestStubs.h. No account is
// touched and nothing reaches the network. `StubBridge::addTracksToPlaylist` and
// `removeTrackFromPlaylist` mirror the real pair including the header re-read, the
// guard on it and the two signals, and `setPlaylistHeaderForTest` is what that
// re-read answers. Before this file they recorded the call and stopped, which is
// precisely why a picker drawing "0 tracks" over a playlist with two songs in it
// kept the suite green: the only thing being tested was the stub.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "PlaylistCounts"
    when: windowShown
    // TestCase declares visible: false, which would make every child report
    // visible == false and stop a synthesized mouse event ever arriving.
    visible: true
    width: 1280
    height: 900

    readonly property int settleMs: 2000

    // ── fixtures ─────────────────────────────────────────────────────────
    //
    // "p-tape" is the playlist under test and is deliberately the *middle* row of
    // three, with a distinct count on each: an assertion that read the wrong row,
    // or a repair that rewrote the whole list, has somewhere to fail. A fixture of
    // three identical rows could say neither.
    //
    // It starts at 0, which is the state the owner's report starts in - a playlist
    // just created.
    function makeCache() {
        return [
            { uuid: "p-first", title: "Alte Liste",  description: "unberührt",
              coverUrl: "cdn/c1.jpg", numTracks: 12, duration: 2400, type: "USER" },
            { uuid: "p-tape",  title: "Tape",        description: "",
              coverUrl: "",           numTracks: 0,  duration: 0,    type: "USER" },
            { uuid: "p-end",   title: "Winterabend", description: "",
              coverUrl: "cdn/c3.jpg", numTracks: 7,  duration: 1500, type: "USER" }
        ]
    }

    // What `playlists/p-tape` answers once the two songs are on it. The cover
    // arrives with them, because Tidal builds a USER playlist's artwork out of its
    // first tracks - so an empty playlist that gains songs gains a picture, and
    // that is a second field the old code left stale.
    function tapeHeaderWithTwo() {
        return { uuid: "p-tape", title: "Tape", numTracks: 2, duration: 418,
                 coverUrl: "cdn/mosaic-two.jpg" }
    }

    function makeEntries() {
        return [
            { kind: "playlist", id: "p-pin",   title: "Angepinnte Liste", subtitle: "", imageUrl: "cdn/pp.jpg", pinned: true,  trackCount: 4  },
            { kind: "album",    id: "a1",      title: "Morgenrot",        subtitle: "Erster Interpret", imageUrl: "cdn/a1.jpg", pinned: false, trackCount: 11 },
            { kind: "playlist", id: "p-tape",  title: "Tape",             subtitle: "", imageUrl: "",           pinned: false, trackCount: 0  },
            { kind: "playlist", id: "p-end",   title: "Winterabend",      subtitle: "", imageUrl: "cdn/pe.jpg", pinned: false, trackCount: 7  }
        ]
    }

    function makeTrack() {
        return {
            id: 9001, title: "Ein Lied mit einem ziemlich langen Titel",
            artists: "Erster Interpret", albumTitle: "Ein Album",
            durationStr: "4:07", coverUrl: "", coverUrl80: "",
            albumId: 42, artistId: 7, popularity: 73
        }
    }

    function init() {
        app.setReducedMotionForTest(false)
        prefs.setSidebarWidthForTest(220)
        auth.setStateForTest(2)
        auth.setUsernameForTest("linus")
        library.setEntriesForTest(makeEntries())
        library.setTracksForTest([])
        library.resetCallsForTest()
        pins.setItemsForTest([])
        bridge.resetForTest()
        bridge.resetRemoveFromPlaylistForTest()
        bridge.setUserPlaylistsForTest(makeCache())
    }

    function cleanup() {
        bridge.resetForTest()
        bridge.resetRemoveFromPlaylistForTest()
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function settle(item) {
        wait(1)
        waitForRendering(item, settleMs)
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    Component { id: playlistC;   PlaylistPage   { anchors.fill: parent } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: trackRowC;   TrackRow { } }
    Component { id: dialogC;     NewPlaylistDialog { } }

    Component {
        id: pageHost
        Window {
            property alias pane: pane
            property var lastNavigation: null
            function navigate(page, params) { lastNavigation = { page: page, params: params } }
            width: 1200
            height: 900
            Item { id: pane; anchors.fill: parent }
        }
    }

    function showPane(w) {
        var host = createTemporaryObject(pageHost, testCase)
        verify(host, "the host window was not created")
        host.width = w
        host.visible = true
        waitForRendering(host.contentItem, settleMs)
        mouseMove(host.contentItem, 4, host.height - 4)
        wait(1)
        return host
    }

    function makePicker(host) {
        var row = createTemporaryObject(trackRowC, host.pane,
                                        { width: 700, trackData: makeTrack() })
        verify(row, "TrackRow did not load")
        row.openPicker()
        settle(host.contentItem)
        return row
    }

    function pickerList(host) {
        var list = findByName(host.contentItem, "pickerPlaylistList")
        verify(list, "the picker has no playlist list")
        return list
    }

    // What the picker's row actually *draws*, not what its model holds. The two
    // were identical for a cache nobody updated, which is how "0 tracks" survived
    // over a playlist with two songs in it.
    function drawnCount(host, index) {
        var list = pickerList(host)
        var item = list.itemAtIndex(index)
        verify(item, "the picker's row " + index + " was never built")
        var label = findByName(item, "pickerRowTrackCount")
        verify(label, "the picker's row " + index + " draws no count")
        return label.text
    }

    function drawnTitle(host, index) {
        var item = pickerList(host).itemAtIndex(index)
        verify(item, "the picker's row " + index + " was never built")
        return findByName(item, "pickerRowTitle").text
    }

    // The expected string, built by the same call the delegate makes rather than
    // spelled out here: "%n track(s)" renders differently per language and per
    // number, and a literal would pin the English source instead of the rule.
    function countText(n) {
        return qsTr("%n track(s)", "", n)
    }

    // ── the reported bug ─────────────────────────────────────────────────

    // The owner's report, step for step: a playlist with nothing in it, two songs
    // added through the picker, and then the picker opened again.
    //
    // Reopened rather than watched in place, because that is what the user did and
    // what the picker supports - it closes on a tap and fills from the cache on
    // each open. The assertion is on the second open.
    function test_the_picker_draws_the_new_count_once_the_songs_are_in() {
        var host = showPane(1200)
        var row  = makePicker(host)

        compare(drawnTitle(host, 1), "Tape", "the fixture's middle row is not the one under test")
        compare(drawnCount(host, 1), countText(0),
                "the picker did not start from the empty playlist the report starts from")

        // The server will say "two tracks" when asked, which is the only way the
        // app can know: the post that puts a song on a playlist sends
        // onDuplicateFound=SKIP, so a success does not mean the playlist grew.
        bridge.setPlaylistHeaderForTest("p-tape", tapeHeaderWithTwo())

        var rowItem = pickerList(host).itemAtIndex(1)
        mouseClick(rowItem, rowItem.width / 2, rowItem.height / 2)
        settle(host.contentItem)
        compare(bridge.lastAddedPlaylistForTest(), "p-tape",
                "the song went onto a different playlist than the row that was pressed")

        row.openPicker()
        settle(host.contentItem)
        compare(drawnTitle(host, 1), "Tape", "the picker's rows reordered")
        compare(drawnCount(host, 1), countText(2),
                "the picker still calls the playlist empty after two songs went into it")
        // The neighbours are untouched: this repairs one row, not the list.
        compare(drawnCount(host, 0), countText(12), "a neighbouring row's count moved")
        compare(drawnCount(host, 2), countText(7),  "a neighbouring row's count moved")
    }

    // One accepted add, one header read, and the picker still never round-trips for
    // the list itself. That second half is the thing a re-read must not quietly
    // undo: going back to the network on every picker *open* is what was removed,
    // and this is a request on a mutation instead.
    function test_an_accepted_add_costs_one_header_read_and_no_list_fetch() {
        var host = showPane(1200)
        makePicker(host)
        bridge.setPlaylistHeaderForTest("p-tape", tapeHeaderWithTwo())

        var rowItem = pickerList(host).itemAtIndex(1)
        mouseClick(rowItem, rowItem.width / 2, rowItem.height / 2)
        settle(host.contentItem)

        compare(bridge.addToPlaylistCallsForTest(), 1, "the add went out more than once")
        compare(bridge.playlistHeaderReadsForTest(), 1,
                "an accepted add cost " + bridge.playlistHeaderReadsForTest()
                + " header reads where it should cost one")
        compare(bridge.userPlaylistFetchCountForTest(), 0,
                "the repair went back to the network for the whole playlist list")
    }

    // A refused add must move no count and must not pay for a reply that could
    // only confirm what is already cached.
    function test_a_refused_add_leaves_the_count_where_it_was() {
        var host = showPane(1200)
        var row  = makePicker(host)
        bridge.setAddToPlaylistOkForTest(false)
        // Set on purpose: a version that re-read the header regardless would
        // visibly write this in rather than merely cost a request.
        bridge.setPlaylistHeaderForTest("p-tape", tapeHeaderWithTwo())

        var rowItem = pickerList(host).itemAtIndex(1)
        mouseClick(rowItem, rowItem.width / 2, rowItem.height / 2)
        settle(host.contentItem)

        compare(bridge.playlistHeaderReadsForTest(), 0,
                "a refused add still went back for the playlist's header")
        compare(row.lastConfirmation, qsTr("Could not add the song to “%1”").arg("Tape"),
                "a refused add was not reported, or was reported as a success")

        row.openPicker()
        settle(host.contentItem)
        compare(drawnCount(host, 1), countText(0),
                "a refused add moved the count anyway")
    }

    // ── the Collection grid, the second place the number is drawn ─────────
    //
    // This one redraws in place rather than on reopen: the page answers
    // favoritePlaylistsChanged by re-reading searchFavoritePlaylists(), so the tile
    // is the one count that must be seen to move without being asked again.
    function test_the_collection_tile_redraws_when_the_count_moves() {
        var host = showPane(1200)
        var page = createTemporaryObject(collectionC, host.pane)
        verify(page, "CollectionPage did not load")
        page.activeTab = 3
        settle(host.contentItem)

        var card = findByName(host.contentItem, "collectionPlaylistCard")
        verify(card, "the Collection grid drew no playlist tile")
        // The first tile is "Alte Liste"; find the one under test by its title
        // rather than by position, because the grid is sorted by the bridge.
        function tapeCard() {
            var grid = findByName(host.contentItem, "collectionPlaylistCard")
            var found = null
            function walk(it) {
                if (!it) return
                if (it.objectName === "collectionPlaylistCard" && it.title === "Tape") found = it
                for (var i = 0; i < it.children.length; ++i) walk(it.children[i])
            }
            walk(host.contentItem)
            return found
        }
        var tape = tapeCard()
        verify(tape, "the Collection grid has no tile for the playlist under test")
        compare(tape.subtitle, countText(0), "the grid did not start from an empty playlist")

        bridge.setPlaylistHeaderForTest("p-tape", tapeHeaderWithTwo())
        bridge.addTracksToPlaylist("p-tape", 9001, function (ok) {})
        settle(host.contentItem)

        tape = tapeCard()
        verify(tape, "the tile under test disappeared")
        compare(tape.subtitle, countText(2),
                "the Collection tile still calls the playlist empty")
    }

    // ── the sidebar's separate copy ──────────────────────────────────────
    //
    // The bridge's cache and the sidebar's library are two lists that do not hear
    // each other; three earlier fixes each needed their own hand-across written for
    // them and this is the fourth. The sidebar row draws no count today, so this
    // asserts the row's `trackCount` rather than a label - and that the row does
    // not *move*, which is the part that has a rejected patch behind it.
    function test_the_sidebars_own_copy_takes_the_new_count_without_moving() {
        var host = showPane(1200)
        var before = []
        for (var i = 0; i < library.entries.length; ++i) before.push(library.entries[i].id)

        bridge.setPlaylistHeaderForTest("p-tape", tapeHeaderWithTwo())
        bridge.addTracksToPlaylist("p-tape", 9001, function (ok) {})
        settle(host.contentItem)

        var after = []
        var count = -1
        for (var j = 0; j < library.entries.length; ++j) {
            after.push(library.entries[j].id)
            if (library.entries[j].id === "p-tape") count = library.entries[j].trackCount
        }
        compare(count, 2, "the sidebar's copy of the row kept the old count")
        compare(after.join(","), before.join(","),
                "putting a song on a playlist moved its sidebar row: was "
                + before.join(",") + ", now " + after.join(","))
    }

    // ── the removal, and its dropped failure ─────────────────────────────

    function showPlaylistPage(host) {
        var page = createTemporaryObject(playlistC, host.pane, {
            playlistUuid: "p-tape",
            playlistTitle: "Tape",
            playlistType: "USER"
        })
        verify(page, "PlaylistPage did not load")
        settle(host.contentItem)
        return page
    }

    function firstTrackRow(host) {
        var found = null
        function walk(it) {
            if (!it) return
            if (found) return
            // A TrackRow is identified by the signal only it has.
            if (it.removeFromPlaylistRequested !== undefined
                    && it.trackItemIndex !== undefined && it.trackItemIndex === 0)
                found = it
            for (var i = 0; i < it.children.length; ++i) walk(it.children[i])
        }
        walk(host.contentItem)
        return found
    }

    // A removal the server refuses must keep the song *and* say so. It already
    // kept it; the silence was the defect.
    function test_a_refused_removal_keeps_the_song_and_says_so() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        compare(page.tracks.length, 1, "the page did not load its one track")

        var row = firstTrackRow(host)
        verify(row, "the playlist page built no track row")
        bridge.setRemoveFromPlaylistOkForTest(false)

        row.removeFromPlaylistRequested(0)
        settle(host.contentItem)

        compare(bridge.removeFromPlaylistCallsForTest(), 1, "the removal never went out")
        compare(bridge.lastRemovedPlaylistForTest(), "p-tape",
                "the removal was sent for the wrong playlist")
        compare(bridge.lastRemovedIndexForTest(), 0, "the removal was sent for the wrong row")
        compare(page.tracks.length, 1, "a refused removal took the song off the page anyway")
        compare(row.lastConfirmation,
                qsTr("Could not remove the song from the playlist"),
                "a refused removal said nothing, so it reads as a click that missed")
    }

    // ...and an accepted one says nothing, because the row leaving the list is the
    // confirmation. A tool tip over the gap the row used to occupy, every time
    // anyone tidies a playlist, would be noise.
    //
    // Driven on a standalone row rather than a page delegate, and that is not a
    // shortcut: on the page, a successful removal destroys the very delegate that
    // raised it, so there is nothing left to read `lastConfirmation` off. Reading it
    // *before* the removal - which is what this case first did - compares "" with ""
    // and cannot fail. The function's own guard is the right unit for the rule.
    function test_an_accepted_removal_is_not_announced_and_a_refused_one_is() {
        var host = showPane(1200)
        var row = createTemporaryObject(trackRowC, host.pane,
                                        { width: 700, trackData: makeTrack() })
        verify(row, "TrackRow did not load")

        row.confirmRemovedFromPlaylist(true)
        compare(row.lastConfirmation, "",
                "a removal that worked was announced; the row leaving the list is the "
                + "confirmation and a tool tip over the gap is noise")

        row.confirmRemovedFromPlaylist(false)
        compare(row.lastConfirmation, qsTr("Could not remove the song from the playlist"),
                "a refused removal said nothing, or said the wrong thing")
    }

    // The page half: the row goes, and the cached counts are repaired.
    function test_an_accepted_removal_drops_the_row_and_repairs_the_counts() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        var row = firstTrackRow(host)
        verify(row, "the playlist page built no track row")

        // The server will report one track fewer when asked.
        bridge.setPlaylistHeaderForTest("p-tape",
            { uuid: "p-tape", title: "Tape", numTracks: 0, duration: 0, coverUrl: "" })

        row.removeFromPlaylistRequested(0)
        settle(host.contentItem)

        compare(bridge.removeFromPlaylistCallsForTest(), 1, "the removal never went out")
        compare(page.tracks.length, 0, "an accepted removal left the song on the page")
        compare(bridge.playlistHeaderReadsForTest(), 1,
                "an accepted removal did not repair the cached counts")
    }

    // ── getting out of the two popups ────────────────────────────────────
    //
    // The owner: "the new playlist as well as add to playlist should be closable
    // with escape and have a more prominent X sign, like especially add to playlist."
    //
    // The picker's X was a 12px glyph in Theme.textSec behind a MouseArea grown
    // with anchors.margins: -6 - a 24px target hanging outside its own parent, and
    // unreachable from the keyboard. The dialog had no X at all; the only ways out
    // were the Cancel button and a click on the overlay. Both are now
    // SettingsPanel's button - a 26px target around a 14px glyph that lights on
    // hover - with SearchBar's keyboard treatment, which is the two idioms already
    // in the tree rather than a third.
    //
    // The hit area is asserted as a number because "more prominent" has to mean
    // something a mutation can fail.
    readonly property int closeTargetPx: 26

    function clickItem(host, item) {
        var at = item.mapToItem(host.contentItem, item.width / 2, item.height / 2)
        mouseClick(host.contentItem, Math.round(at.x), Math.round(at.y))
    }

    function test_the_pickers_x_is_a_real_target_and_closes_it() {
        var host = showPane(1200)
        var row  = makePicker(host)
        verify(row.playlistPicker.visible, "the picker did not open")

        var close = findByName(host.contentItem, "pickerCloseButton")
        verify(close, "the picker has no close button")
        compare(close.width,  closeTargetPx, "the picker's X is a " + close.width + "px target")
        compare(close.height, closeTargetPx, "the picker's X is a " + close.height + "px target")

        clickItem(host, close)
        tryVerify(function () { return !row.playlistPicker.visible }, settleMs,
                  "the picker's X did not close it")
    }

    function test_the_pickers_x_is_reachable_and_usable_from_the_keyboard() {
        var host = showPane(1200)
        var row  = makePicker(host)
        var close = findByName(host.contentItem, "pickerCloseButton")
        verify(close, "the picker has no close button")
        // The mechanism: without this the button is not in the tab order at all,
        // whatever its size.
        compare(close.activeFocusOnTab, true, "the picker's X is not a tab stop")

        close.forceActiveFocus()
        compare(close.activeFocus, true, "the picker's X cannot take focus")
        keyClick(Qt.Key_Return)
        tryVerify(function () { return !row.playlistPicker.visible }, settleMs,
                  "Return on the focused X did not close the picker")
    }

    function test_escape_closes_the_picker() {
        var host = showPane(1200)
        var row  = makePicker(host)
        verify(row.playlistPicker.visible, "the picker did not open")

        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !row.playlistPicker.visible }, settleMs,
                  "Escape did not close the picker")
    }

    // Escape from wherever focus happens to be, which for this popup is the X once
    // anyone has tabbed to it. An item that consumed the key would strand the user
    // on the one control they reached with the keyboard.
    function test_escape_closes_the_picker_with_the_x_focused() {
        var host = showPane(1200)
        var row  = makePicker(host)
        var close = findByName(host.contentItem, "pickerCloseButton")
        close.forceActiveFocus()
        compare(close.activeFocus, true, "the picker's X cannot take focus")

        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !row.playlistPicker.visible }, settleMs,
                  "Escape was swallowed by the focused X")
    }

    function openDialog(host) {
        var dlg = createTemporaryObject(dialogC, host.pane)
        verify(dlg, "NewPlaylistDialog did not load")
        dlg.openEmpty()
        settle(host.contentItem)
        verify(dlg.visible, "the dialog did not open")
        return dlg
    }

    function test_the_dialogs_x_is_a_real_target_and_closes_it() {
        var host = showPane(1200)
        var dlg  = openDialog(host)

        var close = findByName(host.contentItem, "newPlaylistClose")
        verify(close, "the new-playlist dialog has no close button")
        compare(close.width,  closeTargetPx, "the dialog's X is a " + close.width + "px target")
        compare(close.height, closeTargetPx, "the dialog's X is a " + close.height + "px target")
        compare(close.activeFocusOnTab, true, "the dialog's X is not a tab stop")

        clickItem(host, close)
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog's X did not close it")
    }

    // The case the brief singles out: the field takes focus the moment the dialog
    // opens, and a TextInput is exactly the sort of item that can swallow a key.
    function test_escape_closes_the_dialog_with_the_name_field_focused() {
        var host = showPane(1200)
        var dlg  = openDialog(host)

        var field = findByName(host.contentItem, "newPlaylistField")
        verify(field, "the dialog has no name field")
        tryVerify(function () { return field.activeFocus }, settleMs,
                  "the dialog did not put the focus in the field, so this case proves nothing")

        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "Escape was swallowed by the name field")
    }

    // ...and with something typed in it, which is the state a TextInput is most
    // likely to treat a key as its own.
    function test_escape_closes_the_dialog_with_a_name_half_typed() {
        var host = showPane(1200)
        var dlg  = openDialog(host)
        var field = findByName(host.contentItem, "newPlaylistField")
        tryVerify(function () { return field.activeFocus }, settleMs, "the field never took focus")
        keyClick(Qt.Key_T)
        keyClick(Qt.Key_A)
        compare(field.text.length, 2, "the keys did not reach the field")

        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "Escape did not close the dialog once something had been typed")
    }

    function test_escape_closes_the_dialog_with_the_x_focused() {
        var host = showPane(1200)
        var dlg  = openDialog(host)
        var close = findByName(host.contentItem, "newPlaylistClose")
        close.forceActiveFocus()
        compare(close.activeFocus, true, "the dialog's X cannot take focus")

        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "Escape was swallowed by the focused X")
    }

    // ── and the mid-save guard, which must survive all of the above ──────
    //
    // A dialog dismissed under a create that is still going to answer leaves the
    // callback writing into a dialog the user has left, and leaves them unable to
    // tell whether the playlist was made. Escape already refused; the X must refuse
    // for the same reason Cancel does.
    function test_nothing_closes_the_dialog_while_a_create_is_in_flight() {
        var host = showPane(1200)
        var dlg  = openDialog(host)
        var field = findByName(host.contentItem, "newPlaylistField")
        tryVerify(function () { return field.activeFocus }, settleMs, "the field never took focus")
        keyClick(Qt.Key_T); keyClick(Qt.Key_A); keyClick(Qt.Key_P); keyClick(Qt.Key_E)

        bridge.setDeferCreatePlaylistForTest(true)
        dlg.submit()
        tryVerify(function () { return dlg.busy }, settleMs, "the dialog never went in-flight")
        compare(bridge.pendingCreatePlaylistsForTest(), 1, "the create is not actually held")

        var close = findByName(host.contentItem, "newPlaylistClose")
        verify(close, "the dialog has no close button")
        compare(close.enabled, false, "the X stays live under a create that is still going")
        compare(close.activeFocusOnTab, false,
                "a disabled X is still in the tab order, so Tab lands on a dead control")

        // Every way out, one at a time.
        keyClick(Qt.Key_Escape)
        wait(50)
        verify(dlg.visible, "Escape closed the dialog mid-save")

        clickItem(host, close)
        wait(50)
        verify(dlg.visible, "the X closed the dialog mid-save")

        var cancel = findByName(host.contentItem, "newPlaylistCancel")
        verify(cancel, "the dialog has no Cancel button")
        compare(cancel.enabled, false, "Cancel stays live under a create that is still going")

        // And it does finish, so the guard is a hold and not a deadlock.
        bridge.flushCreatePlaylistsForTest()
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog never closed once the create answered")
        compare(bridge.createPlaylistCallsForTest(), 1, "the create went out more than once")
    }

    // ── the hero's length, the one number on that page with no live source ──
    //
    // The count beside it reads tracks.length and is live. The length arrives once,
    // from fetchPlaylist() at load, so taking a song off left the line reading the
    // old figure next to the new count - "4 tracks • 25 min" where 25 minutes was
    // what five tracks came to.
    //
    // The fixture gives the page a five-track length and then has the server report
    // the four-track one, so a page that kept what it was handed fails.
    function test_the_playlist_pages_length_follows_a_removal() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        bridge.setPlaylistForTest({ uuid: "p-tape", title: "Tape", description: "",
                                    numTracks: 1, duration: 1500, coverUrl: "",
                                    type: "USER" })
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        compare(page.playlistDuration, 1500, "the page did not take the length it was served")

        bridge.setPlaylistHeaderForTest("p-tape",
            { uuid: "p-tape", title: "Tape", numTracks: 0, duration: 0, coverUrl: "" })
        var row = firstTrackRow(host)
        verify(row, "the playlist page built no track row")
        row.removeFromPlaylistRequested(0)
        settle(host.contentItem)

        compare(page.tracks.length, 0, "the removal did not take the song off the page")
        compare(page.playlistDuration, 0,
                "the hero still reports the length the playlist had before the removal")
    }

    // ...and it does not go back to the network to learn it. The bridge has already
    // re-read the header; a second request for the same URL would be the round trip
    // the picker had removed, put back one page over.
    function test_the_pages_length_comes_from_the_cache_not_a_second_request() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        bridge.setPlaylistForTest({ uuid: "p-tape", title: "Tape", description: "",
                                    numTracks: 1, duration: 1500, coverUrl: "",
                                    type: "USER" })
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        var headerFetches = bridge.playlistFetchCountForTest()

        bridge.setPlaylistHeaderForTest("p-tape",
            { uuid: "p-tape", title: "Tape", numTracks: 0, duration: 0, coverUrl: "" })
        var row = firstTrackRow(host)
        row.removeFromPlaylistRequested(0)
        settle(host.contentItem)

        compare(page.playlistDuration, 0, "the page did not take the new length")
        compare(bridge.playlistFetchCountForTest(), headerFetches,
                "the page asked the account for a header the bridge had already read")
    }

    // A cache row that reports no length and some tracks is a row the sign-in
    // paging has not filled in, not an empty playlist, and must not blank a figure
    // the page was handed.
    function test_an_unfilled_cache_row_does_not_blank_the_pages_length() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        bridge.setPlaylistForTest({ uuid: "p-tape", title: "Tape", description: "",
                                    numTracks: 1, duration: 1500, coverUrl: "",
                                    type: "USER" })
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        compare(page.playlistDuration, 1500, "the page did not take the length it was served")

        // Four tracks, no length: the shape a half-paged row has.
        bridge.setPlaylistHeaderForTest("p-tape",
            { uuid: "p-tape", title: "Tape", numTracks: 4, duration: 0, coverUrl: "" })
        bridge.addTracksToPlaylist("p-tape", 9001, function (ok) {})
        settle(host.contentItem)

        compare(page.playlistDuration, 1500,
                "a cache row with no length in it blanked the page's own figure")
    }

    // ── a song added to the playlist being looked at ─────────────────────
    //
    // Every row on the page carries the shared picker, so the playlist a song can
    // be put on includes the one on screen. Nothing updated the tracklist for that,
    // so the song went in and the page did not show it - with the count beside the
    // title one short, because that count is tracks.length.
    function test_a_song_added_to_the_open_playlist_appears_on_the_page() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        bridge.setPlaylistForTest({ uuid: "p-tape", title: "Tape", description: "",
                                    numTracks: 1, duration: 200, coverUrl: "",
                                    type: "USER" })
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        compare(page.tracks.length, 1, "the page did not load its one track")
        var fetchesAtLoad = bridge.playlistTracksFetchesForTest()

        // The endpoint will answer two tracks next time, and the header says two.
        var second = makeTrack()
        second.id = 9002
        second.title = "Der zweite Titel"
        bridge.setPlaylistTracksForTest([makeTrack(), second])
        bridge.setPlaylistHeaderForTest("p-tape",
            { uuid: "p-tape", title: "Tape", numTracks: 2, duration: 418, coverUrl: "" })

        bridge.addTracksToPlaylist("p-tape", 9002, function (ok) {})
        settle(host.contentItem)

        compare(page.tracks.length, 2,
                "a song added to the playlist on screen never appeared on it")
        compare(bridge.playlistTracksFetchesForTest(), fetchesAtLoad + 1,
                "the page asked for its tracklist "
                + (bridge.playlistTracksFetchesForTest() - fetchesAtLoad)
                + " times where it should ask once")
    }

    // ...and a removal, where the page has already spliced its own list to match,
    // asks for nothing. This is the case that makes the disagreement test above
    // affordable: without the guard every tidy-up would re-fetch the whole list.
    function test_a_removal_does_not_re_fetch_the_tracklist() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        bridge.setPlaylistForTest({ uuid: "p-tape", title: "Tape", description: "",
                                    numTracks: 1, duration: 200, coverUrl: "",
                                    type: "USER" })
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        var fetchesAtLoad = bridge.playlistTracksFetchesForTest()

        bridge.setPlaylistHeaderForTest("p-tape",
            { uuid: "p-tape", title: "Tape", numTracks: 0, duration: 0, coverUrl: "" })
        var row = firstTrackRow(host)
        verify(row, "the playlist page built no track row")
        row.removeFromPlaylistRequested(0)
        settle(host.contentItem)

        compare(page.tracks.length, 0, "the removal did not take the song off the page")
        compare(bridge.playlistTracksFetchesForTest(), fetchesAtLoad,
                "a removal re-fetched the whole tracklist although the page had "
                + "already spliced it to match")
    }

    // The regression this is wired to avoid, as its own case.
    //
    // favoritePlaylistsChanged says only "the playlist list moved". It fires on
    // every page of the sign-in paging and on every markPlaylistPlayed - which is
    // to say, on pressing Play on this very page. A page that read its length off
    // that signal would, for a playlist edited on another device, throw away the
    // header it had just fetched and take the stale cached figure instead. So the
    // page listens to playlistStatsRefreshed, which names the playlist and only
    // goes out after a contents change.
    //
    // setUserPlaylistsForTest raises favoritePlaylistsChanged and nothing else,
    // which is exactly the shape of that event.
    function test_a_bare_playlist_list_change_does_not_touch_the_pages_length() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        bridge.setPlaylistForTest({ uuid: "p-tape", title: "Tape", description: "",
                                    numTracks: 1, duration: 1500, coverUrl: "",
                                    type: "USER" })
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        compare(page.playlistDuration, 1500, "the page did not take the length it was served")

        // The cache disagrees, the way it does for a playlist changed elsewhere and
        // not yet re-paged. Nothing about *this* playlist's contents has happened.
        bridge.setUserPlaylistsForTest([
            { uuid: "p-tape", title: "Tape", description: "", coverUrl: "",
              numTracks: 9, duration: 9999, type: "USER" }
        ])
        settle(host.contentItem)

        compare(page.playlistDuration, 1500,
                "the page threw away the length it fetched and took a stale cached one, "
                + "which is what happens on every Play if this is wired to "
                + "favoritePlaylistsChanged")
    }

    function test_a_refused_removal_repairs_nothing() {
        bridge.setPlaylistTracksForTest([makeTrack()])
        var host = showPane(1200)
        var page = showPlaylistPage(host)
        var row = firstTrackRow(host)
        verify(row, "the playlist page built no track row")
        bridge.setRemoveFromPlaylistOkForTest(false)
        bridge.setPlaylistHeaderForTest("p-tape",
            { uuid: "p-tape", title: "Tape", numTracks: 0, duration: 0, coverUrl: "" })

        row.removeFromPlaylistRequested(0)
        settle(host.contentItem)

        compare(bridge.playlistHeaderReadsForTest(), 0,
                "a refused removal still went back for the playlist's header")
    }
}
