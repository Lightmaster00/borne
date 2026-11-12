// Short, non-blocking notifications. Errors stay longer and are announced as alerts.
import QtQuick

Column {
    id: toasts
    property QtObject theme
    spacing: 10
    width: 440

    ListModel { id: items }

    function show(text, kind) {
        items.append({ text: text, kind: kind || "info", born: Date.now() })
        if (items.count > 4) items.remove(0)
    }

    Timer {
        interval: 500; repeat: true; running: items.count > 0
        onTriggered: {
            while (items.count && Date.now() - items.get(0).born > (items.get(0).kind === "error" ? 8000 : 4500)) items.remove(0)
        }
    }

    Repeater {
        model: items
        Rectangle {
            required property string text
            required property string kind
            width: toasts.width
            height: t.height + 32
            radius: 14
            color: kind === "error" ? Qt.rgba(0.2, 0.07, 0.08, 0.92) : toasts.theme.panel
            border { width: 1; color: toasts.theme.glassEdge }
            Ink { z: -1; theme: toasts.theme; radius: 14 }
            Accessible.role: kind === "error" ? Accessible.AlertMessage : Accessible.StaticText
            Accessible.name: text
            // Status dot: color for the kind, never color alone (the text says it too).
            Rectangle {
                x: 20; y: 23
                width: 10; height: 10; radius: 5
                color: kind === "error" ? toasts.theme.bad : toasts.theme.accent
            }
            Text {
                id: t
                x: 44; y: 16; width: parent.width - 64
                text: parent.text
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
                color: kind === "error" ? toasts.theme.badSoft : toasts.theme.fg
                font { family: toasts.theme.fontFamily; pixelSize: 17 }
            }
        }
    }
}
