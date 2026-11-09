// Short, non-blocking notifications, bottom right.
import QtQuick

Column {
    id: toasts
    property QtObject theme
    spacing: 8
    width: 420

    ListModel { id: items }

    function show(text, kind) {
        items.append({ text: text, kind: kind || "info", born: Date.now() })
        if (items.count > 4) items.remove(0)
    }

    Timer {
        interval: 500; repeat: true; running: items.count > 0
        onTriggered: {
            while (items.count && Date.now() - items.get(0).born > (items.get(0).kind === "error" ? 7000 : 4000)) items.remove(0)
        }
    }

    Repeater {
        model: items
        Rectangle {
            required property string text
            required property string kind
            width: toasts.width
            height: t.height + 24
            radius: 10
            color: theme.panel
            border { width: 1; color: kind === "error" ? theme.bad : kind === "ok" ? theme.ok : theme.panelBorder }
            // Status dot: color for the kind, never color alone (the text says it too).
            Rectangle { width: 10; height: 10; x: 14; y: 17; radius: 5; color: kind === "error" ? theme.bad : kind === "ok" ? theme.ok : theme.accent }
            Text {
                id: t
                x: 34; y: 12; width: parent.width - 48
                text: parent.text
                wrapMode: Text.WordWrap
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 14 }
            }
        }
    }
}
