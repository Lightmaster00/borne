// Modal action menu, reused everywhere (main menu, game menu, confirmations).
// open(title, subtitle, items, callback); items: [{ id, label, detail?, disabled? }].
import QtQuick

Rectangle {
    id: menu
    property QtObject theme
    property string title: ""
    property string subtitle: ""
    property var items: []
    property int index: 0
    property var callback: null
    property bool pointerActive: false
    readonly property bool opened: visible

    visible: false
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.6)

    function open(t, sub, list, cb) {
        title = t
        subtitle = sub || ""
        items = list
        callback = cb
        index = Math.max(0, list.findIndex(i => !i.disabled))
        visible = true
    }
    function close() { visible = false; callback = null }
    function step(d) {
        const n = items.length
        for (let k = 1; k <= n; k++) {
            const i = (index + d * k + n * k) % n
            if (!items[i].disabled) { index = i; return }
        }
    }
    function handle(a) {
        if (a === "up") step(-1)
        else if (a === "down") step(1)
        else if (a === "a") {
            const it = items[index]
            if (!it || it.disabled) return
            const cb = callback
            close()
            if (cb) cb(it.id)
        }
        else if (a === "b" || a === "start" || a === "y") close()
    }

    // Click outside the panel: same as B.
    MouseArea { anchors.fill: parent; onClicked: menu.close(); onWheel: (w) => w.accepted = true }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(560, parent.width - 80)
        height: col.height + 56
        radius: theme.radius + 4
        color: theme.panel
        border.color: theme.panelBorder
        MouseArea { anchors.fill: parent }   // clicks on the panel itself do not close it
        Column {
            id: col
            x: 28; y: 28; width: parent.width - 56; spacing: 14
            Text { width: parent.width; text: menu.title; elide: Text.ElideRight; color: theme.fg; font { family: theme.displayFont; pixelSize: 24; bold: true } }
            Text { visible: menu.subtitle !== ""; width: parent.width; text: menu.subtitle; wrapMode: Text.WordWrap; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 14 } }
            Menu {
                width: parent.width; theme: menu.theme; currentIndex: menu.index; items: menu.items
                pointerActive: menu.pointerActive
                onClicked: (i) => { menu.index = i; menu.handle("a") }
            }
            Text { text: qsTr("A  Choose      B  Back"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 13 } }
        }
    }
}
