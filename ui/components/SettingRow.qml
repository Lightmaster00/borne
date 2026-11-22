// One line of the settings (Borne's and a game's): its name and a sentence on the left, and on
// the right its value between arrows (a choice: ← → change it at once, dots tell how many there
// are), its buttons, or its state and a chevron (a line that opens a page). The line selected is
// light, its text dark.
import QtQuick

Rectangle {
    id: row
    property QtObject theme
    property string kind: "chips"        // "chips" | "buttons" | "link"
    property string title: ""
    property string desc: ""
    property var items: []               // [{ id, label, detail?, disabled?, primary? }]
    property string selected: ""         // the choice made (chips)
    property bool current: false         // the line selected
    property int focusedCol: -1          // the button selected (buttons)
    property string badge: ""            // link: its state
    property string tone: ""             // link: "bad" | "ok" | ""

    readonly property bool lit: current && kind !== "buttons"
    readonly property int pick: Math.max(0, items.findIndex(x => x.id === selected))
    readonly property var picked: items[pick] || null
    readonly property color ink: lit ? "#121216" : theme.fg
    readonly property color soft: lit ? Qt.rgba(0.07, 0.07, 0.09, 0.62) : theme.fgMuted

    implicitHeight: Math.max(90, Math.max(texts.height, right.height) + 32)
    radius: 18
    color: lit ? theme.fg : current ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.045)
    border { width: current && kind === "buttons" ? 2 : 0; color: Qt.rgba(1, 1, 1, 0.45) }
    Behavior on color { ColorAnimation { duration: 160 } }

    Column {
        id: texts
        x: 28
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - 56 - right.width - 28
        spacing: 4
        Text {
            width: parent.width
            text: row.title
            elide: Text.ElideRight
            color: row.ink
            font { family: theme.fontFamily; pixelSize: 22; weight: Font.ExtraBold }
        }
        Text {
            visible: text !== ""
            width: parent.width
            text: row.desc
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
            lineHeight: 1.2
            color: row.soft
            font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold }
        }
    }

    Item {
        id: right
        anchors { right: parent.right; rightMargin: 28; verticalCenter: parent.verticalCenter }
        width: row.kind === "chips" ? cycler.width : row.kind === "link" ? linkRow.width : buttons.width
        height: row.kind === "chips" ? cycler.height : row.kind === "link" ? linkRow.height : buttons.height

        // A choice: ‹ value ›, and a dot per choice.
        Column {
            id: cycler
            visible: row.kind === "chips"
            spacing: 8
            width: Math.min(380, Math.max(160, valueRow.implicitWidth))
            Row {
                id: valueRow
                anchors.right: parent.right
                spacing: 14
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "‹"
                    opacity: row.current && row.items.length > 1 ? 1 : 0
                    color: row.ink
                    font { family: theme.fontFamily; pixelSize: 26; weight: Font.Bold }
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.right: parent.right
                        width: Math.min(implicitWidth, 300)
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideRight
                        text: row.picked ? row.picked.label : ""
                        color: row.ink
                        font { family: theme.fontFamily; pixelSize: 21; weight: Font.ExtraBold }
                    }
                    Text {
                        visible: !!row.picked && !!row.picked.detail
                        anchors.right: parent.right
                        text: row.picked && row.picked.detail ? row.picked.detail : ""
                        color: row.soft
                        font { family: theme.fontFamily; pixelSize: 14; weight: Font.Bold }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "›"
                    opacity: row.current && row.items.length > 1 ? 1 : 0
                    color: row.ink
                    font { family: theme.fontFamily; pixelSize: 26; weight: Font.Bold }
                }
            }
            Row {
                visible: row.items.length > 1 && row.items.length <= 12
                anchors.right: parent.right
                anchors.rightMargin: 28
                spacing: 6
                Repeater {
                    model: row.items.length
                    Rectangle {
                        required property int index
                        width: index === row.pick ? 16 : 6; height: 6; radius: 3
                        color: row.ink
                        opacity: index === row.pick ? 0.9 : 0.3
                        Behavior on width { NumberAnimation { duration: 160 } }
                    }
                }
            }
        }

        // A line that opens something: its state, a chevron.
        Row {
            id: linkRow
            visible: row.kind === "link"
            spacing: 14
            Rectangle {
                visible: row.badge !== ""
                anchors.verticalCenter: parent.verticalCenter
                height: 34; radius: 17
                width: badgeText.implicitWidth + 28
                color: row.tone === "bad" ? theme.badTint : row.tone === "ok" ? theme.accentSoft : row.lit ? Qt.rgba(0, 0, 0, 0.08) : Qt.rgba(1, 1, 1, 0.08)
                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    text: row.badge
                    color: row.tone === "bad" ? theme.badSoft : row.tone === "ok" ? theme.accent : row.soft
                    font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "›"
                color: row.ink
                opacity: row.current ? 1 : 0.5
                font { family: theme.fontFamily; pixelSize: 32; weight: Font.Medium }
            }
        }

        // Buttons.
        Flow {
            id: buttons
            visible: row.kind === "buttons"
            width: Math.min(implicitW, 560)
            readonly property real implicitW: {
                let w = 0
                for (let i = 0; i < btnRep.count; i++) { const it = btnRep.itemAt(i); if (it) w += it.width + 10 }
                return Math.max(0, w - 10)
            }
            spacing: 10
            Repeater {
                id: btnRep
                model: row.kind === "buttons" ? row.items : []
                PageButton {
                    required property var modelData
                    required property int index
                    implicitHeight: 52
                    theme: row.theme
                    text: modelData.label
                    primary: !!modelData.primary
                    disabled: !!modelData.disabled
                    focused: row.current && row.focusedCol === index
                }
            }
        }
    }
}
