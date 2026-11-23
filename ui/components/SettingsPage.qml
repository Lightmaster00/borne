// Settings: sections on the left, their rows on the right, gathered under group titles.
// Overview first (what needs attention, each a step away), then one page per console with
// everything about it (emulator, its options for all its games, picture, system files), then the
// rest by topic. A game can still have its own settings, from its page.
// Gamepad: up/down moves in the focused column (group titles are skipped), right enters a section,
// left goes back to the sections, left/right inside a row of choices, A to choose or open, B back.
import QtQuick
import "CoreText.js" as CoreText
import "Display.js" as Display
import "EmuOptions.js" as EmuOptions
import "Controls.js" as Controls
import "ConsoleNeeds.js" as Needs

Item {
    id: page
    property QtObject theme
    property var settings: null          // GET /api/v1/settings
    property var status: null            // GET /api/v1/status
    property QtObject prefs: null        // the interface's own preferences (Main.qml, prefs)
    property string version: ""
    property var reportPaths: []

    signal action(string id, var payload)

    property int section: 0
    property bool inRows: false
    property int row: 0
    property var cols: ({})

    // A console's own page (Consoles section): its slug, and what is fetched for it.
    property string consoleSlug: ""
    property var consoleDisplay: null    // GET /api/v1/display?console=…
    property var consoleOpts: null       // GET /api/v1/emulators/<program>/options
    property var controlsAll: null       // GET /api/v1/controls
    property var consoleControls: null   // GET /api/v1/consoles/<slug>/controls (the console open)
    property var steam: null             // GET /api/v1/steam
    property int consoleRow: 0           // the list's row to come back to

    readonly property var upd: settings && settings.update ? settings.update : null
    readonly property var updState: upd && upd.update ? upd.update : null
    readonly property bool streamAvailable: settings ? settings.stream.available : false
    readonly property string installMode: settings ? settings.install_mode : "download"

    // The system files' names (Borne's list, in English) in the interface's language.
    function fileName(n) {
        const t = {
            "DS ARM7 BIOS": qsTr("DS ARM7 BIOS"), "DS ARM9 BIOS": qsTr("DS ARM9 BIOS"), "DS firmware": qsTr("DS firmware"),
            "Game Boy Advance BIOS": qsTr("Game Boy Advance BIOS"), "Mega-CD / Sega CD BIOS": qsTr("Mega-CD / Sega CD BIOS"),
            "PS3 firmware (PS3UPDAT.PUP)": qsTr("PS3 firmware (PS3UPDAT.PUP)"), "PS4 system modules (.sprx)": qsTr("PS4 system modules (.sprx)"),
            "PlayStation 2 BIOS": qsTr("PlayStation 2 BIOS"), "PlayStation BIOS": qsTr("PlayStation BIOS"), "Saturn BIOS": qsTr("Saturn BIOS"),
            "Switch firmware (archive of .nca files)": qsTr("Switch firmware (archive of .nca files)"),
            "Switch keys (prod.keys)": qsTr("Switch keys (prod.keys)"), "Switch title keys (title.keys)": qsTr("Switch title keys (title.keys)")
        }
        return t[n] || n
    }
    function fmtSize(b) {
        return b >= 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
             : b >= 1048576 ? qsTr("%1 MB").arg(Math.round(b / 1048576)) : qsTr("%1 KB").arg(Math.max(1, Math.round(b / 1024)))
    }
    function onOff(v) { return [{ id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }] }
    function group(t) { return { id: "group:" + t, kind: "header", title: t, items: [] } }
    // A row setting one of the interface's preferences: key, choices [[value, label]…].
    function pref(key, title, desc, choices) {
        const v = prefs ? prefs[key] : undefined
        return { id: "pref:" + key, kind: "chips", title: title, desc: desc, selected: String(v),
                 items: choices.map(c => ({ id: String(c[0]), label: c[1], value: c[0] })) }
    }
    function secs(n) { return n >= 60 ? qsTr("%1 min").arg(n / 60) : qsTr("%1 s").arg(n) }
    // The library: the consoles' order, the clock, the videos.
    function libraryRows() {
        const on = [[true, qsTr("On")], [false, qsTr("Off")]]
        const rows = [
            group(qsTr("Home")),
            pref("consoleOrder", qsTr("Order of the consoles"), qsTr("In the collections and the Store (also with Y); your own order: LT and RT on a console of the Store"),
                 [["played", qsTr("Most played")], ["count", qsTr("Most games")], ["year", qsTr("Release date")], ["name", qsTr("Name")], ["maker", qsTr("Maker, then release")], ["maker-name", qsTr("Maker, then name")], ["custom", qsTr("Your order")]]),
            pref("background", qsTr("Background"), qsTr("Behind the home and the game pages"),
                 [["lights", qsTr("Lights in the console's colour")], ["art", qsTr("The game's art")]]),
            pref("showClock", qsTr("Clock"), qsTr("The time at the top of the library"), [[true, qsTr("Shown")], [false, qsTr("Hidden")]]),
            group(qsTr("Videos")),
            pref("bgVideo", qsTr("Video behind the library"), qsTr("The selected game's video plays by itself, muted, behind the covers"), on),
            pref("attractDelay", qsTr("Video in full screen"), qsTr("Without a press for this long, the page fades out and leaves the game's video, with its sound on a game's page"),
                 [[5, secs(5)], [15, secs(15)], [30, secs(30)], [60, secs(60)], [0, qsTr("Never")]]),
            pref("attractRest", qsTr("Full-screen video length"), qsTr("Then the games come back, the video going on dimmed behind them"),
                 [[60, secs(60)], [180, secs(180)], [600, secs(600)], [0, qsTr("No limit")]]),
            pref("pageVideo", qsTr("Videos on the game page"), qsTr("A game's trailer starts on its page after a moment"), on)
        ]
        // The full-screen video's length only when it goes full screen.
        return rows.filter(r => !(prefs && prefs.attractDelay === 0 && r.id === "pref:attractRest"))
    }
    function languageRows() {
        return [
            pref("language", qsTr("Language"), qsTr("Borne's menus; also the version and the language a game starts in, when it has several"),
                 [["auto", qsTr("As the system")], ["fr", "Français"], ["en", "English"]]),
            note("lang-game", qsTr("One game in another version or language: open its page, then Y (Game settings) → Version and language."))
        ]
    }
    function screenRows() {
        const on = [[true, qsTr("On")], [false, qsTr("Off")]]
        const rows = [
            group(qsTr("Screen")),
            pref("uiScale", qsTr("Interface size"), qsTr("Larger text and covers, for a screen seen from afar"),
                 [[100, "100 %"], [115, "115 %"], [130, "130 %"], [145, "145 %"]]),
            pref("motion", qsTr("Animations"), qsTr("Reduced: shorter movements and fades"), [["normal", qsTr("Normal")], ["reduced", qsTr("Reduced")]]),
            pref("prompts", qsTr("Buttons shown"), qsTr("The hints at the bottom show the gamepad's buttons or the keyboard's keys"),
                 [["auto", qsTr("Last used")], ["pad", qsTr("Gamepad")], ["keyboard", qsTr("Keyboard")]]),
            group(qsTr("Sound")),
            pref("sounds", qsTr("Interface sounds"), qsTr("Short, quiet sounds when moving and choosing"), on),
            pref("soundVolume", qsTr("Volume"), qsTr("Of the interface sounds only, not of the games"),
                 [["low", qsTr("Low")], ["medium", qsTr("Medium")], ["high", qsTr("High")]])
        ]
        return rows.filter(r => !(prefs && !prefs.sounds && r.id === "pref:soundVolume"))
    }

    readonly property string updateText: {
        if (!upd) return ""
        const st = updState ? updState.state : "idle"
        // The core says why in English; the known reasons are said in the interface's language.
        const reasons = {
            "this copy was built locally; updates come with the builds published on GitHub": qsTr("this copy was built locally; updates come with the builds published on GitHub"),
            "macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again": qsTr("macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again"),
            "installed with Flatpak: update it with Flatpak": qsTr("installed with Flatpak: update it with Flatpak"),
            "installation folder not recognized": qsTr("installation folder not recognized")
        }
        const why = upd.unsupported ? (reasons[upd.unsupported] || upd.unsupported.replace(/ is not writable$/, qsTr(" is not writable"))) : ""
        const manual = upd.unsupported ? qsTr("Borne cannot install it itself here (%1): download it from GitHub.").arg(why) : ""
        if (st === "available") {
            const v = updState.available
            const newer = v.build > upd.current.build
            const what = !updState.size ? "" : updState.parts && updState.parts.length
                ? " " + qsTr("Only what changed is downloaded: %1.").arg(page.fmtSize(updState.size))
                : " " + qsTr("Download: %1.").arg(page.fmtSize(updState.size))
            return (newer ? qsTr("Version %1 is available.").arg(v.version) : qsTr("Latest build of this channel: %1 (the one installed).").arg(v.version)) + what + (manual ? " " + manual : "")
        }
        if (st === "downloading") return qsTr("Downloading the update… %1 of %2").arg(page.fmtSize(updState.received)).arg(page.fmtSize(updState.total))
        if (st === "ready") return qsTr("Downloaded and verified. Borne restarts to install it.")
        if (st === "checking") return qsTr("Checking…")
        if (st === "uptodate") return qsTr("Borne is up to date: version %1 is the latest of this channel.").arg(upd.current.version)
                                      + (updState.checked_at ? " " + qsTr("Checked at %1.").arg(new Date(updState.checked_at * 1000).toLocaleTimeString(Qt.locale(), "HH:mm")) : "")
        if (st === "error") return qsTr("Update failed: %1").arg(CoreText.tr(updState.error || ""))
        return manual || qsTr("Not checked yet: Borne looks by itself shortly after it starts, or press Check now.")
    }
    readonly property var ss: settings && settings.screenscraper ? settings.screenscraper : null
    readonly property var emus: settings && settings.emulators ? settings.emulators : null
    function emuTaskText(id) {
        const t = emus ? emus.task : null
        if (!t || t.id !== id) return ""
        if (t.running) {
            if (t.step === "download" && t.total > 0) return qsTr("Downloading… %1%").arg(Math.round(100 * t.received / t.total))
            if (t.step === "core") return qsTr("Adding the %1 core…").arg(t.core)
            if (t.step === "unpack") return qsTr("Installing…")
            return qsTr("Preparing…")
        }
        if (t.error) return qsTr("Installation failed: %1").arg(CoreText.tr(t.error))
        const d = t.done
        if (d && d.what === "uptodate") return qsTr("Already up to date: version %1 is the latest").arg(d.version)
        if (d && d.what === "updated") return d.version === "flatpak" ? qsTr("Updated with Flathub") : qsTr("Updated to version %1").arg(d.version)
        if (d && d.what === "installed") return d.version === "flatpak" ? qsTr("Installed from Flathub") : qsTr("Installed: version %1").arg(d.version)
        return ""
    }
    function programText(p) {
        const t = emuTaskText(p.id)
        if (t) return t
        if (p.managed) return p.version === "flatpak" ? qsTr("Installed by Borne (Flathub), kept up to date") : qsTr("Version %1, installed by Borne and kept up to date").arg(p.version)
        if (p.found) return qsTr("Found: %1").arg(p.found)
        if (p.user_provided) return qsTr("Not found: choose its program (Borne does not download it)")
        return qsTr("Downloaded by Borne when a console needs it")
    }
    function programButtons(p) {
        const busy = !!(emus && emus.task && emus.task.running)
        const b = []
        if (p.installable) b.push({ id: "emu-install:" + p.id, label: p.managed ? qsTr("Update now") : qsTr("Install"), primary: !p.found, disabled: busy })
        if (p.user_provided || p.user_path) b.push({ id: "emu-path:" + p.id, label: p.user_path ? qsTr("Change program") : qsTr("Choose program"), primary: !p.found && !p.installable })
        if (p.user_path) b.push({ id: "emu-forget:" + p.id, label: qsTr("Forget this program") })
        return b
    }
    // ---------- consoles ----------
    readonly property var consoles: emus ? emus.consoles : []
    function consoleOf(slug) { return consoles.find(c => c.slug === slug) || null }
    function chosenOf(c) { return c ? (c.choices.find(x => x.id === c.chosen) || null) : null }
    function programOf(id) { return emus ? (emus.programs.find(p => p.id === id) || null) : null }
    function sysOf(slug) { return sysFiles ? (sysFiles.consoles.find(c => c.slug === slug) || null) : null }
    // What a console still needs: [{text, tone}] ("bad": its games cannot start; "info": done by itself).
    function consoleIssues(c) {
        const out = []
        if (!c.choices.length) { out.push({ text: c.known ? qsTr("No emulator can run these games yet") : qsTr("Not supported by Borne yet"), tone: "info" }); return out }
        if (!c.available) out.push({ text: qsTr("No build of its emulator for this computer"), tone: "bad" })
        const ch = chosenOf(c), p = ch ? programOf(ch.program) : null
        if (ch && !ch.ready && p) {
            if (p.installable && emus.auto_update) out.push({ text: qsTr("%1 is installed by Borne at the first game").arg(p.name), tone: "info" })
            else if (p.installable) out.push({ text: qsTr("%1 is not installed").arg(p.name), tone: "bad" })
            else out.push({ text: qsTr("%1 not found: choose its program").arg(p.name), tone: "bad" })
        }
        const sf = sysOf(c.slug)
        if (sf) sf.items.filter(i => i.required && !i.valid).forEach(i => out.push({ text: qsTr("Missing: %1").arg(fileName(i.name)), tone: "bad" }))
        return out
    }
    function consoleLine(c) {
        const ch = chosenOf(c), p = ch ? programOf(ch.program) : null
        const parts = []
        if (ch) parts.push(ch.name + (p && p.managed && p.version && p.version !== "flatpak" ? " " + p.version : ""))
        const sf = sysOf(c.slug)
        if (sf && sf.items.length) {
            const req = sf.items.filter(i => i.required)
            parts.push(req.every(i => i.valid) ? qsTr("system files ready") : qsTr("%n system file(s) missing", "", req.filter(i => !i.valid).length))
        }
        return parts.join(" · ")
    }
    readonly property var attention: {
        const out = []
        consoles.forEach(c => consoleIssues(c).filter(i => i.tone === "bad").forEach(i =>
            out.push({ id: "go:console:" + c.slug, title: c.name, desc: i.text, badge: qsTr("To fix"), tone: "bad" })))
        const t = emus ? emus.task : null
        if (t && !t.running && t.error) out.push({ id: "emu-dismiss", title: qsTr("Installing %1 failed").arg(t.name || t.id), desc: CoreText.tr(t.error) + " · " + qsTr("Press to put this notice away"), badge: qsTr("Failed"), tone: "bad" })
        if (status && status.server_url && !status.online) out.push({ id: "go:library", title: qsTr("RomM"), desc: qsTr("The server cannot be reached: games already here still play"), badge: qsTr("Offline"), tone: "bad" })
        if (status && status.sync && status.sync.error) out.push({ id: "go:library", title: qsTr("Library"), desc: qsTr("Last sync failed: %1").arg(CoreText.tr(status.sync.error)), badge: qsTr("To fix"), tone: "bad" })
        if (updState && (updState.state === "available" || updState.state === "ready") && updState.available && upd && updState.available.build > upd.current.build)
            out.push({ id: "go:updates", title: qsTr("Borne %1").arg(updState.available.version), desc: updState.state === "ready" ? qsTr("Downloaded: restart to install it") : qsTr("A new version is available"), badge: qsTr("New"), tone: "ok" })
        if (steam && steam.available && !steam.added)
            out.push({ id: "go:help", title: qsTr("Steam"), desc: qsTr("Add Borne to Steam, to start it from the gamepad interface"), badge: qsTr("Suggested"), tone: "info" })
        if (ss && ss.developer_access && !ss.configured) out.push({ id: "go:library", title: qsTr("Game images"), desc: qsTr("Connect a ScreenScraper account for case scans, cartridges and logos"), badge: qsTr("Suggested"), tone: "info" })
        return out
    }
    readonly property int problems: attention.filter(a => a.tone === "bad").length
    function link(id, title, desc, badge, tone) { return { id: id, kind: "link", title: title, desc: desc, badge: badge || "", tone: tone || "", items: [{ id: id }] } }
    function note(id, text) { return { id: id, kind: "note", title: "", desc: text, items: [] } }

    function overviewRows() {
        const rows = []
        if (attention.length) {
            rows.push(group(problems ? qsTr("Needs your attention") : qsTr("Suggestions")))
            attention.forEach(a => rows.push(link(a.id, a.title, a.desc, a.badge, a.tone)))
        } else rows.push(note("all-good", qsTr("Everything is ready: every console of the library has its emulator and the files it needs.")))
        rows.push(group(qsTr("At a glance")))
        const ready = consoles.filter(c => c.choices.length && !consoleIssues(c).some(i => i.tone === "bad")).length
        rows.push(link("go:consoles", qsTr("Consoles"), consoles.length ? qsTr("%1 of %2 ready to play").arg(ready).arg(consoles.length) : qsTr("None yet: sync the library")))
        rows.push(link("go:games", qsTr("Games"), (installMode === "stream" ? qsTr("Played from the network") : qsTr("Downloaded before playing"))
                       + " · " + (settings && settings.save_sync === false ? qsTr("saves stay on this device") : qsTr("saves on RomM"))))
        rows.push(link("go:library", qsTr("RomM"), status && status.server_url ? status.server_url + (status.active_profile ? " · " + status.active_profile.name : "") : qsTr("not configured")))
        rows.push(link("go:updates", qsTr("Updates"), qsTr("Version %1").arg(page.version) + " · " + (upd && upd.channel === "dev" ? qsTr("Development") : qsTr("Stable"))))
        return rows
    }
    function consolesRows() {
        const pick = { id: "pick-consoles", kind: "buttons", title: qsTr("Consoles shown in Borne"),
                       desc: qsTr("Add or leave out consoles of your RomM library; what their games need of this computer is said for each"),
                       items: [{ id: "pick-consoles", label: qsTr("Choose"), primary: true }] }
        if (!consoles.length) return [pick, note("no-consoles", qsTr("The consoles of your library appear here after a sync."))]
        const ask = { id: "needs-ask", kind: "buttons", title: qsTr("Questions before playing"),
                      desc: qsTr("Before a game made for an accessory Borne does not find (a guitar, a Balance Board, PlayStation VR…), or a console's first game when this computer lacks what it needs, Borne asks once. Never a lock: Play anyway is remembered."),
                      items: [{ id: "needs-forget", label: qsTr("Ask again") }] }
        const rows = [pick, ask, group(qsTr("In your library"))]
        consoles.forEach(c => {
            const issues = consoleIssues(c)
            const bad = issues.find(i => i.tone === "bad")
            rows.push(link("console:" + c.slug, c.name, bad ? bad.text : (consoleLine(c) || (issues[0] ? issues[0].text : "")),
                           bad ? qsTr("To fix") : c.choices.length ? qsTr("Ready") : "", bad ? "bad" : c.choices.length ? "ok" : ""))
        })
        return rows
    }
    // One console: its emulator, that emulator's options for all its games, its picture, its files.
    function consoleRows(slug) {
        const c = consoleOf(slug)
        if (!c) return [note("gone", qsTr("This console is no longer in the library."))]
        const rows = []
        consoleIssues(c).forEach((i, n) => rows.push(note("issue:" + n, (i.tone === "bad" ? "⚠ " : "") + i.text)))
        // What its games need that this computer lacks.
        Needs.warnings(c.warnings).forEach((t, n) => rows.push(note("need:" + n, "⚠ " + t)))
        rows.push(group(qsTr("Emulator")))
        // A choice only when there is one to make.
        if (c.choices.length > 1)
            rows.push({ id: "emu-choice:" + c.slug, kind: "chips", title: qsTr("Plays these games"),
                        desc: c.slug === "switch" ? qsTr("Your favourite. A game that does not run on it starts on the other one by itself")
                                                  : qsTr("A game can use another one, from its page"),
                        selected: c.chosen, items: c.choices.map(x => ({ id: x.id, label: x.name })) })
        const ch = chosenOf(c), p = ch ? programOf(ch.program) : null
        if (p) rows.push({ id: "prog:" + p.id, kind: "buttons", title: c.choices.length > 1 ? p.name : qsTr("%1 plays these games").arg(ch.name),
                           desc: programText(p), items: programButtons(p) })
        // The emulator's own options: for every game it runs (other consoles included).
        const opts = consoleOpts && p && consoleOpts.program === p.id ? consoleOpts.options : []
        if (opts.length) {
            const shared = consoles.filter(x => x.slug !== c.slug && chosenOf(x) && chosenOf(x).program === p.id).map(x => x.name)
            rows.push(group(qsTr("%1 options").arg(p.name)))
            if (shared.length) rows.push(note("opts-shared", qsTr("Also used for: %1. A game can have its own, from its page.").arg(shared.join(", "))))
            opts.forEach(o => rows.push({ id: "opt:" + p.id + ":" + o.key, kind: "chips", title: EmuOptions.title(o.key),
                desc: EmuOptions.desc(o.key) + (o.own ? "" : " · " + qsTr("Borne's choice")), selected: o.value,
                items: o.values.map(v => ({ id: v, label: EmuOptions.label(o.key, v) })) }))
            if (opts.some(o => o.own)) rows.push({ id: "opt-reset:" + p.id, kind: "buttons", title: qsTr("Back to Borne's choices"), desc: "",
                                                   items: [{ id: "opt-reset:" + p.id, label: qsTr("Reset") }] })
        }
        // Picture: this console's own values over those for all games.
        if (consoleDisplay) {
            rows.push(group(qsTr("Picture")))
            Display.KEYS.forEach(k => {
                const own = consoleDisplay.own ? consoleDisplay.own[k] : undefined
                const all = consoleDisplay.global ? consoleDisplay.global[k] : undefined
                const items = Display.values(k).map(v => ({ id: v, label: Display.label(k, v) }))
                items.unshift({ id: "default", label: qsTr("As for all games") + (all !== undefined ? " (" + Display.label(k, all) + ")" : "") })
                rows.push({ id: "cdisp:" + k, kind: "chips", title: Display.title(k), desc: Display.desc(k), selected: own !== undefined ? own : "default", items: items })
            })
        }
        // Controls: this console's own over those for every game.
        if (consoleControls && consoleControls.console === c.slug) {
            rows.push(group(qsTr("Controls")))
            Controls.rows(consoleControls, prefs && prefs.controlsAdvanced, qsTr("every game")).forEach(r => rows.push(r))
        }
        const sf = sysOf(c.slug)
        if (sf && sf.items.length) {
            rows.push(group(qsTr("System files")))
            sysFileRowsOf(sf).forEach(r => rows.push(r))
        }
        return rows
    }
    function programsRows() {
        if (!emus) return []
        const rows = [{ id: "emu-auto", kind: "chips", title: qsTr("Install and update by themselves"),
                        desc: qsTr("Borne installs the emulators your consoles need and their new versions, never during a game"),
                        selected: emus.auto_update ? "on" : "off", items: onOff() }]
        const used = {}
        consoles.forEach(c => { const ch = chosenOf(c); if (ch) used[ch.program] = (used[ch.program] || []).concat([c.name]) })
        const inUse = emus.programs.filter(p => used[p.id])
        const others = emus.programs.filter(p => !used[p.id] && (p.managed || p.user_path || p.found))
        if (inUse.length) rows.push(group(qsTr("Used by your consoles")))
        inUse.forEach(p => rows.push({ id: "prog:" + p.id, kind: "buttons", title: p.name,
            desc: programText(p) + "\n" + qsTr("For: %1").arg(used[p.id].join(", ")), items: programButtons(p) }))
        if (others.length) rows.push(group(qsTr("Also on this computer")))
        others.forEach(p => rows.push({ id: "prog:" + p.id, kind: "buttons", title: p.name, desc: programText(p), items: programButtons(p) }))
        return rows
    }
    function controlsRows() {
        if (!controlsAll) return [note("loading", qsTr("Loading…"))]
        const pads = controlsAll.pads || []
        const rows = [group(qsTr("Connected")),
                      note("pads", pads.length ? pads.map((n, i) => qsTr("Player %1: %2").arg(i + 1).arg(n)).join("\n")
                                               : qsTr("No controller connected: the keyboard plays.")),
                      pref("controlsAdvanced", qsTr("Display"), qsTr("Simple: the layout and the stick. Advanced: also each button, set by pressing it on your controller"),
                           [[false, qsTr("Simple")], [true, qsTr("Advanced")]]),
                      group(qsTr("For every game"))]
        Controls.rows(controlsAll, prefs && prefs.controlsAdvanced, qsTr("every game")).forEach(r => rows.push(r))
        // The consoles whose games can be shown another controller (Joy-Con, Wii Remote…).
        const kinds = { switch: qsTr("Pro Controller, Joy-Con pair or handheld"), wii: qsTr("Wii Remote with Nunchuk, alone, sideways, or Classic Controller"), wiiu: qsTr("Wii U GamePad or Pro Controller") }
        const own = consoles.filter(c => kinds[c.slug])
        if (own.length) {
            rows.push(group(qsTr("Controller each console's games see")))
            own.forEach(c => rows.push(link("go:console:" + c.slug, c.name, kinds[c.slug])))
        }
        rows.push(note("ctl-note", qsTr("Each console can have its own (Settings → Consoles → the console), and each game its own (its page, Y). Applied the next time a game starts.")))
        return rows
    }

    readonly property bool ssRunning: !!(ss && ss.state && ss.state.running)
    function ssAccountText() {
        if (ss && !ss.developer_access)
            return qsTr("This build of Borne has no ScreenScraper developer access: the official builds include it. Images still come from RomM.")
        if (!ss || !ss.configured)
            return qsTr("Borne asks ScreenScraper itself for each game's case (front, spine, back), cartridge, logo and artwork, without going through RomM. Connect your ScreenScraper account (free on screenscraper.fr).")
        const st = ss.state || {}
        let t = qsTr("Connected as %1").arg(ss.user)
        if (st.max_requests) t += " · " + qsTr("%1 / %2 requests today").arg(st.requests_today || 0).arg(st.max_requests)
        return t
    }
    function ssFetchText() {
        const st = ss && ss.state ? ss.state : null
        if (!st) return ""
        if (st.running && st.paused) return qsTr("Paused: %1 / %2 games, %3 found").arg(st.done).arg(st.total).arg(st.found)
        if (st.running) return qsTr("Asking ScreenScraper… %1 / %2 games, %3 found").arg(st.done).arg(st.total).arg(st.found)
               + (st.threads > 1 ? " · " + qsTr("%1 at a time").arg(st.threads) : "")
        if (st.error) return qsTr("Stopped: %1").arg(CoreText.tr(st.error))
        if (ss.asked) return qsTr("%1 of %2 games found on ScreenScraper (%3 not asked yet). Their images take precedence over RomM's; new games are fetched after each sync.").arg(ss.found).arg(ss.asked).arg(Math.max(0, ss.games - ss.asked))
        return qsTr("Fetched after each sync for new games.")
    }
    readonly property var updateButtons: {
        if (!upd) return []
        const st = updState ? updState.state : "idle"
        const github = { id: "update-github", label: qsTr("Open on GitHub") }
        if (st === "downloading" || st === "checking") return [{ id: "none", label: qsTr("Please wait…"), disabled: true }]
        if (st === "ready") return [{ id: "update-apply", label: qsTr("Restart and install"), primary: true }]
        if (st === "available") {
            const a = updState.available.assets[upd.current.platform]
            if (upd.unsupported) return [{ id: "update-github", label: qsTr("Download from GitHub"), primary: true }]
            return [{ id: "update-download", label: qsTr("Install · %1").arg(fmtSize(a ? a.size : 0)), primary: true }, github]
        }
        // No stable release yet: the way out is one press away.
        if (st === "error" && upd.channel === "stable" && /no stable version/.test(updState.error || ""))
            return [{ id: "update-to-dev", label: qsTr("Switch to the dev channel"), primary: true }, github]
        return [{ id: "update-check", label: qsTr("Check now"), primary: true },
                { id: "update-force", label: qsTr("Reinstall the latest build") }, github]
    }

    readonly property var sysFiles: settings && settings.system_files ? settings.system_files : null
    function sysFileRowsOf(c) {
        const t = sysFiles.task
        return c.items.map(i => {
            const busy = t && t.running && t.console === c.slug && t.item === i.id
            const failed = t && !t.running && t.error && t.console === c.slug && t.item === i.id
            let desc = busy ? qsTr("Adding…")
                     : i.files.length ? qsTr("Here: %1").arg(i.files.join(", "))
                     : i.required ? qsTr("Missing — needed to play") : qsTr("Optional")
            if (failed) desc = qsTr("Not added: %1").arg(CoreText.tr(t.error))
            const key = c.slug + "/" + i.id
            // A valid file is in place: only Remove (another file can be added once it is gone).
            const b = i.valid ? []
                    : [{ id: "sf-romm:" + key, label: qsTr("From RomM"), primary: !i.files.length && i.required, disabled: !!(t && t.running) },
                       { id: "sf-pick:" + key, label: qsTr("Choose a file"), disabled: !!(t && t.running) },
                       { id: "sf-url:" + key, label: qsTr("From a link"), disabled: !!(t && t.running) }]
            if (i.files.length) b.push({ id: "sf-remove:" + key, label: qsTr("Remove") })
            return { id: "sf:" + key, kind: "buttons", title: fileName(i.name), desc: desc, items: b }
        })
    }
    // Picture for all games (a console's own values are on its page).
    readonly property var displayData: settings && settings.display ? settings.display : null
    function displayRows() {
        if (!displayData) return []
        return Display.KEYS.map(k => ({ id: "disp:" + k, kind: "chips", title: Display.title(k), desc: Display.desc(k),
                                        selected: displayData.effective[k], items: Display.values(k).map(v => ({ id: v, label: Display.label(k, v) })) }))
    }
    // Each section: its name, a hint under it in the list (warn: something to fix), and a sentence under its title.
    readonly property var sections: [
        { id: "overview", name: qsTr("Overview"), hint: problems ? qsTr("%n to fix", "", problems) : qsTr("Everything is ready"), warn: problems > 0,
          intro: qsTr("What needs your attention, and the main choices at a glance. Press A on a line to go there.") },
        { id: "consoles", name: qsTr("Consoles"), warn: consoles.some(c => consoleIssues(c).some(i => i.tone === "bad")),
          hint: consoles.length ? qsTr("%n console(s)", "", consoles.length) : qsTr("Emulator, picture, BIOS"),
          intro: qsTr("Everything about each console of your library: the emulator that plays it, that emulator's options, the picture and the system files. A game can still have its own settings, from its page.") },
        { id: "shelf", name: qsTr("Library"), hint: qsTr("Consoles' order, videos"),
          intro: qsTr("How your games are shown: the order of the consoles, the clock and the videos.") },
        { id: "controls", name: qsTr("Controllers"), hint: qsTr("Buttons, the consoles' controllers"),
          intro: qsTr("The controllers connected, how their buttons play in every game, and which controller each console's games see.") },
        { id: "language", name: qsTr("Language"), hint: prefs && prefs.language !== "auto" ? (prefs.language === "fr" ? "Français" : "English") : qsTr("As the system"),
          intro: qsTr("Borne's language, which also picks the version and the language of the games.") },
        { id: "games", name: qsTr("Games and saves"), hint: qsTr("Installation, saves, picture"),
          intro: qsTr("How games come to this device, where their saves go, and how every game looks unless its console or the game has its own.") },
        { id: "programs", name: qsTr("Emulators"), hint: qsTr("Install, update"),
          intro: qsTr("The emulator programs on this computer. Borne installs and updates them; you can also give your own.") },
        { id: "interface", name: qsTr("Screen and sound"), hint: qsTr("Size, animations, sounds"),
          intro: qsTr("Borne itself: its size, animations, sounds and the buttons it shows.") },
        { id: "library", name: qsTr("RomM & images"), hint: qsTr("Server, profile, ScreenScraper"), warn: !!(status && status.server_url && !status.online),
          intro: qsTr("The server your games come from, who is playing, and where the case scans come from.") },
        { id: "updates", name: qsTr("Updates"), hint: upd && upd.channel === "dev" ? qsTr("Development") : qsTr("Stable"),
          intro: qsTr("New versions of Borne. They never install during a game.") },
        { id: "help", name: qsTr("Help"), hint: steam && steam.available ? qsTr("Steam, diagnostics, quit") : qsTr("Diagnostics, quit"),
          intro: qsTr("When something goes wrong: a report to share and measurements of this device.") }
    ]
    readonly property var cacheSizes: [5, 10, 20, 50, 100]
    readonly property string sectionId: sections[section].id
    readonly property var rows: {
        const id = sectionId
        if (id === "overview") return overviewRows()
        if (id === "consoles") return consoleSlug ? consoleRows(consoleSlug) : consolesRows()
        if (id === "programs") return programsRows()
        if (id === "controls") return controlsRows()
        if (id === "games") return [
            group(qsTr("Installation")),
            { id: "install", kind: "cards", selected: installMode },
            { id: "cache", kind: "chips", title: qsTr("Space for network play"), desc: qsTr("Disk space Borne keeps for games played from the network (without downloading them), so they start faster next time"),
              selected: settings && settings.stream.cache_limit_mb ? String(Math.round(settings.stream.cache_limit_mb / 1024)) : "20",
              items: cacheSizes.map(g => ({ id: String(g), label: qsTr("%1 GB").arg(g) })) },
            group(qsTr("Saves")),
            { id: "savesync", kind: "chips", title: qsTr("Saves on RomM"), desc: qsTr("Each profile's saves follow it: taken from RomM before a game when newer, sent after it. Replaced saves are archived."),
              selected: settings && settings.save_sync === false ? "off" : "on", items: onOff() },
            group(qsTr("Picture in every game"))
        ].filter(r => r.id !== "cache" || installMode === "stream").concat(displayRows())
        if (id === "updates") return [
            { id: "update", kind: "buttons", title: qsTr("Installed version: %1").arg(page.version), desc: updateText, items: updateButtons },
            group(qsTr("Options")),
            { id: "channel", kind: "chips", title: qsTr("Update channel"), desc: qsTr("Stable gets tested releases; Development gets every build"),
              selected: upd ? upd.channel : "stable", items: [{ id: "stable", label: qsTr("Stable") }, { id: "dev", label: qsTr("Development") }] },
            { id: "auto", kind: "chips", title: qsTr("Check automatically"), desc: qsTr("Every 6 hours, never while you play"),
              selected: upd && upd.auto_check ? "on" : "off", items: onOff() }
        ]
        if (id === "interface") return screenRows()
        if (id === "shelf") return libraryRows()
        if (id === "language") return languageRows()
        if (id === "library") return [
            group(qsTr("RomM")),
            { id: "server", kind: "buttons", title: qsTr("RomM server"), desc: status && status.server_url ? status.server_url + (status.online ? "" : " · " + qsTr("offline")) : qsTr("not configured"),
              items: [{ id: "server", label: qsTr("Change server") }] },
            { id: "sync", kind: "buttons", title: qsTr("Library"), desc: syncText(), items: [{ id: "sync", label: qsTr("Sync now"), disabled: !!(status && status.sync && status.sync.running) }] },
            { id: "profile", kind: "buttons", title: qsTr("Profile"), desc: status && status.active_profile ? status.active_profile.name : "",
              items: [{ id: "profile", label: qsTr("Switch profile") }] },
            group(qsTr("Game images")),
            { id: "ss-account", kind: "buttons", title: qsTr("ScreenScraper account"), desc: ssAccountText(),
              items: !(ss && ss.developer_access) ? []
                     : ss.configured ? [{ id: "ss-signin", label: qsTr("Change") }, { id: "ss-signout", label: qsTr("Sign out") }]
                     : [{ id: "ss-signin", label: qsTr("Connect"), primary: true }] },
            { id: "ss-fetch", kind: "buttons", title: qsTr("Case scans, cartridges, logos"), desc: ssFetchText(),
              items: ssRunning
                     ? [{ id: ss.state.paused ? "ss-resume" : "ss-pause", label: ss.state.paused ? qsTr("Resume") : qsTr("Pause"), primary: true },
                        { id: "ss-stop", label: qsTr("Stop") }]
                     : [{ id: "ss-fetch", label: qsTr("Fetch missing"), primary: true, disabled: !(ss && ss.configured) },
                        { id: "ss-again", label: qsTr("Fetch everything again"), disabled: !(ss && ss.configured) }] },
            { id: "ss-report", kind: "buttons", title: qsTr("Games found, per console"), desc: qsTr("Which games ScreenScraper recognised, and those it did not: open one to correct its match"),
              items: [{ id: "ss-report", label: qsTr("See the report"), disabled: !(ss && ss.configured) }] }
        ]
        return steamRows().concat([
            group(qsTr("When something goes wrong")),
            { id: "report", kind: "buttons", title: qsTr("Diagnostic report"),
              desc: reportPaths.length ? qsTr("Saved: %1").arg(reportPaths[reportPaths.length - 1]) : qsTr("Saves the log and settings, without passwords or tokens, to share when something goes wrong"),
              items: [{ id: "report", label: qsTr("Export the report") }] },
            { id: "diag", kind: "buttons", title: qsTr("Measurements"), desc: qsTr("Graphics, memory and disk speed of this device, to understand a slow game"),
              items: [{ id: "diag", label: qsTr("Open") }] },
            { id: "quit", kind: "buttons", title: qsTr("Quit Borne"), desc: qsTr("Back to the system"), items: [{ id: "quit", label: qsTr("Quit") }] }
        ])
    }
    // Borne in Steam (Linux): added through Chimera on ChimeraOS, else into Steam's shortcuts.
    function steamRows() {
        if (!steam || !steam.available) return []
        const desc = steam.chimera
            ? (steam.added ? qsTr("Added through ChimeraOS: Borne is in your Steam library after the next Steam session start, with its artwork.")
                           : qsTr("ChimeraOS adds Borne to your Steam library, with its artwork, at the next Steam session start."))
            : steam.added ? qsTr("Borne is in your Steam library.")
            : steam.steam_running ? qsTr("Steam rewrites its list when it quits: close Steam, then add Borne (from the desktop).")
            : qsTr("Adds Borne to your Steam library as a non-Steam game, with its artwork.")
        const items = steam.chimera && steam.added ? [{ id: "steam-remove", label: qsTr("Remove from Steam") }]
                    : [{ id: "steam-add", label: steam.added ? qsTr("Add again") : qsTr("Add to Steam"), primary: !steam.added, disabled: !!steam.steam_running }]
        return [group(qsTr("Steam")), { id: "steam", kind: "buttons", title: qsTr("Borne in Steam"), desc: desc, items: items }]
    }
    function syncText() {
        const s = status ? status.sync : null
        if (!s) return ""
        if (s.running) return qsTr("Syncing %1 of %2…").arg(s.done).arg(s.total)
        if (s.error) return qsTr("Last sync failed: %1").arg(CoreText.tr(s.error))
        if (s.last_sync) return qsTr("Synced at %1").arg(new Date(s.last_sync * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat))
        return ""
    }
    readonly property var installItems: [{ id: "download" }, { id: "stream", disabled: !streamAvailable }]

    function itemsOf(r) { return r.kind === "cards" ? installItems : r.items }
    function colOf(id) { return cols[id] !== undefined ? cols[id] : 0 }
    function setCol(id, c) { const n = Object.assign({}, cols); n[id] = c; cols = n }
    // The next row that can be focused from i in direction d (group titles are skipped).
    function step(i, d) {
        for (let j = i + d; j >= 0 && j < rows.length; j += d) if (rows[j].kind !== "header" && rows[j].kind !== "note") return j
        return i
    }
    function firstRow() { return step(-1, 1) }
    // Rows come and go (a choice can show or hide others): keep the focus on a real row, and give
    // new rows their current choice.
    onRowsChanged: {
        if (row >= rows.length || (rows[row] && (rows[row].kind === "header" || rows[row].kind === "note")))
            row = row >= rows.length ? step(rows.length, -1) : step(row, 1) !== row ? step(row, 1) : step(row, -1)
        const c = Object.assign({}, cols)
        let changed = false
        for (const r of rows) if (c[r.id] === undefined) { c[r.id] = Math.max(0, itemsOf(r).findIndex(x => x.id === r.selected)); changed = true }
        if (changed) cols = c
    }
    function selectSection(i) {
        section = i
        row = firstRow()
        const c = {}
        for (const r of rows) c[r.id] = Math.max(0, itemsOf(r).findIndex(x => x.id === r.selected))
        cols = c
    }
    function reset() { closeConsole(); inRows = false; selectSection(0) }
    // Opens a section from the overview (or a console's page), the focus on its rows.
    function go(target) {
        const parts = target.split(":")
        // "console:<slug>": that console's page in Consoles.
        if (parts[0] === "console") parts[0] = "consoles"
        const i = sections.findIndex(x => x.id === parts[0])
        if (i < 0) return
        closeConsole()
        selectSection(i)
        if (parts[0] === "consoles" && parts[1]) openConsole(parts[1])
        inRows = true
        if (row < 0 || rows[row] === undefined || rows[row].kind === "header" || rows[row].kind === "note") row = firstRow()
    }
    function openConsole(slug) {
        consoleRow = row
        consoleDisplay = null; consoleOpts = null; consoleControls = null
        consoleSlug = slug
        const ch = chosenOf(consoleOf(slug))
        page.action("console-open", { slug: slug, program: ch ? ch.program : "" })
        row = firstRow()
        rowsView.contentY = 0
    }
    function closeConsole() {
        if (!consoleSlug) return
        const slug = consoleSlug
        consoleSlug = ""; consoleDisplay = null; consoleOpts = null; consoleControls = null
        const i = rows.findIndex(r => r.id === "console:" + slug)
        row = i >= 0 ? i : firstRow()
    }
    function activate(r, i) {
        const item = itemsOf(r)[i]
        if (!item || item.disabled || item.id === "none") return
        if (r.id === "install") page.action("install", item.id)
        else if (r.id === "cache") page.action("cache", Number(item.id) * 1024)
        else if (r.id === "channel") page.action("channel", item.id)
        else if (r.id === "auto") page.action("auto", item.id === "on")
        else if (r.id === "savesync") page.action("savesync", item.id === "on")
        else if (r.id.startsWith("pref:")) page.action("pref", { key: r.id.substring(5), value: item.value })
        else if (r.id.startsWith("disp:")) page.action("display", { console: "", key: r.id.substring(5), value: item.id })
        else if (r.id.startsWith("cdisp:")) page.action("display", { console: page.consoleSlug, key: r.id.substring(6), value: item.id })
        else if (r.id.startsWith("console:")) openConsole(r.id.substring(8))
        else if (r.id.startsWith("go:")) go(r.id.substring(3))
        else if (r.id === "pick-consoles") page.action("pick-consoles", null)
        else if (r.id === "emu-dismiss") page.action("emu-dismiss", null)
        else if (r.id.startsWith("emu-choice:")) page.action("console-emu", { slug: r.id.substring(11), engine: item.id })
        else if (r.id.startsWith("opt:")) { const k = r.id.split(":"); page.action("emu-option", { program: k[1], key: k[2], value: item.id }) }
        else if (r.id.startsWith("opt-reset:")) page.action("emu-options-reset", { program: r.id.substring(10) })
        else if (r.id.startsWith("ctl:")) page.action("controls", { scope: ctlScope(), key: r.id.substring(4), value: item.id })
        else if (r.id.startsWith("ctl-btn:")) page.action("controls-capture", { scope: ctlScope(), button: r.id.substring(8), name: r.title })
        else if (r.id === "ctl-reset-buttons") page.action("controls", { scope: ctlScope(), key: "map.*", value: "default" })
        else if (r.id === "ctl-reset") page.action("controls", { scope: ctlScope(), key: "*", value: "default" })
        else if (r.id === "emu-auto") page.action("emu-auto", item.id === "on")
        else if (r.id === "lb") page.action("lb-enabled", item.id === "on")
        else page.action(item.id, null)
    }
    // Whose controls the rows change: the console open, else every game.
    function ctlScope() { return consoleSlug ? "console:" + consoleSlug : "all" }
    function handle(a) {
        if (a === "b" || a === "start") {
            if (inRows && a === "b" && consoleSlug) { closeConsole(); return }
            if (inRows && a === "b") { inRows = false; return }
            page.action("back", null)
            return
        }
        if (!inRows) {
            if (a === "up") { closeConsole(); selectSection(Math.max(0, section - 1)) }
            else if (a === "down") { closeConsole(); selectSection(Math.min(sections.length - 1, section + 1)) }
            else if (a === "right" || a === "a") { inRows = true; row = firstRow() }
            return
        }
        const r = rows[Math.min(row, rows.length - 1)]
        const n = itemsOf(r).length
        // A choice: left and right (and A) change it at once.
        if (r.kind === "chips" && (a === "left" || a === "right" || a === "a")) { cycle(r, a === "left" ? -1 : 1); return }
        if (a === "up") row = step(row, -1)
        else if (a === "down") row = step(row, 1)
        else if (a === "left") { if (colOf(r.id) > 0) setCol(r.id, colOf(r.id) - 1); else if (consoleSlug) closeConsole(); else inRows = false }
        else if (a === "right") setCol(r.id, Math.min(n - 1, colOf(r.id) + 1))
        else if (a === "a") activate(r, colOf(r.id))
    }
    function focused(id, i) { return inRows && rows[row] && rows[row].id === id && colOf(id) === i }
    // The next (d = 1) or previous (-1) choice of a line that can be chosen, applied.
    function cycle(r, d) {
        const items = itemsOf(r)
        const n = items.length
        if (n < 2) return
        let i = Math.max(0, items.findIndex(x => String(x.id) === String(r.selected)))
        for (let k = 0; k < n; k++) {
            i = (i + d + n) % n
            if (!items[i].disabled && items[i].id !== "none") break
        }
        setCol(r.id, i)
        activate(r, i)
    }


    // ---------- sections ----------
    Item {
        id: side
        width: 420
        height: parent.height

        Text {
            x: 56; y: 48
            text: qsTr("Settings")
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 44; weight: Font.ExtraBold; letterSpacing: -1 }
        }
        Column {
            id: sectionsCol
            x: 40; y: 124
            width: parent.width - 72
            spacing: 6
            Repeater {
                model: page.sections
                Rectangle {
                    id: sec
                    required property var modelData
                    required property int index
                    readonly property bool current: page.section === index
                    // The open section shows its hint under its name; the others, their name alone.
                    width: parent.width; height: current ? 70 : 44
                    Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    radius: current ? 22 : 16
                    // The open section: a pill, white while the focus is on the list.
                    readonly property bool focusedHere: current && !page.inRows
                    color: focusedHere ? theme.fg : current ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                    Behavior on color { ColorAnimation { duration: theme.focusMs } }
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.name
                    clip: true
                    Column {
                        x: 22; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 60
                        spacing: 2
                        Text { width: parent.width; elide: Text.ElideRight; text: sec.modelData.name; color: sec.focusedHere ? theme.bg : sec.current ? theme.fg : theme.fgMuted; font { family: theme.fontFamily; pixelSize: 21; weight: sec.current ? Font.ExtraBold : Font.DemiBold } }
                        Text { visible: sec.current; width: parent.width; elide: Text.ElideRight; text: sec.modelData.hint; color: sec.modelData.warn ? theme.bad : sec.focusedHere ? Qt.rgba(0, 0, 0, 0.6) : theme.fgFaint; font { family: theme.fontFamily; pixelSize: 16; weight: Font.Medium } }
                    }
                    // Something to fix there.
                    Rectangle {
                        visible: !!sec.modelData.warn
                        anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
                        width: 10; height: 10; radius: 5; color: theme.bad
                    }
                }
            }
        }
        // The version and the server, at the foot of the sections (when they leave room).
        readonly property bool footRoom: sectionsCol.y + sectionsCol.height + 24 < footText.y
        Text {
            id: footText
            visible: side.footRoom
            x: 56; anchors { bottom: parent.bottom; bottomMargin: 30 }
            width: parent.width - 88
            text: qsTr("Version %1").arg(page.version) + (page.status && page.status.server_url ? "\n" + page.status.server_url : "")
            wrapMode: Text.WrapAnywhere
            lineHeight: 1.4
            color: theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 15 }
        }
    }

    // ---------- rows, in a floating panel (scroll to follow the selection when there are many) ----------
    Flickable {
        id: rowsView
        x: side.width + 40; y: 52
        width: Math.min(1500, parent.width - x - 60)
        height: parent.height - y - 24
        contentHeight: rowsCol.height + 50
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Behavior on contentY { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        function ensure(item) {
            const top = item.y, bottom = item.y + item.height
            if (top - 24 < contentY) contentY = Math.max(0, top - 24)
            else if (bottom + 24 > contentY + height) contentY = Math.min(contentHeight - height, bottom + 24 - height)
        }
        Connections { target: page; function onSectionChanged() { rowsView.contentY = 0 } function onConsoleSlugChanged() { rowsView.contentY = 0 } }
    Column {
        id: rowsCol
        // A margin all round, for the focus ring (and a focused card's growth) not to be cut.
        x: 14; y: 10
        width: parent.width - 28
        spacing: 18

        Column {
            width: parent.width
            spacing: 10
            // On a console's page: where it comes from, then the console's name.
            Text {
                visible: page.consoleSlug !== ""
                text: "‹  " + qsTr("Consoles")
                color: theme.fgFaint
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.DemiBold }
            }
            Text {
                text: page.consoleSlug ? (page.consoleOf(page.consoleSlug) ? page.consoleOf(page.consoleSlug).name : "") : page.sections[page.section].name
                color: theme.fg; font { family: theme.displayFont; pixelSize: 34; weight: Font.Bold }
            }
            Text {
                width: parent.width; wrapMode: Text.WordWrap
                text: page.consoleSlug ? qsTr("These settings apply to every game of this console; a game can have its own, from its page.")
                                       : page.sections[page.section].intro || ""
                color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 18 }
            }
        }

        Repeater {
            model: page.rows
            Item {
                id: rowItem
                required property var modelData
                required property int index
                readonly property bool current: page.row === index
                onCurrentChanged: if (current) rowsView.ensure(rowItem)
                // Rows made again (a value changed): the selected one kept in view.
                Component.onCompleted: if (current) Qt.callLater(function () { if (rowItem && rowItem.current && rowItem.parent && rowsView) rowsView.ensure(rowItem) })
                width: parent.width
                height: modelData.kind === "cards" ? cards.height : modelData.kind === "header" ? 58
                        : modelData.kind === "note" ? noteText.height + 8 : line.implicitHeight

                // A group title: small capitals, a thin line after it; never focused.
                Item {
                    visible: rowItem.modelData.kind === "header"
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

                // A sentence between rows (a state, an explanation); never focused.
                Text {
                    id: noteText
                    visible: rowItem.modelData.kind === "note"
                    x: 8; width: parent.width - 16
                    text: rowItem.modelData.kind === "note" ? rowItem.modelData.desc : ""
                    wrapMode: Text.WordWrap
                    lineHeight: 1.25
                    color: text.indexOf("⚠") === 0 ? theme.bad : theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 17 }
                }

                // Install method: two explained cards.
                Row {
                    id: cards
                    visible: rowItem.modelData.kind === "cards"
                    width: parent.width
                    spacing: 24
                    OptionCard {
                        width: (parent.width - 24) / 2
                        theme: page.theme
                        title: qsTr("Download")
                        badge: page.installMode === "download" ? qsTr("Current") : ""
                        summary: qsTr("The whole game is copied to this device before you play.")
                        points: [qsTr("Plays offline, even if the server is down"), qsTr("Fastest loading, no network during play"), qsTr("Uses disk space for every installed game")]
                        selected: page.installMode === "download"
                        focused: page.focused("install", 0)
                    }
                    OptionCard {
                        width: (parent.width - 24) / 2
                        theme: page.theme
                        title: qsTr("Mount")
                        badge: page.installMode === "stream" ? qsTr("Current") : page.streamAvailable ? "" : qsTr("Linux only")
                        summary: Qt.platform.os === "osx"
                                 ? qsTr("Borne downloads the game you pick as a temporary copy; the least recently played go first when the cache is full.")
                                 : qsTr("Borne reads the game from RomM while you play. Only games you pick are exposed.")
                        points: Qt.platform.os === "osx"
                                ? [qsTr("Nothing to tidy: the space used stays under the cache size"), qsTr("Games you play often stay ready"), qsTr("The first start waits for the download")]
                                : [qsTr("Starts in seconds, even for large games"), qsTr("Keeps the disk free; a small cache speeds up replays"), qsTr("Needs the server reachable during play")]
                        note: !page.streamAvailable && page.settings && page.settings.stream.error ? qsTr("Unavailable here: %1").arg(CoreText.tr(page.settings.stream.error)) : ""
                        selected: page.installMode === "stream"
                        disabled: !page.streamAvailable
                        focused: page.focused("install", 1)
                    }
                }

                // A setting: its name and sentence, its value, buttons or state on the right.
                SettingRow {
                    id: line
                    visible: rowItem.modelData.kind !== "cards" && rowItem.modelData.kind !== "header" && rowItem.modelData.kind !== "note"
                    width: parent.width
                    height: rowItem.height
                    theme: page.theme
                    kind: rowItem.modelData.kind
                    title: rowItem.modelData.title || ""
                    desc: rowItem.modelData.desc || ""
                    items: rowItem.modelData.kind === "chips" || rowItem.modelData.kind === "buttons" ? rowItem.modelData.items : []
                    selected: rowItem.modelData.selected !== undefined ? String(rowItem.modelData.selected) : ""
                    current: rowItem.current && page.inRows
                    focusedCol: page.colOf(rowItem.modelData.id)
                    badge: rowItem.modelData.badge || ""
                    tone: rowItem.modelData.tone || ""
                }
            }
        }
    }
    }

    // The buttons, shown in the app's foot bar, and where you are.
    readonly property var hints: inRows && rows[row] && rows[row].kind === "link"
                                 ? [["A", qsTr("Open"), "a"], ["B", qsTr("Back"), "b"]]
                                 : inRows && rows[row] && rows[row].kind === "chips"
                                   ? [["◀ ▶", qsTr("Change value"), "right"], ["B", qsTr("Back"), "b"]]
                                   : inRows ? [["A", qsTr("Choose"), "a"], ["◀ ▶", qsTr("Move"), "right"], ["B", qsTr("Back"), "b"]]
                                            : [["▲ ▼", qsTr("Sections"), "down"], ["A", qsTr("Open"), "a"], ["B", qsTr("Close"), "b"]]
    readonly property string where: {
        const t = [sections[section] ? sections[section].name : ""]
        if (consoleSlug && consoleOf(consoleSlug)) t.push(consoleOf(consoleSlug).name)
        return t.join("  ›  ")
    }
}
