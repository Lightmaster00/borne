// Each console's games: their retail case (width × height × thickness in millimetres, as sold in
// Europe / North America, and the plastic's or the box's colour), for a cover that has no picture
// or a picture of no sensible shape and for the case in 3D on a game's page; and the console's
// colour (the screen's border, the covers' glow, the badges).
.pragma library

const CASES = {
    nes:       { w: 127, h: 184, d: 32, color: "#26262a" },
    famicom:   { w: 127, h: 92, d: 25, color: "#26262a" },
    snes:      { w: 184, h: 133, d: 38, color: "#26262a" },
    sfam:      { w: 184, h: 133, d: 38, color: "#26262a" },
    n64:       { w: 190, h: 133, d: 38, color: "#26262a" },
    gb:        { w: 114, h: 127, d: 22, color: "#26262a" },
    gbc:       { w: 114, h: 127, d: 22, color: "#26262a" },
    gba:       { w: 127, h: 127, d: 30, color: "#26262a" },
    atari2600: { w: 140, h: 190, d: 30, color: "#26262a" },
    genesis:   { w: 135, h: 184, d: 23, color: "#121214" },
    sms:       { w: 135, h: 184, d: 23, color: "#121214" },
    gamegear:  { w: 112, h: 160, d: 20, color: "#121214" },
    // CD consoles: the square cover insert alone (the core cuts a case hinge out of the scans,
    // media::cut_hinge).
    psx:       { w: 125, h: 125, d: 10, color: "#0b0b0d" },
    ps:        { w: 125, h: 125, d: 10, color: "#0b0b0d" },
    // Saturn, Mega-CD and Dreamcast jewel cases hold the same square insert.
    saturn:    { w: 125, h: 125, d: 10, color: "#0b0b0d" },
    segacd:    { w: 125, h: 125, d: 10, color: "#0b0b0d" },
    dc:        { w: 125, h: 125, d: 10, color: "#0b0b0d" },
    ngc:       { w: 136, h: 191, d: 14, color: "#151517" },
    ps2:       { w: 135, h: 190, d: 14, color: "#141416" },
    xbox:      { w: 135, h: 190, d: 14, color: "#141416" },
    wii:       { w: 135, h: 190, d: 14, color: "#eceef1" },
    xbox360:   { w: 135, h: 190, d: 14, color: "#4f9a3a" },
    wiiu:      { w: 135, h: 170, d: 13, color: "#2a8fd0" },
    ps3:       { w: 135, h: 171, d: 12, color: "#2b4f96" },
    ps4:       { w: 135, h: 171, d: 12, color: "#2b4f96" },
    psp:       { w: 105, h: 180, d: 14, color: "#141416" },
    nds:       { w: 125, h: 137, d: 14, color: "#18181b" },
    "3ds":     { w: 125, h: 137, d: 13, color: "#eceef1" },
    switch:    { w: 105, h: 170, d: 11, color: "#d0202b" },
    // Neo Geo AES: a big cardboard box.
    neogeoaes: { w: 140, h: 191, d: 42, color: "#26262a" },
    neogeo:    { w: 140, h: 191, d: 42, color: "#26262a" }
}
// Each console's case proportions (width / height) as its front scans show them, from the core
// (GET /platforms, case_ar: one or two shapes, most common first), when the consoles are listed.
let ratios = {}
function setRatios(m) { ratios = m || {} }
// A console's games' proportions: its scans', else its real case's.
function ratio(slug) {
    const r = ratios[slug]
    const v = Array.isArray(r) ? r[0] : r
    if (v >= 0.45 && v <= 2.2) return v
    const c = of(slug)
    return c.w / c.h
}

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
    return CASES[slug] || { w: 135, h: 190, d: 14, color: "#141416" }
}
