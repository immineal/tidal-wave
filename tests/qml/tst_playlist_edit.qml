// Renaming a playlist, and the picker that had been asking the network for
// something it was standing next to.
//
// Two defects of the same shape, which is why they share a file: a playlist
// write path whose interface existed and whose write did not.
//
//  * PlaylistPage's "Edit Playlist" dialog wrote the new title and description
//    into two of the page's own properties and stopped. There was no call, no
//    error path and no sign that anything was missing, so the rename was gone
//    the moment the page was left - data loss with a confirmation attached.
//    TidalClient::editPlaylist, TidalBridge::editPlaylist and the
//    playlistUpdated signal behind it are all new; nothing like them existed.
//
//  * TrackRow's "Add to playlist" picker called fetchUserPlaylists on every
//    open while bridge.getUserPlaylists() already held the same list, sorted,
//    in memory. A playlist made a second ago in the sidebar was missing from
//    the picker until a round trip answered.
//
// Everything here goes through the stubs in tests/TestStubs.h. No account is
// touched and nothing reaches the network: StubBridge::editPlaylist mirrors
// the real one, down to editing the favourites row in place rather than
// re-appending it and to raising playlistUpdated separately for the sidebar,
// which installTestStubs() hands to StubLibrary::updatePlaylist exactly as
// Application::run() must hand the real pair to each other.
//
// The whole of the second half rests on StubBridge::fetchUserPlaylists having
// stopped answering an empty array for every input. Before that the picker's
// *list* could not be driven from a QML test at all - only the declared "New
// playlist…" row above it - so "the picker shows the right playlists" and
// "the picker shows nothing" were the same green.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "PlaylistEdit"
    when: windowShown
    // TestCase declares visible: false, which would make every child report
    // visible == false and stop a synthesized mouse event ever arriving.
    visible: true
    width: 1280
    height: 900

    readonly property int settleMs: 2000

    // ── fixtures ─────────────────────────────────────────────────────────

    // The playlist under test is "p-mid", and it is deliberately neither the
    // first nor the last row anywhere it appears.
    //
    // In the sidebar it sits *below* an unpinned album and below two pinned
    // rows, so "renaming does not move the row" has somewhere to fail: a
    // version that re-stamped the row, or that handed the rename to
    // addPlaylist, would lift it to the head of the unpinned block and the
    // order assertion would catch it. A fixture where the renamed row is
    // already at the top cannot tell a correct rename from a re-stamp.
    //
    // The new title also sorts *first* alphabetically ("Abends am Fluss"),
    // so a list that quietly re-collated on the rename would move it too.
    function makeEntries() {
        return [
            { kind: "playlist", id: "p-pin", title: "Angepinnte Liste",  subtitle: "",                 imageUrl: "cdn/pp.jpg", pinned: true,  trackCount: 4  },
            { kind: "album",    id: "a-pin", title: "Angepinntes Album", subtitle: "Pin Artist",       imageUrl: "cdn/ap.jpg", pinned: true,  trackCount: 9  },
            { kind: "album",    id: "a1",    title: "Morgenrot",         subtitle: "Erster Interpret", imageUrl: "cdn/a1.jpg", pinned: false, trackCount: 11 },
            { kind: "playlist", id: "p-mid", title: "Zugfahrt",          subtitle: "",                 imageUrl: "cdn/pm.jpg", pinned: false, trackCount: 31 },
            { kind: "playlist", id: "p-end", title: "Winterabend",       subtitle: "",                 imageUrl: "cdn/pe.jpg", pinned: false, trackCount: 7  }
        ]
    }

    // The bridge's own cache, which is a different list from the sidebar's and
    // has to be shown to move separately. "p-mid" is the middle row here too,
    // so a stub (or a bridge) that removed and re-appended the renamed row
    // instead of editing it in place would show up as a reordering.
    //
    // Each row carries a distinct numTracks and coverUrl, because a rename
    // must not disturb either and a fixture of identical rows could not say so.
    function makeCache() {
        return [
            { id: 401, uuid: "p-first", title: "Alte Liste",  description: "unberührt",
              coverUrl: "cdn/c1.jpg", numTracks: 12, duration: 2400, type: "USER" },
            { id: 402, uuid: "p-mid",   title: "Zugfahrt",    description: "Für die Bahn",
              coverUrl: "cdn/c2.jpg", numTracks: 31, duration: 5400, type: "USER" },
            { id: 403, uuid: "p-end",   title: "Winterabend", description: "",
              coverUrl: "cdn/c3.jpg", numTracks: 7,  duration: 1500, type: "USER" }
        ]
    }

    // What fetchPlaylist() answers for the page under test. `type: "USER"` is
    // the field that decides whether the Edit pill is drawn at all.
    function makeHeader() {
        return { uuid: "p-mid", title: "Zugfahrt", description: "Für die Bahn",
                 numTracks: 31, duration: 5400, coverUrl: "cdn/c2.jpg", type: "USER" }
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
        auth.setUsernameForTest("robin")
        library.setEntriesForTest(makeEntries())
        library.setTracksForTest([])
        library.resetCallsForTest()
        pins.setItemsForTest([])
        bridge.resetForTest()
        bridge.setUserPlaylistsForTest([])
        bridge.setPlaylistForTest(makeHeader())
    }

    function cleanup() {
        bridge.resetForTest()
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

    Component { id: playlistC;  PlaylistPage  { anchors.fill: parent } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: trackRowC;  TrackRow { } }

    Component {
        id: shellHost
        Window {
            property alias sidebar: sb
            width: 1280
            height: 900
            RowLayout {
                anchors.fill: parent
                spacing: 0
                SideBar {
                    id: sb
                    hostWidth: parent.width
                    Layout.preferredWidth: sb.reservedWidth
                    Layout.fillHeight: true
                }
                Item { Layout.fillWidth: true; Layout.fillHeight: true }
            }
        }
    }

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

    function showShell(w) {
        var host = createTemporaryObject(shellHost, testCase)
        verify(host, "the host window was not created")
        host.width = w
        host.visible = true
        waitForRendering(host.contentItem, settleMs)
        mouseMove(host.contentItem, w - 8, host.height - 8)
        wait(1)
        tryVerify(function () {
            return host.sidebar.panelWidth === host.sidebar.targetWidth
        }, settleMs, "the sidebar never settled at " + w + "px")
        return host
    }

    // A PlaylistPage on "p-mid", with its Edit dialog already open on the
    // playlist's current title and description.
    function makePage(host) {
        var page = createTemporaryObject(playlistC, host.pane, {})
        verify(page, "PlaylistPage did not load")
        page.playlistUuid = "p-mid"
        settle(host.contentItem)
        compare(page.playlistTitle, "Zugfahrt", "the header fixture did not load")
        compare(page.playlistType, "USER",
                "the fixture is not a playlist the user may edit, so there is no Edit button")
        return page
    }

    function openEditor(host, page) {
        var btn = findByName(host.contentItem, "playlistEditButton")
        verify(btn, "the hero has no Edit button")
        verify(btn.visible, "the Edit button is not drawn on a playlist the user owns")
        mouseClick(btn)
        var dlg = page.editPopup
        verify(dlg, "there is no Edit dialog")
        tryVerify(function () { return dlg.visible }, settleMs,
                  "the Edit button opened nothing")
        settle(host.contentItem)
        return dlg
    }

    function inDialog(dialog, name) {
        verify(dialog, "there is no dialog to look in")
        var hit = findByName(dialog.contentItem, name)
        verify(hit, "the dialog has no \"" + name + "\"")
        return hit
    }

    function cacheTitles() {
        var out = []
        var pls = bridge.getUserPlaylists()
        for (var i = 0; i < pls.length; ++i) out.push(pls[i].title)
        return out
    }

    function cacheUuids() {
        var out = []
        var pls = bridge.getUserPlaylists()
        for (var i = 0; i < pls.length; ++i) out.push(pls[i].uuid)
        return out
    }

    function rowIds(sidebar) {
        var out = []
        for (var i = 0; i < sidebar.rows.length; ++i) out.push(sidebar.rows[i].id)
        return out
    }

    function rowTitles(sidebar) {
        var out = []
        for (var i = 0; i < sidebar.rows.length; ++i) out.push(sidebar.rows[i].title)
        return out
    }

    // ── the dialog opens on what is there ────────────────────────────────

    function test_the_dialog_opens_on_the_current_title_and_description() {
        var host = showPane(1200)
        var page = makePage(host)
        var dlg  = openEditor(host, page)

        compare(inDialog(dlg, "editPlaylistTitleField").text, "Zugfahrt",
                "the dialog did not open on the playlist's own name")
        compare(inDialog(dlg, "editPlaylistDescField").text, "Für die Bahn",
                "the dialog did not open on the playlist's own description")
        compare(inDialog(dlg, "editPlaylistError").visible, false,
                "the dialog opened complaining about something")
    }

    // The same cap the create dialog applies, stopped at the keyboard rather
    // than at the server. A paste is how a 4000-character title actually
    // arrives, and setting .text is a paste as far as maximumLength is
    // concerned, so this is the way in that matters.
    function test_a_renamed_playlist_cannot_run_past_the_cap() {
        var host = showPane(1200)
        var page = makePage(host)
        var dlg  = openEditor(host, page)

        var field = inDialog(dlg, "editPlaylistTitleField")
        var tooLong = ""
        for (var i = 0; i < 250; ++i) tooLong += "x"
        field.text = tooLong
        settle(host.contentItem)

        compare(field.text.length, 100,
                "the Edit dialog takes a name the server would refuse, where the "
                + "New playlist dialog stops at 100")
        page.saveEdits()
        settle(host.contentItem)
        compare(bridge.lastEditedTitleForTest().length, 100,
                "an over-long name was sent to the server")
    }

    // ── the rename actually leaves the machine ───────────────────────────

    // The defect itself. Saving used to assign root.playlistTitle and stop.
    function test_saving_sends_the_rename_to_the_account() {
        var host = showPane(1200)
        var page = makePage(host)
        var dlg  = openEditor(host, page)

        inDialog(dlg, "editPlaylistTitleField").text = "  Abends am Fluss  "
        inDialog(dlg, "editPlaylistDescField").text  = "  Neu beschrieben  "
        settle(host.contentItem)
        mouseClick(inDialog(dlg, "editPlaylistSave"))
        settle(host.contentItem)

        compare(bridge.editPlaylistCallsForTest(), 1,
                "the rename never left the machine")
        compare(bridge.lastEditedUuidForTest(), "p-mid",
                "the rename was sent for some other playlist")
        // Trimmed, like the create dialog's: a name with three leading spaces
        // is a name nobody meant to make. Both fields, because the description
        // goes through the same field and the same server call.
        compare(bridge.lastEditedTitleForTest(), "Abends am Fluss",
                "the padding went to the server with the name")
        compare(bridge.lastEditedDescriptionForTest(), "Neu beschrieben",
                "the padding went to the server with the description")
    }

    function test_a_saved_rename_shows_on_the_page_and_closes_the_dialog() {
        var host = showPane(1200)
        var page = makePage(host)
        var dlg  = openEditor(host, page)

        inDialog(dlg, "editPlaylistTitleField").text = "Abends am Fluss"
        inDialog(dlg, "editPlaylistDescField").text  = "Neu beschrieben"
        settle(host.contentItem)
        mouseClick(inDialog(dlg, "editPlaylistSave"))

        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog stayed up after a successful save")
        compare(page.playlistTitle, "Abends am Fluss",
                "the page kept the old name after a save that worked")
        compare(page.playlistDescription, "Neu beschrieben",
                "the page kept the old description after a save that worked")
    }

    // The case the old dialog could not have, because it never made a call:
    // the server refuses the rename. Writing the new name onto the page here
    // would be worse than the silence it replaces - it would be wrong rather
    // than merely absent.
    function test_a_refused_rename_is_not_shown_as_done() {
        bridge.setEditPlaylistOkForTest(false)
        var host = showPane(1200)
        var page = makePage(host)
        var dlg  = openEditor(host, page)

        inDialog(dlg, "editPlaylistTitleField").text = "Abends am Fluss"
        settle(host.contentItem)
        mouseClick(inDialog(dlg, "editPlaylistSave"))
        settle(host.contentItem)

        compare(bridge.editPlaylistCallsForTest(), 1, "the save was never attempted")
        compare(page.playlistTitle, "Zugfahrt",
                "a rename the server refused was shown on the page anyway")
        compare(page.playlistDescription, "Für die Bahn",
                "a description the server refused was shown on the page anyway")
        verify(dlg.visible, "the dialog closed on a failure, losing what was typed")
        var err = inDialog(dlg, "editPlaylistError")
        verify(err.visible && err.text.length > 0,
               "a refused rename said nothing; the error line reads \"" + err.text + "\"")
        // ...and the text is still there, so the answer to a failure is one
        // click and not retyping the name.
        compare(inDialog(dlg, "editPlaylistTitleField").text, "Abends am Fluss",
                "the dialog threw away what was typed")
    }

    // Reachable by pressing Return on an emptied field; the Save button is
    // already dark for it. A key that silently does nothing reads as a broken
    // dialog, and an empty name must certainly not be sent.
    function test_a_nameless_playlist_cannot_be_saved_data() {
        return [
            { tag: "nothing typed", typed: "" },
            { tag: "one space",     typed: " " },
            { tag: "only spaces",   typed: "   \t  " }
        ]
    }

    function test_a_nameless_playlist_cannot_be_saved(row) {
        var host = showPane(1200)
        var page = makePage(host)
        var dlg  = openEditor(host, page)

        inDialog(dlg, "editPlaylistTitleField").text = row.typed
        settle(host.contentItem)
        compare(inDialog(dlg, "editPlaylistSave").enabled, false,
                "Save is live with " + row.tag + " in the field")

        page.saveEdits()
        settle(host.contentItem)
        compare(bridge.editPlaylistCallsForTest(), 0,
                "a nameless playlist was sent to the server anyway")
        var err = inDialog(dlg, "editPlaylistError")
        verify(err.visible && err.text.length > 0,
               "Return with " + row.tag + " said nothing; the error line reads \""
               + err.text + "\"")
        verify(dlg.visible, "the dialog closed on an invalid name")
        compare(page.playlistTitle, "Zugfahrt",
                "an invalid name was written onto the page")
    }

    // ── the two caches ───────────────────────────────────────────────────

    // Cache one: the bridge's own favourites list, which is what the
    // Collection grid reads. Without this the grid shows the old name until
    // the next launch.
    function test_the_rename_reaches_the_collection_grid() {
        bridge.setUserPlaylistsForTest(makeCache())
        var host = showPane(1200)
        var col  = createTemporaryObject(collectionC, host.pane, {})
        verify(col, "CollectionPage did not load")
        col.activeTab = 3
        settle(host.contentItem)
        compare(col.filteredPlaylists.length, 3, "the grid fixture did not load")

        // Opened directly rather than through the hero's button: the grid is
        // in the same pane and a synthesized click would have two pages
        // stacked under it. The button's own path is covered above.
        var page = makePage(host)
        var dlg  = page.editPopup
        dlg.open()
        tryVerify(function () { return dlg.visible }, settleMs,
                  "the Edit dialog never opened")
        inDialog(dlg, "editPlaylistTitleField").text = "Abends am Fluss"
        settle(host.contentItem)
        page.saveEdits()
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog stayed up after a successful save")
        settle(host.contentItem)

        // The grid redrew itself off favoritePlaylistsChanged, with no refetch.
        compare(col.filteredPlaylists.length, 3,
                "the rename changed how many playlists there are")
        // The order first, so this has a failure of its own: a cache that
        // removed and re-appended the row instead of editing it in place
        // would shuffle the user's grid every time they fixed a typo, and
        // asserting the title at a fixed index afterwards would otherwise
        // swallow that case before this line ever ran.
        compare(cacheUuids().join(","), "p-first,p-mid,p-end",
                "the renamed playlist moved in the grid; it holds "
                + cacheTitles().join(", "))
        compare(col.filteredPlaylists[1].title, "Abends am Fluss",
                "the grid still shows the old name; it holds " + cacheTitles().join(", "))
        // ...and nothing else about the row moved with the name. The reply
        // carries no body, so a bridge that rebuilt the row from what it had
        // would blank both of these.
        compare(col.filteredPlaylists[1].numTracks, 31,
                "the rename lost the playlist's track count")
        compare(col.filteredPlaylists[1].coverUrl, "cdn/c2.jpg",
                "the rename lost the playlist's artwork")
    }

    // Cache two: the sidebar keeps a second, separate copy of the library, and
    // favoritePlaylistsChanged does not reach it. This is the hand-across.
    function test_the_rename_reaches_the_sidebar() {
        var host = showShell(1280)
        var sb   = host.sidebar
        compare(rowIds(sb).join(","), "p-pin,a-pin,a1,p-mid,p-end",
                "the sidebar fixture did not load in the order this case needs")
        var refreshesBefore = library.refreshCountForTest()

        var page = createTemporaryObject(playlistC, host.contentItem, {})
        verify(page, "PlaylistPage did not load")
        page.playlistUuid = "p-mid"
        settle(host.contentItem)

        page.editPopup.open()
        tryVerify(function () { return page.editPopup.visible }, settleMs,
                  "the Edit dialog never opened")
        inDialog(page.editPopup, "editPlaylistTitleField").text = "Abends am Fluss"
        settle(host.contentItem)
        page.saveEdits()
        tryVerify(function () { return !page.editPopup.visible }, settleMs,
                  "the dialog stayed up after a successful save")
        settle(host.contentItem)

        verify(rowTitles(sb).indexOf("Abends am Fluss") >= 0,
               "the sidebar still shows the old name; it holds " + rowTitles(sb).join(", "))
        // Exactly where it was. A rename is not an acquisition: a version that
        // re-stamped the row, or that handed the rename to addPlaylist, would
        // lift it to the head of the unpinned block - and the new name sorts
        // first alphabetically too, so a list that re-collated would move it
        // as well.
        compare(rowIds(sb).join(","), "p-pin,a-pin,a1,p-mid,p-end",
                "renaming a playlist moved it in the sidebar")
        // ...and it arrived by being handed across, not by re-reading the
        // account.
        compare(library.refreshCountForTest(), refreshesBefore,
                "the sidebar re-paged the whole library to change one label")
        compare(bridge.userPlaylistFetchCountForTest(), 0,
                "the sidebar re-fetched the account's playlists to change one label")
    }

    // ── the in-flight state ──────────────────────────────────────────────

    // A dialog that can be dismissed under a call that is still going to
    // answer leaves the user unable to tell whether the rename took, which is
    // the state the whole dialog was in before it had a call at all.
    function test_the_dialog_is_shut_while_the_save_is_out() {
        bridge.setDeferEditPlaylistForTest(true)
        var host = showPane(1200)
        var page = makePage(host)
        var dlg  = openEditor(host, page)

        inDialog(dlg, "editPlaylistTitleField").text = "Abends am Fluss"
        settle(host.contentItem)
        mouseClick(inDialog(dlg, "editPlaylistSave"))
        settle(host.contentItem)

        compare(bridge.pendingEditPlaylistsForTest(), 1, "the save is not in flight")
        verify(dlg.busy, "the dialog does not know a call is out")
        verify(dlg.visible, "the dialog closed while the save was still out")
        compare(inDialog(dlg, "editPlaylistTitleField").readOnly, true,
                "the name can still be typed into while it is on its way to the server")
        compare(inDialog(dlg, "editPlaylistDescField").readOnly, true,
                "the description can still be typed into while the save is out")
        compare(inDialog(dlg, "editPlaylistSave").enabled, false,
                "Save can be pressed a second time while the first is still out")
        compare(inDialog(dlg, "editPlaylistCancel").enabled, false,
                "Cancel is live while the save is out")
        compare(dlg.closePolicy, Popup.NoAutoClose,
                "Escape or a click outside still closes the dialog mid-save")

        bridge.flushEditPlaylistRepliesForTest()
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog never closed once the save answered")
        compare(bridge.editPlaylistCallsForTest(), 1,
                "the save went out more than once")
        compare(page.playlistTitle, "Abends am Fluss",
                "the page did not take the name once the save answered")
    }

    // ── the picker reads the cache ───────────────────────────────────────

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

    // The fixture probe for everything below: with the stub answering an empty
    // array for every fetch, this list was empty whatever the account held, so
    // no assertion about its contents could fail.
    function test_the_picker_shows_the_playlists_the_account_has() {
        bridge.setUserPlaylistsForTest(makeCache())
        var host = showPane(1200)
        makePicker(host)

        var list = pickerList(host)
        compare(list.count, 3,
                "the picker lists " + list.count + " playlists where the account has 3")
        compare(list.itemAtIndex(0) !== null, true, "the picker's first row was never built")
    }

    // The defect: it went back to the network every time, while the bridge was
    // holding the same list sorted in memory.
    function test_the_picker_does_not_go_to_the_network_for_a_list_it_has() {
        bridge.setUserPlaylistsForTest(makeCache())
        var host = showPane(1200)
        makePicker(host)

        compare(pickerList(host).count, 3, "the picker did not fill from the cache")
        compare(bridge.userPlaylistFetchCountForTest(), 0,
                "the picker fetched the account's playlists although the bridge held them")
    }

    // The consequence a user sees, and the reason the cache is the right
    // source rather than merely the cheaper one: a playlist made a moment ago
    // is in the bridge's list straight away, and was missing from the picker
    // until a round trip answered.
    function test_a_playlist_just_created_is_in_the_picker_at_once() {
        bridge.setUserPlaylistsForTest(makeCache())
        var host = showPane(1200)
        var row  = makePicker(host)
        compare(pickerList(host).count, 3, "the picker did not fill from the cache")
        row.playlistPicker.close()
        settle(host.contentItem)

        // Made somewhere else entirely - the sidebar's dialog, in the app -
        // which is to say: through the bridge and not through this row.
        bridge.createPlaylist("Ganz frisch", function (pl, err) {})
        settle(host.contentItem)
        compare(cacheTitles().length, 4, "the bridge did not take the new playlist")

        row.openPicker()
        settle(host.contentItem)
        compare(pickerList(host).count, 4,
                "the playlist made a moment ago is not in the picker")
        compare(bridge.userPlaylistFetchCountForTest(), 0,
                "the picker needed a round trip to see a playlist it already had")
    }

    // The one case that still needs the network. An empty cache cannot be told
    // apart from a cache the sign-in paging has not reached yet, which is
    // exactly the state the first picker of a session opens in.
    function test_an_empty_cache_still_asks_the_account() {
        bridge.setUserPlaylistsForTest([])
        var host = showPane(1200)
        makePicker(host)

        compare(bridge.userPlaylistFetchCountForTest(), 1,
                "an empty cache went unquestioned, so a picker opened before the "
                + "library had paged in would stay empty for the session")
        compare(bridge.lastUserPlaylistLimitForTest(), 50,
                "the picker asked for a different page than it used to")
        compare(bridge.lastUserPlaylistOffsetForTest(), 0,
                "the picker asked for a page other than the first")
    }

    // ...and then it has to use what comes back. This is the state the app is
    // really in for the first second of a session: the account has playlists
    // and the bridge's in-memory copy has not received them yet, which is
    // precisely when the first picker opens.
    //
    // The case that could not be written at all until StubBridge's
    // fetchUserPlaylists stopped answering an empty array for every input: the
    // picker's list would have been empty here whatever the account held, and
    // a picker that ignored the reply entirely would have passed.
    function test_the_picker_fills_from_the_fetch_when_the_cache_is_cold() {
        bridge.setUserPlaylistsForTest([])                 // still paging in
        bridge.setFetchedUserPlaylistsForTest(makeCache()) // what the account has
        var host = showPane(1200)
        makePicker(host)

        compare(bridge.userPlaylistFetchCountForTest(), 1, "the cold cache was not questioned")
        tryVerify(function () { return pickerList(host).count === 3 }, settleMs,
                  "the picker asked the account and then ignored the answer; it lists "
                  + pickerList(host).count + " of 3")
    }

    // The stub itself, because the cases above lean on it and a stub
    // that ignored its arguments would make them all pass for the wrong
    // reason. The reported bug behind the fetch counter is a caller that
    // asked for 30 of 50 playlists; a fetch that answered the whole list
    // whatever it was asked could not reproduce it.
    function test_the_stubs_fetch_pages_the_way_the_endpoint_does() {
        bridge.setUserPlaylistsForTest(makeCache())
        var got = null
        bridge.fetchUserPlaylists(function (pls, err) { got = pls }, 2, 0)
        verify(got, "the stub never answered")
        compare(got.length, 2, "the stub ignored `limit` and answered " + got.length)
        compare(got[0].uuid, "p-first", "the first page did not start at the first row")

        bridge.fetchUserPlaylists(function (pls, err) { got = pls }, 2, 2)
        compare(got.length, 1, "the last page is the wrong length")
        compare(got[0].uuid, "p-end", "the stub ignored `offset`")

        bridge.fetchUserPlaylists(function (pls, err) { got = pls }, 50, 99)
        compare(got.length, 0, "a page past the end answered rows that are not there")
    }

    // ── and what the picker's rows then do ───────────────────────────────
    //
    // Reachable only now. With the stub answering empty, this list had no rows
    // to press, so the picker's existing-playlist path - the common one - had
    // never been exercised from a test at all.

    function test_pressing_a_row_files_the_song_in_that_playlist() {
        bridge.setUserPlaylistsForTest(makeCache())
        var host = showPane(1200)
        var row  = makePicker(host)

        var list = pickerList(host)
        compare(list.count, 3, "the picker did not fill from the cache")
        // The *second* row. Pressing the first could not tell "the row that was
        // pressed" apart from "whatever the list happens to start with".
        var target = list.itemAtIndex(1)
        verify(target, "the picker's second row was never built")
        mouseClick(target)
        settle(host.contentItem)

        compare(bridge.addToPlaylistCallsForTest(), 1, "the song was never filed")
        compare(bridge.lastAddedPlaylistForTest(), "p-mid",
                "the song went into some other playlist than the row that was pressed")
        compare(bridge.lastAddedTrackIdForTest(), 9001, "some other song was added")
        // ...and the row says so, naming the playlist it went into.
        verify(row.lastConfirmation.indexOf("Zugfahrt") >= 0,
               "the row said \"" + row.lastConfirmation
               + "\" rather than naming the playlist the song went into")
    }

    // The other half of that path: the server refuses the add. Reported, and
    // reported as a failure.
    function test_a_refused_add_from_a_picker_row_is_not_called_a_success() {
        bridge.setUserPlaylistsForTest(makeCache())
        bridge.setAddToPlaylistOkForTest(false)
        var host = showPane(1200)
        var row  = makePicker(host)

        var list = pickerList(host)
        var target = list.itemAtIndex(1)
        verify(target, "the picker's second row was never built")
        mouseClick(target)
        settle(host.contentItem)

        compare(bridge.addToPlaylistCallsForTest(), 1, "the add was never attempted")
        verify(row.lastConfirmation.length > 0, "a failed add said nothing at all")
        verify(row.lastConfirmation.indexOf("Could not") >= 0,
               "a failed add was reported as a success: \"" + row.lastConfirmation + "\"")
    }
}
