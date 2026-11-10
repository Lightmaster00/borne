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
    switch:    { mat: "keep",  color: "#dfe2e6", w: 105, h: 170, d: 11 }
}
const TALLEST = 191   // mm: the tallest case is drawn at the shelf's full box height

function of(slug) {
    return CASES[slug] || { mat: "keep", color: "#18191c", w: 135, h: 190, d: 14 }
}
