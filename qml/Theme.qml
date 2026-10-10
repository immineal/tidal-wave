pragma Singleton
import QtQuick
import TidalWave

// Every colour and corner radius in the app, as one binding layer over the
// palette table in src/ui/ThemePalette.cpp. Nothing here holds a value of its
// own: ThemePalette.current swaps wholesale when the theme, prefs.oledBlack or
// prefs.tintedGreys changes, so every token repaints by itself and nothing
// below has to branch.
QtObject {
    readonly property var p: ThemePalette.current
    readonly property var r: ThemePalette.radius

    // True for the three dark palettes. Prefer a token over asking this.
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
    // Ink on a solid accent fill, white in every theme.
    readonly property color accentInk: p.accentInk
    // Three strengths of accent wash: accentSoft tints a playing row,
    // accentTint a hero gradient, accentWash a filled badge.
    readonly property color accentSoft: p.accentSoft
    readonly property color accentTint: p.accentTint
    readonly property color accentWash: p.accentWash

    // ── interaction ──────────────────────────────────────────────────────
    // The hover wash. A white wash vanishes on a light ground, so each palette
    // picks its own direction.
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
    // A scale: the rounder something is, the more it reads as a control
    // floating above the surface.
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
    // Qt's Basic style gives a Menu's contentItem no implicitWidth, so every
    // Menu binds its implicitWidth to menuWidth(): as wide as its longest
    // visible item, within these bounds. Past the maximum the labels elide.
    readonly property int menuMinWidth: 180
    readonly property int menuMaxWidth: 420
    // Air left between a menu at full width and the window edge.
    readonly property int menuWindowMargin: 12

    function menuWidth(menu) {
        if (!menu) return menuMinWidth
        var w = 0
        // Reading count, implicitWidth and visible here makes the caller's
        // binding re-evaluate when an item is added, hidden or relabelled.
        for (var i = 0; i < menu.count; ++i) {
            var it = menu.itemAt(i)
            if (it && it.visible) w = Math.max(w, it.implicitWidth)
        }
        w += menu.leftPadding + menu.rightPadding

        // A narrower window is the cap. `window` is null until first shown.
        var maxW = menuMaxWidth
        if (menu.window && menu.window.width > 0)
            maxW = Math.min(maxW, menu.window.width - 2 * menuWindowMargin)

        return Math.max(Math.min(menuMinWidth, maxW), Math.min(maxW, w))
    }

    // ── motion ───────────────────────────────────────────────────────────
    // One switch for the whole app. `typeof` because this singleton is
    // reachable from hosts that install no `app` context property, and an
    // unqualified name that is missing is a QML warning.
    readonly property bool reduceMotion: (typeof app !== "undefined")
                                         && app !== null
                                         && app.reducedMotion === true

    // Every `duration:` under qml/ goes through here. Reduced motion gives
    // zero, so a transition still starts and finishes. An infinite animation
    // also needs `loops: Theme.reduceMotion ? 1 : Animation.Infinite`.
    function dur(ms) { return reduceMotion ? 0 : ms }
}
