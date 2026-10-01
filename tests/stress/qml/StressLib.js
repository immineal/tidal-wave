// Shared data builders and helpers for the stress cases.
//
// Not a .pragma library: each test file gets its own copy, which keeps one
// test's scribbles out of the next one.

// A track map shaped like the one TidalBridge hands QML. `i` varies every
// string so nothing can be deduplicated behind our back.
function track(i) {
    return {
        id:          100000 + i,
        title:       "Ein ziemlich langer Tracktitel Nummer " + (i + 1),
        artists:     "Erster Interpret, Zweiter Interpret, Dritter Interpret",
        albumTitle:  "Ein ziemlich langer Albumtitel Nummer " + (i + 1),
        albumId:     42 + (i % 97),
        artistId:    7 + (i % 31),
        albumCover:  "",
        coverUrl:    "",
        coverUrl80:  "",
        duration:    180 + (i % 300),
        durationStr: "4:07",
        trackNumber: 1 + (i % 20),
        popularity:  i % 100,
        quality:     (i % 3 === 0) ? "HI_RES_LOSSLESS" : "LOSSLESS"
    }
}

function tracks(n) {
    var out = []
    for (var i = 0; i < n; ++i) out.push(track(i))
    return out
}

function albums(n) {
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: 200 + i, title: "Ein langer Albumtitel Nummer " + (i + 1),
                   artists: "Erster Interpret und noch ein zweiter", year: "2019",
                   coverUrl: "", type: "ALBUM", numTracks: 12 })
    return out
}

function artists(n) {
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: 300 + i, name: "Ein langer Interpretenname " + (i + 1), coverUrl: "" })
    return out
}

function playlists(n) {
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: 400 + i, uuid: "uuid-" + i,
                   title: "Eine ziemlich lange Wiedergabeliste " + (i + 1),
                   description: "Eine Beschreibung, die über mehrere Zeilen laufen kann.",
                   coverUrl: "", numTracks: 24, duration: 5400, type: "USER" })
    return out
}

function mixes(n) {
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: "mix-" + i, title: "Mein Mix Nummer " + (i + 1),
                   subtitle: "Mit vielen verschiedenen Interpreten", coverUrl: "" })
    return out
}

// Assign only properties the object actually declares.
//
// Three of the files these tests instantiate are being rebuilt by other work
// in this release. A renamed property should leave a page empty, not abort the
// whole stress run on "Cannot assign to non-existent property".
function fill(obj, props) {
    var missed = []
    for (var k in props) {
        if (obj[k] === undefined) { missed.push(k); continue }
        // Assigning undefined to a typed property throws rather than warning,
        // which would abort the test function. A binding that evaluates to
        // undefined only warns, and that is the path the pages really take, so
        // the undefined cases are fed through trackData and the lists instead.
        if (props[k] === undefined) continue
        obj[k] = props[k]
    }
    return missed
}

// Anything to a string, without throwing on undefined or null.
function str(v) {
    return (v === undefined || v === null) ? "" : ("" + v)
}

// One environment variable, read out of procfs because QML has no getenv.
// run.sh sets STRESS_SCALE so the same suite can be run short on a laptop and
// long when something needs to be reproduced. Non-Linux falls back silently.
function env(name, fallback) {
    var xhr = new XMLHttpRequest()
    try {
        xhr.open("GET", "file:///proc/self/environ", false)
        xhr.send()
        if (xhr.status !== 0 && xhr.status !== 200) return fallback
        // The file is NUL separated; the reader turns those into \u0000.
        var parts = xhr.responseText.split("\u0000")
        for (var i = 0; i < parts.length; ++i) {
            if (parts[i].indexOf(name + "=") === 0)
                return parts[i].substring(name.length + 1)
        }
    } catch (e) { /* no procfs */ }
    return fallback
}

function scale() {
    var v = parseFloat(env("STRESS_SCALE", "1"))
    return (isNaN(v) || v <= 0) ? 1 : v
}

// Peak resident set size of this process, in KiB, straight from procfs.
// Returns -1 where /proc is not readable, which is every non-Linux box.
function rssKib() {
    var xhr = new XMLHttpRequest()
    try {
        xhr.open("GET", "file:///proc/self/status", false)
        xhr.send()
        if (xhr.status !== 0 && xhr.status !== 200) return -1
        var m = /VmRSS:\s+(\d+) kB/.exec(xhr.responseText)
        return m ? parseInt(m[1], 10) : -1
    } catch (e) {
        return -1
    }
}
