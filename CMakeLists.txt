cmake_minimum_required(VERSION 3.20)
project(tidal-wave VERSION 0.1.0 LANGUAGES CXX)

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

set(SOURCES
    src/main.cpp
    src/api/TidalApi.cpp
    src/api/Auth.cpp
    src/api/TidalClient.cpp
    src/api/TidalBridge.cpp
    src/player/Player.cpp
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
    src/mpris/MprisPlayer.h
    src/ui/Application.h
    src/ui/ImageProvider.h
)

qt_add_executable(tidal-wave
    ${SOURCES}
    ${HEADERS}
)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(tidal-wave
    URI TidalWave
    VERSION 1.0
    QML_FILES
        qml/Theme.qml
        qml/main.qml
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

target_include_directories(tidal-wave PRIVATE src src/api src/player src/mpris src/ui)

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

set_target_properties(tidal-wave PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER com.tidalwave.client
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

install(TARGETS tidal-wave
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
