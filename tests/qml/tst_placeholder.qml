// Placeholder test for the tst_qml target. Copy this file as the pattern.
// The TidalWave module is linked in, so pages and components can be imported.
// The auth, bridge, player, downloader, cast and app globals are the stubs
// from tests/TestStubs.h, driven from QML through their *ForTest() methods.
// NowPlayingPage needs a Window that provides the sleep timer members.
// A test that needs a shown window or event delivery sets when: windowShown.

import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "Placeholder"

    function test_placeholder() {
        verify(true)
    }
}
