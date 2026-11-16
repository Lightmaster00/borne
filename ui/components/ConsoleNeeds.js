// What a console's games need of the machine (core/src/consoles.rs gives the codes and whether
// each is missing here), in the player's words. `missing`: said as a warning; else as what is
// fine here.
.pragma library

// w: {code, missing} (+ threads, ram_gb for "power").
function text(w) {
    const missing = w.missing
    switch (w.code) {
    case "touch":
        return missing ? qsTr("Many games are played on the lower touch screen: there is none here, the pointer moves with the right stick (slower, some games are hard).")
                       : qsTr("Touch screen: the lower screen is touched directly.")
    case "two_screens":
        return qsTr("Two screens, shown side by side or one above the other.")
    case "motion_some":
        return missing ? qsTr("Some games are played by tilting the console: they need a pad with motion sensors (Switch Pro, DualShock 4, DualSense, Steam Deck).")
                       : qsTr("Motion: your pad has motion sensors.")
    case "wiimote":
        return missing ? qsTr("Most Wii games are played with a Wii Remote pointed at the screen: without one, the pointer moves with the right stick and many games are awkward. Best: a Wii Remote with a sensor bar or a DolphinBar.")
                       : qsTr("Wii Remote: found.")
    case "motion":
        return missing ? qsTr("Wii games ask you to shake the Remote: a pad with motion sensors or a Wii Remote is needed for those moves.")
                       : qsTr("Shaking: your pad has motion sensors.")
    case "touch_gamepad":
        return missing ? qsTr("Many Wii U games use the GamePad's touch screen: there is none here, the pointer moves with the right stick.")
                       : qsTr("Touch screen: the GamePad's screen is touched directly.")
    case "joycon_some":
        return missing ? qsTr("Some Switch games need Joy-Con (motion, two halves held apart): they cannot be played on a pad without motion sensors.")
                       : qsTr("Motion: your pad has motion sensors.")
    case "touch_some":
        return missing ? qsTr("A few Switch games are played only on the touch screen: not playable here.")
                       : qsTr("Touch screen: found.")
    case "touch_vita":
        return missing ? qsTr("Some PS Vita games use the front touch screen or the rear touch pad: there is none here, the right stick stands in for them.")
                       : qsTr("Touch screen: found.")
    case "power":
        return missing ? qsTr("Heavy to emulate: this computer may be too slow (%1 threads, %2 GB of memory).").arg(w.threads).arg(w.ram_gb)
                       : qsTr("Power: this computer should run these games.")
    }
    return w.code
}

// The missing needs of a console, as sentences.
function warnings(list) {
    return (list || []).filter(w => w.missing).map(w => text(w))
}
