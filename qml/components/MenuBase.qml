import QtQuick
import QtQuick.Controls
import TidalWave

// What every Menu in the app shares: how it arrives and leaves, its insets,
// its width, padding and panel. ContextMenu and the track row's menus are
// built on it; the entries are ContextMenu.Entry.
Menu {
    id: base

    // Opacity and nothing else. Qt 6.4 has a Popup/Layout polish loop when a
    // popup's geometry feeds back into its contents, and animating height,
    // scale or y would hand the positioner a moving target.
    component OpenFade : Transition {
        NumberAnimation {
            property: "opacity"
            from: 0; to: 1
            duration: Theme.dur(Theme.motionFast)
            easing.type: Easing.OutCubic
        }
    }
    component CloseFade : Transition {
        NumberAnimation {
            property: "opacity"
            from: 1; to: 0
            duration: Theme.dur(Theme.motionFast)
            easing.type: Easing.InCubic
        }
    }

    enter: OpenFade { }
    exit:  CloseFade { }

    // Insets reset, not inherited. A style sets them for its drop shadow (the
    // native macOS style uses -32), and this menu draws its own background,
    // so inherited insets lay the panel out past the popup and clip entries.
    leftInset: 0; rightInset: 0; topInset: 0; bottomInset: 0

    // popupType and Popup.Item are Qt 6.8. Declared, the property makes this
    // type and every type using it unavailable on older Qt, so it is assigned
    // where it exists. `this.` matters: a bare unknown name throws.
    Component.onCompleted: {
        if (this.popupType !== undefined) this.popupType = Popup.Item
    }

    // Sized to its longest item; see Theme.menuWidth for why a styled Menu
    // does not do that by itself.
    implicitWidth: Theme.menuWidth(base)

    // Qt may let a menu hang `overlap` pixels past the window edge (Basic asks
    // for 1, for submenus). A submenu here opens beside its row, not over it.
    overlap: 0
    padding: Theme.menuPadding

    background: Rectangle {
        color: Theme.surfaceHigh
        border.color: Theme.border
        radius: Theme.radiusLarge
    }
}
