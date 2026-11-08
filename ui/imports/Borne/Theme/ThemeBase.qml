// Borne theme API, version 1.
// A theme declares in its Theme.qml:
//     import Borne.Theme
//     ThemeBase { accent: "#ff8fb8"; cardW: 200 }
// and overrides only what it wants. Any new property added here must keep
// a default value, so existing themes never break.
import QtQuick

QtObject {
    readonly property int apiVersion: 1

    // Colors
    property color bg: "#0b0f1a"
    property color bg2: "#121a2b"
    property color fg: "#e8edf5"
    property color fgMuted: "#8b97ab"
    property color accent: "#46c8dc"
    property color accentFg: "#06121a"
    property color focusRing: accent
    property color panel: Qt.rgba(0.055, 0.08, 0.13, 0.95)
    property color panelBorder: Qt.rgba(1, 1, 1, 0.08)
    property color ok: "#4ade80"
    property color bad: "#f87171"

    // Typography
    property string fontFamily: "Inter, Cantarell, Noto Sans, DejaVu Sans"
    property string displayFont: fontFamily
    property bool uppercaseTitles: false
    property int titleSize: 28

    // Posters and grid
    property int cardW: 180
    property int cardH: 252
    property int cardGap: 28
    property int labelH: 34
    property int cardRadius: 10
    property real focusScale: 1.1
    property real gridAnchor: 0.42   // height of the active row (0 = top, 1 = bottom)
    property int scrollMs: 160
    property int focusMs: 140

    // Detailed view
    property int listRowH: 44

    // Stage (poster + trailer)
    property real stageDim: 0.55
    property int fadeMs: 450
    property int radius: 10
}
