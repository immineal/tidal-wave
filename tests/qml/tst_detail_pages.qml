// The five detail pages (album, playlist, mix, artist, radio) are one page
// with different content: the same hero with a kind label and a title, the
// same action row starting with Play and Shuffle, and the same bar on top
// with the way back and the title that comes in once the hero scrolls away.

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "DetailPages"
    when: windowShown

    function track(i) {
        return { id: 9300 + i, title: "Titel " + i, artists: "Erika Mustermann",
                 artistId: 11, artistList: [{ id: 11, name: "Erika Mustermann" }],
                 albumTitle: "Nachtfahrt", albumId: 7788, duration: 200, durationStr: "3:20",
                 coverUrl: "", coverUrl80: "" }
    }

    function tracks(n) {
        var out = []
        for (var i = 0; i < n; ++i) out.push(track(i))
        return out
    }

    function init() {
        app.setReducedMotionForTest(true)
        auth.setStateForTest(2)
        bridge.resetForTest()
    }

    Component {
        id: pageHost
        Window {
            width: 1280; height: 800
            property int backs: 0
            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() { backs++ }
        }
    }
    Component { id: albumC;    AlbumPage    { anchors.fill: parent } }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }
    Component { id: mixC;      MixPage      { anchors.fill: parent } }
    Component { id: artistC;   ArtistPage   { anchors.fill: parent } }
    Component { id: radioC;    RadioPage    { anchors.fill: parent } }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    function findByType(item, wanted) {
        if (!item) return null
        if (typeName(item) === wanted && item.visible !== false) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByType(kids[i], wanted)
            if (hit) return hit
        }
        return null
    }

    function allByType(item, wanted, out) {
        out = out || []
        if (!item) return out
        if (typeName(item) === wanted && item.visible !== false) out.push(item)
        for (var i = 0; i < item.children.length; ++i) allByType(item.children[i], wanted, out)
        return out
    }

    function page(component, props) {
        var host = createTemporaryObject(pageHost, testCase)
        verify(host, "host window was not created")
        host.visible = true
        var p = createTemporaryObject(component, host.contentItem, props || {})
        verify(p, "the page was not created")
        frame(host.contentItem)
        return { host: host, page: p }
    }

    function test_every_detail_page_has_the_scaffold_data() {
        return [
            { tag: "album",    c: albumC,    kind: "Album" },
            { tag: "playlist", c: playlistC, kind: "Playlist" },
            { tag: "mix",      c: mixC,      kind: "Mix" },
            { tag: "artist",   c: artistC,   kind: "Artist" },
            { tag: "radio",    c: radioC,    kind: "Radio" },
        ]
    }

    function test_every_detail_page_has_the_scaffold(row) {
        var s = page(row.c)
        // Radio draws its pills only once it has something to play.
        if (row.tag === "radio") s.page.tracks = tracks(3)
        frame(s.host.contentItem)

        var hero = findByType(s.page, "DetailHero")
        verify(hero, row.tag + " has no hero of the shared kind")
        compare(hero.kind, row.kind, row.tag + "'s hero is labelled otherwise")

        var labels = allByType(hero.actionRow, "PillButton").map(function (b) { return b.text })
        compare(labels[0], "Play", row.tag + " does not lead with Play: " + labels)
        compare(labels[1], "Shuffle", row.tag + " has no Shuffle next to Play: " + labels)

        var bar = findByType(s.page, "DetailBar")
        verify(bar, row.tag + " has no shared bar on top")
        var back = findByType(bar, "BackButton")
        verify(back && back.activeFocusOnTab, row.tag + "'s bar has no back button to tab to")
        back.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(s.host.backs, 1, row.tag + "'s back button does not go back")
    }

    // Radio used to be a bare list under a chevron: now it scrolls its hero
    // away like the others, and its bar brings the title in.
    function test_the_radio_bar_brings_the_title_in() {
        var s = page(radioC, { radioTitle: "Radio zu Titel 0" })
        s.page.tracks = tracks(40)
        frame(s.host.contentItem)
        var bar = findByType(s.page, "DetailBar")
        verify(bar, "radio has no bar")
        compare(bar.reveal, 0, "the bar shows the title over the hero")
        var list = null
        var kids = s.page.children
        for (var i = 0; i < kids.length; ++i)
            if (kids[i].objectName === "radioTracksList") list = kids[i]
        verify(list, "radio has no track list")
        list.contentY = list.originY + 2000
        tryVerify(function () { return bar.reveal === 1 }, 2000,
                  "the bar did not bring the title in, reveal " + bar.reveal)
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

    // ── an artist's radio ────────────────────────────────────────────────

    function test_an_artist_with_a_radio_offers_it() {
        bridge.setArtistForTest({ id: 61, name: "Erika Mustermann", bio: "",
                                  artistMixId: "00aa11bb22cc33dd44ee55ff6677" },
                                tracks(3), [])
        var s = page(artistC)
        s.page.artistId = 61
        frame(s.host.contentItem)
        var pill = findByName(s.page, "artistRadioPill")
        verify(pill && pill.visible, "an artist Tidal names a radio for offers none")
        mouseClick(pill)
        compare(s.host.navCalls.length, 1, "the radio pill opened nothing")
        compare(s.host.navCalls[0].page, "mix")
        compare(s.host.navCalls[0].params.mixId, "00aa11bb22cc33dd44ee55ff6677")
        compare(s.host.navCalls[0].params.mixType, "ARTIST_MIX")
    }

    function test_an_artist_without_a_radio_offers_none() {
        bridge.setArtistForTest({ id: 62, name: "Erika Mustermann", bio: "" }, tracks(3), [])
        var s = page(artistC)
        s.page.artistId = 62
        frame(s.host.contentItem)
        var pill = findByName(s.page, "artistRadioPill")
        verify(!pill || !pill.visible, "a radio pill for an artist with no radio")
    }

    function test_an_artist_radio_is_headed_radio() {
        var s = page(mixC, { mixId: "00aa11bb22cc33dd44ee55ff6677", mixType: "ARTIST_MIX",
                             title: "Erika Mustermann" })
        compare(findByType(s.page, "DetailHero").kind, "Radio",
                "an artist's station is headed as a mix")
    }

    // ── Copy link, from the hero's menu ─────────────────────────────────

    function test_the_hero_menu_copies_the_link_data() {
        return [
            { tag: "album",    c: albumC,    props: { albumId: 7788 },
              link: "https://tidal.com/album/7788" },
            { tag: "playlist", c: playlistC, props: { playlistUuid: "0c1d2e3f-aaaa-bbbb-cccc-000000000001",
                                                      playlistTitle: "Liste" },
              link: "https://tidal.com/playlist/0c1d2e3f-aaaa-bbbb-cccc-000000000001" },
            { tag: "mix",      c: mixC,      props: { mixId: "0123abcd", title: "Mix" },
              link: "https://tidal.com/mix/0123abcd" },
            { tag: "artist",   c: artistC,   props: { artistId: 11 },
              link: "https://tidal.com/artist/11" },
        ]
    }

    function test_the_hero_menu_copies_the_link(row) {
        var s = page(row.c, row.props)
        frame(s.host.contentItem)
        var more = findByName(s.page, "heroMoreButton")
        verify(more && more.visible, row.tag + "'s hero has no menu button")
        mouseClick(more)
        var menu = s.page.pinMenu
        tryVerify(function () { return menu.opened }, 2000, "the menu button opened no menu")
        verify(menu.copyLinkItem.visible, row.tag + "'s menu has no Copy link")
        compare(menu.copyLinkItem.text, "Copy link")
        menu.copyLinkItem.triggered()
        compare(bridge.lastClipboardTextForTest(), row.link,
                row.tag + " copied the wrong link")
        menu.close()
    }

    // The radio list has no identity on Tidal, so nothing to link to.
    function test_a_track_radio_list_has_no_menu_button() {
        var s = page(radioC, { radioTitle: "Radio" })
        s.page.tracks = tracks(3)
        frame(s.host.contentItem)
        verify(!findByName(s.page, "heroMoreButton"), "the radio list offers a menu with nothing in it")
    }

    // ── the filter inside a playlist ────────────────────────────────────

    // The rows the list holds, top to bottom. Not a walk of the children: a
    // row the filter took out waits, still visible, in the list's reuse pool.
    function playlistRows(p) {
        var list = findByName(p, "playlistTracksList")
        var out = []
        for (var i = 0; i < list.count; ++i) {
            var r = list.itemAtIndex(i)
            if (r) out.push(r)
        }
        return out
    }

    function filteredPlaylist() {
        var list = tracks(4)
        list[1].title = "Café am Hafen"
        list[3].artists = "Jürgen Beispiel"
        // The same track a second time, as a playlist may hold it.
        var again = track(1)
        again.title = "Café am Hafen"
        list.push(again)
        // Loaded the way the app loads it, so the rows are the bridge's own
        // copies and no row can be found by identity.
        bridge.setPlaylistTracksForTest(list)
        var s = page(playlistC, { playlistUuid: "0c1d2e3f-aaaa-bbbb-cccc-000000000002",
                                  playlistTitle: "Liste", playlistEditable: true })
        tryCompare(s.page, "loading", false)
        compare(s.page.trackRows.length, 5)
        frame(s.host.contentItem)
        return s
    }

    function test_the_filter_narrows_the_rows() {
        var s = filteredPlaylist()
        var field = findByName(s.page, "playlistFilter")
        verify(field && field.visible, "a playlist with tracks has no filter field")
        compare(playlistRows(s.page).length, 5)
        field.text = "cafe"
        field.textEdited("cafe")
        frame(s.host.contentItem)
        compare(playlistRows(s.page).length, 2, "case and accents must not count")
        field.text = "jurgen"
        field.textEdited("jurgen")
        frame(s.host.contentItem)
        var rows = playlistRows(s.page)
        compare(rows.length, 1, "the artist is not searched")
        compare(rows[0].trackNum, 4, "a filtered row lost its number in the playlist")
        field.text = ""
        field.textEdited("")
        frame(s.host.contentItem)
        compare(playlistRows(s.page).length, 5)
    }

    // The second copy is its own row: removal and play hit that one.
    function test_a_track_twice_keeps_each_row_its_own_place() {
        var s = filteredPlaylist()
        var field = findByName(s.page, "playlistFilter")
        field.text = "hafen"
        field.textEdited("hafen")
        frame(s.host.contentItem)
        var rows = playlistRows(s.page)
        compare(rows.length, 2)
        compare(rows[0].trackItemIndex, 1)
        compare(rows[1].trackItemIndex, 4, "the second copy points at the first")
        rows[1].playRequested()
        compare(player.queueCount, 2, "the filtered list did not play as shown")
        compare(player.queueIndex, 1)

        // Removing the second copy sends its own place and takes that row.
        rows[1].removeFromPlaylistRequested(rows[1].trackItemIndex)
        tryCompare(s.page.trackRows, "length", 4)
        compare(bridge.lastRemovedIndexForTest(), 4, "the removal was sent for the first copy")
        compare(s.page.trackRows.sourceAt(1).title, "Café am Hafen", "the first copy was taken")
        compare(s.page.trackRows.sourceAt(3).artists, "Jürgen Beispiel")
    }

    // A filter that matches nothing says so and how to get the list back,
    // and clearing the field brings the rows and no line.
    function test_a_filter_that_matches_nothing_says_so() {
        var s = filteredPlaylist()
        var none = findByName(s.page, "playlistNoMatches")
        verify(!none || !none.visible, "a no-match line over a full list")
        var field = findByName(s.page, "playlistFilter")
        field.text = "zzz"
        field.textEdited("zzz")
        frame(s.host.contentItem)
        compare(playlistRows(s.page).length, 0)
        none = findByName(s.page, "playlistNoMatches")
        verify(none && none.visible, "a filter that matches nothing leaves a blank list")
        var head = findByName(none, "playlistNoMatchesText")
        compare(head.text, "No tracks match \"zzz\"")
        verify(findByName(none, "playlistNoMatchesHint").text.indexOf("Clear the field") >= 0,
               "the line does not say how to get the tracks back")
        field.text = ""
        field.textEdited("")
        frame(s.host.contentItem)
        compare(playlistRows(s.page).length, 5)
        verify(!none.visible, "the no-match line stayed after the field was cleared")
    }

    function test_an_empty_playlist_has_no_filter() {
        var s = page(playlistC, { playlistUuid: "", playlistTitle: "Liste" })
        var field = findByName(s.page, "playlistFilter")
        verify(!field || !field.visible, "a filter over no tracks")
    }
}
