pragma Singleton
import QtQuick
import RuyaShell

// Controls in games (RUY-465, 06 §7): the signed-in console profile's global controller profile as
// the pages edit it, over Input's profile calls (RUY-42). One profile per console profile is
// assigned to the global scope; the pages edit it as the stored profile `controls` (or the one an
// import assigned), which inherits `nintendo` for the Nintendo layout and `default` otherwise, and
// holds only what differs: the Applies-to `match`, the remapped buttons, the stick settings.
//
// Every change is shown at once (`doc`) and saved in the background: ValidateProfile, SaveProfile
// and, when the profile is not the assigned one yet, AssignProfile; a slider's change waits 300 ms
// for the next step first (`change(..., true)`). One save runs at a time and only the newest change
// waits behind it. A refused save toasts "Could not save the change" and `doc` goes back to what
// the service has (`stored`). Reset deletes the profile (or takes back an assigned built-in).
// Export and import go through Input.exportProfile / importProfile (Devices1.Storage).
// Also the words the pages share: button names and glyphs by family, the short pad name.
QtObject {
    id: games

    // The console profile whose controls these are ("" signed out).
    readonly property string owner: Profiles.activeProfile
    // The id the pages save under when the console profile has no stored global profile yet.
    readonly property string ownId: "controls"

    // "loading" before the first answer, "ok", or "failed" (ListProfiles or GetProfile failed).
    property string loadState: "loading"
    // The assigned global profile's summary (Input1's keys), or null when none is assigned.
    property var summary: null
    // The assigned stored profile as the service has it (an object), or null (none, or a built-in).
    property var stored: null
    // What the pages show: `stored`, or the newest change while it is on its way.
    property var doc: null

    // The save on its way: "" | "validate" | "save" | "assign" | "delete".
    property string phase: ""
    property var inFlight: null         // { doc, tag }
    property var queued: null           // { doc, tag }: the newest change, waiting
    property string exportVolume: ""    // an export waits for the save before it
    property bool importing: false

    readonly property bool busy: phase !== "" || queued !== null
    // Settings > Controllers' "Controls in games" value: the service's word for the assigned profile.
    readonly property bool changed: summary !== null && summary.changed === true
    readonly property string layout: (doc ? doc.inherits === "nintendo"
                                          : summary !== null && summary.layout === "nintendo") ? "nintendo" : "standard"
    // "all" | "family" | "device"
    readonly property string appliesTo: {
        const m = doc ? (doc.match ?? {}) : (summary ? { family: summary.match_family, device: summary.match_device } : {})
        return (m.device ?? "") !== "" ? "device" : (m.family ?? "") !== "" ? "family" : "all"
    }
    readonly property string matchFamily: doc ? (doc.match?.family ?? "") : (summary?.match_family ?? "")
    readonly property string matchDevice: doc ? (doc.match?.device ?? "") : (summary?.match_device ?? "")

    signal saved(string tag)
    signal failed(string tag)
    signal imported(string fileName)
    signal importRefused(string fileName, string status)

    onOwnerChanged: {
        summary = null
        stored = null
        doc = null
        queued = null
        inFlight = null
        phase = ""
        loadState = "loading"
        if (owner !== "")
            refresh()
    }

    function refresh() {
        if (owner === "")
            return
        Input.listProfiles(owner)
    }

    // ---- the inputs ------------------------------------------------------------------------------
    // The remappable inputs, in the list's order (06 §7; paddles when a pad reports them, none yet).
    readonly property var sources: ["south", "east", "west", "north", "l1", "r1", "left_trigger", "right_trigger",
                                    "l3", "r3", "dpad_up", "dpad_down", "dpad_left", "dpad_right", "select", "start"]
    function isAxis(input) {
        return input === "left_trigger" || input === "right_trigger"
    }

    // What the layout makes of an input before the profile's own mappings (the built-in preset).
    function presetTarget(source) {
        if (layout !== "nintendo")
            return source
        const swap = { south: "east", east: "south", west: "north", north: "west" }
        return swap[source] ?? source
    }
    function ownMapping(source) {
        return (doc?.mappings ?? []).find(m => m.from === source) ?? null
    }
    // The input a source now acts as ("none" when it is off).
    function targetOf(source) {
        const m = ownMapping(source)
        if (m && (m.mode === undefined || m.mode === "press") && m.to) {
            if (m.to.type === "none")
                return "none"
            if ((m.to.type === "button" || m.to.type === "axis") && m.to.code)
                return m.to.code
        }
        return presetTarget(source)
    }
    function isChanged(source) {
        return targetOf(source) !== presetTarget(source)
    }
    readonly property int remapCount: {
        let n = 0
        for (const s of sources) {
            if (isChanged(s))
                ++n
        }
        return n
    }

    // ---- the sticks ------------------------------------------------------------------------------
    readonly property var stickDefaults: ({ inner_deadzone: 0.08, outer_deadzone: 0.02, anti_deadzone: 0,
                                            sensitivity: 1, curve: "linear", invert_x: false, invert_y: false })
    // The settings a stick ("left" | "right") has: the defaults with the profile's own on top.
    function stick(side) {
        return Object.assign({}, stickDefaults, doc?.settings?.[side + "_stick"] ?? {})
    }
    function stickChanged(side) {
        const s = stick(side)
        for (const k in stickDefaults) {
            if (typeof s[k] === "number" ? Math.abs(s[k] - stickDefaults[k]) > 1e-9 : s[k] !== stickDefaults[k])
                return true
        }
        return false
    }
    // 06 §7: what the game sees for a stick magnitude r (0..1) with settings s.
    function response(r, s) {
        const x = Math.max(0, Math.min(1, r))
        const span = 1 - s.inner_deadzone - s.outer_deadzone
        const rp = span <= 1e-9 ? (x > s.inner_deadzone ? 1 : 0)
                                : Math.max(0, Math.min(1, (x - s.inner_deadzone) / span))
        if (rp <= 0)
            return 0
        const c = s.curve === "precise" ? rp * rp : s.curve === "aggressive" ? Math.sqrt(rp) : rp
        return Math.max(0, Math.min(1, (s.anti_deadzone + (1 - s.anti_deadzone) * c) * s.sensitivity))
    }

    // ---- changes ---------------------------------------------------------------------------------
    // A copy of the profile to change: the stored one, or a new one (the layout of an assigned built-in kept).
    function editable() {
        if (doc)
            return JSON.parse(JSON.stringify(doc))
        const d = { schema_version: 1, id: ownId, name: "Controls in games", scope: { type: "global" } }
        if (summary && summary.builtin && summary.layout === "nintendo")
            d.inherits = "nintendo"
        return d
    }

    function setLayout(value) {
        const d = editable()
        if (value === "nintendo")
            d.inherits = "nintendo"
        else
            delete d.inherits
        change(d, "layout", false)
    }

    // "all" | "family:<family>" | "device:<stable id>" (Applies to's values).
    readonly property string appliesValue: appliesTo === "device" ? "device:" + matchDevice
                                           : appliesTo === "family" ? "family:" + matchFamily : "all"
    function setAppliesTo(value) {
        const d = editable()
        const v = String(value)
        if (v.startsWith("family:") && v.length > 7)
            d.match = { family: v.slice(7) }
        else if (v.startsWith("device:") && v.length > 7)
            d.match = { device: v.slice(7) }
        else
            delete d.match
        change(d, "match", false)
    }

    // The source now acts as `target`. False (and nothing saved) when it already does: pressing the
    // same button maps it to itself, which is no change.
    function setTarget(source, target) {
        if (targetOf(source) === target)
            return false
        const d = editable()
        d.mappings = (d.mappings ?? []).filter(m => m.from !== source)
        if (target !== presetTarget(source))
            d.mappings.push({ from: source, to: { type: isAxis(target) ? "axis" : "button", code: target } })
        if (d.mappings.length === 0)
            delete d.mappings
        change(d, "remap:" + source, false)
        return true
    }

    function setStick(side, key, value, debounce) {
        const d = editable()
        const name = side + "_stick"
        const settings = d.settings ?? {}
        const s = settings[name] ?? {}
        const same = typeof value === "number" ? Math.abs(value - stickDefaults[key]) < 1e-9 : value === stickDefaults[key]
        if (same)
            delete s[key]
        else
            s[key] = value
        if (Object.keys(s).length > 0)
            settings[name] = s
        else
            delete settings[name]
        if (Object.keys(settings).length > 0)
            d.settings = settings
        else
            delete d.settings
        change(d, "stick:" + side + ":" + key, debounce)
    }

    function resetStick(side) {
        const d = editable()
        if (d.settings) {
            delete d.settings[side + "_stick"]
            if (Object.keys(d.settings).length === 0)
                delete d.settings
        }
        change(d, "resetStick:" + side, false)
    }

    function change(d, tag, debounce) {
        doc = d
        queued = { doc: d, tag: tag }
        if (debounce) {
            debounceTimer.restart()
        } else {
            debounceTimer.stop()
            flush()
        }
    }

    property Timer debounceTimer: Timer {
        interval: 300           // a held slider saves once it rests (not a Theme duration)
        onTriggered: games.flush()
    }

    function flush() {
        if (phase !== "" || queued === null || owner === "")
            return
        inFlight = queued
        queued = null
        phase = "validate"
        Input.validateProfile(JSON.stringify(inFlight.doc))
    }

    function done() {
        const tag = inFlight ? inFlight.tag : ""
        phase = ""
        inFlight = null
        saved(tag)
        refresh()
        if (queued !== null)
            flush()
        else if (exportVolume !== "")
            startExport()
    }

    function fail() {
        const tag = inFlight ? inFlight.tag : ""
        phase = ""
        inFlight = null
        queued = null
        debounceTimer.stop()
        doc = stored            // every row shows what the service has again
        if (exportVolume !== "") {
            exportVolume = ""
            Notifications.show(qsTr("Could not save to the USB drive"), "error", "", "", qsTr("Try again."))
        } else {
            Notifications.show(qsTr("Could not save the change"), "error", "", "", qsTr("Try again."))
        }
        failed(tag)
        refresh()
    }

    // Everything back to the default: the stored profile goes (and its assignment with it), an
    // assigned built-in is taken back.
    function resetAll() {
        debounceTimer.stop()
        queued = null
        if (phase !== "")
            return
        if (stored) {
            inFlight = { doc: null, tag: "reset" }
            phase = "delete"
            doc = null
            Input.deleteProfile(owner, stored.id)
        } else if (summary && summary.assigned) {
            inFlight = { doc: null, tag: "reset" }
            phase = "assign"
            doc = null
            Input.assignProfile(owner, "global", "", "")
        } else {
            doc = null
            saved("reset")
        }
    }

    // ---- export and import -----------------------------------------------------------------------
    // The profile goes to the volume as one file; one that is not stored yet is saved first.
    function exportTo(volumeId) {
        exportVolume = volumeId
        if (!stored && phase === "" && queued === null) {
            change(editable(), "export", false)
            return
        }
        if (phase === "" && queued === null)
            startExport()
    }
    function startExport() {
        const volume = exportVolume
        exportVolume = ""
        Input.exportProfile(owner, stored ? stored.id : ownId, volume)
    }

    function importFrom(volumeId, fileName) {
        if (importing)
            return
        importing = true
        Input.importProfile(owner, volumeId, fileName)
    }

    // ---- the answers -----------------------------------------------------------------------------
    property Connections replies: Connections {
        target: Input
        function onProfilesListed(profile, status, profiles) {
            if (profile !== games.owner)
                return
            if (status !== "ok") {
                games.loadState = "failed"
                return
            }
            const assigned = profiles.find(p => p.assigned === true && (p.scope === "global" || p.builtin === true)) ?? null
            games.summary = assigned
            if (assigned && assigned.builtin !== true) {
                Input.getProfile(games.owner, assigned.id)
                return
            }
            games.stored = null
            if (games.phase === "" && games.queued === null)
                games.doc = null
            games.loadState = "ok"
        }
        function onProfileFetched(profile, profileId, status, json) {
            if (profile !== games.owner || !games.summary || profileId !== games.summary.id)
                return
            if (status !== "ok") {
                games.loadState = "failed"
                return
            }
            let parsed = null
            try {
                parsed = JSON.parse(json)
            } catch (e) {
                games.loadState = "failed"
                return
            }
            games.stored = parsed
            if (games.phase === "" && games.queued === null)
                games.doc = parsed
            games.loadState = "ok"
        }
        function onProfileValidated(status, errors) {
            if (games.phase !== "validate")
                return
            if (status !== "ok") {
                games.fail()
                return
            }
            games.phase = "save"
            Input.saveProfile(games.owner, JSON.stringify(games.inFlight.doc))
        }
        function onProfileSaved(profile, status, profileId, errors) {
            if (games.phase !== "save" || profile !== games.owner)
                return
            if (status !== "ok") {
                games.fail()
                return
            }
            games.stored = games.inFlight.doc
            if (games.summary && games.summary.id === profileId && games.summary.assigned === true) {
                games.done()
                return
            }
            games.phase = "assign"
            Input.assignProfile(games.owner, "global", "", profileId)
        }
        function onProfileAssigned(profile, scope, scopeId, profileId, status) {
            if (games.phase !== "assign" || profile !== games.owner)
                return
            if (status !== "ok") {
                games.fail()
                return
            }
            games.done()
        }
        function onProfileDeleted(profile, profileId, status) {
            if (games.phase !== "delete" || profile !== games.owner)
                return
            if (status !== "ok") {
                games.fail()
                return
            }
            games.stored = null
            games.done()
        }
        function onProfilesChanged(profile) {
            if (profile === games.owner && games.phase === "")
                games.refresh()
        }
        function onServiceOwnedChanged() {
            if (Input.serviceOwned)
                games.refresh()
        }
        function onExportFinished(profile, profileId, volumeId, status, fileName) {
            if (profile !== games.owner)
                return
            if (status === "ok")
                Notifications.show(qsTr("Saved to the USB drive"), "success", "", "usb", fileName)
            else
                Notifications.show(qsTr("Could not save to the USB drive"), "error", "", "", qsTr("Try again."))
        }
        function onImportFinished(profile, volumeId, fileName, status, profileId, errors) {
            if (profile !== games.owner)
                return
            games.importing = false
            if (status === "ok") {
                Notifications.show(qsTr("Controls imported"), "success", "", "", fileName)
                games.refresh()
                games.imported(fileName)
                return
            }
            Notifications.show(qsTr("That file can't be used"), "error", "", "", games.importReason(status))
            games.importRefused(fileName, status)
        }
    }

    // Why an import was refused, in words (never a path or a field: those are in the journal).
    function importReason(status) {
        switch (status) {
        case "too-large": return qsTr("It is larger than 64 KB.")
        case "invalid":
        case "not-text":
        case "not-allowed":
        case "unknown-profile": return qsTr("It isn't a RuyaOS controls file.")
        }
        return qsTr("Try again.")
    }

    // ---- words -----------------------------------------------------------------------------------
    // The pad the pages are about: the one asked for, else the first connected one, else null.
    function padFor(id) {
        const list = ControllerPads.controllers()
        return list.find(p => p.id === id) ?? list[0] ?? null
    }
    // "DualSense": the pad's name without " Wireless Controller", at most 30 characters.
    function shortName(name) {
        const s = String(name ?? "").replace(/\s+Wireless Controller$/i, "")
        return Notifications.named(s !== "" ? s : String(name ?? ""), 30)
    }
    // "PlayStation controllers" for Applies to; "" for a pad without a family.
    function familyControllers(family) {
        switch (family) {
        case "playstation": return qsTr("PlayStation controllers")
        case "xbox": return qsTr("Xbox controllers")
        case "nintendo": return qsTr("Nintendo controllers")
        }
        return ""
    }
    // The button's name as the family prints it (face buttons by position until RUY-41's glyphs).
    function buttonName(input, family) {
        const ps = family === "playstation"
        const nin = family === "nintendo"
        switch (input) {
        case "none": return qsTr("Nothing")
        case "south": return ps ? qsTr("Cross") : "A"
        case "east": return ps ? qsTr("Circle") : "B"
        case "west": return ps ? qsTr("Square") : "X"
        case "north": return ps ? qsTr("Triangle") : "Y"
        case "l1": return ps ? "L1" : nin ? "L" : "LB"
        case "r1": return ps ? "R1" : nin ? "R" : "RB"
        case "left_trigger": return ps ? "L2" : nin ? "ZL" : "LT"
        case "right_trigger": return ps ? "R2" : nin ? "ZR" : "RT"
        case "l3": return ps ? "L3" : qsTr("Left stick click")
        case "r3": return ps ? "R3" : qsTr("Right stick click")
        case "dpad_up": return qsTr("D-pad up")
        case "dpad_down": return qsTr("D-pad down")
        case "dpad_left": return qsTr("D-pad left")
        case "dpad_right": return qsTr("D-pad right")
        case "select": return ps ? qsTr("Create") : nin ? qsTr("Minus") : qsTr("View")
        case "start": return ps ? qsTr("Options") : nin ? qsTr("Plus") : qsTr("Menu")
        }
        return input
    }
    // The text of a ButtonGlyph for the input: at most two letters, so it fits the row's icon slot.
    function glyphOf(input, family) {
        const ps = family === "playstation"
        const nin = family === "nintendo"
        switch (input) {
        case "none": return "–"
        case "south": return "A"
        case "east": return "B"
        case "west": return "X"
        case "north": return "Y"
        case "l3": return ps ? "L3" : "LS"
        case "r3": return ps ? "R3" : "RS"
        case "dpad_up": return "↑"
        case "dpad_down": return "↓"
        case "dpad_left": return "←"
        case "dpad_right": return "→"
        case "select": return ps ? "C" : nin ? "−" : "V"
        case "start": return ps ? "O" : nin ? "+" : "M"
        }
        return buttonName(input, family)
    }
}
