// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

// The Qt the process runs on. A .deb built against Qt 6.4 also installs on
// 6.8 and 6.10, so a workaround for how Qt behaves asks this, and only a
// guard around an API missing from older headers asks QT_VERSION.
namespace QtRuntime {

// Packed as QT_VERSION is, so that it compares with QT_VERSION_CHECK().
// Read off the loaded Qt once.
int version();

// Tests pretend to run on another Qt with this; 0 goes back to the real one.
void setVersionForTests(int version);

} // namespace QtRuntime
