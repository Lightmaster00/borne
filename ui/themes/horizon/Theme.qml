// Horizon — cinematic home row: small square tiles along the top, the selected game's artwork
// filling the screen behind, low airy sounds. Inspired by modern living-room console homes.
import Borne.Theme

ThemeBase {
    bg: "#05070d"
    bg2: "#0d1422"
    fg: "#f4f6fb"
    fgMuted: "#a9b3c6"
    accent: "#f4f6fb"
    accentFg: "#05070d"
    focusRing: "#ffffff"
    panel: Qt.rgba(0.05, 0.07, 0.12, 0.94)
    panelBorder: Qt.rgba(1, 1, 1, 0.1)
    titleSize: 40
    cardW: 150
    cardH: 150
    cardGap: 18
    cardRadius: 14
    radius: 14
    buttonRadius: 26
    focusScale: 1.36
    scrollMs: 180
    focusMs: 180
    shelfAlign: "left"
    shelfY: 0.04
    heroOpacity: 0.9
    stageDim: 0.55
    heroDim: 0.55
    soundSet: "deep"
}
