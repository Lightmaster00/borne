// Borne's single look: a dark stage inside the selected console's frame, rounded shapes with an ink
// edge (a touch of cel shading), the console's own colour for what you act on. Type: Fredoka for
// titles, Manrope for the rest.
// Focus: a white ring.
// Designed at 1920×1080; the window scales the whole scene.
import QtQuick

QtObject {
    // ---------- Color ----------
    readonly property color bg: "#0C0D10"
    readonly property color fg: "#F4F6FA"
    readonly property color fgSoft: Qt.rgba(0.957, 0.965, 0.98, 0.80)
    readonly property color fgMuted: Qt.rgba(0.957, 0.965, 0.98, 0.70)
    readonly property color fgFaint: Qt.rgba(0.957, 0.965, 0.98, 0.60)
    readonly property color glass: Qt.rgba(1, 1, 1, 0.08)
    readonly property color glassRaised: Qt.rgba(1, 1, 1, 0.14)
    readonly property color glassEdge: Qt.rgba(1, 1, 1, 0.15)
    readonly property color scrim: Qt.rgba(0.047, 0.051, 0.063, 0.92)
    // Ink: the dark line of Borne's touch of cel shading (case outlines, the hard shadow under
    // buttons, chips and panels).
    readonly property color ink: "#05060A"
    readonly property int inkOffset: 4
    readonly property color bad: "#FF7B7B"
    readonly property color badTint: Qt.rgba(1, 0.48, 0.48, 0.16)

    // Accent: the colour of the selected console (Cases.js), set by Main.
    property color accent: "#8CCBFF"
    // The input in use ("pad" or "keyboard"): button hints show that device's keys.
    property string input: "pad"
    // The key or button doing an action ("a", "select"…) on the device in use, for texts.
    function key(action) {
        const pad = { a: "A", b: "B", x: "X", y: "Y", start: "Start", select: "Select", lb: "LB", rb: "RB",
                      lt: "LT", rt: "RT", r3: "R3", up: "▲", down: "▼", left: "◀", right: "▶" }
        if (input !== "keyboard") return pad[action] || action
        const kb = { a: qsTr("Enter"), b: qsTr("Esc"), x: "X", y: "T", start: "M", select: "F2",
                     lb: "Q", rb: "E", lt: "R", rt: "C", r3: "Tab", up: "↑", down: "↓", left: "←", right: "→" }
        return kb[action] || action
    }
    // Text on the accent: white on the consoles' strong colours, dark on light ones.
    readonly property color accentFg: accent.hslLightness > 0.62 ? bg : "#FFFFFF"
    readonly property color halo: Qt.rgba(accent.r, accent.g, accent.b, 0.45)
    readonly property color focusRing: fg
    Behavior on accent { ColorAnimation { duration: 600 } }

    // Names kept from the first look, mapped onto Halo.
    readonly property color surface: glass
    readonly property color raised: glassRaised
    readonly property color line: glassEdge
    readonly property color panel: Qt.rgba(0.06, 0.07, 0.09, 0.86)
    readonly property color panelBorder: glassEdge
    readonly property color status: fg
    readonly property color statusSoft: fg
    readonly property color statusTint: glass
    readonly property color accentSoft: Qt.rgba(accent.r, accent.g, accent.b, 0.16)
    readonly property color badSoft: "#FFD0D0"
    readonly property color ok: accent
    readonly property color bg2: panel

    // ---------- Type ----------
    readonly property string fontFamily: "Manrope"
    readonly property string displayFont: "Fredoka"   // titles: rounded, playful

    // ---------- Shape and motion ----------
    readonly property int radius: 14
    readonly property int focusMs: 160
    readonly property int fadeMs: 600
    readonly property int scrollMs: 220
    readonly property int ringWidth: 3
    readonly property int ringGap: 5

    // ---------- Game tiles ----------
    readonly property int tileW: 156
    readonly property int tileH: 234
    readonly property int tileFocusW: 196
    readonly property int tileFocusH: 294
    readonly property int tileGap: 22
    readonly property int tileRadius: 14

    // ---------- Sounds ----------
    readonly property string soundSet: "soft"
    readonly property real soundVolume: 0.45

    /// Placeholder tone for a game without a cover: muted, stable per game.
    function tone(hue) {
        return Qt.hsla(((hue || 0) % 360) / 360, 0.45, 0.32, 1)
    }
}
