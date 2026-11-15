// The lower half of the artist page and its name: the bio as Tidal sends it
// (<br/> between paragraphs, [wimpLink ...] references), clamped to a few
// lines with a toggle, the Related Artists row, and the name over the photo
// without an outline. Every id, name and sentence below is invented.

import QtQuick
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ArtistAbout"
    when: windowShown
    width: 1700
    height: 900
    // TestCase declares visible: false, and an invisible tree reports every
    // item invisible, so a shown section would read as hidden.
    visible: true

    readonly property int artistId: 900000051

    Component { id: holderC; Item { } }
    Component { id: artistC; ArtistPage { anchors.fill: parent } }
    Component { id: swatchC; Rectangle { width: 32; height: 32 } }
    Component { id: metricsC; FontMetrics { } }

    function makePage(width) {
        var holder = createTemporaryObject(holderC, testCase)
        verify(holder, "the holder was not created")
        holder.width = width || 960
        holder.height = 800
        var page = createTemporaryObject(artistC, holder, {})
        verify(page, "the page was not created")
        return page
    }

    // Asks the item's window for a frame and waits for it.
    function frame(item) {
        item.Window.window.update()
        verify(waitForRendering(item), "the window drew no frame")
    }

    function settle(item) {
        frame(item)
        wait(1)
    }

    function open(detail, width) {
        bridge.setArtistForTest(detail, [], [])
        var page = makePage(width)
        page.artistId = testCase.artistId
        settle(page)
        return page
    }

    function cleanup() {
        bridge.resetHeadersForTest()
        prefs.theme = "sea"
        prefs.oledBlack = false
        prefs.tintedGreys = false
    }

    // A bio of `n` invented sentences, one paragraph.
    function longBio(n) {
        var s = []
        for (var i = 0; i < n; ++i)
            s.push("Die Band spielte im Jahr " + (1990 + i) + " eine lange Reihe von Konzerten in kleinen Hallen.")
        return s.join(" ")
    }

    // ── formatBio ────────────────────────────────────────────────────────────

    function test_breaksAreParagraphsNotText() {
        var page = makePage()
        var html = page.formatBio("Erster Absatz.<br/>Zweiter Absatz.")
        verify(html.indexOf("&lt;br") < 0, "the <br/> came out as text: " + html)
        verify(html.indexOf("<br") > 0, "the paragraphs are not broken: " + html)
        verify(html.indexOf("Erster Absatz.") < html.indexOf("Zweiter Absatz."))
        // Tidal's own bios use one or two in a row; both read as one break.
        compare(page.formatBio("A.<br/><br/>B."), page.formatBio("A.<br/>B."))
        compare(page.formatBio("A.<br>B."), page.formatBio("A.<br/>B."))
        compare(page.formatBio("A. <BR /> B."), page.formatBio("A.<br/>B."))
        compare(page.formatBio("A.\n\nB."), page.formatBio("A.<br/>B."))
    }

    function test_otherMarkupStaysText() {
        var page = makePage()
        var html = page.formatBio("Ein <b>fetter</b> Satz & mehr")
        verify(html.indexOf("<b>") < 0, "markup other than <br/> was let through: " + html)
        verify(html.indexOf("&lt;b&gt;fetter&lt;/b&gt;") >= 0, html)
        verify(html.indexOf("&amp; mehr") >= 0, html)
    }

    function test_wimpLinksBecomeLinks() {
        var page = makePage()
        page.artistId = testCase.artistId
        var html = page.formatBio(
            'Mit [wimpLink artistId="900000077"]Der Gast[/wimpLink] nahm sie '
            + '[wimpLink albumId="900000088"]Das Album[/wimpLink] auf.')
        verify(html.indexOf("[wimpLink") < 0 && html.indexOf("[/wimpLink]") < 0, html)
        verify(html.indexOf('href="artist:900000077"') >= 0, "no artist link: " + html)
        verify(html.indexOf('href="album:900000088"') >= 0, "no album link: " + html)
        verify(html.indexOf(">Der Gast</a>") >= 0, html)
    }

    // A link to the page already open, or to something with no page here,
    // would do nothing: those read as plain words.
    function test_deadLinksArePlainText() {
        var page = makePage()
        page.artistId = testCase.artistId
        var html = page.formatBio(
            '[wimpLink artistId="' + testCase.artistId + '"]Die Band[/wimpLink] und '
            + '[wimpLink trackId="900000099"]ein Lied[/wimpLink] und '
            + '[wimpLink playlistId="aaaa-bbbb"]eine Liste[/wimpLink].')
        compare(html.indexOf("<a"), -1, "a dead link was made: " + html)
        verify(html.indexOf("Die Band und ein Lied und eine Liste.") >= 0, html)
    }

    // Square brackets that are not a reference are words, and a reference
    // that never closes does not leave its tag on screen.
    function test_strayBracketsAndUnclosedLinks() {
        var page = makePage()
        verify(page.formatBio("Die [Erste Reihe] spielte").indexOf("[Erste Reihe]") >= 0)
        var html = page.formatBio('Mit [wimpLink artistId="900000077"]Der Gast und mehr.')
        verify(html.indexOf("wimpLink") < 0, html)
        verify(html.indexOf("Mit Der Gast und mehr.") >= 0, html)
    }

    // ── the clamp ────────────────────────────────────────────────────────────

    function test_longBioIsClampedWithAToggle() {
        var page = open({ id: testCase.artistId, name: "Eine Band", bio: longBio(30) })
        var bio = findChild(page, "artistBio")
        var toggle = findChild(page, "artistBioToggle")
        verify(bio, "the page has no bio text")
        verify(toggle, "the page has no Read more toggle")
        verify(bio.visible)
        verify(bio.lineCount <= page.bioCollapsedLines,
               "the collapsed bio shows " + bio.lineCount + " lines")
        verify(bio.truncated, "the collapsed bio is not cut")
        verify(toggle.visible, "a cut bio offers no Read more")
        compare(toggle.text, "Read more")
        var collapsed = bio.height

        mouseClick(toggle)
        settle(page)
        verify(!bio.truncated, "the opened bio is still cut")
        verify(bio.height > collapsed * 2, "the opened bio did not grow: " + bio.height)
        verify(toggle.visible)
        compare(toggle.text, "Show less")

        // The opened bio pushes the toggle below the window, so scroll to it.
        var flick = findChild(page, "artistContent").contentItem
        flick.contentY = Math.max(0, toggle.mapToItem(flick.contentItem, 0, 0).y - 200)
        settle(page)
        mouseClick(toggle)
        settle(page)
        verify(bio.truncated)
        compare(bio.height, collapsed)
        compare(toggle.text, "Read more")
    }

    function test_shortBioHasNoToggle() {
        var page = open({ id: testCase.artistId, name: "Eine Band", bio: "Ein Satz." })
        var bio = findChild(page, "artistBio")
        verify(bio.visible)
        verify(!bio.truncated)
        verify(!findChild(page, "artistBioToggle").visible, "a whole bio offers Read more")
    }

    // A measure of about 75 characters on a wide window, not the page width.
    function test_bioKeepsAReadableMeasure() {
        var page = open({ id: testCase.artistId, name: "Eine Band", bio: longBio(30) }, 1600)
        var bio = findChild(page, "artistBio")
        var fm = createTemporaryObject(metricsC, testCase, { font: bio.font })
        verify(bio.width <= fm.averageCharacterWidth * 80,
               "the bio is " + bio.width + " px wide, "
               + Math.round(bio.width / fm.averageCharacterWidth) + " characters")
        verify(bio.width >= fm.averageCharacterWidth * 60, "the bio is only " + bio.width + " px wide")
    }

    // A new artist starts collapsed.
    function test_anotherArtistStartsCollapsed() {
        var page = open({ id: testCase.artistId, name: "Eine Band", bio: longBio(30) })
        mouseClick(findChild(page, "artistBioToggle"))
        settle(page)
        verify(!findChild(page, "artistBio").truncated)
        bridge.setArtistForTest({ id: testCase.artistId + 1, name: "Andere Band", bio: longBio(30) }, [], [])
        page.artistId = testCase.artistId + 1
        settle(page)
        verify(findChild(page, "artistBio").truncated, "the next artist opened expanded")
    }

    // ── Related Artists ──────────────────────────────────────────────────────

    readonly property var threeSimilar: [
        { id: 900000061, name: "Erste Verwandte",  coverUrl: "" },
        { id: 900000062, name: "Zweite Verwandte", coverUrl: "" },
        { id: 900000063, name: "Dritte Verwandte", coverUrl: "" }
    ]

    function cardTitles(section) {
        var list = findChild(section, "sectionList")
        verify(list, "the row has no list of cards")
        var out = []
        for (var i = 0; i < list.count; ++i) {
            var card = list.itemAtIndex(i)
            verify(card, "card " + i + " was not drawn")
            out.push(findChild(card, "cardTitle").text)
        }
        return out
    }

    function test_relatedArtistsShow() {
        bridge.setSimilarArtistsForTest(threeSimilar)
        var page = open({ id: testCase.artistId, name: "Eine Band" })
        compare(bridge.lastSimilarFetchedForTest(), testCase.artistId)
        var section = findChild(page, "artistRelatedSection")
        verify(section, "the page has no Related Artists section")
        verify(section.visible, "the Related Artists section is hidden")
        compare(cardTitles(section), ["Erste Verwandte", "Zweite Verwandte", "Dritte Verwandte"])
    }

    function test_relatedArtistsHideWhenEmpty() {
        bridge.setSimilarArtistsForTest([])
        var page = open({ id: testCase.artistId, name: "Eine Band" })
        verify(!findChild(page, "artistRelatedSection").visible)
    }

    // A refusal (Tidal answers 404 for an artist with no list) hides the row
    // and is not the page's error.
    function test_relatedArtistsRefusedIsHiddenNotAnError() {
        bridge.setSimilarArtistsForTest(threeSimilar, "server replied: Not Found")
        var page = open({ id: testCase.artistId, name: "Eine Band" })
        verify(!findChild(page, "artistRelatedSection").visible)
        compare(page.loadError, "")
        verify(!page.loadFailed)
    }

    // The rest of the page lands while the similar list is still out.
    function test_relatedArtistsDoNotHoldThePage() {
        bridge.setSimilarArtistsForTest(threeSimilar)
        bridge.setDeferSimilarForTest(true)
        var page = open({ id: testCase.artistId, name: "Eine Band", bio: "Ein Satz." })
        compare(bridge.pendingSimilarForTest(), 1)
        compare(page.artistData.name, "Eine Band")
        verify(!page.loading, "the page waits for the similar list")
        verify(findChild(page, "artistBio").visible)
        verify(!findChild(page, "artistRelatedSection").visible)
        bridge.flushSimilarForTest()
        settle(page)
        verify(findChild(page, "artistRelatedSection").visible)
    }

    // A list for the artist just left does not land on the next one.
    function test_relatedArtistsForAnotherArtistAreDropped() {
        bridge.setSimilarArtistsForTest(threeSimilar)
        bridge.setDeferSimilarForTest(true)
        var page = open({ id: testCase.artistId, name: "Eine Band" })
        bridge.setSimilarArtistsForTest([])
        page.artistId = testCase.artistId + 1
        settle(page)
        compare(bridge.pendingSimilarForTest(), 2)
        bridge.flushSimilarForTest()
        settle(page)
        verify(!findChild(page, "artistRelatedSection").visible,
               "the previous artist's related list landed on this one")
    }

    // ── the name over the photo ──────────────────────────────────────────────

    function test_nameHasNoOutline() {
        var page = open({ id: testCase.artistId, name: "Eine Band" })
        var name = findChild(page, "artistName")
        verify(name, "the hero has no name text")
        compare(name.style, Text.Normal)
    }

    // WCAG 2.1, as tests/qml/tst_lyrics_contrast.qml.
    function channel(c) {
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
    }
    function luminance(col) {
        return 0.2126 * channel(col.r) + 0.7152 * channel(col.g) + 0.0722 * channel(col.b)
    }
    function contrast(a, b) {
        var la = luminance(a), lb = luminance(b)
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
    }

    // A plain photo of one colour. Inside the hero Image it takes the photo's
    // opacity and its place under the gradient.
    function photoOf(photo, colour) {
        var swatch = createTemporaryObject(swatchC, photo, { color: colour })
        verify(swatch, "the stand-in photo was not created")
        swatch.anchors.fill = photo
        return swatch
    }

    function test_nameReadsOverAWhiteOrBlackPhoto_data() {
        var rows = []
        var themes = ["sea", "pine", "rust", "sky", "sand", "clay"]
        for (var i = 0; i < themes.length; ++i)
            for (var p = 0; p < 2; ++p)
                rows.push({ tag: themes[i] + (p ? " black" : " white"),
                            theme: themes[i], photo: p ? "black" : "white" })
        return rows
    }

    // The ground behind the name's top line, where the photo shows most,
    // against the name's colour. 4.5:1 although the name is large text.
    function test_nameReadsOverAWhiteOrBlackPhoto(row) {
        prefs.theme = row.theme
        // Two lines, so the top of the name sits as high as it can.
        var page = open({ id: testCase.artistId,
                          name: "Ein sehr langer Bandname der sicher zwei Zeilen braucht und noch mehr" }, 900)
        var photo = findChild(page, "artistHeroPhoto")
        var name = findChild(page, "artistName")
        verify(photo && name)
        photoOf(photo, row.photo)
        name.opacity = 0
        settle(page)
        var hero = photo.parent
        var img = grabImage(hero)
        var top = name.mapToItem(hero, 0, 0)
        var worst = 99
        for (var x = top.x + 2; x < top.x + name.width; x += 40) {
            var ground = img.pixel(Math.round(x), Math.round(top.y + 2))
            worst = Math.min(worst, contrast(name.color, ground))
        }
        name.opacity = 1
        verify(worst >= 4.5, row.tag + ": the name reads at " + worst.toFixed(2) + ":1")
    }
}
