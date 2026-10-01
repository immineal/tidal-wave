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
    Sql
    Svg
    Concurrent
)

qt_standard_project_setup()

# Qt policies — guarded by version so the project builds across Qt releases:
# QTP0001 exists since Qt 6.5, QTP0004 only since Qt 6.7 (setting an unknown
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
    src/player/Downloader.cpp
    src/mpris/MprisPlayer.cpp
    src/ui/Application.cpp
    src/ui/ImageProvider.cpp
    src/ui/Prefs.cpp
    src/ui/UpdateCheck.cpp
    src/ui/ThemePalette.cpp
    src/ui/I18n.cpp
    src/ui/PinStore.cpp
    src/api/LibraryIndex.cpp
)

set(HEADERS
    src/api/Models.h
    src/api/TidalApi.h
    src/api/Auth.h
    src/api/TidalClient.h
    src/api/TidalBridge.h
    src/player/Player.h
    src/player/Downloader.h
    src/mpris/MprisPlayer.h
    src/ui/Application.h
    src/ui/ImageProvider.h
    src/ui/Prefs.h
    src/ui/UpdateCheck.h
    src/ui/ThemePalette.h
    src/ui/I18n.h
    src/ui/PinStore.h
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
    Qt6::Sql
    Qt6::Svg
    Qt6::Concurrent
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

set_target_properties(tidal-wave PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER com.tidalwave.client
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

# Desktop integration (Linux). Installs a real .desktop entry and hicolor icons
# so the app appears in menus and the tray/window icon resolve by name — this
# replaces the runtime icon self-install workaround (loadAppIcon()) with a
# proper package-installed icon.
if(UNIX AND NOT APPLE)
    install(FILES packaging/tidal-wave.desktop
        DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
    install(FILES assets/icon.png
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/128x128/apps
        RENAME tidal-wave.png)
    install(FILES assets/icon.svg
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps
        RENAME tidal-wave.svg)
endif()

# ── Packaging (.deb via CPack) ───────────────────────────────────────────────
# Build with: cpack -G DEB --config build/CPackConfig.cmake  (or `cpack -G DEB`
# from the build dir). Depends list covers the Qt6 runtime, the easy-to-miss QML
# runtime modules, the SQLite driver, ALSA, and ffmpeg (used for downloads).
if(UNIX AND NOT APPLE)
    set(CPACK_PACKAGE_NAME "tidal-wave")
    set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "A native desktop client for Tidal")
    set(CPACK_PACKAGE_CONTACT "Linus Linhof <tidal-wave@linu.li>")
    set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/immineal/tidal-wave")

    set(CPACK_GENERATOR "DEB")
    set(CPACK_DEBIAN_PACKAGE_MAINTAINER "${CPACK_PACKAGE_CONTACT}")
    set(CPACK_DEBIAN_PACKAGE_SECTION "sound")
    set(CPACK_DEBIAN_PACKAGE_PRIORITY "optional")
    set(CPACK_DEBIAN_PACKAGE_DEPENDS
        "libqt6core6, libqt6gui6, libqt6widgets6, libqt6quick6, libqt6qml6, libqt6network6, libqt6dbus6, libqt6multimedia6, libqt6sql6, libqt6svg6, libqt6sql6-sqlite, qml6-module-qtquick, qml6-module-qtquick-shapes, qml6-module-qtquick-controls, qml6-module-qtquick-layouts, qml6-module-qtquick-window, qml6-module-qtquick-templates, qml6-module-qtqml-workerscript, libqt6concurrent6, libqt6opengl6, libasound2, libavahi-client3")
    set(CPACK_DEBIAN_PACKAGE_RECOMMENDS "ffmpeg, qt6-wayland")
    # Let dpkg-shlibdeps refine the library deps automatically where possible.
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)

    include(CPack)
endif()
