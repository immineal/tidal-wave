# Standalone CMake project for the stress runner (HANDOFF section I, SPEC X4).
#
# Deliberately NOT part of the main build. tests/CMakeLists.txt globs
# tests/tst_*.cpp and tests/qml/tst_*.qml; this directory is outside both
# globs, so ctest never picks the stress suite up and a long, deliberately
# brutal run cannot slow the normal test cycle down.
#
# It pulls the app in with add_subdirectory() rather than linking the binaries
# in build-t/, so the runner is always built against the current source and the
# repository's own CMakeLists.txt needs no edit.
#
# Configure and build (tests/stress/run.sh does this for you):
#   cmake -B /tmp/tw-stress-build -S tests/stress
#   cmake --build /tmp/tw-stress-build --parallel 4
#
cmake_minimum_required(VERSION 3.20)
project(tidalwave_stress LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

get_filename_component(TIDALWAVE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# The app, as a library plus its QML module. EXCLUDE_FROM_ALL keeps the
# tidal-wave executable itself out of the default target: the stress runner
# only needs the library.
set(TIDALWAVE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${TIDALWAVE_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/app" EXCLUDE_FROM_ALL)

find_package(Qt6 REQUIRED COMPONENTS Test QuickTest Qml Quick)

# Same dance as tests/CMakeLists.txt: linking the module's static QML plugin is
# what makes `import TidalWave` resolve inside a test binary.
get_target_property(tidalwave_qml_plugin tidalwave_qml QT_QML_MODULE_PLUGIN_TARGET)
if(NOT tidalwave_qml_plugin OR NOT TARGET ${tidalwave_qml_plugin})
    message(FATAL_ERROR "tidalwave_qml has no QML plugin target; the stress runner cannot import TidalWave.")
endif()

qt_add_executable(tst_stress
    tst_stress_main.cpp
    "${TIDALWAVE_ROOT}/tests/TestStubs.h"
)

target_include_directories(tst_stress PRIVATE
    "${TIDALWAVE_ROOT}/tests"
    "${TIDALWAVE_ROOT}/src/ui"
)

target_link_libraries(tst_stress PRIVATE
    tidalwave_qml
    ${tidalwave_qml_plugin}
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickTest
)

# Default location of the stress .qml files; run.sh overrides it with -input.
target_compile_definitions(tst_stress PRIVATE
    QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml"
)

qt_import_qml_plugins(tst_stress)

set_target_properties(tst_stress PROPERTIES
    WIN32_EXECUTABLE FALSE
    MACOSX_BUNDLE FALSE
)
