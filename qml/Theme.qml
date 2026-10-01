pragma Singleton
import QtQuick
import TidalWave

// Every colour and corner radius in the app, as one binding layer over the
// palette table in src/ui/ThemePalette.cpp.
//
// Nothing here holds a value of its own. ThemePalette.current is a QVariantMap
// that swaps wholesale when prefs.theme changes, and because each token below
// is a binding onto it, every `Theme.accent` in the app repaints on its own.
// The C++ side is where the palettes are written down and where the contrast
// tests can reach them.
//
// prefs.oledBlack, which pulls a dark theme's grounds to true black, is a
// transform applied over there for the same reason: it arrives as a different
// `current` map, so there is no token for it and nothing below has to branch.
QtObject {
    readonly property var p: ThemePalette.current
    readonly property var r: ThemePalette.radius

    // True for the three dark palettes. Only for the handful of places that
    // genuinely have to branch; prefer a token over asking this.
    readonly property bool dark: ThemePalette.isDark

    // ── grounds ──────────────────────────────────────────────────────────
    readonly property color bg:          p.bg
    readonly property color surface:     p.surface
    readonly property color surfaceHigh: p.surfaceHigh
    readonly property color surfaceHov:  p.surfaceHov
    readonly property color border:      p.border

    // ── type ─────────────────────────────────────────────────────────────
    readonly property color textPrimary: p.textPrimary
    readonly property color textSec:     p.textSec
    readonly property color textDim:     p.textDim

    // ── accent ───────────────────────────────────────────────────────────
    readonly property color accent:    p.accent
    readonly property color accentDim: p.accentDim
    // Ink on a solid accent fill, white in every theme. The accents were
    // darkened until white cleared contrast on all six, rather than the ink
    // changing colour per theme, so a filled chip reads the same everywhere.
    readonly property color accentInk: p.accentInk
    // Three strengths of accent wash. Heavier on the dark themes, because
    // darkening their accents took the derived tints down with them.
    // accentSoft tints a playing row, accentTint a hero gradient, accentWash
    // a filled badge.
    readonly property color accentSoft: p.accentSoft
    readonly property color accentTint: p.accentTint
    readonly property color accentWash: p.accentWash

    // ── interaction ──────────────────────────────────────────────────────
    // The hover wash. Was Qt.rgba(1,1,1,0.04), which vanishes on a light
    // ground, so each palette picks its own direction.
    readonly property color hoverFill: p.hoverFill

    // ── semantic ─────────────────────────────────────────────────────────
    readonly property color red:     p.red
    readonly property color redSoft: p.redSoft
    readonly property color redInk:   p.redInk
    readonly property color green:   p.green
    // Fill for the lossless quality badge, as accentWash is for hi-res.
    readonly property color greenWash: p.greenWash

    // ── overlays ─────────────────────────────────────────────────────────
    // Dims the app behind a modal.
    readonly property color scrim: p.scrim
    // Layered over cover art, which is neither light nor dark, so these four
    // are the same in every theme.
    readonly property color artScrim:       p.artScrim
    readonly property color artScrimStrong: p.artScrimStrong
    readonly property color artInk:          p.artInk
    readonly property color artBorder:      p.artBorder

    // ── corner radii ─────────────────────────────────────────────────────
    // A scale, not one number on everything. The rounder something is, the
    // more it reads as a control floating above the surface.
    readonly property int radiusChip:   r.chip     // pills, filter toggles
    readonly property int radiusField:  r.field    // the sidebar search field
    readonly property int radiusRow:    r.row      // nav rows, list rows
    readonly property int radiusButton: r.button
    readonly property int radiusArt:    r.art      // covers, thumbnails
    readonly property int radiusCard:   r.card
    readonly property int radiusPopup:  r.popup    // dialogs, panels
    readonly property int radiusBadge:  r.badge    // quality tag
    readonly property int radiusMark:   r.mark     // the app icon tile

    // ── menus ────────────────────────────────────────────────────────────
    // A Menu's width does not come from its items. Qt's Basic style gives the
    // menu's contentItem (a ListView) no implicitWidth at all, so a styled
    // Menu is exactly as wide as whatever its background declares -- which is
    // how a hardcoded 200 came to cut "Zur Warteschlange hinzufügen" in half.
    // menuWidth() puts the measurement back: every Menu in the app binds its
    // implicitWidth to it and is then as wide as its longest *visible* item.
    //
    // The two bounds are what keep that honest at both ends. Below the
    // minimum a two-word menu is a stub you have to aim at; above the maximum
    // one long label would drag the whole menu off the screen, so past it the
    // labels elide instead (every menu entry is an elide-capable Text).
    readonly property int menuMinWidth: 180
    readonly property int menuMaxWidth: 420
    // Air left between a menu at full width and the window edge.
    readonly property int menuWindowMargin: 12

    function menuWidth(menu) {
        if (!menu) return menuMinWidth
        var w = 0
        // `count` and each item's `implicitWidth`/`visible` are properties, so
        // reading them here is what makes the caller's binding re-evaluate
        // when an item is added, hidden, or relabelled by a language change.
        for (var i = 0; i < menu.count; ++i) {
            var it = menu.itemAt(i)
            if (it && it.visible) w = Math.max(w, it.implicitWidth)
        }
        w += menu.leftPadding + menu.rightPadding

        // A window narrower than menuMaxWidth is the real cap; without this a
        // 420px menu in a 640px window is a quarter of the screen. `window` is
        // null until the menu is first shown, which is why it is guarded
        // rather than assumed.
        var maxW = menuMaxWidth
        if (menu.window && menu.window.width > 0)
            maxW = Math.min(maxW, menu.window.width - 2 * menuWindowMargin)

        return Math.max(Math.min(menuMinWidth, maxW), Math.min(maxW, w))
    }

    // ── motion ───────────────────────────────────────────────────────────
    // X6. One switch for the whole app, so a new animation has one obvious
    // thing to call and the answer cannot drift from file to file. Where the
    // preference actually comes from is Application::reducedMotion's problem;
    // see src/ui/Application.cpp for what each desktop exposes.
    //
    // `typeof` rather than a bare `app.reducedMotion` because a singleton is
    // reachable from anything that imports TidalWave, including hosts that
    // install only the context properties they need. An unqualified name that
    // is not there is a QML warning, and tests/tst_firstrun.cpp fails on any
    // warning at all. Same guard Main.qml uses for `updateCheck`.
    readonly property bool reduceMotion: (typeof app !== "undefined")
                                         && app !== null
                                         && app.reducedMotion === true

    // How long an animation is allowed to run for. Every `duration:` under
    // qml/ goes through here.
    //
    // Reduced motion collapses the duration to zero instead of switching the
    // animation off: the transition still starts and still finishes, so
    // anything watching for the end of one keeps working, and the property
    // lands on its target in the frame it was written. Switching the
    // animation off instead would be a second code path that only reduced
    // motion ever takes, which is how the two drift apart.
    //
    // An animation that loops forever cannot take this alone — zero-duration
    // and Animation.Infinite together is a spin loop. Those pair it with
    // `loops: Theme.reduceMotion ? 1 : Animation.Infinite` so the thing runs
    // once, instantly, and stops with its indicator still on screen.
    function dur(ms) { return reduceMotion ? 0 : ms }
}
