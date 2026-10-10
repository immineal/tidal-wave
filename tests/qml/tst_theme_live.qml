import QtQuick
import QtTest
import TidalWave

// The end-to-end half of the theme contract: changing prefs.theme must repaint
// what QML draws. tests/tst_theme.cpp only calls the free palette functions,
// so it cannot see a ThemePalette singleton the engine built without Prefs.
TestCase {
    id: root
    name: "ThemeLive"
    width: 200; height: 200
    visible: true
    when: windowShown

    Rectangle {
        id: probe
        anchors.fill: parent
        // A real binding on the singleton, the same shape every file in the
        // app uses.
        color: Theme.bg
        Text { id: label; text: "x"; color: Theme.textPrimary }

        // A filled chip, the shape every accent fill in the app has: an
        // accent-coloured ground with its label in accentInk. Read back as a
        // binding, because a binding is what the app draws with.
        Rectangle {
            id: chip
            anchors.bottom: parent.bottom
            width: 60; height: 20
            color: Theme.accent
            Text { id: chipLabel; anchors.centerIn: parent; text: "(7)"; color: Theme.accentInk }
        }

        // The step above the page. Sky's tinted bg is #FFFFFF and so is the
        // neutral light ramp's, so bg alone cannot see the colour switch move on
        // that theme. Surface can, on all six.
        Rectangle {
            id: surfaceProbe
            anchors.centerIn: parent
            width: 10; height: 10
            color: Theme.surface
        }

        // The same for a filled danger button.
        Rectangle {
            anchors.top: parent.top
            width: 60; height: 20
            color: Theme.red
            Text { id: dangerLabel; anchors.centerIn: parent; text: "x"; color: Theme.redInk }
        }
    }

    function init() {
        prefs.theme = "sea"
        // Explicit, because half the file is about what flipping them does.
        prefs.oledBlack = false
        prefs.tintedGreys = false
    }

    function cleanupTestCase() {
        prefs.theme = "sea"
        prefs.oledBlack = false
        prefs.tintedGreys = false
    }

    function test_singleton_sees_prefs() {
        // If this is empty, the engine built its own instance and create() was
        // skipped.
        verify(ThemePalette.current !== undefined)
        verify(Object.keys(ThemePalette.current).length > 0)
    }

    function test_switching_theme_repaints_data() {
        const themes = [
            { name: "pine", dark: true  },
            { name: "rust", dark: true  },
            { name: "sky",  dark: false },
            { name: "sand", dark: false },
            { name: "clay", dark: false },
        ]
        var rows = []
        for (var i = 0; i < themes.length; i++) {
            for (var t = 0; t < 2; t++) {
                rows.push({ tag: themes[i].name + (t === 1 ? " tinted" : " neutral"),
                            name: themes[i].name, dark: themes[i].dark,
                            tinted: t === 1 })
            }
        }
        return rows
    }

    function test_switching_theme_repaints(data) {
        prefs.tintedGreys = data.tinted

        // toString() because a QML colour read into a var is a value type
        // whose identity is not stable to compare against later; the hex is.
        const before = probe.color.toString()
        const beforeAccent = chip.color.toString()

        prefs.theme = data.name

        compare(ThemePalette.isDark, data.dark)

        // The accent always moves. With the greys neutral, the default, the
        // three dark palettes share one ramp and the three light ones another,
        // so the page stays where it is between two of the same mode.
        verify(chip.color.toString() !== beforeAccent,
               data.name + " did not change the accent away from sea's")

        // The page moves with the tinted grounds on, or when the pick crosses
        // from the dark ramp to the light one. Otherwise it must stay.
        if (data.tinted || !data.dark) {
            verify(probe.color.toString() !== before,
                   data.name + " did not change the background away from sea")
        } else {
            compare(probe.color.toString(), before,
                    data.name + " moved the page, which it shares with sea "
                    + "while the greys are neutral")
        }

        // Two palettes can share an ink, so the text is not required to change.
        // What must hold is that the binding tracks the palette.
        compare(label.color.toString(), ThemePalette.current.textPrimary.toString())
        // The binding has to agree with the table.
        compare(probe.color.toString(), ThemePalette.current.bg.toString())
    }

    function test_light_theme_inverts_text() {
        prefs.theme = "sky"
        verify(!ThemePalette.isDark)
        const bgLum = 0.2126 * probe.color.r + 0.7152 * probe.color.g + 0.0722 * probe.color.b
        const fgLum = 0.2126 * label.color.r + 0.7152 * label.color.g + 0.0722 * label.color.b
        verify(bgLum > 0.5, "the sky background is not light")
        verify(fgLum < 0.5, "the sky text is not dark")
    }

    // Every colour token has to arrive in QML as the palette's value. A token
    // whose binding never ran reads as black here.
    function test_every_token_reaches_qml_data() {
        return [
            { tag: "sea",  name: "sea" },
            { tag: "sea in black", name: "sea", oled: true },
            { tag: "sea tinted", name: "sea", tinted: true },
            { tag: "sea tinted in black", name: "sea", oled: true, tinted: true },
            { tag: "sky",  name: "sky" },
            { tag: "sky tinted", name: "sky", tinted: true },
            { tag: "sand", name: "sand" },
            { tag: "clay", name: "clay" },
            { tag: "clay tinted", name: "clay", tinted: true },
        ]
    }

    function test_every_token_reaches_qml(data) {
        prefs.theme = data.name
        prefs.oledBlack = data.oled === true
        prefs.tintedGreys = data.tinted === true
        const palette = ThemePalette.current
        for (const key in palette) {
            if (key === "dark") continue
            verify(Theme[key] !== undefined,
                   data.name + ": Theme." + key + " is undefined")
            compare(Theme[key].toString(), palette[key].toString(),
                    data.name + ": Theme." + key + " does not match the palette")
        }
    }

    // The ink on a filled chip is white in every theme. Read back off a real
    // Rectangle's label, because the C++ table can be right while the binding
    // paints black.
    function test_ink_on_a_fill_is_white_data() {
        return [
            { tag: "sea",  name: "sea" },
            { tag: "pine", name: "pine" },
            { tag: "rust", name: "rust" },
            { tag: "sky",  name: "sky" },
            { tag: "sand", name: "sand" },
            { tag: "clay", name: "clay" },
        ]
    }

    function test_ink_on_a_fill_is_white(data) {
        prefs.theme = data.name
        for (const probe of [{ item: chipLabel, token: "accentInk" },
                             { item: dangerLabel, token: "redInk" }]) {
            const ink = probe.item.color
            verify(ink.r > 0.9 && ink.g > 0.9 && ink.b > 0.9,
                   data.name + ": Theme." + probe.token + " painted "
                   + ink.toString() + ", which is not white")
        }
        // The fill itself has to stay dark enough to hold that white label.
        const fill = chipLabel.parent.color
        const fillLum = 0.2126 * fill.r + 0.7152 * fill.g + 0.0722 * fill.b
        verify(fillLum < 0.5, data.name + ": the accent fill is too light for white ink")
    }

    // ── the pure-black switch ────────────────────────────────────────────
    // The C++ table can be right about the black variant while the app never
    // shows it, so these read the colour back off a bound Rectangle.

    function test_pure_black_repaints_data() {
        return [
            { tag: "sea",  name: "sea" },
            { tag: "pine", name: "pine" },
            { tag: "rust", name: "rust" },
        ]
    }

    function test_pure_black_repaints(data) {
        prefs.theme = data.name
        const before = probe.color.toString()

        prefs.oledBlack = true

        verify(probe.color.toString() !== before,
               data.name + ": the switch wrote the setting and nothing repainted")
        compare(probe.color.toString(), "#000000",
                data.name + ": the page is not actually black")
        compare(probe.color.toString(), ThemePalette.current.bg.toString())
        // The type must not come down with the ground.
        compare(label.color.toString(), ThemePalette.current.textPrimary.toString())
        verify(label.color.r > 0.8, data.name + ": the ink went dark along with the page")

        // And it goes back.
        prefs.oledBlack = false
        verify(probe.color.toString() !== "#000000",
               data.name + ": turning the switch off left the page black")
    }

    // There is nothing to pull down on a light theme, so the setting must
    // leave the window as it is. Settings hides the switch there.
    function test_pure_black_does_nothing_on_a_light_theme_data() {
        return [
            { tag: "sky",  name: "sky" },
            { tag: "sand", name: "sand" },
            { tag: "clay", name: "clay" },
        ]
    }

    function test_pure_black_does_nothing_on_a_light_theme(data) {
        prefs.theme = data.name
        const before = probe.color.toString()
        const ink = label.color.toString()

        prefs.oledBlack = true

        compare(probe.color.toString(), before,
                data.name + ": the switch darkened a light theme")
        compare(label.color.toString(), ink)
        verify(!ThemePalette.isDark, data.name + " stopped being a light theme")
    }

    // ── the colour switch ────────────────────────────────────────────────
    // As above: these read the colour back off Rectangles bound the way the
    // app's are.

    function test_the_colour_switch_repaints_data() {
        return [
            { tag: "sea",  name: "sea" },
            { tag: "pine", name: "pine" },
            { tag: "rust", name: "rust" },
            { tag: "sky",  name: "sky" },
            { tag: "sand", name: "sand" },
            { tag: "clay", name: "clay" },
        ]
    }

    function test_the_colour_switch_repaints(data) {
        prefs.theme = data.name
        prefs.tintedGreys = false
        const before = probe.color.toString()
        const beforeSurface = surfaceProbe.color.toString()
        const accent = chip.color.toString()

        prefs.tintedGreys = true

        verify(surfaceProbe.color.toString() !== beforeSurface,
               data.name + ": the switch wrote the setting and nothing repainted")
        compare(surfaceProbe.color.toString(), ThemePalette.current.surface.toString())
        compare(probe.color.toString(), ThemePalette.current.bg.toString())
        // The accent is the one thing the switch must not touch: it is what
        // distinguishes the six while the greys are shared.
        compare(chip.color.toString(), accent,
                data.name + ": the colour switch moved the accent")
        compare(label.color.toString(), ThemePalette.current.textPrimary.toString())

        // And it goes back.
        prefs.tintedGreys = false
        compare(surfaceProbe.color.toString(), beforeSurface,
                data.name + ": turning the switch off did not come back")
        compare(probe.color.toString(), before)
    }

    // The state the app starts in, read off the window: one ground per mode,
    // six accents.
    function test_the_neutral_state_shares_one_ground_per_mode() {
        prefs.tintedGreys = false
        var accents = {}
        for (const group of [["sea", "pine", "rust"], ["sky", "sand", "clay"]]) {
            var ground = null
            for (const name of group) {
                prefs.theme = name
                if (ground === null) ground = probe.color.toString()
                else compare(probe.color.toString(), ground,
                             name + " does not share its mode's grey ramp")
                const accent = chip.color.toString()
                verify(accents[accent] === undefined,
                       name + " and " + accents[accent] + " paint the same accent, "
                       + "so with the greys shared they are the same theme")
                accents[accent] = name
            }
        }
        // The two ramps differ from each other.
        prefs.theme = "sea"
        const dark = probe.color.toString()
        prefs.theme = "sky"
        verify(probe.color.toString() !== dark, "the dark and light ramps are one ramp")
    }

    function test_unknown_theme_still_paints() {
        prefs.theme = "no-such-theme"
        verify(Object.keys(ThemePalette.current).length > 0)
        compare(probe.color.toString(), ThemePalette.current.bg.toString())
    }
}
