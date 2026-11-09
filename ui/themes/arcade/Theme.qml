// Arcade — cabinet carousel: a wheel of neon titles, the cover tilted like a marquee card,
// the trailer full screen with sound, 8-bit blips. Its Card.qml dresses the grid view too.
import Borne.Theme

ThemeBase {
    bg: "#160a14"
    bg2: "#2a1024"
    fg: "#fff4e6"
    fgMuted: "#c9a9b8"
    accent: "#ffb020"
    accentFg: "#1a0a00"
    focusRing: "#ff3d7f"
    panel: Qt.rgba(0.12, 0.04, 0.1, 0.96)
    displayFont: "Bebas Neue"
    uppercaseTitles: true
    titleSize: 34
    cardW: 220
    cardH: 308
    cardGap: 34
    cardRadius: 4
    radius: 4
    focusScale: 1.14
    scrollMs: 120
    focusMs: 110
    stageDim: 0.35
    gridAnchor: 0.38
    wheelRowH: 66
    heroOpacity: 0.35
    soundSet: "chip"
}
