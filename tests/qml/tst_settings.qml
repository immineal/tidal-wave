// The Settings panel, qml/components/SettingsPanel.qml, reached through
// SideBar.openSettings() and exposed as SideBar.settingsPanel. Three doubles
// are built below, because tests/TestStubs.h has no i18n stub, StubPlayer has
// no availableAudioDevices(), and StubUpdateCheck's call count is invisible to
// QML. Each goes in through the property the panel has for it. prefs is the
// real StubPrefs, the object ThemePalette is wired to.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "Settings"
    when: windowShown

    // Main.qml's window minimum. The popup has to fit inside it.
    readonly property int minWindowW: 640
    readonly property int minWindowH: 600
    // The popup clamps to the overlay with 32px on every side.
    readonly property int popupInset: 64

    // Main.qml's sidebar width.
    readonly property int sidebarWidth: 220

    // A real binding on the palette singleton, the shape every file in the
    // app uses. Picking a theme has to move this as well as prefs.theme.
    Rectangle {
        id: probe
        width: 1; height: 1
        color: Theme.bg
    }

    // A second one, on the step above the page. The pure-black switch takes
    // bg to #000000 over either grey ramp, so only surface can show which
    // ramp is underneath.
    Rectangle {
        id: surfaceProbe
        width: 1; height: 1
        color: Theme.surface
    }

    // And one on the accent, which is what picking a theme moves. In the
    // neutral state the palettes of one mode share a grey ramp, so a pick
    // within a mode changes the accent and nothing else.
    Rectangle {
        id: accentProbe
        width: 1; height: 1
        color: Theme.accent
    }

    // ── the doubles ──────────────────────────────────────────────────────

    // I18n::availableLanguages(): System translated, the other two endonyms.
    QtObject {
        id: i18nStub
        function availableLanguages() {
            return [
                { code: "system", label: "System" },
                { code: "en",     label: "English" },
                { code: "de",     label: "Deutsch" }
            ]
        }
    }

    // Player::availableAudioDevices(): the System default sentinel first,
    // with an empty id, then the real devices, one of them flagged as the
    // one the OS treats as default.
    QtObject {
        id: audioStub

        property int reads: 0
        property var devices: []

        function availableAudioDevices() {
            reads++
            return devices
        }
    }

    // Rebuilt per test, because one of them unplugs a device.
    function threeDevices() {
        return [
            { id: "",   label: "System default",   isDefault: false },
            { id: "d1", label: "Built-in Analog",  isDefault: false },
            { id: "d2", label: "Scarlett 2i2 USB", isDefault: true  }
        ]
    }

    // UpdateCheck: the switch and the one invokable behind Check now.
    QtObject {
        id: updateStub
        property bool enabled: true
        property bool updateAvailable: false
        property string latestVersion: ""
        property string releaseUrl: ""
        property int checkNowCount: 0
        function checkNow() { checkNowCount++ }
    }

    // ── fixtures ─────────────────────────────────────────────────────────

    function init() {
        prefs.theme = "sea"
        prefs.oledBlack = false
        // The state a fresh install is in: one neutral grey ramp per mode, six
        // accents. Every test that cares about the tinted grounds asks for them.
        prefs.tintedGreys = false
        prefs.language = "system"
        prefs.audioDevice = ""
        prefs.softwareRendering = false
        prefs.quitOnClose = false
        prefs.setSidebarWidthForTest(sidebarWidth)
        app.setReducedMotionForTest(true)
        auth.setUsernameForTest("robin")
        library.setEntriesForTest([])
        pins.setItemsForTest([])

        audioStub.reads = 0
        audioStub.devices = threeDevices()
        updateStub.enabled = true
        updateStub.checkNowCount = 0
    }

    function cleanupTestCase() {
        prefs.theme = "sea"
        prefs.oledBlack = false
        prefs.tintedGreys = false
        app.setReducedMotionForTest(true)
    }

    Component {
        id: sideBarHost
        Window {
            id: win
            width: testCase.minWindowW
            height: testCase.minWindowH
            color: "black"

            property alias sidebar: sb

            SideBar {
                id: sb
                z: 2
                hostWidth: win.width
                width: testCase.sidebarWidth
                height: win.height
            }
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function settle(item) {
        wait(1)
        waitForRendering(item, 2000)
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function collectByName(item, name, out) {
        if (!item) return out
        if (item.objectName === name) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) collectByName(kids[i], name, out)
        return out
    }

    function typeName(obj) {
        return obj.toString().split("(")[0].split("_QML")[0]
    }

    // Everything visible that sticks out of its parent horizontally. The focus
    // rings bleed four pixels on purpose, as in tst_layout_player.qml.
    function collectOverflow(item, path, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            var here = path + " > " + typeName(c)
            // VectorIcon draws into a fixed 24px Shape and scales it down with
            // a transform, so below 24px its own child is wider than it is by
            // construction. The icon itself is still measured.
            if (typeName(c) === "VectorIcon") {
                if (c.x < -4.5 || c.x + c.width > item.width + 4.5)
                    out.push(here + " x=" + c.x.toFixed(1) + " w=" + c.width.toFixed(1)
                             + " but parent is " + item.width.toFixed(1) + " wide")
                continue
            }
            if (c.x < -4.5 || c.x + c.width > item.width + 4.5) {
                out.push(here + " x=" + c.x.toFixed(1) + " w=" + c.width.toFixed(1)
                         + " but parent is " + item.width.toFixed(1) + " wide")
            }
            collectOverflow(c, here, out)
        }
        return out
    }

    function isText(obj) {
        return typeof obj.truncated === "boolean"
            && typeof obj.elide === "number"
            && typeof obj.wrapMode === "number"
    }

    // Every Text under an item that says something. The feedback tests read what
    // the panel puts in front of a person with it.
    function collectTexts(item, out) {
        if (!item) return out
        if (isText(item) && item.text.length > 0) out.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) collectTexts(kids[i], out)
        return out
    }

    // Every visible Text that is cut off. One that elides is allowed to, but
    // not all the way down to nothing.
    function collectClipped(item, path, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (!c || c.visible === false || typeof c.width !== "number") continue
            var here = path + " > " + typeName(c)
            if (isText(c) && c.text.length > 0) {
                if (c.elide === Text.ElideNone && c.wrapMode === Text.NoWrap
                        && c.implicitWidth > c.width + 0.5) {
                    out.push(here + " needs " + c.implicitWidth.toFixed(0)
                             + "px and has " + c.width.toFixed(0) + ": " + c.text)
                } else if (c.elide !== Text.ElideNone && c.width < 24) {
                    out.push(here + " elides down to " + c.width.toFixed(0)
                             + "px: " + c.text)
                }
            }
            collectClipped(c, here, out)
        }
        return out
    }

    // Opens the panel with the three doubles in place. They go in before
    // open(), because reading the device list is something open() does.
    function openPanel(w, h) {
        var host = createTemporaryObject(sideBarHost, testCase)
        verify(host, "host window was not created")
        host.width = w
        host.height = h
        host.visible = true
        waitForRendering(host.contentItem, 2000)

        var panel = host.sidebar.settingsPanel
        verify(panel, "SideBar exposes no settingsPanel")
        panel.langSource   = i18nStub
        panel.deviceSource = audioStub
        panel.check        = updateStub

        host.sidebar.openSettings()
        settle(host.contentItem)
        verify(panel.visible, "the settings popup did not open")
        return { host: host, panel: panel }
    }

    // The Flickable ScrollView wraps the panel's content in.
    function scrollerOf(panel) {
        var sv = findByName(panel.contentItem, "settingsScroll")
        verify(sv, "the settings panel has no scroll view")
        return sv.contentItem
    }

    // A control below the viewport still reports itself visible, but a click
    // on it would land outside the popup and dismiss it. Bring it into view
    // first.
    function scrollTo(panel, item) {
        var flick = scrollerOf(panel)
        var y = item.mapToItem(flick.contentItem, 0, 0).y
        var maxY = Math.max(0, flick.contentHeight - flick.height)
        flick.contentY = Math.max(0, Math.min(y - 40, maxY))
        settle(panel.contentItem)
    }

    function clickItem(panel, item) {
        scrollTo(panel, item)
        mouseClick(item, Math.round(item.width / 2), Math.round(item.height / 2))
        settle(panel.contentItem)
    }

    // Every swatch in the grid, keyed by its theme. Re-read each time:
    // flipping the colour switch rebuilds the Repeater and destroys the tiles
    // collected before it.
    function swatchesByTheme(panel) {
        var tiles = collectByName(panel.contentItem, "settingsThemeOption", [])
        var out = {}
        for (var i = 0; i < tiles.length; i++)
            out[tiles[i].themeName] = findByName(tiles[i], "settingsThemeSwatch")
        return out
    }

    function accentDotsByTheme(panel) {
        var tiles = collectByName(panel.contentItem, "settingsThemeOption", [])
        var out = {}
        for (var i = 0; i < tiles.length; i++)
            out[tiles[i].themeName] = findByName(tiles[i], "settingsThemeSwatchAccent")
        return out
    }

    function valuesOf(options) {
        var out = []
        for (var i = 0; i < options.length; i++) out.push(options[i].value)
        return out
    }

    // ── 1. the theme picker ──────────────────────────────────────────────

    function test_every_theme_is_offered_with_a_swatch() {
        var h = openPanel(1280, 1200)
        var tiles = collectByName(h.panel.contentItem, "settingsThemeOption", [])
        compare(tiles.length, 6, "the panel offers " + tiles.length + " themes, not six")

        var offered = []
        for (var i = 0; i < tiles.length; i++) {
            offered.push(tiles[i].themeName)
            verify(tiles[i].label.length > 0,
                   tiles[i].themeName + " has no label")
            var swatch = findByName(tiles[i], "settingsThemeSwatch")
            verify(swatch && swatch.visible,
                   tiles[i].themeName + " is offered by name alone, with no swatch")
            verify(swatch.width >= 8 && swatch.height >= 8,
                   tiles[i].themeName + "'s swatch is too small to read")
        }

        // Exactly the palettes the C++ table defines, so a theme added or
        // renamed there fails here instead of quietly vanishing from Settings.
        var known = []
        var avail = ThemePalette.available()
        for (var j = 0; j < avail.length; j++) known.push(avail[j].name)
        compare(offered.sort().join(","), known.sort().join(","),
                "the picker and ThemePalette.available() disagree")

        h.panel.close()
    }

    function test_dark_and_light_themes_are_grouped() {
        var h = openPanel(1280, 1200)
        var groups = collectByName(h.panel.contentItem, "settingsThemeGroup", [])
        compare(groups.length, 2, "dark and light are not grouped")

        var dark = 0, light = 0
        for (var i = 0; i < groups.length; i++) {
            var tiles = collectByName(groups[i], "settingsThemeOption", [])
            for (var j = 0; j < tiles.length; j++) {
                compare(tiles[j].themeDark, groups[i].dark,
                        tiles[j].themeName + " sits in the wrong group")
            }
            if (groups[i].dark) dark = tiles.length
            else                light = tiles.length
            var heading = findByName(groups[i], "settingsThemeGroupLabel")
            verify(heading && heading.visible && heading.text.length > 0,
                   "a theme group has no heading")
        }
        compare(dark, 3, "there are three dark palettes")
        compare(light, 3, "there are three light palettes")

        h.panel.close()
    }

    // The two halves are columns side by side, and the nth tile of one sits
    // on the same line as the nth tile of the other, so each line reads as one
    // colour family: Sea with Sky, Pine with Sand, Rust with Clay.
    function test_the_two_columns_read_as_hue_rows() {
        var h = openPanel(1280, 1200)
        var groups = collectByName(h.panel.contentItem, "settingsThemeGroup", [])
        compare(groups.length, 2)

        var darkGroup  = groups[0].dark ? groups[0] : groups[1]
        var lightGroup = groups[0].dark ? groups[1] : groups[0]

        var a = collectByName(darkGroup,  "settingsThemeOption", [])
        var b = collectByName(lightGroup, "settingsThemeOption", [])
        compare(a.length, b.length, "the two columns are not the same length")

        // Side by side.
        var ax = darkGroup.mapToItem(h.panel.contentItem, 0, 0).x
        var bx = lightGroup.mapToItem(h.panel.contentItem, 0, 0).x
        verify(Math.abs(ax - bx) > 40,
               "the two halves are stacked, not side by side")
        verify(Math.abs(darkGroup.width - lightGroup.width) <= 2,
               "the columns are not the same width, so the rows cannot line up")

        var expect = [["sea", "sky"], ["pine", "sand"], ["rust", "clay"]]
        for (var i = 0; i < a.length; i++) {
            var ay = a[i].mapToItem(h.panel.contentItem, 0, 0).y
            var by = b[i].mapToItem(h.panel.contentItem, 0, 0).y
            verify(Math.abs(ay - by) <= 1,
                   a[i].themeName + " and " + b[i].themeName
                   + " are not on the same row (" + ay.toFixed(1) + " vs " + by.toFixed(1) + ")")
            compare([a[i].themeName, b[i].themeName].join(","), expect[i].join(","),
                    "row " + i + " is not the pair the palette table defines")
        }

        h.panel.close()
    }

    // The swatch table in the panel is a hand copy of three columns of the
    // C++ one, so each swatch is compared against the live palette. Both grey
    // ramps, because available() answers for whichever one is in force.
    function test_every_swatch_matches_the_palette_it_claims_data() {
        return [
            { tag: "neutral", tinted: false },
            { tag: "tinted",  tinted: true  }
        ]
    }

    function test_every_swatch_matches_the_palette_it_claims(row) {
        prefs.tintedGreys = row.tinted
        var h = openPanel(1280, 1200)
        var tiles = collectByName(h.panel.contentItem, "settingsThemeOption", [])
        verify(tiles.length > 0)

        for (var i = 0; i < tiles.length; i++) {
            prefs.theme = tiles[i].themeName
            settle(h.panel.contentItem)
            var swatch = findByName(tiles[i], "settingsThemeSwatch")
            compare(swatch.color.toString(), Theme.bg.toString(),
                    tiles[i].themeName + "'s swatch shows a ground the palette does not have")
            compare(swatch.border.color.toString(), Theme.border.toString(),
                    tiles[i].themeName + "'s swatch shows the wrong border")
        }

        h.panel.close()
    }

    function test_picking_a_theme_data() {
        var rows = []
        var avail = ThemePalette.available()
        for (var i = 0; i < avail.length; i++)
            rows.push({ tag: avail[i].name, name: avail[i].name, dark: avail[i].dark })
        return rows
    }

    // Picking writes prefs.theme, and the live binding on the palette
    // repaints. The accent is what is measured: within a mode the palettes
    // share their grounds, so the page only moves on a pick that crosses modes.
    function test_picking_a_theme(row) {
        // Start somewhere else, or picking the current theme is a no-op and
        // the repaint cannot be seen. Crossing modes for half the rows, staying
        // inside one for the other half.
        var from = (row.name === "sea") ? "pine" : "sea"
        prefs.theme = from
        prefs.oledBlack = false

        var h = openPanel(1280, 1200)
        var fromDark = ThemePalette.isDark
        var beforeBg = probe.color.toString()
        var beforeAccent = accentProbe.color.toString()

        var tiles = collectByName(h.panel.contentItem, "settingsThemeOption", [])
        var target = null
        for (var i = 0; i < tiles.length; i++)
            if (tiles[i].themeName === row.name) target = tiles[i]
        verify(target, "no tile for " + row.name)

        clickItem(h.panel, target)

        compare(prefs.theme, row.name, "picking " + row.name + " did not write prefs.theme")
        compare(ThemePalette.isDark, row.dark, row.name + " landed on the wrong palette")
        verify(accentProbe.color.toString() !== beforeAccent,
               "picking " + row.name + " wrote the setting but nothing repainted")
        if (row.dark !== fromDark)
            verify(probe.color.toString() !== beforeBg,
                   "picking " + row.name + " crossed from " + from
                   + " to the other side and the page did not follow")
        verify(target.selected, "the picked tile does not read as selected")

        h.panel.close()
    }

    // In the tinted state every pick moves the page, because each palette
    // carries its own grounds.
    function test_picking_a_theme_in_the_tinted_state_repaints_the_page_data() {
        return test_picking_a_theme_data()
    }

    function test_picking_a_theme_in_the_tinted_state_repaints_the_page(row) {
        prefs.theme = (row.name === "sea") ? "pine" : "sea"
        prefs.oledBlack = false
        prefs.tintedGreys = true

        var h = openPanel(1280, 1200)
        var before = probe.color.toString()

        var tiles = collectByName(h.panel.contentItem, "settingsThemeOption", [])
        var target = null
        for (var i = 0; i < tiles.length; i++)
            if (tiles[i].themeName === row.name) target = tiles[i]
        verify(target, "no tile for " + row.name)

        clickItem(h.panel, target)

        compare(prefs.theme, row.name)
        verify(probe.color.toString() !== before,
               "picking " + row.name + " with the tinted grounds on left the page alone")

        h.panel.close()
    }

    // ── 1b. the pure-black switch ────────────────────────────────────────

    // The switch belongs to the dark themes. On a light theme it is hidden,
    // since there is no way to enable it there.
    function test_the_pure_black_switch_is_hidden_on_a_light_theme_data() {
        return [
            { tag: "sky",  name: "sky" },
            { tag: "sand", name: "sand" },
            { tag: "clay", name: "clay" }
        ]
    }

    function test_the_pure_black_switch_is_hidden_on_a_light_theme(row) {
        prefs.theme = row.name
        var h = openPanel(1280, 1200)

        var toggle = findByName(h.panel.contentItem, "settingsOledToggle")
        verify(toggle, "the switch was removed rather than hidden")
        verify(!toggle.visible, row.name + " still shows the pure-black switch")
        var note = findByName(h.panel.contentItem, "settingsOledNote")
        verify(note && !note.visible, row.name + " still shows the switch's note")

        h.panel.close()
    }

    function test_the_pure_black_switch_is_shown_on_a_dark_theme_data() {
        return [
            { tag: "sea",  name: "sea" },
            { tag: "pine", name: "pine" },
            { tag: "rust", name: "rust" }
        ]
    }

    function test_the_pure_black_switch_is_shown_on_a_dark_theme(row) {
        prefs.theme = row.name
        var h = openPanel(1280, 1200)

        var toggle = findByName(h.panel.contentItem, "settingsOledToggle")
        verify(toggle && toggle.visible, row.name + " hides the pure-black switch")
        var note = findByName(h.panel.contentItem, "settingsOledNote")
        verify(note && note.visible && note.text.length > 0,
               "the switch is offered with no explanation of what it does")

        // Below both palette columns and across the whole card.
        var groups = collectByName(h.panel.contentItem, "settingsThemeGroup", [])
        var tiles = collectByName(h.panel.contentItem, "settingsThemeOption", [])
        var lowest = 0
        for (var i = 0; i < tiles.length; i++)
            lowest = Math.max(lowest, tiles[i].mapToItem(h.panel.contentItem, 0, 0).y)
        var block = findByName(h.panel.contentItem, "settingsOledBlock")
        verify(block && block.visible, "the pure-black block is not there")
        verify(block.mapToItem(h.panel.contentItem, 0, 0).y > lowest,
               "the switch is not below the palettes")
        for (i = 0; i < groups.length; i++) {
            verify(block.width > groups[i].width + 1,
                   "the switch is no wider than one palette column")
        }

        // Centred against both lines of its label.
        var note = findByName(h.panel.contentItem, "settingsOledNote")
        var tMid = toggle.mapToItem(block, 0, 0).y + toggle.height / 2
        verify(Math.abs(tMid - block.height / 2) <= 1.5,
               "the switch sits at " + tMid.toFixed(1) + " in a block "
               + block.height.toFixed(1) + " tall, so it is not centred on both lines")

        h.panel.close()
    }

    // Flipping it writes the setting and the live palette follows. The probe
    // shows the repaint, which a switch that only stored a bool would not do.
    function test_flipping_the_pure_black_switch_repaints() {
        prefs.theme = "pine"
        prefs.oledBlack = false

        var h = openPanel(1280, 1200)
        var before = probe.color.toString()
        var toggle = findByName(h.panel.contentItem, "settingsOledToggle")
        verify(toggle && toggle.visible)
        verify(!toggle.checked, "the switch does not follow prefs.oledBlack")

        clickItem(h.panel, toggle)

        verify(prefs.oledBlack, "the switch did not write prefs.oledBlack")
        verify(toggle.checked, "the switch did not follow the setting it just wrote")
        compare(probe.color.toString(), "#000000", "the page did not go black")
        verify(probe.color.toString() !== before)

        clickItem(h.panel, toggle)

        verify(!prefs.oledBlack)
        compare(probe.color.toString(), before, "turning it off did not come back")

        h.panel.close()
    }

    // ── 1c. the colour switch ────────────────────────────────────────────

    // Offered on every theme, because it has an effect on all of them: the
    // palettes of one mode share a grey ramp until it is turned on.
    function test_the_colour_switch_is_offered_on_every_theme_data() {
        var rows = []
        var avail = ThemePalette.available()
        for (var i = 0; i < avail.length; i++)
            rows.push({ tag: avail[i].name, name: avail[i].name })
        return rows
    }

    function test_the_colour_switch_is_offered_on_every_theme(row) {
        prefs.theme = row.name
        var h = openPanel(1280, 1200)

        var toggle = findByName(h.panel.contentItem, "settingsTintedToggle")
        verify(toggle && toggle.visible, row.name + " hides the colour switch")
        var note = findByName(h.panel.contentItem, "settingsTintedNote")
        verify(note && note.visible && note.text.length > 0,
               "the switch is offered with no explanation of what it does")
        var label = findByName(h.panel.contentItem, "settingsTintedLabel")
        verify(label && label.visible && label.text.length > 0, "the switch has no label")

        // init() leaves the greys neutral, which is what a fresh install gets,
        // so the switch has to read as off.
        verify(!toggle.checked, "the switch does not follow prefs.tintedGreys")

        h.panel.close()
    }

    // Under the grid and across the whole card: it changes what every swatch
    // above it shows, so it belongs to both columns.
    function test_the_colour_switch_sits_under_the_whole_grid() {
        var h = openPanel(1280, 1200)

        var block = findByName(h.panel.contentItem, "settingsTintedBlock")
        verify(block && block.visible, "the colour block is not there")

        var tiles = collectByName(h.panel.contentItem, "settingsThemeOption", [])
        var lowest = 0
        for (var i = 0; i < tiles.length; i++)
            lowest = Math.max(lowest, tiles[i].mapToItem(h.panel.contentItem, 0, 0).y)
        verify(block.mapToItem(h.panel.contentItem, 0, 0).y > lowest,
               "the switch is not below the palettes it applies to")

        var groups = collectByName(h.panel.contentItem, "settingsThemeGroup", [])
        for (i = 0; i < groups.length; i++)
            verify(block.width > groups[i].width + 1,
                   "the switch is no wider than one palette column")

        // Centred against both lines of its label, as the pure-black row is.
        var toggle = findByName(h.panel.contentItem, "settingsTintedToggle")
        var tMid = toggle.mapToItem(block, 0, 0).y + toggle.height / 2
        verify(Math.abs(tMid - block.height / 2) <= 1.5,
               "the switch sits at " + tMid.toFixed(1) + " in a block "
               + block.height.toFixed(1) + " tall, so it is not centred on both lines")

        h.panel.close()
    }

    // Flipping it writes the setting and the live palette follows, as the
    // probe shows.
    function test_flipping_the_colour_switch_repaints() {
        prefs.theme = "pine"
        prefs.oledBlack = false
        prefs.tintedGreys = false

        var h = openPanel(1280, 1200)
        var before = probe.color.toString()
        var toggle = findByName(h.panel.contentItem, "settingsTintedToggle")
        verify(toggle && toggle.visible)
        verify(!toggle.checked)

        clickItem(h.panel, toggle)

        verify(prefs.tintedGreys, "the switch did not write prefs.tintedGreys")
        verify(toggle.checked, "the switch did not follow the setting it just wrote")
        verify(probe.color.toString() !== before,
               "the greys were tinted and nothing repainted")

        clickItem(h.panel, toggle)

        verify(!prefs.tintedGreys)
        compare(probe.color.toString(), before, "turning it off did not come back")

        h.panel.close()
    }

    // The grid shows what the app paints. In the neutral state each mode is
    // one ground and three accents. After a flip all six grounds differ.
    function test_the_colour_switch_flips_the_grid() {
        prefs.theme = "sea"
        prefs.tintedGreys = false
        var h = openPanel(1280, 1200)

        var sw = swatchesByTheme(h.panel)
        var dots = accentDotsByTheme(h.panel)
        var darks = ["sea", "pine", "rust"]
        var lights = ["sky", "sand", "clay"]
        var i

        for (i = 1; i < darks.length; i++)
            compare(String(sw[darks[i]].color), String(sw[darks[0]].color),
                    darks[i] + " and " + darks[0]
                    + " show different grounds in the neutral state")
        for (i = 1; i < lights.length; i++)
            compare(String(sw[lights[i]].color), String(sw[lights[0]].color),
                    lights[i] + " and " + lights[0]
                    + " show different grounds in the neutral state")
        verify(String(sw.sea.color) !== String(sw.sky.color),
               "the dark and light ramps are the same colour")

        // The accent is what the choice is between, so the six dots have to
        // differ.
        var seen = {}
        var all = darks.concat(lights)
        for (i = 0; i < all.length; i++) {
            var c = String(dots[all[i]].color)
            verify(seen[c] === undefined,
                   all[i] + " and " + seen[c] + " show the same accent, so in the "
                   + "neutral state they are the same swatch")
            seen[c] = all[i]
        }

        var toggle = findByName(h.panel.contentItem, "settingsTintedToggle")
        clickItem(h.panel, toggle)

        // The Repeater was rebuilt, so these are new objects.
        sw = swatchesByTheme(h.panel)
        for (i = 1; i < darks.length; i++)
            verify(String(sw[darks[i]].color) !== String(sw[darks[0]].color),
                   "the grid did not follow the switch: " + darks[i] + " and "
                   + darks[0] + " still show the same ground")
        for (i = 1; i < lights.length; i++)
            verify(String(sw[lights[i]].color) !== String(sw[lights[0]].color),
                   "the grid did not follow the switch: " + lights[i] + " and "
                   + lights[0] + " still show the same ground")

        h.panel.close()
    }

    function test_the_colour_switch_shows_the_stored_setting() {
        prefs.tintedGreys = true
        var h = openPanel(1280, 1200)
        var toggle = findByName(h.panel.contentItem, "settingsTintedToggle")
        verify(toggle && toggle.checked, "a stored on came back off")
        var rainbow = findByName(toggle, "toggleRainbow")
        verify(rainbow && rainbow.visible,
               "the switch is on and its track is not a rainbow")
        h.panel.close()

        prefs.tintedGreys = false
        var h2 = openPanel(1280, 1200)
        var toggle2 = findByName(h2.panel.contentItem, "settingsTintedToggle")
        verify(toggle2 && !toggle2.checked, "a stored off came back on")
        var rainbow2 = findByName(toggle2, "toggleRainbow")
        verify(rainbow2 && !rainbow2.visible,
               "the switch is off and still painted as a rainbow")
        h2.panel.close()
    }

    // The track is a rainbow, and it holds still: the gradient is static,
    // and an animation on it fails this.
    function test_the_rainbow_is_static_and_has_no_frame_around_it() {
        app.setReducedMotionForTest(false)
        prefs.tintedGreys = true

        var h = openPanel(1280, 1200)
        var toggle = findByName(h.panel.contentItem, "settingsTintedToggle")
        verify(toggle && toggle.checked)
        var rainbow = findByName(toggle, "toggleRainbow")
        verify(rainbow && rainbow.visible)

        // Seven stops round the wheel, the first and the last on the same hue so
        // the strip joins up, which leaves six distinct colours.
        verify(rainbow.gradient, "the rainbow track carries no gradient")
        compare(rainbow.gradient.stops.length, 7, "the rainbow has the wrong number of stops")
        var distinct = {}
        for (var k = 0; k < 7; k++)
            distinct[String(rainbow.gradient.stops[k].color)] = true
        compare(Object.keys(distinct).length, 6,
                "the rainbow is " + Object.keys(distinct).length + " colours")

        // Still. Sampled over a span long enough to catch a slow animation.
        var before = []
        for (var b = 0; b < 7; b++) before.push(String(rainbow.gradient.stops[b].color))
        wait(400)
        for (var c = 0; c < 7; c++)
            compare(String(rainbow.gradient.stops[c].color), before[c],
                    "stop " + c + " moved: the rainbow is animating again")

        // No solid ring around it: the gradient is the control. Focus is the
        // one exception.
        var track = rainbow.parent
        verify(!toggle.activeFocus, "this half of the case assumes the toggle is not focused")
        compare(track.border.width, 0,
                "the rainbow switch has a " + track.border.width + "px frame around it")

        clickItem(h.panel, toggle)
        verify(!rainbow.visible, "the switch is off and still a rainbow")
        // Off, it is an ordinary toggle again and gets its ordinary border back.
        compare(track.border.width, 1,
                "switched off, the toggle lost the border every other toggle has")

        // No other switch in the panel is painted as a rainbow.
        prefs.theme = "sea"
        var black = findByName(h.panel.contentItem, "settingsOledToggle")
        verify(black && black.visible)
        var strayRainbow = findByName(black, "toggleRainbow")
        verify(strayRainbow && !strayRainbow.visible,
               "the pure-black switch is painted as a rainbow")

        h.panel.close()
    }

    // The rainbow is identical under reduced motion: the reduced-motion path
    // must not take the colour away.
    function test_reduced_motion_keeps_the_rainbow_exactly_as_it_is() {
        prefs.tintedGreys = true

        app.setReducedMotionForTest(false)
        var normal = openPanel(1280, 1200)
        var t1 = findByName(normal.panel.contentItem, "settingsTintedToggle")
        var r1 = findByName(t1, "toggleRainbow")
        verify(r1 && r1.visible)
        var stops = []
        for (var i = 0; i < 7; i++) stops.push(String(r1.gradient.stops[i].color))
        normal.panel.close()

        app.setReducedMotionForTest(true)
        var h = openPanel(1280, 1200)
        var toggle = findByName(h.panel.contentItem, "settingsTintedToggle")
        verify(toggle && toggle.checked)
        var rainbow = findByName(toggle, "toggleRainbow")
        verify(rainbow && rainbow.visible,
               "reduced motion removed the rainbow instead of leaving it alone")
        for (var j = 0; j < 7; j++)
            compare(String(rainbow.gradient.stops[j].color), stops[j],
                    "stop " + j + " differs under reduced motion")

        h.panel.close()
    }

    // Both switches move the grounds, so the resulting page must not depend
    // on which was flipped first. Driven through the two controls here; the
    // palette-level proof is in tests/tst_theme.cpp.
    function test_the_two_switches_land_on_the_same_page_in_either_order() {
        prefs.theme = "pine"
        prefs.oledBlack = false
        prefs.tintedGreys = false

        var h = openPanel(1280, 1200)
        var black  = findByName(h.panel.contentItem, "settingsOledToggle")
        var colour = findByName(h.panel.contentItem, "settingsTintedToggle")
        verify(black && black.visible && colour && colour.visible)

        clickItem(h.panel, black)
        clickItem(h.panel, colour)
        verify(prefs.oledBlack && prefs.tintedGreys)
        var blackFirstBg = probe.color.toString()
        var blackFirstSurface = surfaceProbe.color.toString()
        compare(blackFirstBg, "#000000", "the page is not black with the switch on")

        // All the way back out, then the other way round.
        clickItem(h.panel, colour)
        clickItem(h.panel, black)
        verify(!prefs.oledBlack && !prefs.tintedGreys)

        clickItem(h.panel, colour)
        clickItem(h.panel, black)
        verify(prefs.oledBlack && prefs.tintedGreys)
        compare(probe.color.toString(), blackFirstBg,
                "the page depends on which switch was flipped first")
        compare(surfaceProbe.color.toString(), blackFirstSurface,
                "the step above the page depends on which switch was flipped first")

        // The pure-black switch still reaches black over the neutral ramp, the
        // state that would break if the two transforms were applied in the other
        // order.
        clickItem(h.panel, colour)
        verify(prefs.oledBlack && !prefs.tintedGreys)
        compare(probe.color.toString(), "#000000",
                "the pure-black switch stopped working on the neutral greys")

        h.panel.close()
    }

    // ── 2. the language picker ───────────────────────────────────────────

    function test_three_languages_are_offered() {
        var h = openPanel(1280, 1200)
        var combo = findByName(h.panel.contentItem, "settingsLanguage")
        verify(combo, "there is no language picker")
        compare(valuesOf(combo.options).join(","), "system,en,de",
                "the language picker offers " + valuesOf(combo.options).join(","))
        compare(combo.count, 3)
        // It shows the current setting.
        compare(combo.currentIndex, 0, "\"system\" is the stored language")
        h.panel.close()
    }

    function test_picking_a_language_data() {
        return [
            { tag: "english", index: 1, code: "en" },
            { tag: "deutsch", index: 2, code: "de" }
        ]
    }

    // activated() is the signal a click on a ComboBox entry emits; the popup
    // list is drawn in its own window, which an offscreen click cannot reach.
    function test_picking_a_language(row) {
        var h = openPanel(1280, 1200)
        var combo = findByName(h.panel.contentItem, "settingsLanguage")
        combo.activated(row.index)
        settle(h.panel.contentItem)
        compare(prefs.language, row.code, "the language picker did not write prefs.language")
        h.panel.close()
    }

    function test_language_picker_shows_the_stored_language() {
        prefs.language = "de"
        var h = openPanel(1280, 1200)
        var combo = findByName(h.panel.contentItem, "settingsLanguage")
        compare(combo.currentIndex, 2, "the picker does not show the stored language")
        h.panel.close()
    }

    // ── 3. the close button ──────────────────────────────────────────────

    // The switch for what closing the window does has to read the setting
    // and write it back.
    function test_close_button_switch_writes_prefs() {
        var h = openPanel(1280, 1200)
        var toggle = findByName(h.panel.contentItem, "settingsQuitOnCloseToggle")
        verify(toggle, "there is no switch for what the close button does")
        verify(!toggle.checked,
               "closing the window should minimise to the tray by default")

        clickItem(h.panel, toggle)
        compare(prefs.quitOnClose, true,
                "switching it on must set prefs.quitOnClose")
        verify(toggle.checked, "the switch did not follow the setting")

        clickItem(h.panel, toggle)
        compare(prefs.quitOnClose, false,
                "switching it back off must clear prefs.quitOnClose")
        verify(!toggle.checked)

        h.panel.close()
    }

    function test_close_button_switch_shows_the_stored_setting() {
        prefs.quitOnClose = true
        var h = openPanel(1280, 1200)
        var toggle = findByName(h.panel.contentItem, "settingsQuitOnCloseToggle")
        verify(toggle.checked, "the switch does not show the stored setting")
        h.panel.close()
    }

    // The switch lives in its own section. Performance is about the renderer.
    function test_the_close_button_has_its_own_section() {
        var h = openPanel(1280, 1200)
        var sections = collectByName(h.panel.contentItem, "settingsSection", [])
        var window = null
        for (var i = 0; i < sections.length; ++i)
            if (sections[i].key === "window") window = sections[i]
        verify(window, "there is no window section")
        verify(window.heading.length > 0, "the window section has no heading")

        var toggle = findByName(h.panel.contentItem, "settingsQuitOnCloseToggle")
        verify(toggle, "there is no switch for what the close button does")
        verify(findByName(window, "settingsQuitOnCloseToggle") === toggle,
               "the close button switch is somewhere other than the window section")

        h.panel.close()
    }

    // With no tray icon a close quits whatever the switch says, so the note
    // has to say so. The row is never hidden: the setting is remembered and
    // starts working once a tray turns up, which can be long after login.
    function test_the_close_button_note_covers_the_no_tray_case() {
        var h = openPanel(1280, 1200)
        var note = findByName(h.panel.contentItem, "settingsQuitOnCloseNote")
        verify(note, "the close button switch has no explanatory line")
        verify(note.visible, "the note is hidden until something is hovered")
        var said = note.text.toLowerCase()
        verify(said.indexOf("tray") !== -1,
               "the note says \"" + note.text + "\", which never mentions the tray")
        verify(said.indexOf("no tray") !== -1,
               "the note says \"" + note.text
               + "\", which does not say what happens with no tray at all")

        var toggle = findByName(h.panel.contentItem, "settingsQuitOnCloseToggle")
        var flick = scrollerOf(h.panel)
        verify(Math.abs(note.mapToItem(flick.contentItem, 0, 0).y
                        - toggle.mapToItem(flick.contentItem, 0, 0).y) < 80,
               "the note is nowhere near the switch it belongs to")
        h.panel.close()
    }

    // The panel is taller than any window it fits in, so scrolling to the
    // end and the close button in the pinned header are checked with this
    // section in place.
    function test_the_panel_still_scrolls_and_closes_with_the_window_section() {
        var h = openPanel(minWindowW, minWindowH)
        var flick = scrollerOf(h.panel)
        verify(flick.contentHeight > flick.height,
               "the panel content is " + flick.contentHeight.toFixed(0)
               + "px in a " + flick.height.toFixed(0) + "px viewport, so nothing scrolls")

        var toggle = findByName(h.panel.contentItem, "settingsQuitOnCloseToggle")
        scrollTo(h.panel, toggle)
        var y = toggle.mapToItem(flick, 0, 0).y
        verify(y >= -1 && y + toggle.height <= flick.height + 1,
               "the close button switch is still off the viewport at y=" + y.toFixed(0))

        scrollToEnd(h.panel)
        var close = findByName(h.panel.contentItem, "settingsClose")
        var at = close.mapToItem(h.panel.contentItem, close.width / 2, close.height / 2)
        mouseClick(h.panel.contentItem, at.x, at.y)
        tryVerify(function () { return !h.panel.visible }, 2000,
                  "the panel would not close once the window section was in it")
    }


    // ── 4. the audio output picker ───────────────────────────────────────

    // Devices come and go, so the list is read again every time the panel
    // is opened.
    function test_audio_devices_are_reread_on_open() {
        var h = openPanel(1280, 1200)
        var first = audioStub.reads
        verify(first >= 1, "the panel never asked for the audio device list")

        h.panel.close()
        settle(h.host.contentItem)

        // A device disappears while the panel is shut.
        audioStub.devices = [
            { id: "",   label: "System default",   isDefault: false },
            { id: "d1", label: "Built-in Analog",  isDefault: true  }
        ]
        h.host.sidebar.openSettings()
        settle(h.host.contentItem)

        verify(audioStub.reads > first,
               "re-opening the panel did not re-read the device list")
        var combo = findByName(h.panel.contentItem, "settingsAudioDevice")
        compare(combo.count, 2, "the picker still shows the device that went away")
        h.panel.close()
    }

    function test_system_default_is_first_and_carries_an_empty_id() {
        var h = openPanel(1280, 1200)
        var combo = findByName(h.panel.contentItem, "settingsAudioDevice")
        verify(combo, "there is no audio output picker")
        compare(combo.count, 3)
        compare(combo.options[0].value, "", "the first entry must carry an empty id")
        compare(combo.options[0].label, "System default",
                "\"System default\" is not the first entry")
        h.panel.close()
    }

    // isDefault says which real device the sentinel resolves to, and the
    // panel has to name it.
    function test_system_default_names_the_device_it_resolves_to() {
        var h = openPanel(1280, 1200)
        var note = findByName(h.panel.contentItem, "settingsAudioDefaultNote")
        verify(note && note.visible, "nothing says what \"System default\" resolves to")
        verify(note.text.indexOf("Scarlett 2i2 USB") !== -1,
               "the note says \"" + note.text + "\"")
        h.panel.close()
    }

    function test_picking_a_device_writes_prefs() {
        var h = openPanel(1280, 1200)
        var combo = findByName(h.panel.contentItem, "settingsAudioDevice")
        combo.activated(2)
        settle(h.panel.contentItem)
        compare(prefs.audioDevice, "d2", "the picker did not write prefs.audioDevice")
        // And back to following the system.
        combo.activated(0)
        settle(h.panel.contentItem)
        compare(prefs.audioDevice, "", "\"System default\" must clear the setting")
        h.panel.close()
    }

    // ── 5. hardware acceleration ─────────────────────────────────────────

    // prefs.softwareRendering is inverted: true means draw on the CPU, so the
    // switch is on when the setting is off.
    function test_hardware_acceleration_writes_prefs() {
        var h = openPanel(1280, 1200)
        var toggle = findByName(h.panel.contentItem, "settingsHwAccelToggle")
        verify(toggle, "there is no hardware acceleration toggle")
        verify(toggle.checked, "hardware acceleration should read as on by default")

        clickItem(h.panel, toggle)
        compare(prefs.softwareRendering, true,
                "switching hardware acceleration off must set softwareRendering")
        verify(!toggle.checked, "the toggle did not follow the setting")

        clickItem(h.panel, toggle)
        compare(prefs.softwareRendering, false,
                "switching it back on must clear softwareRendering")
        verify(toggle.checked)

        h.panel.close()
    }

    // Qt picks the scene graph backend once at startup, so the note is always
    // visible in the panel.
    function test_restart_note_is_always_visible() {
        var h = openPanel(1280, 1200)
        var note = findByName(h.panel.contentItem, "settingsRestartNote")
        verify(note, "there is no restart note next to the toggle")
        verify(note.visible, "the restart note is hidden until something is hovered")
        verify(note.text.length > 0)
        verify(note.text.toLowerCase().indexOf("restart") !== -1,
               "the note says \"" + note.text + "\", which does not mention a restart")
        // Next to the control, asserted as the order of rows in the card. A pixel
        // bound would depend on the Controls style: the row between holds a stock
        // Slider, which is taller under Basic (Qt 6.4) than under Fusion.
        var toggle = findByName(h.panel.contentItem, "settingsHwAccelToggle")
        var slider = findByName(h.panel.contentItem, "settingsUiScaleSlider")
        verify(toggle && slider, "the performance controls were not found")
        var card = note.parent
        compare(toggle.parent.parent, card,
                "the restart note is not even in the same card as the toggle")
        var rows = []
        for (var i = 0; i < card.children.length; ++i)
            if (card.children[i].visible) rows.push(card.children[i])
        var ti = rows.indexOf(toggle.parent)
        var si = rows.indexOf(slider.parent)
        var ni = rows.indexOf(note)
        verify(ti >= 0 && si === ti + 1 && ni === si + 1,
               "the card has " + rows.length + " visible rows, with the toggle at "
               + ti + ", interface size at " + si + " and the note at " + ni
               + ": the restart note is nowhere near the toggle it belongs to")
        // And below it.
        var flick = scrollerOf(h.panel)
        verify(note.mapToItem(flick.contentItem, 0, 0).y
               > toggle.mapToItem(flick.contentItem, 0, 0).y,
               "the restart note sits above the toggle it belongs to")
        h.panel.close()
    }

    // ── 6. the update check ──────────────────────────────────────────────

    function test_update_switch_writes_the_setting() {
        var h = openPanel(1280, 1200)
        var toggle = findByName(h.panel.contentItem, "settingsUpdateToggle")
        verify(toggle, "there is no update check switch")
        verify(toggle.checked, "the switch does not follow updateCheck.enabled")

        clickItem(h.panel, toggle)
        compare(updateStub.enabled, false, "the switch did not write updateCheck.enabled")

        clickItem(h.panel, toggle)
        compare(updateStub.enabled, true)
        h.panel.close()
    }

    function test_check_now_calls_the_backend() {
        var h = openPanel(1280, 1200)
        var btn = findByName(h.panel.contentItem, "settingsCheckNowButton")
        verify(btn, "there is no \"Check now\" action")
        clickItem(h.panel, btn)
        compare(updateStub.checkNowCount, 1, "\"Check now\" did not reach checkNow()")
        h.panel.close()
    }

    // ── the header, which does not scroll ────────────────────────────────
    // The header sits outside the ScrollView. A header laid over a scrolling
    // item would let the content show through at its edges.

    // How far the panel can scroll, and a scroll to the bottom of it.
    function scrollToEnd(panel) {
        var flick = scrollerOf(panel)
        flick.contentY = Math.max(0, flick.contentHeight - flick.height)
        settle(panel.contentItem)
        return flick
    }

    function test_the_header_is_outside_the_scroll_area() {
        var h = openPanel(1280, 1200)
        var header = findByName(h.panel.contentItem, "settingsHeader")
        verify(header, "the panel has no header")
        var sv = findByName(h.panel.contentItem, "settingsScroll")
        verify(sv, "the panel has no scroll view")

        // Not a descendant of the ScrollView.
        var p = header.parent
        while (p) {
            verify(p !== sv, "the header is still inside the ScrollView")
            p = p.parent
        }

        // And the content starts below it.
        var headerBottom = header.mapToItem(h.panel.contentItem, 0, header.height).y
        var scrollTop = sv.mapToItem(h.panel.contentItem, 0, 0).y
        verify(scrollTop >= headerBottom - 0.5,
               "the scroll area starts at " + scrollTop.toFixed(1)
               + ", above the header's bottom edge at " + headerBottom.toFixed(1))
        h.panel.close()
    }

    function test_the_header_stays_put_while_the_panel_scrolls() {
        var h = openPanel(1280, 800)
        var header = findByName(h.panel.contentItem, "settingsHeader")
        var before = header.mapToItem(h.panel.contentItem, 0, 0).y

        var flick = scrollToEnd(h.panel)
        verify(flick.contentY > 1, "the panel did not scroll, so this proves nothing")

        var after = header.mapToItem(h.panel.contentItem, 0, 0).y
        compare(after, before, "the header scrolled away with the content")
        verify(header.visible, "the header went off screen")
        h.panel.close()
    }

    function test_the_close_button_still_closes_from_the_bottom() {
        var h = openPanel(1280, 800)
        scrollToEnd(h.panel)
        var close = findByName(h.panel.contentItem, "settingsClose")
        verify(close, "the header has no close button")
        var at = close.mapToItem(h.panel.contentItem, close.width / 2, close.height / 2)
        mouseClick(h.panel.contentItem, Math.round(at.x), Math.round(at.y))
        tryVerify(function () { return !h.panel.visible }, 2000,
                  "the close button in the pinned header did not close the panel")
    }

    function test_escape_still_closes_and_the_panel_reopens() {
        var h = openPanel(1280, 800)
        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !h.panel.visible }, 2000,
                  "Escape no longer closes the panel")

        h.host.sidebar.openSettings()
        tryVerify(function () { return h.panel.visible }, 2000, "the panel did not reopen")
        h.panel.close()
    }

    // A fixed header takes vertical room off the scroll area, so the clamp is
    // re-checked at the window minimum: the panel still fits and there is
    // still something left to scroll in.
    function test_the_panel_still_fits_the_minimum_window() {
        var h = openPanel(minWindowW, minWindowH)
        verify(h.panel.width <= minWindowW - popupInset + 0.5,
               "the popup is " + h.panel.width + "px wide in a " + minWindowW + "px window")
        verify(h.panel.height <= minWindowH - popupInset + 0.5,
               "the popup is " + h.panel.height + "px tall in a " + minWindowH + "px window")

        var header = findByName(h.panel.contentItem, "settingsHeader")
        var flick = scrollerOf(h.panel)
        verify(header.height > 0 && header.height < h.panel.height / 3,
               "the header takes " + header.height + "px of a "
               + h.panel.height + "px panel")
        verify(flick.height > 100,
               "the header left only " + flick.height.toFixed(1) + "px to scroll in")
        h.panel.close()
    }

    // The scrollbar gutter belongs to the scrolling area and must not run up
    // past the header.
    function test_the_scrollbar_runs_alongside_the_scrolling_area_only() {
        var h = openPanel(1280, 800)
        var bar = findByName(h.panel.contentItem, "settingsScrollBar")
        verify(bar, "the panel has no scrollbar")
        var header = findByName(h.panel.contentItem, "settingsHeader")

        var barTop = bar.mapToItem(h.panel.contentItem, 0, 0).y
        var headerBottom = header.mapToItem(h.panel.contentItem, 0, header.height).y
        verify(barTop >= headerBottom - 0.5,
               "the scrollbar starts at " + barTop.toFixed(1)
               + ", beside the header rather than beside the content")
        h.panel.close()
    }

    // The top edge of the scroll area fades once something has scrolled
    // under it, as the bottom edge does, so a half-cut line reads as more
    // content above.
    function test_the_top_edge_fades_only_once_something_has_scrolled() {
        var h = openPanel(1280, 800)
        var fade = findByName(h.panel.contentItem, "settingsTopFade")
        verify(fade, "the scroll area has no top fade")
        verify(!fade.visible, "the top of an unscrolled panel is not cut off by anything")

        scrollToEnd(h.panel)
        verify(fade.visible, "nothing marks the content running under the header")

        var flick = scrollerOf(h.panel)
        flick.contentY = 0
        settle(h.panel.contentItem)
        verify(!fade.visible, "the fade stayed behind at the top of the travel")
        h.panel.close()
    }

    // ── the order of the panel ───────────────────────────────────────────

    // Top to bottom, by where the sections land. The shortcuts sit above the
    // privacy notice, which is long prose and the natural end of the panel.
    // Asserted as the whole list, so no section can be moved quietly.
    readonly property string sectionOrder:
        "account,appearance,window,playback,performance,updates,feedback,shortcuts,privacy"

    function test_sections_are_in_order() {
        var h = openPanel(1280, 1200)
        var sections = collectByName(h.panel.contentItem, "settingsSection", [])
        compare(sections.length, sectionOrder.split(",").length,
                "the panel has " + sections.length + " sections")

        var placed = []
        for (var i = 0; i < sections.length; ++i) {
            verify(sections[i].key.length > 0,
                   "a section with the heading \"" + sections[i].heading
                   + "\" has no key for the order assertion")
            placed.push({ key: sections[i].key,
                          y: sections[i].mapToItem(h.panel.contentItem, 0, 0).y })
        }
        placed.sort(function (a, b) { return a.y - b.y })

        var got = []
        for (i = 0; i < placed.length; ++i) got.push(placed[i].key)
        compare(got.join(","), sectionOrder, "the Settings sections are in the wrong order")

        h.panel.close()
    }

    function test_shortcuts_sit_above_the_privacy_note() {
        var h = openPanel(1280, 1200)
        var shortcuts = null, privacy = null
        var sections = collectByName(h.panel.contentItem, "settingsSection", [])
        for (var i = 0; i < sections.length; ++i) {
            if (sections[i].key === "shortcuts") shortcuts = sections[i]
            if (sections[i].key === "privacy")   privacy   = sections[i]
        }
        verify(shortcuts, "there is no keyboard shortcuts section")
        verify(privacy, "there is no privacy section")

        var sy = shortcuts.mapToItem(h.panel.contentItem, 0, 0).y
        var py = privacy.mapToItem(h.panel.contentItem, 0, 0).y
        verify(sy + shortcuts.height <= py + 1,
               "the shortcuts table starts at y=" + sy.toFixed(0)
               + " and the privacy note at y=" + py.toFixed(0)
               + "; the shortcuts belong above the note, clear of it")

        // And the note really is the end of the panel.
        for (i = 0; i < sections.length; ++i)
            verify(sections[i] === privacy
                   || sections[i].mapToItem(h.panel.contentItem, 0, 0).y < py,
                   "\"" + sections[i].heading + "\" sits below the privacy note")

        h.panel.close()
    }

    // ── the two ways out ─────────────────────────────────────────────────
    // The panel can open a prefilled GitHub issue and a prefilled email. What
    // is asserted is the URL each button hands to app.openUrl(). Nothing in
    // this file opens a browser, a mail client or a connection.

    readonly property string feedbackMailbox: "tidal-wave@linu.li"
    readonly property string issuePrefix:
        "https://github.com/immineal/tidal-wave/issues/new?"

    function feedbackSection(panel) {
        var sections = collectByName(panel.contentItem, "settingsSection", [])
        for (var i = 0; i < sections.length; ++i)
            if (sections[i].key === "feedback") return sections[i]
        return null
    }

    // The value of one query parameter, still encoded.
    function paramOf(url, name) {
        var parts = url.substring(url.indexOf("?") + 1).split("&")
        for (var i = 0; i < parts.length; ++i) {
            var eq = parts[i].indexOf("=")
            if (parts[i].substring(0, eq) === name)
                return parts[i].substring(eq + 1)
        }
        return null
    }

    // The URL the last click handed to app.openUrl(), or an empty string if
    // it handed none.
    function urlFromClick(panel, item) {
        var before = app.openedUrlsForTest().length
        clickItem(panel, item)
        var after = app.openedUrlsForTest()
        verify(after.length === before + 1,
               "the button handed " + (after.length - before)
               + " URLs to app.openUrl(); exactly one was expected")
        return app.lastOpenedUrlForTest()
    }

    // Both routes live in a section of their own, between Updates and the
    // shortcuts table.
    function test_the_feedback_section_sits_between_updates_and_the_shortcuts() {
        var h = openPanel(1280, 1200)
        var sections = collectByName(h.panel.contentItem, "settingsSection", [])
        var y = {}
        for (var i = 0; i < sections.length; ++i)
            y[sections[i].key] = sections[i].mapToItem(h.panel.contentItem, 0, 0).y

        var feedback = feedbackSection(h.panel)
        verify(feedback, "there is no feedback section")
        verify(feedback.heading.length > 0, "the feedback section has no heading")
        verify(y["updates"] < y["feedback"],
               "the feedback section sits above Updates, at y=" + y["feedback"].toFixed(0))
        verify(y["feedback"] < y["shortcuts"],
               "the feedback section sits below the shortcuts table, at y="
               + y["feedback"].toFixed(0))
        h.panel.close()
    }

    // Side by side in one row, and both reachable: visible, inside the card,
    // scrollable into the viewport, and on the tab ring.
    function test_both_feedback_rows_are_reachable() {
        var h = openPanel(minWindowW, minWindowH)
        var section = feedbackSection(h.panel)
        verify(section, "there is no feedback section")

        var names = ["settingsIssueButton", "settingsEmailButton"]
        var flick = scrollerOf(h.panel)
        var seen = []
        for (var i = 0; i < names.length; ++i) {
            var btn = findByName(section, names[i])
            verify(btn, names[i] + " is not in the feedback section")
            verify(btn.visible, names[i] + " is hidden")
            verify(btn.width > 0 && btn.height > 0,
                   names[i] + " is " + btn.width + "x" + btn.height)
            verify(btn.activeFocusOnTab,
                   names[i] + " cannot be reached with the keyboard")

            scrollTo(h.panel, btn)
            var y = btn.mapToItem(flick, 0, 0).y
            verify(y >= -1 && y + btn.height <= flick.height + 1,
                   names[i] + " will not scroll into the viewport; it sits at y="
                   + y.toFixed(0))
            seen.push({ x: btn.mapToItem(section, 0, 0).x,
                        y: btn.mapToItem(section, 0, 0).y })
        }
        // Side by side: same line, one after the other.
        compare(seen[0].y.toFixed(0), seen[1].y.toFixed(0),
                "the two feedback buttons are stacked, not side by side")
        verify(seen[0].x < seen[1].x,
               "the two feedback buttons do not run left to right: the issue "
               + "button is at x=" + seen[0].x.toFixed(0) + " and the email "
               + "button at x=" + seen[1].x.toFixed(0))
        h.panel.close()
    }

    // The GitHub route: the repository slug, and a template prefilled with
    // the version details.
    function test_the_github_route_opens_a_prefilled_issue() {
        var h = openPanel(1280, 1200)
        var btn = findByName(h.panel.contentItem, "settingsIssueButton")
        verify(btn, "there is no \"open an issue\" action")
        var url = urlFromClick(h.panel, btn)

        verify(url.indexOf(issuePrefix) === 0,
               "the issue URL is \"" + url + "\", which does not start with "
               + issuePrefix)

        // Percent-encoded. A raw space or newline makes an unusable URL, and a
        // raw hash, of which the Markdown body has several, cuts everything after
        // it off as a fragment.
        verify(url.indexOf(" ") === -1, "the issue URL carries a raw space: " + url)
        verify(url.indexOf("\n") === -1, "the issue URL carries a raw newline")
        verify(url.indexOf("#") === -1,
               "the issue URL carries a raw \"#\", so GitHub sees everything "
               + "after it as a fragment: " + url)
        verify(url.indexOf("%20") !== -1, "nothing in the issue URL is encoded")

        var title = paramOf(url, "title")
        var body = paramOf(url, "body")
        verify(title && title.length > 0, "the issue URL prefills no title")
        verify(body && body.length > 0, "the issue URL prefills no body")

        var version = Feedback.appVersion()
        verify(version.length > 0, "Feedback reports no app version at all")
        verify(decodeURIComponent(title).indexOf(version) !== -1,
               "the issue title does not name the version: "
               + decodeURIComponent(title))

        var text = decodeURIComponent(body)
        var mustSay = [version, Feedback.operatingSystem(),
                       Feedback.qtCompiledVersion(), Feedback.qtRuntimeVersion()]
        for (var i = 0; i < mustSay.length; ++i)
            verify(text.indexOf(mustSay[i]) !== -1,
                   "the issue body never mentions \"" + mustSay[i] + "\":\n" + text)

        // Compiled against and running now are two different questions. Both
        // labels have to be there, whether or not the two numbers are equal on
        // this machine.
        verify(text.indexOf("compiled against") !== -1,
               "the issue body does not say which Qt the build was compiled "
               + "against:\n" + text)
        verify(text.indexOf("running now") !== -1,
               "the issue body does not say which Qt is running:\n" + text)

        // And the two blanks the person filling it in is meant to answer.
        verify(text.indexOf("What happened") !== -1,
               "the issue body asks nothing about what happened:\n" + text)
        verify(text.indexOf("expected") !== -1,
               "the issue body asks nothing about what was expected:\n" + text)

        h.panel.close()
    }

    // The mail route: the project's own address and a subject naming the app
    // and the version. No body and no credential: the app never signs in to
    // that mailbox.
    function test_the_email_route_opens_a_prefilled_draft() {
        var h = openPanel(1280, 1200)
        var btn = findByName(h.panel.contentItem, "settingsEmailButton")
        verify(btn, "there is no \"send an email\" action")
        var url = urlFromClick(h.panel, btn)

        verify(url.indexOf("mailto:" + feedbackMailbox + "?") === 0,
               "the mail URL is \"" + url + "\"; it has to be a mailto: to "
               + feedbackMailbox)

        var subject = paramOf(url, "subject")
        verify(subject && subject.length > 0, "the mail URL prefills no subject")
        var text = decodeURIComponent(subject)
        verify(text.indexOf("Tidal Wave") !== -1,
               "the mail subject does not name the app: " + text)
        verify(text.indexOf(Feedback.appVersion()) !== -1,
               "the mail subject does not name the version: " + text)

        verify(url.indexOf(" ") === -1, "the mail URL carries a raw space: " + url)
        verify(url.indexOf("%20") !== -1, "nothing in the mail URL is encoded")
        h.panel.close()
    }

    // Every address the feedback feature puts in front of a user, or into a
    // URL, has to be the project mailbox.
    function test_only_the_project_mailbox_is_ever_named() {
        var h = openPanel(1280, 1200)
        compare(Feedback.mailAddress(), feedbackMailbox,
                "Feedback hands out " + Feedback.mailAddress())

        var haystack = [Feedback.mailUrl(), Feedback.issueUrl(),
                        decodeURIComponent(paramOf(Feedback.issueUrl(), "body"))]

        // Everything the panel shows: the address is printed in the feedback
        // rows and in the privacy block.
        var texts = collectTexts(h.panel.contentItem, [])
        for (var i = 0; i < texts.length; ++i) haystack.push(texts[i].text)

        for (var j = 0; j < haystack.length; ++j) {
            var s = haystack[j]
            var at = s.indexOf("@")
            while (at !== -1) {
                verify(s.substring(at - 10, at + 8) === feedbackMailbox,
                       "an address other than " + feedbackMailbox
                       + " is in front of the user: ..."
                       + s.substring(Math.max(0, at - 30), at + 30) + "...")
                at = s.indexOf("@", at + 1)
            }
            verify(s.indexOf("gmail") === -1,
                   "a personal address leaked into the app: " + s)
        }
        h.panel.close()
    }

    // The privacy block names every destination and says what each one gets,
    // so it has to cover the feedback routes accurately. The app sends
    // nothing: it hands a URL to a program the user chose.
    function test_the_privacy_block_covers_the_two_feedback_routes() {
        var h = openPanel(1280, 1200)
        var parts = collectByName(h.panel.contentItem, "settingsPrivacyText", [])
        var all = ""
        for (var i = 0; i < parts.length; i++) all += parts[i].text + "\n"

        // Only wording specific to the feedback paragraph, so a match proves
        // that paragraph is there.
        var mustSay = [
            // Which program gets handed the URL...
            "mail client",
            // ...that the app itself is not the one talking...
            "sends nothing",
            // ...where the words end up, and that one of the two is public...
            feedbackMailbox, "public",
            // ...that nothing moves until the user moves it...
            "until you send it",
            // ...and what is *not* in the part the user did not write.
            "nothing about what you have played"
        ]
        for (var j = 0; j < mustSay.length; j++)
            verify(all.indexOf(mustSay[j]) !== -1,
                   "the privacy block never says \"" + mustSay[j]
                   + "\" about the feedback routes")
        h.panel.close()
    }

    // ── 7. the privacy block ─────────────────────────────────────────────

    function test_privacy_text_is_present() {
        var h = openPanel(1280, 1200)
        var parts = collectByName(h.panel.contentItem, "settingsPrivacyText", [])
        verify(parts.length >= 5,
               "the privacy block is " + parts.length + " paragraphs; the approved text is five")

        var all = ""
        for (var i = 0; i < parts.length; i++) {
            verify(parts[i].visible, "a privacy paragraph is hidden")
            // A paragraph that neither wraps nor elides in a 480px panel is a
            // paragraph with its tail cut off.
            verify(parts[i].wrapMode !== Text.NoWrap,
                   "a privacy paragraph does not wrap")
            all += parts[i].text + "\n"
        }

        var mustSay = ["no analytics", "no telemetry", "auth.tidal.com", "api.tidal.com",
                       "resources.tidal.com", "mDNS", "api.github.com", "IP address",
                       "tokens", "switched off above", "release page", "README"]
        for (var j = 0; j < mustSay.length; j++)
            verify(all.indexOf(mustSay[j]) !== -1,
                   "the privacy text never mentions \"" + mustSay[j] + "\"")

        h.panel.close()
    }

    // The panel is longer than any window it fits in, so the privacy block
    // has to be reachable by scrolling.
    function test_privacy_text_scrolls_into_view() {
        var h = openPanel(minWindowW, minWindowH)
        var flick = scrollerOf(h.panel)
        verify(flick.contentHeight > flick.height,
               "the panel content is " + flick.contentHeight.toFixed(0)
               + "px in a " + flick.height.toFixed(0) + "px viewport, so nothing scrolls")

        var parts = collectByName(h.panel.contentItem, "settingsPrivacyText", [])
        verify(parts.length > 0)
        var last = parts[parts.length - 1]

        scrollTo(h.panel, last)
        verify(flick.contentY > 0, "the panel did not scroll")
        var y = last.mapToItem(flick, 0, 0).y
        verify(y >= -1 && y + last.height <= flick.height + 1,
               "the last privacy paragraph is still off the viewport at y=" + y.toFixed(0))

        h.panel.close()
    }

    // ── the popup still fits ─────────────────────────────────────────────

    function test_popup_fits_data() {
        var rows = []
        var widths = [640, 820, 960, 1280]
        for (var i = 0; i < widths.length; i++) {
            rows.push({ tag: widths[i] + "x600",  w: widths[i], h: 600  })
            rows.push({ tag: widths[i] + "x1200", w: widths[i], h: 1200 })
        }
        return rows
    }

    // The popup is clamped to the overlay, whatever its content's height.
    function test_popup_fits(row) {
        var h = openPanel(row.w, row.h)
        var popup = h.panel

        // Sized against the window, never against the sidebar it is declared
        // inside.
        compare(Math.round(popup.width), Math.min(480, row.w - popupInset),
                "popup width in a " + row.tag + " window")
        compare(Math.round(popup.height), Math.min(640, row.h - popupInset),
                "popup height in a " + row.tag + " window")

        verify(popup.width <= row.w - popupInset + 0.5,
               "popup is " + popup.width + "px wide in a " + row.tag + " window")
        verify(popup.height <= row.h - popupInset + 0.5,
               "popup is " + popup.height + "px tall in a " + row.tag + " window")
        verify(popup.x >= -0.5 && popup.y >= -0.5,
               "popup starts off the top or left in a " + row.tag + " window")
        verify(popup.x + popup.width <= row.w + 0.5
                   && popup.y + popup.height <= row.h + 0.5,
               "popup runs off the bottom or right in a " + row.tag + " window")
        popup.close()
    }

    // Nothing inside the panel may run out the side of it: the panel is 480px
    // at its widest and German runs a third longer than the English here.
    function test_panel_content_stays_inside_data() { return test_popup_fits_data() }

    function test_panel_content_stays_inside(row) {
        var h = openPanel(row.w, row.h)
        var faults = collectOverflow(h.panel.contentItem, "SettingsPanel", [])
        verify(faults.length === 0,
               "at " + row.tag + ":\n  " + faults.join("\n  "))
        h.panel.close()
    }

    // Nothing in the panel may be cut off: a label that neither wraps nor
    // elides has no fallback, and German runs longer than the English here.
    function test_no_label_is_cut_off() {
        var h = openPanel(minWindowW, minWindowH)
        var faults = collectClipped(h.panel.contentItem, "SettingsPanel", [])
        verify(faults.length === 0, faults.join("\n  "))
        h.panel.close()
    }

    // ── 8. the filter chip ───────────────────────────────────────────────

    // The chip filters the track kind, and every other string in the app
    // says track.
    function test_library_filter_chip_says_track() {
        var host = createTemporaryObject(sideBarHost, testCase)
        host.width = 1280
        host.height = 700
        host.visible = true
        settle(host.contentItem)

        var chips = collectByName(host.sidebar, "finderChip", [])
        verify(chips.length > 0, "the finder has no chips")
        var trackChip = null
        for (var i = 0; i < chips.length; i++)
            if (chips[i].kind === "track") trackChip = chips[i]
        verify(trackChip, "there is no track filter chip")
        compare(trackChip.label, "Tracks",
                "the chip is labelled \"" + trackChip.label + "\"")
    }
}
