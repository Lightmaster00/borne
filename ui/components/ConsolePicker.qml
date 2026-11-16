// Which consoles of the RomM library Borne shows (asked once after the first sync, then from
// Settings → Consoles). Each with its games, whether Borne plays it, and what its games need
// that this machine lacks (touch screen, Wii Remote, motion, power), so nothing is a surprise.
// Gamepad: up/down to move, A to show or leave out, Start to confirm, B to go back.
import QtQuick
import "ConsoleNeeds.js" as Needs

Item {
    id: picker
    property QtObject theme
    property var info: null          // GET /api/v1/consoles
    property var shown: ({})         // slug → shown, as being chosen
    property int row: 0
    property bool firstTime: false
    signal done(var shownSlugs)
    signal cancelled()

    readonly property var consoles: info ? info.consoles : []
    readonly property var current: consoles[row] || null

    function open(d, first) {
        info = d
        firstTime = first
        const s = {}
        // First time: every console Borne plays; then: as they are.
        for (const c of consoles) s[c.slug] = first ? c.supported : c.shown
        shown = s
        row = 0
        visible = true
    }
    function toggle() {
        if (!current) return
        const s = Object.assign({}, shown)
        s[current.slug] = !s[current.slug]
        shown = s
    }
    function confirm() {
        visible = false
        done(consoles.filter(c => shown[c.slug]).map(c => c.slug))
    }
    function handle(a) {
        if (a === "up") row = Math.max(0, row - 1)
        else if (a === "down") row = Math.min(consoles.length - 1, row + 1)
        else if (a === "a") toggle()
        else if (a === "start" || a === "x") confirm()
        else if (a === "b") { if (firstTime) confirm(); else { visible = false; cancelled() } }
        list.positionViewAtIndex(row, ListView.Contain)
    }

    visible: false
    Rectangle { anchors.fill: parent; color: picker.theme.bg }

    Column {
        id: head
        x: 84; y: 64
        width: parent.width - 168
        spacing: 10
        Text {
            text: qsTr("Your consoles")
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 40; weight: Font.Bold }
        }
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("Choose the consoles Borne shows. The others stay on RomM and can be added later, in Settings → Consoles. What a console's games need that this computer lacks is said beside it.")
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 19 }
        }
    }

    ListView {
        id: list
        x: 84
        anchors { top: head.bottom; topMargin: 28; bottom: footer.top; bottomMargin: 20 }
        width: parent.width * 0.48
        clip: true
        spacing: 8
        model: picker.consoles
        delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool cur: index === picker.row
            readonly property bool on: !!picker.shown[modelData.slug]
            readonly property int missing: (modelData.warnings || []).filter(w => w.missing).length
            width: list.width
            height: 72
            radius: 20
            color: cur ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.04)
            border { width: cur ? 3 : 0; color: theme.focusRing }
            Rectangle {
                id: box
                x: 20; anchors.verticalCenter: parent.verticalCenter
                width: 30; height: 30; radius: 8
                color: parent.on ? theme.accent : "transparent"
                border { width: 2; color: parent.on ? theme.accent : theme.fgFaint }
                Text { anchors.centerIn: parent; visible: parent.parent.on; text: "✓"; color: theme.accentFg; font { pixelSize: 20; weight: Font.Bold } }
            }
            Column {
                anchors { left: box.right; leftMargin: 18; verticalCenter: parent.verticalCenter; right: badge.left; rightMargin: 12 }
                spacing: 2
                Text {
                    width: parent.width; elide: Text.ElideRight
                    text: modelData.name
                    color: theme.fg
                    font { family: theme.fontFamily; pixelSize: 21; weight: Font.DemiBold }
                }
                Text {
                    text: qsTr("%n game(s)", "", modelData.games) + (modelData.supported ? "" : " · " + qsTr("not playable in Borne yet"))
                    color: theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 16 }
                }
            }
            Rectangle {
                id: badge
                visible: parent.missing > 0 && modelData.supported
                anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
                height: 30; radius: 15
                width: warnText.implicitWidth + 24
                color: theme.badTint
                Text { id: warnText; anchors.centerIn: parent; text: qsTr("Good to know"); color: theme.badSoft; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold } }
            }
        }
    }

    // The selected console: what its games need, said in full.
    Column {
        anchors { left: list.right; leftMargin: 48; right: parent.right; rightMargin: 84; top: list.top }
        spacing: 14
        Text {
            width: parent.width
            text: picker.current ? picker.current.name : ""
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 30; weight: Font.Bold }
        }
        Text {
            visible: !!picker.current && !picker.current.supported
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("Borne cannot start these games yet: no emulator for this console.")
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 18 }
        }
        Text {
            visible: !!picker.current && picker.current.supported && !(picker.current.warnings || []).length
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("Nothing particular: a pad is enough.")
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 18 }
        }
        Repeater {
            model: picker.current && picker.current.supported ? picker.current.warnings : []
            Row {
                required property var modelData
                width: parent.width
                spacing: 12
                Text {
                    text: modelData.missing ? "⚠" : "✓"
                    color: modelData.missing ? theme.bad : theme.accent
                    font { pixelSize: 20; weight: Font.Bold }
                }
                Text {
                    width: parent.width - 36
                    wrapMode: Text.WordWrap
                    text: Needs.text(modelData)
                    color: modelData.missing ? theme.fg : theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 18 }
                    lineHeight: 1.2
                }
            }
        }
    }

    HintBar {
        id: footer
        x: 84; anchors { bottom: parent.bottom; bottomMargin: 48 }
        theme: picker.theme
        hints: [["A", qsTr("Show or leave out"), "a"], ["Start", qsTr("Confirm"), "start"]].concat(picker.firstTime ? [] : [["B", qsTr("Back"), "b"]])
    }
}
