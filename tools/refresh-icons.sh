#!/usr/bin/env bash
# Put the current artwork on every icon surface this user has, and clear the
# caches that sit in front of them.
#
# Why this exists: the icon lives in six or seven places at once, each with its
# own cache, and fixing the asset alone updates none of them. docs/ICONS.md is
# the full map; this is the one command that walks it.
#
# Safety: it writes only under $HOME (the user's own icon theme, desktop entries
# and caches), never under /usr or /etc, and it never restarts an application.
# Anything that needs a restart is printed at the end for you to decide on.
#
# Usage:
#   tools/refresh-icons.sh              # update the files and the caches
#   tools/refresh-icons.sh --dry-run    # print what it would do, change nothing
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
[ "${1:-}" = "-n" ] && DRY=1

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src_png="$repo/assets/icon.png"
src_svg="$repo/assets/icon.svg"
name="tidal-wave"

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
hicolor="$data_home/icons/hicolor"

for f in "$src_png" "$src_svg"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

# Refuse to touch anything outside the user's home, whatever XDG_DATA_HOME says.
case "$data_home/" in "$HOME"/*) ;; *) echo "refusing: $data_home is not under $HOME" >&2; exit 1;; esac
case "$cache_home/" in "$HOME"/*) ;; *) echo "refusing: $cache_home is not under $HOME" >&2; exit 1;; esac

run() {
    if [ "$DRY" = 1 ]; then printf '   would: %s\n' "$*"; else "$@"; fi
}

# Confirmation of something that only happened for real.
did() {
    [ "$DRY" = 1 ] || printf '   %s\n' "$*"
}

echo "artwork: $src_svg + $src_png"
echo

# ── 1. the user's hicolor theme ──────────────────────────────────────────────
# Only two files belong here: the scalable SVG and the 128 PNG, the same pair
# `cmake --install` writes. Every other size is a leftover from the old runtime
# self-install, and a leftover wins over the SVG at that exact size, so an old
# 22x22 would keep showing in the tray for ever.
echo "1. hicolor theme under $hicolor"
shopt -s nullglob
for stale in "$hicolor"/*/apps/"$name".png "$hicolor"/*/apps/"$name".svg; do
    case "$stale" in
        "$hicolor"/128x128/apps/"$name".png) continue ;;
        "$hicolor"/scalable/apps/"$name".svg) continue ;;
    esac
    echo "   stale size, removing: $stale"
    run rm -f "$stale"
done
# ~/.icons is the old pre-XDG location and is still searched ahead of
# ~/.local/share/icons by some toolkits, so a copy left there outranks everything.
for stale in "$HOME"/.icons/*/apps/"$name".png "$HOME"/.icons/*/apps/"$name".svg \
             "$HOME"/.icons/"$name".png "$HOME"/.icons/"$name".svg; do
    # The last two patterns have no wildcard in them, so nullglob leaves them in
    # the list whether or not the file is there; the test is what drops them.
    [ -e "$stale" ] || continue
    echo "   stale copy in the legacy ~/.icons, removing: $stale"
    run rm -f "$stale"
done
shopt -u nullglob

run mkdir -p "$hicolor/128x128/apps" "$hicolor/scalable/apps"
run cp -f "$src_png" "$hicolor/128x128/apps/$name.png"
run cp -f "$src_svg" "$hicolor/scalable/apps/$name.svg"
did "wrote $hicolor/128x128/apps/$name.png"
did "wrote $hicolor/scalable/apps/$name.svg"
echo

# ── 2. the desktop entry ─────────────────────────────────────────────────────
# On Wayland this is what the taskbar, the window switcher and the task-manager
# tooltip resolve the window's icon through, so it matters as much as the pixels.
echo "2. desktop entry"
run mkdir -p "$data_home/applications"
run cp -f "$repo/packaging/$name.desktop" "$data_home/applications/$name.desktop"
did "wrote $data_home/applications/$name.desktop"
echo

# ── 3. the caches ────────────────────────────────────────────────────────────
echo "3. caches"
if command -v gtk-update-icon-cache >/dev/null 2>&1 && [ -f "$hicolor/icon-theme.cache" ]; then
    # Only if one is already there. Creating one where there was none makes GTK
    # trust it exclusively, so a later file added by hand would stop showing up.
    run gtk-update-icon-cache -q -t -f "$hicolor"
    did "rebuilt $hicolor/icon-theme.cache"
else
    echo "   no $hicolor/icon-theme.cache, nothing to rebuild (this is the normal case)"
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    run update-desktop-database -q "$data_home/applications"
    did "rebuilt the desktop entry index"
fi

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    # KDE's service cache. Plasma's launcher and the task manager read the
    # .desktop entry through this, not off the disk.
    # Redirected only on the real run, so --dry-run still shows the command.
    if [ "$DRY" = 1 ]; then
        run kbuildsycoca6 --noincremental
    else
        kbuildsycoca6 --noincremental >/dev/null 2>&1
    fi
    did "rebuilt the KDE service cache (ksycoca)"
fi

# KIconLoader's shared pixmap cache. Not always present on Plasma 6; when it is,
# it holds already-rendered icons and will keep handing out the old pixels.
if [ -f "$cache_home/icon-cache.kcache" ]; then
    run rm -f "$cache_home/icon-cache.kcache"
    did "removed $cache_home/icon-cache.kcache"
else
    echo "   no $cache_home/icon-cache.kcache"
fi
echo

# ── 4. what is left ──────────────────────────────────────────────────────────
cat <<'NOTE'
4. what this cannot do for you

   plasmashell and kwin_wayland hold the icon in memory for as long as they run,
   and they index the icon theme once at startup. Files and caches are now
   correct, but the panel, the window switcher and the task-manager tooltip may
   still show the previous artwork until those processes reload. Nothing here
   restarts them. If you want to, these are the commands:

       systemctl --user restart plasma-plasmashell.service
       kwin_wayland --replace &        # disruptive, usually not worth it

   The in-app marks (the sidebar and the login page) are drawn by the app, so
   they change when the app itself is rebuilt, reinstalled and restarted.
NOTE
