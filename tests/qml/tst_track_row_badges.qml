// What a track row says beside its title: the version that tells two
// recordings of one title apart and the explicit mark; and the heart that
// says a track is liked. Every id and title is invented.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TrackRowBadges"
    when: windowShown
    visible: true
    width: 900
    height: 300

    Component { id: rowC; TrackRow { width: 700 } }

    function init() {
        app.setReducedMotionForTest(true)
        bridge.resetForTest()
        bridge.setFavoriteOkForTest(true)
        bridge.resetFavoriteCallsForTest()
        bridge.setTrackFavoriteForTest(9301, false)
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

    function makeRow(extra, width) {
        var track = { id: 9301, title: "Abendlied", artists: "Ein Chor", artistId: 7,
                      albumTitle: "Lieder", albumId: 42, coverUrl: "", coverUrl80: "",
                      duration: 200 }
        for (var k in extra) track[k] = extra[k]
        var row = createTemporaryObject(rowC, testCase, {
            trackData: track, title: track.title, artists: track.artists,
            width: width || 700
        })
        verify(row, "TrackRow did not load")
        waitForRendering(row)
        return row
    }

    function test_a_version_is_shown_after_the_title() {
        var row = makeRow({ version: "Live in Bremen" })
        var title = findByName(row, "trackTitle")
        var version = findByName(row, "trackVersion")
        verify(version, "the row has no version label")
        verify(version.visible, "the version is not shown")
        compare(version.text, "(Live in Bremen)")
        var t = title.mapToItem(row, 0, 0), v = version.mapToItem(row, 0, 0)
        verify(v.x >= t.x + title.width, "the version does not follow the title")
        compare(Math.round(v.y + version.height / 2), Math.round(t.y + title.height / 2),
                "the version is not on the title's line")
    }

    function test_no_version_no_label() {
        var row = makeRow({})
        var version = findByName(row, "trackVersion")
        verify(!version || !version.visible, "a label is shown for a track without a version")
    }

    // The title gives way last: a narrow row cuts the version first.
    function test_the_title_keeps_its_room_before_the_version() {
        var row = makeRow({ title: "Ein recht langer Titel für eine schmale Zeile",
                            version: "Remastered 2011 Deluxe Edition" }, 420)
        var title = findByName(row, "trackTitle")
        var version = findByName(row, "trackVersion")
        verify(!title.truncated || version.width <= 64,
               "the title was cut while the version kept its room")
    }

    function test_an_explicit_track_is_marked() {
        var row = makeRow({ explicit_: true, version: "Live" })
        var badge = findByName(row, "trackExplicitBadge")
        verify(badge, "the row has no explicit mark")
        verify(badge.visible, "an explicit track is not marked")
        compare(badge.label, "E")
        compare(badge.Accessible.name, "Explicit")
        // After the title and its version, on their line.
        var version = findByName(row, "trackVersion")
        var b = badge.mapToItem(row, 0, 0), v = version.mapToItem(row, 0, 0)
        verify(b.x >= v.x + version.width, "the mark is not after the version")
        verify(badge.width <= 20 && badge.height <= 20, "the mark is not small")
    }

    function test_a_clean_track_has_no_mark() {
        var row = makeRow({ explicit_: false })
        var badge = findByName(row, "trackExplicitBadge")
        verify(!badge || !badge.visible, "a clean track is marked explicit")
    }

    function test_a_liked_track_shows_its_heart() {
        bridge.setTrackFavoriteForTest(9301, true)
        var row = makeRow({})
        var heart = findByName(row, "trackLikeButton")
        verify(heart, "the row has no heart")
        tryVerify(function () { return heart.opacity > 0.99 }, 2000,
                  "a liked track shows no heart without the pointer on it")
        compare(heart.liked, true)
    }

    function test_an_unliked_track_shows_no_heart_until_pointed_at() {
        var row = makeRow({})
        var heart = findByName(row, "trackLikeButton")
        verify(heart, "the row has no heart")
        compare(heart.opacity, 0, "an unliked track shows a heart at rest")
        mouseMove(row, row.width / 2, row.height / 2)
        tryVerify(function () { return heart.opacity > 0.99 }, 2000,
                  "the heart does not come up on hover")
    }

    function test_the_heart_likes_and_unlikes() {
        var row = makeRow({})
        var heart = findByName(row, "trackLikeButton")
        mouseMove(row, row.width / 2, row.height / 2)
        tryVerify(function () { return heart.opacity > 0.99 }, 2000)
        mouseClick(heart, heart.width / 2, heart.height / 2)
        tryVerify(function () { return bridge.lastFavoriteCallForTest() === "addTrack:9301" }, 2000,
                  "a click on the heart sent no like")
        tryVerify(function () { return row.isLiked }, 2000, "the like did not land on the row")
        mouseClick(heart, heart.width / 2, heart.height / 2)
        tryVerify(function () { return bridge.lastFavoriteCallForTest() === "removeTrack:9301" }, 2000,
                  "a click on a liked heart sent no unlike")
    }

    // The heart's click is its own: it does not play the row.
    function test_the_heart_does_not_play_the_row() {
        var row = makeRow({})
        var played = 0
        row.playRequested.connect(function () { ++played })
        var heart = findByName(row, "trackLikeButton")
        mouseMove(row, row.width / 2, row.height / 2)
        tryVerify(function () { return heart.opacity > 0.99 }, 2000)
        mouseClick(heart, heart.width / 2, heart.height / 2)
        compare(played, 0, "a click on the heart played the track")
    }
}
