// The library shelf's layout (ui/components/Shelf.js), checked without Qt:
//   node tests/shelf_test.js
// What it shows in each tab, how each order groups the games, the covers' proportions and sizes,
// and moving the selection with the gamepad.
"use strict"
const fs = require("fs")
const path = require("path")
const assert = require("assert")
const vm = require("vm")

const dir = path.join(__dirname, "..", "ui", "components")
const load = f => fs.readFileSync(path.join(dir, f), "utf8").replace(/^\.(pragma|import).*$/mg, "")
const ctx = {
    qsTr: (s, c, n) => (n === undefined ? s : s.replace("%n", n)),
    console
}
vm.createContext(ctx)
vm.runInContext("String.prototype.arg = function (a) { return this.replace(/%\\d/, a) }", ctx)
vm.runInContext("var Cases = (function () {" + load("Cases.js") + "; return { of, tint, ratio, setRatios } })()", ctx)
vm.runInContext(load("Shelf.js") + "; this.Shelf = { build, move, jumpGroup, sortsFor, quickFilters, tabOf, ready, orderConsoles, consoleOrders, layouts, recents, collections, storeCards }", ctx)
const S = ctx.Shelf
// Arrays made in the other context: compared by value.
const same = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b))

const now = Date.UTC(2026, 10, 20) // a fixed "now"
const day = 86400
const slugs = ["switch", "gba", "n64", "3ds", "psvita", "ngc", "gbc"]
const rows = []
for (let i = 0; i < 40; i++) {
    rows.push({
        rom_id: i + 1, name: ["Zelda", "Mario", "Atoll", "Basalt", "Kirby", "Metroid", "Fernway", "Lumen"][i % 8] + " " + i,
        platform_slug: slugs[i % 7], platform_name: slugs[i % 7], year: 1990 + (i % 33), players: i % 3 ? "1" : "1-2",
        local_state: i % 2 ? "local" : "remote", linked: false, favourite: i % 6 === 0, genres: i % 4 ? "Action" : "Puzzle, Action",
        last_played: i % 2 && i % 4 !== 3 ? Math.floor(now / 1000) - i * day * 3 : null, play_seconds: i % 2 ? i * 3000 : 0,
        fs_size: 1e9, cover_ar: i % 5 ? 0 : 0.7
    })
}
const consoles = ["switch", "3ds", "psvita", "gba", "gb", "n64", "ngc"].map(s => ({ slug: s, name: s.toUpperCase() }))
const opt = o => Object.assign({ tab: "home", console: "", quick: {}, genre: "", sort: "played", layout: "rows2", consoles, now, fmtSize: b => b + " B", width: 1600, height: 720 }, o)

// My library: only the games ready here; the Store: the others.
let r = S.build(rows, opt({}))
assert.strictEqual(r.count, 20)
assert.ok(r.tiles.every(t => S.ready(rows[t.idx])))
r = S.build(rows, opt({ tab: "store", sort: "added" }))
assert.strictEqual(r.count, 20)
assert.ok(r.tiles.every(t => !S.ready(rows[t.idx])))

// The Store without a console filter: by console, in the consoles' order.
same(r.groups.map(g => g.slug), ["switch", "3ds", "psvita", "gba", "gb", "n64", "ngc"])
// gbc games sit with the Game Boy.
assert.ok(r.tiles.filter(t => rows[t.idx].platform_slug === "gbc").every(t => r.groups[t.group].slug === "gb"))

// Last played: the last game played first, by time, the never played last; no large card.
r = S.build(rows, opt({}))
assert.ok(!r.tiles.some(t => t.w > 2 * t.h))
assert.strictEqual(r.groups[0].label, "This week")
assert.strictEqual(r.groups[r.groups.length - 1].label, "Not played yet")
const played = r.tiles.filter(t => rows[t.idx].last_played).map(t => rows[t.idx].last_played)
same(played, played.slice().sort((a, b) => b - a))

// By name: letters gathered so that no group but the last is tiny.
r = S.build(rows, opt({ sort: "name" }))
r.groups.slice(0, -1).forEach(g => assert.ok(Number(g.count) >= 6, g.label))

// By release date: decades, newest first.
r = S.build(rows, opt({ sort: "year" }))
assert.strictEqual(r.groups[0].label, "The 2020s")

// Filters: a console, the quick filters, a genre.
assert.ok(S.build(rows, opt({ console: "switch" })).tiles.every(t => rows[t.idx].platform_slug === "switch"))
assert.ok(S.build(rows, opt({ quick: { multi: true } })).tiles.every(t => rows[t.idx].players === "1-2"))
assert.ok(S.build(rows, opt({ genre: "Puzzle" })).tiles.every(t => rows[t.idx].genres.indexOf("Puzzle") >= 0))
assert.strictEqual(S.quickFilters("store").map(q => q.id).join(), "multi")
assert.ok(S.sortsFor("store").every(s => s.id !== "played" && s.id !== "time"))

// Covers: one height; each its own proportions (else its console's case); two to a column,
// centred in it; columns never overlap.
r = S.build(rows, opt({ sort: "name", height: 720 }))
const small = r.tiles
assert.ok(small.every(t => t.h === small[0].h))
for (const t of small) {
    const g = rows[t.idx]
    const want = g.cover_ar ? g.cover_ar : ctx.Cases.ratio(g.platform_slug)
    assert.ok(Math.abs(t.w / t.h - want) < 0.02, g.name)
}
const cols = {}
for (const t of small) (cols[t.cx] = cols[t.cx] || []).push(t)
for (const cx in cols) assert.ok(cols[cx].length <= 2 && cols[cx].every(t => t.x >= Number(cx)))
// A shorter shelf (a larger interface): smaller covers, never cut.
const shorter = S.build(rows, opt({ sort: "name", height: 520 }))
assert.ok(shorter.tiles[0].h < small[0].h && shorter.tiles[0].h >= 140)

// Moving: right goes to the next column (same row), down to the cover under, groups by LT / RT.
r = S.build(rows, opt({ sort: "name" }))
const a = r.tiles.findIndex(t => t.row === 0)
const right = S.move(r.tiles, a, "right")
assert.ok(r.tiles[right].cx > r.tiles[a].cx && r.tiles[right].row === 0)
const down = S.move(r.tiles, a, "down")
assert.ok(r.tiles[down].cx === r.tiles[a].cx && r.tiles[down].row === 1)
assert.strictEqual(S.move(r.tiles, a, "left"), a)
assert.strictEqual(r.tiles[S.jumpGroup(r.tiles, a, 1)].group, r.tiles[a].group + 1)


// The grid: lines of covers filling the width, never wider; groups one under the other.
const grid = S.build(rows, opt({ sort: "name", layout: "grid", width: 1600, height: 760 }))
assert.ok(grid.vertical && grid.tiles.every(t => t.x + t.w <= 1600))
assert.ok(grid.tiles[0].h >= 300, "large covers: " + grid.tiles[0].h)
for (let k = 1; k < grid.groups.length; k++) assert.ok(grid.groups[k].y > grid.groups[k - 1].y)
const perLine = {}
for (const t of grid.tiles) perLine[t.row] = (perLine[t.row] || 0) + 1
assert.ok(Object.values(perLine).every(n => n <= 7))
// Moving in the grid: right is the next cover, down the nearest one of the line below.
const g0 = 0, gdown = S.move(grid.tiles, g0, "down", true)
assert.strictEqual(grid.tiles[gdown].row, grid.tiles[g0].row + 1)
assert.strictEqual(S.move(grid.tiles, g0, "right", true), 1)
assert.strictEqual(S.move(grid.tiles, g0, "up", true), g0)

// One large row: taller covers, a single line.
const one = S.build(rows, opt({ sort: "name", layout: "row", height: 520 }))
assert.ok(one.tiles.every(t => t.row === 0) && one.tiles[0].h > small[0].h)
assert.strictEqual(S.move(one.tiles, 0, "down"), 0)

// The consoles' order.
const order = o => S.orderConsoles(consoles, o, rows, "home", ["ngc", "gba"]).map(c => c.slug)
same(order("name"), ["3DS", "GB", "GBA", "N64", "NGC", "PSVITA", "SWITCH"].map(x => x.toLowerCase()))
same(order("year").slice(0, 2), ["switch", "3ds"])
same(order("custom").slice(0, 2), ["ngc", "gba"])
same(order("maker").slice(-1), ["psvita"])
const playedOrder = order("played")
const secs = s => rows.filter(g => S.tabOf(g.platform_slug) === s).reduce((a, g) => a + g.play_seconds, 0)
for (let k = 1; k < playedOrder.length; k++) assert.ok(secs(playedOrder[k - 1]) >= secs(playedOrder[k]))
assert.strictEqual(S.consoleOrders().length, 6)
assert.strictEqual(S.layouts().length, 3)

// The home: the row of recent games, the collections, the Store's console cards.
{
    const rec = S.recents(rows, 12)
    assert.strictEqual(rec.length, 12)
    const r0 = rows.find(g => g.rom_id === rec[0])
    assert.ok(S.ready(r0) && r0.last_played > 0)
    // Played first (latest first), then the others.
    const lp = rec.map(id => rows.find(g => g.rom_id === id).last_played || 0)
    for (let k = 1; k < lp.length; k++) assert.ok(lp[k] <= lp[k - 1])
    assert.ok(rec.every(id => S.ready(rows.find(g => g.rom_id === id))))
    const cols = S.collections(rows, consoles)
    assert.strictEqual(cols[0].kind, "fav")
    assert.strictEqual(cols[1].kind, "multi")
    // Consoles with games ready here, in the consoles' order; gbc is in gb's.
    same(cols.filter(c => c.kind === "console").map(c => c.slug), ["switch", "3ds", "psvita", "gba", "gb", "n64", "ngc"].filter(s => rows.some(g => S.ready(g) && S.tabOf(g.platform_slug) === s)))
    assert.ok(cols.every(c => c.covers.length <= 4))
    const fav = rows.filter(g => S.ready(g) && g.favourite).length
    assert.strictEqual(cols[0].count, fav)
    // Favourites stays even when empty.
    assert.strictEqual(S.collections(rows.map(g => Object.assign({}, g, { favourite: false })), consoles)[0].count, 0)
    const cards = S.storeCards(rows, consoles)
    assert.ok(cards.length > 0 && cards.every(c => c.count > 0 && c.covers.length <= 3))
    const sw = cards.find(c => c.slug === "switch")
    assert.strictEqual(sw.count, rows.filter(g => !S.ready(g) && g.platform_slug === "switch").length)
    assert.strictEqual(sw.first, Math.max(...rows.filter(g => !S.ready(g) && g.platform_slug === "switch").map(g => g.rom_id)))
    // A fixed cover height for the folders' grid.
    const l = S.build(rows, opt({ layout: "grid", tileH: 250 }))
    assert.ok(l.tiles.every(t => t.h === 250))
}

console.log("shelf: ok")
