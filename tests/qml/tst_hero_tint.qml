// The detail hero takes its colour from its cover, as Now Playing does in
// fullscreen. The colour and its clamp are tested in tests/tst_covercolor.cpp;
// this file covers which cover the hero asks for and what it paints meanwhile.

import QtQuick
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "HeroTint"
    when: windowShown
    width: 900
    height: 600
    visible: true

    Component { id: heroC; DetailHero { width: 700 } }

    function tintOf(hero) {
        var t = findChild(hero, "heroCoverTint")
        verify(t, "the hero has no CoverTint called heroCoverTint")
        return t
    }

    function test_the_tint_follows_the_art_tile() {
        var hero = createTemporaryObject(heroC, testCase, { artSource: "c/album" })
        compare(tintOf(hero).coverId, "c/album")
        verify(tintOf(hero).active, "a hero with a cover does not ask for its colour")
    }

    // A playlist with no cover of its own: the first of the mosaic's covers.
    function test_a_mosaic_takes_its_first_cover() {
        var hero = createTemporaryObject(heroC, testCase, {
            artCovers: ["c/a", "c/a", "c/b", "c/c", "c/d"] })
        compare(tintOf(hero).coverId, "c/a")
    }

    // An artist has no tile; the photo behind the hero is its art.
    function test_an_artist_takes_the_photo() {
        var hero = createTemporaryObject(heroC, testCase, {
            showArt: false, backdropSource: "c/photo" })
        compare(tintOf(hero).coverId, "c/photo")
    }

    // Nothing to take a colour from: off, and the accent wash paints.
    function test_no_art_paints_the_accent() {
        var hero = createTemporaryObject(heroC, testCase, { artIcon: "waves" })
        compare(tintOf(hero).coverId, "")
        compare(tintOf(hero).active, false)
        compare(hero.tintTop.toString(), Theme.accentTint.toString())
    }

    // The test image provider hands back a transparent square, so the cover
    // has no colour and the accent stays until one is known.
    function test_an_unknown_cover_paints_the_accent() {
        var hero = createTemporaryObject(heroC, testCase, { artSource: "c/unknown" })
        compare(tintOf(hero).hasColor, false)
        compare(hero.tintTop.toString(), Theme.accentTint.toString())
    }

    // The same band as Now Playing: every text token is tested against both
    // of these grounds in tests/tst_theme.cpp.
    function test_the_band_is_the_live_palette() {
        var hero = createTemporaryObject(heroC, testCase, { artSource: "c/album" })
        compare(tintOf(hero).bg.toString(), Theme.bg.toString())
        compare(tintOf(hero).limit.toString(), Theme.surfaceHigh.toString())
    }
}
