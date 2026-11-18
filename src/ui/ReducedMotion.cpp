// SPDX-License-Identifier: GPL-3.0-or-later

#include "ui/ReducedMotion.h"

#include <QByteArray>

#if defined(Q_OS_WIN)
#  include <qt_windows.h>
#elif defined(Q_OS_MACOS)
#  include <objc/message.h>
#  include <objc/runtime.h>
#else
#  include <QSettings>
#  include <QStandardPaths>
#  include <QVariant>
#endif

namespace ReducedMotion {

bool systemPrefers() {
    const QByteArray forced = qgetenv("TIDALWAVE_REDUCED_MOTION");
    if (!forced.isEmpty())
        return forced != "0" && forced.compare("false", Qt::CaseInsensitive) != 0;

#if defined(Q_OS_WIN)
    // "Show animations in Windows" off in Settings > Accessibility.
    BOOL animate = TRUE;
    if (SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animate, 0))
        return !animate;
    return false;
#elif defined(Q_OS_MACOS)
    // [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion],
    // without an Objective-C++ file. Nil until AppKit is loaded.
    Class workspace = objc_getClass("NSWorkspace");
    if (!workspace)
        return false;
    using IdCall = id (*)(id, SEL);
    using BoolCall = BOOL (*)(id, SEL);
    id shared = reinterpret_cast<IdCall>(objc_msgSend)(
        reinterpret_cast<id>(workspace), sel_registerName("sharedWorkspace"));
    SEL ask = sel_registerName("accessibilityDisplayShouldReduceMotion");
    if (!shared || !class_respondsToSelector(object_getClass(shared), ask))
        return false;
    return reinterpret_cast<BoolCall>(objc_msgSend)(shared, ask);
#else
    // Qt has no hint for this up to 6.12, so the KDE and GTK settings are
    // read from their INI files.
    const QString cfg =
        QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    if (!cfg.isEmpty()) {
        // KDE: the animation speed slider at its slowest writes a factor of 0.
        QSettings kde(cfg + QStringLiteral("/kdeglobals"), QSettings::IniFormat);
        const QVariant factor = kde.value(QStringLiteral("KDE/AnimationDurationFactor"));
        if (factor.isValid() && factor.toDouble() <= 0.0)
            return true;

        // GNOME and anything else GTK: "Reduce animation".
        QSettings gtk(cfg + QStringLiteral("/gtk-3.0/settings.ini"), QSettings::IniFormat);
        const QVariant anim = gtk.value(QStringLiteral("Settings/gtk-enable-animations"));
        if (anim.isValid() && !anim.toBool())
            return true;
    }
    return false;
#endif
}

bool resolve(const QString &pref, bool systemPrefers) {
    if (pref == QLatin1String("on"))
        return true;
    if (pref == QLatin1String("off"))
        return false;
    return systemPrefers;
}

} // namespace ReducedMotion
