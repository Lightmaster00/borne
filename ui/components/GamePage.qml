// Game page: opened from the library before anything is downloaded. Shows the game, lets the
// player choose the version (region / languages) and the language the emulator starts in,
// then download it, play it from the network (Borne virtual mount) or manage the local copy.
//
// Gamepad: up/down between rows (actions, versions, language), left/right inside a row,
// A to activate, B to go back. Mouse: everything is clickable; the back button is top left.
import QtQuick
import QtQuick.Effects

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
    property bool paused: false

    signal action(string id, var payload)

    property int row: 0
    property var col: [0, 0, 0]

    readonly property bool busy: game !== null && ["queued", "downloading", "verifying", "extracting"].indexOf(game.dl_state) >= 0
    readonly property var rows: versions.length > 1 ? ["actions", "versions", "language"] : ["actions", "language"]

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
        const chosen = Math.max(0, versions.findIndex(v => game && v.rom_id === game.rom_id))
        col = [0, chosen, Math.max(0, emuLanguages.indexOf(emuLanguage))]
    }
    function rowItems(name) { return name === "actions" ? actions : name === "versions" ? versions : languages }
    function setCol(r, c) { const n = col.slice(); n[r] = c; col = n }
    function colOf(name) { return col[name === "actions" ? 0 : name === "versions" ? 1 : 2] }
    function activate(name, i) {
        if (name === "actions") {
            const a = actions[i]
            if (a && !a.disabled) page.action(a.id, null)
        } else if (name === "versions") {
            const v = versions[i]
            if (v) page.action("version", v.rom_id)
        } else {
            const l = emuLanguages[i]
            if (l) page.action("language", l)
        }
    }
    function handle(a) {
        const name = rows[Math.min(row, rows.length - 1)]
        const idx = name === "actions" ? 0 : name === "versions" ? 1 : 2
        const n = rowItems(name).length
        if (a === "up") row = Math.max(0, row - 1)
        else if (a === "down") row = Math.min(rows.length - 1, row + 1)
        else if (a === "left") setCol(idx, Math.max(0, col[idx] - 1))
        else if (a === "right") setCol(idx, Math.min(n - 1, col[idx] + 1))
        else if (a === "a") activate(name, col[idx])
        else if (a === "b") page.action("back", null)
    }
    onActionsChanged: setCol(0, Math.min(col[0], Math.max(0, actions.length - 1)))
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0
    property bool fromMouse: false

    // Swallow clicks so the library underneath never receives them.
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: (w) => w.accepted = true }

    // ---------- back ----------
    Rectangle {
        x: 96; y: 44
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

    // ---------- cover, with the game's halo ----------
    Rectangle { id: haloSource; anchors.fill: cover; radius: cover.radius; color: theme.halo; visible: false }
    MultiEffect {
        anchors.fill: haloSource
        source: haloSource
        autoPaddingEnabled: true
        blurEnabled: true; blur: 1.0; blurMax: 64
        opacity: 0.8
    }
    Rectangle {
        id: cover
        x: 96; y: 150
        width: 380; height: 570
        radius: 22
        color: theme.tone(page.game ? page.game.hue : 0)
        layer.enabled: coverImg.status === Image.Ready
        layer.effect: MultiEffect { maskEnabled: true; maskSource: coverMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
        Text {
            visible: coverImg.status !== Image.Ready
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 28 }
            text: page.game ? page.game.name : ""
            wrapMode: Text.WordWrap
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 44; weight: Font.ExtraBold }
        }
        Image {
            id: coverImg
            anchors.fill: parent
            source: page.game ? page.game.cover : ""
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(570, 855)
        }
    }
    Item {
        id: coverMask
        anchors.fill: cover
        layer.enabled: true
        visible: false
        Rectangle { anchors.fill: parent; radius: cover.radius; color: "black" }
    }
    Rectangle {
        anchors.fill: cover
        radius: cover.radius
        color: "transparent"
        border { width: 1; color: Qt.rgba(1, 1, 1, 0.18) }
    }

    // ---------- title, actions, choices ----------
    Column {
        id: info
        x: cover.x + cover.width + 72; y: 160
        width: parent.width - x - 96
        spacing: 26

        Text {
            width: parent.width
            text: page.game ? [page.game.platform_name, page.game.year > 0 ? page.game.year : "", page.game.genres,
                               page.game.players ? (/^\d+$/.test(page.game.players) ? qsTr("%n player(s)", "", Number(page.game.players)) : qsTr("%1 players").arg(page.game.players)) : ""].filter(x => x).join(" · ").toUpperCase() : ""
            elide: Text.ElideRight
            color: theme.accent
            font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold; letterSpacing: 3 }
        }
        Text {
            width: parent.width
            height: 88
            text: page.game ? page.game.name : ""
            fontSizeMode: Text.HorizontalFit
            minimumPixelSize: 48
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 88; weight: Font.ExtraBold; letterSpacing: -2.5 }
        }

        Row {
            spacing: 14
            Repeater {
                model: page.actions
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
                    width: Math.min(implicitWidth, 520)
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
            width: parent.width
            text: qsTr("Playing from the network is unavailable here: %1").arg(page.streamError)
            wrapMode: Text.WordWrap
            color: theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 15 }
        }

        // Choices, on glass.
        Rectangle {
            width: parent.width
            height: choices.height + 52
            radius: 24
            color: Qt.rgba(1, 1, 1, 0.06)
            border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
            Column {
                id: choices
                x: 28; y: 26
                width: parent.width - 56
                spacing: 22
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
            width: Math.min(parent.width, 980)
            text: page.game && page.game.summary ? page.game.summary : qsTr("No summary in RomM for this game.")
            wrapMode: Text.WordWrap
            maximumLineCount: 4
            elide: Text.ElideRight
            lineHeight: 1.5
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 20 }
        }
    }

    // ---------- hints ----------
    HintBar {
        x: 84; anchors { bottom: parent.bottom; bottomMargin: 24 }
        theme: page.theme
        pointerActive: page.pointerActive
        hints: [["A", qsTr("Select"), "a"], ["B", qsTr("Back"), "b"]]
        onTriggered: (a) => page.handle(a)
    }
    Text {
        anchors { right: parent.right; rightMargin: 96; bottom: parent.bottom; bottomMargin: 34 }
        text: page.fmtSize(page.game ? page.game.fs_size : 0) + "  ·  " + qsTr("Choices are saved for this profile")
        color: theme.fgFaint
        font { family: theme.fontFamily; pixelSize: 15 }
    }
}
