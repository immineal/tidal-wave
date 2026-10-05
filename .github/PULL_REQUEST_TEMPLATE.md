## What this changes

<!-- And why. Link the issue if there is one. -->

## How it was tested

<!-- Which platform, and whether it was Wayland or X11 if Linux. -->

- [ ] `ctest` passes (`-DTIDALWAVE_BUILD_TESTS=ON`, `QT_QPA_PLATFORM=offscreen`,
      about 15 minutes)
- [ ] Tried it in the running app

## Checklist

- [ ] Any new file under `qml/` is listed in `QML_FILES` in `CMakeLists.txt`
- [ ] Any C++ method called from QML is `Q_INVOKABLE`
- [ ] No QML property that needs a Qt newer than 6.4 is assigned declaratively
      (`Settings`/`import QtCore` 6.5, `Shape.CurveRenderer` 6.6, `popupType`
      6.8). The Debian 12 CI job runs the suite on real Qt 6.4.2.
- [ ] New user-facing strings go through `qsTr()` or `tr()`, with the German
      added to `i18n/tidal-wave_de.ts` by hand if the string is in C++
- [ ] No mail address anywhere in the diff. CI greps for them.
