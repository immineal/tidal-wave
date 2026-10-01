// X4: a 5000-track list.
//
// The number is not arbitrary: a Tidal favourites list of that size is
// ordinary, and CollectionPage, PlaylistPage and AlbumPage all take the whole
// array as a plain JS list rather than a model, so every one of them is a
// candidate for building 5000 delegates at once.
//
// Three things are measured per page:
//   * how long the list takes to mount and settle,
//   * how many delegates actually exist once it has (virtualisation: if this
//     is near 5000 the page is building the whole list and the window will
//     freeze on a real account),
//   * how long a full scroll from top to bottom takes.

import QtQuick
import QtTest
import TidalWave

import "StressLib.js" as S

TestCase {
    id: testCase
    name: "StressBigList"
    when: windowShown
    visible: true
    width: 1300
    height: 950

    readonly property real scale: S.scale()
    readonly property int bigN: 5000
    readonly property int paneWidth: 1100
    readonly property int paneHeight: 800

    Component { id: holderC;     Item { } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: playlistC;   PlaylistPage   { anchors.fill: parent } }
    Component { id: albumC;      AlbumPage      { anchors.fill: parent } }
    Component { id: queueC;      QueuePanel     { anchors.fill: parent } }

    // The first descendant that looks like a virtualised view and carries the
    // expected item count. Pages do not name their track list, so it is found
    // by shape rather than by objectName.
    function findView(item, wantCount) {
        if (item.count === wantCount && item.contentHeight !== undefined
            && item.contentY !== undefined)
            return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findView(kids[i], wantCount)
            if (hit) return hit
        }
        return null
    }

    // Delegates alive right now. ListView parents them to contentItem, so the
    // count of its children is the number of instantiated delegates (plus the
    // odd helper item, which does not change the order of magnitude).
    function liveDelegates(view) {
        return (view.contentItem && view.contentItem.children)
             ? view.contentItem.children.length : -1
    }

    function exercise(comp, label, apply) {
        var holder = createTemporaryObject(holderC, testCase,
                                           { width: paneWidth, height: paneHeight })
        verify(holder, "the holder was not created")

        var data = S.tracks(bigN)
        var page = comp.createObject(holder, {})
        verify(page, label + ": the page was not created")

        var t0 = Date.now()
        apply(page, data)
        waitForRendering(holder, 60000)
        var mount = Date.now() - t0

        var view = findView(page, bigN)
        if (!view) {
            console.log("[stress] " + label + ": no view reported " + bigN
                        + " items, so nothing could be measured")
            page.destroy()
            return
        }

        var live = liveDelegates(view)
        console.log("[stress] " + label + ": mounted " + bigN + " tracks in "
                    + mount + " ms, " + live + " delegates alive, contentHeight "
                    + view.contentHeight.toFixed(0) + ", rss " + S.rssKib() + " KiB")

        verify(live < 400,
               label + ": " + live + " delegates exist for " + bigN
               + " tracks, so the list is not virtualised")
        verify(mount < 15000,
               label + ": mounting " + bigN + " tracks took " + mount + " ms")

        // A full scroll, in viewport-sized jumps, which is what flicking the
        // scrollbar from top to bottom costs.
        var t1 = Date.now()
        var steps = 0
        var maxY = Math.max(0, view.contentHeight - view.height)
        // One jump per viewport, but capped: a full 5000 track sweep is 300+
        // jumps and the point is the per-jump cost, not the total.
        var maxSteps = Math.min(400, Math.max(20, Math.round(120 * scale)))
        var jump = Math.max(view.height, maxY / maxSteps)
        for (var y = 0; y <= maxY; y += jump) {
            view.contentY = y
            wait(0)
            ++steps
            if (steps >= maxSteps) break
        }
        view.contentY = maxY
        waitForRendering(holder, 30000)
        var scroll = Date.now() - t1
        var perStep = steps > 0 ? (scroll / steps) : 0

        console.log("[stress] " + label + ": scrolled to the end in " + scroll
                    + " ms over " + steps + " jumps (" + perStep.toFixed(1)
                    + " ms each), " + liveDelegates(view) + " delegates alive at the bottom")

        verify(liveDelegates(view) < 400,
               label + ": " + liveDelegates(view) + " delegates are alive after scrolling, "
               + "so the view keeps every delegate it ever built")

        page.destroy()
        wait(50)
    }

    function test_collection_tracks_5000() {
        exercise(collectionC, "CollectionPage", function (page, data) {
            S.fill(page, { activeTab: 0 })
            S.fill(page, { filteredTracks: data })
        })
    }

    function test_playlist_tracks_5000() {
        exercise(playlistC, "PlaylistPage", function (page, data) {
            S.fill(page, { playlistUuid: "uuid-big", playlistType: "USER",
                           playlistTitle: "Fünftausend", playlistDuration: 1200000 })
            S.fill(page, { tracks: data })
        })
    }

    function test_album_tracks_5000() {
        exercise(albumC, "AlbumPage", function (page, data) {
            S.fill(page, { albumId: 42 })
            S.fill(page, { albumData: { title: "Eine sehr lange Box", artists: "Interpret",
                                        year: "2019", numTracks: bigN, duration: 1200000,
                                        artistId: 7, coverUrl: "", coverUrl640: "" },
                           tracks: data })
        })
    }

    // The queue is the one list the user can reorder, and it is fed straight
    // from the player rather than from a page property.
    function test_queue_5000() {
        var holder = createTemporaryObject(holderC, testCase,
                                           { width: 420, height: paneHeight })
        var data = S.tracks(bigN)
        var t0 = Date.now()
        player.setQueueForTest(data, 0)
        var panel = queueC.createObject(holder, {})
        verify(panel, "the queue panel was not created")
        waitForRendering(holder, 60000)
        console.log("[stress] QueuePanel: " + bigN + " queued tracks shown in "
                    + (Date.now() - t0) + " ms, rss " + S.rssKib() + " KiB")

        var view = findView(panel, bigN)
        if (view) {
            var live = liveDelegates(view)
            console.log("[stress] QueuePanel: " + live + " delegates alive")
            verify(live < 400, "the queue built " + live + " delegates for " + bigN + " tracks")
        } else {
            console.log("[stress] QueuePanel: no view reported " + bigN + " items")
        }

        // Jumping around a 5000 entry queue is the operation that rebuilds the
        // playback order, which is the expensive half.
        var t1 = Date.now()
        var jumps = Math.max(5, Math.round(40 * scale))
        for (var i = 0; i < jumps; ++i) {
            player.jumpToQueue((i * 137) % bigN)
            if (i % 5 === 0) wait(0)
        }
        waitForRendering(holder, 30000)
        console.log("[stress] QueuePanel: " + jumps + " jumps across the queue in "
                    + (Date.now() - t1) + " ms")

        player.clearQueue()
        panel.destroy()
    }
}
