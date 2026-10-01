// X4: rapid page flipping, watching RSS for a leak.
//
// Main.qml keeps one Loader per top-level destination and swaps the source,
// so a real session creates and destroys pages over and over. This builds and
// tears down every page several hundred times and samples VmRSS as it goes.
//
// A leak verdict from resident set size alone is never exact: the JS heap
// grows in steps, glyph and image caches fill once and stay, and the allocator
// does not hand pages back. So the test warms up first, takes the baseline
// after the warm-up, and only fails on growth that is large in both relative
// and absolute terms. The full series is printed either way, which is the part
// worth reading.

import QtQuick
import QtTest
import TidalWave

import "StressLib.js" as S

TestCase {
    id: testCase
    name: "StressFlip"
    when: windowShown
    visible: true
    width: 1280
    height: 900

    readonly property real scale: S.scale()
    readonly property int paneWidth: 1100
    readonly property int paneHeight: 780

    Component { id: holderC;     Item { } }
    Component { id: homeC;       HomePage       { anchors.fill: parent } }
    Component { id: searchC;     SearchPage     { anchors.fill: parent } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: albumC;      AlbumPage      { anchors.fill: parent } }
    Component { id: artistC;     ArtistPage     { anchors.fill: parent } }
    Component { id: playlistC;   PlaylistPage   { anchors.fill: parent } }
    Component { id: mixC;        MixPage        { anchors.fill: parent } }
    Component { id: radioC;      RadioPage      { anchors.fill: parent } }
    Component { id: playerBarC;  PlayerBar      { } }
    // NowPlayingPage needs a window that carries the sleep timer surface; see
    // NowPlayingHost.qml. A Window cannot be parented to an Item, so it is
    // cycled on its own below rather than in the generic page list.
    Component { id: npHostC;     NowPlayingHost { } }
    Component { id: emptyHostC;  EmptyHost      { } }

    function comps() {
        return [homeC, searchC, collectionC, albumC, artistC,
                playlistC, mixC, radioC]
    }

    function furnish(page, which) {
        switch (which) {
        case 0: S.fill(page, { mixes: S.mixes(6), recentAlbums: S.albums(10),
                               playlists: S.playlists(8), artists: S.artists(8),
                               recentlyPlayed: S.tracks(10) }); break
        case 1: S.fill(page, { query: "suche", tracks: S.tracks(20), albums: S.albums(12),
                               artists: S.artists(12), playlists: S.playlists(12) }); break
        case 2: S.fill(page, { activeTab: 0 })
                S.fill(page, { filteredTracks: S.tracks(20), filteredAlbums: S.albums(12),
                               filteredArtists: S.artists(12), filteredPlaylists: S.playlists(12),
                               mixes: S.mixes(8) }); break
        case 3: S.fill(page, { albumId: 42 })
                S.fill(page, { albumData: { title: "Album", artists: "Interpret", year: "2019",
                                            numTracks: 12, duration: 2400, artistId: 7,
                                            coverUrl: "", coverUrl640: "" },
                               tracks: S.tracks(14) }); break
        case 4: S.fill(page, { artistId: 7 })
                S.fill(page, { artistData: { name: "Interpret", bio: "Eine Biografie.",
                                             coverUrl750: "", similarArtists: S.artists(8) },
                               topTracks: S.tracks(8), albums: S.albums(12) }); break
        case 5: S.fill(page, { playlistUuid: "uuid-flip" })
                S.fill(page, { playlistType: "USER", playlistTitle: "Liste",
                               playlistDuration: 3600, tracks: S.tracks(14) }); break
        case 6: S.fill(page, { mixId: "mix-flip" })
                S.fill(page, { title: "Mix", subtitle: "Untertitel", tracks: S.tracks(14) }); break
        case 7: S.fill(page, { trackId: 99 })
                S.fill(page, { radioTitle: "Radio", tracks: S.tracks(14) }); break
        }
    }

    function test_flip_pages_without_leaking() {
        var holder = createTemporaryObject(holderC, testCase,
                                           { width: paneWidth, height: paneHeight })
        verify(holder, "the holder was not created")

        var list = comps()
        var cycles = Math.max(4, Math.round(40 * scale))   // x9 pages per cycle
        var warmup = Math.max(2, Math.round(cycles / 5))

        // The player stub feeds NowPlayingPage and PlayerBar.
        player.setCurrentTrackForTest(S.track(1))
        player.setQueueForTest(S.tracks(30), 0)
        player.setDurationForTest(240000)

        var series = []
        var baseline = -1
        var t0 = Date.now()
        var built = 0

        for (var c = 0; c < cycles; ++c) {
            for (var i = 0; i < list.length; ++i) {
                var page = list[i].createObject(holder, {})
                verify(page, "page " + i + " failed to build on cycle " + c)
                furnish(page, i)
                ++built
                // One frame every third page: enough that the scene graph
                // really builds nodes, not so much that the run takes an hour.
                if (built % 3 === 0) wait(0)
                page.destroy()
            }
            // destroy() is deferred; give the event loop a turn to run it, and
            // ask the JS heap to collect so the sample means something.
            wait(1)
            gc()

            var rss = S.rssKib()
            series.push(rss)
            if (c === warmup) baseline = rss
        }

        waitForRendering(holder, 5000)
        wait(100)
        gc()
        wait(100)
        var finalRss = S.rssKib()

        console.log("[stress] flip: " + built + " pages built and destroyed in "
                    + (Date.now() - t0) + " ms")
        console.log("[stress] flip: rss series (KiB, one per cycle): " + series.join(" "))

        if (baseline <= 0 || finalRss <= 0) {
            console.log("[stress] flip: /proc is unreadable, so no leak verdict")
            return
        }

        var growth = finalRss - baseline
        var pct = (100.0 * growth / baseline)
        console.log("[stress] flip: baseline after warm-up " + baseline
                    + " KiB, final " + finalRss + " KiB, growth " + growth
                    + " KiB (" + pct.toFixed(1) + "%)")

        // Both bars have to be cleared before this is called a leak: a cache
        // that fills once is neither large nor unbounded, and a few MiB of
        // allocator slack on a 300 MiB process is not a finding.
        verify(growth < 120 * 1024 || pct < 40,
               "resident set grew " + growth + " KiB (" + pct.toFixed(1)
               + "%) over " + built + " page builds, which looks like a leak")
    }

    // NowPlayingPage is a whole window's worth of bindings onto the player,
    // and the one page a user leaves open for hours. Fewer rounds than the
    // others because each one builds and tears down a real window.
    // Cycle `rounds` windows out of `comp` and return the resident set growth
    // in KiB, or -1 where procfs is unreadable.
    function cycleWindows(comp, rounds, each) {
        wait(200); gc(); wait(200)
        var before = S.rssKib()
        for (var i = 0; i < rounds; ++i) {
            var host = comp.createObject(null, {})
            verify(host, "a window failed to build on round " + i)
            if (each) each(host, i)
            if (i % 4 === 0) wait(0)
            host.destroy()
        }
        wait(200); gc(); wait(200)
        var after = S.rssKib()
        return (before > 0 && after > 0) ? (after - before) : -1
    }

    function test_flip_now_playing() {
        var rounds = Math.max(5, Math.round(40 * scale))
        player.setCurrentTrackForTest(S.track(1))
        player.setQueueForTest(S.tracks(30), 0)
        player.setDurationForTest(240000)

        // Warm the platform up before measuring anything: the first window of
        // a run pulls in the whole render path and costs far more than the
        // hundredth, and that one-off would otherwise land on whichever of the
        // two measurements happens to run first.
        cycleWindows(emptyHostC, Math.max(2, Math.round(rounds / 5)), null)

        // The control. Creating and destroying a top level window costs memory
        // the page knows nothing about: on X11 through llvmpipe it was about
        // 4.8 MiB per window, enough to read as a leak in the page and not be
        // one. Only the difference is charged to NowPlayingPage.
        var baseline = cycleWindows(emptyHostC, rounds, null)

        var withPage = cycleWindows(npHostC, rounds, function (host, i) {
            verify(host.page, "NowPlayingHost has no page on round " + i)
            player.setCurrentTrackForTest(S.track(i))
            player.setPositionForTest((i * 1013) % 200000)
        })

        console.log("[stress] flip: " + rounds + " windows, empty " + baseline
                    + " KiB vs with NowPlayingPage " + withPage + " KiB")

        if (baseline < 0 || withPage < 0) {
            console.log("[stress] flip: /proc is unreadable, so no NowPlayingPage verdict")
            return
        }
        var attributable = withPage - baseline
        console.log("[stress] flip: NowPlayingPage accounts for " + attributable
                    + " KiB over " + rounds + " rebuilds ("
                    + (attributable / rounds).toFixed(0) + " KiB each)")
        verify(attributable < 60 * 1024,
               "NowPlayingPage leaked " + attributable + " KiB over " + rounds
               + " rebuilds, on top of " + baseline + " KiB of plain window cost")
    }

    // The queue panel and the player bar live for the whole session and are
    // rebuilt by the same signals a flip produces, so they get their own pass.
    function test_flip_persistent_chrome() {
        var holder = createTemporaryObject(holderC, testCase,
                                           { width: paneWidth, height: paneHeight })
        var rounds = Math.max(10, Math.round(120 * scale))
        var before = S.rssKib()
        for (var i = 0; i < rounds; ++i) {
            var host = playerBarC.createObject(holder, { width: paneWidth })
            verify(host, "the player bar host failed to build on round " + i)
            player.setCurrentTrackForTest(S.track(i))
            player.setPlayingForTest(i % 2 === 0)
            if (i % 4 === 0) wait(0)
            host.destroy()
        }
        wait(100)
        gc()
        wait(100)
        var after = S.rssKib()
        console.log("[stress] flip: player bar x" + rounds + ", rss " + before
                    + " -> " + after + " KiB")
        if (before > 0 && after > 0)
            verify(after - before < 120 * 1024,
                   "the player bar leaked " + (after - before) + " KiB over " + rounds + " rebuilds")
    }
}
