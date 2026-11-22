// Game page: a sheet rising over the library. On the left the cover (at its own proportions) and
// what you can do (Play, Download, favourite, the game's settings); on the right what there is to
// know: the title (or the game's logo), the console and genres, counters (players' rating, your
// play time, last played, where the game is), the versions to choose from, the summary, a table
// of facts and the screenshots. The trailer, else the screenshots, play softly behind.
//
// Gamepad: up/down through the actions, right to the versions, down past the last action to the
// rest of the page (it scrolls), A to activate, B to go back.
import QtQuick
import QtQuick.Effects
import QtMultimedia
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

    signal action(string id, var payload)

    // Where the selection is: "actions" (the column under the cover), "version", "more".
    property string zone: "actions"
    property int actionIndex: 0
    property int versionIndex: 0

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

    // The counters: the players' rating (a ring), your time, the last time, where the game is.
    readonly property var counters: {
        const g = game
        if (!g) return []
        const out = []
        if (facts && facts.rating > 0) out.push({ ring: facts.rating / 100, big: String(Math.round(facts.rating)), label: qsTr("Players' rating"), small: qsTr("out of 100") })
        const h = (g.play_seconds || 0) / 3600
        out.push({ ring: -1, big: h >= 10 ? qsTr("%1 h").arg(Math.round(h)) : h >= 1 ? qsTr("%1 h").arg(Math.round(h * 10) / 10) : h > 0 ? qsTr("%1 min").arg(Math.max(1, Math.round(h * 60))) : "—", label: qsTr("Your play time"), small: h > 0 ? qsTr("on this profile") : qsTr("Not played yet") })
        out.push({ ring: -1, big: "", label: qsTr("Last played"), small: agoText(g.last_played) })
        const where = g.local_state === "local" ? qsTr("Installed") : g.linked ? qsTr("From the network") : qsTr("On the server")
        out.push({ ring: -1, big: "", label: where, small: fmtSize(g.fs_size) })
        return out
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

    // ---------- input ----------
    function reset() {
        zone = "actions"
        actionIndex = 0
        sound = false
        details.contentY = 0
        versionIndex = Math.max(0, playable.findIndex(v => game && v.rom_id === game.rom_id))
    }
    function scrollTo(y) {
        scrollAnim.to = Math.max(0, Math.min(details.contentHeight - details.height, y))
        scrollAnim.restart()
    }
    function handle(a) {
        if (a === "b") { page.action("back", null); return }
        if (a === "y" && actions.some(x => x.id === "settings")) { page.action("settings", null); return }
        if (zone === "actions") {
            if (a === "up") actionIndex = Math.max(0, actionIndex - 1)
            else if (a === "down") {
                if (actionIndex < actions.length - 1) actionIndex++
                else { zone = "more"; scrollTo(details.contentY + 360) }
            }
            else if (a === "right" && playable.length > 1) zone = "version"
            else if (a === "a") {
                const x = actions[actionIndex]
                if (x && !x.disabled) page.action(x.id, null)
            }
        } else if (zone === "version") {
            if (a === "left") { if (versionIndex > 0) versionIndex--; else zone = "actions" }
            else if (a === "right") versionIndex = Math.min(playable.length - 1, versionIndex + 1)
            else if (a === "up") zone = "actions"
            else if (a === "down") { zone = "more"; scrollTo(details.contentY + 360) }
            else if (a === "a") {
                const v = playable[versionIndex]
                if (v && game && v.rom_id !== game.rom_id) page.action("version", v.rom_id)
            }
        } else {
            if (a === "down") scrollTo(details.contentY + 360)
            else if (a === "up") { if (details.contentY > 4) scrollTo(details.contentY - 360); else zone = "actions" }
            else if (a === "left") zone = "actions"
        }
    }
    onActionsChanged: actionIndex = Math.min(actionIndex, Math.max(0, actions.length - 1))
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0

    // Screenshots one after the other behind the sheet when there is no trailer.
    property int shotIndex: 0
    Timer {
        interval: 7000; repeat: true
        running: page.visible && !page.paused && !page.videoShown && !!page.facts && page.facts.screenshots > 1
        onTriggered: page.shotIndex++
    }

    // ---------- trailer ----------
    function restartVideo() {
        delay.stop(); player.stop(); player.source = ""; videoShown = false; videoError = ""
        if (visible && trailers && !paused && trailerUrl !== "") delay.restart()
    }
    property bool videoShown: false
    property int shownRom: -1
    onGameChanged: {
        if (game && game.rom_id === shownRom) return
        shownRom = game ? game.rom_id : -1
        restartVideo()
    }
    onPausedChanged: restartVideo()
    onVisibleChanged: restartVideo()
    onTrailersChanged: restartVideo()
    onTrailerUrlChanged: restartVideo()
    Timer { id: delay; interval: 400; onTriggered: { player.source = page.trailerUrl; player.play() } }
    MediaPlayer {
        id: player
        videoOutput: video.output
        audioOutput: AudioOutput { muted: !page.sound; volume: 0.8 }
        loops: MediaPlayer.Infinite
        onErrorOccurred: (e, text) => page.videoError = text
    }
    property string videoError: ""
    Connections {
        target: video.videoSink
        function onVideoFrameChanged() { if (!page.videoShown && player.source.toString() !== "") page.videoShown = true }
    }

    // ---------- the sheet ----------
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: page.visible ? 0.5 : 0
        Behavior on opacity { NumberAnimation { duration: 400 } }
    }

    Rectangle {
        id: sheet
        x: 56; width: parent.width - 112
        height: parent.height - 124 - 84
        y: page.visible ? 124 : parent.height + 40
        Behavior on y { NumberAnimation { duration: 620 * theme.motion; easing.type: Easing.OutCubic } }
        radius: 36
        color: "#16171C"
        clip: true

        // Behind: the trailer, else the art or the screenshots, faded into the sheet.
        Item {
            id: media
            anchors { right: parent.right; top: parent.top }
            width: parent.width * 0.62; height: parent.height * 0.7
            Image {
                anchors.fill: parent
                source: page.has("fanart") ? page.game.art + "fanart" : page.has("backdrop") ? page.game.art + "backdrop"
                      : page.shotBase && page.facts && page.facts.screenshots > 0 ? page.shotBase + (page.shotIndex % page.facts.screenshots) : ""
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(1280, 720)
                opacity: status === Image.Ready && !page.videoShown ? 0.32 : 0
                Behavior on opacity { NumberAnimation { duration: 800 } }
            }
            GameVideo {
                id: video
                anchors.fill: parent
                opacity: page.videoShown ? 0.42 : 0
                Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
            }
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "#16171C" }
                    GradientStop { position: 0.45; color: Qt.rgba(0.086, 0.09, 0.11, 0.3) }
                    GradientStop { position: 1; color: Qt.rgba(0.086, 0.09, 0.11, 0) }
                }
            }
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.4; color: Qt.rgba(0.086, 0.09, 0.11, 0) }
                    GradientStop { position: 1; color: "#16171C" }
                }
            }
        }
        // A glow of the console's colour in the corner.
        Rectangle {
            x: sheet.width - 520; y: -360; width: 900; height: 900; radius: 450
            color: page.tint; opacity: 0.18
            layer.enabled: true
            layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 64 }
        }

        // ---------- left: the cover, then what you can do ----------
        Column {
            id: leftCol
            x: 80; y: 76
            width: 400
            spacing: 32
            Item {
                id: coverBox
                readonly property real ar: page.game && page.game.cover_ar >= 0.45 && page.game.cover_ar <= 2.2 ? page.game.cover_ar
                                           : page.game ? Cases.ratio(page.game.platform_slug) : 0.72
                readonly property real maxH: Math.max(240, sheet.height - 76 - 32 - page.actions.length * 82 - 90)
                width: Math.min(400, maxH * ar)
                height: width / ar
                anchors.horizontalCenter: parent.horizontalCenter
                Rectangle {
                    anchors { fill: parent; margins: -2 }
                    radius: 30
                    color: page.tint
                    opacity: 0.4
                    layer.enabled: true
                    layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 40 }
                }
                Item {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.effect: MultiEffect { maskEnabled: true; maskSource: coverMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
                    Rectangle { anchors.fill: parent; color: page.game ? theme.tone(page.game.hue) : theme.surface }
                    Text {
                        visible: coverImg.status !== Image.Ready
                        anchors { fill: parent; margins: 24 }
                        text: page.game ? page.game.name : ""
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        color: "#ffffff"
                        font { family: theme.displayFont; pixelSize: 30; weight: Font.ExtraBold }
                    }
                    Image {
                        id: coverImg
                        anchors.fill: parent
                        source: page.game ? page.game.cover : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.height: 900
                    }
                }
                Rectangle { id: coverMask; anchors.fill: parent; radius: 28; visible: false; layer.enabled: true }
            }
            Column {
                width: parent.width
                spacing: 16
                Repeater {
                    model: page.actions
                    PageButton {
                        required property var modelData
                        required property int index
                        width: leftCol.width
                        implicitHeight: modelData.primary ? 76 : modelData.detail ? 72 : 62
                        theme: page.theme
                        text: modelData.label
                        detail: modelData.detail || ""
                        key: modelData.primary ? "A" : modelData.key || ""
                        primary: !!modelData.primary
                        disabled: !!modelData.disabled
                        focused: page.zone === "actions" && page.actionIndex === index
                    }
                }
                Text {
                    width: parent.width
                    text: page.stateText()
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    color: page.game && page.game.dl_state === "failed" ? theme.bad : theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold }
                }
                Rectangle {
                    visible: page.busy
                    width: parent.width; height: 6; radius: 3
                    color: Qt.rgba(1, 1, 1, 0.15)
                    Rectangle {
                        height: parent.height; radius: 3; color: page.tint
                        width: parent.width * page.progress
                        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                    }
                }
            }
        }

        // ---------- right: everything there is to know (scrolls) ----------
        Flickable {
            id: details
            x: leftCol.x + leftCol.width + 110; y: 0
            width: sheet.width - x - 88; height: sheet.height
            contentHeight: info.height + 64 + 80
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            NumberAnimation { id: scrollAnim; target: details; property: "contentY"; duration: 320; easing.type: Easing.OutCubic }

            Column {
                id: info
                y: 76
                width: details.width
                spacing: 40

                // Console and genres.
                Flow {
                    width: parent.width
                    spacing: 10
                    Rectangle {
                        width: consoleChip.implicitWidth + 32; height: 36; radius: 18
                        color: Qt.rgba(page.tint.r, page.tint.g, page.tint.b, 0.25)
                        Text { id: consoleChip; anchors.centerIn: parent; text: page.game ? page.game.platform_short || page.game.platform_name : ""; color: Qt.lighter(page.tint, 1.5); font { family: theme.fontFamily; pixelSize: 15; weight: Font.ExtraBold } }
                    }
                    Repeater {
                        model: page.game ? page.game.genres.split(",").map(x => x.trim()).filter(x => x).slice(0, 4) : []
                        Rectangle {
                            required property string modelData
                            width: gText.implicitWidth + 32; height: 36; radius: 18
                            color: Qt.rgba(1, 1, 1, 0.08)
                            Text { id: gText; anchors.centerIn: parent; text: modelData; color: theme.fg; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold } }
                        }
                    }
                }
                // The game's own logo (ScreenScraper), else its name.
                Item {
                    width: parent.width
                    height: logo.status === Image.Ready ? Math.min(180, logo.paintedHeight) : title.height
                    Image {
                        id: logo
                        width: Math.min(parent.width, 680); height: 180
                        source: page.has("logo") ? page.game.art + "logo" : ""
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                        horizontalAlignment: Image.AlignLeft
                        verticalAlignment: Image.AlignBottom
                        y: parent.height - height
                        sourceSize: Qt.size(1200, 400)
                        visible: status === Image.Ready
                    }
                    Text {
                        id: title
                        visible: logo.status !== Image.Ready
                        width: parent.width
                        text: page.game ? page.game.name : ""
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        lineHeight: 0.92
                        color: theme.fg
                        font { family: theme.displayFont; pixelSize: page.game && page.game.name.length > 26 ? 64 : 88; weight: Font.ExtraBold; letterSpacing: -2 }
                    }
                }
                Text {
                    width: parent.width
                    text: page.game ? [page.facts && page.facts.companies && page.facts.companies.length ? page.facts.companies[0] : "",
                                       page.game.year > 0 ? String(page.game.year) : "", page.playersText(page.game.players)].filter(x => x).join("  ·  ") : ""
                    elide: Text.ElideRight
                    color: theme.fgSoft
                    font { family: theme.fontFamily; pixelSize: 20; weight: Font.DemiBold }
                }

                // The counters.
                Flow {
                    width: parent.width
                    spacing: 18
                    Repeater {
                        model: page.counters
                        Rectangle {
                            required property var modelData
                            width: cRow.implicitWidth + 40; height: 92; radius: 46
                            color: Qt.rgba(1, 1, 1, 0.06)
                            Row {
                                id: cRow
                                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                spacing: 14
                                Item {
                                    visible: modelData.big !== ""
                                    width: 68; height: 68
                                    anchors.verticalCenter: parent.verticalCenter
                                    // A ring for the rating, a plain disc for the others.
                                    Canvas {
                                        anchors.fill: parent
                                        property real ring: modelData.ring
                                        property color fill: page.tint
                                        onRingChanged: requestPaint()
                                        onPaint: {
                                            const c = getContext("2d")
                                            c.clearRect(0, 0, width, height)
                                            c.lineWidth = 7
                                            c.strokeStyle = "rgba(255,255,255,0.12)"
                                            c.beginPath(); c.arc(width / 2, height / 2, width / 2 - 4, 0, 2 * Math.PI); c.stroke()
                                            if (ring >= 0) {
                                                c.strokeStyle = fill
                                                c.lineCap = "round"
                                                c.beginPath(); c.arc(width / 2, height / 2, width / 2 - 4, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * ring); c.stroke()
                                            }
                                        }
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.big
                                        color: theme.fg
                                        font { family: theme.displayFont; pixelSize: modelData.big.length > 4 ? 16 : 21; weight: Font.ExtraBold }
                                    }
                                }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    leftPadding: modelData.big === "" ? 10 : 0
                                    spacing: 2
                                    Text { text: modelData.label; color: theme.fg; font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold } }
                                    Text { text: modelData.small; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 14; weight: Font.DemiBold } }
                                }
                            }
                        }
                    }
                }

                // A game that takes another controller than its console's usual one.
                Rectangle {
                    visible: page.deviceWanted !== "" && page.device === page.deviceWanted
                    width: parent.width
                    height: wantedText.height + 32
                    radius: 22
                    color: Qt.rgba(page.tint.r, page.tint.g, page.tint.b, 0.2)
                    Text {
                        id: wantedText
                        x: 24; y: 16
                        width: parent.width - 48
                        wrapMode: Text.WordWrap
                        text: Devices.wantedNote(page.deviceWanted, page.game ? page.game.platform_slug : "")
                        color: theme.fg
                        font { family: theme.fontFamily; pixelSize: 17; weight: Font.Bold }
                    }
                }

                // The versions of the game (regions, languages): the one chosen is launched.
                Column {
                    visible: page.playable.length > 1
                    width: parent.width
                    spacing: 12
                    Text { text: qsTr("Version"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 16; weight: Font.ExtraBold } }
                    Flow {
                        width: parent.width
                        spacing: 10
                        Repeater {
                            model: page.playable
                            Chip {
                                required property var modelData
                                required property int index
                                theme: page.theme
                                text: page.versionLabel(modelData)
                                detail: page.versionDetail(modelData)
                                selected: !!page.game && modelData.rom_id === page.game.rom_id
                                badge: modelData.local_state === "local" || modelData.linked
                                focused: page.zone === "version" && page.versionIndex === index
                            }
                        }
                    }
                }

                // What this console's games need that this computer lacks, the file's own note,
                // why playing from the network is off.
                Repeater {
                    model: Needs.warnings(page.needs)
                    Text {
                        required property string modelData
                        width: info.width
                        wrapMode: Text.WordWrap
                        text: "⚠ " + modelData
                        color: theme.badSoft
                        font { family: theme.fontFamily; pixelSize: 17 }
                    }
                }
                Text {
                    visible: !!page.fileNote
                    width: info.width
                    wrapMode: Text.WordWrap
                    text: page.fileNote ? (page.fileNote.ok ? "✓ " : "⚠ ") + CoreText.tr(page.fileNote.text) : ""
                    color: page.fileNote && !page.fileNote.ok ? theme.badSoft : theme.fgSoft
                    font { family: theme.fontFamily; pixelSize: 17 }
                }
                Text {
                    visible: !page.streamAvailable && page.streamError !== "" && page.actions.some(a => a.id === "link")
                    width: parent.width
                    text: qsTr("Playing from the network is unavailable here: %1").arg(page.streamError)
                    wrapMode: Text.WordWrap
                    color: theme.fgFaint
                    font { family: theme.fontFamily; pixelSize: 17 }
                }

                Text {
                    width: Math.min(parent.width, 1100)
                    text: page.longSummary || qsTr("No summary for this game yet.")
                    wrapMode: Text.WordWrap
                    lineHeight: 1.6
                    color: theme.fgSoft
                    font { family: theme.fontFamily; pixelSize: 20 }
                }

                // The facts, in two columns.
                Rectangle {
                    visible: page.factRows.length > 0
                    width: parent.width
                    height: factGrid.height + 32
                    radius: 30
                    color: Qt.rgba(1, 1, 1, 0.05)
                    Grid {
                        id: factGrid
                        x: 36; y: 16
                        width: parent.width - 72
                        columns: width > 900 ? 2 : 1
                        columnSpacing: 72
                        Repeater {
                            model: page.factRows
                            Item {
                                required property var modelData
                                width: (factGrid.width - (factGrid.columns - 1) * factGrid.columnSpacing) / factGrid.columns
                                height: Math.max(62, fv.implicitHeight + 32)
                                Text {
                                    id: fk
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.k
                                    color: theme.fgMuted
                                    font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold }
                                }
                                Text {
                                    id: fv
                                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                    width: parent.width - fk.implicitWidth - 24
                                    horizontalAlignment: Text.AlignRight
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    text: modelData.v
                                    color: theme.fg
                                    font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold }
                                }
                                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
                            }
                        }
                    }
                }

                // Screenshots.
                Flow {
                    visible: shotRep.count > 0
                    width: parent.width
                    spacing: 16
                    Repeater {
                        id: shotRep
                        model: page.facts ? Math.min(6, page.facts.screenshots) : 0
                        Item {
                            required property int index
                            width: (info.width - 32) / 3; height: width * 9 / 16
                            Item {
                                anchors.fill: parent
                                layer.enabled: true
                                layer.effect: MultiEffect { maskEnabled: true; maskSource: shotMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1 }
                                Rectangle { anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.06) }
                                Image {
                                    anchors.fill: parent
                                    source: page.shotBase ? page.shotBase + index : ""
                                    asynchronous: true
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize: Qt.size(640, 360)
                                }
                            }
                            Rectangle { id: shotMask; anchors.fill: parent; radius: 20; visible: false; layer.enabled: true }
                        }
                    }
                }
                Text {
                    text: qsTr("Source: RomM")
                    color: theme.fgFaint
                    font { family: theme.fontFamily; pixelSize: 15 }
                }
            }
        }
        // Trailer state, discreet, top right.
        Rectangle {
            visible: !page.videoShown && page.trailers && page.hasTrailer
            anchors { right: parent.right; rightMargin: 40; top: parent.top; topMargin: 32 }
            width: tl.implicitWidth + 44; height: 36; radius: 18
            color: Qt.rgba(0, 0, 0, 0.4)
            Icon { x: 14; anchors.verticalCenter: parent.verticalCenter; name: "play"; size: 12; filled: true; stroke: 1.5; color: theme.fg }
            Text {
                id: tl; x: 32; anchors.verticalCenter: parent.verticalCenter
                text: page.videoError !== "" ? qsTr("The trailer cannot be played: %1").arg(page.videoError)
                    : page.trailerState.startsWith("error") ? qsTr("Trailer unavailable: %1").arg(page.trailerState.substring(7))
                    : qsTr("Loading the trailer…")
                color: theme.fg; font { family: theme.fontFamily; pixelSize: 16 }
            }
        }
    }

    HintBar {
        anchors { right: parent.right; rightMargin: 96; bottom: parent.bottom; bottomMargin: 26 }
        theme: page.theme
        hints: [["A", qsTr("Select"), "a"], ["Y", qsTr("Game settings"), "y"], ["B", qsTr("Back"), "b"], ["▲ ▼", qsTr("More about the game"), "down"]]
    }
}
