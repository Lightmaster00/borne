// Game page: opened from the library before anything is downloaded. Shows the game, lets the
// player choose the version (region / languages) and the language the emulator starts in,
// then download it, play it from the network (Borne virtual mount) or manage the local copy.
//
// The trailer plays across the top of the page; below come the choices, the credits and the
// anecdotes (Wikidata, Wikipedia), and the screenshots (RomM).
//
// Gamepad: up/down between rows (actions, versions, language, then the rest of the page),
// left/right inside a row, A to activate, B to go back. Mouse and wheel: everything works.
import QtQuick
import QtQuick.Effects
import QtMultimedia

Item {
    id: page
    property QtObject theme
    property var game: null            // shown version, as a library row (cover, trailer, states…)
    property var versions: []          // every version of the game (raw API rows)
    property string emuLanguage: "auto"
    property var emuLanguages: []
    property string installMode: "download"
    property bool streamAvailable: false
    property string streamError: ""
    property bool pointerActive: false
    property bool trailers: true
    property string trailerUrl: ""         // local file prepared by the core
    property string trailerState: ""       // "", "loading", "ready", "error: …"
    property bool paused: false
    property var facts: null           // GET /api/v1/games/<id>/facts
    property string shotBase: ""       // URL prefix of the screenshots (…/screenshots/)
    property bool sound: false

    signal action(string id, var payload)

    property int row: 0
    property var col: [0, 0, 0]

    readonly property bool busy: game !== null && ["queued", "downloading", "verifying", "extracting"].indexOf(game.dl_state) >= 0
    readonly property var rows: versions.length > 1 ? ["actions", "versions", "language", "more"] : ["actions", "language", "more"]
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
        if (g.local_state === "local") return [{ id: "play", label: qsTr("Play"), primary: true }, { id: "delete", label: qsTr("Delete from this device") }]
        if (g.linked) return [{ id: "play", label: qsTr("Play"), primary: true }, { id: "unlink", label: qsTr("Remove from the network mount") }]
        if (g.local_state === "missing") return [{ id: "download", label: qsTr("Download again"), primary: true }, { id: "delete", label: qsTr("Forget the local copy") }]
        const dl = { id: "download", label: qsTr("Download · %1").arg(fmtSize(g.fs_size)) }
        const net = { id: "link", label: qsTr("Play from the network"), disabled: !streamAvailable }
        if (installMode === "stream" && streamAvailable) { net.primary = true; return [net, dl] }
        dl.primary = true
        return [dl, net]
    }
    readonly property var allActions: hasTrailer ? actions.concat([{ id: "sound", label: page.sound ? qsTr("Mute the trailer") : qsTr("Trailer sound") }]) : actions

    // Credits: Wikidata first; RomM's studios and series when Wikidata has nothing.
    readonly property var credits: {
        const f = facts && facts.facts && facts.facts.status === "ok" ? facts.facts : null
        const c = f ? f.credits : {}
        const out = []
        const add = (label, list) => { if (list && list.length) out.push([label, list.join(", ")]) }
        add(qsTr("Developer"), c.developer)
        add(qsTr("Publisher"), c.publisher)
        if (!c.developer && !c.publisher && facts) add(qsTr("Studios"), facts.companies)
        add(qsTr("Director"), c.director)
        add(qsTr("Producer"), c.producer)
        add(qsTr("Designer"), c.designer)
        add(qsTr("Composer"), c.composer)
        add(qsTr("Series"), c.series && c.series.length ? c.series : facts ? facts.franchises : [])
        if (f && f.release_years && f.release_years.length) out.push([qsTr("Released"), Array.from(new Set(f.release_years)).sort().join(", ")])
        if (game && game.players) out.push([qsTr("Players"), game.players])
        return out
    }
    readonly property var anecdotes: facts && facts.facts && facts.facts.anecdotes ? facts.facts.anecdotes : []
    readonly property string longSummary: facts && facts.facts && facts.facts.summary ? facts.facts.summary : (game && game.summary ? game.summary : "")
    readonly property bool factsLoading: !!(facts && facts.facts && facts.facts.status === "loading")
    readonly property var languages: emuLanguages.map(code => ({ id: code, label: languageName(code) }))

    function languageName(code) {
        const names = { en: "English", fr: "Français", de: "Deutsch", es: "Español", it: "Italiano", nl: "Nederlands", pt: "Português", ja: "日本語" }
        if (code === "auto") return qsTr("Automatic")
        return names[code] || code
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
        const chosen = Math.max(0, versions.findIndex(v => game && v.rom_id === game.rom_id))
        col = [0, chosen, Math.max(0, emuLanguages.indexOf(emuLanguage))]
    }
    function rowItems(name) { return name === "actions" ? allActions : name === "versions" ? versions : name === "language" ? languages : [] }
    function setCol(r, c) { const n = col.slice(); n[r] = c; col = n }
    function activate(name, i) {
        if (name === "actions") {
            const a = allActions[i]
            if (!a || a.disabled) return
            if (a.id === "sound") sound = !sound
            else page.action(a.id, null)
        } else if (name === "versions") {
            const v = versions[i]
            if (v) page.action("version", v.rom_id)
        } else if (name === "language") {
            const l = emuLanguages[i]
            if (l) page.action("language", l)
        }
    }
    function scrollTo(y) {
        scrollAnim.to = Math.max(0, Math.min(body.contentHeight - body.height, y))
        scrollAnim.restart()
    }
    function handle(a) {
        const name = rows[Math.min(row, rows.length - 1)]
        const idx = name === "actions" ? 0 : name === "versions" ? 1 : 2
        const n = rowItems(name).length
        if (name === "more" && (a === "up" || a === "down")) {
            // The rest of the page: scroll, and go back to the choices from the top.
            if (a === "down") scrollTo(body.contentY + 420)
            else if (body.contentY > choices.y + 40) scrollTo(body.contentY - 420)
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
    property bool fromMouse: false
    onRowChanged: {
        if (fromMouse) return
        const name = rows[row]
        if (name === "actions") scrollTo(0)
        else if (name === "versions" || name === "language") scrollTo(choices.y - 360)
        else if (name === "more") scrollTo(credits.y - 120)
    }
    NumberAnimation { id: scrollAnim; target: body; property: "contentY"; duration: 260; easing.type: Easing.OutCubic }

    // ---------- trailer ----------
    function restartVideo() {
        delay.stop(); player.stop(); player.source = ""; videoShown = false; videoError = ""
        if (visible && trailers && !paused && trailerUrl !== "") delay.restart()
    }
    property bool videoShown: false
    onGameChanged: restartVideo()
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
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: (w) => w.accepted = true }

    Flickable {
        id: body
        anchors.fill: parent
        contentHeight: content.height + 120
        boundsBehavior: Flickable.StopAtBounds
        interactive: page.pointerActive
        flickDeceleration: 4000

        Item {
            id: content
            width: body.width
            height: shots.y + shots.height

            // Hero: the trailer across the top, fading into the page.
            Item {
                id: hero
                width: parent.width
                height: page.hasTrailer ? 660 : 560
                Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                VideoOutput {
                    id: video
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectCrop
                    opacity: page.videoShown ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
                }
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(0.047, 0.051, 0.063, 0.0) }
                        GradientStop { position: 0.5; color: Qt.rgba(0.047, 0.051, 0.063, 0.25) }
                        GradientStop { position: 0.82; color: Qt.rgba(0.047, 0.051, 0.063, 0.8) }
                        GradientStop { position: 1.0; color: Qt.rgba(0.047, 0.051, 0.063, 1.0) }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Qt.rgba(0.047, 0.051, 0.063, 0.8) }
                        GradientStop { position: 0.55; color: Qt.rgba(0.047, 0.051, 0.063, 0.0) }
                    }
                }
                // Without a trailer, the game case stands on the right, like on a shelf.
                Item {
                    id: caseItem
                    visible: !page.videoShown && coverImg.status === Image.Ready
                    readonly property real aspect: coverImg.implicitHeight > 0 ? Math.max(0.55, Math.min(1.45, coverImg.implicitWidth / coverImg.implicitHeight)) : 0.68
                    height: aspect > 1 ? 300 / aspect + 16 : 430
                    width: aspect > 1 ? 300 + 16 : (430 - 16) * aspect + 16
                    x: parent.width - 96 - width
                    y: Math.max(108, (parent.height - height) / 2 - 10)
                    layer.enabled: true
                    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: 0.7; shadowBlur: 1.0; shadowVerticalOffset: 18 }
                    Rectangle {
                        anchors.fill: parent
                        radius: 9
                        color: "#1a1c21"
                        border { width: 1; color: Qt.rgba(1, 1, 1, 0.1) }
                    }
                    Item {
                        anchors { fill: parent; margins: 8 }
                        clip: true
                        Image {
                            id: coverImg
                            anchors.fill: parent
                            source: page.game ? page.game.cover : ""
                            asynchronous: true
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(600, 860)
                        }
                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.0) }
                                GradientStop { position: 0.32; color: Qt.rgba(1, 1, 1, 0.09) }
                                GradientStop { position: 0.4; color: Qt.rgba(1, 1, 1, 0.0) }
                            }
                        }
                    }
                    Rectangle { x: 10; width: parent.width - 20; height: 1; color: Qt.rgba(1, 1, 1, 0.22) }
                }
                Rectangle {
                    visible: !page.videoShown && page.trailers
                    anchors { right: parent.right; rightMargin: 96; top: parent.top; topMargin: 56 }
                    width: tl.implicitWidth + 44; height: 36; radius: 18
                    color: theme.glass
                    border { width: 1; color: theme.glassEdge }
                    Icon { x: 14; anchors.verticalCenter: parent.verticalCenter; name: "play"; size: 12; filled: true; stroke: 1.5; color: theme.fg }
                    Text {
                        id: tl; x: 32; anchors.verticalCenter: parent.verticalCenter
                        text: !page.hasTrailer ? qsTr("No trailer in RomM for this game")
                            : page.videoError !== "" ? qsTr("The trailer cannot be played: %1").arg(page.videoError)
                            : page.trailerState.startsWith("error") ? qsTr("Trailer unavailable: %1").arg(page.trailerState.substring(7))
                            : qsTr("Loading the trailer…")
                        color: theme.fg; font { family: theme.fontFamily; pixelSize: 15 }
                    }
                }

                Column {
                    x: 96; anchors.bottom: parent.bottom; anchors.bottomMargin: 36
                    width: 1300
                    spacing: 16
                    Text {
                        width: parent.width
                        text: page.game ? [page.game.platform_name, page.game.year > 0 ? page.game.year : "", page.game.genres.split(",")[0],
                                           page.game.players ? (/^\d+$/.test(page.game.players) ? qsTr("%n player(s)", "", Number(page.game.players)) : qsTr("%1 players").arg(page.game.players)) : ""].filter(x => x).join(" · ").toUpperCase() : ""
                        elide: Text.ElideRight
                        color: theme.accent
                        font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold; letterSpacing: 3 }
                    }
                    Text {
                        width: Math.min(1100, hero.width - 192 - (caseItem.visible ? caseItem.width + 48 : 0))
                        text: page.game ? page.game.name : ""
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        lineHeight: 0.95
                        color: theme.fg
                        font { family: theme.displayFont; pixelSize: page.game && page.game.name.length > 24 ? 60 : 78; weight: Font.ExtraBold; letterSpacing: -2 }
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
                                pointerActive: page.pointerActive
                                onClicked: { page.fromMouse = true; page.row = 0; page.fromMouse = false; page.setCol(0, index); page.activate("actions", index) }
                            }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            leftPadding: 10
                            spacing: 8
                            Text {
                                text: page.stateText()
                                width: Math.min(implicitWidth, 480)
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
                    Text {
                        visible: !page.streamAvailable && page.streamError !== "" && page.actions.some(a => a.id === "link")
                        width: 1100
                        text: qsTr("Playing from the network is unavailable here: %1").arg(page.streamError)
                        wrapMode: Text.WordWrap
                        color: theme.fgFaint
                        font { family: theme.fontFamily; pixelSize: 15 }
                    }
                }
            }

            // The rest of the page sits on the same veil as the end of the hero.
            Rectangle {
                y: hero.height
                width: parent.width
                height: Math.max(parent.height, body.height + body.contentY) - hero.height + 200
                color: Qt.rgba(0.047, 0.051, 0.063, 0.82)
            }

            // Choices and the introduction.
            Row {
                id: choices
                x: 96; y: hero.height
                spacing: 28
                Rectangle {
                    width: 1048
                    height: choiceCol.height + 48
                    radius: 24
                    color: Qt.rgba(1, 1, 1, 0.06)
                    border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
                    Column {
                        id: choiceCol
                        x: 26; y: 24
                        width: parent.width - 64
                        spacing: 20
                        Column {
                            visible: page.versions.length > 1
                            width: parent.width
                            spacing: 12
                            Text { text: qsTr("VERSION"); color: theme.fgFaint; font { family: theme.fontFamily; pixelSize: 14; weight: Font.DemiBold; letterSpacing: 2 } }
                            Flow {
                                width: parent.width
                                spacing: 10
                                Repeater {
                                    model: page.versions
                                    Chip {
                                        required property var modelData
                                        required property int index
                                        theme: page.theme
                                        text: page.versionTitle(modelData)
                                        detail: page.versionDetail(modelData)
                                        selected: page.game !== null && modelData.rom_id === page.game.rom_id
                                        badge: modelData.local_state === "local" || modelData.linked
                                        focused: page.rows[page.row] === "versions" && page.col[1] === index
                                        pointerActive: page.pointerActive
                                        onClicked: { page.fromMouse = true; page.row = page.rows.indexOf("versions"); page.fromMouse = false; page.setCol(1, index); page.activate("versions", index) }
                                    }
                                }
                            }
                        }
                        Column {
                            width: parent.width
                            spacing: 12
                            Text {
                                textFormat: Text.StyledText
                                text: qsTr("GAME LANGUAGE") + "<font color='#99F4F6FA'>  " + qsTr("— passed to the emulator") + "</font>"
                                color: theme.fgFaint
                                font { family: theme.fontFamily; pixelSize: 14; weight: Font.DemiBold; letterSpacing: 2 }
                            }
                            Flow {
                                width: parent.width
                                spacing: 10
                                Repeater {
                                    model: page.languages
                                    Chip {
                                        required property var modelData
                                        required property int index
                                        theme: page.theme
                                        text: modelData.label
                                        selected: modelData.id === page.emuLanguage
                                        focused: page.rows[page.row] === "language" && page.col[2] === index
                                        pointerActive: page.pointerActive
                                        onClicked: { page.fromMouse = true; page.row = page.rows.indexOf("language"); page.fromMouse = false; page.setCol(2, index); page.activate("language", index) }
                                    }
                                }
                            }
                        }
                    }
                }
                Text {
                    width: 640
                    text: page.longSummary || qsTr("No summary for this game yet.")
                    wrapMode: Text.WordWrap
                    lineHeight: 1.55
                    color: theme.fgSoft
                    font { family: theme.fontFamily; pixelSize: 20 }
                }
            }

            // Credits and anecdotes.
            Row {
                id: credits
                x: 96; y: choices.y + choices.height + 28
                spacing: 28
                visible: page.credits.length > (page.game && page.game.players ? 1 : 0) || page.anecdotes.length > 0 || page.factsLoading
                height: visible ? Math.max(creditsPanel.height, triviaPanel.height) : 0
                Rectangle {
                    id: creditsPanel
                    width: 760
                    height: creditsCol.height + 52
                    radius: 24
                    color: Qt.rgba(1, 1, 1, 0.06)
                    border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
                    Column {
                        id: creditsCol
                        x: 26; y: 26
                        width: parent.width - 52
                        spacing: 16
                        Text { text: qsTr("Credits"); color: theme.fg; font { family: theme.displayFont; pixelSize: 26; weight: Font.Bold } }
                        Grid {
                            columns: 2
                            columnSpacing: 28
                            rowSpacing: 20
                            Repeater {
                                model: page.credits
                                Column {
                                    required property var modelData
                                    width: (creditsCol.width - 28) / 2
                                    spacing: 4
                                    Text { text: modelData[0]; color: theme.fgFaint; font { family: theme.fontFamily; pixelSize: 15 } }
                                    Text { width: parent.width; text: modelData[1]; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight; color: theme.fg; font { family: theme.fontFamily; pixelSize: 19; weight: Font.Medium } }
                                }
                            }
                        }
                        Text {
                            visible: page.factsLoading && page.credits.length === 0
                            text: qsTr("Looking up the credits…")
                            color: theme.fgMuted
                            font { family: theme.fontFamily; pixelSize: 17 }
                        }
                        Text {
                            text: qsTr("Sources: RomM, Wikidata, Wikipedia")
                            color: theme.fgFaint
                            font { family: theme.fontFamily; pixelSize: 14 }
                        }
                    }
                }
                Rectangle {
                    id: triviaPanel
                    visible: page.anecdotes.length > 0
                    width: 928
                    height: triviaCol.height + 52
                    radius: 24
                    color: Qt.rgba(1, 1, 1, 0.06)
                    border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
                    Column {
                        id: triviaCol
                        x: 26; y: 26
                        width: parent.width - 52
                        spacing: 14
                        Text { text: qsTr("Did you know?"); color: theme.fg; font { family: theme.displayFont; pixelSize: 26; weight: Font.Bold } }
                        Repeater {
                            model: page.anecdotes
                            Row {
                                required property string modelData
                                spacing: 16
                                Rectangle { y: 11; width: 8; height: 8; radius: 4; color: theme.accent }
                                Text { width: triviaCol.width - 24; text: modelData; wrapMode: Text.WordWrap; lineHeight: 1.5; color: theme.fgSoft; font { family: theme.fontFamily; pixelSize: 19 } }
                            }
                        }
                        Text {
                            text: qsTr("From the game's Wikipedia article")
                            color: theme.fgFaint
                            font { family: theme.fontFamily; pixelSize: 14 }
                        }
                    }
                }
            }

            // Screenshots.
            Column {
                id: shots
                x: 96; y: credits.y + credits.height + 28
                width: parent.width - 192
                spacing: 18
                visible: page.facts && page.facts.screenshots > 0
                height: visible ? implicitHeight : 0
                Text { text: qsTr("Screenshots"); color: theme.fg; font { family: theme.displayFont; pixelSize: 26; weight: Font.Bold } }
                Row {
                    spacing: 20
                    Repeater {
                        model: page.facts ? Math.min(4, page.facts.screenshots) : 0
                        Rectangle {
                            required property int index
                            width: 420; height: 236; radius: 14
                            color: theme.glass
                            clip: true
                            Image {
                                anchors.fill: parent
                                source: page.shotBase ? page.shotBase + parent.index : ""
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                sourceSize: Qt.size(840, 472)
                            }
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
        color: backMouse.containsMouse ? theme.glassRaised : theme.glass
        border { width: 1; color: theme.glassEdge }
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Back to the library")
        Row {
            id: backRow
            anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 10
            Rectangle {
                width: 32; height: 32; radius: 16; color: theme.glassRaised
                Text { anchors.centerIn: parent; text: "B"; color: theme.fg; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold } }
            }
            Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Library"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 17; weight: Font.Medium } }
        }
        MouseArea {
            id: backMouse
            anchors.fill: parent
            hoverEnabled: page.pointerActive
            cursorShape: Qt.PointingHandCursor
            onClicked: page.action("back", null)
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
        pointerActive: page.pointerActive
        hints: [["A", qsTr("Select"), "a"], ["B", qsTr("Back"), "b"], ["▲ ▼", qsTr("More about the game"), "down"]]
        onTriggered: (a) => page.handle(a)
    }
}
