// The button right of Collection's field: "Surprise me" opens a random one
// of the albums, artists, playlists or mixes the tab shows right now, and
// "Shuffle" on the tracks tab plays the shown tracks shuffled. Both take the
// field's filter, and both are off when nothing is shown.
// The bridge and player stubs are from tests/TestStubs.h.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CollectionSurprise"
    when: windowShown

    Component {
        id: hostC
        Window {
            id: win
            width: 1280; height: 760
            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}
            property alias page: cp
            CollectionPage { id: cp; anchors.fill: parent }
        }
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        bridge.setFavoriteTracksListForTest(tracks())
        bridge.setFavoriteAlbumsForTest([
            { id: 501, title: "Nachtfahrt", artists: "Eine Band", coverUrl: "" },
            { id: 502, title: "Morgenrot",  artists: "Eine Band", coverUrl: "" },
            { id: 503, title: "Abendlied",  artists: "Andere",    coverUrl: "" }
        ])
        bridge.setFavoriteArtistsForTest([
            { id: 31, name: "Eine Band", coverUrl: "" },
            { id: 32, name: "Andere",    coverUrl: "" },
            { id: 33, name: "Gäste",     coverUrl: "" }
        ])
        bridge.setUserPlaylistsForTest([
            { uuid: "pl-a", title: "Fahrt", numTracks: 3, coverUrl: "" },
            { uuid: "pl-b", title: "Ruhe",  numTracks: 5, coverUrl: "" },
            { uuid: "pl-c", title: "Feier", numTracks: 7, coverUrl: "" }
        ])
        bridge.setHomeMixesForTest([
            { id: "m1", title: "Morgenmix", subtitle: "Eine Band", coverUrl: "", mixType: "" },
            { id: "m2", title: "Abendmix",  subtitle: "Andere",    coverUrl: "", mixType: "" },
            { id: "m3", title: "Nachtmix",  subtitle: "Gäste",     coverUrl: "", mixType: "" }
        ])
        player.setShuffle(false)
        player.setQueueForTest([], -1)
    }

    function cleanup() {
        bridge.useCatalogueForTest("")
        bridge.resetForTest()
        bridge.setFavoriteTracksListForTest([])
        player.setShuffle(false)
    }

    function tracks() {
        var titles = ["Ein Lied", "Zwei Lieder", "Drei Lieder", "Vier", "Fünf"]
        var out = []
        for (var i = 0; i < titles.length; ++i)
            out.push({ id: 62000 + i, title: titles[i], artists: "Eine Band",
                       albumTitle: "Ein Album", durationStr: "3:21", coverUrl: "",
                       coverUrl80: "", albumId: 11, artistId: 3 })
        return out
    }

    function open(tab) {
        var host = createTemporaryObject(hostC, testCase)
        verify(host, "the host window was not created")
        host.visible = true
        host.page.activeTab = tab
        frame(host.contentItem)
        wait(1)
        return host
    }

    function filter(host, text) {
        host.page.searchPattern = text
        host.page.updateFilteredContent()
        frame(host.contentItem)
        wait(1)
    }

    function button(host) {
        var b = findChild(host.page, "collectionSurpriseButton")
        verify(b && b.visible, "the tab has no surprise button")
        return b
    }

    function press(b) {
        mouseClick(b, Math.round(b.width / 2), Math.round(b.height / 2))
    }

    function test_surprise_opens_one_of_the_shown_data() {
        return [
            { tag: "albums",    tab: 1, page: "album",    key: "albumId",
              all: [501, 502, 503], query: "nacht", only: 501 },
            { tag: "artists",   tab: 2, page: "artist",   key: "artistId",
              all: [31, 32, 33], query: "andere", only: 32 },
            { tag: "playlists", tab: 3, page: "playlist", key: "playlistUuid",
              all: ["pl-a", "pl-b", "pl-c"], query: "ruhe", only: "pl-b" },
            { tag: "mixes",     tab: 4, page: "mix",      key: "mixId",
              all: ["m1", "m2", "m3"], query: "nacht", only: "m3" }
        ]
    }

    function test_surprise_opens_one_of_the_shown(row) {
        var host = open(row.tab)
        var b = button(host)
        compare(b.text, "Surprise me")
        compare(b.icon, "dice")
        verify(b.enabled, "the button is off with items on show")

        for (var i = 0; i < 12; ++i) press(b)
        compare(host.navCalls.length, 12, "not every press opened something")
        for (var k = 0; k < host.navCalls.length; ++k) {
            compare(host.navCalls[k].page, row.page)
            verify(row.all.indexOf(host.navCalls[k].params[row.key]) !== -1,
                   "opened " + host.navCalls[k].params[row.key] + ", which is not in the tab")
        }

        // The field's filter leaves one, so that one is the surprise.
        filter(host, row.query)
        host.navCalls = []
        press(b)
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].params[row.key], row.only,
                "the surprise ignored the field's filter")
    }

    function test_shuffle_plays_the_shown_tracks() {
        var host = open(0)
        var b = button(host)
        compare(b.text, "Shuffle")
        compare(b.icon, "shuffle")

        filter(host, "lied")
        compare(host.page.filteredTracks.length, 3)
        press(b)
        verify(player.shuffle, "the tracks were not played shuffled")
        compare(player.queueCount, 3, "the queue is not the shown tracks")
        var shown = [62000, 62001, 62002]
        verify(shown.indexOf(Number(player.currentTrack.id)) !== -1,
               "it started on a track the field had filtered out")
        compare(player.sourceType, "collection")
        compare(host.navCalls.length, 0, "Shuffle went somewhere instead of playing")
    }

    function test_nothing_shown_means_off_data() {
        return [ { tag: "tracks", tab: 0 }, { tag: "albums", tab: 1 }, { tag: "artists", tab: 2 },
                 { tag: "playlists", tab: 3 }, { tag: "mixes", tab: 4 } ]
    }

    function test_nothing_shown_means_off(row) {
        var host = open(row.tab)
        filter(host, "xyzzy")
        var b = button(host)
        verify(!b.enabled, "the button is on with nothing to pick from")
        press(b)
        compare(host.navCalls.length, 0)
        compare(player.queueCount, 0)
    }

    // Right of the field, which gives up the room.
    function test_it_sits_right_of_the_field() {
        var host = open(1)
        var b = button(host)
        var field = findChild(host.page, "collectionSearch")
        var f = field.mapToItem(host.contentItem, 0, 0)
        var p = b.mapToItem(host.contentItem, 0, 0)
        verify(p.x >= f.x + field.width, "the button is not right of the field")
        verify(Math.abs((p.y + b.height / 2) - (f.y + field.height / 2)) <= 1,
               "the button is not on the field's line")
        verify(p.x + b.width <= host.width, "the button runs off the page")
    }

    function test_german_labels() {
        verify(bridge.useCatalogueForTest("de"), "the German catalogue did not load")
        var host = open(1)
        compare(button(host).text, "Überrasch mich")
        host.page.activeTab = 0
        wait(1)
        compare(button(host).text, "Zufallswiedergabe")
        bridge.useCatalogueForTest("")
    }
}
