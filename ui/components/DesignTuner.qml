// Developer mode: the light, the Store's cards and the move between consoles tuned live, over the screen they change.
// ▲ ▼ choose a setting, ◀ ▶ change it, X puts it back to Borne's value, LB RB switch Home and
// Store, LT RT move along the consoles, B closes. Every value is kept (prefs.look*).
import QtQuick

Item {
    id: tuner
    property QtObject theme
    property var prefs: null
    property int row: 0
    signal tab(string t)
    signal step(int d)
    visible: false

    // key in prefs, label, values (numbers step 5 from 0 to 100, or named choices), Borne's value.
    readonly property var params: [
        { key: "lookGlow", label: qsTr("Background: colour from the picture"), def: 40 },
        { key: "lookSoft", label: qsTr("Background: softness"), def: 70 },
        { key: "lookVignette", label: qsTr("Background: dark edges"), def: 45 },
        { key: "lookGrain", label: qsTr("Background: grain"), def: 30 },
        { key: "lookCard", label: qsTr("Cards: style"), def: "studio",
          choices: [["studio", qsTr("Studio")], ["lacquer", qsTr("Lacquer")], ["glass", qsTr("Glass")]] },
        { key: "lookKey", label: qsTr("Cards: light"), def: 50 },
        { key: "lookFloor", label: qsTr("Cards: floor"), def: 40 },
        { key: "lookShadow", label: qsTr("Cards: shadow under the console"), def: 60 },
        { key: "moveSpeed", label: qsTr("Transition: speed (%)"), def: 100, min: 40, max: 200, step: 10 },
        { key: "moveBounce", label: qsTr("Transition: bounce"), def: 30 },
        { key: "moveDelay", label: qsTr("Transition: console's delay"), def: 40 }
    ]
    function value(p) { return prefs ? prefs[p.key] : p.def }
    function shownValue(p) {
        const v = value(p)
        if (p.choices) { const c = p.choices.find(x => x[0] === v); return c ? c[1] : v }
        return String(v)
    }
    function change(d) {
        const p = params[row]
        if (!prefs || !p) return
        if (p.choices) {
            const i = Math.max(0, p.choices.findIndex(x => x[0] === prefs[p.key]))
            prefs[p.key] = p.choices[(i + d + p.choices.length) % p.choices.length][0]
        } else {
            prefs[p.key] = Math.max(p.min ?? 0, Math.min(p.max ?? 100, prefs[p.key] + d * (p.step ?? 5)))
        }
    }
    function open() { row = 0; visible = true }
    function handle(a) {
        if (a === "b" || a === "start") { visible = false; return "back" }
        if (a === "up") { row = Math.max(0, row - 1); return "move" }
        if (a === "down") { row = Math.min(params.length - 1, row + 1); return "move" }
        if (a === "left") { change(-1); return "move" }
        if (a === "right") { change(1); return "move" }
        if (a === "x") { const p = params[row]; if (prefs) prefs[p.key] = p.def; return "move" }
        if (a === "lb") { tab("home"); return "move" }
        if (a === "rb") { tab("store"); return "move" }
        if (a === "l2" || a === "lt") { step(-1); return "move" }
        if (a === "r2" || a === "rt") { step(1); return "move" }
        return ""
    }

    Rectangle {
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 48; bottomMargin: 110 }
        width: 560
        height: col.height + 40
        radius: 22
        color: Qt.rgba(0.06, 0.06, 0.08, 0.88)
        border { width: 1; color: Qt.rgba(1, 1, 1, 0.14) }
        Column {
            id: col
            x: 22; y: 20
            width: parent.width - 44
            spacing: 4
            Text {
                text: qsTr("Light and cards")
                color: theme.fg
                font { family: theme.displayFont; pixelSize: 24; weight: Font.ExtraBold }
            }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: qsTr("▲ ▼ choose · ◀ ▶ change · X Borne's value · LB RB Home / Store · LT RT consoles · B close")
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 14 }
            }
            Item { width: 1; height: 8 }
            Repeater {
                model: tuner.params
                Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === tuner.row
                    width: col.width; height: 40; radius: 12
                    color: cur ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                    Text {
                        x: 14; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 150
                        elide: Text.ElideRight
                        text: modelData.label
                        color: parent.cur ? theme.fg : theme.fgMuted
                        font { family: theme.fontFamily; pixelSize: 16; weight: parent.cur ? Font.Bold : Font.Medium }
                    }
                    Row {
                        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                        spacing: 10
                        Text { visible: parent.parent.cur; text: "◀"; color: theme.fgMuted; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                        Text {
                            text: tuner.prefs ? tuner.shownValue(modelData) : ""
                            color: tuner.prefs && tuner.value(modelData) !== modelData.def ? "#FFD27A" : theme.fg
                            font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
                        }
                        Text { visible: parent.parent.cur; text: "▶"; color: theme.fgMuted; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                    }
                }
            }
        }
    }
}
