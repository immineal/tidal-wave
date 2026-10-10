# Test targets. Both link tidalwave_qml, so they get the app's C++ *and* the
# TidalWave QML module (files + resources + QML_ELEMENT registrations).
#
# Only reached when -DTIDALWAVE_BUILD_TESTS=ON, so Test/QuickTest are found here
# rather than in the top-level find_package().
find_package(Qt6 REQUIRED COMPONENTS Test QuickTest)

# Registering the TidalWave module in a test binary takes the module's static QML
# plugin. qt_import_qml_plugins() alone is not enough here: it runs
# qmlimportscanner over the target's own source dir, so it only finds the module
# once some tests/qml/*.qml already says "import TidalWave" (and only after a
# re-configure). Linking the plugin target pulls in its Q_IMPORT_PLUGIN init
# object as well, so the module and its C++ QML_ELEMENT types are always there.
get_target_property(tidalwave_qml_plugin tidalwave_qml QT_QML_MODULE_PLUGIN_TARGET)
if(NOT tidalwave_qml_plugin OR NOT TARGET ${tidalwave_qml_plugin})
    message(FATAL_ERROR
        "tidalwave_qml has no QML plugin target; tests cannot import TidalWave.")
endif()

# ── tst_core: plain QTest console test ───────────────────────────────────────
# One binary per tst_*.cpp, because each carries its own QTEST_MAIN. Globbed so
# adding a test file needs no edit here; CONFIGURE_DEPENDS re-runs cmake when
# the set changes.
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

# tst_shortcuts reads qml/Main.qml and qml/components/SettingsPanel.qml as text.
# It is the test that the shortcut table, the bindings in Main.qml and the rows
# the Settings panel prints cannot drift apart, and the only way to see whether a
# QML binding still goes through the table - rather than back to a literal - is
# to look at the file. Reaching them through the module's resources would work
# too, but a real path is what makes a failure message say where to go.
# tst_startup needs it for the same kind of guard: the high-DPI rule has to know
# Main.qml's default window size before any QML is loaded, so the number is
# written down in C++ too, and the test reads the file to prove they still agree.
# tst_qml_cpp_calls reads every .qml file and checks each `obj.method(` call it
# makes against the real type's meta-object. It has to be the source tree and
# not the module's resources, because the point is to name the file a bad call
# is in.
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

# ctest gives a test 1500 seconds unless it is told otherwise, and tst_qml takes
# 625 of them on a GitHub runner and 809 on a loaded desktop. A runner twice as
# slow would be killed mid-suite and reported as a failure of whichever test
# happened to be running. The core binaries finish in well under a minute each,
# so five is already a hang.
set_tests_properties(${CORE_TEST_TARGETS} PROPERTIES TIMEOUT 300)
set_tests_properties(tst_qml PROPERTIES TIMEOUT 2700)
