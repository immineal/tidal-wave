// Shared fixtures and helpers for the screenshot scenes. Not a .pragma
// library: each scene file gets its own copy, so one scene cannot reach the
// next through it.

// ── the themes a scene is shot in ───────────────────────────────────────────

// All six, and the three core ones. The light pair is in both lists.
var allThemes   = ["sea", "pine", "rust", "sky", "sand", "clay"]
var coreThemes  = ["sea", "sky", "sand"]

// ── fixtures ────────────────────────────────────────────────────────────────

// Shaped like what TidalBridge hands QML. Real-looking strings rather than
// lorem, and long enough in places to show elision where elision is the plan.
function track(i) {
    var titles = [
        "A Short Walk Home in the Rain",
        "Tidewrack / Signal Box",
        "A Title That Runs On Long Enough To Need Eliding Somewhere",
        "Postscript",
        "Pilot Light",
        "15 Step"
    ]
    var secs = [251, 318, 197, 309, 289, 237][i % 6]
    return {
        id:          100000 + i,
        title:       titles[i % titles.length],
        artists:     (i % 3 === 2) ? "Brackwater, Corin Halvey, Ines Varelund"
                                   : "Brackwater",
        // PlayerBar draws one clickable link per entry and falls back to the
        // joined string above when the list is missing, so both halves of that
        // are populated here.
        artistList:  (i % 3 === 2)
                     ? [{ id: 7, name: "Brackwater" }, { id: 8, name: "Corin Halvey" },
                        { id: 9, name: "Ines Varelund" }]
                     : [{ id: 7, name: "Brackwater" }],
        albumTitle:  (i % 2 === 0) ? "Thaw" : "Salt Lines (Deluxe Edition)",
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
    var names = ["Thaw", "Salt Lines", "Night Buses", "Kindling",
                 "Under Sodium Lights", "Small Hours, Big Sky"]
    var out = []
    for (var i = 0; i < n; ++i)
        out.push({ id: 200 + i, title: names[i % names.length],
                   artists: "Brackwater", year: "" + (1997 + (i % 20)),
                   coverUrl: "cover/album" + i, type: "ALBUM", numTracks: 10 + i })
    return out
}

function artists(n) {
    var names = ["Brackwater", "Odd Lantern Club", "Lumen Drift", "Vellum Coast",
                 "Kestrel Arcade", "Slate Meridian"]
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
                   subtitle: "Brackwater, Vellum Coast and more",
                   coverUrl: "cover/mix" + i })
    return out
}

// The sidebar's flat library list: pinned rows first, which is the order the
// data layer guarantees and what the pinned block is counted off.
function libraryEntries() {
    return [
        { kind: "playlist", id: "p1",  title: "Late Night Drive", subtitle: "",             imageUrl: "cover/pl0",     pinned: true,  trackCount: 24 },
        { kind: "album",    id: "a1",  title: "Salt Lines",       subtitle: "Brackwater",   imageUrl: "cover/album1",  pinned: true,  trackCount: 10 },
        { kind: "album",    id: "a2",  title: "Kindling",         subtitle: "Brackwater",   imageUrl: "cover/album3",  pinned: false, trackCount: 11 },
        { kind: "artist",   id: "ar1", title: "Odd Lantern Club", subtitle: "",             imageUrl: "cover/artist1", pinned: false, trackCount: 0  },
        { kind: "mix",      id: "m1",  title: "Daily Discovery",  subtitle: "Your mix",     imageUrl: "cover/mix0",    pinned: false, trackCount: 0  },
        { kind: "playlist", id: "p2",  title: "Sunday Morning",   subtitle: "",             imageUrl: "cover/pl2",     pinned: false, trackCount: 31 },
        { kind: "album",    id: "a3",  title: "Night Buses",      subtitle: "Brackwater",   imageUrl: "cover/album2",  pinned: false, trackCount: 12 },
        { kind: "artist",   id: "ar2", title: "Vellum Coast",     subtitle: "",             imageUrl: "cover/artist3", pinned: false, trackCount: 0  }
    ]
}

function pinItems() {
    return [
        { kind: "playlist", id: "p1", title: "Late Night Drive", subtitle: "",          imageUrl: "cover/pl0" },
        { kind: "album",    id: "a1", title: "Salt Lines",       subtitle: "Brackwater", imageUrl: "cover/album1" }
    ]
}

function albumData() {
    return {
        title: "Salt Lines", artists: "Brackwater", year: "2007",
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
