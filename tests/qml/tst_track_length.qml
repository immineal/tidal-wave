// Lengths read as a clock does, with hours from an hour on, in the track rows
// and on the seek bar, and the labels are wide enough for them.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "TrackLength"
    when: windowShown
    // TestCase declares visible: false, which would make every child report
    // visible == false.
    visible: true
    width: 900
    height: 300

    Component { id: rowC; TrackRow { width: 700 } }
    Component { id: seekC; SeekBar { width: 500 } }

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

    function makeRow(seconds) {
        var track = {
            id: 8104, title: "Lang", artists: "Erste Interpretin", artistId: 7,
            albumTitle: "Ein Album", albumId: 42, coverUrl: "", coverUrl80: "",
            duration: seconds
        }
        var row = createTemporaryObject(rowC, testCase, {
            trackData: track, title: track.title, artists: track.artists
        })
        verify(row, "TrackRow did not load")
        return row
    }

    function test_lengths_read_as_a_clock_data() {
        return [
            { tag: "seconds",        secs: 7,    want: "0:07" },
            { tag: "minutes",        secs: 247,  want: "4:07" },
            { tag: "just under 1 h", secs: 3599, want: "59:59" },
            { tag: "an hour",        secs: 3600, want: "1:00:00" },
            { tag: "over an hour",   secs: 4325, want: "1:12:05" }
        ]
    }

    function test_lengths_read_as_a_clock(data) {
        compare(Theme.clock(data.secs * 1000), data.want)
        var row = makeRow(data.secs)
        compare(row.durationText, data.want, "the row reads its length otherwise")
        var seek = createTemporaryObject(seekC, testCase, { duration: data.secs * 1000 })
        verify(seek, "SeekBar did not load")
        var texts = []
        for (var i = 0; i < seek.children.length; ++i)
            if (seek.children[i].text !== undefined) texts.push(seek.children[i].text)
        verify(texts.indexOf(data.want) >= 0, "the seek bar reads " + texts.join(" / "))
        var length = findByName(row, "trackDuration")
        verify(length.width >= length.implicitWidth, "the row cuts its length short")
    }
}
