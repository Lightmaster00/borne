// Game page: a glass window over the game's world. A header (the console, where it was opened
// from, the game's state), then the game's art in large with its name, a few lines about it and
// what you can do: Play (or Install), the heart (favourites), its settings (Y) and its fact sheet
// (i), which takes the summary's place. Under it, the gallery: the trailer first, then the
// screenshots; the art above follows the one selected.
//
// Gamepad: left / right through the buttons, down to the gallery, A to activate, Y for the game's
// settings, B to go back.
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
    property string consoleLogo: ""      // the console's logo (url), or ""
    property string consoleName: ""
    property string crumb: ""            // where the game was opened from

    signal action(string id, var payload)

    // Where the selection is: "buttons" or "gallery".
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
    // The gallery: the trailer (when there is one), then the screenshots.
    readonly property bool trailerItem: hasTrailer && trailers
    readonly property int shotCount: facts ? Math.min(8, facts.screenshots || 0) : 0
    readonly property int galleryCount: (trailerItem ? 1 : 0) + shotCount
    function shotOf(k) { return trailerItem ? k - 1 : k }
    // The art above: the screenshot selected in the gallery, else the game's fan art, else its
    // first screenshot.
    readonly property string heroArt: {
        if (!game) return ""
        if (zone === "gallery" && shotOf(galleryIndex) >= 0 && shotBase) return shotBase + shotOf(galleryIndex)
        if (has("fanart")) return game.art + "fanart"
        if (has("backdrop")) return game.art + "backdrop"
        return shotBase && shotCount > 0 ? shotBase + "0" : ""
    }
    readonly property bool trailerInHero: videoShown && !(zone === "gallery" && shotOf(galleryIndex) >= 0)
    // The footer's buttons (Main's footer shows them).
    readonly property var hints: {
        if (shotOpen) return [["◀ ▶", qsTr("Screenshots"), "right"], ["B", qsTr("Close"), "b"]]
        const h = []
        if (zone === "buttons") {
            const b = buttons[buttonIndex]
            if (b && !b.disabled) h.push(["A", b.label, "a"])
            if (galleryCount) h.push(["▼", qsTr("Gallery"), "down"])
        } else {
            h.push(["A", trailerItem && galleryIndex === 0 ? (sound ? qsTr("Sound off") : qsTr("Sound on")) : qsTr("View"), "a"])
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
    }
    function handle(a) {
        if (shotOpen) {
            if (a === "b" || a === "a") shotOpen = false
            else if (a === "left" && galleryIndex > (trailerItem ? 1 : 0)) galleryIndex--
            else if (a === "right" && galleryIndex < galleryCount - 1) galleryIndex++
            return
        }
        if (a === "b") { page.action("back", null); return }
        if (a === "y" && actions.some(x => x.id === "settings")) { page.action("settings", null); return }
        if (zone === "buttons") {
            if (a === "left") buttonIndex = Math.max(0, buttonIndex - 1)
            else if (a === "right") buttonIndex = Math.min(buttons.length - 1, buttonIndex + 1)
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
                if (shotOf(galleryIndex) < 0) {
                    // The trailer: its sound on or off (it starts if it was not playing).
                    if (!videoShown) restartVideo()
                    page.action("sound", !sound)
                } else shotOpen = true
            }
        }
    }
    onButtonsChanged: buttonIndex = Math.min(buttonIndex, Math.max(0, buttons.length - 1))
    onGalleryCountChanged: { if (galleryIndex >= galleryCount) galleryIndex = Math.max(0, galleryCount - 1); if (!galleryCount && zone === "gallery") zone = "buttons" }
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0

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

    // ---------- the window ----------
    Rectangle {
        id: glass
        x: 196; width: parent.width - x - 120
        y: 168; height: Math.min(820, parent.height - y - 112)
        radius: 42
        color: Qt.rgba(0.16, 0.16, 0.2, 0.55)
        border { width: 1; color: Qt.rgba(1, 1, 1, 0.18) }
        opacity: page.visible ? 1 : 0
        scale: page.visible ? 1 : 0.96
        Behavior on opacity { NumberAnimation { duration: 450 * theme.motion } }
        Behavior on scale { NumberAnimation { duration: 650 * theme.motion; easing.type: Easing.OutCubic } }
        layer.enabled: true
        layer.effect: MultiEffect { maskEnabled: true; maskSource: winMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
        readonly property real headH: 78
        readonly property real galleryH: page.galleryCount > 0 ? 276 : 0
        readonly property real heroH: height - headH - galleryH

        // ---------- header ----------
        Rectangle {
            width: parent.width; height: glass.headH
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.12) }
                GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0.04) }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.12) }
            Row {
                x: 30; anchors.verticalCenter: parent.verticalCenter
                spacing: 16
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: logoImg.status === Image.Ready ? Math.min(180, logoImg.paintedWidth) : nameChip.width
                    height: 40
                    Image {
                        id: logoImg
                        height: 40; width: 180
                        visible: status === Image.Ready
                        source: page.consoleLogo
                        sourceSize.height: 120
                        fillMode: Image.PreserveAspectFit
                        horizontalAlignment: Image.AlignLeft
                        asynchronous: true
                        layer.enabled: visible
                        layer.effect: MultiEffect { brightness: 1.0; saturation: -1.0 }
                    }
                    Rectangle {
                        id: nameChip
                        visible: logoImg.status !== Image.Ready
                        width: chipText.implicitWidth + 32; height: 40; radius: 12
                        color: Qt.rgba(page.tint.r, page.tint.g, page.tint.b, 0.35)
                        Text {
                            id: chipText
                            anchors.centerIn: parent
                            text: page.consoleName || (page.game ? page.game.platform_short : "")
                            color: "#ffffff"
                            font { family: theme.displayFont; pixelSize: 20; weight: Font.ExtraBold }
                        }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.crumb
                    color: Qt.rgba(1, 1, 1, 0.8)
                    font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold }
                }
            }
            Row {
                anchors { right: parent.right; rightMargin: 30; verticalCenter: parent.verticalCenter }
                spacing: 14
                Rectangle {
                    visible: page.busy
                    anchors.verticalCenter: parent.verticalCenter
                    width: 120; height: 6; radius: 3
                    color: Qt.rgba(1, 1, 1, 0.18)
                    Rectangle {
                        height: parent.height; radius: 3; color: theme.fg
                        width: parent.width * page.progress
                        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.stateText()
                    color: page.game && page.game.dl_state === "failed" ? theme.badSoft : Qt.rgba(1, 1, 1, 0.75)
                    font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold }
                }
            }
        }

        // ---------- the art, the name, what you can do ----------
        Item {
            id: hero
            y: glass.headH
            width: parent.width; height: glass.heroH
            clip: true
            Rectangle { anchors.fill: parent; color: page.game ? Qt.darker(theme.tone(page.game.hue), 1.6) : "#16171C" }
            // Two images that cross-fade as the art changes.
            Item {
                id: heroArt
                anchors.fill: parent
                property bool useA: true
                property string shown: ""
                Connections { target: page; function onHeroArtChanged() { heroArt.swap() } }
                Component.onCompleted: swap()
                function swap() {
                    if (page.heroArt === shown) return
                    shown = page.heroArt
                    if (useA) artB.source = page.heroArt; else artA.source = page.heroArt
                    useA = !useA
                }
                component HeroImage: Image {
                    property bool front: false
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 1600
                    opacity: front && status === Image.Ready ? 1 : 0
                    scale: front ? 1.04 : 1
                    Behavior on opacity { NumberAnimation { duration: 700 } }
                    Behavior on scale { NumberAnimation { duration: 6000; easing.type: Easing.OutQuad } }
                }
                HeroImage { id: artA; front: heroArt.useA }
                HeroImage { id: artB; front: !heroArt.useA }
            }
            GameVideo {
                id: video
                anchors.fill: parent
                opacity: page.trailerInHero ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
            }
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: Qt.rgba(0.03, 0.04, 0.063, 0.88) }
                    GradientStop { position: 0.4; color: Qt.rgba(0.03, 0.04, 0.063, 0.62) }
                    GradientStop { position: 0.72; color: Qt.rgba(0.03, 0.04, 0.063, 0) }
                }
            }
            // Trailer state, discreet, top right.
            Rectangle {
                visible: page.trailerItem && (!page.videoShown || page.videoError !== "")
                anchors { right: parent.right; rightMargin: 30; top: parent.top; topMargin: 24 }
                width: tl.implicitWidth + 44; height: 36; radius: 18
                color: Qt.rgba(0, 0, 0, 0.45)
                Icon { x: 14; anchors.verticalCenter: parent.verticalCenter; name: "play"; size: 12; filled: true; stroke: 1.5; color: theme.fg }
                Text {
                    id: tl; x: 32; anchors.verticalCenter: parent.verticalCenter
                    text: page.videoError !== "" ? qsTr("The trailer cannot be played: %1").arg(page.videoError)
                        : page.trailerState.startsWith("error") ? qsTr("Trailer unavailable: %1").arg(page.trailerState.substring(7))
                        : qsTr("Loading the trailer…")
                    color: theme.fg; font { family: theme.fontFamily; pixelSize: 15 }
                }
            }
            Rectangle {
                visible: page.trailerInHero
                anchors { right: parent.right; rightMargin: 30; top: parent.top; topMargin: 24 }
                width: 44; height: 44; radius: 22
                color: Qt.rgba(0, 0, 0, 0.45)
                Icon { anchors.centerIn: parent; name: page.sound ? "sound" : "mute"; size: 22; stroke: 2; color: theme.fg }
            }

            Column {
                id: textCol
                x: 80; y: 44
                width: Math.min(700, hero.width * 0.52)
                spacing: 14
                Text {
                    width: parent.width
                    text: page.game ? page.game.name : ""
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    lineHeight: 0.95
                    color: theme.fg
                    font { family: theme.displayFont; pixelSize: page.game && page.game.name.length > 22 ? 56 : 76; weight: Font.ExtraBold; letterSpacing: -2.5 }
                }
                // The summary and two lines of facts, or the fact sheet.
                Text {
                    visible: !page.infoShown
                    width: parent.width
                    text: page.longSummary || qsTr("No summary for this game yet.")
                    wrapMode: Text.WordWrap
                    maximumLineCount: Math.max(2, Math.floor((hero.height - 44 - 170 - 150) / 29))
                    elide: Text.ElideRight
                    lineHeight: 1.5
                    color: Qt.rgba(1, 1, 1, 0.9)
                    font { family: theme.fontFamily; pixelSize: 18 }
                }
                Column {
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
                            font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold }
                        }
                    }
                }
                Grid {
                    id: factGrid
                    visible: page.infoShown
                    width: parent.width
                    columns: 2
                    columnSpacing: 34
                    Repeater {
                        model: page.factRows.slice(0, 2 * Math.max(3, Math.floor((hero.height - 44 - 170 - 120) / 38)))
                        Item {
                            required property var modelData
                            width: (factGrid.width - factGrid.columnSpacing) / 2
                            height: 38
                            Text {
                                id: fk
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.k
                                color: Qt.rgba(1, 1, 1, 0.7)
                                font { family: theme.fontFamily; pixelSize: 15; weight: Font.DemiBold }
                            }
                            Text {
                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                width: parent.width - fk.implicitWidth - 14
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                                text: modelData.v
                                color: theme.fg
                                font { family: theme.fontFamily; pixelSize: 15; weight: Font.ExtraBold }
                            }
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.12) }
                        }
                    }
                }
                // What to know before playing: the controller it wants, what is missing here.
                Rectangle {
                    readonly property string note: {
                        const w = Needs.warnings(page.needs)
                        if (w.length) return "⚠ " + w[0]
                        if (page.fileNote && !page.fileNote.ok) return "⚠ " + CoreText.tr(page.fileNote.text)
                        if (page.deviceWanted !== "" && page.device === page.deviceWanted)
                            return Devices.wantedNote(page.deviceWanted, page.game ? page.game.platform_slug : "")
                        return ""
                    }
                    visible: note !== ""
                    width: Math.min(parent.width, noteText.implicitWidth + 32)
                    height: noteText.height + 20
                    radius: 16
                    color: Qt.rgba(1, 1, 1, 0.12)
                    Text {
                        id: noteText
                        x: 16; y: 10
                        width: Math.min(textCol.width - 32, implicitWidth)
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        text: parent.note
                        color: theme.fg
                        font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold }
                    }
                }
            }

            // The buttons, at the foot of the art.
            Row {
                id: btnRow
                x: 80
                anchors { bottom: parent.bottom; bottomMargin: 36 }
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
                        width: labelled ? btnLabel.implicitWidth + (modelData.icon ? 30 : 0) + 60 : 60
                        height: 60
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
                            radius: 30
                            color: bt.primary || bt.on ? theme.fg : Qt.rgba(1, 1, 1, 0.16)
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
                                font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
                            }
                        }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    leftPadding: 10
                    width: Math.min(implicitWidth, hero.width - btnRow.x - 40 - x)
                    elide: Text.ElideRight
                    text: page.zone === "buttons" ? (page.buttons[page.buttonIndex] ? page.buttons[page.buttonIndex].tip : "")
                        : page.shotOf(page.galleryIndex) < 0 ? (page.sound ? qsTr("A to turn the sound off") : qsTr("A to hear the trailer"))
                        : qsTr("Screenshot %1 of %2 · A to see it in large").arg(page.shotOf(page.galleryIndex) + 1).arg(page.shotCount)
                    color: Qt.rgba(1, 1, 1, 0.8)
                    font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold }
                }
            }
        }

        // ---------- the gallery ----------
        Rectangle {
            visible: page.galleryCount > 0
            y: glass.headH + glass.heroH
            width: parent.width; height: glass.galleryH
            color: Qt.rgba(0.12, 0.12, 0.16, 0.45)
            Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.12) }
            Text {
                x: 30; y: 22
                text: qsTr("Gallery")
                color: theme.fg
                font { family: theme.displayFont; pixelSize: 28; weight: Font.ExtraBold; letterSpacing: -0.6 }
            }
            Item {
                x: 20; y: 64
                width: parent.width - 40; height: 190
                clip: true
                Row {
                    x: 10 - Math.max(0, (page.galleryIndex + 1) * 280 - (parent.width - 40))
                    y: 16
                    spacing: 18
                    Behavior on x { NumberAnimation { duration: 400 * theme.motion; easing.type: Easing.OutCubic } }
                    Repeater {
                        model: page.galleryCount
                        Item {
                            id: ga
                            required property int index
                            readonly property bool isTrailer: page.shotOf(index) < 0
                            readonly property bool on: page.zone === "gallery" && page.galleryIndex === index && !page.shotOpen
                            width: 262; height: 150
                            scale: on ? 1.06 : 1
                            z: on ? 2 : 1
                            Behavior on scale { NumberAnimation { duration: 250 * theme.motion; easing.type: Easing.OutCubic } }
                            Accessible.role: Accessible.Button
                            Accessible.name: isTrailer ? qsTr("Trailer") : qsTr("Screenshot %1").arg(page.shotOf(index) + 1)
                            Rectangle {
                                visible: ga.on
                                anchors { fill: parent; margins: -9 }
                                radius: 29
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
                                    source: !page.game ? "" : ga.isTrailer ? (page.has("fanart") ? page.game.art + "fanart" : page.has("backdrop") ? page.game.art + "backdrop" : page.game.cover)
                                            : page.shotBase + page.shotOf(ga.index)
                                    sourceSize: Qt.size(524, 300)
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                                Rectangle { anchors.fill: parent; visible: ga.isTrailer; color: Qt.rgba(0, 0, 0, 0.3) }
                            }
                            Rectangle { id: gaMask; anchors.fill: parent; radius: 20; visible: false; layer.enabled: true }
                            Rectangle {
                                visible: ga.isTrailer
                                anchors.centerIn: parent
                                width: 56; height: 56; radius: 28
                                color: Qt.rgba(0, 0, 0, 0.3)
                                border { width: 3; color: "#ffffff" }
                                Icon { anchors.centerIn: parent; anchors.horizontalCenterOffset: 2; name: "play"; size: 20; filled: true; stroke: 1.5; color: "#ffffff" }
                            }
                            Rectangle {
                                visible: ga.isTrailer
                                x: 12; anchors { bottom: parent.bottom; bottomMargin: 10 }
                                width: trText.implicitWidth + 20; height: 24; radius: 12
                                color: "transparent"
                                border { width: 2; color: Qt.rgba(1, 1, 1, 0.85) }
                                Text {
                                    id: trText
                                    anchors.centerIn: parent
                                    text: qsTr("Trailer")
                                    color: "#ffffff"
                                    font { family: theme.fontFamily; pixelSize: 13; weight: Font.ExtraBold }
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
                anchors { fill: parent; margins: 30 }
                source: page.shotOpen && page.shotOf(page.galleryIndex) >= 0 ? page.shotBase + page.shotOf(page.galleryIndex) : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                sourceSize.width: 1600
            }
        }
    }
    Rectangle { id: winMask; width: glass.width; height: glass.height; radius: glass.radius; visible: false; layer.enabled: true }
}
