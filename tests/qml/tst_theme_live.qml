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
    }

    function init() {
        prefs.theme = "midnight"
    }

    function cleanupTestCase() {
        prefs.theme = "midnight"
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
            { tag: "deep",     name: "deep",     dark: true  },
            { tag: "daylight", name: "daylight", dark: false },
            { tag: "paper",    name: "paper",    dark: false },
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
        // Not "the text colour changed": Midnight and Deep both use white
        // text, so only the ground legitimately differs between those two.
        // What must hold is that the binding tracks the palette.
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
            { tag: "daylight", name: "daylight" },
            { tag: "paper",    name: "paper" },
        ]
    }

    function test_every_token_reaches_qml(data) {
        prefs.theme = data.name
        const palette = ThemePalette.current
        for (const key in palette) {
            if (key === "dark") continue
            verify(Theme[key] !== undefined,
                   data.name + ": Theme." + key + " is undefined")
            compare(Theme[key].toString(), palette[key].toString(),
                    data.name + ": Theme." + key + " does not match the palette")
        }
    }

    // An unknown name must still paint something rather than leaving the
    // window unstyled.
    function test_unknown_theme_still_paints() {
        prefs.theme = "no-such-theme"
        verify(Object.keys(ThemePalette.current).length > 0)
        compare(probe.color.toString(), ThemePalette.current.bg.toString())
    }
}
