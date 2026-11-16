// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <QString>

// Whether to animate less. The desktop's setting is read per platform, and
// the Settings choice ("system", "on", "off") can override it.
namespace ReducedMotion {

// What the desktop asks for. TIDALWAVE_REDUCED_MOTION=1/0 overrides it.
bool systemPrefers();

// The choice from Settings over the desktop's answer. Anything but "on" or
// "off" follows the desktop.
bool resolve(const QString &pref, bool systemPrefers);

} // namespace ReducedMotion
