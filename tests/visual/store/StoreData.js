// The catalogue behind the store screenshots: real records whose sleeves and
// artist photos are under free licences (tests/visual/store/CREDITS.md). Titles,
// track lists and running times are the releases' own, from MusicBrainz. The
// playlists, play counts and the library itself are invented.
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

// The library's artists. The first eight have a photo in store/art/artist/;
// the rest show the app's own placeholder, as artists without a picture do.
var artistNames = [
    "The Postal Service", "Ben Wendel", "Josh Woodward", "Allison Crowe",
    "Midaircondo", "LARY", "Grizzly", "The Brian Landrus Kaleidoscope",
    "Baby Jey", "Bosquito", "Hello=Fire", "Shahriyar Jamshidi", "Topic",
    "Marco Di Meco"
]
var artistsWithPhotos = 8

function artistNamed(id, name, photo) {
    var art = photo ? "store/artist/" + slug(name) : ""
    return { id: id, name: name, coverUrl: art, coverUrl750: art }
}

function artist(i) { return artistNamed(3000 + i, artistNames[i], i < artistsWithPhotos) }

function artists() {
    var out = []
    for (var i = 0; i < artistNames.length; ++i) out.push(artist(i))
    return out
}

// Featured musicians on single tracks: credited, never pictured.
var guestNames = []

function guest(name) {
    var i = guestNames.indexOf(name)
    if (i < 0) { guestNames.push(name); i = guestNames.length - 1 }
    return { id: 3200 + i, name: name }
}

// ── albums ──────────────────────────────────────────────────────────────────

// Art slug, title, index into artistNames, release date, and the tracks as
// title, seconds and any featured artists. The order is the order the
// library shows them in, newest save first.
var albumRows = [
    // 0
    ["all-one", "All One", 1, "2023-04-21", [
        ["I Loves You Porgy", 340, ["Cécile McLorin Salvant"]],
        ["Wanderers", 453, ["Terence Blanchard"]],
        ["Throughout", 408, ["Bill Frisell"]],
        ["Speak Joy", 465, ["Elena Pinderhughes"]],
        ["Tenderly", 390, ["José James"]],
        ["In Anima", 482, ["Tigran Hamasyan"]]]],
    // 1
    ["newfoundland-vinyl", "Newfoundland Vinyl", 3, "2013-06-25", [
        ["Black Velvet Band", 250],
        ["Easy", 235],
        ["Men Who Die for a Living", 150],
        ["Cliffs of Baccalieu", 238],
        ["Skipper Billy's Wake", 138],
        ["Sonny's Dream", 228],
        ["Tiny Red Light", 139],
        ["The Mobile Goat Song", 194],
        ["Seven Old Ladies", 240],
        ["Sweet Forget Me Not", 209]]],
    // 2
    ["polaroids", "Polaroids", 6, "2018-01-19", [
        ["Day & Night", 212],
        ["Parents Nightmare", 211],
        ["We Stop at Nothing", 118],
        ["Hide or Run", 201],
        ["Dirty Dudes", 230],
        ["Til Sunrise", 273],
        ["Heads High, Hands Down", 191],
        ["A Calm Sea Never Made a Skillful Lad", 213],
        ["Home", 221],
        ["Wishing & Waiting", 202],
        ["The Two of Us", 225],
        ["Firefighter", 305]]],
    // 3
    ["hello-fire", "Hello=Fire", 10, "2009-10-26", [
        ["Certain Circles", 200],
        ["Far From It", 206],
        ["She Gets Remote", 180],
        ["Mirror Each Other", 210],
        ["Nature Of Our Minds", 178],
        ["She's Mine In Sorrow", 190],
        ["Faint Notion", 226],
        ["Someplace Spacious", 193],
        ["Looking Daggers", 122],
        ["I Wanna Like You", 189],
        ["They Wear Lightning", 210],
        ["Parallel", 323]]],
    // 4
    ["someday-cowboy", "Someday Cowboy", 8, "2018-09-14", [
        ["Hannah Holliday's Son", 188],
        ["U Don't Have 2 Go Alone", 212],
        ["Toboggan", 140],
        ["Someday My Space Cowboy Will Come", 196],
        ["Hundred Percent", 296],
        ["Bernice Kentner", 233],
        ["Teach Me 2 Forget", 186],
        ["Every Thing", 254],
        ["I Accept", 207]]],
    // 5
    ["future-deutsche-welle", "Future Deutsche Welle", 5, "2014-09-05", [
        ["Jung & Schön", 237],
        ["Sirenen", 246],
        ["Problem", 213],
        ["System", 214],
        ["Hollywood", 252],
        ["Propeller", 170],
        ["Outro", 224],
        ["Allein", 304],
        ["Rot", 206],
        ["Feuer", 249],
        ["Lieder über Liebe", 356],
        ["Sturm und Drang", 204],
        ["Kryptonit", 223],
        ["Revolver", 249]]],
    // 6
    ["give-up", "Give Up", 0, "2003-02-18", [
        ["The District Sleeps Alone Tonight", 284],
        ["Such Great Heights", 266],
        ["Sleeping In", 261],
        ["Nothing Better", 226],
        ["Recycled Air", 269],
        ["Clark Gable", 294],
        ["We Will Become Silhouettes", 300],
        ["This Place Is a Prison", 234],
        ["Brand New Colony", 252],
        ["Natural Anthem", 306]]],
    // 7
    ["ashes", "Ashes", 2, "2010-11-16", [
        ["Let It In", 241],
        ["Cherubs", 256],
        ["Infinite Horizon", 164],
        ["A Thousand Skins (Part 2)", 202],
        ["The Handyman's Lament", 231],
        ["Anchor", 206],
        ["Already There", 221],
        ["Together On Our Own", 297],
        ["Pompeii", 216],
        ["Swimming in Turpentine", 202],
        ["A Thousand Skins (Part 1)", 387],
        ["Motionless Land", 211]]],
    // 8
    ["lucilla", "Lucilla", 13, "2016-04-30", [
        ["Lucilla", 1130],
        ["Thinking on You", 448],
        ["End of a Day and a Sunset", 585],
        ["L'Ile des Couleurs Oubliees", 437],
        ["I Sei Palazzi a Sant'Andrea", 971],
        ["Caida de Agua", 844],
        ["Morà", 444],
        ["Up in Love, So Far Away", 669],
        ["El Dia de la Golondrina", 421]]],
    // 9
    ["sus", "Sus", 9, "2019", [
        ["Viu", 337],
        ["Satelit", 300],
        ["Eroul", 310],
        ["Bine", 296],
        ["Supernova", 301],
        ["Din Greseala", 240],
        ["Juruinta", 245],
        ["Iarna", 394],
        ["Negru", 296],
        ["Paranoia", 189],
        ["Desert", 327],
        ["Printesa Inorog", 420],
        ["Teafar", 140]]],
    // 10
    ["shopping-for-images", "Shopping for Images", 4, "2005-10-03", [
        ["Eva Stern, Shake It", 159],
        ["Could You Please Stop", 242],
        ["Serenade", 303],
        ["Coffeeshop", 153],
        ["Sorry", 355],
        ["Although I Heard", 403],
        ["Perfect Spot", 221],
        ["Who's Playing", 279],
        ["Lo-Fi Love", 477],
        ["Faces", 272],
        ["I'll Be Waiting", 351]]],
    // 11
    ["understory", "Understory: Live at the Village Vanguard", 1, "2024-10-04", [
        ["Lu - Live", 625],
        ["Proof - Live", 661],
        ["On the Trail - Live", 596],
        ["Scosh - Live", 626],
        ["Jean & Renata - Live", 474],
        ["I Saw You Say - Live", 480],
        ["Tao - Live", 497]]],
    // 12
    ["mirage", "Mirage", 7, "2013", [
        ["Arrival", 321],
        ["Sammy", 323],
        ["Don't Close Your Eyes", 344],
        ["A New Day", 103],
        ["The Thousands", 344],
        ["Someday", 306],
        ["Reach", 95],
        ["Mirage", 477],
        ["I've Been Told", 350],
        ["Three Words", 326],
        ["Jade", 372],
        ["Kismet", 182]]],
    // 13
    ["not-quite-connected", "Not Quite Connected", 2, "2007-08-21", [
        ["Darién Gap", 246],
        ["Effortless", 229],
        ["She Dreams in Blue", 317],
        ["Untitled", 207],
        ["Symmetry and the Pocket of Angels", 247],
        ["Inertia", 177],
        ["Dizzy Spells", 237],
        ["Honcho Graham From Birmingham", 268],
        ["Let Me Talk, Carol", 183],
        ["Josie Has the Upper Hand", 168],
        ["River Went Dry", 350]]],
    // 14
    ["secrets", "Secrets", 3, "2004", [
        ["How Long", 241],
        ["Raining in Baltimore", 285],
        ["Philosophy", 328],
        ["Midnight", 238],
        ["Immersed", 258],
        ["Secrets (That Aren't My Own)", 377],
        ["Montreal", 269],
        ["Sea of a Million Faces", 192],
        ["What About You", 293],
        ["Joan of Arc", 294],
        ["Whether I'm Wrong", 405]]],
    // 15
    ["the-seasons", "The Seasons", 1, "2018", [
        ["January", 407],
        ["February", 408],
        ["March", 375],
        ["April", 399],
        ["May", 396],
        ["June", 300],
        ["July", 367],
        ["August", 411],
        ["September", 239],
        ["October", 376],
        ["November", 394],
        ["December", 647]]],
    // 16
    ["curtain-call", "Curtain Call", 4, "2009", [
        ["Curtain Call", 195],
        ["Come With Me", 338],
        ["Reports on the Horizon", 197],
        ["Below", 37],
        ["Bringing Me Home", 265],
        ["The Very Eye of Night", 165],
        ["Silk, Silver and Stone", 282],
        ["Glowing Red", 362],
        ["Stay", 251],
        ["Revolve and Repeat", 295],
        ["Venetian Veil", 242]]],
    // 17
    ["miles", "Miles", 12, "2015-07-31", [
        ["Light It Up", 239, ["Jona Selle"]],
        ["Real Stars", 206, ["Marco Minella"]],
        ["Hold On", 216, ["Jona Selle"]],
        ["Up And Away", 231, ["Marco Minella"]],
        ["Find Love", 225, ["Jona Selle", "Kayef"]],
        ["All This Time", 217, ["Lili Pistorius"]],
        ["Falling Apart", 202],
        ["Hologram", 174, ["Safi"]],
        ["The Hike", 237],
        ["Eternity", 343],
        ["We Call That Life", 210, ["Jona Selle"]],
        ["Fly Away", 199, ["Lili Pistorius"]],
        ["Light It Up (Acoustic Version)", 187, ["Jona Selle"]],
        ["Real Stars (Acoustic Version)", 191, ["Marco Minella"]]]],
    // 18
    ["here-today", "Here Today", 2, "2004-04-17", [
        ["Incoherent", 278],
        ["Mona Lisa", 241],
        ["Dust", 286],
        ["Troublemaker", 238],
        ["House in My Head", 226],
        ["Learn to Fly", 205],
        ["Nothing in the Dark", 284],
        ["Soft Orange Glow", 194],
        ["Morning After", 190],
        ["Home Improvement", 240],
        ["Midnight Sun", 214],
        ["Wake Up", 240],
        ["Sleepy Thought", 270]]],
    // 19
    ["the-lullaby-of-a-nomad", "The Lullaby of a Nomad", 11, "2018-11-02", [
        ["In the Shadow of the Fatherland", 230],
        ["The Lullaby of a Nomad", 389],
        ["Decamping Path", 378],
        ["Welcomed (Xêrhatin)", 256],
        ["Garmiyanî (Garmiyan Is the Artistic Zone in East of Kurdistan)", 297],
        ["Swing in the Wind Lonely", 123],
        ["Jointly (Šan-Be-Šan)", 340],
        ["Enthusiastically in the Circle", 160]]],
    // 20
    ["crawford-street", "Crawford Street", 2, "2005-02-05", [
        ["Fight the Sea", 270],
        ["Cherry", 253],
        ["Can't Take Our Love Away", 224],
        ["Big Disco Ball", 237],
        ["The Pawnbroker's Stepdaughter", 248],
        ["The Spirit World", 231],
        ["Shower Scene", 133],
        ["Swimming to Cambodia", 220],
        ["Twelve Monkeys", 197],
        ["Hey Ruth", 203],
        ["Thanks for Coming", 230],
        ["Sundown", 258],
        ["Frannie", 191],
        ["Waiting Takes Time", 185]]],
    // 21
    ["little-light", "Little Light", 3, "2008-05-02", [
        ["Northern Lights", 250],
        ["Angels", 207],
        ["Disease", 499],
        ["Time After Time", 229],
        ["Little Light", 289],
        ["Happy People", 224],
        ["Hold Back", 251],
        ["Choose to Be", 271],
        ["Running for Home", 241],
        ["When I'm Gone", 177],
        ["Wedding Song", 242]]]
]

// The album the player is on in every scene, and the one the album page opens.
var heroAlbum = 6
var heroPlaying = 1
// Never drawn: a track with lyrics is what puts the Lyrics chip on its cover.
// Not the song's words, which do not belong in this repository.
var heroLyrics = [{ ms: 0, text: "Lyrics" }]

function trackCount(i) { return albumRows[i][4].length }

function albumCover(i) { return "store/album/" + albumRows[i][0] }

function album(i) {
    var row = albumRows[i]
    var by = artist(row[2])
    return {
        id: 2000 + i, title: row[1], artists: by.name, artistId: by.id,
        artistList: [{ id: by.id, name: by.name }],
        year: row[3].slice(0, 4), releaseDate: row[3],
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
    var row = albumRows[i][4][j]
    var credits = a.artistList.concat((row[2] || []).map(guest))
    return {
        id: 100000 + i * 100 + j,
        title: row[0],
        artists: credits.map(function (c) { return c.name }).join(", "),
        artistList: credits, artistId: a.artistId,
        albumTitle: a.title, albumId: a.id,
        albumCover: a.coverUrl, coverUrl: a.coverUrl, coverUrl80: a.coverUrl,
        duration: row[1], durationStr: clock(row[1]), trackNumber: j + 1,
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
    ["Morning Pages",             42, [0, 4, 15, 11]],
    ["Kitchen Radio",            118, [3, 13, 5, 9]],
    ["Deep Work, No Words",       67, [12, 16, 1, 8]],
    ["Slow Sunday",               31, [14, 19, 6, 21]],
    ["Long Drive North",          96, [17, 2, 18, 10]],
    ["Rain on the Tram",          24, [5, 20, 7, 15]],
    ["Songs to Repot Plants To",  53, [13, 4, 19, 0]],
    ["Dinner for Six",            38, [11, 6, 12, 3]],
    ["Run Club",                  45, [2, 3, 17, 9]],
    ["Late Shift",                72, [16, 7, 1, 21]],
    ["Borrowed from Friends",    187, [8, 10, 14, 5]],
    ["Window Seat",               29, [18, 1, 9, 13]],
    ["Quiet Loud Quiet",          16, [20, 12, 2, 6]],
    ["Favorites 2024",           104, [0, 11, 3, 17]]
]

function playlist(i) {
    var row = playlistRows[i]
    var tiles = row[2].map(function (a) { return albumRows[a][0] })
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

// Title, subtitle, and the artist whose photo is the cover, as Tidal does it.
var mixRows = [
    ["Daily Discovery", "New and familiar, picked for today",                   7],
    ["New Arrivals",    "LARY, Grizzly, Ben Wendel and more",                   5],
    ["My Mix 1",        "The Postal Service, Hello=Fire, Midaircondo and more", 0],
    ["My Mix 2",        "Allison Crowe, Josh Woodward and more",                3],
    ["My Mix 3",        "Midaircondo, Baby Jey and more",                       4],
    ["My Mix 4",        "Ben Wendel, The Brian Landrus Kaleidoscope and more",  1],
    ["My Mix 5",        "Grizzly, LARY and more",                               6],
    ["My Mix 6",        "Josh Woodward, Allison Crowe and more",                2]
]

function mix(i) {
    var row = mixRows[i]
    return { id: "store-mix-" + (i + 1), title: row[0], subtitle: row[1],
             coverUrl: artist(row[2]).coverUrl, mixType: "" }
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
var searchQuery = "josh"

// Josh Woodward is in the library; the others are what the catalogue adds.
var searchArtistNames = [
    "Josh Woodward", "Josh Ritter", "Josh Groban", "Josh Homme",
    "Josh Garrels", "Josh Rouse"
]

function searchArtists() {
    return searchArtistNames.map(function (name, i) {
        return i === 0 ? artist(2) : artistNamed(3100 + i, name, true)
    })
}

// Josh Woodward's tracks across his four albums: album, track, score.
var searchHits = [[7, 0, 93], [13, 2, 91], [20, 0, 90], [18, 1, 88],
                  [7, 8, 86], [20, 1, 74], [18, 11, 69], [13, 6, 61]]

function searchTracks() {
    return searchHits.map(function (hit) {
        var t = track(hit[0], hit[1])
        t.popularity = hit[2]
        return t
    })
}

function searchAlbums() {
    return [album(7), album(20), album(13), album(18)]
}
