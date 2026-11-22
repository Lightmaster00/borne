// Sort and layout: a short list that drops from its button, in sections (Sort by, Layout; the
// Store's consoles: their order), each choice with what it does; the one in use carries a
// filled dot. Up and down choose (across the sections), A applies, B closes.
import QtQuick

Rectangle {
    id: root
    property QtObject theme
    // [{ title, items: [{ id, label, hint, on }] }]
    property var sections: []
    property int index: 0             // among every section's items, in order
    readonly property var flat: {
        const out = []
        for (let s = 0; s < sections.length; s++)
            for (const it of sections[s].items) out.push({ section: s, id: it.id })
        return out
    }
    readonly property var picked: flat[Math.min(index, flat.length - 1)] || null

    width: 460
    height: col.height + 28
    radius: 28
    color: Qt.rgba(0.094, 0.094, 0.118, 0.97)
    border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
    transformOrigin: Item.TopRight
    scale: visible ? 1 : 0.94
    opacity: visible ? 1 : 0
    Behavior on scale { NumberAnimation { duration: 320 * theme.motion; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 200 } }

    Column {
        id: col
        x: 14; y: 14
        width: parent.width - 28
        Repeater {
            model: root.sections
            Column {
                id: sec
                required property var modelData
                required property int index
                width: col.width
                readonly property int offset: {
                    let n = 0
                    for (let s = 0; s < index; s++) n += root.sections[s].items.length
                    return n
                }
                Text {
                    leftPadding: 16; topPadding: sec.index ? 18 : 8; bottomPadding: 10
                    text: sec.modelData.title
                    color: theme.fgFaint
                    font { family: theme.fontFamily; pixelSize: 15; weight: Font.ExtraBold }
                }
                Repeater {
                    model: sec.modelData.items
                    Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool hov: sec.offset + index === root.index
                        width: col.width; height: 66; radius: 18
                        color: hov ? theme.fg : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData.label
                        Accessible.checked: !!modelData.on
                        Column {
                            anchors { left: parent.left; leftMargin: 18; right: dot.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            spacing: 2
                            Text { text: modelData.label; color: hov ? theme.bg : theme.fg; font { family: theme.fontFamily; pixelSize: 19; weight: Font.ExtraBold } }
                            Text { width: parent.width; elide: Text.ElideRight; text: modelData.hint; color: hov ? Qt.rgba(0, 0, 0, 0.6) : theme.fgFaint; font { family: theme.fontFamily; pixelSize: 13; weight: Font.Bold } }
                        }
                        Rectangle {
                            id: dot
                            anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
                            width: 22; height: 22; radius: 11
                            color: "transparent"
                            border { width: modelData.on ? 7 : 2; color: hov ? theme.bg : modelData.on ? theme.fg : Qt.rgba(1, 1, 1, 0.4) }
                        }
                    }
                }
            }
        }
    }
}
