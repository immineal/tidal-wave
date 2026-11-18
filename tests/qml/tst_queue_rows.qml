// The queue panel reads each row from the player as it draws it, rather
// than holding the whole queue as one JS list. These pin what the list used
// to give for free: a row follows a change to the queue that keeps its
// length, and a drag ends when the queue changes under it.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "QueueRows"
    when: windowShown

    function makeTracks(n, tag) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ id: 1000 + i, title: tag + " " + i, artists: "Artist", albumTitle: "Album",
                       albumId: 55, duration: 215, coverUrl80: "" })
        return out
    }

    function collect(item, name, out) {
        if (item.objectName === name) out.push(item)
        for (var i = 0; i < item.children.length; ++i) collect(item.children[i], name, out)
        return out
    }
    function titles(panel) {
        var all = collect(panel, "queueEntry", [])
        all.sort(function (a, b) { return a.rowIndex - b.rowIndex })
        var out = []
        for (var i = 0; i < all.length; ++i) if (!all[i].isHeader) out.push(all[i].titleText)
        return out.join(",")
    }

    Component {
        id: hostC
        Window {
            width: 960; height: 700
            property alias panel: qp
            function navigate(page, params) {}
            QueuePanel { id: qp; anchors.fill: parent; visible: false }
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        player.setManualForTest([])
        player.setQueueForTest(makeTracks(3, "A"), 0)
    }

    function openHost() {
        var host = createTemporaryObject(hostC, testCase)
        verify(host)
        host.visible = true
        host.panel.visible = true
        tryVerify(function () { return host.panel.rowCount > 0 }, 5000)
        waitForRendering(host.contentItem)
        return host
    }

    function test_a_row_follows_a_queue_of_the_same_length() {
        var host = openHost()
        compare(titles(host.panel), "A 0,A 1,A 2")
        player.setQueueForTest(makeTracks(3, "B"), 0)
        tryVerify(function () { return titles(host.panel) === "B 0,B 1,B 2" }, 2000,
                  "the rows still show " + titles(host.panel))
    }

    function test_a_drag_ends_when_the_queue_changes() {
        var host = openHost()
        var panel = host.panel
        panel.beginDrag("context", 0, panel.contextAt, 0, 0)
        verify(panel.dragging)
        player.setQueueForTest(makeTracks(3, "B"), 0)
        verify(!panel.dragging, "the drag outlived a change to the queue")
    }
}
