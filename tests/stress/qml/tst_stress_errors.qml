// X4: simulated API errors and timeouts.
//
// There is no network in this binary: the bridge, the player, the cast manager
// and the downloader are the stubs from tests/TestStubs.h. So "an API error"
// here means the two things the UI actually has to survive when the network
// misbehaves:
//
//   1. the error and session signals arriving in a storm, out of order, and
//      while pages are being built and destroyed, and
//   2. the payload being wrong: fields missing, nulls where a string was
//      expected, numbers as strings, negative durations, absurd lengths. That
//      is what a timed-out or truncated response leaves behind, and it is the
//      case that reaches a QML binding rather than an error handler.
//
// A "timeout" is modelled as its only observable consequence for the UI: the
// loading flag goes up, no data ever arrives, and the error signal lands much
// later or never. Pages have to stay interactive through it.

import QtQuick
import QtTest
import TidalWave

import "StressLib.js" as S

TestCase {
    id: testCase
    name: "StressErrors"
    when: windowShown
    visible: true
    width: 1280
    height: 900

    readonly property real scale: S.scale()

    Component { id: holderC;     Item { } }
    Component { id: homeC;       HomePage       { anchors.fill: parent } }
    Component { id: searchC;     SearchPage     { anchors.fill: parent } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: albumC;      AlbumPage      { anchors.fill: parent } }
    Component { id: artistC;     ArtistPage     { anchors.fill: parent } }
    Component { id: playlistC;   PlaylistPage   { anchors.fill: parent } }
    Component { id: trackRowC;   TrackRow       { } }
    // A window, not a page: NowPlayingPage reads the sleep timer off
    // Window.window. See NowPlayingHost.qml.
    Component { id: npHostC;     NowPlayingHost { } }

    function allPages() {
        return [homeC, searchC, collectionC, albumC, artistC, playlistC]
    }

    // Payloads a flaky or truncated response produces. Each one is a track map
    // with something the QML has no reason to expect.
    function brokenTracks() {
        return [
            {},                                                   // nothing at all
            { id: 0 },                                            // the "no track" sentinel
            { id: -1, title: null, artists: null, albumTitle: null },
            { id: "42", duration: "nicht eine Zahl", popularity: "hoch" },
            { id: 43, title: undefined, durationStr: undefined },
            { id: 44, duration: -1, trackNumber: -7, popularity: -5 },
            { id: 45, duration: 1e12, popularity: 10000 },
            { id: 46, title: "ä".repeat(4000), artists: "x".repeat(4000) },
            { id: 47, title: "<b>nicht</b> &amp; roh", artists: "a\nb\tc\u0000d" },
            { id: 48, artists: [], albumTitle: {} },               // wrong types
            { id: 49, coverUrl: "not://a.real.scheme/x", coverUrl80: 17 }
        ]
    }

    function test_error_storm_while_pages_churn() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 780 })
        var list = allPages()
        var rounds = Math.max(5, Math.round(30 * scale))
        var fired = 0

        for (var r = 0; r < rounds; ++r) {
            var page = list[r % list.length].createObject(holder, {})
            verify(page, "a page failed to build during the error storm, round " + r)

            // Everything that can go wrong at once, several times, while the
            // page is still settling.
            for (var k = 0; k < 7; ++k) {
                player.emitErrorForTest("Zeitüberschreitung bei der Anfrage")
                cast.emitErrorForTest("Das Gerät hat die Verbindung abgelehnt")
                downloader.emitDownloadErrorForTest(100000 + k, "Der Download ist fehlgeschlagen")
                auth.emitLoginFailedForTest("401 Unauthorized")
                fired += 4
            }
            auth.emitSessionExpiredForTest()
            auth.setStateForTest(0)          // LoggedOut
            auth.setStateForTest(2)          // LoggedIn again, as a refresh does
            if (r % 3 === 0) wait(0)
            page.destroy()
        }

        wait(100)
        console.log("[stress] errors: " + fired + " error signals across " + rounds
                    + " page builds, rss " + S.rssKib() + " KiB")
    }

    // The loading flag up and nothing ever arriving. The page must still lay
    // out, still answer property reads, and still tear down cleanly.
    function test_pages_survive_a_request_that_never_returns() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 780 })
        var list = allPages()
        for (var i = 0; i < list.length; ++i) {
            var page = list[i].createObject(holder, {})
            verify(page, "page " + i + " was not created")
            S.fill(page, { loading: true })
            waitForRendering(holder, 10000)

            verify(page.width > 0 && page.height > 0,
                   "page " + i + " collapsed while loading")

            // The width changes under the spinner, as it would if the user
            // resized the window while waiting.
            for (var w = 1100; w >= 640; w -= 20) { holder.width = w; wait(0) }
            holder.width = 1100
            waitForRendering(holder, 10000)

            // The error finally lands, long after the request went out.
            player.emitErrorForTest("Die Anfrage hat zu lange gedauert")
            S.fill(page, { loading: false })
            waitForRendering(holder, 10000)
            page.destroy()
            wait(1)
        }
        console.log("[stress] errors: every page survived a request that never returned")
    }

    // Malformed payloads straight into the lists. The pages must not throw;
    // the harness greps stderr for TypeError, so a silent pass here with a
    // dirty log is still a failure at the script level.
    function test_malformed_payloads() {
        var holder = createTemporaryObject(holderC, testCase, { width: 1100, height: 780 })
        var bad = brokenTracks()

        // Mixed in with good data, which is what a partially parsed page is.
        var mixed = []
        for (var i = 0; i < 60; ++i)
            mixed.push(i % 3 === 0 ? bad[i % bad.length] : S.track(i))

        var page = collectionC.createObject(holder, {})
        S.fill(page, { activeTab: 0 })
        S.fill(page, { filteredTracks: mixed })
        waitForRendering(holder, 20000)
        verify(page.width > 0, "CollectionPage collapsed on a malformed payload")
        page.destroy()

        var pl = playlistC.createObject(holder, {})
        S.fill(pl, { playlistUuid: "uuid-bad", playlistType: "USER" })
        S.fill(pl, { tracks: mixed })
        waitForRendering(holder, 20000)
        pl.destroy()

        // And one row per broken payload on its own, so a crash names the shape.
        for (var k = 0; k < bad.length; ++k) {
            var row = trackRowC.createObject(holder, { width: 900 })
            verify(row, "TrackRow " + k + " was not created")
            // trackData raw, the string columns coerced: a page builds those
            // from the payload, and a QML binding that yields undefined warns
            // where a direct assignment would throw and end the test here.
            S.fill(row, { trackData: bad[k], trackNum: k + 1,
                          title: S.str(bad[k].title), artists: S.str(bad[k].artists),
                          albumTitle: S.str(bad[k].albumTitle),
                          durationStr: S.str(bad[k].durationStr) })
            wait(0)
            row.destroy()
        }
        waitForRendering(holder, 10000)
        console.log("[stress] errors: " + bad.length + " malformed payload shapes rendered")
    }

    // A track whose fields change under the player bar and the now playing
    // page as fast as a flapping connection can retry.
    function test_player_state_flapping() {
        var host = npHostC.createObject(null, {})
        verify(host, "NowPlayingHost was not created")
        var np = host.page
        verify(np, "NowPlayingHost has no page")

        var flaps = Math.max(20, Math.round(300 * scale))
        var bad = brokenTracks()
        for (var i = 0; i < flaps; ++i) {
            player.setLoadingForTest(i % 2 === 0)
            player.setCurrentTrackForTest(i % 5 === 0 ? bad[i % bad.length] : S.track(i))
            player.setPlayingForTest(i % 3 === 0)
            player.setDurationForTest(i % 7 === 0 ? 0 : 200000 + i)
            player.setPositionForTest((i * 997) % 200000)
            if (i % 10 === 0) player.emitErrorForTest("Der Stream ist abgebrochen")
            if (i % 11 === 0) wait(0)
        }
        waitForRendering(np, 20000)
        verify(np.width > 0, "NowPlayingPage collapsed while the player flapped")
        console.log("[stress] errors: " + flaps + " player state flips survived")
        host.destroy()
    }
}
