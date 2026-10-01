// The control for NowPlayingHost: the same window, with nothing in it.
//
// Creating and destroying a top level window costs memory that has nothing to
// do with the page inside it. On X11 through llvmpipe it cost about 4.8 MiB a
// window in the first version of this suite, which was enough to look like a
// leak in NowPlayingPage and was not. Cycling this first gives the platform's
// own figure, so only the difference is charged to the page.
//
// Not named tst_*.qml, so QtQuickTest does not run it as a test case.

import QtQuick
import QtQuick.Window

Window {
    width: 1200
    height: 820
    visible: true
    color: "black"

    Rectangle {
        anchors.fill: parent
        color: "#101010"
    }
}
