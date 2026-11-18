// What a reused row does when it is handed another track. A list reuses its
// rows as they scroll, so anything a row rebuilds for a new track is paid on
// every row of every flick.

import QtQuick
import QtTest
import TidalWave

TestCase {
    id: testCase
    name: "RowReuse"
    when: windowShown
    visible: true
    width: 400; height: 100

    Component { id: linksC; ArtistLinks { width: 300 } }

    function named(item, name, out) {
        if (item.objectName === name) out.push(item)
        for (var i = 0; i < item.children.length; ++i) named(item.children[i], name, out)
        return out
    }

    function test_credits_of_the_same_count_keep_their_items() {
        var links = createTemporaryObject(linksC, testCase,
                                          { artistList: [{ id: 1, name: "First" }] })
        verify(links)
        var before = named(links, "ArtistName", [])
        compare(before.length, 1)
        links.artistList = [{ id: 2, name: "Second" }]
        var after = named(links, "ArtistName", [])
        compare(after.length, 1)
        compare(after[0].text, "Second")
        verify(after[0] === before[0], "the name was made again for a credit of the same count")
    }

    function test_a_longer_credit_list_still_shows_every_name() {
        var links = createTemporaryObject(linksC, testCase,
                                          { artistList: [{ id: 1, name: "First" }] })
        links.artistList = [{ id: 2, name: "Lead" }, { id: 3, name: "Guest" }]
        var names = named(links, "ArtistName", []).map(function (t) { return t.text })
        compare(names.join(","), "Lead,Guest")
        links.artistList = [{ id: 4, name: "Solo" }]
        names = named(links, "ArtistName", []).map(function (t) { return t.text })
        compare(names.join(","), "Solo")
    }
}
