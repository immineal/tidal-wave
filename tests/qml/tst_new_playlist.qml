// Making a playlist: the three entry points, the dialog they share, and the
// two lists that have to show the new playlist without a refresh.
// StubBridge::createPlaylist mirrors the real one: on success it appends to
// the favourites cache, raises favoritePlaylistsChanged, and raises
// playlistCreated, which installTestStubs() hands to StubLibrary::addPlaylist.
// The stub's error, uuid and deferral hooks reach each of the dialog's outcomes.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "NewPlaylist"
    when: windowShown
    // TestCase declares visible: false, which would make every child report
    // visible == false and stop a synthesized mouse event ever arriving.
    visible: true
    width: 1280
    height: 900

    readonly property int settleMs: 2000
    // NewPlaylistDialog.maxTitleLength, repeated so a change to the cap fails
    // here.
    readonly property int titleCap: 100
    // Prefs::railBreakpoint, same reason.
    readonly property int railBreak: 820

    // ── fixtures ─────────────────────────────────────────────────────────
    // Two pinned rows at the head, because a created playlist belongs at the
    // top of the unpinned block. The unpinned titles both start with A, so a
    // playlist named Zugfahrt can only reach the front by its date.

    function makeEntries() {
        return [
            { kind: "playlist", id: "p-pin", title: "Angepinnte Liste",  subtitle: "",                imageUrl: "cdn/pp.jpg", pinned: true,  trackCount: 4  },
            { kind: "album",    id: "a-pin", title: "Angepinntes Album", subtitle: "Pin Artist",      imageUrl: "cdn/ap.jpg", pinned: true,  trackCount: 9  },
            { kind: "album",    id: "a1",    title: "Abendrot",          subtitle: "Erster Interpret", imageUrl: "cdn/a1.jpg", pinned: false, trackCount: 11 },
            { kind: "playlist", id: "p-old", title: "Alte Liste",        subtitle: "",                imageUrl: "cdn/po.jpg", pinned: false, trackCount: 31 }
        ]
    }

    function makePlaylists(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 400 + i, uuid: "uuid-" + i,
                       title: "Eine gespeicherte Wiedergabeliste " + (i + 1),
                       description: "", coverUrl: "", numTracks: 24,
                       duration: 5400, type: "USER" })
        return out
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

    // A Popup is not a visual child of whatever declared it, so its field and
    // its buttons are reached through the dialog's own content item.
    function inDialog(dialog, name) {
        verify(dialog, "there is no dialog to look in")
        var hit = findByName(dialog.contentItem, name)
        verify(hit, "the dialog has no \"" + name + "\"")
        return hit
    }

    // The library list's ids, in order.
    function rowIds(sidebar) {
        var out = []
        for (var i = 0; i < sidebar.rows.length; ++i) out.push(sidebar.rows[i].id)
        return out
    }

    function playlistTitles() {
        var out = []
        var pls = bridge.getUserPlaylists()
        for (var i = 0; i < pls.length; ++i) out.push(pls[i].title)
        return out
    }

    Component { id: dialogC;     NewPlaylistDialog { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: trackRowC;   TrackRow { } }

    // The sidebar host, mirroring Main.qml: a RowLayout holding the SideBar
    // and the content pane. A real Window, because every dialog here centres
    // on the window's overlay and `Overlay.overlay` is null without one.
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

    // A bare window for the cases that are not about the sidebar. It has
    // Main.qml's navigate(), so a navigation is recorded and one that should
    // not happen can be asserted.
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

    function showShell(w) {
        var host = createTemporaryObject(shellHost, testCase)
        verify(host, "the host window was not created")
        host.width = w
        host.visible = true
        waitForRendering(host.contentItem, settleMs)
        // Park the pointer clear of the rail: a freshly shown window inherits the
        // position of the last synthesized event, which under the offscreen
        // platform is often inside the sidebar and would hover-expand it.
        mouseMove(host.contentItem, w - 8, host.height - 8)
        wait(1)
        tryVerify(function () {
            return host.sidebar.panelWidth === host.sidebar.targetWidth
        }, settleMs, "the sidebar never settled at " + w + "px")
        return host
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

    // A dialog on its own, for the cases that are about the dialog itself.
    function makeDialog() {
        var host = showPane(1200)
        var dlg = createTemporaryObject(dialogC, host.pane, {})
        verify(dlg, "NewPlaylistDialog did not load - is it in the module's QML_FILES?")
        dlg.openEmpty()
        tryVerify(function () { return dlg.visible }, settleMs, "the dialog never opened")
        settle(host.contentItem)
        return dlg
    }

    // ── the dialog: what counts as a name ────────────────────────────────

    // Empty and all-spaces are the same mistake and have to be the same
    // answer; the second is the one a dialog that only checks `length` lets
    // through.
    function test_a_nameless_playlist_cannot_be_made_data() {
        return [
            { tag: "nothing typed", typed: "" },
            { tag: "one space",     typed: " " },
            { tag: "only spaces",   typed: "   \t  " }
        ]
    }

    function test_a_nameless_playlist_cannot_be_made(row) {
        var dlg = makeDialog()
        inDialog(dlg, "newPlaylistField").text = row.typed
        settle(dlg.contentItem)

        compare(inDialog(dlg, "newPlaylistCreate").enabled, false,
                "Create is live with " + row.tag + " in the field")

        // Pressing Return anyway has to say what is missing.
        dlg.submit()
        var err = inDialog(dlg, "newPlaylistError")
        verify(err.visible && err.text.length > 0,
               "Return with " + row.tag + " said nothing; the error line reads \""
               + err.text + "\"")
        compare(bridge.createPlaylistCallsForTest(), 0,
                "a nameless playlist was sent to the server anyway")
        verify(dlg.visible, "the dialog closed on an invalid name")
    }

    // The name as the server sees it: trimmed, because a title with three
    // leading spaces is a title nobody meant to make.
    function test_the_name_is_trimmed_before_it_is_sent() {
        var dlg = makeDialog()
        inDialog(dlg, "newPlaylistField").text = "   Strandfahrt 1998   "
        settle(dlg.contentItem)

        compare(inDialog(dlg, "newPlaylistCreate").enabled, true,
                "Create stayed dark for a name that is merely padded")
        dlg.submit()

        compare(bridge.createPlaylistCallsForTest(), 1, "the create never went out")
        compare(bridge.lastCreatedTitleForTest(), "Strandfahrt 1998",
                "the padding went to the server with the name")
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog stayed up after a successful create")
    }

    // The over-long case, stopped at the keyboard. A paste, which is how a
    // title that long arrives, has to be stopped by the same rule.
    function test_a_name_cannot_run_past_the_cap() {
        var dlg = makeDialog()
        var field = inDialog(dlg, "newPlaylistField")
        var tooLong = ""
        for (var i = 0; i < 250; ++i) tooLong += "x"
        field.text = tooLong
        settle(dlg.contentItem)

        compare(field.text.length, titleCap,
                "the field kept " + field.text.length + " characters")
        verify(inDialog(dlg, "newPlaylistCounter").visible,
               "nothing says why the typing stopped at " + titleCap)

        dlg.submit()
        compare(bridge.lastCreatedTitleForTest().length, titleCap,
                "an over-long title reached the server")
    }

    // The dialog is clamped to the window, whose declared minimum is 640x600
    // (Main.qml). Hit targets and focus rings are drawn a few px outside
    // their item on purpose, so an overflow only counts past this slack.
    readonly property real overflowSlack: 8

    function audit(item, label, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number" || c.width <= 0) continue
            var here = label + " > " + (c.objectName.length > 0
                                        ? c.objectName : ("" + c).split("(")[0])
            // Mapped, because a VectorIcon is a Shape drawn at its design size and
            // scaled down by a transform, so its own width overstates it.
            var l = c.mapToItem(item, 0, 0).x
            var r = c.mapToItem(item, c.width, 0).x
            if (r < l) { var swap = l; l = r; r = swap }
            if (l < -overflowSlack || r > item.width + overflowSlack)
                out.push(here + " spans " + l.toFixed(1) + ".." + r.toFixed(1)
                         + " in a parent " + item.width.toFixed(1) + " wide")
            if (c.truncated !== undefined && c.elide === Text.ElideNone
                    && ("" + c.text).length > 0 && c.truncated)
                out.push(here + ": \"" + c.text + "\" is clipped with no elide mode")
            audit(c, here, out)
        }
        return out
    }

    function test_the_dialog_fits_the_smallest_window() {
        var host = showPane(640)
        host.height = 600
        waitForRendering(host.contentItem, settleMs)
        var dlg = createTemporaryObject(dialogC, host.pane, {})
        verify(dlg, "NewPlaylistDialog did not load")
        dlg.openEmpty()
        tryVerify(function () { return dlg.visible }, settleMs, "the dialog never opened")
        // The widest it ever gets: the long label on the Create button, a German
        // error line below the field, and a name past counterShowsFrom so the
        // counter is out beside that error.
        var field = inDialog(dlg, "newPlaylistField")
        field.text = "Ein ziemlich langer Name für eine Playlist, aufgenommen im Sommer 1998 "
                   + "an der Ostsee"
        verify(field.text.length >= dlg.maxTitleLength - 20,
               "the name is too short to bring the counter out (" + field.text.length + ")")
        dlg.errorText = "Playlist konnte nicht erstellt werden: 503 Service Unavailable"
        dlg.busy = true
        settle(host.contentItem)
        verify(inDialog(dlg, "newPlaylistCounter").visible, "the counter is not out")
        verify(inDialog(dlg, "newPlaylistError").visible, "the error line is not out")

        var faults = audit(dlg.contentItem, "NewPlaylistDialog@640x600", [])
        verify(faults.length === 0, faults.join("\n  "))
        dlg.busy = false
    }

    // 360px is below the app's 640 minimum on purpose. At 640 the clamp
    // never binds, so a width assertion there passes with or without it.
    function test_the_dialog_is_clamped_to_a_window_narrower_than_itself() {
        var host = showPane(360)
        var dlg = createTemporaryObject(dialogC, host.pane, {})
        verify(dlg, "NewPlaylistDialog did not load")
        dlg.openEmpty()
        tryVerify(function () { return dlg.visible }, settleMs, "the dialog never opened")
        inDialog(dlg, "newPlaylistField").text = "Zugfahrt"
        dlg.errorText = "Playlist konnte nicht erstellt werden: 503 Service Unavailable"
        settle(host.contentItem)

        verify(dlg.width <= 360 - 48 + 0.5,
               "the dialog is " + dlg.width.toFixed(1)
               + "px wide in a 360px window; the clamp allows " + (360 - 48))
        var faults = audit(dlg.contentItem, "NewPlaylistDialog@360", [])
        verify(faults.length === 0, faults.join("\n  "))
    }

    // The counter is for the end of the field: on a short name it would be
    // noise.
    function test_the_counter_keeps_out_of_a_short_name_s_way() {
        var dlg = makeDialog()
        inDialog(dlg, "newPlaylistField").text = "Strandfahrt"
        settle(dlg.contentItem)
        compare(inDialog(dlg, "newPlaylistCounter").visible, false,
                "the character counter is up for an eleven-character name")
    }

    // ── the dialog: while the call is out ────────────────────────────────
    // Only reachable with the reply held: the stub otherwise answers in the
    // same turn.
    function test_the_dialog_says_it_is_working_while_the_call_is_out() {
        bridge.setDeferCreatePlaylistForTest(true)
        var dlg = makeDialog()
        var field = inDialog(dlg, "newPlaylistField")
        field.text = "Nachtfahrt"
        dlg.submit()
        settle(dlg.contentItem)

        compare(bridge.pendingCreatePlaylistsForTest(), 1, "the create never went out")
        compare(dlg.busy, true, "the dialog does not know a call is out")
        verify(dlg.visible, "the dialog went away while its call was still out")
        compare(field.readOnly, true, "the name can still be edited mid-flight")
        compare(inDialog(dlg, "newPlaylistCreate").enabled, false,
                "Create can be pressed again while the first press is still out")
        compare(inDialog(dlg, "newPlaylistCancel").enabled, false,
                "Cancel is live under a call that is still going to answer")
        // Neither Escape nor a click outside may take the dialog away under a
        // reply that has not arrived.
        compare(dlg.closePolicy, Popup.NoAutoClose,
                "the dialog can still be dismissed mid-flight")

        // A second press must not make a second playlist.
        dlg.submit()
        compare(bridge.createPlaylistCallsForTest(), 1,
                "submitting twice sent two playlists")

        bridge.flushCreatePlaylistsForTest()
        tryVerify(function () { return !dlg.busy }, settleMs,
                  "the dialog stayed busy after the reply arrived")
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog stayed up after a successful create")
    }

    // ── the dialog: the two ways it can fail ─────────────────────────────

    function test_a_failed_create_says_so_and_keeps_the_name() {
        bridge.setCreatePlaylistErrorForTest("401 Unauthorized")
        var dlg = makeDialog()
        var field = inDialog(dlg, "newPlaylistField")
        field.text = "Nachtfahrt"
        dlg.submit()
        settle(dlg.contentItem)

        var err = inDialog(dlg, "newPlaylistError")
        verify(err.visible && err.text.length > 0, "a failed create said nothing at all")
        verify(err.text.indexOf("401 Unauthorized") >= 0,
               "the reason was dropped; the error line reads \"" + err.text + "\"")
        verify(dlg.visible, "the dialog closed on a failure, losing the name with it")
        compare(field.text, "Nachtfahrt", "the name was thrown away on a failure")
        compare(dlg.busy, false, "the dialog is stuck in its in-flight state")
        compare(library.entries.length, makeEntries().length,
                "a failed create still put a row in the sidebar")
        compare(bridge.getUserPlaylists().length, 0,
                "a failed create still put a row in the collection")
    }

    // A 200 that parsed to nothing. The bridge treats that as a failure, and
    // so must the dialog.
    function test_a_reply_with_no_playlist_in_it_is_a_failure() {
        bridge.setCreatePlaylistUuidForTest("")
        var dlg = makeDialog()
        inDialog(dlg, "newPlaylistField").text = "Nachtfahrt"
        dlg.submit()
        settle(dlg.contentItem)

        verify(inDialog(dlg, "newPlaylistError").visible,
               "a reply carrying no playlist was taken for a success")
        verify(dlg.visible, "the dialog closed on a reply that carried nothing")
        compare(library.entries.length, makeEntries().length,
                "a reply carrying no playlist still put a row in the sidebar")
    }

    // Typing is the user answering the complaint, so the complaint goes away.
    function test_typing_clears_the_complaint() {
        bridge.setCreatePlaylistErrorForTest("503 Service Unavailable")
        var dlg = makeDialog()
        var field = inDialog(dlg, "newPlaylistField")
        field.text = "Nachtfahrt"
        dlg.submit()
        settle(dlg.contentItem)
        verify(inDialog(dlg, "newPlaylistError").visible, "there is no complaint to clear")

        field.text = "Nachtfahrt 2"
        settle(dlg.contentItem)
        compare(inDialog(dlg, "newPlaylistError").visible, false,
                "the complaint survived the correction")
    }

    function test_reopening_forgets_the_name_that_failed() {
        bridge.setCreatePlaylistErrorForTest("503 Service Unavailable")
        var dlg = makeDialog()
        inDialog(dlg, "newPlaylistField").text = "Nachtfahrt"
        dlg.submit()
        settle(dlg.contentItem)
        dlg.close()

        dlg.openEmpty()
        settle(dlg.contentItem)
        compare(inDialog(dlg, "newPlaylistField").text, "",
                "the dialog reopened with the last name still in it")
        compare(inDialog(dlg, "newPlaylistError").visible, false,
                "the dialog reopened with the last failure still on it")
    }

    // The same over the complaint an empty field earns. Clearing the name on
    // the way in fires onTextChanged, which hides any error, but here the
    // field is empty both times, so only the errorText reset can clear it.
    function test_reopening_forgets_a_complaint_about_an_empty_name() {
        var dlg = makeDialog()
        dlg.submit()                     // Return on an empty field
        settle(dlg.contentItem)
        verify(inDialog(dlg, "newPlaylistError").visible,
               "an empty field earned no complaint to forget")
        dlg.close()

        dlg.openEmpty()
        settle(dlg.contentItem)
        compare(inDialog(dlg, "newPlaylistError").visible, false,
                "the dialog reopened still complaining about the last attempt")
    }

    // ── entry point 1: the sidebar ───────────────────────────────────────

    function test_the_sidebar_offers_a_way_to_make_one() {
        var host = showShell(1280)
        var sb = host.sidebar
        settle(host.contentItem)

        var row    = findByName(sb, "sidebarNewPlaylist")
        var finder = findByName(sb, "sidebarFinder")
        var list   = findByName(sb, "sidebarLibraryList")
        verify(row, "the sidebar lists playlists and still has no way to add one")
        verify(row.visible, "the New playlist row is not drawn")
        verify(findByName(sb, "sidebarNewPlaylistLabel").visible,
               "the open sidebar does not say what the + does")

        // It belongs at the head of the list it adds to.
        verify(row.mapToItem(sb, 0, 0).y > finder.mapToItem(sb, 0, 0).y,
               "the New playlist row must sit below the finder")
        verify(row.mapToItem(sb, 0, 0).y < list.mapToItem(sb, 0, 0).y,
               "the New playlist row must sit above the library list")
    }

    // At the rail there is no room for a label, so the tile stands on its own.
    function test_the_rail_keeps_the_plus_and_drops_the_label() {
        var host = showShell(640)
        var sb = host.sidebar
        settle(host.contentItem)

        compare(sb.compact, true, "640px did not collapse the sidebar to the rail")
        verify(findByName(sb, "sidebarNewPlaylistTile").visible,
               "the rail lost the + altogether")
        compare(findByName(sb, "sidebarNewPlaylistLabel").visible, false,
                "a 68px rail is drawing the New playlist label")
    }

    // The row has to arrive in the sidebar on its own, with nothing re-paged.
    function test_making_one_from_the_sidebar_lands_at_the_top_of_the_library() {
        var host = showShell(1280)
        var sb = host.sidebar
        settle(host.contentItem)

        compare(rowIds(sb).join(","), "p-pin,a-pin,a1,p-old",
                "the fixture is not the list this test is about")
        var refreshesBefore = library.refreshCountForTest()

        mouseClick(findByName(sb, "sidebarNewPlaylist"))
        var dlg = sb.playlistDialog
        tryVerify(function () { return dlg.visible }, settleMs,
                  "clicking the New playlist row opened nothing")

        inDialog(dlg, "newPlaylistField").text = "Zugfahrt"
        dlg.submit()
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog stayed up after a successful create")
        settle(host.contentItem)

        var after = rowIds(sb)
        verify(after.indexOf("uuid-created-1") >= 0,
               "the new playlist never reached the sidebar; it holds " + after.join(","))
        // Third: the two pinned rows keep the head of the list and a created
        // playlist leads the block below them. Zugfahrt cannot get there
        // alphabetically, so only its date can put it third.
        compare(after.join(","), "p-pin,a-pin,uuid-created-1,a1,p-old",
                "the new playlist did not lead the unpinned block")
        compare(sb.rows[2].title, "Zugfahrt", "the row came through under the wrong name")

        // It arrived by being handed across, with no re-read of the account.
        compare(library.refreshCountForTest(), refreshesBefore,
                "the sidebar re-paged the whole library to show one new row")
        compare(bridge.userPlaylistFetchCountForTest(), 0,
                "the sidebar re-fetched the account's playlists to show one new row")
    }

    // ── entry point 2: the Collection page's Playlists tab ───────────────

    function makeCollection(w, tab) {
        var host = showPane(w)
        var page = createTemporaryObject(collectionC, host.pane, {})
        verify(page, "CollectionPage did not load")
        page.activeTab = tab
        settle(host.contentItem)
        return { host: host, page: page }
    }

    function test_the_button_belongs_to_the_playlists_tab_only_data() {
        return [
            { tag: "tracks",    tab: 0, shown: false },
            { tag: "albums",    tab: 1, shown: false },
            { tag: "artists",   tab: 2, shown: false },
            { tag: "playlists", tab: 3, shown: true  },
            { tag: "mixes",     tab: 4, shown: false }
        ]
    }

    function test_the_button_belongs_to_the_playlists_tab_only(row) {
        bridge.setUserPlaylistsForTest(makePlaylists(3))
        var c = makeCollection(1000, row.tab)
        var btn = findByName(c.page, "collectionNewPlaylistButton")
        verify(btn, "the New playlist button is not on the page at all")
        compare(btn.visible, row.shown,
                "on the " + row.tag + " tab the button is "
                + (btn.visible ? "shown" : "hidden") + ", which it should not be")
    }

    // An account with no playlists is the one that most needs to make one.
    function test_the_empty_state_is_not_a_dead_end() {
        bridge.setUserPlaylistsForTest([])
        var c = makeCollection(1000, 3)
        var btn = findByName(c.page, "collectionEmptyNewPlaylistButton")
        verify(btn, "the empty Playlists tab offers no way out of being empty")
        verify(btn.visible, "the empty state's New playlist button is not drawn")

        mouseClick(btn)
        tryVerify(function () { return c.page.playlistDialog.visible }, settleMs,
                  "the empty state's button opened nothing")
    }

    // The page listens to favoritePlaylistsChanged. Creating a playlist has
    // to raise it, and the grid grows by one on its own.
    function test_making_one_from_the_collection_shows_it_in_the_grid() {
        bridge.setUserPlaylistsForTest(makePlaylists(2))
        var c = makeCollection(1000, 3)
        compare(c.page.filteredPlaylists.length, 2, "the fixture did not load")

        mouseClick(findByName(c.page, "collectionNewPlaylistButton"))
        var dlg = c.page.playlistDialog
        tryVerify(function () { return dlg.visible }, settleMs,
                  "the Playlists tab's button opened nothing")

        inDialog(dlg, "newPlaylistField").text = "Zugfahrt"
        dlg.submit()
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog stayed up after a successful create")
        settle(c.host.contentItem)

        compare(c.page.filteredPlaylists.length, 3,
                "the new playlist never reached the grid; it holds "
                + playlistTitles().join(", "))
        compare(c.page.filteredPlaylists[2].title, "Zugfahrt",
                "the grid gained a row, but not the playlist that was made")
        // The page stays where it is: no tab change and no navigation.
        compare(c.page.activeTab, 3, "creating a playlist moved the tab")
        compare(c.host.lastNavigation, null,
                "creating a playlist navigated away from the collection")
    }

    // ── entry point 3: the track menu's "Add to playlist" picker ─────────

    function makePicker() {
        var host = showPane(1200)
        var row = createTemporaryObject(trackRowC, host.pane,
                                        { width: 700, trackData: makeTrack() })
        verify(row, "TrackRow did not load")
        row.openPicker()
        settle(host.contentItem)
        return { host: host, row: row }
    }

    function test_the_picker_offers_a_new_playlist_row() {
        bridge.setUserPlaylistsForTest(makePlaylists(2))
        var p = makePicker()
        var newRow = findByName(p.host.contentItem, "pickerNewPlaylistRow")
        verify(newRow, "\"Add to playlist\" still has no way to make one")
        verify(newRow.visible, "the picker's New playlist row is not drawn")
    }

    function test_the_picker_is_not_a_dead_end_with_no_playlists() {
        bridge.setUserPlaylistsForTest([])
        var p = makePicker()
        var newRow = findByName(p.host.contentItem, "pickerNewPlaylistRow")
        verify(newRow && newRow.visible,
               "an account with no playlists gets an empty picker and no way on")
    }

    function test_making_one_from_the_picker_puts_the_track_in_it() {
        bridge.setUserPlaylistsForTest([])
        var p = makePicker()
        mouseClick(findByName(p.host.contentItem, "pickerNewPlaylistRow"))

        var dlg = p.row.newPlaylistPopup
        verify(dlg, "the picker's New playlist row opened nothing")
        tryVerify(function () { return dlg.visible }, settleMs,
                  "the picker's dialog never came up")

        inDialog(dlg, "newPlaylistField").text = "Zugfahrt"
        dlg.submit()
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog stayed up after a successful create")
        settle(p.host.contentItem)

        compare(bridge.createPlaylistCallsForTest(), 1, "no playlist was made")
        compare(bridge.addToPlaylistCallsForTest(), 1,
                "the song was not added to the playlist that was just made for it")
        compare(bridge.lastAddedPlaylistForTest(), "uuid-created-1",
                "the song went into some other playlist")
        compare(bridge.lastAddedTrackIdForTest(), 9001, "some other song was added")
        // The row says so, naming the playlist it went into.
        verify(p.row.lastConfirmation.indexOf("Zugfahrt") >= 0,
               "the row said \"" + p.row.lastConfirmation
               + "\" rather than naming the playlist the song went into")
        // The picker closes with it.
        var pickerRow = findByName(p.host.contentItem, "pickerNewPlaylistRow")
        verify(!pickerRow || !pickerRow.visible,
               "the picker stayed up after the song had been filed")
    }

    // The playlist is made and the add then fails. That must be reported as
    // a failure, never announced as a success.
    function test_a_failed_add_is_not_reported_as_a_success() {
        bridge.setUserPlaylistsForTest([])
        bridge.setAddToPlaylistOkForTest(false)
        var p = makePicker()
        mouseClick(findByName(p.host.contentItem, "pickerNewPlaylistRow"))

        var dlg = p.row.newPlaylistPopup
        verify(dlg, "the picker's New playlist row opened nothing")
        tryVerify(function () { return dlg.visible }, settleMs,
                  "the picker's dialog never came up")
        inDialog(dlg, "newPlaylistField").text = "Zugfahrt"
        dlg.submit()
        tryVerify(function () { return !dlg.visible }, settleMs,
                  "the dialog stayed up after a successful create")
        settle(p.host.contentItem)

        // The create call succeeded, so the dialog is right to have closed.
        compare(bridge.createPlaylistCallsForTest(), 1, "no playlist was made")
        compare(bridge.addToPlaylistCallsForTest(), 1, "the add was never attempted")
        verify(p.row.lastConfirmation.length > 0,
               "a failed add said nothing at all")
        verify(p.row.lastConfirmation.indexOf("Could not") >= 0,
               "a failed add was reported as a success: \""
               + p.row.lastConfirmation + "\"")
    }
}
