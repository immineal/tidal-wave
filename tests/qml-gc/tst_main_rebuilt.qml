// Builds the main window a dozen times with garbage in between, so collections
// start while a window is half built. ctest runs this as tst_qml_gc_whole_heap
// and fails on any incremental collection (tests/CMakeLists.txt).

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "MainRebuilt"
    when: windowShown
    width: 1000; height: 700

    Component { id: appC; Main { } }

    function test_main_is_built_again_and_again() {
        auth.setStateForTest(2)
        for (var i = 0; i < 12; ++i) {
            var junk = []
            for (var j = 0; j < (i * 3000) % 20000; ++j) junk.push({ j: j })
            var win = createTemporaryObject(appC, testCase)
            verify(win)
            wait(20)
            win.destroy()
            wait(20)
        }
    }
}
