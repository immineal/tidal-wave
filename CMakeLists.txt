cmake_minimum_required(VERSION 3.20)
project(tidal-wave VERSION 0.3.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

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

# Chromecast support (Linux only) needs Avahi for mDNS discovery.
if(UNIX AND NOT APPLE)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(AVAHI REQUIRED IMPORTED_TARGET avahi-client)
endif()

set(SOURCES
    src/main.cpp
    src/api/TidalApi.cpp
    src/api/Auth.cpp
    src/api/TidalClient.cpp
    src/api/TidalBridge.cpp
    src/player/Player.cpp
    src/player/Downloader.cpp
    src/mpris/MprisPlayer.cpp
    src/ui/Application.cpp
    src/ui/ImageProvider.cpp
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

qt_add_executable(tidal-wave
    ${SOURCES}
    ${HEADERS}
)

qt_policy(SET QTP0001 NEW)
qt_policy(SET QTP0004 NEW)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(tidal-wave
    URI TidalWave
    VERSION 1.0
    QML_FILES
        qml/Theme.qml
        qml/Main.qml
        qml/components/PlayerBar.qml
        qml/components/SideBar.qml
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
)

target_include_directories(tidal-wave PRIVATE src src/api src/player src/mpris src/ui src/cast)

target_link_libraries(tidal-wave PRIVATE
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
    target_link_libraries(tidal-wave PRIVATE PkgConfig::AVAHI)
endif()

set_target_properties(tidal-wave PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER com.tidalwave.client
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

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
    set(CPACK_PACKAGE_CONTACT "Linus Linhof <nussscheibe@gmail.com>")
    set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/user/tidal-wave")

    set(CPACK_GENERATOR "DEB")
    set(CPACK_DEBIAN_PACKAGE_MAINTAINER "${CPACK_PACKAGE_CONTACT}")
    set(CPACK_DEBIAN_PACKAGE_SECTION "sound")
    set(CPACK_DEBIAN_PACKAGE_PRIORITY "optional")
    set(CPACK_DEBIAN_PACKAGE_DEPENDS
        "libqt6core6, libqt6gui6, libqt6widgets6, libqt6quick6, libqt6qml6, libqt6network6, libqt6dbus6, libqt6multimedia6, libqt6sql6, libqt6svg6, libqt6sql6-sqlite, qml6-module-qtquick, qml6-module-qtquick-controls, qml6-module-qtquick-layouts, qml6-module-qtquick-window, qml6-module-qtquick-templates, qml6-module-qtqml-workerscript, libasound2, libavahi-client3")
    set(CPACK_DEBIAN_PACKAGE_RECOMMENDS "ffmpeg")
    # Let dpkg-shlibdeps refine the library deps automatically where possible.
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)

    include(CPack)
endif()
