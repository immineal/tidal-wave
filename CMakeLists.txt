cmake_minimum_required(VERSION 3.20)
project(tidal-wave VERSION 0.4.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Tests are opt-in: a plain `cmake -B build -S .` builds exactly what it always
# did (app only, no Qt6::Test/QuickTest requirement).
option(TIDALWAVE_BUILD_TESTS "Build tests" OFF)

find_package(Qt6 6.4 REQUIRED COMPONENTS
    Core
    Gui
    Widgets
    Quick
    Qml
    QmlModels
    Network
    DBus
    Multimedia
    Svg
    Concurrent
    # QQuickStyle, which Application::run() uses to pin the Controls style to
    # Basic. The call was commented out in the initial commit together with its
    # include, and this component was never added - a missing link, not an
    # objection to the style.
    QuickControls2
)

qt_standard_project_setup()

# Qt policies — guarded by version so the project builds across Qt releases:
# QTP0001 exists since Qt 6.5, QTP0004 only since Qt 6.8 (setting an unknown
# policy is a hard error, which broke CI on Qt 6.5.3). These must be set before
# qt_add_qml_module() below, since QTP0001 decides the module's resource prefix
# (":/qt/qml/TidalWave/..." vs ":/TidalWave/...").
if(Qt6_VERSION VERSION_GREATER_EQUAL 6.5)
    qt_policy(SET QTP0001 NEW)
endif()
if(Qt6_VERSION VERSION_GREATER_EQUAL 6.8)
    qt_policy(SET QTP0004 NEW)
endif()

# Chromecast support (Linux only) needs Avahi for mDNS discovery.
if(UNIX AND NOT APPLE)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(AVAHI REQUIRED IMPORTED_TARGET avahi-client)
endif()

# Everything except main.cpp lives in the tidalwave_qml library (see below), so
# both the app and the test binaries get the same C++ *and* the same QML module.
set(SOURCES
    src/api/TidalApi.cpp
    src/api/Auth.cpp
    src/api/TidalClient.cpp
    src/api/TidalBridge.cpp
    src/player/Player.cpp
    src/player/SpectrumAnalyzer.cpp
    src/player/Downloader.cpp
    src/mpris/MprisPlayer.cpp
    src/ui/Application.cpp
    src/ui/ImageProvider.cpp
    src/ui/CoverColor.cpp
    src/ui/Prefs.cpp
    src/ui/UpdateCheck.cpp
    src/ui/Feedback.cpp
    src/ui/ThemePalette.cpp
    src/ui/I18n.cpp
    src/ui/PinStore.cpp
    src/ui/Shortcuts.cpp
    src/api/LibraryIndex.cpp
)

set(HEADERS
    src/api/Models.h
    src/api/TidalApi.h
    src/api/Auth.h
    src/api/TidalClient.h
    src/api/TidalBridge.h
    src/player/Player.h
    src/player/SpectrumAnalyzer.h
    src/player/Downloader.h
    src/mpris/MprisPlayer.h
    src/ui/Application.h
    src/ui/ImageProvider.h
    src/ui/CoverColor.h
    src/ui/Prefs.h
    src/ui/UpdateCheck.h
    src/ui/Feedback.h
    src/ui/ThemePalette.h
    src/ui/I18n.h
    src/ui/PinStore.h
    src/ui/Shortcuts.h
    src/api/LibraryIndex.h
)

# Chromecast backend (Linux only — depends on Avahi).
if(UNIX AND NOT APPLE)
    list(APPEND SOURCES
        src/cast/CastMessage.cpp
        src/cast/CastDiscovery.cpp
        src/cast/CastSession.cpp
        src/cast/CastMediaServer.cpp
        src/cast/CastMediaPrep.cpp
        src/cast/CastManager.cpp
    )
    list(APPEND HEADERS
        src/cast/CastMessage.h
        src/cast/CastDiscovery.h
        src/cast/CastSession.h
        src/cast/CastMediaServer.h
        src/cast/CastMediaPrep.h
        src/cast/CastManager.h
    )
endif()

# ── QML module + app logic as a static library ───────────────────────────────
# The QML module used to be attached to the executable, which made both the QML
# files and the C++ QML_ELEMENT registrations unreachable from a test binary
# (you cannot link an executable). Hosting the module on a static library lets
# tidal-wave and tests/ link the exact same module, resources included.
qt_add_library(tidalwave_qml STATIC
    ${SOURCES}
    ${HEADERS}
)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(tidalwave_qml
    URI TidalWave
    VERSION 1.0
    # Pinned, rather than left to QTP0001's default, because the policy only
    # exists from Qt 6.5 and the two defaults are not interchangeable. Under the
    # old default the module's resources land at ":/TidalWave/...", while a QML
    # engine's default import path is "qrc:/qt/qml" - so on Qt 6.4 every
    # `import TidalWave` resolved nothing, every type in the module came out
    # "is not a type", and the engine returned no root object. Application::run()
    # then exits -1 with no window and no message. A real Debian 12 build found
    # this *after* the loadFromModule guard below made it compile: the declared
    # 6.4 floor was false one layer deeper than the compile error.
    #
    # Setting it here puts the resources in the same place on every Qt, so the
    # import works without a runtime addImportPath - which would have fixed the
    # app and not the tests, since QuickTest builds its own engine and would have
    # gone on failing all 35 of its module types.
    RESOURCE_PREFIX "/qt/qml"
    # A library-hosted module gets its own directory in the build tree; without
    # this it lands in the build root, which doesn't match the TidalWave target
    # path and makes Qt warn that qmllint may misbehave. The app still loads the
    # module out of the embedded resources, not from here.
    OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/TidalWave
    QML_FILES
        qml/Theme.qml
        qml/Main.qml
        qml/components/PlayerBar.qml
        qml/components/SideBar.qml
        qml/components/NewPlaylistDialog.qml
        qml/components/SettingsPanel.qml
        qml/components/LibraryFinder.qml
        qml/components/TrackRow.qml
        qml/components/MediaCard.qml
        qml/components/BackButton.qml
        qml/components/PillButton.qml
        qml/components/NavIcon.qml
        qml/components/HorizontalSection.qml
        qml/components/PageHeader.qml
        qml/components/LoadingOverlay.qml
        qml/components/ContextMenu.qml
        qml/components/SearchBar.qml
        qml/components/VolumeSlider.qml
        qml/components/SeekBar.qml
        qml/components/QueuePanel.qml
        qml/components/UpdatePrompt.qml
        qml/components/VectorIcon.qml
        qml/components/AppMark.qml
        qml/components/ArtistLinks.qml
        qml/pages/LoginPage.qml
        qml/pages/HomePage.qml
        qml/pages/SearchPage.qml
        qml/pages/CollectionPage.qml
        qml/pages/AlbumPage.qml
        qml/pages/ArtistPage.qml
        qml/pages/PlaylistPage.qml
        qml/pages/MixPage.qml
        qml/pages/NowPlayingPage.qml
        qml/pages/RadioPage.qml
    RESOURCES
        assets/icon.png
        assets/icon.svg
)

# Qt 6.4's qmlcachegen miscompiles at least one binding in this module. It emits
# an ahead-of-time compiled C++ function that reads a property straight off a
# QQuickItem pointer with no null check, and QueuePanel's delegate hands it one -
#
#   QQuickItem::z() const
#   QQmlPrivate::AOTCompiledContext::getValueLookup(unsigned int, void*, void*)
#   QmlCacheGeneratedCode::_qt_qml_TidalWave_qml_components_QueuePanel_qml
#       ::aotBuiltFunctions::{lambda(...)#18}
#
# - which is a SIGSEGV inside waitForRendering(), taking the whole tst_qml binary
# down partway through. Qt 6.12's qmlcachegen does not generate the same code and
# the suite is clean there.
#
# --only-bytecode keeps the compile-to-bytecode cache, which is what makes QML
# load fast, and skips just the AOT C++ generation that is wrong here. It is the
# narrowest switch that covers it: QT_QML_SKIP_CACHEGEN would throw the bytecode
# away too. Guarded by version so the newer Qt everyone develops against keeps
# generating AOT code, and so this disappears on its own when 6.4 is dropped.
if(Qt6_VERSION VERSION_LESS 6.5)
    set_target_properties(tidalwave_qml PROPERTIES
        QT_QMLCACHEGEN_ARGUMENTS "--only-bytecode")
endif()

# PUBLIC: tests include the same headers with the same short paths as the app
# (e.g. #include "ui/Application.h", #include "Auth.h").
target_compile_definitions(tidalwave_qml PUBLIC
    TIDALWAVE_VERSION="${PROJECT_VERSION}"
)

target_include_directories(tidalwave_qml PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/api
    ${CMAKE_CURRENT_SOURCE_DIR}/src/player
    ${CMAKE_CURRENT_SOURCE_DIR}/src/mpris
    ${CMAKE_CURRENT_SOURCE_DIR}/src/ui
    ${CMAKE_CURRENT_SOURCE_DIR}/src/cast
)

# PUBLIC so linking tidalwave_qml is all the app and the tests have to do.
target_link_libraries(tidalwave_qml PUBLIC
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Quick
    Qt6::Qml
    Qt6::QmlModels
    Qt6::Network
    Qt6::DBus
    Qt6::Multimedia
    Qt6::Svg
    Qt6::Concurrent
    Qt6::QuickControls2
)

# Avahi for Chromecast discovery (Linux only).
if(UNIX AND NOT APPLE)
    target_link_libraries(tidalwave_qml PUBLIC PkgConfig::AVAHI)
endif()

# ── Application ──────────────────────────────────────────────────────────────
qt_add_executable(tidal-wave
    src/main.cpp
)

target_link_libraries(tidal-wave PRIVATE tidalwave_qml)

# The QML module is static, so the app has to import its plugin
# (tidalwave_qmlplugin) or QML loading fails with "module TidalWave is not
# installed". Linking the plugin target does exactly that: Qt propagates the
# plugin's generated Q_IMPORT_PLUGIN init object library along with it.
#
# qt_import_qml_plugins(tidal-wave) is the usual one-liner here and it does work,
# but it runs qmlimportscanner with -rootPath <target source dir> — the whole
# repo — so it also reads tests/qml/*.qml and records QtTest as a dependency of
# the *app*. That warns at configure time on Qt installs without the QuickTest
# CMake package (a distro Qt without qt6-quicktest-devel) and would link
# Qt6::QuickTest into the shipped binary on a static Qt. qmlimportscanner's
# -exclude option has no effect on -rootPath scans (checked against 6.12), so the
# scan is turned off and the plugin named directly instead.
set_target_properties(tidal-wave PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)

get_target_property(tidalwave_qml_plugin tidalwave_qml QT_QML_MODULE_PLUGIN_TARGET)
if(NOT tidalwave_qml_plugin OR NOT TARGET ${tidalwave_qml_plugin})
    message(FATAL_ERROR "tidalwave_qml has no QML plugin target to link into tidal-wave.")
endif()
target_link_libraries(tidal-wave PRIVATE ${tidalwave_qml_plugin})

# An installed binary has to find the Qt it was built against. qt_standard_
# project_setup() presets CMAKE_INSTALL_RPATH to $ORIGIN, and `cmake --install`
# otherwise drops the build tree's own RPATH, so a binary built against a Qt
# outside the default linker search path falls back to whatever Qt the system
# has. Here that meant a 6.12 build silently loading the distro's 6.11 and
# dying with "version `Qt_6.12' not found" the moment it ran from ~/.local/bin
# instead of from the build directory. CMAKE_INSTALL_RPATH_USE_LINK_PATH does
# not cover it, because Qt reaches the link line through a static library.
# Appending the directory Qt6::Core actually came from does.
if(UNIX AND NOT APPLE)
    get_target_property(_tw_qt_core Qt6::Core IMPORTED_LOCATION_RELEASE)
    if(NOT _tw_qt_core)
        get_target_property(_tw_qt_core Qt6::Core IMPORTED_LOCATION)
    endif()
    if(_tw_qt_core)
        get_filename_component(_tw_qt_libdir "${_tw_qt_core}" DIRECTORY)
        # ...but only when the dynamic linker would not have found it anyway. A
        # distro Qt lives in /usr/lib/x86_64-linux-gnu, which is already on the
        # default search path, so appending it writes a RUNPATH entry that
        # changes nothing and that lintian flags as a custom library search path
        # on a package built exactly the way a release is built. The implicit
        # link directories are the authoritative list of what needs no RPATH, so
        # ask them rather than matching on the path's spelling.
        if("${_tw_qt_libdir}" IN_LIST CMAKE_CXX_IMPLICIT_LINK_DIRECTORIES)
            message(STATUS
                "Qt is in a default linker directory (${_tw_qt_libdir}); "
                "leaving it out of the install RPATH.")
        else()
            get_target_property(_tw_rpath tidal-wave INSTALL_RPATH)
            if(NOT _tw_rpath)
                set(_tw_rpath "")
            endif()
            list(APPEND _tw_rpath "${_tw_qt_libdir}")
            list(REMOVE_DUPLICATES _tw_rpath)
            set_target_properties(tidal-wave PROPERTIES INSTALL_RPATH "${_tw_rpath}")
        endif()
    endif()
endif()

set_target_properties(tidal-wave PROPERTIES
    # CFBundleName, which is what the macOS application menu and the About item
    # are titled with. Unset, the bundle fell back to the target name and the
    # menu read "tidal-wave" where every other app on the machine reads its
    # proper name.
    MACOSX_BUNDLE_BUNDLE_NAME "Tidal Wave"
    # The organization half matches the preferences domain QSettings writes
    # under on macOS, which Application::run() now pins with
    # setOrganizationDomain("tidalwave.com") -> com.tidalwave. The leaf is the
    # same machine-readable name as the Linux .desktop file and
    # QGuiApplication::setDesktopFileName(), rather than the "client" that
    # matched nothing. The leaf QSettings uses is still the display name
    # ("Tidal Wave"), because that comes from applicationName(), and renaming
    # that to make the two identical would orphan every existing Linux user's
    # ~/.config/TidalWave/Tidal Wave.conf for a cosmetic win - see the report.
    MACOSX_BUNDLE_GUI_IDENTIFIER com.tidalwave.tidal-wave
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

# ── Tests ────────────────────────────────────────────────────────────────────
if(TIDALWAVE_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# ── Translations ───────────────────────────────────────────────────────
# lupdate/lrelease live in qttools, which not every Qt install carries, so this
# is optional: without it the app builds and runs in English.
find_package(Qt6 QUIET COMPONENTS LinguistTools)
if(Qt6LinguistTools_FOUND)
    qt_add_translations(tidalwave_qml
        TS_FILES
            i18n/tidal-wave_en.ts
            i18n/tidal-wave_de.ts
        RESOURCE_PREFIX "/i18n"
        LUPDATE_OPTIONS -no-obsolete -locations none
    )
else()
    message(WARNING
        "Qt6 LinguistTools not found - building without translations. "
        "Install the qttools module to get the German catalogue.")
endif()

include(GNUInstallDirs)

install(TARGETS tidal-wave
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

# Desktop integration (Linux). The .desktop entry is what puts the app in the
# menus, and on Wayland it is also what the taskbar matches the window against:
# the app calls QGuiApplication::setDesktopFileName("io.github.immineal.TidalWave"),
# the compositor gets that as the surface's app id, and KWin looks up
# io.github.immineal.TidalWave.desktop to find Icon=tidal-wave.
#
# There are two separate agreements in that chain, and they are about different
# names. The entry's *basename* has to equal setDesktopFileName() and the
# metainfo <launchable>; it is the app id, because Flatpak exports only
# <app-id>.desktop and nothing else would have made us rename it. The entry's
# Icon= key has to equal the installed icon *file* names, and both are still
# "tidal-wave" - the icon was not renamed, and neither was the binary Exec=
# names. Renaming the entry moved the Wayland app id and nothing else.
#
# StartupWMClass is the X11 half and does not follow either of them: it has to
# equal the window's actual WM_CLASS, which the xcb plugin builds out of
# QCoreApplication::applicationName() and never out of desktopFileName(). See
# the header of the .desktop file for the measurement.
#
# These two install rules are the only writers of the hicolor icon. The app used
# to rescale its embedded PNG over the same paths on every launch, which let an
# old binary overwrite a freshly installed icon; loadAppIcon() now installs a
# copy only when the theme has none. Keep it that way: one writer, one source.
# docs/ICONS.md has the full list of surfaces and their refresh commands.
if(UNIX AND NOT APPLE)
    install(FILES packaging/io.github.immineal.TidalWave.desktop
        DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)

    # Sweep up the entry this one replaced. `cmake --install` is the only
    # install path with no package manager behind it, so for anyone who
    # installed before the rename nothing owns the old tidal-wave.desktop and
    # nothing would ever remove it: they would get the new entry alongside the
    # old one and see this app twice in their launcher, both working, for ever.
    #
    # This cannot reach a file some other package owns. CPack and the PKGBUILD
    # both run this script into a DESTDIR staging tree that was empty a moment
    # ago, so there is never a stale entry there to find and the whole block is
    # a no-op for them; only a direct `cmake --install` onto a live prefix can
    # match, which is exactly the case that needs it. A pinned launcher
    # pointing at the old basename breaks once - accepted by the owner, and it
    # breaks either way, since the file it points at is the one being replaced.
    install(CODE "
        set(_tw_appdir \"${CMAKE_INSTALL_DATADIR}/applications\")
        if(NOT IS_ABSOLUTE \"\${_tw_appdir}\")
            set(_tw_appdir \"\${CMAKE_INSTALL_PREFIX}/\${_tw_appdir}\")
        endif()
        set(_tw_legacy \"\$ENV{DESTDIR}\${_tw_appdir}/tidal-wave.desktop\")
        if(EXISTS \"\${_tw_legacy}\")
            message(STATUS \"Removing superseded desktop entry: \${_tw_legacy}\")
            file(REMOVE \"\${_tw_legacy}\")
        endif()
    ")
    install(FILES assets/icon.png
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/128x128/apps
        RENAME tidal-wave.png)
    install(FILES assets/icon.svg
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps
        RENAME tidal-wave.svg)

    # AppStream metainfo: the file KDE Discover and GNOME Software build the
    # store listing *from*, and the one Flathub refuses a submission without.
    # Without it the app is at best a bare desktop entry with no description.
    #
    # The installed basename has to be "<component id>.metainfo.xml" exactly -
    # that is how AppStream pairs the file with the component - so the name is
    # spelled out here rather than inherited from the source file. The id is
    # io.github.immineal.TidalWave (docs/PACKAGING.md), and since the rename it
    # is also the .desktop basename above. They are still joined by <launchable>
    # inside the file rather than by being spelled alike, and the store-metadata
    # CI job checks that join; the matching the comment above describes is
    # untouched by this.
    #
    # Configured rather than copied so the version in <releases> comes from
    # project(), instead of being a second copy of 0.4.0 to forget. @ONLY
    # because ${...} means nothing in AppStream and a future <caption> with
    # braces in it should not quietly become a CMake expansion.
    set(TW_METAINFO
        "${CMAKE_CURRENT_BINARY_DIR}/io.github.immineal.TidalWave.metainfo.xml")
    configure_file(packaging/io.github.immineal.TidalWave.metainfo.xml.in
        "${TW_METAINFO}" @ONLY)
    install(FILES "${TW_METAINFO}"
        DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo)
endif()

# ── Packaging (.deb via CPack) ───────────────────────────────────────────────
# Build with: cpack -G DEB --config build/CPackConfig.cmake  (or `cpack -G DEB`
# from the build dir). Depends list covers the Qt6 runtime, the easy-to-miss QML
# runtime modules, ALSA, and ffmpeg (used for downloads). No SQL: nothing in
# src/ has ever used it, so Qt6::Sql and the two sqlite packages are gone.
if(UNIX AND NOT APPLE)
    set(CPACK_PACKAGE_NAME "tidal-wave")
    set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "A native desktop client for Tidal")
    # The Maintainer field of every .deb this produces, which `dpkg -I` prints
    # for anyone who downloads one. It carried a private address until now;
    # the project has a mailbox, and that is the only address that ships.
    set(CPACK_PACKAGE_CONTACT "Linus Linhof <tidal-wave@linu.li>")
    set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/immineal/tidal-wave")

    # What apt and every Debian mirror expect a file to be called:
    # tidal-wave_0.4.0_amd64.deb. CPack's own default is the CMake-ish
    # "tidal-wave-0.4.0-Linux.deb", which names an architecture that does not
    # exist and sorts wrongly next to anything else in a release directory.
    set(CPACK_DEBIAN_FILE_NAME "DEB-DEFAULT")

    set(CPACK_GENERATOR "DEB")
    set(CPACK_DEBIAN_PACKAGE_MAINTAINER "${CPACK_PACKAGE_CONTACT}")
    set(CPACK_DEBIAN_PACKAGE_SECTION "sound")
    set(CPACK_DEBIAN_PACKAGE_PRIORITY "optional")

    # The binary shipped with its whole symbol table attached: 4,810,408 bytes
    # installed against 3,884,384 stripped, so 926 KB of a 4.8 MB package - 19%
    # - was a .symtab nothing reads. Debian Policy 10.1 asks for it stripped,
    # and a Release build has no debug info to lose on top of that. The GNU
    # build-id survives stripping, so a backtrace off a user's machine can still
    # be symbolised against the matching unstripped build.
    set(CPACK_STRIP_FILES TRUE)

    # Debian's Description field is a one-line synopsis plus an indented
    # extended description, and only the synopsis was set - which lintian calls
    # extended-description-is-empty and which leaves every package manager's
    # detail pane blank. CPack prepends CPACK_PACKAGE_DESCRIPTION_SUMMARY as the
    # synopsis and indents what follows, so this is the long half only.
    set(CPACK_DEBIAN_PACKAGE_DESCRIPTION
"Tidal Wave is a desktop client for the Tidal music service, written in C++ with
Qt Quick rather than wrapped around a web view. It plays your collection,
playlists and mixes, searches the catalogue, follows album and artist pages, and
keeps a queue you can reorder.

It integrates with the desktop it runs on: a tray icon, MPRIS so the usual media
keys and the panel's player widget work, Chromecast output, and downloads for
offline listening. Lossless and hi-res streams are labelled where the account
allows them.

An account with an active subscription is required. This package is not produced
by or affiliated with Tidal.")
    # Every Qt dependency carries a floor, and the floor is the Qt this package
    # was actually built against rather than a number typed in by hand.
    #
    # This list used to be unversioned, with SHLIBDEPS below left to "refine it
    # automatically where possible". It never did, and the reason is structural:
    # dpkg-shlibdeps attaches a floor by asking dpkg which package owns each
    # library it links, and the Qt here resolves to ~/Qt/6.12.0/gcc_64/lib,
    # which no apt package owns. With no owning package it has nothing to
    # version and silently contributes nothing - so on every build made outside
    # a distro-Qt environment, which is every build anyone makes here, the pin
    # existed only in the README.
    #
    # What that cost, measured on a real Debian 12 "bookworm" box: the package
    # installed cleanly, 41 dependencies and no complaint, and then the binary
    # died at load with `libQt6Core.so.6: version 'Qt_6.12' not found`. An
    # install that works and then crashes is the worst of the three possible
    # outcomes; a refusal from apt naming the unmet version is the good one.
    set(TW_QT_DEB_FLOOR "${Qt6_VERSION_MAJOR}.${Qt6_VERSION_MINOR}")
    set(TW_QT_DEB_PACKAGES
        libqt6core6 libqt6gui6 libqt6widgets6 libqt6quick6 libqt6qml6
        libqt6network6 libqt6dbus6 libqt6multimedia6 libqt6svg6
        libqt6concurrent6 libqt6opengl6
        qml6-module-qtquick qml6-module-qtquick-shapes
        qml6-module-qtquick-controls qml6-module-qtquick-layouts
        qml6-module-qtquick-window qml6-module-qtquick-templates
        qml6-module-qtqml-workerscript qml6-module-qtqml-models)
    set(TW_DEB_DEPENDS "")
    foreach(pkg IN LISTS TW_QT_DEB_PACKAGES)
        list(APPEND TW_DEB_DEPENDS "${pkg} (>= ${TW_QT_DEB_FLOOR})")
    endforeach()
    # The C++ runtime needs a floor of its own, and it is not a Qt one. The
    # binary carries whatever CXXABI the compiler here emits; bookworm's GCC 12
    # libstdc++ stops below CXXABI_1.3.15, which GCC 13 introduced, so the same
    # box that could not find Qt_6.12 could not find that either. Deriving it
    # from the compiler keeps the two honest together.
    # The major alone: libstdc++6 is versioned 14.2.0-3 and friends, so a floor
    # of 14.2.1 taken from the compiler's patch version would exclude the very
    # package that carries the right ABI.
    #
    # This is an upper bound on what the binary needs, not a measurement of it:
    # the compiler's major says which ABI it *may* emit, and the binary may
    # reference nothing newer than several releases back. It is the safe
    # direction to be wrong in - it refuses installs that would have worked,
    # rather than allowing installs that crash - but it means a package built on
    # a rolling distribution asks for a libstdc++ almost nobody has. The fix for
    # an actual release is to build it against the oldest toolchain we mean to
    # support, in a container, rather than to loosen this number.
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        string(REGEX MATCH "^[0-9]+" TW_GXX_MAJOR "${CMAKE_CXX_COMPILER_VERSION}")
        list(APPEND TW_DEB_DEPENDS "libstdc++6 (>= ${TW_GXX_MAJOR})")
    endif()
    # Not Qt, and versioned by the distro rather than by us.
    list(APPEND TW_DEB_DEPENDS libasound2 libavahi-client3)
    # qt6-wayland is a hard dependency by the owner's decision, 2026-10-04.
    # It was a Recommends, and `apt --no-install-recommends` then leaves a
    # Wayland-only desktop with no platform plugin: Qt falls back to xcb
    # through XWayland, so the app still starts and nothing says why it is
    # running translated. Degrading silently is the outcome the version
    # floors above exist to prevent, so this is a Depends.
    list(APPEND TW_DEB_DEPENDS qt6-wayland)
    list(JOIN TW_DEB_DEPENDS ", " CPACK_DEBIAN_PACKAGE_DEPENDS)
    set(CPACK_DEBIAN_PACKAGE_RECOMMENDS "ffmpeg")
    # Left on so it can still add anything it *can* resolve on a machine where
    # Qt does come from apt. It cannot weaken the floors above.
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)

    # Installing the icon and the .desktop file is not enough on its own: the
    # desktop's caches do not notice a new file, so without these the launcher
    # shows the old icon (or none) until something else rebuilds them. The two
    # scripts have to be mode 0755, which is what the STRICT_PERMISSION flag
    # checks, rather than leaving dpkg to refuse the package at install time.
    set(CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA
        "${CMAKE_CURRENT_SOURCE_DIR}/packaging/deb/postinst;${CMAKE_CURRENT_SOURCE_DIR}/packaging/deb/postrm")
    set(CPACK_DEBIAN_PACKAGE_CONTROL_STRICT_PERMISSION ON)

    include(CPack)
endif()
