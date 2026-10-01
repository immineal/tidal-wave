// The quality badge, in the player bar and in Now Playing.
//
// Reported during QA: "the audio quality label seems to be empty in the visual
// tests". The app was innocent. `StubPlayer::qualityLabel()` returned {} for
// every input, and because both badges are gated on
// `player.audioQuality.length > 0` rather than on the label, a quality that was
// set made the badge *visible and empty* - a coloured box with no word in it.
// Every visual shot and every assertion that had ever looked at that badge was
// looking at nothing, and passing.
//
// So every test here is about the badge's text. A test that only checked
// `visible` is precisely the test that let this through.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "QualityBadge"
    when: windowShown
    width: 1200
    height: 800
    // TestCase declares visible: false, which would make every child report
    // visible == false and the assertions below vacuous.
    visible: true

    // Tier code to the word the user should read. Written out rather than taken
    // from player.qualityLabel(), because deriving the expectation from the
    // thing under test is how an empty stub passed in the first place.
    readonly property var tiers: [
        { code: "HI_RES_LOSSLESS", label: "Max" },
        { code: "LOSSLESS",        label: "Lossless" },
        { code: "HIGH",            label: "High" },
        { code: "LOW",             label: "Low" }
    ]

    Component { id: holderC; Item { } }
    Component { id: barC;    PlayerBar      { anchors.fill: parent } }
    Component { id: npC;     NowPlayingPage { anchors.fill: parent } }

    function findByName(root, name) {
        if (!root) return null
        if (root.objectName === name) return root
        var kids = root.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function settle(item) {
        wait(1)
        waitForRendering(item, 2000)
        wait(1)
    }

    // The player bar's badge also gates on `hasTrack`, so a quality with no
    // track showing is not the case under test here - that is what
    // test_no_quality_means_no_badge covers from the other side.
    function build(which, quality) {
        var host = createTemporaryObject(holderC, testCase,
                                        { width: testCase.width, height: testCase.height })
        verify(host, "the holder was not created")
        player.setCurrentTrackForTest({ id: 1, title: "Ein Titel",
                                        artist: "Ein Interpret",
                                        album: "Ein Album", duration: 215 })
        player.setAudioQualityForTest(quality)
        var page = (which === "bar" ? barC : npC).createObject(host)
        verify(page, which + " was not created")
        settle(host)
        return page
    }

    function badgeText(page) { return findByName(page, "qualityBadgeText") }
    function badge(page)     { return findByName(page, "qualityBadge") }

    // ── the four tiers, in both places ──────────────────────────────────────

    function test_the_player_bar_badge_reads_the_tier_data() { return testCase.tiers }
    function test_the_player_bar_badge_reads_the_tier(row) {
        var page = build("bar", row.code)
        var t = badgeText(page)
        verify(t, "the player bar has no quality badge text item")
        verify(badge(page).visible, "the badge was not visible for " + row.code)
        compare(t.text, row.label, "the player bar badge read the wrong tier")
        verify(t.width > 0, "the badge text had no width, so nothing is drawn")
    }

    function test_the_now_playing_badge_reads_the_tier_data() { return testCase.tiers }
    function test_the_now_playing_badge_reads_the_tier(row) {
        var page = build("np", row.code)
        var t = badgeText(page)
        verify(t, "Now Playing has no quality badge text item")
        verify(badge(page).visible, "the badge was not visible for " + row.code)
        compare(t.text, row.label, "Now Playing's badge read the wrong tier")
        verify(t.width > 0, "the badge text had no width, so nothing is drawn")
    }

    // ── the two cases that are not a tier ───────────────────────────────────

    // Nothing has streamed yet. The badge must be *gone*, not empty: an empty
    // coloured box is the bug this file exists for, and it is what the user saw.
    function test_no_quality_means_no_badge() {
        var page = build("bar", "")
        var b = badge(page)
        if (b) verify(!b.visible, "an empty badge was drawn with no quality set")
    }

    // An unknown code is echoed rather than swallowed, which is what the real
    // Player does: a tier Tidal adds later should show as itself rather than
    // leaving a blank badge behind.
    function test_an_unknown_tier_is_echoed() {
        var page = build("bar", "SOMETHING_NEW")
        compare(badgeText(page).text, "SOMETHING_NEW",
                "an unrecognised tier was swallowed instead of being shown")
    }

    function cleanup() {
        player.setAudioQualityForTest("HI_RES_LOSSLESS")
    }
}
