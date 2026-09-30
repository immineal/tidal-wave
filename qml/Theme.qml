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
QtObject {
    readonly property var p: ThemePalette.current
    readonly property var r: ThemePalette.radius

    // True for the four dark palettes. Only for the handful of places that
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
    // Ink on a solid accent fill. Not always white: on the dark themes the
    // accent is bright enough that white text on it fails contrast.
    readonly property color onAccent: p.onAccent
    // Three strengths of accent wash, heavier on the light themes so they
    // still read. accentSoft tints a playing row, accentTint a hero gradient,
    // accentWash a filled badge.
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
    readonly property color onRed:   p.onRed
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
    readonly property color onArt:          p.onArt
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
}
