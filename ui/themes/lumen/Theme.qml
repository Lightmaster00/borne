// Lumen — a bright home: one row of large square tiles, round shortcuts underneath,
// short clicky sounds. Inspired by handheld-hybrid console homes.
import Borne.Theme

ThemeBase {
    bg: "#ebedf0"
    bg2: "#dfe2e7"
    fg: "#2d2f33"
    fgMuted: "#686d76"
    accent: "#00a3d9"
    accentFg: "#ffffff"
    focusRing: "#00b8f0"
    ok: "#15803d"
    bad: "#c2262e"
    panel: Qt.rgba(0.985, 0.985, 0.99, 0.98)
    panelBorder: Qt.rgba(0, 0, 0, 0.08)
    fontFamily: "Poppins"
    displayFont: "Poppins"
    titleSize: 24
    cardW: 236
    cardH: 236
    cardGap: 16
    cardRadius: 4
    radius: 12
    buttonRadius: 24
    focusScale: 1.0
    scrollMs: 160
    focusMs: 120
    shelfAlign: "left"
    shelfY: 0.12
    quickBar: true
    shelfLabels: false        // the tile shows its own title, above it
    heroOpacity: 0
    heroVideo: false
    stageDim: 0
    heroDim: 0.86
    soundSet: "soft"
}
