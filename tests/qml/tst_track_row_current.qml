// A track row of the player's track shows it as the current one whether it
// plays or is paused, and a click on it pauses or resumes it.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TrackRowCurrent"
    when: windowShown
    // TestCase declares visible: false, which would make every child report
    // visible == false.
    visible: true
    width: 900
    height: 300

    function rowOf(id, title, seconds) {
        return {
            id: id, title: title, artists: "Erste Interpretin", artistId: 7,
            albumTitle: "Ein Album", albumId: 42, coverUrl: "", coverUrl80: "",
            duration: seconds
        }
    }

    Component { id: rowC; TrackRow { width: 700 } }

    function init() {
        app.setReducedMotionForTest(true)
        player.setCurrentTrackForTest({})
        player.setPlayingForTest(false)
    }

    function cleanup() {
        player.setCurrentTrackForTest({})
        player.setPlayingForTest(false)
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

    function makeRow(track) {
        var row = createTemporaryObject(rowC, testCase, {
            trackData: track, title: track.title, artists: track.artists
        })
        verify(row, "TrackRow did not load")
        return row
    }

    SignalSpy { id: playSpy; signalName: "playRequested" }

    function test_a_paused_current_track_keeps_its_highlight() {
        var track = rowOf(8100, "Winterabend", 247)
        var row = makeRow(track)
        player.setCurrentTrackForTest(track)
        player.setPlayingForTest(true)
        wait(1)
        verify(row.isCurrent && row.playsNow, "the playing track is not shown as playing")

        player.setPlayingForTest(false)
        wait(1)
        verify(row.isCurrent, "the paused track lost its place as the current one")
        verify(!row.playsNow, "the paused track is shown as playing")
        var title = findByName(row, "trackTitle")
        verify(Qt.colorEqual(title.color, Theme.accentText), "the paused track's title lost its accent")
        verify(!findByName(row, "trackRowPlayingIndicator").visible,
               "the paused track shows the moving bars")
        verify(findByName(row, "trackRowNumber").visible, "the paused track shows no number")
    }

    function test_a_click_on_the_current_track_pauses_and_resumes_it() {
        var track = rowOf(8101, "Nebelmeer", 200)
        var row = makeRow(track)
        playSpy.target = row
        playSpy.clear()
        player.setCurrentTrackForTest(track)
        player.setPlayingForTest(true)
        wait(1)

        mouseClick(row, row.width / 2, row.height / 2)
        verify(!player.playing, "a click on the playing track did not pause it")
        mouseClick(row, row.width / 2, row.height / 2)
        verify(player.playing, "a click on the paused track did not resume it")
        row.forceActiveFocus()
        keyClick(Qt.Key_Space)
        verify(!player.playing, "Space on the playing track did not pause it")
        compare(playSpy.count, 0, "the current track was started over")
    }

    function test_a_click_on_another_track_plays_it() {
        var row = makeRow(rowOf(8102, "Morgenrot", 200))
        playSpy.target = row
        playSpy.clear()
        player.setCurrentTrackForTest(rowOf(8103, "Anderswo", 100))
        player.setPlayingForTest(true)
        wait(1)
        verify(!row.isCurrent, "a row of another track is shown as the current one")
        mouseClick(row, row.width / 2, row.height / 2)
        compare(playSpy.count, 1, "a click on another track did not ask to play it")
    }
}
