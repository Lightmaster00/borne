// The emulator options a game can have (Game settings → Emulator), named in Borne. The keys and
// values are those of the core (gamesettings.rs, EMU_OPTIONS).
.pragma library

function title(k) {
    return { rewind: qsTr("Rewind"), runahead: qsTr("Run-ahead"), widescreen: qsTr("Widescreen"),
             overclock: qsTr("Emulated CPU speed"), renderer: qsTr("Renderer"), pgxp: qsTr("Geometry correction (PGXP)"),
             filtering: qsTr("Texture filtering"), docked: qsTr("Console mode"), colorbuffers: qsTr("Write colour buffers"),
             console: qsTr("Console"), jit: qsTr("JIT recompiler"), license: qsTr("Arcade games"), vsync: qsTr("Vertical sync"),
             pro: qsTr("PS4 Pro mode"), trophies: qsTr("Trophy notifications") }[k] || k
}
function desc(k) {
    return { rewind: qsTr("Go back in time during play; uses a little more memory"),
             runahead: qsTr("Cuts input lag by a frame or two; needs a stronger computer"),
             widescreen: qsTr("A 16:9 picture where the game allows it; can show glitches at the edges"),
             overclock: qsTr("Smoother for games that slow down; needs a stronger computer"),
             renderer: qsTr("Software: slower, but exact where the graphics are wrong"),
             pgxp: qsTr("Steadier 3D, without wobbling polygons"),
             filtering: qsTr("Bilinear smooths the textures"),
             docked: qsTr("On a TV (higher resolution) or handheld (faster)"),
             colorbuffers: qsTr("Fixes missing graphics in some games; slower"),
             console: qsTr("DSi: for DSi-only games and their extras; needs the DSi system files"),
             jit: qsTr("Much faster on most computers; turn off if the game misbehaves"),
             license: qsTr("Xbox Live Arcade games as the full version, not the trial"),
             vsync: qsTr("No tearing; off can lower input lag"),
             pro: qsTr("Some games look better on a PS4 Pro; needs a stronger computer"),
             trophies: qsTr("A notice on screen when a trophy is won") }[k] || ""
}
function label(k, v) {
    if (k === "runahead") return v === "off" ? qsTr("Off") : qsTr("%n frame(s)", "", Number(v))
    if (k === "overclock") return v === "off" ? qsTr("Normal") : v + " %"
    if (k === "renderer") return v === "software" ? qsTr("Software") : v === "opengl" ? "OpenGL" : qsTr("Automatic")
    if (k === "console") return v === "dsi" ? "DSi" : "DS"
    if (k === "license") return v === "full" ? qsTr("Full version") : qsTr("Trial")
    if (k === "trophies") return v === "off" ? qsTr("Hidden") : qsTr("Shown")
    if (k === "filtering") return v === "bilinear" ? qsTr("Bilinear") : qsTr("Nearest")
    if (k === "docked") return v === "off" ? qsTr("Handheld") : qsTr("TV")
    return v === "on" ? qsTr("On") : qsTr("Off")
}
