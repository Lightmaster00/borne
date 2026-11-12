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
    psx:       { mat: "jewel", color: "#0b0b0d", w: 142, h: 125, d: 10 },
    ps:        { mat: "jewel", color: "#0b0b0d", w: 142, h: 125, d: 10 },
    saturn:    { mat: "jewel", color: "#0b0b0d", w: 142, h: 125, d: 10 },
    segacd:    { mat: "jewel", color: "#0b0b0d", w: 142, h: 125, d: 10 },
    dc:        { mat: "jewel", color: "#0b0b0d", w: 142, h: 125, d: 10 },
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
const TALLEST = 191   // mm: the tallest case is drawn at the shelf's full box height

// Each console's own colour (its buttons, logo or body, as people know it): Borne's accent while
// the console or one of its games is selected (buttons, active pills, the frame round the screen).
const TINTS = {
    switch: "#E60012", ngc: "#6A4FC4", wii: "#34BEED", wiiu: "#009AC7", ps2: "#1F55D6", psx: "#8A90A0",
    ps: "#8A90A0", ps3: "#2F5FD0", ps4: "#2563D9", psp: "#5A6070", nes: "#D2232A", famicom: "#B8232B",
    snes: "#6B5CA5", sfam: "#6B5CA5", n64: "#1E9E5A", gb: "#9B2257", gbc: "#7B3FC0", gba: "#4B3FA8",
    genesis: "#D3222A", sms: "#C8102E", gamegear: "#3A6FD8", saturn: "#5B5FC7", dc: "#E26A1B",
    xbox: "#107C10", xbox360: "#107C10", nds: "#7D8590", "3ds": "#CE1126", segacd: "#D3222A", atari2600: "#C46A1E"
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
    const w = (k.turns ? k.h : k.w) * boxH / TALLEST
    return Math.max(300, w * 0.95 + 90)
}
