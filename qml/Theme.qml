pragma Singleton
import QtQuick
import TidalWave

// Every design token in the app. Colours and radii bind to the palette table
// in src/ui/ThemePalette.cpp, which swaps wholesale on a theme change, so they
// repaint by themselves. Sizes, spacing and motion are plain values here.
QtObject {
    readonly property var p: ThemePalette.current
    readonly property var r: ThemePalette.radius

    // True for the three dark palettes. Prefer a token over asking this.
    readonly property bool dark: ThemePalette.isDark

    // ── grounds ──────────────────────────────────────────────────────────
    readonly property color bg:          p.bg
    readonly property color surface:     p.surface
    readonly property color surfaceHigh: p.surfaceHigh
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
    // The accent as text or an icon; accent itself is for fills.
    readonly property color accentText: p.accentText
    // Three strengths of accent wash: accentSoft tints a playing row,
    // accentTint a hero gradient, accentWash a filled badge.
    readonly property color accentSoft: p.accentSoft
    readonly property color accentTint: p.accentTint
    readonly property color accentWash: p.accentWash

    // ── interaction ──────────────────────────────────────────────────────
    // The hover wash, for every hover in the app. A white wash vanishes on a
    // light ground, so each palette picks its own direction.
    readonly property color hoverFill: p.hoverFill
    // The opaque fill of the selected thing: the page you are on, the chosen
    // row. Stronger than hoverFill, so hovering never looks like choosing.
    readonly property color selectedFill: p.surfaceHov

    // ── semantic ─────────────────────────────────────────────────────────
    readonly property color red:     p.red
    readonly property color redText: p.redText
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

    // ── font sizes ───────────────────────────────────────────────────────
    // Six sizes, and every font.pixelSize in qml/ is one of them
    // (tests/tst_design_tokens.cpp). Pick by role, not by look.
    readonly property int fontDisplay: 28   // a page's or a hero's title
    readonly property int fontTitle:   20   // a dialog's or a panel's title
    readonly property int fontSection: 18   // a heading over a block of a page
    readonly property int fontBody:    14   // titles in rows, labels, reading text
    readonly property int fontMeta:    13   // second lines, counts, durations, notes
    readonly property int fontMicro:   11   // overlines, captions, tiny print

    // ── corner radii ─────────────────────────────────────────────────────
    // Four steps: the rounder something is, the more it reads as a control
    // floating above the surface.
    readonly property int radiusSmall:  r.small    // covers, thumbnails, tags
    readonly property int radiusMedium: r.medium   // rows, buttons, menu entries
    readonly property int radiusLarge:  r.large    // cards, fields, dialogs, menus
    readonly property int radiusFull:   r.full     // pills, chips, toggles

    // ── spacing ──────────────────────────────────────────────────────────
    // A 4 px scale, named by its multiple of 4, plus the half step for text
    // stacked tight. Gaps, margins and paddings all come from here.
    readonly property int spaceHalf: 2
    readonly property int space1:    4
    readonly property int space2:    8
    readonly property int space3:    12
    readonly property int space4:    16
    readonly property int space5:    20
    readonly property int space6:    24
    readonly property int space8:    32
    readonly property int space12:   48
    readonly property int space16:   64

    // ── icons ────────────────────────────────────────────────────────────
    // The stroke of every drawn glyph, in VectorIcon's 24-unit space, so it
    // scales with the icon.
    readonly property real iconStroke: 1.8

    // ── tool tips ────────────────────────────────────────────────────────
    readonly property int tooltipDelay: 500

    // ── menus ────────────────────────────────────────────────────────────
    // Qt's Basic style gives a Menu's contentItem no implicitWidth, so every
    // Menu binds its implicitWidth to menuWidth(): as wide as its longest
    // visible item, within these bounds. Past the maximum the labels elide.
    readonly property int menuMinWidth: 180
    readonly property int menuMaxWidth: 420
    // Air left between a menu at full width and the window edge.
    readonly property int menuWindowMargin: 12
    // The gap between a menu's edge and its entries, so an entry's rounded
    // highlight sits inside the menu's rounder corners.
    readonly property int menuPadding: space1

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

    // Three speeds: a hover or a colour change, a slide or a fade, and the
    // slow pulse of something waiting. A spinner turns once per two slow.
    readonly property int motionFast:   100
    readonly property int motionMedium: 200
    readonly property int motionSlow:   400

    // Every `duration:` under qml/ goes through here. Reduced motion gives
    // zero, so a transition still starts and finishes. An infinite animation
    // also needs `loops: Theme.reduceMotion ? 1 : Animation.Infinite`.
    function dur(ms) { return reduceMotion ? 0 : ms }

    // A length in ms as a clock reads it: m:ss, and h:mm:ss from an hour on.
    // The seek bar and the track rows share it, so the two always agree.
    function clock(ms) {
        var t = Math.max(0, Math.floor((Number(ms) || 0) / 1000))
        var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60
        var ss = (s < 10 ? "0" : "") + s
        if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + ss
        return m + ":" + ss
    }

    // A length in seconds as a sentence reads it, "1 hr 5 min" or "42 min",
    // for the detail pages' totals. Whole strings, so a translation can
    // reorder them; kept in AlbumPage's context, where they were translated.
    function lengthText(seconds) {
        var loc  = Qt.locale()
        var hrs  = Math.floor(seconds / 3600)
        var mins = Math.floor((seconds % 3600) / 60)
        return hrs > 0
            ? qsTranslate("AlbumPage", "%1 hr %2 min").arg(hrs.toLocaleString(loc, 'f', 0)).arg(mins.toLocaleString(loc, 'f', 0))
            : qsTranslate("AlbumPage", "%1 min").arg(mins.toLocaleString(loc, 'f', 0))
    }
}
