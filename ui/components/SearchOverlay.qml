// Search across the current library. Matches update as you type and the
// shelf behind follows the highlighted result, so confirming simply lands
// on that game. Works with the on-screen keyboard (pad) or a real keyboard.
import QtQuick

Item {
    id: root
    property QtObject theme
    property var model: null          // the library ListModel
    property bool pointerActive: false
    property bool showKeyboard: true  // hidden when the user types on a physical keyboard
    property int selected: 0
    property var results: []          // [{ index, name, sub, cover }]
    readonly property string query: kb.text
    visible: false

    signal picked(int index)          // library index to focus
    signal closed()

    function fold(s) {
        return (s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase()
    }
    function open(initial, fromKeyboard) {
        kb.text = initial || ""
        kb.row = 1; kb.col = 0; kb.shift = false
        showKeyboard = !fromKeyboard
        selected = 0
        refresh()
        visible = true
    }
    function close() { visible = false; closed() }
    function refresh() {
        const q = fold(kb.text).trim()
        const out = []
        if (q.length && model) {
            for (let i = 0; i < model.count; i++) {
                const g = model.get(i)
                const n = fold(g.name)
                const at = n.indexOf(q)
                if (at < 0) continue
                const score = at === 0 ? 0 : (n.charAt(at - 1) === " " || n.charAt(at - 1) === ":" || n.charAt(at - 1) === "-") ? 1 : 2
                out.push({ index: i, score: score, name: g.name, cover: g.cover,
                           sub: [g.platform_name, g.year > 0 ? g.year : ""].filter(x => x).join(" · ") })
            }
            out.sort((a, b) => a.score - b.score || a.index - b.index)
        }
        results = out.slice(0, 6)
        total = out.length
        selected = 0
        if (results.length) picked(results[0].index)
    }
    property int total: 0
    function step(d) {
        if (!results.length) return
        selected = (selected + d + results.length) % results.length
        picked(results[selected].index)
    }
    function confirm() {
        if (results.length) picked(results[selected].index)
        close()
    }
    function typeText(t) { kb.typeText(t) }
    function backspace() { if (kb.text.length) kb.backspace(); else close() }
    function handle(a) {
        if (a === "lb" || a === "lt") return step(-1)
        if (a === "rb" || a === "rt") return step(1)
        if (a === "start") return confirm()
        if (a === "select") return close()
        if (!showKeyboard) {
            if (a === "up") return step(-1)
            if (a === "down") return step(1)
            if (a === "a") return confirm()
            if (a === "b") return backspace()
            return
        }
        if (a === "b" && !kb.text.length) return close()
        kb.handle(a)
    }

    Connections { target: kb; function onTextChanged() { root.refresh() } }

    Rectangle { anchors.fill: parent; color: Qt.rgba(0.03, 0.035, 0.045, 0.82) }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    Rectangle {
        id: panel
        anchors.horizontalCenter: parent.horizontalCenter
        y: 120
        width: 1240
        height: content.height + 64
        radius: 22
        color: Qt.rgba(0.09, 0.1, 0.12, 0.92)
        border { color: Qt.rgba(1, 1, 1, 0.08); width: 1 }
        MouseArea { anchors.fill: parent }   // swallow clicks inside the panel

        Column {
            id: content
            x: 32; y: 32
            width: parent.width - 64
            spacing: 22

            Row {
                spacing: 14
                Icon { name: "search"; size: 26; color: root.theme.fgMuted; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: qsTr("Search")
                    color: root.theme.fg
                    font { family: root.theme.displayFont; pixelSize: 30; weight: Font.Bold }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.query.length > 0
                    text: root.total === 0 ? qsTr("No game found") : qsTr("%n game(s)", "", root.total)
                    color: root.theme.fgMuted
                    font { family: root.theme.fontFamily; pixelSize: 18; weight: Font.Medium }
                }
            }

            Row {
                spacing: 32
                width: parent.width

                OnScreenKeyboard {
                    id: kb
                    visible: root.showKeyboard
                    width: implicitWidth; height: implicitHeight
                    theme: root.theme
                    maxLength: 40
                    placeholder: qsTr("Game title")
                    onAccepted: root.confirm()
                    onCancelled: root.close()
                }

                Column {
                    width: root.showKeyboard ? parent.width - kb.width - 32 : parent.width
                    spacing: 8

                    // With a physical keyboard there is no on-screen field: show the query here.
                    Rectangle {
                        visible: !root.showKeyboard
                        width: parent.width; height: 60; radius: 12
                        color: Qt.rgba(1, 1, 1, 0.05)
                        border { color: Qt.rgba(1, 1, 1, 0.14); width: 1 }
                        Text {
                            id: typed
                            anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
                            text: root.query.length ? root.query : qsTr("Type a game title")
                            color: root.query.length ? root.theme.fg : root.theme.fgMuted
                            font { family: root.theme.fontFamily; pixelSize: 24; weight: Font.Medium }
                        }
                        Rectangle {
                            x: typed.x + typed.contentWidth + 3
                            visible: root.query.length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: 2; height: 30; color: root.theme.fg
                            SequentialAnimation on opacity { loops: Animation.Infinite; NumberAnimation { to: 0; duration: 500 } NumberAnimation { to: 1; duration: 500 } }
                        }
                    }

                    Text {
                        visible: !root.query.length
                        width: parent.width
                        topPadding: 12
                        wrapMode: Text.WordWrap
                        text: qsTr("Results appear as you type. The library follows the highlighted game.")
                        color: root.theme.fgMuted
                        font { family: root.theme.fontFamily; pixelSize: 18 }
                    }

                    Repeater {
                        model: root.results
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            readonly property bool cur: index === root.selected
                            width: parent.width; height: 72; radius: 12
                            color: cur ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
                            border { color: cur ? Qt.rgba(1, 1, 1, 0.35) : "transparent"; width: 1 }
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Rectangle {
                                id: thumb
                                x: 10; anchors.verticalCenter: parent.verticalCenter
                                width: 40; height: 56; radius: 4
                                color: Qt.rgba(1, 1, 1, 0.06)
                                clip: true
                                Image {
                                    anchors.fill: parent
                                    source: modelData.cover || ""
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize { width: 80; height: 112 }
                                    asynchronous: true
                                }
                            }
                            Column {
                                anchors { left: thumb.right; leftMargin: 16; right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                                spacing: 3
                                Text {
                                    width: parent.width
                                    text: modelData.name
                                    elide: Text.ElideRight
                                    color: root.theme.fg
                                    font { family: root.theme.fontFamily; pixelSize: 21; weight: cur ? Font.Bold : Font.SemiBold }
                                }
                                Text {
                                    width: parent.width
                                    text: modelData.sub
                                    elide: Text.ElideRight
                                    color: root.theme.fgMuted
                                    font { family: root.theme.fontFamily; pixelSize: 15; weight: Font.Medium }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { root.selected = index; root.confirm() }
                            }
                        }
                    }
                }
            }

            HintBar {
                theme: root.theme
                pointerActive: root.pointerActive
                hints: root.showKeyboard
                    ? [["A", qsTr("Key"), "a"], ["B", qsTr("Erase"), "b"], ["LB/RB", qsTr("Result"), "rb"], ["Start", qsTr("Go to game"), "start"]]
                    : [["↑↓", qsTr("Result"), "down"], ["Enter", qsTr("Go to game"), "start"], ["Esc", qsTr("Close"), "select"]]
                onTriggered: (a) => root.handle(a)
            }
        }
    }
}
