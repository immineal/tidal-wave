// components/ArtistLinks.qml everywhere it is not the player bar or Now
// Playing — those two are tests/qml/tst_navigation.qml's, and they went on
// passing unchanged when the two copies became one component.
//
// The user, for the third time: the selector belongs "in the album view and
// wherever else it is currently still just an unhighlighted thing that just
// leads to the first artist in the accent color". So: a track row, a queue row,
// the album hero and the sticky header it collapses into, and the "Go to
// artist" entry of a track row's menu, which is a submenu once a track has
// more than one credited artist.
//
// Every host stands in for Main.qml, which owns the router: a line reaches it
// as Window.window.navigate(page, params), and the hosts record the calls
// instead of routing, so a test can say exactly where a click would have gone.
//
// German names on purpose: track metadata is never translated (SPEC T3) but it
// is what has to fit, and German names are long.

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ArtistLinks"
    when: windowShown

    // ── fixtures ─────────────────────────────────────────────────────────

    readonly property var twoArtists: [
        { id: 11, name: "Erika Mustermann" },
        { id: 22, name: "Gastsängerin" }
    ]

    // The shape TidalBridge::trackToMap() produces.
    function trackWith(artists) {
        var names = []
        for (var i = 0; i < artists.length; i++) names.push(artists[i].name)
        return {
            id:          4242,
            title:       "Weit hinter dem Horizont",
            artists:     names.join(", "),
            artistId:    artists.length > 0 ? artists[0].id : 0,
            artistList:  artists,
            albumTitle:  "Nachtfahrt",
            albumId:     7788,
            coverUrl:    "",
            coverUrl80:  "",
            duration:    215,
            durationStr: "3:35"
        }
    }

    // A map from before artistList existed: a recently-played entry restored
    // from disk, or anything a caller built by hand.
    function trackWithoutList() {
        return {
            id: 99, title: "Ohne Liste", artists: "Erika Mustermann, Gastsängerin",
            artistId: 11, albumId: 7788, albumTitle: "Nachtfahrt",
            coverUrl: "", coverUrl80: "", duration: 100, durationStr: "1:40"
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        player.setCurrentTrackForTest({})
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        player.resetQueueCallsForTest()
    }

    // ── helpers ──────────────────────────────────────────────────────────

    // Every visible descendant carrying this objectName, in tree order, which
    // for a Repeater inside a Row is left to right.
    function visibleNamed(item, objectName) {
        return collectNamed(item, objectName, [])
    }

    function collectNamed(item, objectName, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            if (c.objectName === objectName) out.push(c)
            collectNamed(c, objectName, out)
        }
        return out
    }

    function namesOf(items) {
        var out = []
        for (var i = 0; i < items.length; i++) out.push(items[i].text)
        return out.join(" | ")
    }

    function centerClick(item) {
        mouseClick(item, Math.round(item.width / 2), Math.round(item.height / 2))
    }

    function hover(item) {
        mouseMove(item, Math.round(item.width / 2), Math.round(item.height / 2))
        wait(0)
    }

    function rightEdgeIn(item, container) {
        return item.mapToItem(container, item.width, 0).x
    }

    function showHost(component, w, h) {
        var host = createTemporaryObject(component, testCase)
        verify(host, "host window was not created")
        host.width = w
        host.height = h
        host.visible = true
        waitForRendering(host.contentItem, 2000)
        return host
    }

    function settle(host) {
        wait(1)
        waitForRendering(host.contentItem, 2000)
    }

    // ── hosts ────────────────────────────────────────────────────────────

    Component {
        id: trackRowHost
        Window {
            id: trWin
            width: 900; height: 200

            property var navCalls: []
            property int playCalls: 0
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}

            property alias row: tr
            TrackRow {
                id: tr
                width: trWin.width
                height: 52
                onPlayRequested: trWin.playCalls++
            }
        }
    }

    Component {
        id: albumHost
        Window {
            id: alWin
            width: 1100; height: 700

            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}

            property alias page: ap
            AlbumPage {
                id: ap
                anchors.fill: parent
            }
        }
    }

    Component {
        id: queueHost
        Window {
            id: qWin
            width: 960; height: 700

            property var navCalls: []
            function navigate(page, params) {
                navCalls = navCalls.concat([{ page: page, params: params }])
            }
            function goBack() {}

            property alias panel: qp
            QueuePanel {
                id: qp
                anchors.fill: parent
            }
        }
    }

    function makeRow(track) {
        var host = showHost(trackRowHost, 900, 200)
        host.row.trackData = track
        host.row.title     = track.title
        host.row.artists   = track.artists
        settle(host)
        return host
    }

    // The album id is assigned first: it triggers the load, and the stub
    // answers synchronously with an empty list, which would otherwise wipe the
    // tracks straight back out again.
    function makeAlbum(albumData, tracks) {
        var host = showHost(albumHost, 1100, 700)
        host.page.albumId = 42
        host.page.albumData = albumData
        host.page.tracks = tracks || []
        settle(host)
        return host
    }

    // ── a track row ──────────────────────────────────────────────────────

    function test_track_row_renders_one_target_per_artist() {
        var host = makeRow(trackWith(testCase.twoArtists))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 2, "each artist needs its own target in a track row")
        compare(namesOf(names), "Erika Mustermann | Gastsängerin")
        verify(rightEdgeIn(names[0], host.row) <= names[1].mapToItem(host.row, 0, 0).x + 0.5,
               "the two artist names overlap")
    }

    function test_track_row_second_artist_opens_the_second_artist() {
        var host = makeRow(trackWith(testCase.twoArtists))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 2, "each artist needs its own target in a track row")

        centerClick(names[1])
        compare(host.navCalls.length, 1, "clicking an artist should navigate once")
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 22,
                "the second name must open the second artist, not the lead")
        compare(host.playCalls, 0, "an artist click is not a request to play the row")
    }

    function test_track_row_first_artist_opens_the_first_artist() {
        var host = makeRow(trackWith(testCase.twoArtists))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 2, "each artist needs its own target in a track row")
        centerClick(names[0])
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].params.artistId, 11)
        compare(host.playCalls, 0)
    }

    // The row's own job survives: the names took the clicks that land on them
    // and nothing else.
    function test_track_row_still_plays_from_the_rest_of_the_line() {
        var host = makeRow(trackWith(testCase.twoArtists))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 2, "each artist needs its own target in a track row")
        var after = rightEdgeIn(names[1], host.row)
        verify(host.row.width - after > 40, "fixture needs slack after the names")

        var y = Math.round(names[1].mapToItem(host.row, 0, names[1].height / 2).y)
        mouseClick(host.row, Math.round(after + 20), y)
        compare(host.playCalls, 1, "the space after the names still plays the row")
        compare(host.navCalls.length, 0, "empty space is not an artist link")

        var title = findChild(host.row, "trackTitle")
        verify(title, "the row title was not found")
        centerClick(title)
        compare(host.playCalls, 2, "the title still plays the row")
        compare(host.navCalls.length, 0)
    }

    // The links take the left button only, so the row menu is still reachable
    // from anywhere on the row including an artist's name.
    function test_track_row_right_click_on_a_name_still_opens_the_menu() {
        var host = makeRow(trackWith(testCase.twoArtists))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 2, "each artist needs its own target in a track row")

        mouseClick(names[1], Math.round(names[1].width / 2), Math.round(names[1].height / 2),
                   Qt.RightButton)
        tryVerify(function () { return host.row.rowMenu && host.row.rowMenu.visible }, 2000,
                  "a right-click on an artist name did not open the row menu")
        compare(host.navCalls.length, 0, "a right-click is not a visit to the artist")
        host.row.rowMenu.close()
    }

    // The row dresses itself on hover — the play glyph replaces the track
    // number. Pointing at a name must not read as leaving the row.
    function test_track_row_stays_hovered_over_a_name() {
        var host = makeRow(trackWith(testCase.twoArtists))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 2, "each artist needs its own target in a track row")
        // Park the pointer below the row first, so "hovered" below is this
        // test's doing and not wherever the pointer happened to already be.
        mouseMove(host.contentItem, 400, 150)
        wait(0)
        verify(!host.row.hovered, "the pointer could not be moved off the row")

        hover(names[1])
        verify(names[1].font.underline, "the hovered name should be underlined")
        verify(host.row.hovered,
               "the row stopped reporting itself hovered while the pointer was on a name")
    }

    function test_track_row_hover_underlines_only_that_name() {
        var host = makeRow(trackWith(testCase.twoArtists))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 2, "each artist needs its own target in a track row")
        verify(!names[0].font.underline && !names[1].font.underline,
               "nothing is underlined before the pointer arrives")
        hover(names[1])
        verify(names[1].font.underline, "the hovered name should be underlined")
        verify(!names[0].font.underline, "only the hovered name should be underlined")
    }

    // A map that predates artistList still shows its artists, as one link to
    // the one artist it can name.
    function test_track_row_without_artist_list_falls_back_to_one_link() {
        var host = makeRow(trackWithoutList())
        compare(visibleNamed(host.row, "trackRowArtistName").length, 0,
                "no artist list means no per-artist targets")
        var joined = findChild(host.row, "trackRowArtists")
        verify(joined && joined.visible, "the joined artists line should stand in")
        compare(joined.text, "Erika Mustermann, Gastsängerin")

        // Near the left edge: the hit target follows the words, not the column.
        mouseClick(joined, 6, Math.round(joined.height / 2))
        compare(host.navCalls.length, 1, "the fallback still opens the lead artist")
        compare(host.navCalls[0].params.artistId, 11)
    }

    function test_track_row_credit_without_an_id_is_not_a_target() {
        var host = makeRow(trackWith([{ id: 0, name: "Unbekannt" }]))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 1, "the name still shows, it just does not link")
        verify(!names[0].activeFocusOnTab, "a dead credit is not a tab stop")
        hover(names[0])
        verify(!names[0].font.underline, "an artist with no id must not look clickable")
        centerClick(names[0])
        compare(host.navCalls.length, 0, "an artist with no id must not navigate")
        compare(host.playCalls, 1, "it falls through and plays the row, like the gaps do")
    }

    function test_track_row_each_artist_is_its_own_tab_stop() {
        var host = makeRow(trackWith(testCase.twoArtists))
        var names = visibleNamed(host.row, "trackRowArtistName")
        compare(names.length, 2, "each artist needs its own target in a track row")
        for (var i = 0; i < names.length; i++)
            verify(names[i].activeFocusOnTab,
                   "\"" + names[i].text + "\" is not reachable by tab")

        names[1].forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(host.navCalls.length, 1, "Return on a focused name should navigate")
        compare(host.navCalls[0].params.artistId, 22)
    }

    // ── the album hero, and the header it collapses into ─────────────────

    function test_album_hero_renders_one_target_per_artist() {
        var host = makeAlbum({ title: "Nachtfahrt", artists: "Erika Mustermann, Gastsängerin",
                               artistId: 11, artistList: testCase.twoArtists, coverUrl: "" })
        var names = visibleNamed(host.page, "albumHeroArtistName")
        compare(names.length, 2, "each artist on the album needs its own target")
        compare(namesOf(names), "Erika Mustermann | Gastsängerin")

        centerClick(names[1])
        compare(host.navCalls.length, 1, "clicking an artist should navigate once")
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 22,
                "the album hero's second name must open the second artist")
    }

    function test_album_hero_hover_underlines_only_that_name() {
        var host = makeAlbum({ title: "Nachtfahrt", artists: "Erika Mustermann, Gastsängerin",
                               artistId: 11, artistList: testCase.twoArtists, coverUrl: "" })
        var names = visibleNamed(host.page, "albumHeroArtistName")
        compare(names.length, 2, "each artist on the album needs its own target")
        verify(!names[0].font.underline && !names[1].font.underline,
               "nothing is underlined before the pointer arrives")
        hover(names[1])
        verify(names[1].font.underline, "the hovered name should be underlined")
        verify(!names[0].font.underline, "only the hovered name should be underlined")
    }

    // An album map with no artistList — one the app built by hand, or an older
    // cache — keeps the one link it always had, to the lead artist, and
    // effectiveArtistId still recovers that id off the tracklist.
    function test_album_hero_without_artist_list_falls_back_to_the_lead() {
        var host = makeAlbum({ title: "Nachtfahrt", artists: "Erika Mustermann", coverUrl: "" },
                             [trackWith(testCase.twoArtists)])
        compare(visibleNamed(host.page, "albumHeroArtistName").length, 0,
                "no artist list means no per-artist targets")
        var joined = findChild(host.page, "albumHeroArtists")
        verify(joined && joined.visible, "the joined artists line should stand in")
        compare(joined.text, "Erika Mustermann")
        mouseClick(joined, 6, Math.round(joined.height / 2))
        compare(host.navCalls.length, 1, "the fallback still opens the lead artist")
        compare(host.navCalls[0].params.artistId, 11)
    }

    // The sticky header is full size the whole time and only fades in, so
    // while it is invisible its links must be neither hit targets nor tab
    // stops — they sit over the top of the hero.
    function test_album_sticky_header_links_are_dead_until_it_is_shown() {
        var host = makeAlbum({ title: "Nachtfahrt", artists: "Erika Mustermann, Gastsängerin",
                               artistId: 11, artistList: testCase.twoArtists, coverUrl: "" },
                             [trackWith(testCase.twoArtists)])
        var names = visibleNamed(host.page, "albumStickyArtistName")
        compare(names.length, 2, "the collapsed header carries the same names")
        for (var i = 0; i < names.length; i++) {
            verify(!names[i].enabled,
                   "\"" + names[i].text + "\" is live while the sticky header is invisible")
            verify(!names[i].activeFocusOnTab || !names[i].enabled,
                   "\"" + names[i].text + "\" is a tab stop while invisible")
        }
        centerClick(names[1])
        compare(host.navCalls.length, 0,
                "an invisible sticky header must not answer a click over the hero")
    }

    function test_album_sticky_header_links_work_once_it_is_shown() {
        var host = makeAlbum({ title: "Nachtfahrt", artists: "Erika Mustermann, Gastsängerin",
                               artistId: 11, artistList: testCase.twoArtists, coverUrl: "" },
                             [trackWith(testCase.twoArtists)])
        var list = findChild(host.page, "albumTracksList")
        verify(list, "the album tracklist was not found")
        list.contentY = 400
        settle(host)

        var names = visibleNamed(host.page, "albumStickyArtistName")
        compare(names.length, 2, "the collapsed header carries the same names")
        for (var i = 0; i < names.length; i++)
            verify(names[i].enabled,
                   "\"" + names[i].text + "\" is still dead with the header on screen")

        centerClick(names[1])
        compare(host.navCalls.length, 1, "the shown header's names are links")
        compare(host.navCalls[0].params.artistId, 22)
    }

    // ── a queue row ──────────────────────────────────────────────────────

    function test_queue_row_artist_opens_that_artist_rather_than_jumping() {
        player.setCurrentTrackForTest(trackWith([{ id: 99, name: "Jetzt" }]))
        player.setManualForTest([trackWith(testCase.twoArtists)])
        var host = showHost(queueHost, 960, 700)
        settle(host)
        tryVerify(function () { return host.panel.rowCount > 0 }, 5000,
                  "the queue panel drew no rows at all")
        settle(host)

        var names = visibleNamed(host.panel, "queueArtistName")
        compare(names.length, 2, "each artist in a queue row needs its own target")
        compare(namesOf(names), "Erika Mustermann | Gastsängerin")

        var jumpsBefore = player.queueCalls.length
        centerClick(names[1])
        compare(host.navCalls.length, 1, "clicking an artist should navigate once")
        compare(host.navCalls[0].params.artistId, 22)
        compare(player.queueCalls.length, jumpsBefore,
                "an artist click must not jump the queue to that row")
    }

    // ── "Go to artist" in the row menu ───────────────────────────────────

    function openRowMenu(host) {
        host.row.openMenu()
        tryVerify(function () { return host.row.rowMenu && host.row.rowMenu.visible }, 2000,
                  "the row menu did not open")
        return host.row.rowMenu
    }

    function menuItemNamed(menu, objectName) {
        for (var i = 0; i < menu.count; i++) {
            var it = menu.itemAt(i)
            if (it && it.objectName === objectName) return it
        }
        return null
    }

    function creditLabels(subMenu) {
        var out = []
        for (var i = 0; i < subMenu.count; i++) {
            var it = subMenu.itemAt(i)
            if (it) out.push(it.text)
        }
        return out.join(" | ")
    }

    // One credited artist: the row it has always been, no submenu and no extra
    // hover to get at it.
    function test_go_to_artist_is_a_plain_row_for_one_artist() {
        var host = makeRow(trackWith([{ id: 11, name: "Erika Mustermann" }]))
        var menu = openRowMenu(host)

        var direct = menuItemNamed(menu, "goToArtistMenuItem")
        verify(direct, "the Go to artist entry was not found")
        verify(direct.visible, "a single-artist track gets the direct action")
        verify(direct.enabled, "and it has somewhere to go")

        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(subRow, "the submenu row was not built from the menu's delegate")
        verify(!subRow.visible, "one artist must not be offered as a submenu")
        compare(subRow.height, 0, "a hidden row must not keep its height")

        direct.triggered()
        compare(host.navCalls.length, 1, "the direct action should navigate once")
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 11)
        menu.close()
    }

    // More than one, and the names go in a submenu instead of the one row
    // picking the lead for you.
    function test_go_to_artist_becomes_a_submenu_for_several() {
        var host = makeRow(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" },
            { id: 33, name: "Rundfunk-Tanzorchester Ehrenfeld" }
        ]))
        var menu = openRowMenu(host)

        var direct = menuItemNamed(menu, "goToArtistMenuItem")
        verify(direct, "the Go to artist entry was not found")
        verify(!direct.visible, "the direct action must stand down for the submenu")
        compare(direct.height, 0, "a hidden row must not keep its height")

        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(subRow, "the submenu row was not built from the menu's delegate")
        verify(subRow.visible, "three artists must be offered as a submenu")
        compare(subRow.text, qsTranslate("TrackRow", "Go to artist"),
                "the submenu row says what the direct row said")
        compare(subRow.iconName, "artist", "every menu row carries its icon")
        verify(subRow.subMenu, "the row has no submenu attached")

        compare(creditLabels(subRow.subMenu),
                "Erika Mustermann | Gastsängerin | Rundfunk-Tanzorchester Ehrenfeld",
                "the submenu lists the credits in order")
        menu.close()
    }

    function test_go_to_artist_submenu_rows_open_their_own_artist() {
        var host = makeRow(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 22, name: "Gastsängerin" },
            { id: 33, name: "Rundfunk-Tanzorchester Ehrenfeld" }
        ]))
        var menu = openRowMenu(host)
        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(subRow, "the submenu row was not built from the menu's delegate")
        var subMenu = subRow.subMenu
        verify(subMenu, "the submenu row has no submenu attached")
        compare(subMenu.count, 3, "one row per credited artist")

        subMenu.itemAt(2).triggered()
        compare(host.navCalls.length, 1, "a submenu row should navigate once")
        compare(host.navCalls[0].page, "artist")
        compare(host.navCalls[0].params.artistId, 33,
                "the third row must open the third artist")

        subMenu.itemAt(0).triggered()
        compare(host.navCalls.length, 2)
        compare(host.navCalls[1].params.artistId, 11)
        menu.close()
    }

    // A credit with no usable id is dropped rather than becoming a row that
    // does nothing — the same way the text links skip it for tab focus.
    function test_go_to_artist_submenu_drops_credits_with_no_id() {
        var host = makeRow(trackWith([
            { id: 11, name: "Erika Mustermann" },
            { id: 0,  name: "Unbekannt" },
            { id: 33, name: "Rundfunk-Tanzorchester Ehrenfeld" }
        ]))
        var menu = openRowMenu(host)
        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(subRow, "the submenu row was not built from the menu's delegate")
        var subMenu = subRow.subMenu
        verify(subMenu, "the submenu row has no submenu attached")
        compare(subMenu.count, 2, "a credit with no id must not get a row")
        compare(creditLabels(subMenu),
                "Erika Mustermann | Rundfunk-Tanzorchester Ehrenfeld")
        menu.close()
    }

    // Two credits but only one of them usable is one action, not a submenu of
    // one.
    function test_go_to_artist_collapses_when_only_one_credit_is_usable() {
        var host = makeRow(trackWith([
            { id: 0,  name: "Unbekannt" },
            { id: 33, name: "Rundfunk-Tanzorchester Ehrenfeld" }
        ]))
        var menu = openRowMenu(host)

        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(subRow && !subRow.visible, "one usable credit is not a submenu")

        var direct = menuItemNamed(menu, "goToArtistMenuItem")
        verify(direct && direct.visible && direct.enabled,
               "the one usable credit should be the direct action")
        direct.triggered()
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].params.artistId, 33,
                "the direct action must open the credit that has an id, not the first name")
        menu.close()
    }

    // No usable id at all: the row stays where it was, and does nothing.
    function test_go_to_artist_is_dead_when_nothing_is_reachable() {
        var host = makeRow(trackWith([{ id: 0, name: "Unbekannt" }]))
        var menu = openRowMenu(host)

        var direct = menuItemNamed(menu, "goToArtistMenuItem")
        verify(direct && direct.visible, "the row stays in place")
        verify(!direct.enabled, "with nowhere to go it must be dead")

        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(subRow && !subRow.visible, "and there is no submenu")

        direct.triggered()
        compare(host.navCalls.length, 0, "a dead row must not navigate")
        menu.close()
    }

    // A track map with no artistList has exactly one credit it can name, so it
    // gets the direct action — the behaviour the entry had before the submenu.
    function test_go_to_artist_without_an_artist_list_is_the_direct_action() {
        var host = makeRow(trackWithoutList())
        var menu = openRowMenu(host)

        var subRow = menuItemNamed(menu, "goToArtistSubMenuRow")
        verify(subRow && !subRow.visible, "a map with no list cannot fill a submenu")

        var direct = menuItemNamed(menu, "goToArtistMenuItem")
        verify(direct && direct.visible && direct.enabled)
        direct.triggered()
        compare(host.navCalls.length, 1)
        compare(host.navCalls[0].params.artistId, 11)
        menu.close()
    }
}
