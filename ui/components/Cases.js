// Each console's games: the proportions of their retail case (width × height in millimetres, as
// sold in Europe / North America), for a cover that has no picture or a picture of no sensible
// shape, and the console's colour (the screen's border, the covers' glow, the badges).
.pragma library

const CASES = {
    nes:       { w: 127, h: 184 },
    famicom:   { mat: "card",  color: "#26262a", w: 127, h: 92,  d: 25 },
    snes:      { w: 184, h: 133 },
    sfam:      { w: 184, h: 133 },
    n64:       { w: 190, h: 133 },
    gb:        { w: 114, h: 127 },
    gbc:       { w: 114, h: 127 },
    gba:       { w: 127, h: 127 },
    atari2600: { w: 140, h: 190 },
    genesis:   { w: 135, h: 184 },
    sms:       { w: 135, h: 184 },
    gamegear:  { w: 112, h: 160 },
    // CD consoles: the square cover insert alone (the core cuts a case hinge out of the scans,
    // media::cut_hinge).
    psx:       { w: 125, h: 125 },
    ps:        { w: 125, h: 125 },
    // Saturn, Mega-CD and Dreamcast jewel cases hold the same square insert.
    saturn:    { w: 125, h: 125 },
    segacd:    { w: 125, h: 125 },
    dc:        { w: 125, h: 125 },
    ngc:       { w: 136, h: 191 },
    ps2:       { w: 135, h: 190 },
    xbox:      { w: 135, h: 190 },
    wii:       { w: 135, h: 190 },
    xbox360:   { w: 135, h: 190 },
    wiiu:      { w: 135, h: 170 },
    ps3:       { w: 135, h: 171 },
    ps4:       { w: 135, h: 171 },
    psp:       { w: 105, h: 180 },
    nds:       { w: 125, h: 137 },
    "3ds":     { w: 125, h: 137 },
    switch:    { w: 105, h: 170 },
    // Neo Geo AES: a big cardboard box.
    neogeoaes: { w: 140, h: 191 },
    neogeo:    { w: 140, h: 191 }
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
    return CASES[slug] || { w: 135, h: 190 }
}
