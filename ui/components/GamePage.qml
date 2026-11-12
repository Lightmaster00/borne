// Game page, laid out like a film poster: the trailer (or the game's artwork) across the screen,
// the game's logo, its actions and the languages it really exists in on the left, its case in 3D
// on the right. Choosing a language chooses the version that is launched (French → the European
// version that has French, Japanese → the Japanese one…). Below: about, screenshots, studios and
// series (RomM).
//
// Gamepad: up/down between rows (actions, language, then the rest of the page),
// left/right inside a row, A to activate, B to go back.
import QtQuick
import QtQuick.Effects
import QtMultimedia

Item {
    id: page
    property QtObject theme
    property var game: null            // shown version, as a library row (cover, trailer, states…)
    property var versions: []          // every version of the game (raw API rows)
    property string emuLanguage: "auto"
    property var gameLanguages: []     // [{ code, version }]: the game's real languages
    property string uiLang: "en"
    property real boxYaw: 0
    property real boxPitch: 0
    property bool boxTurning: false
    property string installMode: "download"
    property bool streamAvailable: false
    property string streamError: ""
    property bool trailers: true
    property string trailerUrl: ""         // local file prepared by the core
    property string trailerState: ""       // "", "loading", "ready", "error: …"
    property bool paused: false
    property var facts: null           // GET /api/v1/games/<id>/facts
    property string shotBase: ""       // URL prefix of the screenshots (…/screenshots/)
    property bool sound: false

    signal action(string id, var payload)

    property int row: 0
    property var col: [0, 0]

    readonly property bool busy: game !== null && ["queued", "downloading", "verifying", "extracting"].indexOf(game.dl_state) >= 0
    readonly property var rows: gameLanguages.length > 0 ? ["actions", "language", "more"] : ["actions", "more"]
    readonly property bool hasTrailer: !!(game && game.trailer)

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
        if (g.local_state === "local") return [{ id: "play", label: qsTr("Play"), primary: true }, { id: "cheats", label: qsTr("Cheats") }, { id: "display", label: qsTr("Display") }, { id: "delete", label: qsTr("Delete from this device") }]
        if (g.linked) return [{ id: "play", label: qsTr("Play"), primary: true }, { id: "cheats", label: qsTr("Cheats") }, { id: "display", label: qsTr("Display") }, { id: "unlink", label: qsTr("Remove from the network mount") }]
        if (g.local_state === "missing") return [{ id: "download", label: qsTr("Download again"), primary: true }, { id: "delete", label: qsTr("Forget the local copy") }]
        const dl = { id: "download", label: qsTr("Download · %1").arg(fmtSize(g.fs_size)) }
        const net = { id: "link", label: qsTr("Play from the network"), disabled: !streamAvailable }
        if (installMode === "stream" && streamAvailable) { net.primary = true; return [net, dl] }
        dl.primary = true
        return [dl, net]
    }
    // The secondary actions: shown in the row when there is room, else behind "More…".
    readonly property var moreActions: {
        let a = []
        if (game && !busy) a.push({ id: "fav", label: game.favourite ? qsTr("Remove from favourites") : qsTr("Add to favourites") })
        if (game && !busy) a.push({ id: "images", label: qsTr("Images") })
        if (hasTrailer && trailers) a.push({ id: "sound", label: page.sound ? qsTr("Mute the trailer") : qsTr("Trailer sound") })
        return a
    }
    readonly property var allActions: actions.length + moreActions.length <= 5 ? actions.concat(moreActions)
                                    : actions.concat([{ id: "more", label: qsTr("More…") }])

    // Credits: from RomM (studios, series), with the year and the number of players.
    readonly property var credits: {
        const out = []
        const add = (label, list) => { if (list && list.length) out.push([label, list.join(", ")]) }
        if (facts) add(qsTr("Studios"), facts.companies)
        if (facts) add(qsTr("Series"), facts.franchises)
        if (game && game.year > 0) out.push([qsTr("Released"), String(game.year)])
        if (game && game.players) out.push([qsTr("Players"), game.players])
        return out
    }
    readonly property string longSummary: game && game.summary ? game.summary : ""
    readonly property bool factsLoading: false
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
    function versionOf(romId) { return versions.find(v => v.rom_id === romId) || null }
    function regionShort(v) {
        const map = { Europe: "EU", USA: "US", Japan: "JP", World: "W", France: "FR", Germany: "DE", Spain: "ES", Italy: "IT", UK: "UK",
                      Australia: "AU", Brazil: "BR", Korea: "KR", China: "CN", Canada: "CA", Netherlands: "NL" }
        return v ? (v.regions || "").split(",").map(x => x.trim()).filter(x => x).map(r => map[r] || r).join("/") : ""
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
    function langCode(name) {
        const map = { English: "EN", French: "FR", German: "DE", Spanish: "ES", Italian: "IT", Japanese: "JA", Dutch: "NL",
                      Portuguese: "PT", Swedish: "SV", Danish: "DA", Norwegian: "NO", Finnish: "FI", Korean: "KO", Chinese: "ZH", Russian: "RU", Polish: "PL" }
        return map[name] || name.substring(0, 2).toUpperCase()
    }
    function versionTitle(v) {
        const regions = (v.regions || "").split(",").map(x => x.trim()).filter(x => x).map(regionName)
        let t = regions.length ? regions.join(" / ") : qsTr("Version %1").arg(versions.indexOf(v) + 1)
        if (v.revision) t += " · " + qsTr("Rev. %1").arg(v.revision)
        return t
    }
    function versionDetail(v) {
        return (v.langs || []).map(langCode).join(" ")
    }
    function stateText() {
        const g = game
        if (!g) return ""
        const dl = g.dl_state
        if (dl === "queued") return qsTr("Waiting to download")
        if (dl === "downloading") return qsTr("Downloading… %1%").arg(g.dl_total > 0 ? Math.round(100 * g.dl_received / g.dl_total) : 0)
        if (dl === "verifying") return qsTr("Verifying files…")
        if (dl === "extracting") return qsTr("Extracting…")
        if (dl === "failed") return qsTr("Download failed: %1").arg(g.dl_error || "")
        if (g.local_state === "local") return qsTr("Installed on this device")
        if (g.linked) return qsTr("Played from the network: nothing stored on this device")
        if (g.local_state === "missing") return qsTr("Local files not found")
        return qsTr("On RomM · %1").arg(fmtSize(g.fs_size))
    }

    // ---------- input ----------
    function reset() {
        row = 0
        sound = false
        body.contentY = 0
        col = [0, Math.max(0, gameLanguages.findIndex(l => l.code === currentLang))]
    }
    function rowItems(name) { return name === "actions" ? allActions : name === "language" ? gameLanguages : [] }
    function setCol(r, c) { const n = col.slice(); n[r] = c; col = n }
    function activate(name, i) {
        if (name === "actions") {
            const a = allActions[i]
            if (!a || a.disabled) return
            if (a.id === "sound") sound = !sound
            else if (a.id === "more") page.action("more", moreActions)
            else page.action(a.id, null)
        } else if (name === "language") {
            const l = gameLanguages[i]
            if (l) page.action("lang", l)
        }
    }
    function scrollTo(y) {
        scrollAnim.to = Math.max(0, Math.min(body.contentHeight - body.height, y))
        scrollAnim.restart()
    }
    function handle(a) {
        const name = rows[Math.min(row, rows.length - 1)]
        const idx = name === "actions" ? 0 : 1
        const n = rowItems(name).length
        if (name === "more" && (a === "up" || a === "down")) {
            // The rest of the page: scroll, and go back to the choices from the top.
            if (a === "down") scrollTo(body.contentY + 420)
            else if (body.contentY > hero.height - 120) scrollTo(body.contentY - 420)
            else row = row - 1
            return
        }
        if (a === "up") row = Math.max(0, row - 1)
        else if (a === "down") row = Math.min(rows.length - 1, row + 1)
        else if (a === "left" && name !== "more") setCol(idx, Math.max(0, col[idx] - 1))
        else if (a === "right" && name !== "more") setCol(idx, Math.min(n - 1, col[idx] + 1))
        else if (a === "a" && name !== "more") activate(name, col[idx])
        else if (a === "b") page.action("back", null)
    }
    onAllActionsChanged: setCol(0, Math.min(col[0], Math.max(0, allActions.length - 1)))
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0
    onRowChanged: {
        const name = rows[row]
        if (name === "actions") scrollTo(0)
        else if (name === "language") scrollTo(0)
        else if (name === "more") scrollTo(hero.height - 160)
    }
    NumberAnimation { id: scrollAnim; target: body; property: "contentY"; duration: 260; easing.type: Easing.OutCubic }

    // Slideshow of the screenshots behind the title when the game has no other picture.
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
    onGameChanged: { restartVideo(); boxModel.clear(); if (game) boxModel.append(game) }
    onPausedChanged: restartVideo()
    onVisibleChanged: restartVideo()
    onTrailersChanged: restartVideo()
    onTrailerUrlChanged: restartVideo()
    Timer { id: delay; interval: 400; onTriggered: { player.source = page.trailerUrl; player.play() } }
    MediaPlayer {
        id: player
        videoOutput: video
        audioOutput: AudioOutput { muted: !page.sound; volume: 0.8 }
        loops: MediaPlayer.Infinite
        onErrorOccurred: (e, text) => page.videoError = text
    }
    property string videoError: ""
    Connections {
        target: video.videoSink
        function onVideoFrameChanged() { if (!page.videoShown && player.source.toString() !== "") page.videoShown = true }
    }

    // Swallow clicks so the library underneath never receives them.

    ListModel { id: boxModel }

    Flickable {
        id: body
        anchors.fill: parent
        contentHeight: content.height + 140
        boundsBehavior: Flickable.StopAtBounds
        interactive: false
        flickDeceleration: 4000

        Item {
            id: content
            width: body.width
            height: lower.y + lower.height

            // ---------- hero: trailer or artwork, logo, actions, languages, the case ----------
            Item {
                id: hero
                width: parent.width
                height: Math.max(760, page.height * 0.8)
                clip: true
                Image {
                    id: backdrop
                    anchors.fill: parent
                    // The game's art without text first (ScreenScraper), else RomM's artwork.
                    // Without any art: the screenshots, one after the other.
                    source: page.has("marquee") ? page.game.art + "marquee" : page.has("steamgrid") ? page.game.art + "steamgrid"
                          : page.has("backdrop") ? page.game.art + "backdrop"
                          : page.shotBase && page.facts && page.facts.screenshots > 0 ? page.shotBase + (page.shotIndex % page.facts.screenshots) : ""
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(1920, 1080)
                    opacity: status === Image.Ready && !page.videoShown ? 0.7 : 0
                    Behavior on opacity { NumberAnimation { duration: 700 } }
                    property real drift       // driven by the animation below
                    scale: Math.max(1.03, drift)
                    SequentialAnimation on drift {
                        loops: Animation.Infinite
                        running: page.visible && !page.paused
                        NumberAnimation { from: 1.03; to: 1.1; duration: 26000; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.1; to: 1.03; duration: 26000; easing.type: Easing.InOutSine }
                    }
                }
                VideoOutput {
                    id: video
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectCrop
                    opacity: page.videoShown ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
                }
                // Scrims: the left side for the text, the bottom into the page.
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Qt.rgba(0.047, 0.051, 0.063, 0.92) }
                        GradientStop { position: 0.45; color: Qt.rgba(0.047, 0.051, 0.063, 0.45) }
                        GradientStop { position: 0.75; color: Qt.rgba(0.047, 0.051, 0.063, 0.1) }
                        GradientStop { position: 1.0; color: Qt.rgba(0.047, 0.051, 0.063, 0.3) }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(0.047, 0.051, 0.063, 0.45) }
                        GradientStop { position: 0.22; color: "transparent" }
                        GradientStop { position: 0.62; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.rgba(0.047, 0.051, 0.063, 1.0) }
                    }
                }

                // The case, rebuilt from its scans, turning round now and then to show its spine and back.
                ShelfView {
                    id: caseStage
                    width: 620; height: 640
                    x: parent.width - 96 - 520
                    y: (parent.height - height) / 2 + 20
                    theme: page.theme
                    games: boxModel
                    currentIndex: 0
                    showSelection: false
                    scale: 1.2
                    swayAmp: 6
                    swayPeriod: 5000
                    userYaw: page.boxYaw
                    userPitch: page.boxPitch
                    opacity: page.videoShown ? 0.0 : 1
                    Behavior on opacity { NumberAnimation { duration: 600 } }
                }

                // Trailer state, discreet, top right.
                Rectangle {
                    visible: !page.videoShown && page.trailers && page.hasTrailer
                    anchors { right: parent.right; rightMargin: 96; top: parent.top; topMargin: 48 }
                    width: tl.implicitWidth + 44; height: 36; radius: 18
                    color: theme.glass
                    border { width: 1; color: theme.glassEdge }
                    Icon { x: 14; anchors.verticalCenter: parent.verticalCenter; name: "play"; size: 12; filled: true; stroke: 1.5; color: theme.fg }
                    Text {
                        id: tl; x: 32; anchors.verticalCenter: parent.verticalCenter
                        text: page.videoError !== "" ? qsTr("The trailer cannot be played: %1").arg(page.videoError)
                            : page.trailerState.startsWith("error") ? qsTr("Trailer unavailable: %1").arg(page.trailerState.substring(7))
                            : qsTr("Loading the trailer…")
                        color: theme.fg; font { family: theme.fontFamily; pixelSize: 15 }
                    }
                }

                Column {
                    id: info
                    x: 96
                    anchors { bottom: parent.bottom; bottomMargin: 56 }
                    width: Math.min(1100, hero.width - 96 - 96 - (caseStage.opacity > 0.5 ? 560 : 0))
                    spacing: 22

                    // The game's own logo (RomM / ScreenScraper), else its name.
                    Item {
                        width: parent.width
                        height: logo.status === Image.Ready ? Math.min(230, logo.paintedHeight) : title.height
                        Image {
                            id: logo
                            width: Math.min(parent.width, 760); height: 230
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
                            lineHeight: 0.95
                            color: theme.fg
                            font { family: theme.displayFont; pixelSize: page.game && page.game.name.length > 24 ? 64 : 84; weight: Font.ExtraBold; letterSpacing: -2 }
                        }
                    }
                    Text {
                        width: parent.width
                        text: page.game ? [page.game.platform_name, page.game.year > 0 ? page.game.year : "", page.game.genres.split(",")[0],
                                           page.game.players ? (/^\d+$/.test(page.game.players) ? qsTr("%n player(s)", "", Number(page.game.players)) : qsTr("%1 players").arg(page.game.players)) : ""].filter(x => x).join("  ·  ") : ""
                        elide: Text.ElideRight
                        color: theme.fgSoft
                        font { family: theme.fontFamily; pixelSize: 20; weight: Font.Medium }
                    }
                    Row {
                        spacing: 14
                        Repeater {
                            model: page.allActions
                            PageButton {
                                required property var modelData
                                required property int index
                                implicitHeight: 64
                                theme: page.theme
                                text: modelData.label
                                key: modelData.primary ? "A" : ""
                                primary: !!modelData.primary
                                disabled: !!modelData.disabled
                                focused: page.rows[page.row] === "actions" && page.col[0] === index
                            }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            leftPadding: 10
                            spacing: 8
                            Text {
                                text: page.stateText()
                                width: Math.min(implicitWidth, 420)
                                elide: Text.ElideRight
                                color: page.game && page.game.dl_state === "failed" ? theme.bad : theme.fgMuted
                                font { family: theme.fontFamily; pixelSize: 16 }
                            }
                            Rectangle {
                                visible: page.busy
                                width: 300; height: 4; radius: 2
                                color: Qt.rgba(1, 1, 1, 0.2)
                                Rectangle {
                                    height: parent.height; radius: 2; color: theme.fg
                                    width: parent.width * page.progress
                                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                                }
                            }
                        }
                    }
                    // Languages the game exists in; each one launches its version.
                    Row {
                        visible: page.gameLanguages.length > 0
                        spacing: 16
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Language")
                            color: theme.fgMuted
                            font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold }
                        }
                        Flow {
                            width: info.width - 140
                            spacing: 10
                            Repeater {
                                model: page.gameLanguages
                                Chip {
                                    required property var modelData
                                    required property int index
                                    readonly property var v: page.versionOf(modelData.version)
                                    theme: page.theme
                                    text: page.languageName(modelData.code)
                                    detail: page.regionShort(v)
                                    selected: modelData.code === page.currentLang
                                    badge: !!v && (v.local_state === "local" || v.linked)
                                    focused: page.rows[page.row] === "language" && page.col[1] === index
                                }
                            }
                        }
                    }
                    Text {
                        visible: !page.streamAvailable && page.streamError !== "" && page.actions.some(a => a.id === "link")
                        width: parent.width
                        text: qsTr("Playing from the network is unavailable here: %1").arg(page.streamError)
                        wrapMode: Text.WordWrap
                        color: theme.fgFaint
                        font { family: theme.fontFamily; pixelSize: 15 }
                    }
                }
            }

            // ---------- below: about and screenshots | credits ----------
            Rectangle {
                y: hero.height
                width: parent.width
                height: lower.height + 400
                color: Qt.rgba(0.047, 0.051, 0.063, 1)
            }
            Row {
                id: lower
                x: 96; y: hero.height + 8
                width: parent.width - 192
                spacing: 72
                readonly property real rightW: Math.min(620, width * 0.36)

                // Cards, as in the redesign: rounded, with an ink shadow.
                Item {
                    width: lower.width - lower.rightW - lower.spacing
                    height: aboutCol.height + 72
                    Ink { theme: page.theme; radius: 30 }
                    Rectangle { anchors.fill: parent; radius: 30; color: Qt.rgba(0.11, 0.11, 0.14, 1) }
                Column {
                    id: aboutCol
                    x: 40; y: 36
                    width: parent.width - 80
                    spacing: 22
                    Text { text: qsTr("About"); color: theme.fg; font { family: theme.displayFont; pixelSize: 28; weight: Font.Bold } }
                    Text {
                        width: Math.min(parent.width, 900)
                        text: page.longSummary || qsTr("No summary for this game yet.")
                        wrapMode: Text.WordWrap
                        lineHeight: 1.5
                        color: theme.fgSoft
                        font { family: theme.fontFamily; pixelSize: 20 }
                    }
                    Item { width: 1; height: 10 }
                    Text {
                        visible: shotGrid.count > 0
                        text: qsTr("Screenshots"); color: theme.fg
                        font { family: theme.displayFont; pixelSize: 28; weight: Font.Bold }
                    }
                    Flow {
                        width: parent.width
                        spacing: 16
                        Repeater {
                            id: shotGrid
                            model: page.facts ? Math.min(6, page.facts.screenshots) : 0
                            Rectangle {
                                required property int index
                                width: (parent.width - 32) / 3; height: width * 9 / 16; radius: 20
                                color: theme.glass
                                Ink { z: -1; theme: page.theme; radius: 20 }
                                Image {
                                    layer.enabled: true
                                    layer.effect: MultiEffect { maskEnabled: true; maskSource: shotMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1 }
                                    anchors.fill: parent
                                    source: page.shotBase ? page.shotBase + parent.index : ""
                                    asynchronous: true
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize: Qt.size(640, 360)
                                }
                                Rectangle { id: shotMask; anchors.fill: parent; radius: 20; visible: false; layer.enabled: true }
                            }
                        }
                    }
                }
                }

                Item {
                    width: lower.rightW
                    height: credits.height + 72
                    Ink { theme: page.theme; radius: 30 }
                    Rectangle { anchors.fill: parent; radius: 30; color: Qt.rgba(0.11, 0.11, 0.14, 1) }
                Column {
                    id: credits
                    x: 36; y: 36
                    width: parent.width - 72
                    spacing: 18
                    Text { text: qsTr("Credits"); color: theme.fg; font { family: theme.displayFont; pixelSize: 28; weight: Font.Bold } }
                    Repeater {
                        model: page.credits
                        Row {
                            required property var modelData
                            width: credits.width
                            spacing: 20
                            Text { width: 170; text: modelData[0]; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 17 } }
                            Text { width: parent.width - 190; text: modelData[1]; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight; color: theme.fg; font { family: theme.fontFamily; pixelSize: 18; weight: Font.Medium } }
                        }
                    }
                    Text {
                        visible: page.factsLoading && page.credits.length === 0
                        text: qsTr("Looking up the credits…")
                        color: theme.fgMuted
                        font { family: theme.fontFamily; pixelSize: 17 }
                    }
                    Text {
                        text: qsTr("Source: RomM")
                        color: theme.fgFaint
                        font { family: theme.fontFamily; pixelSize: 14 }
                    }
                }
                }
            }
        }
    }

    // ---------- back, hints ----------
    Rectangle {
        x: 96; y: 44 - body.contentY
        visible: y > -60
        width: backRow.implicitWidth + 24; height: 44
        radius: 22
        color: theme.glass
        border { width: 1; color: theme.glassEdge }
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Back to the library")
        Row {
            id: backRow
            anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 10
            Rectangle {
                width: 32; height: 32; radius: 16; color: "#FF6B6B"
                Text { anchors.centerIn: parent; text: "B"; color: theme.bg; font { family: theme.displayFont; pixelSize: 15; weight: Font.Bold } }
            }
            Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Library"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 17; weight: Font.Medium } }
        }
    }
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 150
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0.047, 0.051, 0.063, 0.0) }
            GradientStop { position: 0.55; color: Qt.rgba(0.047, 0.051, 0.063, 0.92) }
            GradientStop { position: 1.0; color: Qt.rgba(0.047, 0.051, 0.063, 0.98) }
        }
    }
    HintBar {
        x: 84; anchors { bottom: parent.bottom; bottomMargin: 24 }
        theme: page.theme
        hints: [["A", qsTr("Select"), "a"], ["B", qsTr("Back"), "b"], ["▲ ▼", qsTr("More about the game"), "down"]]
    }
}
