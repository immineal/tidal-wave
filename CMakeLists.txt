cmake_minimum_required(VERSION 3.20)
project(tidal-wave VERSION 0.4.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Opt-in, so a plain build needs no Qt6::Test or QuickTest.
option(TIDALWAVE_BUILD_TESTS "Build tests" OFF)
option(TIDALWAVE_REQUIRE_TRANSLATIONS "Fail the configure step when lrelease is missing" OFF)

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
    # QQuickStyle, to pin the Controls style to Basic.
    QuickControls2
)

qt_standard_project_setup()

# QTP0001 exists from Qt 6.5 and QTP0004 from Qt 6.8, and setting an unknown
# policy is a hard error. Set before qt_add_qml_module(), whose resource
# prefix QTP0001 decides.
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
    src/player/GrowingFileServer.cpp
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
    src/ui/SignalWatcher.cpp
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
    src/player/GrowingFileServer.h
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
    src/ui/SignalWatcher.h
    src/api/LibraryIndex.h
)

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
# A static library, so that the app and tests/ link the same module,
# resources included. A test binary cannot link an executable.
qt_add_library(tidalwave_qml STATIC
    ${SOURCES}
    ${HEADERS}
)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(tidalwave_qml
    URI TidalWave
    VERSION 1.0
    # Pinned: QTP0001 only exists from Qt 6.5, and under the Qt 6.4 default
    # the resources land at ":/TidalWave/...", off the engine's "qrc:/qt/qml"
    # import path, so `import TidalWave` resolves nothing.
    RESOURCE_PREFIX "/qt/qml"
    # Otherwise the module lands in the build root, which does not match the
    # TidalWave target path, and Qt warns that qmllint may misbehave.
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

# Qt 6.4's qmlcachegen emits AOT code that reads a property off a null
# QQuickItem in QueuePanel's delegate and crashes. --only-bytecode skips the
# AOT step and keeps the bytecode cache.
if(Qt6_VERSION VERSION_LESS 6.5)
    set_target_properties(tidalwave_qml PROPERTIES
        QT_QMLCACHEGEN_ARGUMENTS "--only-bytecode")
endif()

# PUBLIC: tests include the same headers by the same short paths as the app.
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
    Qt6::QuickControls2
)

if(UNIX AND NOT APPLE)
    target_link_libraries(tidalwave_qml PUBLIC PkgConfig::AVAHI)
endif()

# ── Application ──────────────────────────────────────────────────────────────
qt_add_executable(tidal-wave
    src/main.cpp
)

target_link_libraries(tidal-wave PRIVATE tidalwave_qml)

# The module is static, so the app must link its plugin or QML loading fails
# with "module TidalWave is not installed". qt_import_qml_plugins() would scan
# the whole repo and make QtTest a dependency of the app, so the scan is off.
set_target_properties(tidal-wave PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)

get_target_property(tidalwave_qml_plugin tidalwave_qml QT_QML_MODULE_PLUGIN_TARGET)
if(NOT tidalwave_qml_plugin OR NOT TARGET ${tidalwave_qml_plugin})
    message(FATAL_ERROR "tidalwave_qml has no QML plugin target to link into tidal-wave.")
endif()
target_link_libraries(tidal-wave PRIVATE ${tidalwave_qml_plugin})

# `cmake --install` drops the build RPATH, so a Qt outside the default linker
# path would be lost. CMAKE_INSTALL_RPATH_USE_LINK_PATH does not cover it: Qt
# reaches the link line through a static library.
if(UNIX AND NOT APPLE)
    get_target_property(_tw_qt_core Qt6::Core IMPORTED_LOCATION_RELEASE)
    if(NOT _tw_qt_core)
        get_target_property(_tw_qt_core Qt6::Core IMPORTED_LOCATION)
    endif()
    if(_tw_qt_core)
        get_filename_component(_tw_qt_libdir "${_tw_qt_core}" DIRECTORY)
        # Only when the linker would not find it anyway: a distro Qt in a
        # default directory needs no RUNPATH entry, and lintian flags one.
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
    # CFBundleName: the title of the macOS application menu.
    MACOSX_BUNDLE_BUNDLE_NAME "Tidal Wave"
    # com.tidalwave is the preferences domain QSettings writes under on macOS.
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
# CI and the release workflow set this: a missing lrelease is otherwise
# silent and the build ships English only.
if(TIDALWAVE_REQUIRE_TRANSLATIONS AND NOT Qt6LinguistTools_FOUND)
    message(FATAL_ERROR
        "TIDALWAVE_REQUIRE_TRANSLATIONS is on and Qt6 LinguistTools was not "
        "found, so the .qm catalogues would be skipped and the build would "
        "ship English only. Install the Qt tools package that carries lrelease.")
endif()
if(Qt6LinguistTools_FOUND)
    # Do not add LRELEASE_OPTIONS without reading
    # tests/tst_shortcuts.cpp::theUnfinishedFlagIsNotLoadBearing(): that test
    # fails if the option that drops unfinished entries is named in this file.
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

# The entry's basename is the Wayland app id: it must equal
# setDesktopFileName() and the metainfo <launchable>. Icon= must equal the
# installed icon file names. docs/ICONS.md lists every icon surface.
if(UNIX AND NOT APPLE)
    install(FILES packaging/io.github.immineal.TidalWave.desktop
        DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)

    # Remove the entry this one replaced. Nothing owns the old file after a
    # plain `cmake --install`, and the launcher would show the app twice.
    # In a DESTDIR staging tree this is a no-op.
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

    # The installed basename must be "<component id>.metainfo.xml": AppStream
    # pairs the file with the component by name. Configured so <releases> takes
    # its version from project(); @ONLY because ${...} means nothing here.
    set(TW_METAINFO
        "${CMAKE_CURRENT_BINARY_DIR}/io.github.immineal.TidalWave.metainfo.xml")
    configure_file(packaging/io.github.immineal.TidalWave.metainfo.xml.in
        "${TW_METAINFO}" @ONLY)
    install(FILES "${TW_METAINFO}"
        DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo)
endif()

# ── Packaging (.deb via CPack) ───────────────────────────────────────────────
# Build with `cpack -G DEB` from the build directory.
if(UNIX AND NOT APPLE)
    set(CPACK_PACKAGE_NAME "tidal-wave")
    set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "A native desktop client for Tidal")
    # The Maintainer field of the .deb. Only the project mailbox ships.
    set(CPACK_PACKAGE_CONTACT "Linus Linhof <tidal-wave@linu.li>")
    set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/immineal/tidal-wave")

    # The Debian naming scheme, tidal-wave_<version>_<arch>.deb, in place of
    # CPack's "tidal-wave-<version>-Linux.deb".
    set(CPACK_DEBIAN_FILE_NAME "DEB-DEFAULT")

    set(CPACK_GENERATOR "DEB")
    set(CPACK_DEBIAN_PACKAGE_MAINTAINER "${CPACK_PACKAGE_CONTACT}")
    set(CPACK_DEBIAN_PACKAGE_SECTION "sound")
    set(CPACK_DEBIAN_PACKAGE_PRIORITY "optional")

    # Debian Policy 10.1 asks for a stripped binary. The GNU build-id survives,
    # so a backtrace can still be symbolised against an unstripped build.
    set(CPACK_STRIP_FILES TRUE)

    # The extended description only: CPack prepends
    # CPACK_PACKAGE_DESCRIPTION_SUMMARY as the synopsis and indents the rest.
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
    # Every Qt dependency gets a floor taken from the Qt this was built against.
    # dpkg-shlibdeps cannot add one when no apt package owns that Qt, and an
    # unversioned package installs on an older Qt and then fails at load.
    set(TW_QT_DEB_FLOOR "${Qt6_VERSION_MAJOR}.${Qt6_VERSION_MINOR}")
    set(TW_QT_DEB_PACKAGES
        libqt6core6 libqt6gui6 libqt6widgets6 libqt6quick6 libqt6qml6
        libqt6network6 libqt6dbus6 libqt6multimedia6 libqt6svg6
        libqt6opengl6
        qml6-module-qtquick qml6-module-qtquick-shapes
        qml6-module-qtquick-controls qml6-module-qtquick-layouts
        qml6-module-qtquick-window qml6-module-qtquick-templates
        qml6-module-qtqml-workerscript qml6-module-qtqml-models)
    set(TW_DEB_DEPENDS "")
    foreach(pkg IN LISTS TW_QT_DEB_PACKAGES)
        list(APPEND TW_DEB_DEPENDS "${pkg} (>= ${TW_QT_DEB_FLOOR})")
    endforeach()
    # libstdc++ needs its own floor: the binary carries the compiler's CXXABI.
    # The major alone: the compiler's patch version can be newer than the
    # distro package that carries the same ABI.
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        string(REGEX MATCH "^[0-9]+" TW_GXX_MAJOR "${CMAKE_CXX_COMPILER_VERSION}")
        list(APPEND TW_DEB_DEPENDS "libstdc++6 (>= ${TW_GXX_MAJOR})")
    endif()
    # Not Qt, and versioned by the distro rather than by us.
    list(APPEND TW_DEB_DEPENDS libasound2 libavahi-client3)
    # A Depends: as a Recommends, `apt --no-install-recommends` leaves a
    # Wayland-only desktop without the platform plugin, and Qt silently falls
    # back to xcb through XWayland.
    list(APPEND TW_DEB_DEPENDS qt6-wayland)
    list(JOIN TW_DEB_DEPENDS ", " CPACK_DEBIAN_PACKAGE_DEPENDS)
    set(CPACK_DEBIAN_PACKAGE_RECOMMENDS "ffmpeg")
    # Left on so it can still add anything it *can* resolve on a machine where
    # Qt does come from apt. It cannot weaken the floors above.
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)

    # The scripts refresh the desktop's icon and menu caches. They must be mode
    # 0755, which STRICT_PERMISSION checks at package time.
    set(CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA
        "${CMAKE_CURRENT_SOURCE_DIR}/packaging/deb/postinst;${CMAKE_CURRENT_SOURCE_DIR}/packaging/deb/postrm")
    set(CPACK_DEBIAN_PACKAGE_CONTROL_STRICT_PERMISSION ON)

    include(CPack)
endif()

# Strip the installed binary; the build tree keeps its symbols. An explicit
# rule because cmake_install.cmake only sees CMAKE_INSTALL_DO_STRIP under
# `cmake --install --strip`. Declared last so it runs after install(TARGETS).
if(CMAKE_STRIP AND (CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "MinSizeRel"))
    # Stripped to a temporary file and renamed over the target: strip in place
    # fails with ETXTBSY while the binary is running.
    install(CODE "
        set(tw_installed \"\$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_BINDIR}/tidal-wave\")
        if(EXISTS \"\${tw_installed}\")
            execute_process(
                COMMAND \"${CMAKE_STRIP}\" --strip-unneeded -o \"\${tw_installed}.stripped\" \"\${tw_installed}\"
                RESULT_VARIABLE tw_strip_rc ERROR_VARIABLE tw_strip_err)
            if(tw_strip_rc EQUAL 0)
                file(RENAME \"\${tw_installed}.stripped\" \"\${tw_installed}\")
                message(STATUS \"Stripped \${tw_installed}\")
            else()
                file(REMOVE \"\${tw_installed}.stripped\")
                message(WARNING \"strip failed, the installed binary keeps its symbols: \${tw_strip_err}\")
            endif()
        endif()
    ")
endif()
