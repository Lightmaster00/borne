// Compact key / value table for diagnostics. rows: [[key, value, state?]]; state = "ok" | "bad".
import QtQuick

Column {
    id: kv
    property var rows: []
    property QtObject theme
    property int keyWidth: 220
    property int size: 13
    spacing: 3
    Repeater {
        model: kv.rows
        Row {
            required property var modelData
            spacing: 10
            Text {
                width: kv.keyWidth
                text: modelData[0]
                elide: Text.ElideRight
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: kv.size }
            }
            Text {
                width: kv.width - kv.keyWidth - 10
                text: String(modelData[1])
                wrapMode: Text.WrapAnywhere
                maximumLineCount: 2
                elide: Text.ElideRight
                color: modelData[2] === "ok" ? theme.ok : modelData[2] === "bad" ? theme.bad : theme.fg
                font { family: theme.fontFamily; pixelSize: kv.size }
            }
        }
    }
}
