// X4: theme switching under load, and language switching under load.
//
// Both are whole-tree events. A theme change swaps ThemePalette.current, and
// every colour in the app is a binding onto it; a language change calls
// QQmlEngine::retranslate(), which re-evaluates every qsTr() binding in the
// live tree. Doing either once on an empty window proves nothing. These run
// them hundreds of times with every page mounted and a long list in view.
//
// Needs the real Prefs and I18n, which tests/stress/tst_stress_main.cpp
// installs. Run through tests/tst_qml instead and both tests skip rather than
// fail, because there is no `prefs` there.

import QtQuick
import QtTest
import TidalWave

import "StressLib.js" as S

TestCase {
    id: testCase
    name: "StressThemeI18n"
    when: windowShown
    visible: true
    width: 1300
    height: 950

    readonly property real scale: S.scale()
    readonly property bool havePrefs: typeof prefs !== "undefined" && prefs !== null
    readonly property bool haveI18n: typeof i18n !== "undefined" && i18n !== null

    Component { id: holderC;     Item { } }
    Component { id: homeC;       HomePage       { anchors.fill: parent } }
    Component { id: collectionC; CollectionPage { anchors.fill: parent } }
    Component { id: albumC;      AlbumPage      { anchors.fill: parent } }
    Component { id: artistC;     ArtistPage     { anchors.fill: parent } }
    Component { id: playerBarC;  PlayerBar      { } }
    Component { id: npHostC;     NowPlayingHost { } }

    property var loaded: []

    // Everything the user can have on screen at once: a page, the player bar,
    // and a list long enough that a repaint is real work.
    function mountEverything(holder) {
        loaded = []
        var page = collectionC.createObject(holder, {})
        S.fill(page, { activeTab: 0 })
        S.fill(page, { filteredTracks: S.tracks(400), filteredAlbums: S.albums(60),
                       filteredArtists: S.artists(60), filteredPlaylists: S.playlists(60),
                       mixes: S.mixes(20) })
        loaded.push(page)

        var home = homeC.createObject(holder, {})
        S.fill(home, { mixes: S.mixes(10), recentAlbums: S.albums(20),
                       playlists: S.playlists(16), artists: S.artists(16),
                       recentlyPlayed: S.tracks(20) })
        home.visible = false          // mounted but not drawn, as a Loader keeps it
        loaded.push(home)

        // A real window, because NowPlayingPage reads the sleep timer off
        // Window.window. It is part of the load either way: its bindings
        // re-evaluate on every theme and language change too.
        var npHost = npHostC.createObject(null, {})
        loaded.push(npHost)

        var bar = playerBarC.createObject(holder, { width: holder.width })
        loaded.push(bar)

        player.setCurrentTrackForTest(S.track(3))
        player.setQueueForTest(S.tracks(60), 3)
        player.setDurationForTest(240000)
        return page
    }

    function unmountEverything() {
        for (var i = 0; i < loaded.length; ++i)
            if (loaded[i]) loaded[i].destroy()
        loaded = []
    }

    function isColour(c) {
        // A QColor that failed to resolve comes back fully transparent black,
        // which is never a token in any of the six palettes.
        return c !== undefined && c !== null
            && !(c.a === 0 && c.r === 0 && c.g === 0 && c.b === 0)
    }

    function test_theme_switching_under_load() {
        if (!havePrefs) { skip("no `prefs` context property; run through tests/stress/run.sh"); return }

        var holder = createTemporaryObject(holderC, testCase, { width: 1200, height: 820 })
        mountEverything(holder)
        waitForRendering(holder, 60000)

        var names = []
        var available = ThemePalette.available()
        for (var i = 0; i < available.length; ++i) names.push(available[i].name)
        verify(names.length >= 2, "ThemePalette offers only " + names.length + " themes")
        console.log("[stress] theme: cycling " + names.join(", "))

        var original = prefs.theme
        var rounds = Math.max(6, Math.round(120 * scale))
        var slowest = 0
        var slowestName = ""
        var total = 0
        var seen = {}

        for (var r = 0; r < rounds; ++r) {
            var name = names[r % names.length]
            var t0 = Date.now()
            prefs.theme = name
            // Force the bindings to settle in this iteration rather than
            // coalescing all of them into one repaint at the end.
            waitForRendering(holder, 20000)
            var dt = Date.now() - t0
            total += dt
            if (dt > slowest) { slowest = dt; slowestName = name }

            compare(prefs.theme, name, "the theme did not stick on round " + r)
            verify(isColour(Theme.bg), name + ": Theme.bg did not resolve")
            verify(isColour(Theme.accent), name + ": Theme.accent did not resolve")
            verify(isColour(Theme.textPrimary), name + ": Theme.textPrimary did not resolve")
            seen["" + Theme.bg] = true
        }

        prefs.theme = original
        waitForRendering(holder, 20000)
        unmountEverything()

        var distinct = Object.keys(seen).length
        console.log("[stress] theme: " + rounds + " switches, " + total + " ms total, worst "
                    + slowest + " ms (" + slowestName + "), " + distinct
                    + " distinct backgrounds seen, rss " + S.rssKib() + " KiB")
        verify(distinct >= 2,
               "all " + names.length + " themes painted the same background (" + Theme.bg
               + "), so Prefs::theme is not reaching the QML tree. The usual cause is the"
               + " ThemePalette singleton QML built for itself not being the one"
               + " Application wired Prefs into.")
        // A theme switch is a user-visible action; a third of a second is the
        // point where it stops feeling like a switch and starts feeling like a
        // reload.
        verify(slowest < 1500,
               "the slowest theme switch took " + slowest + " ms (" + slowestName + ")")
    }

    function test_language_switching_under_load() {
        if (!havePrefs || !haveI18n) {
            skip("no `prefs`/`i18n` context property; run through tests/stress/run.sh")
            return
        }

        var holder = createTemporaryObject(holderC, testCase, { width: 1200, height: 820 })
        mountEverything(holder)
        waitForRendering(holder, 60000)

        var original = prefs.language
        var codes = ["de", "en", "system"]
        var rounds = Math.max(6, Math.round(90 * scale))
        var slowest = 0
        var total = 0
        var effective = {}

        for (var r = 0; r < rounds; ++r) {
            var code = codes[r % codes.length]
            var t0 = Date.now()
            prefs.language = code
            waitForRendering(holder, 20000)
            var dt = Date.now() - t0
            total += dt
            if (dt > slowest) slowest = dt

            compare(prefs.language, code, "the language did not stick on round " + r)
            effective[i18n.effectiveLanguage] = true
            verify(i18n.effectiveLanguage === "en" || i18n.effectiveLanguage === "de",
                   "effectiveLanguage resolved to \"" + i18n.effectiveLanguage + "\"")
        }

        prefs.language = original
        waitForRendering(holder, 20000)
        unmountEverything()

        var langs = Object.keys(effective)
        console.log("[stress] i18n: " + rounds + " switches, " + total + " ms total, worst "
                    + slowest + " ms, effective languages seen: " + langs.join(", ")
                    + ", rss " + S.rssKib() + " KiB")
        verify(langs.length >= 2,
               "only " + langs.join(", ") + " was ever effective, so the catalogue never swapped");
        verify(slowest < 2500, "the slowest language switch took " + slowest + " ms")
    }

    // Both at once, with pages being built and destroyed underneath. This is
    // the combination that finds a binding reading a palette token out of a
    // tree that retranslate() is already rebuilding.
    function test_theme_and_language_together_while_pages_churn() {
        if (!havePrefs || !haveI18n) {
            skip("no `prefs`/`i18n` context property; run through tests/stress/run.sh")
            return
        }

        var holder = createTemporaryObject(holderC, testCase, { width: 1200, height: 820 })
        var names = []
        var available = ThemePalette.available()
        for (var i = 0; i < available.length; ++i) names.push(available[i].name)
        var codes = ["de", "en"]
        var pages = [homeC, collectionC, albumC, artistC]

        var originalTheme = prefs.theme
        var originalLang = prefs.language
        var rounds = Math.max(10, Math.round(80 * scale))
        var before = S.rssKib()

        for (var r = 0; r < rounds; ++r) {
            var page = pages[r % pages.length].createObject(holder, {})
            verify(page, "a page failed to build on round " + r)
            if (r % pages.length === 1)
                S.fill(page, { activeTab: r % 5, filteredTracks: S.tracks(80) })

            // No wait between the two: the second lands while the first is
            // still being applied.
            prefs.theme = names[r % names.length]
            prefs.language = codes[r % codes.length]
            if (r % 3 === 0) wait(0)
            page.destroy()
        }

        prefs.theme = originalTheme
        prefs.language = originalLang
        waitForRendering(holder, 30000)
        wait(100)
        gc()
        wait(100)
        var after = S.rssKib()

        console.log("[stress] theme+i18n: " + rounds
                    + " interleaved switches over churning pages, rss " + before
                    + " -> " + after + " KiB")
        verify(isColour(Theme.bg), "Theme.bg stopped resolving after the interleaved run")
        if (before > 0 && after > 0)
            verify(after - before < 150 * 1024,
                   "interleaved theme and language switching leaked " + (after - before) + " KiB")
    }
}
