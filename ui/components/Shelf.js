// The library's shelf: which games show (My library: ready to play here; Store: the others),
// in what order, gathered in groups the order explains (This week, A – D, the 1990s…), and where
// each cover stands. Covers are all the same height; each keeps its own proportions (the cover's,
// else its console's case), so a Game Boy Advance box stands square and a Switch case narrow.
// Two rows; a column is as wide as its widest cover. Pure functions: the QML only draws.
.pragma library
.import "Cases.js" as Cases

// Sizes for a shelf `height` high (its two rows and their captions): covers as tall as fits,
// between 140 and 290 (a large interface, a small window: smaller covers, never cut).
const CAPTION = 52, ROW_GAP = 34, GAP = 46, GROUP_GAP = 130
function sizes(height) {
    const tileH = Math.round(Math.max(140, Math.min(290, ((height || 640) - ROW_GAP - 2 * CAPTION) / 2)))
    return { tileH, rowH: tileH + CAPTION, heroW: Math.round(tileH * 1.92), minCol: Math.round(tileH * 0.6) }
}

// Consoles that are one in practice share a tab (core: library::JOINED).
function tabOf(slug) { return slug === "gbc" ? "gb" : (slug || "") }

function ready(g) { return g.local_state === "local" || !!g.linked }

function ratioOf(g) {
    const r = g.cover_ar
    if (r >= 0.45 && r <= 2.2) return r
    return Cases.ratio(g.platform_slug)
}

function maxPlayers(g) {
    const m = String(g.players || "").match(/\d+/g)
    return m ? Math.max.apply(null, m.map(Number)) : 1
}

function sortKey(name) {
    return String(name || "").normalize("NFD").replace(/[̀-ͯ]/g, "")
        .replace(/^(the|a|an|le|la|les|l'|l’|der|die|das|el|los|las|il|lo|gli)\s+/i, "").toLowerCase()
}

function letterOf(name) {
    const c = sortKey(name).charAt(0).toUpperCase()
    return c >= "A" && c <= "Z" ? c : "#"
}

// "Yesterday", "3 days ago"…, from a time in seconds.
function ago(secs, now) {
    const d = Math.floor((now / 1000 - secs) / 86400)
    if (d <= 0) return qsTr("Today")
    if (d === 1) return qsTr("Yesterday")
    if (d < 14) return qsTr("%n day(s) ago", "", d)
    if (d < 60) return qsTr("%n week(s) ago", "", Math.round(d / 7))
    if (d < 730) return qsTr("%n month(s) ago", "", Math.round(d / 30))
    return qsTr("%n year(s) ago", "", Math.round(d / 365))
}

function hours(secs) {
    const h = secs / 3600
    return h >= 10 ? Math.round(h) : Math.round(h * 10) / 10
}

// The orders offered, each with how it groups the games. home: offered in My library; store: in
// the Store (no play record there).
function sorts() {
    return [
        { id: "played", label: qsTr("Last played"), hint: qsTr("What you launched lately first"), home: true, store: false },
        { id: "added", label: qsTr("Added to the server"), hint: qsTr("Newest first"), home: true, store: true },
        { id: "name", label: qsTr("Name"), hint: qsTr("From A to Z"), home: true, store: true },
        { id: "time", label: qsTr("Play time"), hint: qsTr("Your most played first"), home: true, store: false },
        { id: "year", label: qsTr("Release date"), hint: qsTr("By decade, newest first"), home: true, store: true }
    ]
}

function sortsFor(tab) { return sorts().filter(s => tab === "store" ? s.store : s.home) }

function compare(sort) {
    const byName = (a, b) => sortKey(a.name).localeCompare(sortKey(b.name))
    switch (sort) {
    case "played": return (a, b) => (b.last_played || 0) - (a.last_played || 0) || byName(a, b)
    case "added": return (a, b) => b.rom_id - a.rom_id
    case "time": return (a, b) => (b.play_seconds || 0) - (a.play_seconds || 0) || byName(a, b)
    case "year": return (a, b) => (b.year || 0) - (a.year || 0) || byName(a, b)
    default: return byName
    }
}

// The group a game falls in, for a sort. rank: its place in the sorted list.
function groupOf(sort, g, rank, now) {
    const day = 86400
    switch (sort) {
    case "played": {
        if (!g.last_played) return qsTr("Not played yet")
        const d = (now / 1000 - g.last_played) / day
        return d <= 7 ? qsTr("This week") : d <= 31 ? qsTr("This month") : qsTr("Earlier")
    }
    case "time": {
        const h = (g.play_seconds || 0) / 3600
        return h <= 0 ? qsTr("Not played yet") : h >= 20 ? qsTr("Over 20 hours") : h >= 5 ? qsTr("5 to 20 hours") : qsTr("Under 5 hours")
    }
    case "year": return g.year > 0 ? qsTr("The %1s").arg(Math.floor(g.year / 10) * 10) : qsTr("Date unknown")
    case "added": return rank < 12 ? qsTr("Recently added") : qsTr("Earlier")
    default: return letterOf(g.name)
    }
}

// The line under a cover, after the order shown.
function subOf(sort, g, tab, filtered, now, fmtSize) {
    if (tab === "store" && sort !== "year") return fmtSize(g.fs_size)
    switch (sort) {
    case "played": return g.last_played ? ago(g.last_played, now) : qsTr("Never played")
    case "time": return g.play_seconds > 0 ? qsTr("%1 h played").arg(hours(g.play_seconds)) : qsTr("Never played")
    case "year": return g.year > 0 ? String(g.year) : ""
    default: return filtered ? (g.year > 0 ? String(g.year) : "") : (g.platform_name || "")
    }
}

// The quick filters, on top of the console.
function quickFilters(tab) {
    const all = [
        { id: "fav", label: qsTr("Favourites"), home: true, store: false, test: g => !!g.favourite },
        { id: "never", label: qsTr("Never played"), home: true, store: false, test: g => !g.last_played },
        { id: "multi", label: qsTr("2 players or more"), home: true, store: true, test: g => maxPlayers(g) >= 2 }
    ]
    return all.filter(q => tab === "store" ? q.store : q.home)
}

// The shelf. rows: the library (every game); opt: { tab: "home" | "store", console: tab slug or
// "", quick: { id: true }, genre, sort, height (of the two rows), consoles: [{ slug, name }] in their order, now, fmtSize }.
// Returns { tiles: [{ idx, x, cx, y, w, h, hero, row, sub, group }], groups: [{ x, w, label,
// count, slug }], total, count }. idx points into rows.
function build(rows, opt) {
    const tab = opt.tab, sort = opt.sort, now = opt.now
    const quick = quickFilters(tab).filter(q => opt.quick && opt.quick[q.id])
    const picked = []
    for (let i = 0; i < rows.length; i++) {
        const g = rows[i]
        if ((tab === "store") === ready(g)) continue
        if (opt.console && tabOf(g.platform_slug) !== opt.console) continue
        if (quick.some(q => !q.test(g))) continue
        if (opt.genre && String(g.genres || "").split(", ").indexOf(opt.genre) < 0) continue
        picked.push(i)
    }
    const cmp = compare(sort)
    picked.sort((a, b) => cmp(rows[a], rows[b]))

    const z = sizes(opt.height)
    const TILE_H = z.tileH, ROW_H = z.rowH, HERO_W = z.heroW, MIN_COL = z.minCol
    const tiles = [], groups = []
    let x = 0
    let rest = picked
    const byConsole = tab === "store" && !opt.console
    const heroLabel = byConsole ? "" : sort === "played" ? qsTr("Resume") : sort === "time" ? qsTr("Your most played")
                    : sort === "added" ? qsTr("Newest") : ""
    const heroOk = heroLabel && picked.length > 2
        && !(sort === "played" && !rows[picked[0]].last_played) && !(sort === "time" && !(rows[picked[0]].play_seconds > 0))
    if (heroOk) {
        const h = ROW_H * 2 + ROW_GAP - CAPTION
        groups.push({ x, w: HERO_W, label: heroLabel, count: "", slug: "" })
        tiles.push({ idx: picked[0], x, cx: x, y: 0, w: HERO_W, h, hero: true, row: 0, group: 0,
                     sub: subOf(sort, rows[picked[0]], tab, !!opt.console, now, opt.fmtSize) })
        x += HERO_W + GROUP_GAP
        rest = picked.slice(1)
    }
    // The groups, in order of appearance (consoles: in the consoles' order).
    let list = []
    if (byConsole) {
        for (const c of opt.consoles || []) {
            const items = rest.filter(i => tabOf(rows[i].platform_slug) === c.slug)
            if (items.length) list.push({ label: c.name, slug: c.slug, items })
        }
        const known = {}
        for (const c of opt.consoles || []) known[c.slug] = true
        const others = rest.filter(i => !known[tabOf(rows[i].platform_slug)])
        if (others.length) list.push({ label: qsTr("Other consoles"), slug: "", items: others })
    } else {
        rest.forEach((i, k) => {
            const label = groupOf(sort, rows[i], k + (heroOk ? 1 : 0), now)
            const last = list[list.length - 1]
            if (last && last.label === label) last.items.push(i)
            else list.push({ label, slug: "", items: [i] })
        })
        // By name: letters with few games are gathered (A – C) so the shelf is not a row of
        // one-game groups.
        if (sort === "name") {
            const merged = []
            for (const gr of list) {
                const last = merged[merged.length - 1]
                if (last && last.items.length < 6) { last.items = last.items.concat(gr.items); last.to = gr.label }
                else merged.push({ label: gr.label, to: gr.label, slug: "", items: gr.items.slice() })
            }
            list = merged.map(m => ({ label: m.label === m.to ? m.label : m.label + " – " + m.to, slug: "", items: m.items }))
        }
    }
    for (const gr of list) {
        const start = x, gi = groups.length
        let cx = x
        for (let k = 0; k < gr.items.length; k += 2) {
            const pair = gr.items.slice(k, k + 2)
            const widths = pair.map(i => Math.round(TILE_H * ratioOf(rows[i])))
            const colW = Math.max(MIN_COL, Math.max.apply(null, widths))
            pair.forEach((i, row) => {
                tiles.push({ idx: i, x: cx + (colW - widths[row]) / 2, cx, y: row * (ROW_H + ROW_GAP), w: widths[row], h: TILE_H,
                             hero: false, row, group: gi, sub: subOf(sort, rows[i], tab, !!opt.console, now, opt.fmtSize) })
            })
            cx += colW + GAP
        }
        const w = Math.max(cx - GAP - start, 240)
        groups.push({ x: start, w, label: gr.label, count: String(gr.items.length), slug: gr.slug })
        x = start + w + GROUP_GAP
    }
    return { tiles, groups, total: Math.max(0, x - GROUP_GAP), count: picked.length }
}

// The tile reached from tile f going "left", "right", "up" or "down"; f when there is none.
function move(tiles, f, dir) {
    const cur = tiles[f]
    if (!cur) return f
    if (dir === "up" || dir === "down") {
        if (cur.hero) return f
        const want = dir === "down" ? 1 : 0
        const j = tiles.findIndex(t => !t.hero && t.cx === cur.cx && t.row === want)
        return j >= 0 ? j : f
    }
    const right = dir === "right"
    let edge = null
    for (const t of tiles) {
        if (right ? t.cx > cur.cx + 1 : t.cx < cur.cx - 1)
            edge = edge === null ? t.cx : right ? Math.min(edge, t.cx) : Math.max(edge, t.cx)
    }
    if (edge === null) return f
    let first = -1
    for (let j = 0; j < tiles.length; j++) {
        const t = tiles[j]
        if (t.cx !== edge) continue
        if (t.hero || t.row === cur.row) return j
        if (first < 0) first = j
    }
    return first
}

// The tile of the next / previous group (LT / RT): its first one.
function jumpGroup(tiles, f, d) {
    const cur = tiles[f]
    if (!cur) return f
    const want = cur.group + d
    const j = tiles.findIndex(t => t.group === want)
    return j >= 0 ? j : f
}
