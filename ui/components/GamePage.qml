// Game page: over the game's art (and its video, Main's background, which fills the screen with
// its sound after a few seconds without a press), the console and where the game was opened from,
// its name, a few lines about it and what you can do: Play (or Install), the heart (favourites),
// its settings (Y) and its fact sheet (i), which takes the summary's place. On the right its case
// in 3D, turning slowly; up reaches it and the arrows turn it. Under it, the gallery: the video
// first (A: in full screen with its sound), then the screenshots, which the background follows.
//
// Gamepad: left / right through the buttons, up to the case, down to the gallery, A to activate,
// Y for the game's settings, B to go back.
import QtQuick
import QtQuick.Effects
import "ConsoleNeeds.js" as Needs
import "CoreText.js" as CoreText
import "Cases.js" as Cases
import "Devices.js" as Devices

Item {
    id: page
    property QtObject theme
    property var game: null            // shown version, as a library row (cover, trailer, states…)
    property var versions: []          // every version of the game (raw API rows)
    property var needs: []             // what its console's games need that is missing here
    property var fileNote: null        // { ok, text }: what the downloaded file says of itself
    property string emuLanguage: "auto"
    property var gameLanguages: []     // [{ code, version }]: the game's real languages
    property string uiLang: "en"
    property string installMode: "download"
    property bool streamAvailable: false
    property string streamError: ""
    property bool trailers: true
    property string trailerUrl: ""         // local file prepared by the core
    property string trailerState: ""       // "", "loading", "ready", "error: …"
    property bool paused: false
    property var facts: null           // GET /api/v1/games/<id>/facts
    property string shotBase: ""       // URL prefix of the screenshots (…/screenshots/)
    property string emulator: ""       // the emulator the game opens in
    property string device: ""         // the controller its console sees ("" when it has no choice)
    property string deviceWanted: ""   // the one the game is known to want
    property bool sound: false
    property string consoleLogo: ""      // the console's logo (url), or ""
    property string consoleName: ""
    property string crumb: ""            // where the game was opened from

    signal action(string id, var payload)

    // Where the selection is: "buttons", "box" (the case, turned with the arrows) or "gallery".
    property string zone: "buttons"
    property int buttonIndex: 0
    property int galleryIndex: 0
    property bool infoShown: false       // the fact sheet instead of the summary
    property bool shotOpen: false        // a screenshot in large

    readonly property bool busy: game !== null && ["queued", "downloading", "verifying", "extracting"].indexOf(game.dl_state) >= 0
    // The versions a player can choose (an update or a DLC stored as a game of its own is not one).
    readonly property var playable: versions.filter(v => !v.extra)
    readonly property bool hasTrailer: !!(game && game.trailer)
    readonly property color tint: game ? Cases.tint(game.platform_slug) : theme.accent

    function fmtSize(b) {
        return b >= 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
             : b >= 1048576 ? qsTr("%1 MB").arg(Math.round(b / 1048576)) : qsTr("%1 KB").arg(Math.max(1, Math.round(b / 1024)))
    }

    // ---------- content ----------
    readonly property var actions: {
        const g = game
        if (!g) return []
        if (busy) return [{ id: "cancel", label: qsTr("Cancel download"), primary: true }]
        if (g.dl_state === "failed") return [{ id: "download", label: qsTr("Retry download"), primary: true }, { id: "cancel", label: qsTr("Give up") }]
        if (g.dl_state === "paused") return [{ id: "download", label: qsTr("Resume download"), primary: true }, { id: "cancel", label: qsTr("Cancel download") }]
        // Play (or get the game), the favourite, and the game's own settings (emulator, display,
        // cheats, language, cover, removal: see Main.gameSettings).
        const fav = { id: "fav", label: g.favourite ? qsTr("Remove from favourites") : qsTr("Add to favourites") }
        const set = { id: "settings", label: qsTr("Game settings"), key: "Y", detail: settingsLine }
        if (g.local_state === "local" || g.linked) return [{ id: "play", label: qsTr("Play"), primary: true }, fav, set]
        if (g.local_state === "missing") return [{ id: "download", label: qsTr("Download again"), primary: true }, fav, set]
        const dl = { id: "download", label: qsTr("Download · %1").arg(fmtSize(g.fs_size)) }
        const net = { id: "link", label: qsTr("Play from the network"), disabled: !streamAvailable }
        if (installMode === "stream" && streamAvailable) { net.primary = true; return [net, dl, fav, set] }
        dl.primary = true
        return [dl, net, fav, set]
    }
    // Under "Game settings": what this game is set to (version, language, controller).
    readonly property string settingsLine: {
        const g = game
        if (!g) return ""
        const bits = []
        const v = playable.find(x => x.rom_id === g.rom_id)
        if (v && playable.length > 1) bits.push(versionLabel(v))
        if (currentLang) bits.push(languageName(currentLang))
        if (device) bits.push(Devices.label(device, g.platform_slug))
        return bits.join(" · ")
    }
    // Kept for Main (the actions as before).
    readonly property var allActions: actions

    readonly property string longSummary: game && game.summary ? game.summary : ""
    // The language played: the stored choice if it matches the shown version, else the UI
    // language, else the version's first language.
    readonly property string currentLang: {
        const fits = c => gameLanguages.some(l => l.code === c && game && l.version === game.rom_id)
        if (fits(emuLanguage)) return emuLanguage
        if (fits(uiLang)) return uiLang
        const m = gameLanguages.find(l => game && l.version === game.rom_id)
        return m ? m.code : ""
    }
    function languageName(code) {
        const names = { en: "English", fr: "Français", de: "Deutsch", es: "Español", it: "Italiano", nl: "Nederlands", pt: "Português",
                        ja: "日本語", sv: "Svenska", da: "Dansk", no: "Norsk", fi: "Suomi", pl: "Polski", ru: "Русский", ko: "한국어", zh: "中文" }
        return names[code] || code
    }
    function has(kind) { return !!(game && game.art_kinds && game.art_kinds.indexOf("," + kind + ",") >= 0) }
    function versionLabel(v) {
        const regions = (v.regions || "").split(",").map(x => x.trim()).filter(x => x)
        return regions.length ? regions.map(regionName).join(" / ") : qsTr("Version %1").arg(playable.indexOf(v) + 1)
    }
    function versionDetail(v) {
        const codes = { English: "EN", French: "FR", German: "DE", Spanish: "ES", Italian: "IT", Dutch: "NL", Portuguese: "PT",
                        Japanese: "JA", Swedish: "SV", Danish: "DA", Norwegian: "NO", Finnish: "FI", Polish: "PL", Russian: "RU",
                        Korean: "KO", Chinese: "ZH" }
        const langs = (v.langs || []).map(l => codes[l] || l).join(" ")
        const rev = v.revision ? qsTr("rev %1").arg(v.revision) : ""
        return [langs, rev].filter(x => x).join(" · ")
    }
    function regionName(r) {
        const map = {
            "Europe": qsTr("Europe"), "USA": qsTr("USA"), "Japan": qsTr("Japan"), "World": qsTr("World"),
            "France": qsTr("France"), "Germany": qsTr("Germany"), "Spain": qsTr("Spain"), "Italy": qsTr("Italy"),
            "UK": qsTr("United Kingdom"), "Australia": qsTr("Australia"), "Brazil": qsTr("Brazil"), "Korea": qsTr("Korea"),
            "China": qsTr("China"), "Canada": qsTr("Canada"), "Netherlands": qsTr("Netherlands")
        }
        return map[r] || r
    }
    function stateText() {
        const g = game
        if (!g) return ""
        const dl = g.dl_state
        if (dl === "queued") return qsTr("Waiting to download")
        if (dl === "downloading") return qsTr("Downloading… %1%").arg(g.dl_total > 0 ? Math.round(100 * g.dl_received / g.dl_total) : 0)
        if (dl === "verifying") return qsTr("Verifying files…")
        if (dl === "extracting") return qsTr("Extracting…")
        if (dl === "paused") return qsTr("Download paused at %1%").arg(g.dl_total > 0 ? Math.round(100 * g.dl_received / g.dl_total) : 0)
        if (dl === "failed") return qsTr("Download failed: %1").arg(g.dl_error || "")
        if (g.local_state === "local") return qsTr("Installed on this device")
        if (g.linked) return qsTr("Played from the network: nothing stored on this device")
        if (g.local_state === "missing") return qsTr("Local files not found")
        return qsTr("On RomM · %1").arg(fmtSize(g.fs_size))
    }
    function agoText(secs) {
        if (!secs) return qsTr("Never")
        const d = Math.floor((Date.now() / 1000 - secs) / 86400)
        if (d <= 0) return qsTr("Today")
        if (d === 1) return qsTr("Yesterday")
        if (d < 14) return qsTr("%n day(s) ago", "", d)
        if (d < 60) return qsTr("%n week(s) ago", "", Math.round(d / 7))
        return qsTr("%n month(s) ago", "", Math.round(d / 30))
    }
    function playersText(p) {
        if (!p) return ""
        return /^\d+$/.test(p) ? qsTr("%n player(s)", "", Number(p)) : qsTr("%1 players").arg(p)
    }

    // The table of facts: what RomM and the files say.
    readonly property var factRows: {
        const g = game
        if (!g) return []
        const out = []
        const add = (k, v) => { if (v !== undefined && v !== null && String(v) !== "") out.push({ k: k, v: String(v) }) }
        const list = x => x && x.length ? x.join(", ") : ""
        if (facts) add(qsTr("Studios"), list(facts.companies))
        if (facts) add(qsTr("Series"), list((facts.franchises || []).concat(facts.collections || []).filter((x, i, a) => a.indexOf(x) === i).slice(0, 3)))
        const rel = facts && facts.release ? new Date(facts.release * (facts.release > 1e11 ? 1 : 1000)) : null
        add(qsTr("Released"), rel ? rel.toLocaleDateString(Qt.locale(), Locale.LongFormat) : g.year > 0 ? String(g.year) : "")
        add(qsTr("Players"), playersText(g.players))
        if (facts && facts.rating > 0) add(qsTr("Players' rating"), qsTr("%1 / 100").arg(Math.round(facts.rating)))
        const h = (g.play_seconds || 0) / 3600
        add(qsTr("Your play time"), h >= 1 ? qsTr("%1 h").arg(Math.round(h * 10) / 10) : h > 0 ? qsTr("%1 min").arg(Math.max(1, Math.round(h * 60))) : qsTr("Not played yet"))
        if (g.last_played) add(qsTr("Last played"), agoText(g.last_played))
        if (facts) add(qsTr("Modes"), list(facts.game_modes))
        if (facts) add(qsTr("Age rating"), list(facts.age_ratings))
        add(qsTr("Regions"), (g.regions || "").split(",").map(x => regionName(x.trim())).filter(x => x).join(", "))
        add(qsTr("Languages"), gameLanguages.filter(l => l.version === g.rom_id).map(l => languageName(l.code)).join(", "))
        add(qsTr("Versions"), playable.length > 1 ? String(playable.length) : "")
        add(qsTr("File"), fmtSize(g.fs_size))
        add(qsTr("Emulator"), emulator)
        if (device) add(qsTr("Controller"), Devices.label(device, g.platform_slug))
        return out
    }

    // ---------- the buttons ----------
    // Play (or get the game) in white with its name, the other ways to get it in glass, then the
    // heart, the game's settings and its fact sheet as round buttons.
    readonly property var buttons: {
        const out = []
        for (const a of actions) {
            if (a.id === "fav") out.push({ id: "fav", icon: "heart", filled: !!(game && game.favourite), label: a.label,
                                           tip: game && game.favourite ? qsTr("In your favourites · A to remove it") : qsTr("Add to your favourites") })
            else if (a.id === "settings") out.push({ id: "settings", icon: "settings", label: a.label,
                                                     tip: settingsLine ? qsTr("Game settings · %1").arg(settingsLine) : qsTr("Game settings") })
            else out.push({ id: a.id, icon: a.id === "play" ? "play" : a.id === "download" ? "download" : a.id === "link" ? "link" : a.id === "cancel" ? "close" : "",
                            filled: a.id === "play", label: a.label, text: a.label, primary: !!a.primary, disabled: !!a.disabled, tip: tipOf(a) })
        }
        out.push({ id: "info", icon: "info", label: qsTr("Fact sheet"), tip: infoShown ? qsTr("Back to the summary") : qsTr("Fact sheet") })
        return out
    }
    function tipOf(a) {
        const g = game
        if (!g) return ""
        if (a.id === "play") {
            const h = (g.play_seconds || 0) / 3600
            return h > 0 ? qsTr("%1 played · last time %2").arg(h >= 1 ? qsTr("%1 h").arg(Math.round(h * 10) / 10) : qsTr("%1 min").arg(Math.max(1, Math.round(h * 60))))
                                                             .arg(agoText(g.last_played).toLowerCase())
                         : qsTr("Never played")
        }
        if (a.id === "link") return a.disabled ? streamError : qsTr("Nothing stored on this device")
        return stateText()
    }
    // The gallery: the game's video (when there is one), then the screenshots.
    property bool videoShown: false       // the video plays behind the page (Main's background)
    readonly property bool videoItem: trailers && (trailerUrl !== "" || trailerState === "loading")
    readonly property int shotCount: facts ? Math.min(8, facts.screenshots || 0) : 0
    readonly property int galleryCount: (videoItem ? 1 : 0) + shotCount
    function shotOf(k) { return videoItem ? k - 1 : k }
    // The picture behind the page: the screenshot selected in the gallery ("" for the game's art).
    readonly property string artOverride: zone === "gallery" && shotOf(galleryIndex) >= 0 && shotBase ? shotBase + shotOf(galleryIndex) : ""
    // The footer's buttons (Main's footer shows them).
    readonly property var hints: {
        if (shotOpen) return [["◀ ▶", qsTr("Screenshots"), "right"], ["B", qsTr("Close"), "b"]]
        if (zone === "box") return [["✥", qsTr("Turn the case"), "right", "← →"], ["A", qsTr("Done"), "a"]]
        const h = []
        if (zone === "buttons") {
            const b = buttons[buttonIndex]
            if (b && !b.disabled) h.push(["A", b.label, "a"])
            h.push(["▲", qsTr("The case"), "up"])
            if (galleryCount) h.push(["▼", qsTr("Gallery"), "down"])
        } else {
            h.push(["A", shotOf(galleryIndex) < 0 ? qsTr("Watch") : qsTr("View"), "a"])
            h.push(["▲", qsTr("Actions"), "up"])
        }
        if (actions.some(x => x.id === "settings")) h.push(["Y", qsTr("Game settings"), "y"])
        h.push(["B", qsTr("Back"), "b"])
        return h
    }

    // ---------- input ----------
    function reset() {
        zone = "buttons"
        buttonIndex = 0
        galleryIndex = 0
        infoShown = false
        shotOpen = false
        sound = false
        caseYaw = -24; casePitch = 6
    }
    property real caseYaw: -24
    property real casePitch: 6
    function handle(a) {
        if (shotOpen) {
            if (a === "b" || a === "a") shotOpen = false
            else if (a === "left" && galleryIndex > (videoItem ? 1 : 0)) galleryIndex--
            else if (a === "right" && galleryIndex < galleryCount - 1) galleryIndex++
            return
        }
        if (zone === "box") {
            if (a === "left") caseYaw -= 30
            else if (a === "right") caseYaw += 30
            else if (a === "up") casePitch = Math.max(-45, casePitch - 15)
            else if (a === "down") casePitch = Math.min(45, casePitch + 15)
            else if (a === "a" || a === "b") { zone = "buttons"; caseYaw = -24; casePitch = 6 }
            else if (a === "y" && actions.some(x => x.id === "settings")) page.action("settings", null)
            return
        }
        if (a === "b") { page.action("back", null); return }
        if (a === "y" && actions.some(x => x.id === "settings")) { page.action("settings", null); return }
        if (zone === "buttons") {
            if (a === "left") buttonIndex = Math.max(0, buttonIndex - 1)
            else if (a === "right") buttonIndex = Math.min(buttons.length - 1, buttonIndex + 1)
            else if (a === "up") zone = "box"
            else if (a === "down" && galleryCount > 0) zone = "gallery"
            else if (a === "a") {
                const b = buttons[buttonIndex]
                if (!b || b.disabled) return
                if (b.id === "info") infoShown = !infoShown
                else page.action(b.id, null)
            }
        } else {
            if (a === "left") galleryIndex = Math.max(0, galleryIndex - 1)
            else if (a === "right") galleryIndex = Math.min(galleryCount - 1, galleryIndex + 1)
            else if (a === "up") zone = "buttons"
            else if (a === "a") {
                // The video: in full screen with its sound; a screenshot: in large.
                if (shotOf(galleryIndex) < 0) page.action("watch", null)
                else shotOpen = true
            }
        }
    }
    onButtonsChanged: buttonIndex = Math.min(buttonIndex, Math.max(0, buttons.length - 1))
    onGalleryCountChanged: { if (galleryIndex >= galleryCount) galleryIndex = Math.max(0, galleryCount - 1); if (!galleryCount && zone === "gallery") zone = "buttons" }
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0

    // ---------- the page ----------
    Item {
        id: body
        anchors.fill: parent
        opacity: page.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 450 * theme.motion } }
        readonly property real leftX: 196
        readonly property real textW: Math.min(820, width * 0.46)

        // Where you are: the console's logo, where the game was opened from, its state.
        Row {
            id: head
            x: body.leftX; y: 112
            spacing: 16
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: logoImg.status === Image.Ready ? Math.min(160, logoImg.paintedWidth) : nameChip.width
                height: 30
                Image {
                    id: logoImg
                    height: 30; width: 160
                    visible: status === Image.Ready
                    source: page.consoleLogo
                    sourceSize.height: 96
                    fillMode: Image.PreserveAspectFit
                    horizontalAlignment: Image.AlignLeft
                    asynchronous: true
                    layer.enabled: visible
                    layer.effect: MultiEffect { brightness: 1.0; saturation: -1.0 }
                }
                Text {
                    id: nameChip
                    visible: logoImg.status !== Image.Ready
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.consoleName || (page.game ? page.game.platform_short : "")
                    color: "#ffffff"
                    font { family: theme.displayFont; pixelSize: 22; weight: Font.ExtraBold }
                }
            }
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 1.5; height: 22; color: Qt.rgba(1, 1, 1, 0.35) }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: page.crumb
                color: Qt.rgba(1, 1, 1, 0.8)
                font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold }
            }
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 1.5; height: 22; color: Qt.rgba(1, 1, 1, 0.35) }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: page.stateText()
                color: page.game && page.game.dl_state === "failed" ? theme.badSoft : Qt.rgba(1, 1, 1, 0.8)
                font { family: theme.fontFamily; pixelSize: 17; weight: Font.Bold }
            }
            Rectangle {
                visible: page.busy
                anchors.verticalCenter: parent.verticalCenter
                width: 140; height: 6; radius: 3
                color: Qt.rgba(1, 1, 1, 0.2)
                Rectangle {
                    height: parent.height; radius: 3; color: theme.fg
                    width: parent.width * page.progress
                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                }
            }
        }

        // ---------- the name, a few lines, what you can do ----------
        Column {
            id: textCol
            x: body.leftX; y: 170
            width: body.textW
            spacing: 18
            // Everything above the gallery: the summary gets the lines left.
            readonly property real room: (page.galleryCount > 0 ? 760 : 940) - y
            Text {
                id: titleText
                width: parent.width
                text: page.game ? page.game.name : ""
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                lineHeight: 0.95
                color: theme.fg
                font { family: theme.displayFont; pixelSize: page.game && page.game.name.length > 24 ? 60 : 78; weight: Font.ExtraBold; letterSpacing: -2.5 }
            }
            Text {
                id: summary
                visible: !page.infoShown
                width: parent.width
                text: page.longSummary || qsTr("No summary for this game yet.")
                wrapMode: Text.WordWrap
                readonly property real others: titleText.height + facts.height + (note.visible ? note.height + textCol.spacing : 0) + btnRow.height + 3 * textCol.spacing + 10
                maximumLineCount: Math.max(1, Math.min(5, Math.floor((textCol.room - others) / 29)))
                elide: Text.ElideRight
                lineHeight: 1.4
                color: Qt.rgba(1, 1, 1, 0.9)
                font { family: theme.fontFamily; pixelSize: 19 }
            }
            Column {
                id: facts
                visible: !page.infoShown
                spacing: 4
                Repeater {
                    model: {
                        const g = page.game, f = page.facts
                        if (!g) return []
                        const out = []
                        if (f && f.companies && f.companies.length) out.push([qsTr("Studio:"), f.companies[0]])
                        const bits = []
                        if (g.players) bits.push(page.playersText(g.players))
                        if (f && f.rating > 0) bits.push(qsTr("rated %1").arg(Math.round(f.rating)))
                        if (g.year > 0) out.push([qsTr("Released:"), [String(g.year)].concat(bits).join(" · ")])
                        else if (bits.length) out.push([qsTr("Players:"), bits.join(" · ")])
                        return out
                    }
                    Text {
                        required property var modelData
                        text: "<b>" + modelData[0] + "</b> " + modelData[1]
                        textFormat: Text.StyledText
                        color: Qt.rgba(1, 1, 1, 0.85)
                        font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold }
                    }
                }
            }
            // The fact sheet, in the summary's place.
            Grid {
                id: factGrid
                visible: page.infoShown
                width: parent.width
                columns: 2
                columnSpacing: 34
                Repeater {
                    model: page.factRows.slice(0, 2 * Math.max(3, Math.floor((textCol.room - titleText.height - btnRow.height - 60) / 40)))
                    Item {
                        required property var modelData
                        width: (factGrid.width - factGrid.columnSpacing) / 2
                        height: 40
                        Text {
                            id: fk
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.k
                            color: Qt.rgba(1, 1, 1, 0.7)
                            font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold }
                        }
                        Text {
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                            width: parent.width - fk.implicitWidth - 14
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                            text: modelData.v
                            color: theme.fg
                            font { family: theme.fontFamily; pixelSize: 16; weight: Font.ExtraBold }
                        }
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.14) }
                    }
                }
            }
            // What to know before playing: what is missing here, the file's note, the controller.
            Rectangle {
                id: note
                readonly property string text: {
                    const w = Needs.warnings(page.needs)
                    if (w.length) return "⚠ " + w[0]
                    if (page.fileNote && !page.fileNote.ok) return "⚠ " + CoreText.tr(page.fileNote.text)
                    if (page.deviceWanted !== "" && page.device === page.deviceWanted)
                        return Devices.wantedNote(page.deviceWanted, page.game ? page.game.platform_slug : "")
                    return ""
                }
                visible: text !== "" && !page.infoShown
                width: Math.min(parent.width, noteText.implicitWidth + 36)
                height: noteText.height + 22
                radius: 14
                color: Qt.rgba(0, 0, 0, 0.45)
                border { width: 1; color: Qt.rgba(1, 1, 1, 0.16) }
                Text {
                    id: noteText
                    x: 18; y: 11
                    width: Math.min(textCol.width - 36, implicitWidth)
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    text: note.text
                    color: theme.fg
                    font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
                }
            }
            // The buttons.
            Item { width: 1; height: 4 }
            Row {
                id: btnRow
                spacing: 14
                Repeater {
                    model: page.buttons
                    Item {
                        id: bt
                        required property var modelData
                        required property int index
                        readonly property bool on: page.zone === "buttons" && page.buttonIndex === index && !page.shotOpen
                        readonly property bool labelled: !!modelData.text
                        readonly property bool primary: !!modelData.primary
                        width: labelled ? btnLabel.implicitWidth + (modelData.icon ? 30 : 0) + 64 : 64
                        height: 64
                        scale: on ? 1.08 : 1
                        Behavior on scale { NumberAnimation { duration: 250 * theme.motion; easing.type: Easing.OutCubic } }
                        opacity: modelData.disabled ? 0.45 : 1
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData.label
                        Rectangle {
                            visible: bt.on
                            anchors { fill: parent; margins: -8 }
                            radius: height / 2
                            color: "transparent"
                            border { width: 4; color: theme.fg }
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            color: bt.primary || bt.on ? theme.fg : Qt.rgba(1, 1, 1, 0.18)
                            border { width: bt.primary || bt.on ? 0 : 1; color: Qt.rgba(1, 1, 1, 0.2) }
                            Behavior on color { ColorAnimation { duration: 200 * theme.motion } }
                        }
                        Row {
                            anchors.centerIn: parent
                            spacing: 10
                            Icon {
                                visible: bt.modelData.icon !== ""
                                anchors.verticalCenter: parent.verticalCenter
                                name: bt.modelData.icon
                                size: bt.labelled ? 20 : 24
                                filled: !!bt.modelData.filled
                                stroke: 2.2
                                color: bt.primary || bt.on ? "#121216" : theme.fg
                            }
                            Text {
                                id: btnLabel
                                visible: bt.labelled
                                anchors.verticalCenter: parent.verticalCenter
                                text: bt.modelData.text || ""
                                color: bt.primary || bt.on ? "#121216" : theme.fg
                                font { family: theme.fontFamily; pixelSize: 19; weight: Font.ExtraBold }
                            }
                        }
                    }
                }
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: page.zone === "buttons" ? (page.buttons[page.buttonIndex] ? page.buttons[page.buttonIndex].tip : "")
                    : page.zone === "box" ? qsTr("Turn the case with the arrows")
                    : page.shotOf(page.galleryIndex) < 0 ? qsTr("A to watch the video in full screen, with its sound")
                    : qsTr("Screenshot %1 of %2 · A to see it in large").arg(page.shotOf(page.galleryIndex) + 1).arg(page.shotCount)
                color: Qt.rgba(1, 1, 1, 0.75)
                font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
            }
        }

        // ---------- the case, in 3D ----------
        Item {
            id: caseArea
            x: body.leftX + body.textW + 40
            y: 120
            width: body.width - x - 100
            height: (page.galleryCount > 0 ? 760 : 940) - y
            Rectangle {
                visible: page.zone === "box"
                anchors { fill: parent; margins: 10 }
                radius: 24
                color: Qt.rgba(1, 1, 1, 0.06)
                border { width: 3; color: Qt.rgba(1, 1, 1, 0.5) }
            }
            // A slow sway while it is not being turned.
            property real sway
            SequentialAnimation on sway {
                loops: Animation.Infinite
                running: page.visible && page.zone !== "box" && !page.paused
                NumberAnimation { from: -9; to: 9; duration: 7000; easing.type: Easing.InOutSine }
                NumberAnimation { from: 9; to: -9; duration: 7000; easing.type: Easing.InOutSine }
            }
            Box3D {
                id: box3d
                anchors.fill: parent
                theme: page.theme
                game: page.game
                boxH: Math.min(480, parent.height - 110)
                yaw: page.caseYaw + (page.zone === "box" ? 0 : caseArea.sway)
                pitch: page.casePitch
                Behavior on yaw { enabled: page.zone === "box"; NumberAnimation { duration: 420 * theme.motion; easing.type: Easing.OutCubic } }
                Behavior on pitch { NumberAnimation { duration: 420 * theme.motion; easing.type: Easing.OutCubic } }
            }
        }

        // ---------- the gallery ----------
        Item {
            visible: page.galleryCount > 0
            x: body.leftX - 10; y: 772
            width: body.width - x - 90; height: 200
            Text {
                x: 10
                text: qsTr("Gallery")
                color: Qt.rgba(1, 1, 1, 0.8)
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
            }
            Item {
                y: 26
                width: parent.width; height: 174
                clip: true
                Row {
                    x: 10 - Math.max(0, (page.galleryIndex + 1) * 274 - (parent.width - 40))
                    y: 12
                    spacing: 18
                    Behavior on x { NumberAnimation { duration: 400 * theme.motion; easing.type: Easing.OutCubic } }
                    Repeater {
                        model: page.galleryCount
                        Item {
                            id: ga
                            required property int index
                            readonly property bool isVideo: page.shotOf(index) < 0
                            readonly property bool on: page.zone === "gallery" && page.galleryIndex === index && !page.shotOpen
                            width: 256; height: 144
                            scale: on ? 1.06 : 1
                            z: on ? 2 : 1
                            Behavior on scale { NumberAnimation { duration: 250 * theme.motion; easing.type: Easing.OutCubic } }
                            Accessible.role: Accessible.Button
                            Accessible.name: isVideo ? qsTr("Video") : qsTr("Screenshot %1").arg(page.shotOf(index) + 1)
                            Rectangle {
                                visible: ga.on
                                anchors { fill: parent; margins: -8 }
                                radius: 18
                                color: "transparent"
                                border { width: 4; color: theme.fg }
                            }
                            Item {
                                anchors.fill: parent
                                layer.enabled: true
                                layer.effect: MultiEffect { maskEnabled: true; maskSource: gaMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
                                Rectangle { anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.08) }
                                Image {
                                    anchors.fill: parent
                                    source: !page.game ? "" : ga.isVideo ? (page.has("fanart") ? page.game.art + "fanart" : page.has("backdrop") ? page.game.art + "backdrop" : page.game.cover)
                                            : page.shotBase + page.shotOf(ga.index)
                                    sourceSize: Qt.size(512, 288)
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                                Rectangle { anchors.fill: parent; visible: ga.isVideo; color: Qt.rgba(0, 0, 0, 0.35) }
                            }
                            Rectangle { id: gaMask; anchors.fill: parent; radius: 10; visible: false; layer.enabled: true }
                            Rectangle {
                                visible: ga.isVideo
                                anchors.centerIn: parent
                                width: 54; height: 54; radius: 27
                                color: Qt.rgba(0, 0, 0, 0.3)
                                border { width: 3; color: "#ffffff" }
                                Icon { anchors.centerIn: parent; anchors.horizontalCenterOffset: 2; name: "play"; size: 20; filled: true; stroke: 1.5; color: "#ffffff" }
                            }
                            Text {
                                visible: ga.isVideo
                                x: 12; anchors { bottom: parent.bottom; bottomMargin: 8 }
                                text: page.trailerState === "loading" ? qsTr("Video · loading…") : qsTr("Video")
                                color: "#ffffff"
                                font { family: theme.fontFamily; pixelSize: 14; weight: Font.ExtraBold }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------- a screenshot in large ----------
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.02, 0.02, 0.03, 0.94)
        opacity: page.shotOpen ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 300 * theme.motion } }
        Image {
            anchors { fill: parent; leftMargin: 160; rightMargin: 120; topMargin: 110; bottomMargin: 130 }
            source: page.shotOpen && page.shotOf(page.galleryIndex) >= 0 ? page.shotBase + page.shotOf(page.galleryIndex) : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            sourceSize.width: 1600
        }
    }
}
