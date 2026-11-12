// A game's own settings, over its page: sections on the left, their rows on the right, as in
// Settings. Nothing closes by itself: a choice applies and stays on screen; B goes back one level
// (from the rows to the sections, from the sections to the game page).
// Gamepad: up/down in the focused column (group titles and notes skipped), right or A enters a
// section, left/right between a row's choices, A to choose, B to go back.
import QtQuick
import "Display.js" as Display
import "EmuOptions.js" as EmuOptions

Item {
    id: page
    property QtObject theme
    property var game: null
    // Filled by Main.qml from the core (null while loading):
    property var emulator: null      // GET /games/<id>/emulator
    property var emuOptions: null    // GET /games/<id>/emuoptions
    property var display: null       // GET /games/<id>/display
    property var cheats: null        // GET /games/<id>/cheats
    property var images: null        // GET /games/<id>/screenscraper
    property var languages: []       // [{ code, version }] when the game exists in several
    property string currentLang: ""
    property var languageName: function (c) { return c }
    property bool hasVideo: false
    property bool videoSound: false

    signal action(string id, var payload)

    property int section: 0
    property bool inRows: false
    property int row: 0
    property var cols: ({})

    readonly property bool playable: !!game && (game.local_state === "local" || game.linked)

    function open() { section = 0; inRows = false; row = firstRow(); resetCols(); visible = true }
    function close() { visible = false }
    visible: false

    function group(t) { return { id: "group:" + t, kind: "header", title: t, items: [] } }
    function note(id, t) { return { id: id, kind: "note", title: t, items: [] } }

    readonly property var sections: {
        const s = [
            { id: "emulator", name: qsTr("Emulator"), hint: emulator && emulator.own ? qsTr("Its own") : qsTr("As for its console") },
            { id: "picture", name: qsTr("Picture"), hint: qsTr("Shape, sharpness, filters") },
            { id: "cheats", name: qsTr("Cheats"), hint: cheats && cheats.cheats ? qsTr("%n on", "", cheats.cheats.filter(x => x.on).length) : "" }
        ]
        if (languages.length > 1) s.push({ id: "language", name: qsTr("Language"), hint: languageName(currentLang) })
        s.push({ id: "cover", name: qsTr("Cover and video"), hint: qsTr("ScreenScraper") })
        if (game && (game.local_state === "local" || game.linked || game.local_state === "missing"))
            s.push({ id: "storage", name: qsTr("Storage"), hint: game.local_state === "local" ? qsTr("On this device") : game.linked ? qsTr("Network mount") : "" })
        return s
    }
    readonly property string sectionId: sections[Math.min(section, sections.length - 1)].id

    readonly property var rows: {
        const id = sectionId
        if (id === "emulator") {
            if (!emulator) return [note("loading", qsTr("Loading…"))]
            const consoleName = (emulator.choices.find(c => c.id === emulator.console) || {}).name || ""
            const r = [group(qsTr("Program")),
                { id: "engine", kind: "chips", title: qsTr("Emulator"), desc: qsTr("The program that runs this game"),
                  selected: emulator.own || "",
                  items: [{ id: "", label: qsTr("As for its console (%1)").arg(consoleName) }].concat(emulator.choices.map(c => ({ id: c.id, label: c.name }))) }]
            const opts = emuOptions ? emuOptions.options : []
            r.push(group(emuOptions && emuOptions.engine ? qsTr("%1 options for this game").arg(emuOptions.engine) : qsTr("Options for this game")))
            if (!opts.length) r.push(note("no-opts", qsTr("This emulator has no option of its own here: the picture settings apply.")))
            for (const o of opts)
                r.push({ id: "opt:" + o.key, kind: "chips", title: EmuOptions.title(o.key), desc: EmuOptions.desc(o.key) + (o.own ? "" : " · " + qsTr("default")),
                         selected: o.value, items: o.values.map(v => ({ id: v, label: EmuOptions.label(o.key, v) })) })
            if (opts.some(o => o.own)) r.push({ id: "opt-reset", kind: "buttons", title: qsTr("This game's options"), desc: qsTr("Back to the emulator's defaults"),
                                                items: [{ id: "opt-reset", label: qsTr("Reset") }] })
            r.push(note("applied", qsTr("Applied the next time the game starts.")))
            return r
        }
        if (id === "picture") {
            if (!display) return [note("loading", qsTr("Loading…"))]
            const r = Display.KEYS.map(k => {
                const items = [{ id: "default", label: qsTr("As for its console") }].concat(Display.values(k).map(v => ({ id: v, label: Display.label(k, v) })))
                const own = display.own[k]
                return { id: "disp:" + k, kind: "chips", title: Display.title(k),
                         desc: Display.desc(k) + (own === undefined ? " · " + qsTr("now: %1").arg(Display.label(k, display.effective[k])) : ""),
                         selected: own !== undefined ? own : "default", items: items }
            })
            r.push(note("applied", qsTr("Applied the next time the game starts.")))
            return r
        }
        if (id === "cheats") {
            const ps2 = game && game.platform_slug === "ps2"
            const files = ps2 ? [{ id: "pnach-pick", label: qsTr("Choose a file") }, { id: "pnach-path", label: qsTr("Type its path") }, { id: "pnach-url", label: qsTr("From a link") }] : []
            if (!playable) return [note("not-here", qsTr("Install the game or mount it from the network to choose its cheats."))]
            if (!cheats) return [note("loading", qsTr("Loading…"))]
            const r = []
            if (!cheats.cheats.length) {
                r.push(note("none", ps2 ? qsTr("PS2 cheats come from a .pnach file you give for this game (PCSX2's format).")
                                        : cheats.updating ? qsTr("Downloading the cheat databases… try again in a moment.")
                                        : cheats.error ? cheats.error : qsTr("No cheats for this version of the game in the public databases.")))
            } else {
                r.push(group(qsTr("%n cheat(s) on", "", cheats.cheats.filter(x => x.on).length)))
                cheats.cheats.forEach((x, i) => r.push({ id: "cheat:" + i, kind: "chips", title: x.name, selected: x.on ? "on" : "off",
                                                         items: [{ id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }] }))
                r.push({ id: "cheats-off", kind: "buttons", title: qsTr("All cheats"), items: [{ id: "cheats-off", label: qsTr("Turn all off"), disabled: !cheats.cheats.some(x => x.on) }] })
            }
            if (ps2) r.push({ id: "pnach", kind: "buttons", title: qsTr(".pnach file"), desc: qsTr("Cheats for this game, in PCSX2's format"), items: files })
            r.push(note("applied", qsTr("Applied the next time the game starts.")))
            return r
        }
        if (id === "language") return [
            { id: "lang", kind: "chips", title: qsTr("Game language"), desc: qsTr("Starts the version of the game in this language"),
              selected: currentLang, items: languages.map(l => ({ id: l.code, label: languageName(l.code) })) }
        ]
        if (id === "cover") {
            const r = [group(qsTr("Cover"))]
            const regions = images && images.regions ? images.regions : []
            if (regions.length > 1)
                r.push({ id: "region", kind: "chips", title: qsTr("Box region"), desc: qsTr("Which edition's box is shown"),
                         selected: images.chosen || "", items: [{ id: "", label: qsTr("Automatic") }].concat(regions.map(x => ({ id: x, label: regionName(x) }))) })
            r.push({ id: "ss-search", kind: "buttons", title: qsTr("Not the right game?"), desc: qsTr("Search ScreenScraper by name and choose the right one"),
                     items: [{ id: "ss-search", label: qsTr("Search") }] })
            if (hasVideo) {
                r.push(group(qsTr("Video")))
                r.push({ id: "sound", kind: "chips", title: qsTr("Video sound"), desc: qsTr("The trailer on this game's page"),
                         selected: videoSound ? "on" : "off", items: [{ id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }] })
            }
            return r
        }
        const r = []
        if (game && game.local_state === "local")
            r.push({ id: "delete", kind: "buttons", title: qsTr("Delete from this device"), desc: qsTr("Saves stay on RomM; the game can be downloaded again"),
                     items: [{ id: "delete", label: qsTr("Delete") }] })
        else if (game && game.linked)
            r.push({ id: "unlink", kind: "buttons", title: qsTr("Remove from the network mount"), desc: qsTr("The game stays on RomM"), items: [{ id: "unlink", label: qsTr("Remove") }] })
        else if (game && game.local_state === "missing")
            r.push({ id: "delete", kind: "buttons", title: qsTr("Forget the local copy"), desc: qsTr("Its files are no longer there"), items: [{ id: "delete", label: qsTr("Forget") }] })
        return r
    }
    property var regionName: function (c) { return c.toUpperCase() }

    function focusable(r) { return r.kind !== "header" && r.kind !== "note" }
    function step(i, d) {
        for (let j = i + d; j >= 0 && j < rows.length; j += d) if (focusable(rows[j])) return j
        return i
    }
    function firstRow() { return step(-1, 1) }
    function hasRows() { return rows.some(focusable) }
    function resetCols() {
        const c = {}
        for (const r of rows) c[r.id] = Math.max(0, r.items.findIndex(x => x.id === r.selected))
        cols = c
    }
    // Rows change as answers come: keep the focus on a real row, new rows on their current choice.
    onRowsChanged: {
        if (row >= rows.length || (rows[row] && !focusable(rows[row]))) {
            const f = step(-1, 1)
            row = row >= rows.length ? step(rows.length, -1) : step(row, 1) !== row ? step(row, 1) : f
        }
        const c = Object.assign({}, cols)
        let changed = false
        for (const r of rows) if (c[r.id] === undefined) { c[r.id] = Math.max(0, r.items.findIndex(x => x.id === r.selected)); changed = true }
        if (changed) cols = c
    }
    function colOf(id) { return cols[id] !== undefined ? cols[id] : 0 }
    function setCol(id, c) { const n = Object.assign({}, cols); n[id] = c; cols = n }
    function selectSection(i) { section = i; row = firstRow(); resetCols() }

    function activate(r, i) {
        const item = r.items[i]
        if (!item || item.disabled) return
        if (r.kind === "chips" && item.id === r.selected && !r.id.startsWith("disp:")) return
        if (r.id === "engine") page.action("engine", item.id)
        else if (r.id.startsWith("opt:")) page.action("opt", { key: r.id.substring(4), value: item.id })
        else if (r.id.startsWith("disp:")) page.action("display", { key: r.id.substring(5), value: item.id })
        else if (r.id.startsWith("cheat:")) page.action("cheat", { index: Number(r.id.substring(6)), on: item.id === "on" })
        else if (r.id === "lang") page.action("lang", languages.find(l => l.code === item.id))
        else if (r.id === "region") page.action("region", item.id)
        else if (r.id === "sound") page.action("sound", item.id === "on")
        else page.action(item.id, null)
    }
    function handle(a) {
        if (a === "b" || a === "start") {
            if (inRows && a === "b") { inRows = false; return }
            page.action("close", null)
            return
        }
        if (!inRows) {
            if (a === "up") selectSection(Math.max(0, section - 1))
            else if (a === "down") selectSection(Math.min(sections.length - 1, section + 1))
            else if ((a === "right" || a === "a") && hasRows()) { inRows = true; row = firstRow() }
            return
        }
        const r = rows[Math.min(row, rows.length - 1)]
        if (!r) return
        const n = r.items.length
        if (a === "up") row = step(row, -1)
        else if (a === "down") row = step(row, 1)
        else if (a === "left") { if (colOf(r.id) === 0) inRows = false; else setCol(r.id, colOf(r.id) - 1) }
        else if (a === "right") setCol(r.id, Math.min(n - 1, colOf(r.id) + 1))
        else if (a === "a") activate(r, colOf(r.id))
    }
    function focused(id, i) { return inRows && rows[row] && rows[row].id === id && colOf(id) === i }

    Rectangle { anchors.fill: parent; color: theme.bg }

    // ---------- sections ----------
    Rectangle {
        id: side
        width: 480
        height: parent.height
        color: Qt.rgba(1, 1, 1, 0.05)
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, 0.1) }
        Column {
            x: 64; y: 64
            width: parent.width - 104
            spacing: 6
            Text { text: qsTr("Game settings"); color: theme.fg; font { family: theme.displayFont; pixelSize: 40; weight: Font.ExtraBold; letterSpacing: -1 } }
            Text { width: parent.width; text: page.game ? page.game.name : ""; elide: Text.ElideRight; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 18; weight: Font.Medium } }
        }
        Column {
            x: 64; y: 180
            width: parent.width - 104
            spacing: 8
            Repeater {
                model: page.sections
                Rectangle {
                    id: sec
                    required property var modelData
                    required property int index
                    readonly property bool current: page.section === index
                    readonly property bool focusedHere: current && !page.inRows
                    width: parent.width; height: 72
                    radius: 14
                    color: focusedHere ? Qt.rgba(1, 1, 1, 0.14) : current ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
                    Behavior on color { ColorAnimation { duration: theme.focusMs } }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 4; height: parent.height - 24; radius: 2
                        color: theme.accent
                        opacity: sec.focusedHere ? 1 : sec.current ? 0.45 : 0
                    }
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.name
                    Column {
                        x: 20; anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { text: sec.modelData.name; color: sec.current ? theme.fg : theme.fgMuted; font { family: theme.fontFamily; pixelSize: 21; weight: Font.DemiBold } }
                        Text { visible: text !== ""; text: sec.modelData.hint; color: theme.fgFaint; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Medium } }
                    }
                }
            }
        }
    }

    // ---------- rows ----------
    Flickable {
        id: rowsView
        x: side.width + 80; y: 64
        width: Math.min(1500, parent.width - x - 96)
        height: parent.height - y - 110
        contentHeight: rowsCol.height + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Behavior on contentY { NumberAnimation { duration: theme.scrollMs; easing.type: Easing.OutCubic } }
        function ensure(item) {
            const top = item.y, bottom = item.y + item.height
            if (top - 24 < contentY) contentY = Math.max(0, top - 24)
            else if (bottom + 24 > contentY + height) contentY = Math.min(contentHeight - height, bottom + 24 - height)
        }
        Connections { target: page; function onSectionChanged() { rowsView.contentY = 0 } }
        Column {
            id: rowsCol
            width: parent.width
            spacing: 18
            Text { text: page.sections[Math.min(page.section, page.sections.length - 1)].name; color: theme.fg; font { family: theme.displayFont; pixelSize: 34; weight: Font.Bold } }
            Repeater {
                model: page.rows
                Item {
                    id: rowItem
                    required property var modelData
                    required property int index
                    readonly property bool current: page.inRows && page.row === index
                    readonly property string kind: modelData.kind
                    onCurrentChanged: if (current) rowsView.ensure(rowItem)
                    width: parent.width
                    height: kind === "header" ? 58 : kind === "note" ? noteText.height + 8 : Math.max(96, line.height + 52)

                    Item {
                        visible: rowItem.kind === "header"
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 6; leftMargin: 8 }
                        height: groupTitle.height
                        Text {
                            id: groupTitle
                            text: (rowItem.modelData.title || "").toUpperCase()
                            color: theme.fgFaint
                            font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold; letterSpacing: 1.6 }
                        }
                        Rectangle {
                            anchors { left: groupTitle.right; leftMargin: 16; right: parent.right; rightMargin: 8; verticalCenter: groupTitle.verticalCenter }
                            height: 1; color: Qt.rgba(1, 1, 1, 0.1)
                        }
                    }
                    Text {
                        id: noteText
                        visible: rowItem.kind === "note"
                        x: 8; y: 4
                        width: parent.width - 16
                        text: rowItem.kind === "note" ? rowItem.modelData.title : ""
                        wrapMode: Text.WordWrap
                        color: theme.fgMuted
                        font { family: theme.fontFamily; pixelSize: 17 }
                    }
                    Rectangle {
                        visible: rowItem.kind === "chips" || rowItem.kind === "buttons"
                        anchors.fill: parent
                        radius: 26
                        color: rowItem.current ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(1, 1, 1, 0.045)
                        Behavior on color { ColorAnimation { duration: theme.focusMs } }
                    }
                    Item {
                        id: line
                        visible: rowItem.kind === "chips" || rowItem.kind === "buttons"
                        x: 32
                        width: parent.width - 64
                        height: Math.max(texts.height, choices.height)
                        anchors.verticalCenter: parent.verticalCenter
                        Column {
                            id: texts
                            width: Math.max(260, parent.width - choices.width - 32)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 4
                            Text { width: parent.width; text: rowItem.modelData.title || ""; elide: Text.ElideRight; color: theme.fg; font { family: theme.fontFamily; pixelSize: 20; weight: Font.DemiBold } }
                            Text {
                                visible: text !== ""
                                width: parent.width
                                text: rowItem.modelData.desc || ""
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                color: theme.fgMuted
                                font { family: theme.fontFamily; pixelSize: 16 }
                            }
                        }
                        Flow {
                            id: choices
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                            width: Math.min(implicitW, line.width - 292)
                            readonly property real implicitW: {
                                let w = 0
                                for (let i = 0; i < rep.count; i++) { const it = rep.itemAt(i); if (it) w += it.width + 10 }
                                return Math.max(0, w - 10)
                            }
                            spacing: 10
                            Repeater {
                                id: rep
                                model: rowItem.modelData.items
                                Item {
                                    required property var modelData
                                    required property int index
                                    width: rowItem.kind === "buttons" ? btn.width : chip.width
                                    height: rowItem.kind === "buttons" ? btn.height : chip.height
                                    PageButton {
                                        id: btn
                                        visible: rowItem.kind === "buttons"
                                        implicitHeight: 52
                                        theme: page.theme
                                        text: modelData.label
                                        primary: !!modelData.primary
                                        disabled: !!modelData.disabled
                                        focused: page.focused(rowItem.modelData.id, index)
                                    }
                                    Chip {
                                        id: chip
                                        visible: rowItem.kind === "chips"
                                        theme: page.theme
                                        text: modelData.label
                                        selected: modelData.id === rowItem.modelData.selected
                                        focused: page.focused(rowItem.modelData.id, index)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------- hints ----------
    HintBar {
        anchors { left: side.right; leftMargin: 64; bottom: parent.bottom; bottomMargin: 40 }
        theme: page.theme
        hints: page.inRows ? [["A", qsTr("Choose"), "a"], ["B", qsTr("Back"), "b"], ["◀ ▶", qsTr("Change value"), "right"]]
                           : [["A", qsTr("Open"), "a"], ["B", qsTr("Back to the game"), "b"]]
    }
}
