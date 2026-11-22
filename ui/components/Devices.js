// The controller a console's game sees (core/src/controls.rs, "device"): its name and what it is
// good for, in the player's words.
.pragma library

function label(id, console) {
    switch (id) {
    case "pro": return console === "wiiu" ? qsTr("Wii U Pro Controller") : qsTr("Pro Controller")
    case "dual": return qsTr("Joy-Con pair")
    case "handheld": return qsTr("Handheld (console in hand)")
    case "nunchuk": return qsTr("Wii Remote + Nunchuk")
    case "remote": return qsTr("Wii Remote alone")
    case "sideways": return qsTr("Wii Remote sideways")
    case "classic": return qsTr("Classic Controller")
    case "gamepad": return qsTr("Wii U GamePad")
    }
    return id
}

function hint(id) {
    switch (id) {
    case "pro": return qsTr("Most games")
    case "dual": return qsTr("For games that refuse the Pro Controller")
    case "handheld": return qsTr("The Switch as if held in hand")
    case "nunchuk": return qsTr("Most Wii games: stick on the Nunchuk, pointer on the right stick")
    case "remote": return qsTr("Pointer games without a Nunchuk")
    case "sideways": return qsTr("Played like a NES pad: 1 and 2 on the bottom and left buttons")
    case "classic": return qsTr("Games that take the Classic Controller, Virtual Console")
    case "gamepad": return qsTr("The Wii U's own controller, with its screen")
    }
    return ""
}

// Why a game takes another controller than its console's usual one.
function wantedNote(id, console) {
    if (id === "dual") return qsTr("This game does not take the Pro Controller: it plays with a pair of Joy-Con, which Borne shows it.")
    if (id === "sideways") return qsTr("This game is played with the Wii Remote held sideways: Borne shows it one, 1 and 2 on your bottom and left buttons.")
    return ""
}

// The console's controller's buttons, each with the place on your pad that gives it ("south",
// "east", "west", "north", "lb", "rb", "lt", "rt", "start", "select", "ls", "rs"), as the
// emulators Borne sets up bind them (the face buttons by position: Nintendo's A on the right).
// label(place): how that place reads on your pad.
function mapping(id, label) {
    let rows
    switch (id) {
    case "nunchuk": rows = [["A", "south"], [qsTr("B (trigger)"), "rt"], ["1", "west"], ["2", "north"], ["+", "start"], ["−", "select"], [qsTr("Pointer"), "rs"], [qsTr("Shake"), "east"], ["C", "lb"], ["Z", "lt"], [qsTr("Nunchuk stick"), "ls"]]; break
    case "remote": rows = [["A", "south"], [qsTr("B (trigger)"), "rt"], ["1", "west"], ["2", "north"], ["+", "start"], ["−", "select"], [qsTr("Pointer"), "rs"], [qsTr("Shake"), "rb"]]; break
    case "sideways": rows = [["2", "south"], ["1", "west"], ["A", "east"], ["B", "north"], ["+", "start"], ["−", "select"], [qsTr("Shake"), "rb"]]; break
    default: rows = [["A", "east"], ["B", "south"], ["X", "north"], ["Y", "west"], ["L", "lb"], ["R", "rb"], ["ZL", "lt"], ["ZR", "rt"], ["+", "start"], ["−", "select"]]
    }
    return rows.map(r => ({ from: r[0], to: label(r[1]) }))
}
