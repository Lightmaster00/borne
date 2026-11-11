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
    onIndexChanged: Qt.callLater(listView.follow)
    onItemsChanged: Qt.callLater(listView.follow)

    visible: false
    anchors.fill: parent
    color: Qt.rgba(0.047, 0.051, 0.063, 0.6)

    function open(t, sub, list, cb, at) {
        title = t
        subtitle = sub || ""
        items = list
        callback = cb
        index = at !== undefined && at >= 0 && at < list.length && !list[at].disabled ? at : Math.max(0, list.findIndex(i => !i.disabled))
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
        width: Math.min(760, parent.width - 80)
        height: col.height + 72
        radius: 28
        color: theme.panel
        border.color: theme.panelBorder
        MouseArea { anchors.fill: parent }   // clicks on the panel itself do not close it
        Column {
            id: col
            x: 36; y: 36; width: parent.width - 72; spacing: 18
            Text { width: parent.width; text: menu.title; elide: Text.ElideRight; color: theme.fg; font { family: theme.displayFont; pixelSize: 34; weight: Font.ExtraBold } }
            Text { visible: menu.subtitle !== ""; width: parent.width; text: menu.subtitle; wrapMode: Text.WordWrap; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 18 } }
            // Long lists (cheats) scroll to follow the selection.
            Flickable {
                id: listView
                width: parent.width
                height: Math.min(list.height, menu.height - 360)
                contentHeight: list.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Behavior on contentY { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                function follow() {
                    const item = list.children[menu.index]
                    if (!item) return
                    if (item.y < contentY) contentY = item.y
                    else if (item.y + item.height > contentY + height) contentY = item.y + item.height - height
                }
                Menu {
                    id: list
                    width: parent.width; theme: menu.theme; currentIndex: menu.index; items: menu.items
                    pointerActive: menu.pointerActive
                    onClicked: (i) => { menu.index = i; menu.handle("a") }
                }
            }
            HintBar {
                theme: menu.theme
                pointerActive: menu.pointerActive
                hints: [["A", qsTr("Choose"), "a"], ["B", qsTr("Back"), "b"]]
                onTriggered: (a) => menu.handle(a)
            }
        }
    }
}
