// The physical case of each console's games: material and thickness (as a share of the height,
// from real case dimensions). Materials: "card" (cardboard box), "keep" (plastic keep case with a
// clear sleeve), "jewel" (clear CD case with a hinge), "clam" (hard plastic clamshell).
// Logos and printed artwork come only from the user's own RomM scans, never drawn here.
.pragma library

const CASES = {
    nes:       { mat: "card",  color: "#2a2a2e", depth: 0.17 },
    famicom:   { mat: "card",  color: "#2a2a2e", depth: 0.17 },
    snes:      { mat: "card",  color: "#2a2a2e", depth: 0.21 },
    sfam:      { mat: "card",  color: "#2a2a2e", depth: 0.21 },
    n64:       { mat: "card",  color: "#2a2a2e", depth: 0.2 },
    gb:        { mat: "card",  color: "#2a2a2e", depth: 0.2 },
    gbc:       { mat: "card",  color: "#2a2a2e", depth: 0.2 },
    gba:       { mat: "card",  color: "#2a2a2e", depth: 0.2 },
    atari2600: { mat: "card",  color: "#2a2a2e", depth: 0.17 },
    genesis:   { mat: "clam",  color: "#121214", depth: 0.13 },
    sms:       { mat: "clam",  color: "#121214", depth: 0.13 },
    gamegear:  { mat: "clam",  color: "#121214", depth: 0.13 },
    psx:       { mat: "jewel", color: "#0d0d10", depth: 0.08 },
    ps:        { mat: "jewel", color: "#0d0d10", depth: 0.08 },
    saturn:    { mat: "jewel", color: "#0d0d10", depth: 0.08 },
    segacd:    { mat: "jewel", color: "#0d0d10", depth: 0.08 },
    dc:        { mat: "jewel", color: "#0d0d10", depth: 0.08 },
    ngc:       { mat: "keep",  color: "#151517", depth: 0.075 },
    ps2:       { mat: "keep",  color: "#141416", depth: 0.075 },
    xbox:      { mat: "keep",  color: "#141416", depth: 0.075 },
    wii:       { mat: "keep",  color: "#e9ebee", depth: 0.075 },
    wiiu:      { mat: "keep",  color: "#2a8fd0", depth: 0.075 },
    xbox360:   { mat: "keep",  color: "#4f9a3a", depth: 0.075 },
    ps3:       { mat: "keep",  color: "#2b4f96", depth: 0.07 },
    ps4:       { mat: "keep",  color: "#2b4f96", depth: 0.07 },
    psp:       { mat: "keep",  color: "#141416", depth: 0.08 },
    nds:       { mat: "keep",  color: "#18181b", depth: 0.1 },
    "3ds":     { mat: "keep",  color: "#e9ebee", depth: 0.1 },
    switch:    { mat: "keep",  color: "#dfe2e6", depth: 0.065 }
}

function of(slug) {
    return CASES[slug] || { mat: "keep", color: "#18191c", depth: 0.075 }
}
