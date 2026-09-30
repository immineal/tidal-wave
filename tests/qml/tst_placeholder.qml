// Placeholder QML test for the tst_qml target — copy this file as the pattern.
//
// The TidalWave module is linked into the test binary, so `import TidalWave`
// works and pages/components can be instantiated with a Component or a Loader,
// e.g.
//
//   Component { id: pageC; AlbumPage { albumId: 1 } }
//   ...
//   let page = createTemporaryObject(pageC, testCase)
//   verify(page)
//
// The auth/bridge/player/downloader/cast/app globals are the stubs from
// tests/TestStubs.h; their *ForTest() methods drive state from QML.
//
// One page needs more than the stubs: NowPlayingPage delegates its sleep timer
// to Window.window, so on its own it logs "Unable to assign [undefined]" and
// "formatSleepTime is not a function". Either instantiate Main (which provides
// them), or wrap the page in a Window declaring sleepTimerActive,
// sleepStopAtEndOfTrack, sleepTimeLeft, sleepIsFading, sleepFadeOut and
// startSleepTimer()/cancelSleepTimer()/formatSleepTime().
//
// Tests that need a shown window / event delivery want `when: windowShown`.

import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "Placeholder"

    function test_placeholder() {
        verify(true)
    }
}
