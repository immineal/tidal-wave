// X4: continuous resize while navigating between pages.
//
// The window is swept across the whole supported width range in small steps,
// twice over: once hammered (many width changes between two frames, which is
// what dragging a window edge on a loaded machine actually produces) and once
// frame synced. Pages are swapped underneath the sweep so a resize lands on a
// page that is still being built.
//
// What it can catch: geometry that goes negative or NaN, a page that stops
// following its parent's width, a child that escapes its parent, and anything
// that throws or loops in a binding (the harness greps stderr for those).

import QtQuick
import QtTest
import TidalWave

import "StressLib.js" as S

TestCase {
    id: testCase
    name: "StressResize"
    when: windowShown
    visible: true
    width: 1700
    height: 1000

    readonly property real scale: S.scale()
    // Below 640 the layout is explicitly not supported; 1680 is a wide monitor
    // with the sidebar open. The odd step avoids landing on round numbers only.
    readonly property int minW: 560
    readonly property int maxW: 1680
    readonly property int step: 7
    readonly property int paneHeight: 820
    readonly property int overflowSlack: 8

    Component { id: holderC;     Item { } }
    Component { id: homeC;       HomePage       { anchors.fill: parent } }
    Component { id: searchC;     SearchPage     { anchors.fill: parent } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: albumC;      AlbumPage      { anchors.fill: parent } }
    Component { id: artistC;     ArtistPage     { anchors.fill: parent } }
    Component { id: playlistC;   PlaylistPage   { anchors.fill: parent } }
    Component { id: mixC;        MixPage        { anchors.fill: parent } }
    Component { id: radioC;      RadioPage      { anchors.fill: parent } }

    property var pages: []
    property var missedProps: []

    function makePage(which, holder) {
        var comp = [homeC, searchC, collectionC, albumC,
                    artistC, playlistC, mixC, radioC][which]
        var page = comp.createObject(holder, {})
        verify(page, "page " + which + " was not created")
        var missed = []
        switch (which) {
        case 0: missed = S.fill(page, { mixes: S.mixes(8), recentAlbums: S.albums(12),
                                        playlists: S.playlists(10), artists: S.artists(10),
                                        recentlyPlayed: S.tracks(12) }); break
        case 1: missed = S.fill(page, { query: "ein langer suchbegriff", tracks: S.tracks(30),
                                        albums: S.albums(20), artists: S.artists(20),
                                        playlists: S.playlists(20) }); break
        case 2: S.fill(page, { activeTab: 0 })
                missed = S.fill(page, { filteredTracks: S.tracks(40), filteredAlbums: S.albums(30),
                                        filteredArtists: S.artists(30), filteredPlaylists: S.playlists(30),
                                        mixes: S.mixes(12) }); break
        case 3: S.fill(page, { albumId: 42 })
                missed = S.fill(page, { albumData: { title: "Ein langer Albumtitel (Deluxe Edition)",
                                                     artists: "Erster Interpret, Zweiter Interpret",
                                                     year: "2019", numTracks: 14, duration: 3842,
                                                     quality: "HI_RES_LOSSLESS", artistId: 7,
                                                     coverUrl: "", coverUrl640: "" },
                                        tracks: S.tracks(25) }); break
        case 4: S.fill(page, { artistId: 7 })
                missed = S.fill(page, { artistData: { name: "Ein langer Interpretenname",
                                                      bio: "Eine Biografie über mehrere Sätze, "
                                                         + "damit der Textblock wirklich umbricht.",
                                                      coverUrl750: "", similarArtists: S.artists(10) },
                                        topTracks: S.tracks(10), albums: S.albums(18) }); break
        case 5: S.fill(page, { playlistUuid: "uuid-stress" })
                missed = S.fill(page, { playlistType: "USER", playlistTitle: "Eine lange Wiedergabeliste",
                                        playlistDescription: "Eine Beschreibung über mehrere Zeilen.",
                                        playlistDuration: 7322, tracks: S.tracks(25) }); break
        case 6: S.fill(page, { mixId: "mix-stress" })
                missed = S.fill(page, { title: "Mein ganz persönlicher Mix",
                                        subtitle: "Mit vielen Interpreten", tracks: S.tracks(25) }); break
        case 7: S.fill(page, { trackId: 1234 })
                missed = S.fill(page, { radioTitle: "Radio zu einem langen Tracktitel",
                                        tracks: S.tracks(25) }); break
        }
        for (var i = 0; i < missed.length; ++i)
            missedProps.push(which + "." + missed[i])
        return page
    }

    // `skip` is an item to ignore anywhere in the subtree. It carries the
    // enclosing view's highlightItem down: ListView creates a default, empty
    // highlight item and animates its geometry towards the current delegate,
    // so for about half a second after a resize it is still the old width.
    // It draws nothing, the list clips it, and the user never sees it, but a
    // naive bounds check calls it an overflow every time. Found the hard way:
    // it was the only thing this test reported on PlaylistPage.
    function audit(item, label, skip) {
        if (item.contentWidth !== undefined && item.contentX !== undefined
            && item.contentWidth > item.width + 1)
            return                                    // a horizontal scroller
        if (item.highlightItem !== undefined && item.highlightItem)
            skip = item.highlightItem
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (!c || c === skip) continue
            if (!c.visible || c.width === undefined || c.width <= 0) continue
            verify(!isNaN(c.x) && !isNaN(c.width),
                   label + ": a child has NaN geometry (x=" + c.x + " w=" + c.width + ")")
            verify(c.width >= 0 && c.height >= 0,
                   label + ": a child went negative (" + c.width + "x" + c.height + ")")
            verify(c.x + c.width <= item.width + overflowSlack,
                   label + ": a child ends at " + (c.x + c.width).toFixed(1)
                   + " inside a parent " + item.width.toFixed(1) + " wide")
            audit(c, label, skip)
        }
    }

    function test_resize_while_navigating() {
        var holder = createTemporaryObject(holderC, testCase,
                                           { width: maxW, height: paneHeight })
        verify(holder, "the holder was not created")

        var sweeps = Math.max(1, Math.round(6 * scale))
        var which = 0
        var page = makePage(which, holder)
        waitForRendering(holder, 5000)

        var resizes = 0
        var swaps = 0
        var t0 = Date.now()

        for (var sweep = 0; sweep < sweeps; ++sweep) {
            var up = (sweep % 2 === 0)
            for (var w = up ? minW : maxW;
                 up ? w <= maxW : w >= minW;
                 w += up ? step : -step) {

                holder.width = w
                ++resizes

                // Every 23rd step the page under the sweep is replaced, so a
                // resize arrives at a page mid-construction.
                if (resizes % 23 === 0) {
                    page.destroy()
                    which = (which + 1) % 8
                    page = makePage(which, holder)
                    ++swaps
                }

                // First half of each sweep: hammer, no frame in between.
                // Second half: one frame per step, the honest redraw path.
                if (!(sweep % 2 === 0 && w < (minW + maxW) / 2)) {
                    if (resizes % 5 === 0) wait(0)
                }

                if (resizes % 97 === 0) {
                    waitForRendering(holder, 5000)
                    compare(page.width, holder.width,
                            "the page stopped following the pane width at " + w)
                    audit(page, "page " + which + " @" + w)
                }
            }
        }

        waitForRendering(holder, 5000)
        page.destroy()
        wait(50)

        console.log("[stress] resize: " + resizes + " resizes, " + swaps
                    + " page swaps, " + (Date.now() - t0) + " ms, rss "
                    + S.rssKib() + " KiB")
        if (missedProps.length > 0)
            console.log("[stress] resize: properties that no longer exist: "
                        + missedProps.join(", "))
    }

    // The narrowest supported window, resized one pixel at a time. Rounding
    // bugs that only bite at the edge of the range show up here and nowhere
    // else, because every other sweep steps over them.
    function test_resize_one_pixel_at_the_minimum() {
        var holder = createTemporaryObject(holderC, testCase,
                                           { width: 640, height: paneHeight })
        var page = makePage(2, holder)
        waitForRendering(holder, 5000)

        for (var w = 640; w >= 560; --w) {
            holder.width = w
            wait(0)
        }
        waitForRendering(holder, 5000)
        audit(page, "CollectionPage @560")
        compare(page.width, 560, "the page stopped following the pane width")
        page.destroy()
    }
}
