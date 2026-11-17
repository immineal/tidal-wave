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
}
