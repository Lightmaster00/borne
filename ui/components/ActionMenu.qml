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
    readonly property bool opened: visible
    onIndexChanged: Qt.callLater(listView.follow)
    onItemsChanged: { listView.contentY = 0; Qt.callLater(listView.follow) }

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


    Rectangle {
        anchors.centerIn: parent
        width: Math.min(760, parent.width - 80)
        height: col.height + 72
        radius: 28
        color: theme.panel
        Ink { z: -1; theme: menu.theme; radius: 28 }
        border.color: theme.panelBorder
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
                    if (list.height <= height + 1) { contentY = 0; return }
                    const item = list.rowAt(menu.index)
                    if (!item) return
                    if (item.y < contentY) contentY = item.y
                    else if (item.y + item.height > contentY + height) contentY = item.y + item.height - height
                }
                Menu {
                    id: list
                    width: parent.width; theme: menu.theme; currentIndex: menu.index; items: menu.items
                }
            }
            HintBar {
                theme: menu.theme
                hints: [["A", qsTr("Choose"), "a"], ["B", qsTr("Back"), "b"]]
            }
        }
    }
}
