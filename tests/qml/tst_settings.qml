// The Settings panel: the interface for the 0.4.0 features that shipped with
// no way to reach them - theme, language, audio output, hardware acceleration,
// the update check, and the privacy block.
//
// The panel lives in qml/components/SettingsPanel.qml and is reached through
// SideBar.openSettings(), exposed as SideBar.settingsPanel. That is the same
// surface tst_layout_player.qml and tst_sidebar.qml already measure, so it is
// what is hosted here too: extracting the popup out of SideBar.qml must not
// change anything either of those files can see.
//
// Three doubles are built below instead of taken from tests/TestStubs.h,
// because that file is owned by another agent this round and none of the three
// can be read as it stands:
//   * there is no `i18n` stub at all, and the shared QML context never
//     installs one;
//   * StubPlayer has no availableAudioDevices(), so there is nothing for the
//     panel to re-read when it opens;
//   * StubUpdateCheck counts checkNow() in a plain C++ member, which is not a
//     Q_PROPERTY and therefore invisible to QML.
// Each goes in through the property the panel already has for it, exactly the
// way tst_update_prompt.qml hands UpdatePrompt its own `check`.
//
// prefs is the real StubPrefs, because the theme assertions need the object
// ThemePalette is wired to - a double there would let a dead switch pass.

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
    // The popup clamps to the overlay with 32px on every side (SPEC L10).
    readonly property int popupInset: 64

    // Main.qml's sidebar width.
    readonly property int sidebarWidth: 220

    // A real binding on the palette singleton, the same shape every file in
    // the app uses. Picking a theme has to move this, not just prefs.theme.
    Rectangle {
        id: probe
        width: 1; height: 1
        color: Theme.bg
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

    // Player::availableAudioDevices(): the "System default" sentinel first
    // with an empty id, then the real devices, one of them flagged as the one
    // the OS currently treats as default.
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

    // UpdateCheck: the switch and the one invokable behind "Check now".
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
        prefs.theme = "midnight"
        prefs.language = "system"
        prefs.audioDevice = ""
        prefs.softwareRendering = false
        prefs.setSidebarWidthForTest(sidebarWidth)
        app.setReducedMotionForTest(true)
        auth.setUsernameForTest("linus")
        library.setEntriesForTest([])
        pins.setItemsForTest([])

        audioStub.reads = 0
        audioStub.devices = threeDevices()
        updateStub.enabled = true
        updateStub.checkNowCount = 0
    }

    function cleanupTestCase() {
        prefs.theme = "midnight"
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

    // A control further down the panel than the viewport reaches is still
    // "visible", but a click on it would land outside the popup and dismiss
    // it. Bring it into view first.
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

    function valuesOf(options) {
        var out = []
        for (var i = 0; i < options.length; i++) out.push(options[i].value)
        return out
    }

    // ── 1. the theme picker ──────────────────────────────────────────────

    // All six palettes, each with a swatch, so the choice can be made by eye.
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

    // Dark and light are told apart, not mixed into one undifferentiated grid.
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
        compare(dark, 4, "there are four dark palettes")
        compare(light, 2, "there are two light palettes")

        h.panel.close()
    }

    function test_picking_a_theme_data() {
        var rows = []
        var avail = ThemePalette.available()
        for (var i = 0; i < avail.length; i++)
            rows.push({ tag: avail[i].name, name: avail[i].name, dark: avail[i].dark })
        return rows
    }

    // Picking writes prefs.theme, and the live binding on the palette repaints.
    function test_picking_a_theme(row) {
        // Start somewhere else, or picking the current theme is a no-op and
        // the repaint cannot be seen.
        prefs.theme = (row.name === "midnight") ? "forest" : "midnight"

        var h = openPanel(1280, 1200)
        var before = probe.color.toString()

        var tiles = collectByName(h.panel.contentItem, "settingsThemeOption", [])
        var target = null
        for (var i = 0; i < tiles.length; i++)
            if (tiles[i].themeName === row.name) target = tiles[i]
        verify(target, "no tile for " + row.name)

        clickItem(h.panel, target)

        compare(prefs.theme, row.name, "picking " + row.name + " did not write prefs.theme")
        compare(ThemePalette.isDark, row.dark, row.name + " landed on the wrong palette")
        verify(probe.color.toString() !== before,
               "picking " + row.name + " wrote the setting but nothing repainted")
        verify(target.selected, "the picked tile does not read as selected")

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
        // The current setting is what it shows, not whatever came first.
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

    // ── 3. the audio output picker ───────────────────────────────────────

    // Devices come and go, so the list is read again every time the panel is
    // opened rather than once when it is built.
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

    // isDefault says which real device the sentinel currently resolves to, and
    // the panel has to say so rather than leaving "System default" opaque.
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

    // ── 4. hardware acceleration ─────────────────────────────────────────

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

    // Qt picks the scene graph backend once at startup, so the note is part of
    // the panel and not a tooltip someone has to find with the pointer.
    function test_restart_note_is_always_visible() {
        var h = openPanel(1280, 1200)
        var note = findByName(h.panel.contentItem, "settingsRestartNote")
        verify(note, "there is no restart note next to the toggle")
        verify(note.visible, "the restart note is hidden until something is hovered")
        verify(note.text.length > 0)
        verify(note.text.toLowerCase().indexOf("restart") !== -1,
               "the note says \"" + note.text + "\", which does not mention a restart")
        // Next to the control, not somewhere else in the panel.
        var toggle = findByName(h.panel.contentItem, "settingsHwAccelToggle")
        var flick = scrollerOf(h.panel)
        verify(Math.abs(note.mapToItem(flick.contentItem, 0, 0).y
                        - toggle.mapToItem(flick.contentItem, 0, 0).y) < 80,
               "the restart note is nowhere near the toggle it belongs to")
        h.panel.close()
    }

    // ── 5. the update check ──────────────────────────────────────────────

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

    // ── the order of the panel ───────────────────────────────────────────

    // Top to bottom, by where the sections actually land rather than by the
    // order they are declared in. The shortcuts sit above the privacy notice:
    // the notice is long prose and the natural end of the panel, and a
    // reference table buried under it is a reference table nobody finds.
    // Asserted as the whole list, so no section can be moved quietly.
    readonly property string sectionOrder:
        "account,appearance,playback,performance,updates,shortcuts,privacy"

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

    // The same thing said the way the user said it, so the reason survives
    // even if the list above is ever rewritten.
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

    // ── 6. the privacy block ─────────────────────────────────────────────

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

    // The panel is longer than any window it fits in, so the privacy block has
    // to be reachable by scrolling rather than clipped off the bottom.
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

    // L10, restated here because everything above added content to the popup:
    // it is clamped to the overlay, never to its own idea of how tall it is.
    function test_popup_fits(row) {
        var h = openPanel(row.w, row.h)
        var popup = h.panel

        // Sized against the window, not against the 220px sidebar it is
        // declared inside. Reading the sidebar made it 156px wide, which fits
        // every window there is and is still unusable.
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
    // elides has no graceful degradation left, and German runs 20 to 35
    // percent longer than every string written here.
    function test_no_label_is_cut_off() {
        var h = openPanel(minWindowW, minWindowH)
        var faults = collectClipped(h.panel.contentItem, "SettingsPanel", [])
        verify(faults.length === 0, faults.join("\n  "))
        h.panel.close()
    }

    // ── 7. the filter chip ───────────────────────────────────────────────

    // The chip filters kind: "track" and every other string in the app says
    // track, so the chip says track too.
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
