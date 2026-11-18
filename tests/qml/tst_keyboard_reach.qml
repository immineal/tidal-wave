// Controls that used to answer the mouse only: each is a tab stop now, says
// what it is to a screen reader, and does its job on Enter.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "KeyboardReach"
    when: windowShown

    function track(i) {
        return { id: 9200 + i, title: "Titel " + i, artists: "Erika Mustermann",
                 artistId: 11, artistList: [{ id: 11, name: "Erika Mustermann" }],
                 albumTitle: "Nachtfahrt", albumId: 7788, duration: 200, durationStr: "3:20",
                 coverUrl: "", coverUrl80: "" }
    }

    function playlists() {
        return [
            { uuid: "p-m", title: "Mittagspause", description: "", coverUrl: "",
              numTracks: 3, duration: 600, type: "USER", editable: true },
            { uuid: "p-a", title: "Abendrot", description: "", coverUrl: "",
              numTracks: 5, duration: 900, type: "USER", editable: true },
            { uuid: "p-z", title: "Zugfahrt", description: "", coverUrl: "",
              numTracks: 8, duration: 1500, type: "USER", editable: true }
        ]
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        bridge.resetForTest()
        bridge.setUserPlaylistsForTest(playlists())
        player.setCurrentTrackForTest(track(0))
    }

    function cleanup() {
        bridge.setUserPlaylistsForTest([])
    }

    Component {
        id: pageHost
        Window {
            width: 1280; height: 800
            property var navCalls: []
            property int backs: 0
            function navigate(page, params) { navCalls = navCalls.concat([page]) }
            function goBack() { backs++ }
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) {}
            function cancelSleepTimer() {}
            function formatSleepTime(seconds) { return "0:30" }
            property bool fullScreen: false
            function toggleFullScreen() {}
        }
    }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: queueC;      QueuePanel { anchors.fill: parent } }
    Component { id: npC;         NowPlayingPage { anchors.fill: parent } }
    Component { id: radioC;      RadioPage { anchors.fill: parent } }
    Component { id: artistC;     ArtistPage { anchors.fill: parent } }
    Component { id: rowC;        TrackRow { width: 800 } }
    Component {
        id: sectionC
        HorizontalSection { width: 600; title: "Neu"; mediaType: "album" }
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function show() {
        var host = createTemporaryObject(pageHost, testCase)
        verify(host, "host window was not created")
        host.visible = true
        host.requestActivate()
        frame(host.contentItem)
        return host
    }

    function place(host, component, props) {
        var item = createTemporaryObject(component, host.contentItem, props || {})
        verify(item, "the item was not created")
        frame(host.contentItem)
        wait(1)
        return item
    }

    function allNamed(item, name, out) {
        out = out || []
        if (!item) return out
        if (item.objectName === name && item.visible !== false) out.push(item)
        for (var i = 0; i < item.children.length; ++i) allNamed(item.children[i], name, out)
        return out
    }
    function named(item, name) { return allNamed(item, name)[0] || null }

    function tabStopsIn(item, out) {
        out = out || []
        for (var i = 0; i < item.children.length; ++i) {
            var c = item.children[i]
            if (c.visible && c.activeFocusOnTab) out.push(c)
            tabStopsIn(c, out)
        }
        return out
    }

    function cardsIn(item, out) {
        out = out || []
        for (var i = 0; i < item.children.length; ++i) {
            var c = item.children[i]
            if (c.hasOwnProperty("pinMenu") && c.hasOwnProperty("mediaType")) out.push(c)
            else cardsIn(c, out)
        }
        return out
    }

    function reachable(item, what) {
        verify(item, what + " not found")
        verify(item.activeFocusOnTab, what + " is not a tab stop")
        verify(a11y.exposed(item), what + " is invisible to a screen reader")
        verify(a11y.name(item).length > 0, what + " has no accessible name")
    }

    // ── Collection ───────────────────────────────────────────────────────

    function test_collection_sort_pills() {
        var host = show()
        var page = place(host, collectionC)
        page.activeTab = 3
        frame(page)
        var pills = allNamed(page, "collectionSortDefault").concat(allNamed(page, "collectionSortPill"))
        compare(pills.length, 3)
        for (var i = 0; i < pills.length; ++i) {
            reachable(pills[i], "sort pill " + i)
            compare(a11y.role(pills[i]), Accessible.RadioButton)
        }
        verify(a11y.checked(pills[0]), "the chosen order does not read as chosen")
        pills[1].forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(page.sortMode, 1)
    }

    function test_collection_grid_is_one_tab_stop() {
        var host = show()
        var page = place(host, collectionC)
        page.activeTab = 3
        frame(page)
        var grid = findChild(page, "collectionPlaylistsGrid")
        verify(grid)
        tryVerify(function () { return cardsIn(grid.contentItem).length === 3 }, 2000)
        compare(tabStopsIn(grid.contentItem).length, 1, "every card is its own tab stop")

        var cards = cardsIn(grid.contentItem)
        var first = null
        for (var i = 0; i < cards.length; ++i) if (cards[i].activeFocusOnTab) first = cards[i]
        first.forceActiveFocus()
        keyClick(Qt.Key_Right)
        compare(grid.currentIndex, 1)
        var now = null
        for (var k = 0; k < cards.length; ++k) if (cards[k].activeFocus) now = cards[k]
        verify(now && now !== first, "Right does not move the keyboard to the next card")

        // The card's play button follows it in the tab order.
        keyClick(Qt.Key_Tab)
        var play = named(now, "cardPlayButton")
        verify(play && play.activeFocus, "Tab from a card does not reach its play button")
        compare(a11y.role(play), Accessible.Button)

        now.forceActiveFocus()
        keyClick(Qt.Key_Menu)
        tryVerify(function () { return now.pinMenu.opened }, 1000, "the Menu key opens no card menu")
        now.pinMenu.close()
    }

    // ── a horizontal row of cards ────────────────────────────────────────

    function test_horizontal_row_scrolls_the_focused_card_into_view() {
        var host = show()
        var items = []
        for (var i = 0; i < 10; ++i)
            items.push({ id: 500 + i, title: "Album " + i, subtitle: "Erika Mustermann", coverUrl: "" })
        var section = place(host, sectionC, { items: items })
        var list = named(section, "sectionList")
        verify(list)
        compare(tabStopsIn(list.contentItem).length, 1, "every card in the row is a tab stop")
        list.currentItem.forceActiveFocus()
        for (var k = 0; k < 7; ++k) keyClick(Qt.Key_Right)
        compare(list.currentIndex, 7)
        var card = list.currentItem
        verify(card.activeFocus)
        var p = card.mapToItem(list, 0, 0)
        verify(p.x >= 0 && p.x + card.width <= list.width + 1,
               "the focused card is off screen at x " + p.x)
    }

    // ── the queue ────────────────────────────────────────────────────────

    function test_queue_clear() {
        var host = show()
        player.clearManual()
        player.addToQueue([track(1), track(2)])
        var panel = place(host, queueC)
        var clear = named(panel, "queueClear")
        reachable(clear, "the queue's Clear")
        compare(a11y.role(clear), Accessible.Button)
        clear.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(player.manualCount, 0)
    }

    // ── Now Playing ──────────────────────────────────────────────────────

    function test_playing_from_link() {
        var host = show()
        player.setPlaybackSource("album", "7788", "Nachtfahrt")
        var page = place(host, npC)
        var link = named(page, "nowPlayingSourceLink")
        reachable(link, "Playing from")
        compare(a11y.role(link), Accessible.Link)
        link.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(host.navCalls[host.navCalls.length - 1], "album")
    }

    // A search has no title of its own, so the link says it was a search
    // rather than showing the bare query as if it were an album.
    function test_playing_from_a_search_says_search() {
        var host = show()
        player.setPlaybackSource("search", "fontaines", "fontaines")
        var page = place(host, npC)
        var link = named(page, "nowPlayingSourceLink")
        compare(link.text,
                qsTranslate("NowPlayingPage", "Playing from: search “%1”",
                            "the track was started from the search results").arg("fontaines"))
        // And it goes back to that search.
        link.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(host.navCalls[host.navCalls.length - 1], "search")
        player.setPlaybackSource("album", "7788", "Nachtfahrt")
        compare(link.text, qsTranslate("NowPlayingPage", "Playing from: %1").arg("Nachtfahrt"))
    }

    // ── Radio and Artist ─────────────────────────────────────────────────

    function test_radio_back() {
        var host = show()
        var page = place(host, radioC)
        var back = named(page, "radioBack")
        reachable(back, "Radio's back arrow")
        compare(a11y.role(back), Accessible.Button)
        back.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(host.backs, 1)
    }

    function test_artist_show_all() {
        var host = show()
        var page = place(host, artistC)
        var tops = []
        for (var i = 0; i < 8; ++i) tops.push(track(i))
        page.topTracks = tops
        frame(page)
        var more = named(page, "artistShowAllTracks")
        reachable(more, "Show all")
        compare(a11y.role(more), Accessible.Button)
        more.forceActiveFocus()
        keyClick(Qt.Key_Return)
        verify(page.showAllTracks)
    }

    // ── the add-to-playlist picker ───────────────────────────────────────

    function test_picker_rows() {
        var host = show()
        var row = place(host, rowC, { title: "Titel 1", artists: "Erika Mustermann",
                                      trackData: track(1) })
        row.openPicker()
        var picker = row.playlistPicker
        tryVerify(function () { return picker.opened }, 1000)
        var list = named(picker.contentItem, "pickerPlaylistList")
        tryVerify(function () { return list.count === 3 && list.currentItem }, 1000)
        var newRow = named(picker.contentItem, "pickerNewPlaylistRow")
        reachable(newRow, "New playlist in the picker")
        compare(tabStopsIn(list.contentItem).length, 1, "every picker row is its own tab stop")
        var first = list.currentItem
        reachable(first, "a picker row")
        first.forceActiveFocus()
        keyClick(Qt.Key_Down)
        compare(list.currentIndex, 1)
        verify(list.currentItem.activeFocus)
        keyClick(Qt.Key_Return)
        tryVerify(function () { return !picker.opened }, 1000, "Enter on a playlist does not add")
    }
}
