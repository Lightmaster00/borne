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
            Rectangle { width: 4; height: parent.height - 16; x: 8; anchors.verticalCenter: parent.verticalCenter; radius: 2; color: kind === "error" ? theme.bad : kind === "ok" ? theme.ok : theme.accent }
            Text {
                id: t
                x: 22; y: 12; width: parent.width - 36
                text: parent.text
                wrapMode: Text.WordWrap
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 14 }
            }
        }
    }
}
