// The reduce-motion choice in Settings: follow the system, or force it on
// or off. Application resolves it against the desktop (tst_reduced_motion.cpp).

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "ReducedMotionSetting"
    when: windowShown

    Component { id: hostC; Window { width: 1100; height: 1200 } }
    Component { id: settingsC; SettingsPanel { } }

    function init() {
        auth.setStateForTest(2)
        prefs.reducedMotion = "system"
    }
    function cleanup() { prefs.reducedMotion = "system" }

    function named(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = named(item.children[i], name)
            if (hit) return hit
        }
        return null
    }

    function test_the_picker_writes_the_choice() {
        var host = createTemporaryObject(hostC, testCase)
        host.visible = true
        var panel = createTemporaryObject(settingsC, host.contentItem)
        panel.open()
        tryVerify(function () { return panel.opened }, 1000)
        var combo = named(panel.contentItem, "settingsReducedMotion")
        verify(combo, "Settings has no reduce-motion picker")
        var values = combo.options.map(function (o) { return o.value })
        compare(values.join(","), "system,on,off")
        compare(combo.currentIndex, 0)
        combo.activated(1)
        compare(prefs.reducedMotion, "on")
        combo.activated(2)
        compare(prefs.reducedMotion, "off")
        panel.close()
    }
}
