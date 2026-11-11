// Display settings shown in Borne (Settings → Display and a game's own, on its page). The values
// are those of the core (gamesettings.rs).
.pragma library

var KEYS = ["aspect", "upscale", "smooth", "integer", "fps"]
var VALUES = { aspect: ["auto", "4:3", "16:9", "stretch"], upscale: ["1", "2", "3", "4"], smooth: ["sharp", "smooth"], integer: ["off", "on"], fps: ["off", "on"] }

function values(k) { return VALUES[k] || [] }
function title(k) {
    return { aspect: qsTr("Picture shape"), upscale: qsTr("Rendering resolution"), smooth: qsTr("Pixels"),
             integer: qsTr("Whole-number scaling"), fps: qsTr("Frame rate on screen") }[k] || k
}
function desc(k) {
    return { aspect: qsTr("The game's own shape, or forced"), upscale: qsTr("3D consoles (GameCube, Wii, PS1, PS2): sharper, needs a stronger computer"),
             smooth: qsTr("2D consoles: crisp pixels or smoothed"), integer: qsTr("2D consoles: even pixels, with borders"),
             fps: qsTr("Shows the frame rate while playing") }[k] || ""
}
function label(k, v) {
    if (k === "aspect") return { auto: qsTr("Game's own"), "4:3": "4:3", "16:9": "16:9", stretch: qsTr("Fill the screen") }[v]
    if (k === "upscale") return v + "×"
    if (k === "smooth") return v === "smooth" ? qsTr("Smoothed") : qsTr("Sharp")
    return v === "on" ? qsTr("On") : qsTr("Off")
}
