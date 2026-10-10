// The catalogue behind the store screenshots. Every artist, album, track and
// playlist in this file is invented; none of it is anybody's library.
//
// Shaped like what TidalBridge hands QML, so the pages take it unchanged.

function slug(s) {
    return s.toLowerCase().replace(/&/g, "and").replace(/[^a-z0-9]+/g, "-")
            .replace(/^-+|-+$/g, "")
}

function clock(secs) {
    return Math.floor(secs / 60) + ":" + ("0" + (secs % 60)).slice(-2)
}

// ── artists ─────────────────────────────────────────────────────────────────

var artistNames = [
    "Vellum Coast", "Slate Meridian", "Brackwater", "Ines Varelund",
    "The Saltmarsh Quartet", "Kestrel Arcade", "Odd Lantern Club",
    "Corin Halvey", "Lumen Drift", "Marrow & Pine", "Northbound Static",
    "Glasshouse Atlas", "Hollow Pines Motel", "Sunday Cartographers",
    "Little Harbour Radio", "Tamsin Oyelaran-Wade"
]

function artistNamed(id, name) {
    var art = "store/artist/" + slug(name)
    return { id: id, name: name, coverUrl: art, coverUrl750: art }
}

function artist(i) { return artistNamed(3000 + i, artistNames[i]) }

function artists() {
    var out = []
    for (var i = 0; i < artistNames.length; ++i) out.push(artist(i))
    return out
}

// ── albums ──────────────────────────────────────────────────────────────────

// Title, index into artistNames, release date. The order is the order the
// library shows them in, newest save first.
var albumRows = [
    ["Paper Weather",               0, "2025-03-21"],
    ["Northern Rooms",              1, "2024-10-04"],
    ["Silt & Signal",               2, "2023-06-16"],
    ["A Field Guide to Leaving",    3, "2022-09-09"],
    ["Second Summer",               4, "2024-05-31"],
    ["Salt Lines",                  2, "2025-01-17"],
    ["Small Hours, Big Sky",        6, "2021-11-12"],
    ["Understory",                  7, "2023-02-24"],
    ["Half-Remembered Maps",       13, "2020-08-28"],
    ["Slow Machines",              10, "2024-03-08"],
    ["Glass Orchard",               5, "2022-04-22"],
    ["Winter Greenhouse",          11, "2023-12-01"],
    ["Motel Aquarium",             12, "2021-06-18"],
    ["Postcards from the Interior", 15, "2024-08-16"],
    ["Tin Roof Sessions",           0, "2022-01-28"],
    ["Kindling",                    3, "2025-02-07"],
    ["Night Buses",                 1, "2021-03-19"],
    ["The Long Field",              9, "2023-09-29"],
    ["Lanternlight",                8, "2024-11-22"],
    ["Everything Near the Water",   9, "2022-07-15"],
    ["Blue Hour Radio",            14, "2020-10-30"],
    ["Soft Static",                10, "2021-09-03"],
    ["The Quiet Engine",            5, "2023-04-14"],
    ["Low Tide Hours",              0, "2020-05-08"],
    ["Harbour Songs for No One",    4, "2022-11-18"],
    ["Driftwood Economy",           2, "2021-02-05"],
    ["Amber Signals",               8, "2023-07-21"],
    ["Room Tone",                  11, "2024-01-26"],
    ["Late Trains Home",            1, "2022-06-10"],
    ["Marigold",                   15, "2021-08-13"],
    ["Ferry to Somewhere",         14, "2024-06-28"],
    ["Under Sodium Lights",        10, "2020-12-04"],
    ["Thaw",                        7, "2021-04-02"],
    ["Cartography for Beginners",  13, "2023-10-20"],
    ["Open Windows",                6, "2024-04-19"],
    ["The Weather Indoors",         3, "2020-03-13"],
    ["Kite Season",                 9, "2025-04-11"],
    ["Nine Small Fires",           12, "2023-01-13"],
    ["Slow Bloom",                  5, "2021-10-08"],
    ["Echo Lake Demos",             6, "2022-02-18"],
    ["Tide Tables",                 4, "2020-07-24"],
    ["A Year of Sundays",          13, "2022-12-09"],
    ["Moth Hours",                  8, "2021-05-21"],
    ["Cold Coffee, Warm Tape",     12, "2024-09-13"],
    ["Outskirts",                  11, "2022-03-25"],
    ["Still Life with Radio",      14, "2023-05-19"],
    ["Low Sun",                     7, "2024-12-06"],
    ["Hinterland Hours",           15, "2023-08-25"]
]

// The album the player is on in every scene, and the one the album page opens.
var heroAlbum = 14
var heroTracks = [
    ["Estuary Light",         238, -1],
    ["Paper Boats",           255, -1],
    ["Borrowed Bicycle",      273, -1],
    ["Tin Roof Rain",         207, -1],
    ["Kelp Forest",           239,  3],
    ["Rain Gauge",            219, -1],
    ["Lamplighter",           214, -1],
    ["Second Shift",          167, -1],
    ["Salt on the Windows",   236, -1],
    ["Last Ferry Out",        248,  8],
    ["Marram Grass",          192, -1],
    ["A Map of the Shallows", 321, -1],
    ["Slack Water",           276, -1],
    ["Harbour Wall",          201, -1]
]
var heroPlaying = 2
// Never drawn: a track with lyrics is what puts the Lyrics chip on its cover.
var heroLyrics = [{ ms: 0, text: "Borrowed bicycle, the long way down to the water" }]

// Forty-one titles: a prime, so stepping through it never repeats in an album.
var trackPool = [
    "Greenhouse Glass", "Seven Streetlights", "Understudy", "Coat Check",
    "Radio Garden", "Low Sun, Long Shadows", "Pocket Atlas", "Blue Enamel",
    "Sleeper Car", "Good Morning, Machine", "Orchard Ladder", "Postscript",
    "Half a Postcard", "Rainwater Tank", "Quiet Carriage", "Night Shift Kitchen",
    "Fold-Out Map", "Thirty Miles of Fence", "Pilot Light", "Corner Shop Lights",
    "Tidewrack", "Signal Box", "Chalk Line", "Field Recording No. 4",
    "Ember Days", "Loose Change", "Two Rivers Meet", "Kite String",
    "Unsent Letter", "Milk Glass", "North Platform", "Sodium Glow",
    "A Short Walk Home", "Borrowed Light", "Waiting Room Radio", "Thimble",
    "Long Exposure", "Paper Lantern", "The Last Good Chair", "Inland",
    "Small Weather"
]

function trackCount(i) { return i === heroAlbum ? heroTracks.length : 8 + (i * 5) % 7 }

function albumCover(i) { return "store/album/" + slug(albumRows[i][0]) }

function album(i) {
    var row = albumRows[i]
    var by = artist(row[1])
    return {
        id: 2000 + i, title: row[0], artists: by.name, artistId: by.id,
        artistList: [{ id: by.id, name: by.name }],
        year: row[2].slice(0, 4), releaseDate: row[2],
        coverUrl: albumCover(i), coverUrl640: albumCover(i),
        type: "ALBUM", numTracks: trackCount(i), quality: "LOSSLESS"
    }
}

function albums() {
    var out = []
    for (var i = 0; i < albumRows.length; ++i) out.push(album(i))
    return out
}

// ── tracks ──────────────────────────────────────────────────────────────────

function track(i, j) {
    var a = album(i)
    var hero = i === heroAlbum
    var secs = hero ? heroTracks[j][1] : 150 + (i * 37 + j * 53) % 170
    var guest = hero ? heroTracks[j][2] : ((i + j) % 6 === 5 ? (a.artistId - 3000 + 3) % artistNames.length : -1)
    var credits = a.artistList.slice()
    if (guest >= 0) credits.push({ id: 3000 + guest, name: artistNames[guest] })
    return {
        id: 100000 + i * 100 + j,
        title: hero ? heroTracks[j][0] : trackPool[(i * 5 + j * 7) % trackPool.length],
        artists: credits.map(function (c) { return c.name }).join(", "),
        artistList: credits, artistId: a.artistId,
        albumTitle: a.title, albumId: a.id,
        albumCover: a.coverUrl, coverUrl: a.coverUrl, coverUrl80: a.coverUrl,
        duration: secs, durationStr: clock(secs), trackNumber: j + 1,
        popularity: 40 + (i * 11 + j * 17) % 55, quality: "LOSSLESS"
    }
}

function albumTracks(i) {
    var out = []
    for (var j = 0; j < trackCount(i); ++j) out.push(track(i, j))
    return out
}

// What `albums/<id>` answers: the list row plus the facts the hero prints.
function albumHeader(i) {
    var a = album(i)
    var total = 0
    var rows = albumTracks(i)
    for (var j = 0; j < rows.length; ++j) total += rows[j].duration
    a.duration = total
    a.copyright = "© " + a.year + " " + a.artists
    return a
}

// Two tracks in three, across the whole library: the songs that were liked.
function likedTracks() {
    var out = []
    for (var i = 0; i < albumRows.length; ++i)
        for (var j = 0; j < trackCount(i); ++j)
            if ((i + j) % 3 !== 0) out.push(track(i, j))
    return out
}

// ── playlists ───────────────────────────────────────────────────────────────

// Title, track count, and the four albums its cover is a mosaic of.
var playlistRows = [
    ["Morning Pages",             42, [4, 0, 10, 7]],
    ["Kitchen Radio",            118, [2, 13, 5, 9]],
    ["Deep Work, No Words",       67, [1, 6, 16, 11]],
    ["Slow Sunday",               31, [3, 8, 14, 17]],
    ["Long Drive North",          96, [9, 12, 0, 15]],
    ["Rain on the Tram",          24, [18, 5, 20, 1]],
    ["Songs to Repot Plants To",  53, [11, 19, 4, 22]],
    ["Dinner for Six",            38, [21, 7, 23, 2]],
    ["Run Club",                  45, [10, 26, 13, 28]],
    ["Late Shift",                72, [16, 31, 18, 27]],
    ["Borrowed from Friends",    187, [24, 3, 30, 12]],
    ["Window Seat",               29, [29, 14, 33, 8]],
    ["Quiet Loud Quiet",          16, [36, 25, 6, 38]],
    ["Favorites 2024",           104, [1, 4, 13, 18]]
]

function playlist(i) {
    var row = playlistRows[i]
    var tiles = row[2].map(function (a) { return slug(albumRows[a][0]) })
    return {
        id: 4000 + i, uuid: "store-playlist-" + (i + 1), title: row[0],
        description: "", coverUrl: "store/playlist/" + tiles.join("+"),
        numTracks: row[1], duration: row[1] * 214, type: "USER"
    }
}

function playlists() {
    var out = []
    for (var i = 0; i < playlistRows.length; ++i) out.push(playlist(i))
    return out
}

// ── mixes ───────────────────────────────────────────────────────────────────

var mixRows = [
    ["Daily Discovery", "New and familiar, picked for today"],
    ["New Arrivals",    "Slate Meridian, Lumen Drift, Corin Halvey and more"],
    ["My Mix 1",        "Vellum Coast, Brackwater, Marrow & Pine and more"],
    ["My Mix 2",        "Ines Varelund, Corin Halvey and more"],
    ["My Mix 3",        "Kestrel Arcade, Northbound Static and more"],
    ["My Mix 4",        "The Saltmarsh Quartet, Glasshouse Atlas and more"],
    ["My Mix 5",        "Odd Lantern Club, Hollow Pines Motel and more"],
    ["My Mix 6",        "Sunday Cartographers, Little Harbour Radio and more"]
]

function mix(i) {
    var row = mixRows[i]
    return { id: "store-mix-" + (i + 1), title: row[0], subtitle: row[1],
             coverUrl: "store/mix/" + i + "/" + slug(row[0]), mixType: "" }
}

function mixes() {
    var out = []
    for (var i = 0; i < mixRows.length; ++i) out.push(mix(i))
    return out
}

// The tile shape HomePage builds out of a fetched mix.
function homeMixes() {
    return mixes().map(function (m) {
        return { id: m.id, title: m.title, subtitle: m.subtitle,
                 coverUrl: m.coverUrl, type: "mix", mixType: m.mixType }
    })
}

// ── the sidebar ─────────────────────────────────────────────────────────────

function playlistEntry(i, pinned) {
    var p = playlist(i)
    return { kind: "playlist", id: p.uuid, title: p.title, subtitle: "",
             imageUrl: p.coverUrl, pinned: pinned === true, trackCount: p.numTracks }
}

function albumEntry(i, pinned) {
    var a = album(i)
    return { kind: "album", id: "" + a.id, title: a.title, subtitle: a.artists,
             imageUrl: a.coverUrl, pinned: pinned === true, trackCount: a.numTracks }
}

function artistEntry(i) {
    var a = artist(i)
    return { kind: "artist", id: "" + a.id, title: a.name, subtitle: "",
             imageUrl: a.coverUrl, pinned: false, trackCount: 0 }
}

function mixEntry(i) {
    var m = mix(i)
    return { kind: "mix", id: m.id, title: m.title, subtitle: m.subtitle,
             imageUrl: m.coverUrl, pinned: false, trackCount: 0 }
}

// Pinned rows first, which is the order the library index guarantees.
function libraryEntries() {
    return [
        playlistEntry(0, true), albumEntry(heroAlbum, true),
        playlistEntry(1), albumEntry(1), artistEntry(1), playlistEntry(2),
        mixEntry(2), albumEntry(10), playlistEntry(4), artistEntry(5),
        albumEntry(4), playlistEntry(6), artistEntry(3), albumEntry(7),
        playlistEntry(3), albumEntry(18)
    ]
}

function pinItems() {
    return libraryEntries().filter(function (e) { return e.pinned })
        .map(function (e) {
            return { kind: e.kind, id: e.id, title: e.title,
                     subtitle: e.subtitle, imageUrl: e.imageUrl }
        })
}

// ── search ──────────────────────────────────────────────────────────────────

// Only artist names start with the query, so Artists is the section that leads.
var searchQuery = "brack"

var searchArtistNames = [
    "Brackwater", "Brackwater Choir", "Brack & Thistle", "Bracken Hours",
    "Brackley Sound", "Brackish Kids", "Brackenridge Tapes", "Brackmoor"
]

function searchArtists() {
    return searchArtistNames.map(function (name, i) {
        return i === 0 ? artist(2) : artistNamed(3100 + i, name)
    })
}

// The top hits are the library's own Brackwater tracks: album, track, score.
var searchHits = [[2, 0, 93], [2, 3, 91], [5, 1, 90], [5, 4, 88], [25, 2, 86]]

// The rest of the catalogue's answer: title, artist, album, seconds, score.
var searchOtherTracks = [
    ["Chalk Line", "Brackwater Choir", "Low Ceiling Hymns", 248, 74],
    ["Ember Days", "Bracken Hours",    "Fern Season",       205, 69],
    ["Milk Glass", "Brack & Thistle",  "Hedgerow Tapes",    193, 61]
]

function searchTracks() {
    var out = searchHits.map(function (hit) {
        var t = track(hit[0], hit[1])
        t.popularity = hit[2]
        return t
    })
    searchOtherTracks.forEach(function (row, i) {
        var art = "store/album/" + slug(row[2])
        var by = artistNamed(3100 + searchArtistNames.indexOf(row[1]), row[1])
        out.push({
            id: 150000 + i, title: row[0], artists: by.name,
            artistList: [{ id: by.id, name: by.name }], artistId: by.id,
            albumTitle: row[2], albumId: 2600 + i,
            albumCover: art, coverUrl: art, coverUrl80: art,
            duration: row[3], durationStr: clock(row[3]), trackNumber: i + 1,
            popularity: row[4], quality: "LOSSLESS"
        })
    })
    return out
}

function searchAlbums() {
    var out = [album(2), album(5), album(25)]
    var more = [["Low Ceiling Hymns", "Brackwater Choir"],
                ["Fern Season",       "Bracken Hours"],
                ["Hedgerow Tapes",    "Brack & Thistle"],
                ["Platform Two",      "Brackley Sound"],
                ["Puddle Jumpers",    "Brackish Kids"]]
    more.forEach(function (row, i) {
        out.push({ id: 2600 + i, title: row[0], artists: row[1],
                   coverUrl: "store/album/" + slug(row[0]), type: "ALBUM",
                   numTracks: 9 + i % 4 })
    })
    return out
}
