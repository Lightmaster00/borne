// The library's shelf: which games show (My library: ready to play here; Store: the others),
// in what order, gathered in groups the order explains (This week, A – D, the 1990s…), and where
// each cover stands. Covers of a shelf are all the same height; each keeps its own proportions
// (the cover's, else its console's case), so a Game Boy Advance box stands square and a Switch
// case narrow. Three layouts, chosen in the Sort menu or Settings:
//   grid   large covers in rows that fill the width, the groups one under the other (scrolls down)
//   row    one row of large covers (the selected game's title and summary shown above it)
//   rows2  two rows (scrolls sideways)
// Pure functions: the QML only draws.
.pragma library
.import "Cases.js" as Cases

const CAPTION = 52, ROW_GAP = 34, GAP = 46, GROUP_GAP = 130, HEAD = 66, GRID_GAP = 40, GRID_ROW_GAP = 30, GRID_GROUP_GAP = 34

function layouts() {
    return [
        { id: "grid", label: qsTr("Grid"), hint: qsTr("Large covers, scroll down by sections") },
        { id: "row", label: qsTr("Large row"), hint: qsTr("One row, the selected game large above it") },
        { id: "rows2", label: qsTr("Two rows"), hint: qsTr("More games on screen") }
    ]
}
function layoutOf(id) { return ["grid", "row", "rows2"].indexOf(id) >= 0 ? id : "grid" }

// Covers' height for a shelf `width` × `height` (its rows, captions and group titles).
function sizes(layout, width, height) {
    const w = width || 1600, h = height || 720
    const clamp = (v, lo, hi) => Math.round(Math.max(lo, Math.min(hi, v)))
    if (layout === "row") return { tileH: clamp(h - HEAD, 160, 460), caption: 0, rows: 1 }
    if (layout === "rows2") return { tileH: clamp((h - HEAD - ROW_GAP - 2 * CAPTION) / 2, 140, 340), caption: CAPTION, rows: 2 }
    // Grid: about five cases of a DVD's shape to a row, never taller than most of the view.
    return { tileH: clamp(Math.min((w - 4 * GRID_GAP) / (5 * 0.72), (h - HEAD - CAPTION) * 0.66), 180, 420), caption: CAPTION, rows: 0 }
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
// "", quick: { id: true }, genre, sort, layout, width, height (of the shelf), consoles: [{ slug,
// name }] in their order, now, fmtSize }.
// Returns { tiles: [{ idx, x, cx, y, w, h, row, sub, group, caption }], groups: [{ x, y, w, label,
// count, slug }], total (width), totalH (height), vertical, count }. idx points into rows; row
// counts the lines of covers from the top (grid) or 0 / 1 (two rows).
function build(rows, opt) {
    const tab = opt.tab, sort = opt.sort, now = opt.now
    const layout = layoutOf(opt.layout)
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

    // The groups, in order of appearance (the Store without a console: by console, in the
    // consoles' order).
    let list = []
    const byConsole = tab === "store" && !opt.console
    if (byConsole) {
        for (const c of opt.consoles || []) {
            const items = picked.filter(i => tabOf(rows[i].platform_slug) === c.slug)
            if (items.length) list.push({ label: c.name, slug: c.slug, items })
        }
        const known = {}
        for (const c of opt.consoles || []) known[c.slug] = true
        const others = picked.filter(i => !known[tabOf(rows[i].platform_slug)])
        if (others.length) list.push({ label: qsTr("Other consoles"), slug: "", items: others })
    } else {
        picked.forEach((i, k) => {
            const label = groupOf(sort, rows[i], k, now)
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

    const z = sizes(layout, opt.width, opt.height)
    const H = z.tileH
    const sub = i => subOf(sort, rows[i], tab, !!opt.console, now, opt.fmtSize)
    const widthOf = i => Math.round(H * ratioOf(rows[i]))
    const tiles = [], groups = []
    if (layout === "grid") {
        const W = Math.max(400, opt.width || 1600)
        let y = 0, row = -1
        for (const gr of list) {
            const gi = groups.length
            groups.push({ x: 0, y, w: W, label: gr.label, count: String(gr.items.length), slug: gr.slug })
            y += HEAD
            let x = 0
            row++
            for (const i of gr.items) {
                const w = widthOf(i)
                if (x > 0 && x + w > W) { x = 0; y += H + CAPTION + GRID_ROW_GAP; row++ }
                tiles.push({ idx: i, x, cx: x + w / 2, y, w, h: H, row, group: gi, sub: sub(i), caption: true })
                x += w + GRID_GAP
            }
            y += H + CAPTION + GRID_ROW_GAP + GRID_GROUP_GAP
        }
        return { tiles, groups, total: W, totalH: Math.max(0, y - GRID_ROW_GAP - GRID_GROUP_GAP), vertical: true, count: picked.length }
    }
    const n = z.rows
    const minCol = Math.round(H * 0.6)
    let x = 0
    for (const gr of list) {
        const start = x, gi = groups.length
        let cx = x
        for (let k = 0; k < gr.items.length; k += n) {
            const col = gr.items.slice(k, k + n)
            const widths = col.map(widthOf)
            const colW = Math.max(minCol, Math.max.apply(null, widths))
            col.forEach((i, row) => {
                tiles.push({ idx: i, x: cx + (colW - widths[row]) / 2, cx, y: HEAD + row * (H + z.caption + ROW_GAP), w: widths[row], h: H,
                             row, group: gi, sub: sub(i), caption: n > 1 })
            })
            cx += colW + GAP
        }
        const w = Math.max(cx - GAP - start, 240)
        groups.push({ x: start, y: 0, w, label: gr.label, count: String(gr.items.length), slug: gr.slug })
        x = start + w + GROUP_GAP
    }
    return { tiles, groups, total: Math.max(0, x - GROUP_GAP), totalH: HEAD + n * (H + z.caption) + (n - 1) * ROW_GAP, vertical: false, count: picked.length }
}

// The tile reached from tile f going "left", "right", "up" or "down"; f when there is none.
function move(tiles, f, dir, vertical) {
    const cur = tiles[f]
    if (!cur) return f
    if (vertical) {
        // The grid: left and right along the covers, up and down to the nearest cover of the line
        // above or below.
        if (dir === "left") return f > 0 ? f - 1 : f
        if (dir === "right") return f < tiles.length - 1 ? f + 1 : f
        const want = cur.row + (dir === "down" ? 1 : -1)
        let best = f, bd = Infinity
        for (let j = 0; j < tiles.length; j++) {
            const t = tiles[j]
            if (t.row !== want) continue
            const d = Math.abs(t.cx - cur.cx)
            if (d < bd) { bd = d; best = j }
        }
        return best
    }
    if (dir === "up" || dir === "down") {
        const want = dir === "down" ? 1 : 0
        const j = tiles.findIndex(t => t.cx === cur.cx && t.row === want)
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
        if (t.row === cur.row) return j
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

// ---------- the consoles' order ----------
// Who made each console and when it came out (for the orders by maker and by date).
const MADE = {
    nes: ["Nintendo", 1983], famicom: ["Nintendo", 1983], fds: ["Nintendo", 1986], snes: ["Nintendo", 1990], sfam: ["Nintendo", 1990],
    n64: ["Nintendo", 1996], ngc: ["Nintendo", 2001], wii: ["Nintendo", 2006], wiiu: ["Nintendo", 2012], switch: ["Nintendo", 2017],
    gb: ["Nintendo", 1989], gbc: ["Nintendo", 1998], gba: ["Nintendo", 2001], nds: ["Nintendo", 2004], "3ds": ["Nintendo", 2011],
    n3ds: ["Nintendo", 2014], virtualboy: ["Nintendo", 1995], "pokemon-mini": ["Nintendo", 2001],
    psx: ["Sony", 1994], ps: ["Sony", 1994], ps2: ["Sony", 2000], ps3: ["Sony", 2006], ps4: ["Sony", 2013], psp: ["Sony", 2004], psvita: ["Sony", 2011],
    sms: ["Sega", 1985], genesis: ["Sega", 1988], megadrive: ["Sega", 1988], segacd: ["Sega", 1991], sega32: ["Sega", 1994],
    saturn: ["Sega", 1994], dc: ["Sega", 1998], gamegear: ["Sega", 1990],
    xbox: ["Microsoft", 2001], xbox360: ["Microsoft", 2005], "tg16": ["NEC", 1987], pce: ["NEC", 1987], ngp: ["SNK", 1998], neogeo: ["SNK", 1990],
    atari2600: ["Atari", 1977], lynx: ["Atari", 1989], jaguar: ["Atari", 1993], wonderswan: ["Bandai", 1999], arcade: ["Arcade", 1978]
}
function madeBy(slug) { return (MADE[slug] || ["", 0])[0] }
function madeIn(slug) { return (MADE[slug] || ["", 0])[1] }

function consoleOrders() {
    return [
        { id: "played", label: qsTr("Most played"), hint: qsTr("By your play time") },
        { id: "count", label: qsTr("Most games"), hint: qsTr("By their number of games") },
        { id: "year", label: qsTr("Release date"), hint: qsTr("Newest first") },
        { id: "name", label: qsTr("Name"), hint: qsTr("From A to Z") },
        { id: "maker", label: qsTr("Maker"), hint: qsTr("Nintendo, Sony, Sega… then by date") },
        { id: "custom", label: qsTr("Your order"), hint: qsTr("Move them with LB and RB in the Consoles menu") }
    ]
}

// The consoles [{ slug, name, … }] in the order chosen. rows: the library, for the play time and
// the counts (of `tab`'s games); custom: slugs in the order the player put them.
function orderConsoles(consoles, order, rows, tab, custom) {
    const played = {}, count = {}
    for (const g of rows || []) {
        const s = tabOf(g.platform_slug)
        played[s] = (played[s] || 0) + (g.play_seconds || 0)
        if ((tab === "store") !== ready(g)) count[s] = (count[s] || 0) + 1
    }
    const name = (a, b) => String(a.name).localeCompare(String(b.name))
    const keep = consoles.map((c, i) => ({ c, i }))
    const by = {
        played: (a, b) => (played[b.c.slug] || 0) - (played[a.c.slug] || 0) || a.i - b.i,
        count: (a, b) => (count[b.c.slug] || 0) - (count[a.c.slug] || 0) || a.i - b.i,
        year: (a, b) => madeIn(b.c.slug) - madeIn(a.c.slug) || name(a.c, b.c),
        name: (a, b) => name(a.c, b.c),
        maker: (a, b) => (madeBy(a.c.slug) || "~").localeCompare(madeBy(b.c.slug) || "~") || madeIn(b.c.slug) - madeIn(a.c.slug) || name(a.c, b.c),
        custom: (a, b) => {
            const pa = (custom || []).indexOf(a.c.slug), pb = (custom || []).indexOf(b.c.slug)
            return (pa < 0 ? 1e6 + a.i : pa) - (pb < 0 ? 1e6 + b.i : pb)
        }
    }
    return keep.sort(by[order] || by.played).map(x => x.c)
}
