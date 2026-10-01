# Standalone CMake project for the screenshot harness.
#
# Deliberately NOT part of the main build, for the same reason tests/stress is
# not: tests/CMakeLists.txt globs tests/tst_*.cpp and tests/qml/tst_*.qml, and
# this directory sits outside both globs, so `ctest` never picks a run that
# wants a display and writes PNGs.
#
# It pulls the app in with add_subdirectory() rather than linking the binaries
# already in build-t/, so the shots are always of the current source.
#
# Configure and build (tests/visual/run.sh does this for you):
#   cmake -B /tmp/tw-vis-build -S tests/visual
#   cmake --build /tmp/tw-vis-build --parallel 4
#
cmake_minimum_required(VERSION 3.20)
project(tidalwave_visual LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

get_filename_component(TIDALWAVE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# The app as a library plus its QML module. EXCLUDE_FROM_ALL keeps the
# tidal-wave executable itself out of the default target: the shot runner only
# needs the library, and building the executable here would also build a second
# copy of something the developer already has in build-t/.
set(TIDALWAVE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${TIDALWAVE_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/app" EXCLUDE_FROM_ALL)

find_package(Qt6 REQUIRED COMPONENTS Test QuickTest Qml Quick Gui)

# Same dance as tests/CMakeLists.txt and tests/stress/CMakeLists.txt: linking
# the module's static QML plugin is what makes `import TidalWave` resolve
# inside a binary that is not the app.
get_target_property(tidalwave_qml_plugin tidalwave_qml QT_QML_MODULE_PLUGIN_TARGET)
if(NOT tidalwave_qml_plugin OR NOT TARGET ${tidalwave_qml_plugin})
    message(FATAL_ERROR "tidalwave_qml has no QML plugin target; the shot runner cannot import TidalWave.")
endif()

qt_add_executable(tst_shots
    shots_main.cpp
    "${TIDALWAVE_ROOT}/tests/TestStubs.h"
)

target_include_directories(tst_shots PRIVATE
    "${TIDALWAVE_ROOT}/tests"
    "${TIDALWAVE_ROOT}/src/ui"
)

target_link_libraries(tst_shots PRIVATE
    tidalwave_qml
    ${tidalwave_qml_plugin}
    Qt6::Qml
    Qt6::Quick
    Qt6::Gui
    Qt6::QuickTest
)

# Default location of the scene files; run.sh overrides it with -input.
target_compile_definitions(tst_shots PRIVATE
    QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml"
)

qt_import_qml_plugins(tst_shots)

set_target_properties(tst_shots PROPERTIES
    WIN32_EXECUTABLE FALSE
    MACOSX_BUNDLE FALSE
)
