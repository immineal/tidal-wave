// Deleting a playlist, and the question before Log out. A playlist the
// account made can be deleted from its sidebar row and from the Edit dialog,
// always behind a confirmation; one it only saved cannot. Once the bridge
// says it is gone, Main leaves its page and the back history forgets it.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "DeletePlaylist"
    when: windowShown
    visible: true
    width: 1280
    height: 900

    readonly property int settleMs: 2000

    function makeEntries() {
        return [
            { kind: "playlist", id: "p-own",   title: "Zugfahrt",     subtitle: "", imageUrl: "",
              pinned: false, trackCount: 3, editable: true },
            { kind: "playlist", id: "p-saved", title: "Fremde Liste", subtitle: "", imageUrl: "",
              pinned: false, trackCount: 9, editable: false }
        ]
    }

    function makeHeader() {
        return { uuid: "p-own", title: "Zugfahrt", description: "", numTracks: 3,
                 duration: 600, coverUrl: "", type: "USER", editable: true }
    }

    function init() {
        app.setReducedMotionForTest(true)
        prefs.setSidebarWidthForTest(220)
        auth.setStateForTest(2)
        updateCheck.clearForTest()
        library.setEntriesForTest(makeEntries())
        library.setTracksForTest([])
        pins.setItemsForTest([])
        bridge.resetForTest()
        bridge.setUserPlaylistsForTest([])
        bridge.setPlaylistForTest(makeHeader())
        bridge.setPlaylistTracksForTest([])
    }

    function cleanup() { bridge.resetForTest() }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        if (item.objectName === "detailView" && !item.visible) return null
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function typeName(obj) { return obj.toString().split("(")[0].split("_QML")[0] }

    function findByType(item, wanted) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || typeof c.width !== "number") continue
            // A page kept for back is hidden; the one on screen is meant.
            if (c.objectName === "detailView" && !c.visible) continue
            if (typeName(c) === wanted) return c
            var found = findByType(c, wanted)
            if (found) return found
        }
        return null
    }

    function inDialog(dialog, name) {
        var hit = findByName(dialog.contentItem, name)
        verify(hit, "the dialog has no \"" + name + "\"")
        return hit
    }

    Component { id: appWindowHost; Main {} }

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

    function showShell() {
        var host = createTemporaryObject(shellHost, testCase)
        verify(host, "the host window was not created")
        host.visible = true
        frame(host.contentItem)
        return host
    }

    function rowFor(sidebar, id) {
        for (var i = 0; i < sidebar.rows.length; ++i)
            if (sidebar.rows[i].id === id) return sidebar.rows[i]
        return null
    }

    // ── the sidebar ──────────────────────────────────────────────────────

    function test_an_own_playlist_row_offers_delete_behind_a_question() {
        var host = showShell()
        var sb = host.sidebar
        tryVerify(function () { return rowFor(sb, "p-own") !== null }, settleMs,
                  "the sidebar never listed the playlist")
        sb.showPinMenu(40, 40, rowFor(sb, "p-own"))
        var menu = sb.pinMenu
        tryVerify(function () { return menu.visible }, settleMs, "the row menu did not open")
        verify(menu.removeItem.visible, "an own playlist's menu offers no Delete")
        compare(menu.removeLabel, "Delete playlist…")

        menu.removeItem.triggered()
        var dlg = sb.deleteDialog
        tryVerify(function () { return dlg.visible }, settleMs, "Delete asked nothing")
        compare(bridge.deletePlaylistCallsForTest(), 0, "it deleted before the answer")
        verify(inDialog(dlg, "confirmDialogText").text.indexOf("Zugfahrt") !== -1,
               "the question does not name the playlist")

        mouseClick(inDialog(dlg, "confirmDialogConfirm"))
        compare(bridge.deletePlaylistCallsForTest(), 1)
        compare(bridge.lastDeletedPlaylistForTest(), "p-own")
        tryVerify(function () { return !dlg.visible }, settleMs, "the dialog stayed up")
    }

    function test_a_saved_playlist_row_offers_no_delete() {
        var host = showShell()
        var sb = host.sidebar
        tryVerify(function () { return rowFor(sb, "p-saved") !== null }, settleMs)
        sb.showPinMenu(40, 40, rowFor(sb, "p-saved"))
        compare(sb.pinMenu.removeLabel, "")
        verify(!sb.pinMenu.removeItem.visible, "someone else's playlist offers Delete")
        sb.pinMenu.close()
    }

    function test_cancel_deletes_nothing() {
        var host = showShell()
        var sb = host.sidebar
        tryVerify(function () { return rowFor(sb, "p-own") !== null }, settleMs)
        sb.showPinMenu(40, 40, rowFor(sb, "p-own"))
        sb.pinMenu.removeItem.triggered()
        var dlg = sb.deleteDialog
        tryVerify(function () { return dlg.visible }, settleMs)
        mouseClick(inDialog(dlg, "confirmDialogCancel"))
        tryVerify(function () { return !dlg.visible }, settleMs)
        compare(bridge.deletePlaylistCallsForTest(), 0)
    }

    function test_a_refused_delete_says_so_and_keeps_the_dialog() {
        bridge.setDeletePlaylistOkForTest(false)
        var host = showShell()
        var sb = host.sidebar
        tryVerify(function () { return rowFor(sb, "p-own") !== null }, settleMs)
        sb.showPinMenu(40, 40, rowFor(sb, "p-own"))
        sb.pinMenu.removeItem.triggered()
        var dlg = sb.deleteDialog
        tryVerify(function () { return dlg.visible }, settleMs)
        mouseClick(inDialog(dlg, "confirmDialogConfirm"))
        verify(dlg.visible, "a refused delete closed the dialog as if it had worked")
        verify(inDialog(dlg, "confirmDialogError").visible, "a refused delete said nothing")
        dlg.close()
    }

    // ── the page, in the real window ─────────────────────────────────────

    function showApp() {
        var win = createTemporaryObject(appWindowHost, testCase)
        verify(win, "the application window was not created")
        win.width = 1280
        win.height = 800
        win.visible = true
        frame(win.contentItem)
        return win
    }

    function test_deleting_from_the_edit_dialog_leaves_the_page_and_the_history() {
        var win = showApp()
        win.navigate("album", { albumId: 5 })
        win.navigate("playlist", { playlistUuid: "p-own", playlistTitle: "Zugfahrt",
                                   coverUrl: "", playlistType: "USER" })
        win.navigate("artist", { artistId: 9 })
        win.navigate("album", { albumId: 6 })
        win.navigate("playlist", { playlistUuid: "p-own", playlistTitle: "Zugfahrt",
                                   coverUrl: "", playlistType: "USER" })
        tryVerify(function () { return win.currentPage === "playlist" }, settleMs)
        var page = findByType(win.contentItem, "PlaylistPage")
        verify(page, "no playlist page")
        tryVerify(function () { return page.playlistEditable }, settleMs,
                  "the page never learnt the playlist is the account's")
        frame(win.contentItem)

        var edit = findByName(win.contentItem, "playlistEditButton")
        verify(edit && edit.visible, "no Edit button")
        mouseClick(edit)
        tryVerify(function () { return page.editPopup.visible }, settleMs)
        mouseClick(inDialog(page.editPopup, "editPlaylistDelete"))
        var dlg = page.deleteDialog
        tryVerify(function () { return dlg.visible }, settleMs, "Delete asked nothing")
        verify(!page.editPopup.visible, "the Edit dialog stayed under the question")
        mouseClick(inDialog(dlg, "confirmDialogConfirm"))

        compare(bridge.lastDeletedPlaylistForTest(), "p-own")
        // Back from it, to the album opened before it.
        tryVerify(function () { return win.currentPage === "album" }, settleMs,
                  "the page of a deleted playlist stayed up")
        for (var i = 0; i < win.navHistory.length; ++i)
            verify(!(win.navHistory[i].page === "playlist"
                     && win.navHistory[i].params.playlistUuid === "p-own"),
                   "back still leads to the deleted playlist")
        compare(win.navHistory[win.navHistory.length - 1].page, "artist")
    }

    // ── Log out ──────────────────────────────────────────────────────────

    function test_log_out_asks_first() {
        var win = showApp()
        var sidebar = findByType(win.contentItem, "SideBar")
        verify(sidebar)
        sidebar.openSettings()
        var panel = sidebar.settingsPanel
        tryVerify(function () { return panel.visible }, settleMs)
        var button = findByName(panel.contentItem, "settingsLogOut")
        verify(button, "Settings has no Log out")
        button.activated()
        var dlg = panel.logOutConfirm
        tryVerify(function () { return dlg.visible }, settleMs, "Log out asked nothing")
        compare(auth.state, 2, "Log out acted before the answer")

        mouseClick(inDialog(dlg, "confirmDialogCancel"))
        tryVerify(function () { return !dlg.visible }, settleMs)
        compare(auth.state, 2, "Cancel logged out")

        button.activated()
        tryVerify(function () { return dlg.visible }, settleMs)
        mouseClick(inDialog(dlg, "confirmDialogConfirm"))
        tryVerify(function () { return auth.state === 0 }, settleMs, "confirming did not log out")
        tryVerify(function () { return !dlg.visible }, settleMs)
    }
}
