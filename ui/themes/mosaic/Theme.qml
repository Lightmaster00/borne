// Mosaic — a dashboard of flat landscape tiles with a bright accent and crisp ticks.
// Inspired by tile-based console dashboards.
import Borne.Theme

ThemeBase {
    bg: "#0f1112"
    bg2: "#1a1d1f"
    fg: "#f2f4f3"
    fgMuted: "#9aa3a0"
    accent: "#5ce1a3"
    accentFg: "#06150e"
    focusRing: "#5ce1a3"
    panel: Qt.rgba(0.08, 0.09, 0.1, 0.97)
    panelBorder: Qt.rgba(1, 1, 1, 0.08)
    fontFamily: "Inter"
    titleSize: 30
    cardW: 296
    cardH: 166
    cardGap: 12
    labelH: 0
    cardRadius: 4
    radius: 6
    buttonRadius: 4
    focusScale: 1.06
    gridAnchor: 0.36
    scrollMs: 140
    focusMs: 120
    heroOpacity: 0.3
    soundSet: "tick"
}
