// An album card's artists: the second line links each credited artist, the
// way ArtistLinks does on a track row, and the card's menu has "Go to artist".
// The card's own click and its menu built only when asked stay as they were.
// Every name and id is invented.

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "CardArtists"
    when: windowShown
    width: 1300
    height: 820
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible.
    visible: true

    readonly property var twoArtists: [
        { id: 11, name: "Erika Mustermann" },
        { id: 22, name: "Gastsängerin" }
    ]

    function init() { app.setReducedMotionForTest(true) }
    function cleanup() {
        app.setReducedMotionForTest(false)
        bridge.resetForTest()
    }

    Component {
        id: cardHost
        Window {
            width: 400; height: 400
            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}
            property alias card: card
            property int clicks: 0
            MediaCard {
                id: card
                x: 20; y: 20
                cardSize: 160
                onClicked: parent.Window.window.clicks++
            }
        }
    }

    Component {
        id: sectionHost
        Window {
            width: 900; height: 400
            property alias section: section
            function navigate(page, params) {}
            HorizontalSection {
                id: section
                width: parent.width
                title: "Neu"
                mediaType: "album"
            }
        }
    }

    Component { id: holderC; Item { } }
    Component { id: searchC; SearchPage { anchors.fill: parent } }
    Component { id: homeC;   HomePage   { anchors.fill: parent } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function makeCard(props) {
        var host = createTemporaryObject(cardHost, testCase)
        verify(host, "the host window was not created")
        for (var k in props) host.card[k] = props[k]
        host.visible = true
        frame(host.contentItem)
        return host
    }

    function albumCard(artists) {
        var names = artists.map(function (a) { return a.name }).join(", ")
        return makeCard({ mediaType: "album", itemId: "4242", title: "Nachtfahrt",
                          subtitle: names, artistList: artists })
    }

    function visibleNamed(item, objectName, out) {
        out = out || []
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            if (c.objectName === objectName) out.push(c)
            visibleNamed(c, objectName, out)
        }
        return out
    }

    // A pointer over the card's second line, which is where the links are.
    function hoverLine(host) {
        var sub = findChild(host.card, "cardSubtitle")
        mouseMove(sub, 4, sub.height / 2)
        wait(0)
        frame(host.contentItem)
    }

    function namesOn(host) {
        var names = []
        tryVerify(function () {
            names = visibleNamed(host.card, "cardArtistName")
            return names.length > 0
        }, 2000, "the card's second line has no artist links")
        return names
    }

    function menuItemNamed(menu, objectName) {
        for (var i = 0; i < menu.count; i++) {
            var it = menu.itemAt(i)
            if (it && it.objectName === objectName) return it
        }
        return null
    }

    function openMenu(host) {
        host.card.openMenu(10, 10)
        var menu = host.card.pinMenu
        verify(menu, "the card's menu was not built")
        tryVerify(function () { return menu.opened }, 2000, "the card's menu did not open")
        return menu
    }

    // ── the second line ──────────────────────────────────────────────────

    function test_each_credited_artist_opens_its_own_page() {
        var host = albumCard(twoArtists)
        hoverLine(host)
        var names = namesOn(host)
        compare(names.length, 2, "one link per credited artist")
        compare(names[0].text, "Erika Mustermann")
        compare(names[1].text, "Gastsängerin")

        mouseClick(names[1], names[1].width / 2, names[1].height / 2)
        compare(host.navCalls.length, 1, "a click on a name should navigate once")
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 22, "the second name opened someone else")
        compare(host.clicks, 0, "a click on a name also opened the album")
    }

    function test_a_name_underlines_under_the_pointer() {
        var host = albumCard(twoArtists)
        hoverLine(host)
        var names = namesOn(host)
        mouseMove(names[0], names[0].width / 2, names[0].height / 2)
        tryVerify(function () { return names[0].font.underline }, 1000,
                  "the name under the pointer is not underlined")
        verify(!names[1].font.underline, "the other name is underlined too")
    }

    // Same place, same size: the links stand where the plain line stood.
    function test_the_links_sit_where_the_line_did() {
        var host = albumCard(twoArtists)
        var sub = findChild(host.card, "cardSubtitle")
        var before = sub.mapToItem(host.card, 0, 0)
        var cardHeight = host.card.height
        hoverLine(host)
        var names = namesOn(host)
        var at = names[0].mapToItem(host.card, 0, 0)
        fuzzyCompare(at.x, before.x, 0.5, "the links moved sideways")
        fuzzyCompare(at.y, before.y, 0.5, "the links moved up or down")
        compare(names[0].font.pixelSize, sub.fontInfo.pixelSize, "the links are another size")
        compare(host.card.height, cardHeight, "the card changed height")
    }

    // A line too long shrinks before it is cut, as the plain line does.
    function test_a_long_line_shrinks_as_before() {
        var long = [{ id: 11, name: "Rundfunk-Tanzorchester Salzwiesen" },
                    { id: 22, name: "Gastsängerin" }]
        var host = albumCard(long)
        var sub = findChild(host.card, "cardSubtitle")
        verify(sub.fontInfo.pixelSize < Theme.fontMeta, "the fixture does not shrink")
        hoverLine(host)
        var names = namesOn(host)
        compare(names[0].font.pixelSize, sub.fontInfo.pixelSize)
    }

    function test_the_cover_still_opens_the_album() {
        var host = albumCard(twoArtists)
        hoverLine(host)
        namesOn(host)
        var art = findChild(host.card, "cardArt")
        mouseClick(art, 20, 20)
        compare(host.clicks, 1, "the cover no longer opens the album")
        compare(host.navCalls.length, 0, "the cover opened an artist")
    }

    function test_cards_without_credits_keep_the_plain_line_data() {
        return [
            { tag: "playlist", props: { mediaType: "playlist", itemId: "uuid-1", title: "Liste",
                                        subtitle: "12 tracks", artistList: twoArtists } },
            { tag: "album without a list", props: { mediaType: "album", itemId: "4242",
                                                    title: "Nachtfahrt", subtitle: "Erika Mustermann" } },
            { tag: "album with no ids", props: { mediaType: "album", itemId: "4242", title: "Nachtfahrt",
                                                 subtitle: "Unbekannt",
                                                 artistList: [{ id: 0, name: "Unbekannt" }] } }
        ]
    }
    function test_cards_without_credits_keep_the_plain_line(data) {
        var host = makeCard(data.props)
        hoverLine(host)
        wait(50)
        compare(visibleNamed(host.card, "cardArtistName").length, 0, "the line became links")
        verify(findChild(host.card, "cardSubtitle").visible, "the plain line went")
    }

    // ── the menu ─────────────────────────────────────────────────────────

    function test_the_menu_is_still_built_only_when_asked() {
        var host = albumCard(twoArtists)
        hoverLine(host)
        namesOn(host)
        compare(host.card.pinMenu, null, "the card built its menu before anyone asked")
    }

    function test_one_artist_is_a_direct_go_to_artist() {
        var host = albumCard([{ id: 11, name: "Erika Mustermann" }])
        var menu = openMenu(host)
        var direct = menuItemNamed(menu, "goToArtistMenuItem")
        verify(direct, "the card's menu has no Go to artist")
        verify(direct.visible && direct.height > 0, "Go to artist is hidden for one artist")
        compare(direct.text, qsTranslate("TrackRow", "Go to artist"))
        compare(direct.iconName, "artist")
        var sub = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(!sub || !sub.visible, "one artist is offered as a submenu")
        direct.triggered()
        compare(host.navCalls.length, 1, "Go to artist did not navigate")
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 11)
        menu.close()
    }

    function test_several_artists_are_a_submenu() {
        var host = albumCard(twoArtists)
        var menu = openMenu(host)
        var direct = menuItemNamed(menu, "goToArtistMenuItem")
        verify(direct && !direct.visible && direct.height === 0,
               "the direct row stays for two artists")
        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(subRow && subRow.visible, "two artists get no submenu")
        compare(subRow.text, qsTranslate("TrackRow", "Go to artist"))
        compare(subRow.iconName, "artist")
        var subMenu = subRow.subMenu
        verify(subMenu, "the row has no submenu")
        compare(subMenu.count, 2)
        compare(subMenu.itemAt(0).text, "Erika Mustermann")
        compare(subMenu.itemAt(1).text, "Gastsängerin")
        subMenu.itemAt(1).triggered()
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].params.artistId, 22, "the second row opened someone else")
        menu.close()
    }

    // Other kinds, and the heroes and sidebar rows that share the menu,
    // have no artist row.
    function test_other_cards_have_no_go_to_artist() {
        var host = makeCard({ mediaType: "playlist", itemId: "uuid-1", title: "Liste",
                              subtitle: "12 tracks", artistList: twoArtists })
        var menu = openMenu(host)
        var direct = menuItemNamed(menu, "goToArtistMenuItem")
        verify(!direct || !direct.visible, "a playlist card offers Go to artist")
        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(!subRow || !subRow.visible, "a playlist card offers an artist submenu")
        menu.close()
    }

    // ── the hosts hand the credits over ──────────────────────────────────

    function test_a_row_of_cards_hands_each_card_its_artists() {
        var host = createTemporaryObject(sectionHost, testCase)
        host.section.items = [{ id: 4242, title: "Nachtfahrt", subtitle: "Erika Mustermann, Gastsängerin",
                                coverUrl: "", artistList: twoArtists }]
        host.visible = true
        frame(host.contentItem)
        var cards = visibleNamed(host.contentItem, "cardMenuArea").map(function (m) { return m.parent })
        compare(cards.length, 1)
        compare(cards[0].artistList.length, 2, "the row dropped the card's artists")
    }

    readonly property var albumMap: ({ id: 4242, title: "Nachtfahrt",
                                       artists: "Erika Mustermann, Gastsängerin",
                                       artistList: twoArtists, coverUrl: "" })

    function test_pages_build_album_cards_with_their_artists() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1280, height: 760 })
        var home = createTemporaryObject(homeC, holder, {})
        compare(home.albumItem(albumMap).artistList.length, 2, "Home's album rows drop the artists")
        compare(home.feedCard(albumMap).artistList.length, 2, "Home's feed rows drop the artists")
        var search = createTemporaryObject(searchC, holder, {})
        search.albums = [albumMap]
        compare(search.tilesFor(search.kAlbums)[0].artistList.length, 2,
                "Search's album tiles drop the artists")
    }

    function test_the_collection_album_grid_links_its_artists() {
        bridge.setFavoriteAlbumsForTest([albumMap])
        var holder = createTemporaryObject(holderC, testCase, { width: 1280, height: 800 })
        var page = createTemporaryObject(collectionC, holder, {})
        page.activeTab = 1
        var cards = []
        tryVerify(function () {
            cards = visibleNamed(page, "cardMenuArea").map(function (m) { return m.parent })
            return cards.length === 1
        }, 3000, "the albums grid drew no card")
        compare(cards[0].artistList.length, 2, "the albums grid drops the artists")
    }
}
