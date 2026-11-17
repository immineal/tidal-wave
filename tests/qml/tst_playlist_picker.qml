// The "Add to playlist" picker: only the user's own playlists, a search
// field over them, a tick on those that hold the tracks already, and the
// window's picker that the queue and the album headers ask for. The bridge
// stub answers reads from setServerPlaylistForTest().

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "PlaylistPicker"
    when: windowShown
    width: 900
    height: 700
    visible: true

    readonly property int settleMs: 2000

    function playlist(uuid, title, n, editable) {
        return { id: 0, uuid: uuid, title: title, description: "", coverUrl: "",
                 numTracks: n, duration: 600, type: "USER", editable: editable !== false }
    }

    function track(id, title) {
        return { id: id, title: title, artists: "Kestrel Arcade", albumTitle: "Glass Orchard",
                 durationStr: "3:21", coverUrl80: "", albumId: 42, artistId: 7 }
    }

    function cleanup() { bridge.useCatalogueForTest("") }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        Edits.clearHistory()
        Toasts.dismiss()
        bridge.setUserPlaylistsForTest([
            playlist("pl-road", "Road trip", 2),
            playlist("pl-cafe", "Café mornings", 1),
            playlist("pl-rain", "Rainy road", 0),
            playlist("pl-staff", "Editors' picks", 9, false)
        ])
        bridge.setServerPlaylistForTest("pl-road", [11, 12])
        bridge.setServerPlaylistForTest("pl-cafe", [12])
        bridge.setServerPlaylistForTest("pl-rain", [])
        // The tick reads are kept per playlist; each test starts from none.
        // Emitted through a reference: Qt 6.5 crashes on a direct call of a
        // QML singleton's signal from outside it.
        var changed = Edits.playlistChanged
        var touched = ["pl-road", "pl-cafe", "pl-rain", "uuid-created-1"]
        touched.forEach(function (u) {
            changed.call(Edits, u)
        })
    }

    // A window with Main.qml's navigate(), so opening a playlist is recorded.
    Component {
        id: hostC
        Window {
            property var visits: []
            function navigate(page, params) {
                visits = visits.concat([page + " " + (params.playlistUuid || "")])
            }
            width: 900
            height: 700
            PlaylistPickerHost { id: pickerHost; objectName: "host" }
            property alias pickerHost: pickerHost
        }
    }

    function showHost() {
        var w = createTemporaryObject(hostC, testCase)
        verify(w, "the host window was not created")
        w.visible = true
        verify(waitForRendering(w.contentItem), "the window drew no frame")
        return w
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findByName(item.children[i], name)
            if (hit) return hit
        }
        return null
    }

    function rows(picker) {
        var list = findByName(picker.contentItem, "pickerPlaylistList")
        verify(list, "the picker has no list")
        var out = []
        for (var i = 0; i < list.count; ++i) {
            list.currentIndex = i
            out.push(list.currentItem)
        }
        list.currentIndex = -1
        return out
    }

    function titles(picker) {
        return rows(picker).map(function (r) { return findByName(r, "pickerRowTitle").text })
    }

    function held(picker) {
        return rows(picker).filter(function (r) { return r.holds })
                           .map(function (r) { return findByName(r, "pickerRowTitle").text })
    }

    function openFor(w, tracks) {
        Edits.pickPlaylist(tracks)
        var picker = w.pickerHost.picker
        tryVerify(function () { return picker.opened }, settleMs, "the picker did not open")
        // A frame, so the popup's column has laid its rows out.
        picker.contentItem.Window.window.update()
        verify(waitForRendering(picker.contentItem), "the window drew no frame")
        return picker
    }

    function type(picker, text) {
        var field = findByName(picker.contentItem, "pickerSearchField")
        verify(field && field.visible, "the picker has no search field")
        field.text = text
        field.textEdited(text)
    }

    // ── what is offered ──────────────────────────────────────────────────

    function test_only_the_users_own_playlists_are_offered() {
        var picker = openFor(showHost(), [track(13, "Thirteen")])
        compare(titles(picker), ["Road trip", "Café mornings", "Rainy road"],
                "a playlist the user cannot add to was offered")
    }

    function test_the_search_field_comes_before_new_playlist() {
        var picker = openFor(showHost(), [track(13, "Thirteen")])
        var field = findByName(picker.contentItem, "pickerSearchField")
        var newRow = findByName(picker.contentItem, "pickerNewPlaylistRow")
        verify(field.mapToItem(picker.contentItem, 0, 0).y
               < newRow.mapToItem(picker.contentItem, 0, 0).y,
               "the search field is below New playlist")
    }

    // ── the search ───────────────────────────────────────────────────────

    function test_the_search_has_the_keyboard_and_escape_still_closes() {
        var picker = openFor(showHost(), [track(13, "Thirteen")])
        var field = findByName(picker.contentItem, "pickerSearchField")
        tryVerify(function () { return field.focused }, settleMs, "typing does not reach the search")
        keyClick(Qt.Key_R)
        compare(field.text, "r")
        // The first Escape empties the field, the next closes the picker.
        keyClick(Qt.Key_Escape)
        compare(field.text, "")
        verify(picker.visible, "Escape closed the picker over a search")
        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !picker.visible }, settleMs, "Escape did not close the picker")
    }

    function test_typing_narrows_the_list_data() {
        return [
            { tag: "one word",          text: "road",       want: ["Road trip", "Rainy road"] },
            { tag: "every word counts", text: "road rainy", want: ["Rainy road"] },
            { tag: "accents and case",  text: "CAFE",       want: ["Café mornings"] },
            { tag: "nothing matches",   text: "jazz",       want: [] },
            { tag: "cleared again",     text: "",           want: ["Road trip", "Café mornings", "Rainy road"] }
        ]
    }

    function test_typing_narrows_the_list(row) {
        var picker = openFor(showHost(), [track(13, "Thirteen")])
        type(picker, row.text)
        compare(titles(picker), row.want)
    }

    function test_return_picks_the_one_row_left() {
        var w = showHost()
        var picker = openFor(w, [track(13, "Thirteen")])
        type(picker, "cafe")
        findByName(picker.contentItem, "pickerSearchField").submitted("cafe")
        tryVerify(function () { return !picker.visible }, settleMs, "the picker stayed up")
        tryVerify(function () { return bridge.lastAddedPlaylistForTest() === "pl-cafe" }, settleMs)
        compare(bridge.serverPlaylistForTest("pl-cafe"), [12, 13])
    }

    function test_a_new_open_starts_with_an_empty_search() {
        var w = showHost()
        var picker = openFor(w, [track(13, "Thirteen")])
        type(picker, "jazz")
        picker.close()
        tryVerify(function () { return !picker.visible }, settleMs)
        picker = openFor(w, [track(13, "Thirteen")])
        compare(findByName(picker.contentItem, "pickerSearchField").text, "")
        compare(titles(picker).length, 3, "the last search was kept")
    }

    // ── the tick on a playlist that has the tracks ───────────────────────

    function test_a_playlist_that_has_the_track_is_marked() {
        var picker = openFor(showHost(), [track(12, "Twelve")])
        tryVerify(function () { return held(picker).join(",") === "Road trip,Café mornings" },
                  settleMs, "the playlists with the track were not marked")
        var road = rows(picker)[0]
        verify(findByName(road, "pickerRowHeldMark").visible, "the tick is not drawn")
        compare(findByName(road, "pickerRowHeldText").text, "Has this track already")
        compare(road.Accessible.description, "Has this track already")
        verify(!findByName(rows(picker)[2], "pickerRowHeldMark").visible,
               "an empty playlist is marked")
    }

    function test_several_tracks_mark_only_where_all_are() {
        var picker = openFor(showHost(), [track(11, "Eleven"), track(12, "Twelve")])
        wait(50)
        compare(held(picker), ["Road trip"], "a playlist with only some was marked")
        compare(findByName(rows(picker)[0], "pickerRowHeldText").text, "Has all of these already")
    }

    function test_a_marked_playlist_still_takes_the_track() {
        var w = showHost()
        var picker = openFor(w, [track(12, "Twelve")])
        wait(50)
        rows(picker)[0].choose()
        // Already in it: the duplicate question comes, as before.
        tryVerify(function () { return Edits.duplicateQuestion !== null }, settleMs,
                  "nothing was asked about the duplicate")
        Edits.answerDuplicates("cancel")
    }

    function test_the_mark_is_read_again_after_the_playlist_changes() {
        var w = showHost()
        var picker = openFor(w, [track(13, "Thirteen")])
        wait(50)
        compare(held(picker), [])
        picker.choose("pl-rain", "Rainy road")
        tryVerify(function () { return bridge.lastAddedPlaylistForTest() === "pl-rain" }, settleMs)
        wait(50)
        picker = openFor(w, [track(13, "Thirteen")])
        wait(50)
        compare(held(picker), ["Rainy road"], "the old read was kept after the add")
    }

    function test_a_reopen_reads_nothing_again() {
        var w = showHost()
        var picker = openFor(w, [track(13, "Thirteen")])
        wait(50)
        var reads = bridge.readBacksForTest()
        picker.close()
        tryVerify(function () { return !picker.visible }, settleMs)
        picker = openFor(w, [track(12, "Twelve")])
        wait(50)
        compare(bridge.readBacksForTest(), reads, "unchanged playlists were read again")
        compare(held(picker), ["Road trip", "Café mornings"])
    }

    // ── what the window's picker adds ────────────────────────────────────

    function test_the_window_picker_adds_every_track_it_was_handed() {
        verify(bridge.useCatalogueForTest("en"), "the English catalogue did not load")
        var w = showHost()
        var picker = openFor(w, [track(13, "Thirteen"), track(14, "Fourteen")])
        picker.choose("pl-rain", "Rainy road")
        tryCompare(w.pickerHost, "lastConfirmation", "2 tracks added to “Rainy road”")
        compare(bridge.serverPlaylistForTest("pl-rain"), [13, 14])
    }

    function test_a_new_playlist_gets_the_tracks_and_opens() {
        verify(bridge.useCatalogueForTest("en"), "the English catalogue did not load")
        var w = showHost()
        var picker = openFor(w, [track(13, "Thirteen"), track(14, "Fourteen")])
        mouseClick(findByName(picker.contentItem, "pickerNewPlaylistRow"))
        var dlg = w.pickerHost.newPlaylistDialog
        tryVerify(function () { return dlg.visible }, settleMs, "the dialog never came up")
        findByName(dlg.contentItem, "newPlaylistField").text = "Night bus"
        dlg.submit()
        tryVerify(function () { return !dlg.visible }, settleMs, "the dialog stayed up")
        tryVerify(function () { return !picker.visible }, settleMs, "the picker stayed up")
        compare(w.visits, ["playlist uuid-created-1"], "the new playlist was not opened")
        tryCompare(w.pickerHost, "lastConfirmation", "2 tracks added to “Night bus”")
        compare(bridge.serverPlaylistForTest("uuid-created-1"), [13, 14])
    }

    // ── German ───────────────────────────────────────────────────────────

    function test_the_picker_in_german() {
        verify(bridge.useCatalogueForTest("de"), "the German catalogue did not load")
        var picker = openFor(showHost(), [track(12, "Twelve")])
        wait(50)
        compare(findByName(picker.contentItem, "pickerSearchField").placeholder,
                "Playlist suchen")
        compare(findByName(rows(picker)[0], "pickerRowHeldText").text, "Schon darin")
    }
}
