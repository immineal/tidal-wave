import QtQuick
import QtTest
import TidalWave

// The end-to-end half of the theme contract: changing prefs.theme must repaint
// what QML actually draws.
//
// This exists because tst_theme.cpp passed while theme switching was entirely
// broken in the app. It only called the free palette functions, so it never
// touched the QML singleton, which is where the bug was: Qt built its own
// ThemePalette with a null Prefs and nothing ever repainted.
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
            anchors.bottom: parent.bottom
            width: 60; height: 20
            color: Theme.accent
            Text { id: chipLabel; anchors.centerIn: parent; text: "(7)"; color: Theme.accentInk }
        }

        // ...and the same for a filled danger button.
        Rectangle {
            anchors.top: parent.top
            width: 60; height: 20
            color: Theme.red
            Text { id: dangerLabel; anchors.centerIn: parent; text: "x"; color: Theme.redInk }
        }
    }

    function init() {
        prefs.theme = "midnight"
        // Explicit, because half the file is about what flipping it does.
        prefs.oledBlack = false
    }

    function cleanupTestCase() {
        prefs.theme = "midnight"
        prefs.oledBlack = false
    }

    function test_singleton_sees_prefs() {
        // If this is null the engine built its own instance and create() was
        // skipped, which is the failure this file was written for.
        verify(ThemePalette.current !== undefined)
        verify(Object.keys(ThemePalette.current).length > 0)
    }

    function test_switching_theme_repaints_data() {
        return [
            { tag: "forest",   name: "forest",   dark: true  },
            { tag: "ember",    name: "ember",    dark: true  },
            { tag: "daylight", name: "daylight", dark: false },
            { tag: "paper",    name: "paper",    dark: false },
            { tag: "dawn",     name: "dawn",     dark: false },
        ]
    }

    function test_switching_theme_repaints(data) {
        // toString() because a QML colour read into a var is a value type
        // whose identity is not stable to compare against later; the hex is.
        const before = probe.color.toString()

        prefs.theme = data.name

        compare(ThemePalette.isDark, data.dark)
        verify(probe.color.toString() !== before,
               data.name + " did not change the background away from midnight")
        // Not "the text colour changed": Midnight and Daylight are not the
        // only pair that can share an ink, so only the ground legitimately
        // differs. What must hold is that the binding tracks the palette.
        compare(label.color.toString(), ThemePalette.current.textPrimary.toString())
        // The binding has to agree with the table, not merely have moved.
        compare(probe.color.toString(), ThemePalette.current.bg.toString())
    }

    // Light themes are the reason the token layer exists, so prove a light
    // ground really produces dark text rather than white on white.
    function test_light_theme_inverts_text() {
        prefs.theme = "daylight"
        verify(!ThemePalette.isDark)
        const bgLum = 0.2126 * probe.color.r + 0.7152 * probe.color.g + 0.0722 * probe.color.b
        const fgLum = 0.2126 * label.color.r + 0.7152 * label.color.g + 0.0722 * label.color.b
        verify(bgLum > 0.5, "daylight background is not light")
        verify(fgLum < 0.5, "daylight text is not dark")
    }

    // The end-to-end version of the same guard: every colour token has to
    // arrive in QML as the palette's value. A token whose binding silently
    // never ran reads as black here, which is what onAccent and onRed did.
    function test_every_token_reaches_qml_data() {
        return [
            { tag: "midnight", name: "midnight" },
            { tag: "midnight in black", name: "midnight", oled: true },
            { tag: "daylight", name: "daylight" },
            { tag: "paper",    name: "paper" },
            { tag: "dawn",     name: "dawn" },
        ]
    }

    function test_every_token_reaches_qml(data) {
        prefs.theme = data.name
        prefs.oledBlack = data.oled === true
        const palette = ThemePalette.current
        for (const key in palette) {
            if (key === "dark") continue
            verify(Theme[key] !== undefined,
                   data.name + ": Theme." + key + " is undefined")
            compare(Theme[key].toString(), palette[key].toString(),
                    data.name + ": Theme." + key + " does not match the palette")
        }
    }

    // The ink on a filled chip is white in every theme now, and QML is where
    // that has to be true: the C++ table was always right about onAccent too,
    // and the binding still painted black. Reading it back off a real
    // Rectangle's label is the only check that covers the whole path.
    function test_ink_on_a_fill_is_white_data() {
        return [
            { tag: "midnight", name: "midnight" },
            { tag: "forest",   name: "forest" },
            { tag: "ember",    name: "ember" },
            { tag: "daylight", name: "daylight" },
            { tag: "paper",    name: "paper" },
            { tag: "dawn",     name: "dawn" },
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
    //
    // Same argument as the rest of this file: the C++ table can be perfectly
    // right about the black variant and the app can still never show it, so
    // these read the colour back off a Rectangle that is bound the way the
    // app's are.

    function test_pure_black_repaints_data() {
        return [
            { tag: "midnight", name: "midnight" },
            { tag: "forest",   name: "forest" },
            { tag: "ember",    name: "ember" },
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
        // The type did not come down with the ground: a black page with grey
        // text would be the transform overreaching.
        compare(label.color.toString(), ThemePalette.current.textPrimary.toString())
        verify(label.color.r > 0.8, data.name + ": the ink went dark along with the page")

        // ...and it goes back.
        prefs.oledBlack = false
        verify(probe.color.toString() !== "#000000",
               data.name + ": turning the switch off left the page black")
    }

    // Nothing to pull down on a light theme, so the setting must leave the
    // window exactly as it was. Settings hides the switch there; this is the
    // half that makes hiding it honest.
    function test_pure_black_does_nothing_on_a_light_theme_data() {
        return [
            { tag: "daylight", name: "daylight" },
            { tag: "paper",    name: "paper" },
            { tag: "dawn",     name: "dawn" },
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

    // An unknown name must still paint something rather than leaving the
    // window unstyled.
    function test_unknown_theme_still_paints() {
        prefs.theme = "no-such-theme"
        verify(Object.keys(ThemePalette.current).length > 0)
        compare(probe.color.toString(), ThemePalette.current.bg.toString())
    }
}
