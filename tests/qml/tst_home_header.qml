// The top of Home is about the user's own music: the track in the player
// with a way to pick it up again, then what was played here lately. A page
// with neither is named the way the sidebar names it.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "HomeHeader"
    when: windowShown
    visible: true
    width: 1100
    height: 900

    Component {
        id: hostC
        Window {
            property alias pane: pane
            property string lastPage: ""
            property var lastParams: null
            function navigate(page, params) { lastPage = page; lastParams = params }
            function goBack() {}
            width: 1100; height: 900
            Item { id: pane; anchors.fill: parent }
        }
    }
    Component { id: homeC; HomePage { anchors.fill: parent } }

    function init() {
        app.setReducedMotionForTest(true)
        player.setCurrentTrackForTest({})
        player.setPlayingForTest(false)
        library.setEntriesForTest([])
        bridge.setFavoriteAlbumsForTest([])
        bridge.setFavoriteArtistsForTest([])
        bridge.setUserPlaylistsForTest([])
    }

    function settle(item) {
        wait(1)
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
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

    function allTexts(item, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || c.visible === false) continue
            if (typeof c.text === "string" && c.text.length > 0) out.push(c.text)
            allTexts(c, out)
        }
        return out
    }

    function makeHome() {
        var host = createTemporaryObject(hostC, testCase)
        host.visible = true
        var page = createTemporaryObject(homeC, host.pane)
        verify(page, "HomePage was not created")
        settle(page)
        return { host: host, page: page }
    }

    function test_no_greeting_by_the_clock() {
        var h = makeHome()
        var texts = allTexts(h.page, []).join(" | ")
        verify(!/Good (morning|afternoon|evening)/.test(texts),
               "Home still greets by the time of day: " + texts)
    }

    function test_the_track_in_the_player_leads_the_page() {
        player.setCurrentTrackForTest({ id: 51, title: "Signal Box", artists: "Kestrel Arcade",
                                        coverUrl: "" })
        var h = makeHome()
        var card = findByName(h.page, "homeContinue")
        verify(card && card.visible, "Home does not show the track in the player")
        verify(allTexts(card, []).indexOf("Signal Box") >= 0, "the card does not name the track")
        verify(!findByName(h.page, "homeTitle").visible, "the plain title shows over the track")

        var resume = findByName(card, "homeResume")
        verify(resume && resume.visible, "the card has no way to resume")
        verify(resume.width >= 32 && resume.height >= 32, "the resume target is too small")
        mouseClick(resume)
        verify(player.playing, "the resume button did not start the track")

        mouseClick(card, 140, card.height / 2)
        compare(h.host.lastPage, "nowplaying", "the card does not open what plays")
    }

    function test_recently_played_comes_first_newest_first() {
        library.setEntriesForTest([
            { kind: "album",    id: "11", title: "Older album", subtitle: "Kestrel Arcade",
              imageUrl: "", lastPlayed: 1000 },
            { kind: "playlist", id: "p-2", title: "Newest list", subtitle: "",
              imageUrl: "", lastPlayed: 3000 },
            { kind: "artist",   id: "7",  title: "Kestrel Arcade", subtitle: "",
              imageUrl: "", lastPlayed: 2000 },
            { kind: "album",    id: "12", title: "Never played", subtitle: "",
              imageUrl: "", lastPlayed: 0 }
        ])
        bridge.setFavoriteAlbumsForTest([{ id: 11, title: "Older album", artists: "Kestrel Arcade",
                                           coverUrl: "" }])
        var h = makeHome()
        var row = findByName(h.page, "homeRecentlyPlayed")
        verify(row && row.visible, "Home has no recently played row")
        compare(row.items.length, 3, "the row holds something never played")
        compare(row.items[0].title, "Newest list", "the row is not newest first")
        compare(row.items[1].kind, "artist", "the row lost the kind of an item")

        // Above every other row on the page.
        var top = row.mapToItem(h.page, 0, 0).y
        function walk(it) {
            for (var i = 0; i < it.children.length; ++i) {
                var c = it.children[i]
                if (c.title !== undefined && c.items !== undefined && c.visible && c !== row)
                    verify(c.mapToItem(h.page, 0, 0).y > top, "\"" + c.title + "\" sits above it")
                walk(c)
            }
        }
        walk(h.page)
    }

    function test_with_nothing_played_the_page_is_named() {
        var h = makeHome()
        var title = findByName(h.page, "homeTitle")
        verify(title && title.visible, "an empty Home has no title")
        verify(!findByName(h.page, "homeContinue").visible)
        verify(!findByName(h.page, "homeRecentlyPlayed").visible)
    }
}
