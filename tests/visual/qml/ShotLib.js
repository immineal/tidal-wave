// Shared fixtures and helpers for the screenshot scenes.
//
// Not a .pragma library, for the same reason tests/stress/qml/StressLib.js is
// not: each scene file gets its own copy, so one scene's scribbles cannot
// reach the next.

// ── the themes a scene is shot in ───────────────────────────────────────────

// All six, and the three the brief cares most about. The light pair is the
// risk, so they are in both lists.
var allThemes   = ["midnight", "forest", "ember", "deep", "daylight", "paper"]
var coreThemes  = ["midnight", "daylight", "paper"]

// ── fixtures ────────────────────────────────────────────────────────────────

// Shaped like what TidalBridge hands QML. Real-looking strings rather than
// lorem, and long enough in places to show elision where elision is the plan.
function track(i) {
    var titles = [
        "Everything In Its Right Place",
        "Weird Fishes / Arpeggi",
        "A Title That Runs On Long Enough To Need Eliding Somewhere",
        "Idioteque",
        "Pyramid Song",
        "15 Step"
    ]
    var secs = [251, 318, 197, 309, 289, 237][i % 6]
    return {
        id:          100000 + i,
        title:       titles[i % titles.length],
        artists:     (i % 3 === 2) ? "Radiohead, Thom Yorke, Jonny Greenwood"
                                   : "Radiohead",
        // PlayerBar draws one clickable link per entry and falls back to the
        // joined string above when the list is missing, so both halves of that
        // are populated here.
        artistList:  (i % 3 === 2)
                     ? [{ id: 7, name: "Radiohead" }, { id: 8, name: "Thom Yorke" },
                        { id: 9, name: "Jonny Greenwood" }]
                     : [{ id: 7, name: "Radiohead" }],
        albumTitle:  (i % 2 === 0) ? "Kid A" : "In Rainbows (Deluxe Edition)",
        albumId:     42 + (i % 7),
        artistId:    7,
        albumCover:  "cover/" + (i % 7),
        coverUrl:    "cover/" + (i % 7),
        coverUrl80:  "cover/" + (i % 7),
        duration:    secs,
        durationStr: Math.floor(secs / 60) + ":" + ("0" + (secs % 60)).slice(-2),
        trackNumber: i + 1,
        popularity:  [72, 54, 91, 33, 68, 12][i % 6],
        quality:     (i % 3 === 0) ? "HI_RES_LOSSLESS" : "LOSSLESS"
    }
}

function tracks(n) {
    var out = []
    for (var i = 0; i < n; ++i) out.push(track(i))
    return out
}

function albums(n) {
    var names = ["Kid A", "In Rainbows", "OK Computer", "Amnesiac",
                 "Hail To The Thief", "A Moon Shaped Pool"]
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: 200 + i, title: names[i % names.length],
                   artists: "Radiohead", year: "" + (1997 + (i % 20)),
                   coverUrl: "cover/album" + i, type: "ALBUM", numTracks: 10 + i })
    return out
}

function artists(n) {
    var names = ["Radiohead", "Boards of Canada", "Aphex Twin", "Portishead",
                 "Massive Attack", "Burial"]
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: 300 + i, name: names[i % names.length],
                   coverUrl: "cover/artist" + i })
    return out
}

function playlists(n) {
    var names = ["Late Night Drive", "Focus", "Sunday Morning",
                 "A Playlist With A Fairly Long Name On It", "Running", "Ambient"]
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: 400 + i, uuid: "uuid-" + i, title: names[i % names.length],
                   description: "Thirty-odd tracks that go together.",
                   coverUrl: "cover/pl" + i, numTracks: 24 + i,
                   duration: 5400, type: "USER" })
    return out
}

function mixes(n) {
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: "mix-" + i, title: "My Mix " + (i + 1),
                   subtitle: "Radiohead, Portishead and more",
                   coverUrl: "cover/mix" + i })
    return out
}

// The sidebar's flat library list: pinned rows first, which is the order the
// data layer guarantees and what the pinned block is counted off.
function libraryEntries() {
    return [
        { kind: "playlist", id: "p1",  title: "Late Night Drive", subtitle: "",             imageUrl: "cover/pl0",     pinned: true,  trackCount: 24 },
        { kind: "album",    id: "a1",  title: "In Rainbows",      subtitle: "Radiohead",    imageUrl: "cover/album1",  pinned: true,  trackCount: 10 },
        { kind: "album",    id: "a2",  title: "Amnesiac",         subtitle: "Radiohead",    imageUrl: "cover/album3",  pinned: false, trackCount: 11 },
        { kind: "artist",   id: "ar1", title: "Boards of Canada", subtitle: "",             imageUrl: "cover/artist1", pinned: false, trackCount: 0  },
        { kind: "mix",      id: "m1",  title: "Daily Discovery",  subtitle: "Your mix",     imageUrl: "cover/mix0",    pinned: false, trackCount: 0  },
        { kind: "playlist", id: "p2",  title: "Sunday Morning",   subtitle: "",             imageUrl: "cover/pl2",     pinned: false, trackCount: 31 },
        { kind: "album",    id: "a3",  title: "OK Computer",      subtitle: "Radiohead",    imageUrl: "cover/album2",  pinned: false, trackCount: 12 },
        { kind: "artist",   id: "ar2", title: "Portishead",       subtitle: "",             imageUrl: "cover/artist3", pinned: false, trackCount: 0  }
    ]
}

function pinItems() {
    return [
        { kind: "playlist", id: "p1", title: "Late Night Drive", subtitle: "",          imageUrl: "cover/pl0" },
        { kind: "album",    id: "a1", title: "In Rainbows",      subtitle: "Radiohead", imageUrl: "cover/album1" }
    ]
}

function albumData() {
    return {
        title: "In Rainbows", artists: "Radiohead", year: "2007",
        numTracks: 10, duration: 2823, quality: "HI_RES_LOSSLESS",
        artistId: 7, coverUrl: "cover/album1", coverUrl640: "cover/album1"
    }
}

// Assign only properties the object actually declares, so a renamed property
// leaves one panel empty instead of aborting the whole run.
function fill(obj, props) {
    var missed = []
    for (var k in props) {
        if (obj[k] === undefined) { missed.push(k); continue }
        if (props[k] === undefined) continue
        obj[k] = props[k]
    }
    return missed
}
