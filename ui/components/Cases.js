// The real retail case of each console's games: material, plastic color and outer size in
// millimetres (width × height × thickness, as sold in Europe / North America). Cases are drawn to
// scale against each other: a PlayStation jewel case is small and nearly square, a GameCube case
// tall, a Super Nintendo box wide. Printed artwork (cover, spine, logos) comes only from the
// user's RomM scans; nothing is drawn here.
// Materials: "card" (printed cardboard box), "keep" (plastic keep case under a clear sleeve),
// "jewel" (clear CD case with a black tray and hinge), "clam" (hard plastic clamshell).
.pragma library

const CASES = {
    nes:       { mat: "card",  color: "#26262a", w: 127, h: 184, d: 32 },
    famicom:   { mat: "card",  color: "#26262a", w: 127, h: 92,  d: 25 },
    snes:      { mat: "card",  color: "#26262a", w: 184, h: 133, d: 38, turns: true },
    sfam:      { mat: "card",  color: "#26262a", w: 184, h: 133, d: 38, turns: true },
    n64:       { mat: "card",  color: "#26262a", w: 190, h: 133, d: 38, turns: true },
    gb:        { mat: "card",  color: "#26262a", w: 114, h: 127, d: 30 },
    gbc:       { mat: "card",  color: "#26262a", w: 114, h: 127, d: 30 },
    gba:       { mat: "card",  color: "#26262a", w: 127, h: 127, d: 30 },
    atari2600: { mat: "card",  color: "#26262a", w: 140, h: 190, d: 30 },
    genesis:   { mat: "clam",  color: "#121214", w: 135, h: 184, d: 23 },
    sms:       { mat: "clam",  color: "#121214", w: 135, h: 184, d: 23 },
    gamegear:  { mat: "clam",  color: "#121214", w: 112, h: 160, d: 20 },
    // CD consoles: the square cover insert alone (the core cuts a case hinge out of the scans,
    // media::cut_hinge), so the case is drawn square.
    psx:       { mat: "jewel", color: "#0b0b0d", w: 125, h: 125, d: 10, insert: 1.0 },
    ps:        { mat: "jewel", color: "#0b0b0d", w: 125, h: 125, d: 10, insert: 1.0 },
    // Saturn, Mega-CD and Dreamcast jewel cases hold the same square insert.
    saturn:    { mat: "jewel", color: "#0b0b0d", w: 125, h: 125, d: 10, insert: 1.0 },
    segacd:    { mat: "jewel", color: "#0b0b0d", w: 125, h: 125, d: 10, insert: 1.0 },
    dc:        { mat: "jewel", color: "#0b0b0d", w: 125, h: 125, d: 10, insert: 1.0 },
    ngc:       { mat: "keep",  color: "#151517", w: 136, h: 191, d: 14 },
    ps2:       { mat: "keep",  color: "#141416", w: 135, h: 190, d: 14 },
    xbox:      { mat: "keep",  color: "#141416", w: 135, h: 190, d: 14 },
    wii:       { mat: "keep",  color: "#eceef1", w: 135, h: 190, d: 14 },
    xbox360:   { mat: "keep",  color: "#4f9a3a", w: 135, h: 190, d: 14 },
    wiiu:      { mat: "keep",  color: "#2a8fd0", w: 135, h: 170, d: 13 },
    ps3:       { mat: "keep",  color: "#2b4f96", w: 135, h: 171, d: 12 },
    ps4:       { mat: "keep",  color: "#2b4f96", w: 135, h: 171, d: 12 },
    psp:       { mat: "keep",  color: "#141416", w: 105, h: 180, d: 14 },
    nds:       { mat: "keep",  color: "#18181b", w: 125, h: 137, d: 14 },
    "3ds":     { mat: "keep",  color: "#eceef1", w: 125, h: 137, d: 13 },
    switch:    { mat: "keep",  color: "#d0202b", w: 105, h: 170, d: 11 }
}
// Each console's case proportions (width / height) as its front scans show them, from the core
// (GET /platforms, case_ar: one or two shapes, most common first), set when the consoles are
// listed, before the shelf is built.
let ratios = {}
function setRatios(m) { ratios = m || {} }
// Width and height of a console's case in its own millimetres, every case of the console alike:
// the longest side of its real case, the proportions of its scans (else of its real case). Where
// the console was sold in two kinds of case, a game takes the one closest to its scan; with one
// known shape, a cover upright where the console's cases are usually wide turns the case.
function shape(slug, frontAR) {
    const k = of(slug)
    const known = ratios[slug] && ratios[slug].length ? ratios[slug] : [k.w / k.h]
    let ar = known[0]
    if (frontAR > 0 && known.length > 1)
        ar = known.reduce((b, r) => Math.abs(Math.log(r / frontAR)) < Math.abs(Math.log(b / frontAR)) ? r : b, ar)
    const turned = known.length === 1 && !!k.turns && frontAR > 0 && (frontAR < 1) !== (ar < 1)
    const a = turned ? 1 / ar : ar
    const longest = Math.max(k.w, k.h)
    return a <= 1 ? { w: longest * a, h: longest, turned: turned } : { w: longest, h: longest / a, turned: turned }
}

const TALLEST = 191   // mm: the tallest case is drawn at the shelf's full box height
// Small cases (a PlayStation jewel case, a Game Boy box) drawn to true scale would be too small
// to read: every case is drawn with its longest side at least this share of the tallest, keeping
// its own proportions. Sizes still differ between consoles, just less than in real life.
const MIN_SIDE = 0.94
// Scene units per millimetre for a case of that kind, on a shelf where the tallest case is boxH.
function scale(k, boxH) {
    const longest = Math.max(k.w, k.h)
    return boxH / TALLEST * Math.max(1, TALLEST * MIN_SIDE / longest)
}
// A spine thinner than this share of the case's height is drawn this thick, so its print and
// title stay readable (real spines of keep and jewel cases are about 6 to 8 %).
const MIN_SPINE = 0.09

// Each console's own colour (its buttons, logo or body, as people know it): Borne's accent while
// the console or one of its games is selected (buttons, active pills, the frame round the screen).
const TINTS = {
    // Nintendo: the red of the logo and the Switch, each console's own colour otherwise.
    switch: "#E60012", nes: "#E4000F", famicom: "#B8232B", snes: "#5B4B9A", sfam: "#5B4B9A",
    n64: "#009B48", ngc: "#5C4B9E", wii: "#34BEED", wiiu: "#009AC7", virtualboy: "#C8102E",
    gb: "#8B1F4E", gbc: "#8B1F4E", gba: "#4C3F9B", nds: "#7D8590", "3ds": "#D12228",
    // Sony: PlayStation blue, grey for the first console's body.
    psx: "#A3A7AE", ps: "#A3A7AE", ps2: "#1F4BBF", ps3: "#2F5FD0", ps4: "#0070D1", ps5: "#0070D1",
    psp: "#5A6070", psvita: "#1E5AA8",
    // Sega: each logo's colour.
    sms: "#C8102E", genesis: "#D3222A", segacd: "#D3222A", sega32: "#D3222A", gamegear: "#0060A8",
    saturn: "#5B5FC7", dc: "#E26A1B",
    // Others.
    xbox: "#107C10", xbox360: "#107C10", atari2600: "#C46A1E", pce: "#E8612C", neogeo: "#C9A227",
    arcade: "#F2A900"
}
function tint(slug) { return TINTS[slug] || "#5A6DB0" }

function of(slug) {
    return CASES[slug] || { mat: "keep", color: "#18191c", w: 135, h: 190, d: 14 }
}

// Where the case t places from the selection stands on the shelf (t = 0: the selected case, which
// faces you, a little forward; ±1, ±2: the next cases, turned about 18° then 26° toward it, set
// back and well apart). step: the distance between the selected case and its neighbours, from
// the width of the selected case. Returns x, z (scene units), the turn (degrees) and a lift.
function place(t, step) {
    const a = Math.abs(t), s = t < 0 ? -1 : 1
    let x, z, ang
    if (a <= 1) {
        x = t * step
        z = 150 * (1 - a) - 90 * a
        ang = -t * 18
    } else {
        x = s * (step + (a - 1) * step * 0.95)
        z = -90 - (a - 1) * 90
        ang = -s * Math.min(26, 18 + (a - 1) * 8)
    }
    return { x: x, z: z, ang: ang, lift: a < 1 ? 14 * (1 - a) : 0 }
}
// How visible the case t places away is: whole for the selection and its neighbours, fainter for
// the next ones, gone beyond.
function presence(t) {
    return Math.max(0, Math.min(1, (3.2 - Math.abs(t)) / 2))
}
// Distance between the selected case and its neighbours, for a case of that console.
function step(slug, boxH) {
    const k = of(slug)
    const w = shape(slug, 0).w * scale(k, boxH)
    return Math.max(300, w * 0.95 + 90)
}
