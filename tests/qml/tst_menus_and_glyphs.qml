// What the app is allowed to draw, and how wide a menu is allowed to get.
//
// Three things are pinned down here.
//
//   1. No Text the app shows contains a character outside Basic Latin, bar a
//      short allowlist of real punctuation. Emoji and dingbats render
//      differently on every machine, drag in a colour font, and sit on a
//      different baseline from the words beside them; the app has a drawn
//      icon set and that is where a mark belongs. This is the guard that
//      stops them coming back one glyph at a time.
//
//   2. A menu is as wide as its longest item, between a floor and a ceiling,
//      and at the ceiling the label elides rather than the menu growing off
//      the screen. The reported bug was a German label cut mid-word by a
//      hardcoded width; the fix has to be about the mechanism, so the long
//      label here is far longer than any real one.
//
//   3. The glyphs render at 16px -- the size menus and list rows use -- with
//      every painted pixel inside the icon's own box and something actually
//      painted. A VectorIcon with a name nobody drew is silently blank, which
//      is the one failure mode a reader cannot see in a diff.
//
// The globals (bridge, player, pins, ...) are the stubs from tests/TestStubs.h.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "MenusAndGlyphs"
    when: windowShown
    width: 900
    height: 700
    // TestCase declares visible: false, which would make every child report
    // visible == false and the sweeps below skip the whole tree.
    visible: true

    // ── what counts as punctuation ───────────────────────────────────────
    //
    // Everything else outside U+0020..U+007E is iconography by this test's
    // reckoning. Each of these is a mark that stands for nothing clickable,
    // replaces no word, and would be wrong to draw:
    //
    //   U+2026 …  ellipsis. Says an action opens something that asks for
    //             more ("Download…"), and marks text still arriving
    //             ("Searching for devices…"). It is punctuation in both.
    //   U+00B7 ·  middot. Run-in separator: "12 tracks · Shuffled", the
    //             window title, the sidebar's tool tip.
    //   U+2022 •  bullet. The same separator on the album and playlist
    //             hero lines. Two characters for one job is untidy, but
    //             both are separators and renaming either re-keys a
    //             translated string for no gain.
    //   U+2013 –  en dash. Between the two halves of the window title, and
    //             alone as the Now Playing title when there is no track.
    readonly property string punctuation: "…·•–"

    // The two sort chips read "A→Z" and "Z→A". The arrow there is not a mark
    // standing in for a control: nothing about it is clickable, it is part of
    // the name of a sort order the way a range is written "Mon–Fri", and it
    // is read aloud as "A to Z". Spelling it out would be longer, no clearer,
    // and would re-key two entries of a finished catalogue. Exempted as whole
    // strings rather than by allowing the arrow everywhere, so the next
    // "View all →" still fails.
    readonly property var exemptStrings: ["A→Z", "Z→A"]

    // What this platform calls the app's shortcuts, removed from a label
    // before it is scanned.
    //
    // This is not a hole in the allowlist, it is the allowlist asking the
    // right question. On macOS QKeySequence::NativeText renders the modifier
    // keys as the symbols Apple puts on the keyboard - the Mac measured the
    // chips as carrying U+2318 COMMAND, U+2325 OPTION, U+238B ESCAPE and the
    // four arrows - and those are not decoration the app chose, they are the
    // name of the key. Refusing them would mean printing "Cmd+," on a machine
    // where every other application prints the symbol, which is the bug this
    // panel's shortcut table was built to fix in the first place.
    //
    // Subtracted by exact string rather than by allowing the characters
    // anywhere, so a stray arrow written into a label still fails, and so the
    // set is whatever this platform actually produces rather than a list of
    // code points that would rot the next time Apple adds one. The chips join
    // several sequences with " / ", which is why this removes substrings
    // instead of comparing whole labels.
    function withoutKeyNames(s) {
        var ids = Shortcuts.ids(), names = []
        for (var k = 0; k < ids.length; ++k) {
            var d = Shortcuts.display(ids[k])
            if (d && d.length > 0) names.push(d)
        }
        // Whole tokens, not substrings. Subtracting substrings looked right
        // and was wrong twice over, both found by negative probes on the Mac:
        //
        //   * Order mattered. "←" (seekBack) is subtracted before "⌥←" (back),
        //     so the arrow went first and the "⌥" was left stranded as an
        //     offender - a real chip failing.
        //   * Worse, it did not catch what it claimed to. "→", "←", "↑" and
        //     "↓" are each a COMPLETE display() string on their own, so
        //     substring subtraction deleted an arrow from anywhere, and a
        //     label reading "Weiter →" passed. The guard's whole purpose is to
        //     stop exactly that.
        //
        // A chip joins its sequences with " / ", so every part of a chip is
        // one key name exactly. If any part is not, this is not a chip and the
        // whole label is scanned as written.
        var parts = s.split(" / ")
        for (var i = 0; i < parts.length; ++i)
            if (names.indexOf(parts[i]) === -1) return s
        return ""
    }

    function offendingChars(s) {
        var bad = ""
        for (var i = 0; i < s.length; ++i) {
            var c = s.charAt(i)
            var n = s.charCodeAt(i)
            if (n >= 0x20 && n <= 0x7e) continue
            if (n === 0x09 || n === 0x0a || n === 0x0d) continue
            if (testCase.punctuation.indexOf(c) !== -1) continue
            if (bad.indexOf(c) === -1) bad += c
        }
        return bad
    }

    function isText(obj) {
        return obj && typeof obj.text === "string"
            && typeof obj.truncated === "boolean"
            && typeof obj.elide === "number"
    }

    // Every Text in a tree, visible or not: a label that is hidden at this
    // instant is still shipped, and the Like/Unlike pair is exactly the kind
    // of thing only one half of which is ever on screen at a time.
    function collectTexts(item, out) {
        if (!item) return out
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            if (isText(c)) out.push(c)
            collectTexts(c, out)
        }
        return out
    }

    function sweep(item, where) {
        var texts = collectTexts(item, [])
        var hits = []
        for (var i = 0; i < texts.length; ++i) {
            var t = texts[i].text
            if (testCase.exemptStrings.indexOf(t) !== -1) continue
            var bad = offendingChars(withoutKeyNames(t))
            if (bad.length > 0) hits.push('"' + t + '" carries ' + bad)
        }
        compare(hits.join("; "), "", where + " ships a character that is not Basic Latin")
        return texts.length
    }

    function settle(item) {
        waitForRendering(item)
        wait(1)
    }

    // ── fixtures ─────────────────────────────────────────────────────────

    Component { id: holderC; Item { } }

    Component {
        id: trackIconC
        VectorIcon { name: "track" }
    }

    Component {
        id: trackRowC
        TrackRow { width: 700 }
    }
    Component {
        id: mediaCardC
        MediaCard { }
    }
    Component {
        id: queueC
        QueuePanel { anchors.fill: parent }
    }
    Component {
        id: sidebarC
        SideBar { height: 700 }
    }
    Component {
        id: playerBarC
        PlayerBar { width: 900 }
    }
    Component {
        id: sectionC
        HorizontalSection { width: 900 }
    }
    Component {
        id: pageHeaderC
        PageHeader { width: 500 }
    }
    Component {
        id: pillC
        PillButton { }
    }
    Component {
        id: collectionC
        CollectionPage { anchors.fill: parent }
    }
    Component {
        id: albumPageC
        AlbumPage { anchors.fill: parent }
    }
    Component {
        id: playlistPageC
        PlaylistPage { anchors.fill: parent }
    }
    Component {
        id: radioPageC
        RadioPage { anchors.fill: parent }
    }
    // A Popup, so it has no anchors and nothing to sweep until it is open.
    Component {
        id: settingsC
        SettingsPanel { }
    }

    // NowPlayingPage delegates its sleep timer to Window.window, so it
    // warns its way through a plain TestCase parent. The same stand-in
    // window tst_nowplaying_access uses.
    Component {
        id: nowPlayingHostC
        Window {
            id: npWin
            width: 900; height: 700
            property alias page: np
            function navigate(page, params) {}
            function goBack() {}
            property bool fullScreen: false
            function toggleFullScreen() { fullScreen = !fullScreen }
            property bool sleepTimerActive: false
            property bool sleepStopAtEndOfTrack: false
            property int  sleepTimeLeft: 0
            property bool sleepIsFading: false
            property bool sleepFadeOut: true
            function startSleepTimer(minutes, stopAtEnd) {}
            function cancelSleepTimer() {}
            function formatSleepTime(seconds) { return "" }
            NowPlayingPage { id: np; width: npWin.width; height: npWin.height }
        }
    }

    // A menu built out of the shared entry row, with labels this test
    // chooses: the only way to aim a label at the ceiling without waiting for
    // a language that happens to be long enough.
    Component {
        id: probeMenuC
        // Built exactly the way the app builds a menu, including the
        // overlap: the Basic style asks for 1px of it, and Qt spends it
        // letting the menu hang that far past the window edge.
        Menu {
            id: probe
            popupType: Popup.Item
            overlap: 0
            implicitWidth: Theme.menuWidth(probe)
            background: Rectangle { color: Theme.surfaceHigh; border.color: Theme.border; radius: Theme.radiusPopup }
            property string longLabel: ""
            property string iconName: ""
            readonly property alias longItem: longEntry
            ContextMenu.Entry { text: "Kurz" }
            ContextMenu.Entry {
                id: longEntry
                objectName: "probeLongItem"
                text: probe.longLabel
                iconName: probe.iconName
                danger: probe.iconName !== ""
            }
        }
    }

    // One icon on a known ground, with room around it, so a grab can say
    // whether anything was painted outside the icon's own box.
    Component {
        id: iconProbeC
        Rectangle {
            property alias iconItem: ico
            property string iconName: ""
            property int iconSize: 16
            readonly property int pad: 6
            width:  iconSize + 2 * pad
            height: iconSize + 2 * pad
            color: "#ffffff"
            VectorIcon {
                id: ico
                x: parent.pad
                y: parent.pad
                width:  parent.iconSize
                height: parent.iconSize
                name: parent.iconName
                color: "#000000"
                strokeWidth: 1.6
            }
        }
    }

    function makeTrack() {
        return {
            id: 1001, title: "Ein Titel", artists: "Eine Band",
            albumTitle: "Ein Album", durationStr: "4:07",
            coverUrl: "", coverUrl80: "", albumId: 42, artistId: 7, popularity: 73,
            duration: 247
        }
    }

    function init() {
        app.setReducedMotionForTest(true)
        player.setManualForTest([])
        player.setQueueForTest([], -1)
        player.setCurrentTrackForTest({})
        pins.setItemsForTest([])
    }

    // ── 1. nothing typographic ships ─────────────────────────────────────

    function test_no_component_ships_a_text_glyph_data() {
        return [
            { tag: "TrackRow",          c: trackRowC   },
            { tag: "MediaCard",         c: mediaCardC  },
            { tag: "QueuePanel",        c: queueC      },
            { tag: "SideBar",           c: sidebarC    },
            { tag: "PlayerBar",         c: playerBarC  },
            { tag: "HorizontalSection", c: sectionC    },
            { tag: "PageHeader",        c: pageHeaderC },
            { tag: "CollectionPage",    c: collectionC },
            { tag: "AlbumPage",         c: albumPageC  },
            { tag: "PlaylistPage",      c: playlistPageC },
            { tag: "RadioPage",         c: radioPageC  }
        ]
    }

    function test_no_component_ships_a_text_glyph(data) {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var item = createTemporaryObject(data.c, holder, {})
        verify(item, data.tag + " was not created")
        settle(holder)
        sweep(item, data.tag)
    }

    function test_now_playing_ships_no_text_glyph() {
        var win = createTemporaryObject(nowPlayingHostC, testCase, {})
        verify(win, "the Now Playing host was not created")
        win.show()
        waitForRendering(win.page)
        wait(1)
        verify(sweep(win.page, "NowPlayingPage") > 10,
               "the sweep found almost no labels, so it proved nothing")
        win.close()
    }

    // The Settings panel is a Popup: it has to be opened before there is a
    // tree to walk, and its contents are under contentItem rather than under
    // the panel itself.
    function test_the_settings_panel_ships_no_text_glyph() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var panel = createTemporaryObject(settingsC, holder, {})
        verify(panel, "the settings panel was not created")
        panel.open()
        tryVerify(function () { return panel.visible }, 2000, "the panel did not open")
        settle(holder)
        verify(sweep(panel.contentItem, "SettingsPanel") > 10,
               "the sweep found almost no labels, so it proved nothing")
        panel.close()
    }

    // A pill names an icon now; handing it a character has to leave it with no
    // icon at all rather than quietly drawing one.
    function test_a_pill_takes_an_icon_name_not_a_character() {
        var holder = createTemporaryObject(holderC, testCase, { width: 400, height: 80 })
        var pill = createTemporaryObject(pillC, holder, { text: "Abspielen", icon: "play" })
        verify(pill, "the pill was not created")
        settle(holder)
        sweep(pill, "PillButton")
        verify(pill.icon === "play", "the pill lost its icon name")
    }

    // The menus are the point of the exercise, so they are opened and swept
    // rather than left to the component sweeps above, which never build them:
    // TrackRow's menu is behind a Loader that is deliberately inactive.
    function test_an_open_track_menu_ships_no_text_glyph() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var row = createTemporaryObject(trackRowC, holder, {
            trackNum: 1, title: "Ein Titel", artists: "Eine Band",
            durationStr: "4:07", trackData: makeTrack(),
            playlistUuid: "uuid-1", trackItemIndex: 0
        })
        verify(row, "the row was not created")
        settle(holder)

        row.openMenu()
        var menu = row.rowMenu
        verify(menu, "the row built no menu")
        settle(holder)
        verify(sweep(menu.contentItem, "the track row menu") > 0,
               "the sweep found no labels at all, so it proved nothing")
        menu.close()
    }

    function test_an_open_pin_menu_ships_no_text_glyph() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var card = createTemporaryObject(mediaCardC, holder, {
            mediaType: "album", itemId: "42", title: "Fever Dream", subtitle: "The Band"
        })
        verify(card, "the card was not created")
        settle(holder)

        card.pinMenu.showPin(10, 10, "album", "42", "Fever Dream", "The Band", "")
        tryVerify(function () { return card.pinMenu.visible }, 2000, "the card menu did not open")
        verify(sweep(card.pinMenu.contentItem, "the pin menu") > 0,
               "the sweep found no labels at all, so it proved nothing")
        card.pinMenu.close()
    }

    // ── 2. a menu is as wide as its longest item ─────────────────────────

    function test_a_menu_grows_to_its_longest_label() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        // Comfortably longer than "Zur Warteschlange hinzufügen" and still
        // under the ceiling, so growth is what is being measured.
        var label = "Aus der Wiedergabeliste entfernen"
        var menu = createTemporaryObject(probeMenuC, holder, { longLabel: label })
        verify(menu, "the probe menu was not created")
        menu.popup(20, 20)
        tryVerify(function () { return menu.visible }, 2000, "the probe menu did not open")
        settle(holder)

        var item = menu.longItem
        verify(item.width >= item.implicitWidth - 0.5,
               "the long item got " + item.width.toFixed(1) + " for an implicit "
               + item.implicitWidth.toFixed(1))
        verify(menu.width >= Theme.menuMinWidth, "the menu fell below its floor")
        verify(menu.width <= Theme.menuMaxWidth, "the menu passed its ceiling")

        var labels = collectTexts(item, [])
        compare(labels.length, 1, "the entry should hold exactly one label")
        verify(!labels[0].truncated,
               "the label is clipped at a menu width of " + menu.width.toFixed(1))
        menu.close()
    }

    // A short menu must not shrink to the width of its words.
    function test_a_short_menu_keeps_its_floor() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var menu = createTemporaryObject(probeMenuC, holder, { longLabel: "Pin" })
        menu.popup(20, 20)
        tryVerify(function () { return menu.visible }, 2000, "the probe menu did not open")
        settle(holder)
        compare(menu.width, Theme.menuMinWidth, "a two-word menu did not hold the floor")
        menu.close()
    }

    // The ceiling, and what happens at it: the label gives way, the menu does
    // not. 300 characters is not a language, it is the mechanism.
    function test_an_absurd_label_elides_instead_of_growing_the_menu() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var label = ""
        for (var i = 0; i < 30; ++i) label += "Warteschlangeneintrag "
        var menu = createTemporaryObject(probeMenuC, holder, { longLabel: label })
        menu.popup(20, 20)
        tryVerify(function () { return menu.visible }, 2000, "the probe menu did not open")
        settle(holder)

        verify(menu.width <= Theme.menuMaxWidth,
               "the menu grew to " + menu.width.toFixed(1) + " for a 600 character label")
        var labels = collectTexts(menu.longItem, [])
        verify(labels[0].truncated, "the label did not elide, so it is being clipped instead")
        verify(labels[0].elide === Text.ElideRight, "the label has no elide mode")
        menu.close()
    }

    // ── the window edge ──────────────────────────────────────────────────

    function test_a_menu_at_the_right_edge_stays_on_screen() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var menu = createTemporaryObject(probeMenuC, holder,
                                         { longLabel: "Aus der Mediathek entfernen" })
        // Three pixels from the right edge of the window, which is where a
        // right-click on the last column of a list lands.
        menu.popup(holder.width - 3, 40)
        tryVerify(function () { return menu.visible }, 2000, "the probe menu did not open")
        settle(holder)

        // The background fills the popup, so it is the popup's own box in
        // window coordinates. contentItem is inset by the menu's padding and
        // would understate it.
        var box = menu.background
        var at = box.mapToItem(null, 0, 0)
        verify(at.x >= -0.5,
               "the menu starts at x=" + at.x.toFixed(1) + ", off the left of the window")
        verify(at.x + box.width <= testCase.width + 0.5,
               "the menu ends at x=" + (at.x + box.width).toFixed(1)
               + " in a window " + testCase.width + " wide")
        menu.close()
    }

    function test_a_menu_at_the_bottom_edge_stays_on_screen() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var menu = createTemporaryObject(probeMenuC, holder, { longLabel: "Abspielen" })
        menu.popup(40, holder.height - 3)
        tryVerify(function () { return menu.visible }, 2000, "the probe menu did not open")
        settle(holder)

        var box = menu.background
        var at = box.mapToItem(null, 0, 0)
        verify(at.y >= -0.5,
               "the menu starts at y=" + at.y.toFixed(1) + ", off the top of the window")
        verify(at.y + box.height <= testCase.height + 0.5,
               "the menu ends at y=" + (at.y + box.height).toFixed(1)
               + " in a window " + testCase.height + " tall")
        menu.close()
    }

    // The real menu, with the real labels, in the language the bug was
    // reported in: nothing in it may be clipped.
    function test_the_real_track_menu_clips_nothing() {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var row = createTemporaryObject(trackRowC, holder, {
            trackNum: 1, title: "Ein Titel", trackData: makeTrack(),
            playlistUuid: "uuid-1", trackItemIndex: 0
        })
        settle(holder)
        row.openMenu()
        var menu = row.rowMenu
        settle(holder)

        var labels = collectTexts(menu.contentItem, [])
        verify(labels.length > 6, "only " + labels.length + " labels found in the track menu")
        var clipped = []
        for (var i = 0; i < labels.length; ++i)
            if (labels[i].truncated) clipped.push(labels[i].text)
        compare(clipped.join("; "), "", "the track menu clips its own labels")
        menu.close()
    }

    // ── 3. the marks ─────────────────────────────────────────────────────

    // Every name the menus and rows ask for, plus the one drawn for this
    // change. A typo in a name is a blank icon and nothing else, which is why
    // "something is actually drawn" is half of what this asserts.
    readonly property var iconNames: [
        "trash", "play", "pause", "more", "track", "chevron-left", "chevron-right",
        "heart", "heart-filled", "shuffle", "edit", "download", "check", "x",
        "album", "artist", "playlist", "mix", "pin", "pin-filled", "grip",
        "speaker", "cast", "queue", "volume-high", "volume-mute"
    ]

    function markCases() {
        var out = []
        for (var i = 0; i < iconNames.length; ++i)
            out.push({ tag: iconNames[i], name: iconNames[i] })
        return out
    }

    // Every number in a glyph's path, so the grid it is drawn on can be
    // checked. Arc flags and radii are numbers too, and they are all in the
    // same 0..24 range as the coordinates, so no attempt is made to tell them
    // apart: anything over 24 is out of the grid whatever it was meant to be.
    function pathNumbers(path) {
        var out = []
        var re = /-?\d+(?:\.\d+)?/g
        var m
        while ((m = re.exec(path)) !== null) out.push(parseFloat(m[0]))
        return out
    }

    // This is the "inside its bounds at 16px" assertion, and it is made on
    // the path rather than on pixels on purpose.
    //
    // VectorIcon draws into a fixed 24-unit Shape and scales it by
    // width * 0.85 / 24, centred. At 16px that is 13.6px of drawing in a 16px
    // box: 1.2px of margin on each side, against a stroke whose half-width
    // comes to 0.6px. So a path that stays inside the 24 grid cannot leave
    // the box at 16px -- or at any other size, which a pixel count could not
    // tell you.
    //
    // Counting pixels at 16px is not an option here anyway: under the
    // offscreen platform the tests run on, a Shape stroke under about one
    // device pixel rasterises to nothing at all, so every stroked glyph in
    // the set grabs as a blank square. The 48px grab below is what proves the
    // path draws something.
    function test_every_mark_stays_inside_the_24_grid_data() { return markCases() }

    function test_every_mark_stays_inside_the_24_grid(data) {
        var holder = createTemporaryObject(holderC, testCase, { width: 200, height: 200 })
        var probe = createTemporaryObject(iconProbeC, holder,
                                          { iconName: data.name, iconSize: 16 })
        verify(probe, "the icon probe was not created")

        var path = probe.iconItem._pathFor(data.name)
        verify(path.length > 0, data.name + " has no path, so it draws nothing at all")

        var ns = pathNumbers(path)
        verify(ns.length >= 4, data.name + " has a path of " + ns.length + " numbers")
        var bad = []
        for (var i = 0; i < ns.length; ++i)
            if (ns[i] < 0 || ns[i] > 24) bad.push(ns[i])
        compare(bad.join(" "), "", data.name + " leaves the 24 unit grid")

        compare(probe.iconItem.width, 16, "the probe is not at the size being asserted")
    }

    // And it draws. Grabbed at 48px for the reason above, on a white ground,
    // with a margin all round so paint outside the icon's own box shows up.
    function test_every_mark_draws_and_only_inside_its_box_data() { return markCases() }

    function test_every_mark_draws_and_only_inside_its_box(data) {
        var holder = createTemporaryObject(holderC, testCase, { width: 300, height: 300 })
        var probe = createTemporaryObject(iconProbeC, holder,
                                          { iconName: data.name, iconSize: 48 })
        verify(probe, "the icon probe was not created")
        settle(holder)

        var img = grabImage(probe)
        var pad = probe.pad
        var size = probe.iconSize
        var ink = 0
        var outside = []
        for (var y = 0; y < img.height; ++y) {
            for (var x = 0; x < img.width; ++x) {
                // The ground is white and the glyph black; anything that is
                // not nearly white is paint.
                if (img.red(x, y) > 0.9 && img.green(x, y) > 0.9 && img.blue(x, y) > 0.9)
                    continue
                if (x < pad || y < pad || x >= pad + size || y >= pad + size) {
                    if (outside.length < 6) outside.push(x + "," + y)
                    continue
                }
                ink++
            }
        }
        compare(outside.join(" "), "", data.name + " paints outside its " + size + "px box")
        verify(ink > 20, data.name + " painted only " + ink
               + " pixels at " + size + "px, so it is blank or near enough")
    }

    // ── 4. the note is gone ──────────────────────────────────────────────
    //
    // "music" was a pair of beamed eighth notes standing in for four
    // unrelated meanings: a track, an empty shelf, a missing cover, and an
    // avatar. It is Western staff notation rather than a symbol for audio and
    // it is not coming back, so this is the guard rather than a grep.

    function isVectorIcon(obj) {
        return obj && typeof obj._pathFor === "function"
            && typeof obj.name === "string"
    }

    function collectIcons(item, out) {
        if (!item) return out
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            if (isVectorIcon(kids[i])) out.push(kids[i])
            collectIcons(kids[i], out)
        }
        return out
    }

    function test_the_note_is_not_drawn_at_all() {
        var probe = createTemporaryObject(iconProbeC, testCase, { iconName: "music" })
        compare(probe.iconItem._pathFor("music"), "",
                "VectorIcon still knows how to draw a note")
        compare(probe.iconItem._accentFor("music"), "")
    }

    // Every component in the app, swept for the name. A VectorIcon nobody
    // drew a path for is silently blank, so a leftover "music" would not show
    // up as anything at all in a screenshot.
    function test_no_component_asks_for_the_note_data() {
        return test_no_component_ships_a_text_glyph_data()
    }

    function test_no_component_asks_for_the_note(data) {
        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var item = createTemporaryObject(data.c, holder, {})
        verify(item, data.tag + " was not created")
        settle(holder)

        var icons = collectIcons(item, [])
        var named = []
        var blank = []
        for (var i = 0; i < icons.length; ++i) {
            var n = icons[i].name
            if (n === "music") named.push(data.tag)
            // And nothing else silently blank either, which is the failure
            // mode retiring a glyph creates: every call site has to have been
            // given a name that draws.
            if (n !== "" && icons[i]._pathFor(n) === "" && icons[i]._accentFor(n) === "")
                blank.push(n)
        }
        compare(named.join(" "), "", data.tag + " still asks for the note")
        compare(blank.join(" "), "", data.tag + " names a glyph nobody drew")
    }

    function test_now_playing_and_settings_ask_for_no_note() {
        var win = createTemporaryObject(nowPlayingHostC, testCase, {})
        win.show()
        waitForRendering(win.page)
        wait(1)
        var icons = collectIcons(win.page, [])
        verify(icons.length > 5, "the sweep found almost no icons, so it proved nothing")
        for (var i = 0; i < icons.length; ++i)
            verify(icons[i].name !== "music", "NowPlayingPage still asks for the note")
        win.close()

        var holder = createTemporaryObject(holderC, testCase, { width: 900, height: 700 })
        var panel = createTemporaryObject(settingsC, holder, {})
        panel.open()
        tryVerify(function () { return panel.visible }, 2000, "the panel did not open")
        settle(holder)
        var pi = collectIcons(panel.contentItem, [])
        verify(pi.length > 2, "the sweep found almost no icons in Settings")
        for (var k = 0; k < pi.length; ++k)
            verify(pi[k].name !== "music", "SettingsPanel still asks for the note")
        panel.close()
    }

    // ── 5. the two marks the note was replaced by ────────────────────────
    //
    // "a track" and "this is playing" sit next to each other in a track row,
    // and at five bars against seven the count is not something anyone reads
    // at 14px. The animation carries the difference while it is running, and
    // under reduced motion it is not, so the structure has to: a waveform is
    // symmetric about its centre line, the playing bars stand on a floor.
    // Both halves of that are asserted below, on geometry rather than on
    // pixels.

    // "M x y1 V y2" per bar, which is the only shape the waveform's path
    // takes. Returns [{x, top, bottom}].
    function barsInPath(path) {
        var out = []
        var re = /M\s+(-?[\d.]+)\s+(-?[\d.]+)\s+V\s+(-?[\d.]+)/g
        var m
        while ((m = re.exec(path)) !== null) {
            out.push({ x: parseFloat(m[1]),
                       top: Math.min(parseFloat(m[2]), parseFloat(m[3])),
                       bottom: Math.max(parseFloat(m[2]), parseFloat(m[3])) })
        }
        return out
    }

    function test_the_track_mark_is_a_waveform_about_a_centre_line() {
        var probe = createTemporaryObject(iconProbeC, testCase, { iconName: "track" })
        var bars = barsInPath(probe.iconItem._pathFor("track"))
        compare(bars.length, 7, "a waveform strip is seven bars")

        var heights = []
        for (var i = 0; i < bars.length; ++i) {
            var centre = (bars[i].top + bars[i].bottom) / 2
            verify(Math.abs(centre - 12) < 0.01,
                   "bar " + i + " is centred on " + centre.toFixed(2)
                   + ", not on the 24 grid's centre line")
            heights.push(bars[i].bottom - bars[i].top)
            if (i > 0) verify(bars[i].x > bars[i - 1].x, "the bars are out of order")
        }
        // A rendered audio file, not a comb: the heights have to differ.
        var distinct = {}
        for (var k = 0; k < heights.length; ++k) distinct[heights[k].toFixed(2)] = true
        verify(Object.keys(distinct).length >= 5,
               "only " + Object.keys(distinct).length + " distinct bar heights")
    }

    Component {
        id: playingProbeC
        Item {
            width: 40; height: 40
            property alias indicator: ind
            VectorIcon.PlayingIndicator {
                id: ind
                anchors.centerIn: parent
                width: 16; height: 14
            }
        }
    }

    // The bars, in the indicator's own coordinates.
    function barsOf(ind) {
        var out = []
        function walk(item) {
            var kids = item.children
            for (var i = 0; i < kids.length; ++i) {
                var c = kids[i]
                if (typeof c.radius === "number" && c.children.length === 0
                        && c.width > 0 && c.height > 0) {
                    var at = c.mapToItem(ind, 0, 0)
                    out.push({ x: at.x, top: at.y, bottom: at.y + c.height,
                               w: c.width, h: c.height })
                } else {
                    walk(c)
                }
            }
        }
        walk(ind)
        out.sort(function (a, b) { return a.x - b.x })
        return out
    }

    function test_the_playing_mark_stands_on_a_baseline_with_motion_off() {
        // init() already switched reduced motion on; said out loud because
        // the whole point of this case is the parked state.
        app.setReducedMotionForTest(true)
        var holder = createTemporaryObject(holderC, testCase, { width: 200, height: 200 })
        var probe = createTemporaryObject(playingProbeC, holder, {})
        verify(probe, "the probe was not created")
        settle(holder)
        // Long enough for a sequence that is not parking to have moved on.
        wait(80)

        var ind = probe.indicator
        var bars = barsOf(ind)
        compare(bars.length, 5, "the playing mark is five bars")

        // Standing on a floor: one bottom edge, shared.
        var floor = bars[0].bottom
        for (var i = 0; i < bars.length; ++i) {
            verify(Math.abs(bars[i].bottom - floor) < 0.5,
                   "bar " + i + " sits at " + bars[i].bottom.toFixed(2)
                   + " while the first is at " + floor.toFixed(2)
                   + ", so there is no baseline")
            // Parked, not vanished: a "this is playing" mark that disappears
            // under reduced motion says the wrong thing about a playing row.
            verify(bars[i].h > 1,
                   "bar " + i + " parked at " + bars[i].h.toFixed(2) + "px, which is nothing")
            // And inside its own box, like any other mark.
            verify(bars[i].top >= -0.5 && bars[i].bottom <= ind.height + 0.5
                       && bars[i].x >= -0.5 && bars[i].x + bars[i].w <= ind.width + 0.5,
                   "bar " + i + " paints outside the indicator's box")
        }

        // A recognisable shape, which an even row of five would not be.
        var distinct = {}
        for (var k = 0; k < bars.length; ++k) distinct[bars[k].h.toFixed(1)] = true
        verify(Object.keys(distinct).length >= 3,
               "the parked mark has only " + Object.keys(distinct).length
               + " distinct heights, so it is a block rather than a skyline")
    }

    // The two side by side, with nothing moving: whatever else they share,
    // one is symmetric about its middle and the other is not.
    function test_the_two_marks_stay_apart_with_motion_off() {
        app.setReducedMotionForTest(true)
        var holder = createTemporaryObject(holderC, testCase, { width: 200, height: 200 })
        var probe = createTemporaryObject(playingProbeC, holder, {})
        var ico = createTemporaryObject(iconProbeC, holder, { iconName: "track" })
        settle(holder)
        wait(80)

        var wave = barsInPath(ico.iconItem._pathFor("track"))
        var bars = barsOf(probe.indicator)
        verify(wave.length !== bars.length, "both marks have the same number of bars")

        // The waveform's bars are centred on one line and its tops and its
        // bottoms both vary.
        var waveTops = {}, waveBottoms = {}
        for (var i = 0; i < wave.length; ++i) {
            waveTops[wave[i].top.toFixed(2)] = true
            waveBottoms[wave[i].bottom.toFixed(2)] = true
        }
        verify(Object.keys(waveTops).length > 1 && Object.keys(waveBottoms).length > 1,
               "the waveform has a flat edge, so it is not symmetric about anything")

        // The playing mark's bottoms are all one value and only its tops vary,
        // which is the whole of the difference once nothing is moving.
        var playTops = {}, playBottoms = {}
        for (var k = 0; k < bars.length; ++k) {
            playTops[bars[k].top.toFixed(1)] = true
            playBottoms[bars[k].bottom.toFixed(1)] = true
        }
        compare(Object.keys(playBottoms).length, 1,
                "the playing mark has no single baseline, so it reads as a waveform too")
        verify(Object.keys(playTops).length > 1, "the playing mark is a flat block")
    }

    // The "track" strip draws seven bars of one width, separated by gaps of
    // one width, at every size it is used at.
    //
    // This is the property the stroked-path version could not hold, and the
    // reason is worth keeping next to the test: Qt rasterises that Shape with
    // no antialiasing, so each stroke snapped to whole pixels and its width
    // became a function of where its edges happened to land. The Mac measured
    // bars of 2,1,1,2,1,1,2 device px at W=12 on a Retina panel, and gaps that
    // were never uniform except at one size. Averages and totals would both
    // have passed that; only comparing every bar to every other catches it.
    function test_the_track_strip_has_uniform_bars_and_gaps_data() {
        return [
            { tag: "12 - Now Playing button",  w: 12 },
            { tag: "15 - LibraryFinder chip",  w: 15 },
            { tag: "16 - player bar row",      w: 16 },
            { tag: "18",                       w: 18 },
            { tag: "24 - the design size",     w: 24 },
        ]
    }

    function test_the_track_strip_has_uniform_bars_and_gaps(row) {
        var icon = createTemporaryObject(trackIconC, testCase, { width: row.w, height: row.w })
        verify(icon, "could not build the icon")
        waitForRendering(icon)

        var bars = []
        collect(icon, "trackBar", bars)
        compare(bars.length, 7, row.tag + ": the strip is not seven bars")

        bars.sort(function (a, b) { return a.x - b.x })
        for (var i = 1; i < bars.length; ++i) {
            compare(bars[i].width, bars[0].width,
                    row.tag + ": bar " + i + " is " + bars[i].width
                    + " against bar 0 at " + bars[0].width)
            verify(bars[i].height > 0, row.tag + ": bar " + i + " has no height")
        }

        var gap0 = bars[1].x - (bars[0].x + bars[0].width)
        verify(gap0 >= 0, row.tag + ": the bars overlap")
        for (var k = 2; k < bars.length; ++k) {
            var gap = bars[k].x - (bars[k - 1].x + bars[k - 1].width)
            compare(gap, gap0,
                    row.tag + ": gap " + (k - 1) + " is " + gap
                    + " against the first gap at " + gap0)
        }
    }

    // Depth-first by objectName, because the bars are inside a Repeater.
    function collect(item, objName, out) {
        if (!item) return
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            if (kids[i].objectName === objName) out.push(kids[i])
            collect(kids[i], objName, out)
        }
    }

    // The key-name subtraction must not become a hole in the guard.
    //
    // Every row here was run as a probe on a Mac, where display() actually
    // produces symbols; on Linux it is ASCII and the first two rows cannot
    // fail, which is precisely why the expectations are written down rather
    // than inferred from a passing run. The substring version this replaced
    // ACCEPTED "Weiter →" - it deleted an arrow from anywhere, because "→" is
    // a complete shortcut string on its own - and REJECTED the real "⌥← / ⎋"
    // chip, because it subtracted "←" first and stranded the "⌥".
    function test_the_key_name_subtraction_is_not_a_hole_data() {
        var ids = Shortcuts.ids()
        var oneChip = ids.length > 0 ? Shortcuts.display(ids[0]) : ""
        return [
            { tag: "a real chip is allowed",
              text: oneChip, offends: false },
            { tag: "two real chips joined are allowed",
              text: oneChip + " / " + oneChip, offends: false },
            { tag: "a stray arrow in prose is NOT allowed",
              text: "Weiter \u2192", offends: true },
            { tag: "a bare modifier symbol in prose is NOT allowed",
              text: "\u2318 Befehl", offends: true },
            { tag: "a dingbat is NOT allowed",
              text: "\u2605 Favorit", offends: true },
            { tag: "a chip with something extra appended is NOT allowed",
              text: oneChip + "\u2605", offends: true },
        ]
    }

    function test_the_key_name_subtraction_is_not_a_hole(row) {
        if (row.text.length === 0)
            skip("no shortcuts in the table to build a chip from")
        var bad = offendingChars(withoutKeyNames(row.text))
        if (row.offends)
            verify(bad.length > 0,
                   row.tag + ': "' + row.text + '" was accepted and should not be')
        else
            compare(bad, "",
                    row.tag + ': "' + row.text + '" was rejected, carrying ' + bad)
    }
}
