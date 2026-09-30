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
qt_add_executable(tst_core
    tst_placeholder.cpp
    TestStubs.h
)

target_link_libraries(tst_core PRIVATE
    tidalwave_qml
    ${tidalwave_qml_plugin}
    Qt6::Test
)

# Picks up any other QML module a test imports (QtQuick, QtTest, ...).
qt_import_qml_plugins(tst_core)

set_target_properties(tst_core PROPERTIES
    WIN32_EXECUTABLE FALSE
    MACOSX_BUNDLE FALSE
)

add_test(NAME tst_core COMMAND tst_core)

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
set_tests_properties(tst_core tst_qml PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)
