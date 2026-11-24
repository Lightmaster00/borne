// A game's own settings, over its page: sections on the left (version and language, controller,
// emulator, picture, cheats, cover, storage), their rows in the middle, and on the right what the
// section changes (for the controller: what each of your buttons does in the game). Nothing
// closes by itself: a choice applies and stays on screen; B goes back one level (from the rows to
// the sections, from the sections to the game page).
// Gamepad: up/down in the focused column (group titles and notes skipped), right or A enters a
// section, left/right between a row's choices, A to choose, B to go back.
import QtQuick
import "Display.js" as Display
import "EmuOptions.js" as EmuOptions
import "Controls.js" as Controls
import "Devices.js" as Devices

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
    property string apiBase: ""      // the core's address, for the boxes' pictures
    property var controls: null      // GET /games/<id>/controls
    property bool advanced: false    // developer mode: each button, the emulator's options and the picture, for this game
    property var languages: []       // [{ code, version }] when the game exists in several
    property var versions: []        // the versions to choose from (raw API rows)
    property var versionLabel: function (v) { return String(v.rom_id) }
    property var versionDetail: function (v) { return "" }
    property string currentLang: ""
    property string emuLanguage: "auto"   // this game's own choice ("auto": the games' language)
    property string defaultLang: "en"     // the games' language (Settings → Language)
    // The languages offered for any game, after those its versions are known to have.
    readonly property var commonLangs: ["en", "fr", "de", "es", "it", "pt", "nl", "ja", "ko", "zh", "ru", "pl", "sv", "da", "no", "fi"]
    property var languageName: function (c) { return c }

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
        const dev = deviceOption
        const s = [
            { id: "language", name: qsTr("Version and language"), hint: [game && versions.length > 1 ? versionLabel(versions.find(v => v.rom_id === game.rom_id) || versions[0]) : "", currentLang ? languageName(currentLang) : ""].filter(x => x).join(" · ") || qsTr("One version") },
            { id: "controls", name: qsTr("Controller"), hint: dev ? Devices.label(dev.value, controls.console) : qsTr("Buttons, player 1") },
            { id: "emulator", name: qsTr("Emulator"), hint: emulator && emulator.own ? qsTr("Its own") : qsTr("As for its console") },
            { id: "cheats", name: qsTr("Cheats"), hint: cheats && cheats.cheats ? qsTr("%n on", "", cheats.cheats.filter(x => x.on).length) : "" }
        ]
        if (advanced) s.splice(3, 0, { id: "picture", name: qsTr("Picture"), hint: qsTr("Shape, sharpness, filters") })
        s.push({ id: "cover", name: qsTr("Cover and video"), hint: qsTr("ScreenScraper") })
        if (game && (game.local_state === "local" || game.linked || game.local_state === "missing"))
            s.push({ id: "storage", name: qsTr("Storage"), hint: game.local_state === "local" ? qsTr("On this device") : game.linked ? qsTr("Network mount") : "" })
        return s
    }
    readonly property string sectionId: sections[Math.min(section, sections.length - 1)].id
    // The controller the console sees, where it has a choice (controls.rs "device").
    readonly property var deviceOption: controls && controls.options ? controls.options.find(o => o.key === "device") || null : null
    // What the section on screen changes, on the right.
    readonly property var aside: {
        const id = sectionId
        if (id === "language") return { title: qsTr("Version and language"), text: qsTr("For this game only. Without a choice, Borne takes the version and the language set in Settings → Language.") }
        if (id === "controls") {
            const dev = deviceOption
            const fam = controls ? controls.family : "xbox"
            // The controller in hand by its name; none connected, no brand is guessed.
            const pads = controls && controls.pads ? controls.pads : []
            const famName = pads.length ? String(pads[0]) : qsTr("Your controller")
            const name = dev ? Devices.label(dev.value, controls.console) : (game ? game.platform_short || game.platform_name : "")
            // What gives each of the console's buttons now (the layout and the buttons chosen
            // included), as printed on your pad.
            const at = {}
            for (const b of controls ? controls.buttons || [] : []) at[b.button] = b.pad
            const logical = { south: "a", east: "b", west: "x", north: "y", lb: "l", rb: "r", lt: "l2", rt: "r2", start: "start", select: "select" }
            const sticks = { ls: qsTr("Left stick"), rs: qsTr("Right stick") }
            const label = place => sticks[place] || (at[logical[place] || place] ? Controls.padLabel(fam, at[logical[place] || place]) : "—")
            const map = dev ? Devices.mapping(dev.value, label)
                            : Controls.consoleButtons(controls ? controls.console : "").map(x => ({ from: x[1], to: at[x[0]] ? Controls.padLabel(fam, at[x[0]]) : "—" }))
            return { title: qsTr("%1 → %2").arg(famName).arg(name),
                     text: dev ? Devices.hint(dev.value) : qsTr("What each of your buttons does in the game."),
                     note: dev && dev.wanted && dev.value === dev.wanted ? Devices.wantedNote(dev.wanted, controls.console) : "",
                     left: name, right: famName, map: map }
        }
        if (id === "emulator") return { title: qsTr("Emulator"), text: qsTr("Borne sets the emulator up just before the game starts, then puts back the settings of the console's other games.") }
        if (id === "picture") return { title: qsTr("Picture"), text: qsTr("Without a choice of its own, the game takes the picture set for its console in Settings → Consoles.") }
        if (id === "cheats") return { title: qsTr("Cheats"), text: qsTr("The codes depend on the version chosen in Version and language. They apply the next time the game starts.") }
        if (id === "cover") {
            // Every edition's box as a picture, the one shown ringed: moving through the regions
            // shows the choice at once.
            const regions = images && images.regions ? images.regions : []
            const covers = game ? [{ id: "", label: qsTr("Automatic"), url: game.cover || "" }]
                                  .concat(regions.map(r => ({ id: r, label: regionName(r), url: apiBase + "/api/v1/games/" + game.rom_id + "/box-preview/" + r }))) : []
            return { title: qsTr("Cover and video"), text: qsTr("Images and video come from ScreenScraper; choose another edition's box or search for the right game."),
                     covers: covers, chosen: images && images.chosen ? images.chosen : "" }
        }
        return { title: qsTr("Storage"), text: qsTr("Saves stay on RomM whatever you remove here.") }
    }

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
            if (!advanced) {
                r.push(note("applied", qsTr("Applied the next time the game starts.")))
                return r
            }
            r.push(group(emuOptions && emuOptions.engine ? qsTr("%1 options for this game").arg(emuOptions.engine) : qsTr("Options for this game")))
            if (!opts.length) r.push(note("no-opts", qsTr("This emulator has no option of its own here: the picture settings apply.")))
            for (const o of opts)
                r.push({ id: "opt:" + o.key, kind: "chips", title: EmuOptions.title(o.key), desc: EmuOptions.desc(o.key) + (o.own ? "" : " · " + qsTr("as for all its games")),
                         selected: o.value, items: o.values.map(v => ({ id: v, label: EmuOptions.label(o.key, v) })) })
            if (opts.some(o => o.own)) r.push({ id: "opt-reset", kind: "buttons", title: qsTr("This game's options"), desc: qsTr("Back to the emulator's options for all its games (Settings → Consoles)"),
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
        if (id === "controls") {
            if (!controls) return [note("loading", qsTr("Loading…"))]
            const r = []
            const dev = deviceOption
            if (dev) {
                r.push({ id: "ctl:device", kind: "chips", title: qsTr("Controller the game sees"),
                         desc: dev.own ? qsTr("Chosen for this game") : dev.wanted && dev.value === dev.wanted ? qsTr("The one this game needs")
                                       : qsTr("As for %1 (Settings → Consoles)").arg(game ? game.platform_short || game.platform_name : ""),
                         selected: dev.value, items: dev.values.map(v => ({ id: v, label: Devices.label(v, controls.console) })) })
            }
            if (!controls.applies) {
                r.push(note("ctl-none", controls.program
                    ? qsTr("This game's emulator reads your controller by itself, buttons where the console has them.")
                    : qsTr("No emulator runs this game yet.")))
                return r
            }
            for (const x of Controls.rows(controls, advanced, game ? game.platform_name : "")) r.push(x)
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
        if (id === "language") {
            const r = []
            if (versions.length > 1)
                r.push({ id: "version", kind: "chips", title: qsTr("Version"), desc: qsTr("The one launched; the others stay on the server"),
                         selected: game ? game.rom_id : -1, items: versions.map(v => ({ id: v.rom_id, label: versionLabel(v) + (versionDetail(v) ? " · " + versionDetail(v) : "") })) })
            // Always offered, one version or several: many games hold more languages than their
            // name lists, and the language is set in the emulator. Those the versions are known to
            // have come first.
            const known = languages.map(l => l.code)
            const codes = known.concat(commonLangs.filter(c => known.indexOf(c) < 0))
            r.push({ id: "lang", kind: "chips", title: qsTr("Game language"),
                     desc: known.length ? qsTr("Set in the emulator; may start the version in this language. Known in this game: %1").arg(known.map(c => languageName(c)).join(", "))
                                        : qsTr("Set in the emulator, if the game has it"),
                     selected: emuLanguage && emuLanguage !== "auto" ? emuLanguage : "auto",
                     items: [{ id: "auto", label: qsTr("Default (%1)").arg(languageName(defaultLang)) }].concat(codes.map(c => ({ id: c, label: languageName(c) }))) })
            r.push(note("applied", qsTr("Applied the next time the game starts.")))
            return r
        }
        if (id === "cover") {
            const r = [group(qsTr("Cover"))]
            const regions = images && images.regions ? images.regions : []
            if (regions.length > 1)
                r.push({ id: "region", kind: "chips", title: qsTr("Box region"), desc: qsTr("Which edition's box is shown"),
                         selected: images.chosen || "", items: [{ id: "", label: qsTr("Automatic") }].concat(regions.map(x => ({ id: x, label: regionName(x) }))) })
            r.push({ id: "ss-search", kind: "buttons", title: qsTr("Not the right game?"), desc: qsTr("Search ScreenScraper by name and choose the right one"),
                     items: [{ id: "ss-search", label: qsTr("Search") }] })
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
        else if (r.id.startsWith("ctl:")) page.action("controls", { key: r.id.substring(4), value: item.id })
        else if (r.id.startsWith("ctl-btn:")) page.action("controls-capture", { button: r.id.substring(8), name: r.title })
        else if (r.id === "ctl-reset-buttons") page.action("controls", { key: "map.*", value: "default" })
        else if (r.id === "ctl-reset") page.action("controls", { key: "*", value: "default" })
        else if (r.id.startsWith("cheat:")) page.action("cheat", { index: Number(r.id.substring(6)), on: item.id === "on" })
        else if (r.id === "lang") page.action("lang", languages.find(l => l.code === item.id) || { code: item.id, version: game ? game.rom_id : -1 })
        else if (r.id === "version") page.action("version", item.id)
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
        // A choice: left and right (and A) change it at once.
        if (r.kind === "chips" && (a === "left" || a === "right" || a === "a")) { cycle(r, a === "left" ? -1 : 1); return }
        if (a === "up") row = step(row, -1)
        else if (a === "down") row = step(row, 1)
        else if (a === "left") { if (colOf(r.id) === 0) inRows = false; else setCol(r.id, colOf(r.id) - 1) }
        else if (a === "right") setCol(r.id, Math.min(n - 1, colOf(r.id) + 1))
        else if (a === "a") activate(r, colOf(r.id))
    }
    function focused(id, i) { return !!(inRows && rows[row] && rows[row].id === id && colOf(id) === i) }
    // The next (d = 1) or previous (-1) choice of a line that can be chosen, applied.
    function cycle(r, d) {
        const n = r.items.length
        if (n < 2) return
        let i = Math.max(0, r.items.findIndex(x => String(x.id) === String(r.selected)))
        for (let k = 0; k < n; k++) {
            i = (i + d + n) % n
            if (!r.items[i].disabled) break
        }
        setCol(r.id, i)
        activate(r, i)
    }

    // ---------- sections ----------
    Rectangle {
        id: side
        width: 420
        height: parent.height
        color: "transparent"
        Column {
            x: 56; y: 44
            width: parent.width - 88
            spacing: 4
            Text { text: qsTr("Game settings"); color: theme.fg; font { family: theme.displayFont; pixelSize: 40; weight: Font.ExtraBold; letterSpacing: -1 } }
            Text { width: parent.width; text: page.game ? page.game.name : ""; elide: Text.ElideRight; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 18; weight: Font.Medium } }
        }
        Column {
            x: 40; y: 150
            width: parent.width - 72
            spacing: 6
            Repeater {
                model: page.sections
                Rectangle {
                    id: sec
                    required property var modelData
                    required property int index
                    readonly property bool current: page.section === index
                    readonly property bool focusedHere: current && !page.inRows
                    width: parent.width; height: current && sec.modelData.hint ? 70 : 48
                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    radius: current ? 22 : 16
                    color: focusedHere ? theme.fg : current ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                    Behavior on color { ColorAnimation { duration: theme.focusMs } }
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.name
                    clip: true
                    Column {
                        x: 22; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 44
                        spacing: 2
                        Text { width: parent.width; elide: Text.ElideRight; text: sec.modelData.name; color: sec.focusedHere ? theme.bg : sec.current ? theme.fg : theme.fgMuted; font { family: theme.fontFamily; pixelSize: 21; weight: sec.current ? Font.ExtraBold : Font.DemiBold } }
                        Text { visible: sec.current && text !== ""; width: parent.width; elide: Text.ElideRight; text: sec.modelData.hint; color: sec.focusedHere ? Qt.rgba(0, 0, 0, 0.6) : theme.fgFaint; font { family: theme.fontFamily; pixelSize: 16; weight: Font.Medium } }
                    }
                }
            }
        }
    }

    // ---------- rows ----------
    Flickable {
        id: rowsView
        x: side.width + 40; y: 52
        width: Math.min(1200, parent.width - x - asidePanel.width - 96)
        height: parent.height - y - 24
        contentHeight: rowsCol.height + 50
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
            x: 14; y: 10
            width: parent.width - 28
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
                    Component.onCompleted: if (current) Qt.callLater(function () { if (rowItem && rowItem.current && rowItem.parent && rowsView) rowsView.ensure(rowItem) })
                    width: parent.width
                    height: kind === "header" ? 58 : kind === "note" ? noteText.height + 8 : line.implicitHeight

                    Item {
                        visible: rowItem.kind === "header"
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 6; leftMargin: 8 }
                        height: groupTitle.height
                        Text {
                            id: groupTitle
                            text: (rowItem.modelData.title || "").toUpperCase()
                            color: theme.fgFaint
                            font { family: theme.fontFamily; pixelSize: 17; weight: Font.Bold; letterSpacing: 1.6 }
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
                    SettingRow {
                        id: line
                        visible: rowItem.kind === "chips" || rowItem.kind === "buttons"
                        width: parent.width
                        height: rowItem.height
                        theme: page.theme
                        kind: rowItem.kind
                        title: rowItem.modelData.title || ""
                        desc: rowItem.modelData.desc || ""
                        items: rowItem.modelData.items || []
                        selected: rowItem.modelData.selected !== undefined && rowItem.modelData.selected !== null ? String(rowItem.modelData.selected) : ""
                        current: rowItem.current
                        focusedCol: page.colOf(rowItem.modelData.id)
                    }
                }
            }
        }
    }

    // ---------- what the section changes ----------
    Column {
        id: asidePanel
        anchors { right: parent.right; rightMargin: 72; top: parent.top; topMargin: 72 }
        width: parent.width > 1700 ? 460 : 300
        spacing: 16
        Text { width: parent.width; wrapMode: Text.WordWrap; text: page.aside.title; color: theme.fg; font { family: theme.displayFont; pixelSize: 26; weight: Font.ExtraBold } }
        Text { width: parent.width; wrapMode: Text.WordWrap; text: page.aside.text; lineHeight: 1.3; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold } }
        Rectangle {
            visible: !!page.aside.note
            width: parent.width; height: noteBox.height + 28; radius: 18
            color: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.22)
            Text { id: noteBox; x: 18; y: 14; width: parent.width - 36; wrapMode: Text.WordWrap; text: page.aside.note || ""; color: theme.fg; font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold } }
        }
        // The boxes of every edition (Cover section).
        Flow {
            id: coverFlow
            visible: !!page.aside.covers && page.aside.covers.length > 0
            width: parent.width
            spacing: 14
            readonly property real cw: Math.floor((width - 2 * spacing) / 3)
            Repeater {
                model: page.aside.covers || []
                Column {
                    required property var modelData
                    readonly property bool on: modelData.id === page.aside.chosen
                    width: coverFlow.cw
                    spacing: 8
                    Rectangle {
                        width: parent.width; height: Math.round(parent.width * 1.38); radius: 10
                        color: Qt.rgba(1, 1, 1, 0.06)
                        border { width: parent.on ? 3 : 0; color: theme.fg }
                        Image {
                            id: boxPic
                            anchors { fill: parent; margins: parent.parent.on ? 6 : 0 }
                            source: modelData.url
                            sourceSize.height: theme ? theme.px(200, 600) : 400
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            opacity: status === Image.Ready ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 250 } }
                        }
                        Spinner { anchors.centerIn: parent; size: 28; visible: boxPic.status === Image.Loading }
                    }
                    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; text: modelData.label
                           color: parent.on ? theme.fg : theme.fgMuted; font { family: theme.fontFamily; pixelSize: 14; weight: parent.on ? Font.ExtraBold : Font.DemiBold } }
                }
            }
        }
        Rectangle {
            visible: !!page.aside.map && page.aside.map.length > 0
            width: parent.width; height: mapCol.height + 24; radius: 22
            color: Qt.rgba(1, 1, 1, 0.05)
            Column {
                id: mapCol
                x: 18; y: 12
                width: parent.width - 36
                Item {
                    width: parent.width; height: 32
                    Text { anchors.verticalCenter: parent.verticalCenter; text: page.aside.left || ""; color: theme.fgFaint; font { family: theme.fontFamily; pixelSize: 13; weight: Font.ExtraBold } }
                    Text { anchors { right: parent.right; verticalCenter: parent.verticalCenter } text: page.aside.right || ""; color: theme.fgFaint; font { family: theme.fontFamily; pixelSize: 13; weight: Font.ExtraBold } }
                }
                Repeater {
                    model: page.aside.map || []
                    Item {
                        required property var modelData
                        width: mapCol.width; height: 42
                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.from; color: theme.fg; font { family: theme.fontFamily; pixelSize: 16; weight: Font.ExtraBold } }
                        KeyCap { anchors { right: parent.right; verticalCenter: parent.verticalCenter } theme: page.theme; size: 30; text: modelData.to }
                    }
                }
            }
        }
    }

    // ---------- hints ----------
    readonly property var hints: inRows ? [["A", qsTr("Choose"), "a"], ["◀ ▶", qsTr("Change value"), "right"], ["B", qsTr("Back"), "b"]]
                                        : [["A", qsTr("Open"), "a"], ["B", qsTr("Back to the game"), "b"]]
}
