# Test targets. They link tidalwave_qml for the app's C++ and its QML module.
# Only reached with -DTIDALWAVE_BUILD_TESTS=ON, so Test and QuickTest are found
# here.
find_package(Qt6 REQUIRED COMPONENTS Test QuickTest)

# Link the module's static QML plugin target. qt_import_qml_plugins() alone only
# finds the module once a tests/qml file imports TidalWave, and only after a
# re-configure.
get_target_property(tidalwave_qml_plugin tidalwave_qml QT_QML_MODULE_PLUGIN_TARGET)
if(NOT tidalwave_qml_plugin OR NOT TARGET ${tidalwave_qml_plugin})
    message(FATAL_ERROR
        "tidalwave_qml has no QML plugin target; tests cannot import TidalWave.")
endif()

# ── tst_core: plain QTest console test ───────────────────────────────────────
# One binary per tst_*.cpp, because each carries its own QTEST_MAIN.
file(GLOB TEST_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/tst_*.cpp")
list(REMOVE_ITEM TEST_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/tst_qml.cpp")

set(CORE_TEST_TARGETS "")
foreach(test_src IN LISTS TEST_SOURCES)
    get_filename_component(test_name "${test_src}" NAME_WE)
    qt_add_executable(${test_name} "${test_src}" TestStubs.h)
    target_link_libraries(${test_name} PRIVATE
        tidalwave_qml
        ${tidalwave_qml_plugin}
        Qt6::Test
    )
    qt_import_qml_plugins(${test_name})
    set_target_properties(${test_name} PROPERTIES
        WIN32_EXECUTABLE FALSE
        MACOSX_BUNDLE FALSE
    )
    add_test(NAME ${test_name} COMMAND ${test_name})
    list(APPEND CORE_TEST_TARGETS ${test_name})
endforeach()

# These tests read the QML sources as text. They are given the source tree's
# path so that a failure message can name the file to open.
foreach(reads_qml_as_text tst_shortcuts tst_startup tst_qml_cpp_calls)
    if(TARGET ${reads_qml_as_text})
        target_compile_definitions(${reads_qml_as_text} PRIVATE
            TIDALWAVE_QML_DIR="${CMAKE_SOURCE_DIR}/qml")
    endif()
endforeach()

# ── tst_qml: QtQuickTest runner over tests/qml/tst_*.qml ─────────────────────
qt_add_executable(tst_qml
    tst_qml.cpp
    TestStubs.h
)

target_link_libraries(tst_qml PRIVATE
    tidalwave_qml
    ${tidalwave_qml_plugin}
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickTest
)

# Where QUICK_TEST_MAIN_WITH_SETUP looks for tst_*.qml.
target_compile_definitions(tst_qml PRIVATE
    QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml"
)

qt_import_qml_plugins(tst_qml)

set_target_properties(tst_qml PROPERTIES
    WIN32_EXECUTABLE FALSE
    MACOSX_BUNDLE FALSE
)

add_test(NAME tst_qml COMMAND tst_qml)

# QML tests need a QPA plugin. Forcing offscreen keeps `ctest` working on a
# headless box (and in CI) and stops test windows flashing on a desktop.
set_tests_properties(${CORE_TEST_TARGETS} tst_qml PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)

# ctest's default of 1500 seconds is too close to what tst_qml takes on a slow
# runner. The core binaries finish in under a minute each, so five means a hang.
set_tests_properties(${CORE_TEST_TARGETS} PROPERTIES TIMEOUT 300)
set_tests_properties(tst_qml PROPERTIES TIMEOUT 2700)
