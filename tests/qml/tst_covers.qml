// Artwork that is not there, and artwork that repeats. A hero without a cover
// of its own builds a 2x2 mosaic from its tracks' covers: four distinct ones,
// or the one cover when fewer than four exist. A row, the player bar, the
// queue and Now Playing draw a themed placeholder where a track has no cover.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Covers"
    when: windowShown
    width: 1000
    height: 900
    visible: true

    Component { id: holderC; Item { } }
    Component { id: heroC; DetailHero { width: 700 } }
    Component { id: playlistC; PlaylistPage { anchors.fill: parent } }
    Component { id: rowC; TrackRow { width: 700; height: 56 } }
    Component { id: barC; PlayerBar { width: 960 } }
    Component { id: nowC; NowPlayingPage { anchors.fill: parent } }
    Component {
        id: queueC
        Window {
            width: 960; height: 700
            property alias panel: qp
            QueuePanel { id: qp; anchors.fill: parent; visible: false }
        }
    }

    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
        wait(1)
    }

    function collect(item, pred, out) {
        if (!item) return out
        if (pred(item)) out.push(item)
        for (var i = 0; i < item.children.length; i++) collect(item.children[i], pred, out)
        return out
    }
    function findByName(item, name) {
        var hit = collect(item, function (it) { return it.objectName === name }, [])
        return hit.length > 0 ? hit[0] : null
    }
    function shown(item) {
        for (var it = item; it; it = it.parent) if (!it.visible) return false
        return true
    }

    // The covers the hero's art box draws, as image ids, in reading order.
    function drawnCovers(hero) {
        var art = findByName(hero, "heroArt")
        verify(art, "the hero has no art box")
        var imgs = collect(art, function (it) {
            return it.source !== undefined && it.fillMode !== undefined
                   && String(it.source).length > 0 && shown(it)
        }, [])
        imgs.sort(function (a, b) {
            var pa = a.mapToItem(art, 0, 0), pb = b.mapToItem(art, 0, 0)
            return pa.y !== pb.y ? pa.y - pb.y : pa.x - pb.x
        })
        return imgs.map(function (i) { return String(i.source).replace("image://tidal/", "") })
    }

    function test_a_mosaic_never_repeats_a_cover() {
        var hero = createTemporaryObject(heroC, testCase, {
            artCovers: ["c/a", "c/a", "c/b", "c/a", "c/c", "c/b", "c/d", "c/e"] })
        frame(hero)
        compare(drawnCovers(hero).join(","), "c/a,c/b,c/c,c/d",
                "the mosaic is not the first four distinct covers")
    }

    function test_fewer_than_four_covers_make_one_cover() {
        var hero = createTemporaryObject(heroC, testCase, {
            artCovers: ["c/a", "c/a", "c/b", "c/a", "c/b", "c/c"] })
        frame(hero)
        compare(drawnCovers(hero).join(","), "c/a",
                "three distinct covers should draw the first one, whole")
    }

    function test_blank_covers_do_not_count() {
        var hero = createTemporaryObject(heroC, testCase, {
            artCovers: ["", "c/a", "", "c/b", "c/c", "", "c/d"] })
        frame(hero)
        compare(drawnCovers(hero).join(","), "c/a,c/b,c/c,c/d")
    }

    function test_an_own_cover_wins_over_the_mosaic() {
        var hero = createTemporaryObject(heroC, testCase, {
            artSource: "c/own", artCovers: ["c/a", "c/b", "c/c", "c/d"] })
        frame(hero)
        compare(drawnCovers(hero).join(","), "c/own")
    }

    // The page hands the hero every track's cover, not the first four.
    function test_the_playlist_mosaic_looks_past_the_first_four_tracks() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 800 })
        var page = createTemporaryObject(playlistC, holder)
        var covers = ["c/a", "c/a", "c/a", "c/b", "c/a", "c/c", "c/d"]
        var tracks = []
        for (var i = 0; i < covers.length; i++)
            tracks.push({ id: 500 + i, title: "T" + i, artists: "A", albumTitle: "X",
                          durationStr: "3:00", coverUrl: covers[i], coverUrl80: covers[i] })
        page.tracks = tracks
        frame(page)
        compare(drawnCovers(page).join(","), "c/a,c/b,c/c,c/d")
    }

    // ── placeholders ─────────────────────────────────────────────────────

    function placeholderIn(box) {
        verify(box, "the cover box was not found")
        var glyphs = collect(box, function (it) { return it.name !== undefined && it.color !== undefined
                                                         && it.objectName === "coverPlaceholder" }, [])
        return glyphs.length > 0 && shown(glyphs[0]) ? glyphs[0] : null
    }

    function test_a_row_without_a_cover_shows_a_placeholder() {
        var row = createTemporaryObject(rowC, testCase, {
            title: "No art", artists: "Someone", coverUrl: "", durationStr: "3:00",
            trackData: { id: 77, title: "No art", artists: "Someone", coverUrl: "" } })
        frame(row)
        var img = findByName(row, "trackRowCover")
        verify(placeholderIn(img.parent), "a row with no cover draws an empty box")

        row.coverUrl = "c/x"
        frame(row)
        verify(!placeholderIn(img.parent), "a row with a cover still draws the placeholder")
    }

    function test_the_player_bar_without_a_cover_shows_a_placeholder() {
        var t = { id: 88, title: "Bare", artists: "Someone", coverUrl: "", duration: 200 }
        player.setQueueForTest([t], 0)
        player.setCurrentTrackForTest(t)
        var bar = createTemporaryObject(barC, testCase)
        frame(bar)
        verify(placeholderIn(findByName(bar, "playerBarCover")),
               "the player bar draws an empty box for a track with no cover")
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
    }

    function test_now_playing_without_a_cover_shows_a_placeholder() {
        var t = { id: 89, title: "Bare", artists: "Someone", coverUrl: "", duration: 200 }
        player.setQueueForTest([t], 0)
        player.setCurrentTrackForTest(t)
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 800 })
        var page = createTemporaryObject(nowC, holder)
        frame(page)
        verify(placeholderIn(findByName(page, "nowPlayingArt")),
               "Now Playing draws an empty box for a track with no cover")
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
    }

    function test_a_queue_row_without_a_cover_shows_a_placeholder() {
        var t = [{ id: 90, title: "Bare", artists: "A", duration: 200, coverUrl80: "" },
                 { id: 91, title: "Bare 2", artists: "A", duration: 200, coverUrl80: "" }]
        player.setQueueForTest(t, 0)
        player.setCurrentTrackForTest(t[0])
        var host = createTemporaryObject(queueC, testCase)
        host.visible = true
        host.panel.visible = true
        frame(host.contentItem)
        tryVerify(function () { return host.panel.rowCount > 0 }, 5000)
        frame(host.contentItem)
        // The first row on screen: a delegate kept for another section is hidden.
        var img = collect(host.contentItem, function (it) {
            return it.objectName === "queueRowCover" && shown(it) }, [])[0]
        verify(img, "no queue row is on screen")
        verify(placeholderIn(img.parent), "a queue row with no cover draws an empty box")
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
    }
}
