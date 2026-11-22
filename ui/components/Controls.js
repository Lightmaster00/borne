// The controls rows, the same for every game (Settings → Controllers), a console (its page in
// Settings → Consoles) and a game (its settings): who plays, the layout, the left stick and, in
// the advanced display, each of the console's buttons with the pad button that does it now,
// changed by pressing that pad button. Each level takes the one above until changed
// (core/src/controls.rs). The rows' ids: "ctl:<key>" a setting, "ctl-btn:<button>" press the
// pad button for a console button, "ctl-reset-buttons", "ctl-reset".
.pragma library
.import "Devices.js" as Devices

// A pad button by its place, in the controls' names: a bottom, b right, x left, y top.
const PLACES = ["a", "b", "x", "y", "l", "r", "l2", "r2", "start", "select"]

// The console's own buttons, each with the place that does it by default (as the emulators
// Borne sets up read them).
function consoleButtons(slug) {
    const nintendo = [["b", "A"], ["a", "B"], ["y", "X"], ["x", "Y"], ["l", "L"], ["r", "R"]]
    const ps = [["a", "✕"], ["b", "○"], ["x", "□"], ["y", "△"], ["l", "L1"], ["r", "R1"], ["l2", "L2"], ["r2", "R2"], ["start", "Start"], ["select", "Select"]]
    const sega = [["x", "A"], ["a", "B"], ["b", "C"], ["l", "X"], ["y", "Y"], ["r", "Z"], ["start", "Start"]]
    switch (slug) {
    case "nes": case "famicom": case "fds":
        return [["b", "A"], ["a", "B"], ["start", "Start"], ["select", "Select"]]
    case "gb": case "gbc":
        return [["b", "A"], ["a", "B"], ["start", "Start"], ["select", "Select"]]
    case "gba":
        return [["b", "A"], ["a", "B"], ["l", "L"], ["r", "R"], ["start", "Start"], ["select", "Select"]]
    case "snes": case "sfam":
        return nintendo.concat([["start", "Start"], ["select", "Select"]])
    case "n64":
        return [["a", "A"], ["x", "B"], ["l2", "Z"], ["l", "L"], ["r", "R"], ["start", "Start"]]
    case "nds": case "3ds": case "n3ds":
        return nintendo.concat(slug === "nds" ? [] : [["l2", "ZL"], ["r2", "ZR"]]).concat([["start", "Start"], ["select", "Select"]])
    case "switch": case "wiiu":
        return nintendo.concat([["l2", "ZL"], ["r2", "ZR"], ["start", "+"], ["select", "−"]])
    case "ngc":
        return [["a", "A"], ["x", "B"], ["b", "X"], ["y", "Y"], ["r", "Z"], ["l2", "L"], ["r2", "R"], ["start", "Start"]]
    case "wii":
        return [["a", "A"], ["r2", "B"], ["x", "1"], ["y", "2"], ["select", "−"], ["start", "+"], ["l", qsTr("C (Nunchuk)")], ["l2", qsTr("Z (Nunchuk)")], ["b", qsTr("Shake")]]
    case "genesis": case "megadrive": case "sms": case "segacd": case "sega32": case "gamegear":
        return sega.concat([["select", "Mode"]])
    case "saturn":
        return sega.concat([["l2", "L"], ["r2", "R"]])
    case "psx": case "ps2": case "ps3": case "ps4":
        return ps
    case "psp": case "psvita":
        return [["a", "✕"], ["b", "○"], ["x", "□"], ["y", "△"], ["l", "L"], ["r", "R"], ["start", "Start"], ["select", "Select"]]
    case "xbox": case "xbox360":
        return [["a", "A"], ["b", "B"], ["x", "X"], ["y", "Y"], ["l", "LB"], ["r", "RB"], ["l2", "LT"], ["r2", "RT"], ["start", "Start"], ["select", "Back"]]
    }
    // Every game, or a console without its own names: the pad's places.
    return [["a", qsTr("Bottom button")], ["b", qsTr("Right button")], ["x", qsTr("Left button")], ["y", qsTr("Top button")],
            ["l", qsTr("Left shoulder")], ["r", qsTr("Right shoulder")], ["l2", qsTr("Left trigger")], ["r2", qsTr("Right trigger")],
            ["start", "Start"], ["select", "Select"]]
}

// A pad button as printed on the player's pad.
function padLabel(family, place) {
    const t = {
        xbox: { a: "A", b: "B", x: "X", y: "Y", l: "LB", r: "RB", l2: "LT", r2: "RT", start: "Menu", select: "View" },
        playstation: { a: "✕", b: "○", x: "□", y: "△", l: "L1", r: "R1", l2: "L2", r2: "R2", start: "Options", select: "Create" },
        nintendo: { a: "B", b: "A", x: "Y", y: "X", l: "L", r: "R", l2: "ZL", r2: "ZR", start: "+", select: "−" }
    }
    return (t[family] || t.xbox)[place] || place
}

// The rows for a controls view (GET …/controls). advanced: every button shown. parentName: what
// this level takes when it has nothing of its own ("every game", the console's name).
function rows(v, advanced, parentName) {
    const out = []
    if (!v) return out
    const opt = k => v.options.find(o => o.key === k)
    const chips = function (k, title, desc, labels) {
        const o = opt(k)
        if (!o) return null
        const vals = k !== "pad" ? o.values : o.values.filter(x => x === "auto" || x === o.value || Number(x) <= v.pads.length)
        return { id: "ctl:" + k, kind: "chips", title: title, desc: desc + (o.own || v.level === "all" || k === "pad" ? "" : " · " + qsTr("as for %1").arg(parentName)),
                 selected: o.value, items: vals.map(x => ({ id: x, label: labels(x) })) }
    }
    // A console's games: the controller its emulator shows them (a game can change it).
    const dev = v.options.find(o => o.key === "device")
    if (dev && v.level === "console")
        out.push({ id: "ctl:device", kind: "chips", title: qsTr("Controller the games see"),
                   desc: qsTr("The console's controller shown to its games; each game can take another"),
                   selected: dev.value, items: dev.values.map(x => ({ id: x, label: Devices.label(x, v.console) })) })
    if (v.level === "game")
        out.push(chips("pad", qsTr("Player 1"), qsTr("The controller that plays"),
                       x => x === "auto" ? qsTr("Automatic") : (v.pads[Number(x) - 1] || qsTr("Controller %1").arg(x))))
    out.push(chips("face", qsTr("Layout"),
                   qsTr("Swapped: A and B, X and Y trade places, for a Nintendo layout (A on the right) on another controller, or the other way round"),
                   x => x === "swap" ? qsTr("A↔B, X↔Y swapped") : qsTr("As on the controller")))
    if (v.stick)
        out.push(chips("stick", qsTr("Left stick"), qsTr("Also moves as the D-pad, for games made for a D-pad"),
                       x => x === "dpad" ? qsTr("Also the D-pad") : qsTr("Stick only")))
    if (advanced) {
        out.push({ id: "group:ctl-buttons", kind: "header", title: qsTr("Buttons"), items: [] })
        const at = {}
        for (const b of v.buttons) at[b.button] = b.pad
        for (const [place, name] of consoleButtons(v.console)) {
            const pad = at[place]
            out.push({ id: "ctl-btn:" + place, kind: "buttons", title: name,
                       desc: pad ? qsTr("On your controller: %1").arg(padLabel(v.family, pad)) : qsTr("On no button"),
                       items: [{ id: "capture", label: qsTr("Press to change") }] })
        }
        if (v.options.some(o => o.own && o.key.startsWith("map.")))
            out.push({ id: "ctl-reset-buttons", kind: "buttons", title: qsTr("Buttons back as they were"), desc: qsTr("As for %1").arg(parentName),
                       items: [{ id: "ctl-reset-buttons", label: qsTr("Reset") }] })
    }
    if (v.options.some(o => o.own))
        out.push({ id: "ctl-reset", kind: "buttons",
                   title: v.level === "game" ? qsTr("This game's controls") : v.level === "console" ? qsTr("This console's controls") : qsTr("Back to the controller as it is"),
                   desc: v.level === "all" ? qsTr("Every button doing its own") : qsTr("Back to the controls of %1").arg(parentName),
                   items: [{ id: "ctl-reset", label: qsTr("Reset") }] })
    return out.filter(r => r !== null)
}
