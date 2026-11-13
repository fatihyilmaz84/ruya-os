pragma Singleton
import QtQuick
import RuyaShell

// Controls in games (RUY-465, 06 §7): the signed-in console profile's global controller profiles as
// the pages edit them, over Input's profile calls (RUY-42), for one pad at a time (RUY-545: `show`).
// The console profile has up to one global profile per slot: all controllers (""), a family
// ("family:<f>") or one pad ("device:<id>"); a pad takes its device's, else its family's, else all
// controllers' (`applyingFor`, the service's rule). A profile inherits `nintendo` for the Nintendo
// layout and `default` otherwise, and holds only what differs: its `match` (the slot), the remapped
// buttons, the stick settings.
//
// An edit changes the pad's own profile: the stored one of its device's slot, of its family's, or
// the one Applies to = All controllers saved (`allId`). When nothing else applies (no profile, a
// built-in, or an all-controllers profile the page did not put there) the first edit makes a copy
// of it for This <pad> (`deviceProfileId`, match.device), so it reaches no other pad. Applies to
// moves the pad's settings to the chosen slot under that slot's id, replacing what the slot held;
// a wider slot also empties the narrower ones of this pad (so the pad takes it).
//
// Every change is shown at once (`doc`) and saved in the background: ValidateProfile, SaveProfile,
// AssignProfile when it is not assigned to its slot yet, then the slots to empty; a slider's change
// waits 300 ms for the next step first (`change(..., true)`). One save runs at a time and the newest
// change of each pad waits behind it, in order. A refused save toasts "Could not save the change" and `doc` goes
// back to what the service has (`stored`). Reset gives the pad the default (`resetAll`).
// Export and import go through Input.exportProfile / importProfile (Devices1.Storage).
// Also the words the pages share: button names and glyphs by family, the short pad name.
QtObject {
    id: games

    // The console profile whose controls these are ("" signed out).
    readonly property string owner: Profiles.activeProfile
    // The ids the pages save under, one per slot.
    readonly property string allId: "controls-all"
    function familyProfileId(family) {
        return "controls-family-" + family
    }
    // "controls-device-<the stable id, ':' as '-'>", at most 64 characters (a hash ends a long one).
    function deviceProfileId(device) {
        const s = String(device).toLowerCase().replace(/[^a-z0-9._-]/g, "-")
        const id = "controls-device-" + s
        return id.length <= 64 ? id : "controls-device-" + s.slice(0, 39) + "-" + Qt.md5(String(device)).slice(0, 8)
    }

    // The pad the pages are about: the id `show` was given, else the first connected one; null without one.
    property string padId: ""
    readonly property var pad: padFor(padId)
    readonly property string padKey: pad ? pad.id + "/" + pad.family : ""
    onPadKeyChanged: {
        stored = null
        doc = null
        if (owner !== "" && loadState !== "loading")
            resolve()
    }

    // "loading" before the first answer, "ok", or "failed" (ListProfiles or GetProfile failed).
    property string loadState: "loading"
    // The last ListProfiles answer (Input1's summaries).
    property var profiles: []
    // The summary of what applies to the pad, or null when nothing is assigned that fits it.
    property var summary: null
    // That profile as the service has it (an object), or null (none, or a built-in).
    property var stored: null
    // What the pages show: `stored`, or the newest change while it is on its way.
    property var doc: null

    // The save on its way: "" | "validate" | "save" | "assign" | "clear" | "delete".
    property string phase: ""
    property var inFlight: null         // { doc, tag, clears, padKey }
    // The changes waiting, oldest first: the newest one per pad ({ doc, tag, clears, padKey }).
    property var queue: []
    property string exportVolume: ""    // an export waits for the save before it
    property bool importing: false

    readonly property bool busy: phase !== "" || queue.length > 0
    // The pad's "Controls in games" value: the service's word for what applies to it.
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
        profiles = []
        summary = null
        stored = null
        doc = null
        queue = []
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

    // The pages' entry: their pad (`id`, "" for the first connected one) and a fresh list.
    function show(id) {
        padId = String(id ?? "")
        refresh()
    }

    // ---- the slots (06 §7, RUY-545) ---------------------------------------------------------------
    // The slot a match names: "device:<id>", else "family:<f>", else "" (all controllers).
    function slotOf(m) {
        const device = m?.device ?? ""
        const family = m?.family ?? ""
        return device !== "" ? "device:" + device : family !== "" ? "family:" + family : ""
    }
    function slotRank(slot) {
        return slot.startsWith("device:") ? 2 : slot.startsWith("family:") ? 1 : 0
    }
    // The summary of the profile that applies to pad `p` ({ id, family }, or null for no pad): its
    // device's slot, else its family's, else all controllers', looking only below `below` (a rank;
    // 3 looks at every slot); null when none.
    function applyingFor(p, below) {
        const limit = below === undefined ? 3 : below
        const fits = s => (s.match_family === "" || (p !== null && s.match_family === p.family))
                          && (s.match_device === "" || (p !== null && s.match_device === p.id))
        const slots = []
        if (p && p.id !== "" && limit > 2)
            slots.push("device:" + p.id)
        if (p && (p.family ?? "") !== "" && limit > 1)
            slots.push("family:" + p.family)
        if (limit > 0)
            slots.push("")
        for (const slot of slots) {
            const s = profiles.find(r => r.assigned === true && r.global_slot === slot
                                         && (r.scope === "global" || r.builtin === true) && fits(r))
            if (s)
                return s
        }
        return null
    }
    // A pad's "Controls in games" value (the controller page, Settings > Controllers).
    function changedFor(p) {
        const s = applyingFor(p ?? null)
        return s !== null && s.changed === true
    }

    // What applies to the pad now; its stored profile is fetched.
    function resolve() {
        const s = applyingFor(pad)
        summary = s
        if (s && s.builtin !== true) {
            Input.getProfile(owner, s.id)
            return
        }
        stored = null
        if (phase === "" && queue.length === 0)
            doc = null
        loadState = "ok"
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
    // What applies to the pad as a profile to change: the newest change, else the stored one (also
    // when it arrived while another pad's save was running), else a new one without an id (the
    // layout of an assigned built-in kept).
    function current() {
        const base = doc ?? stored
        if (base)
            return JSON.parse(JSON.stringify(base))
        const d = { schema_version: 1, id: "", name: "Controls in games", scope: { type: "global" } }
        if (summary && summary.builtin && summary.layout === "nintendo")
            d.inherits = "nintendo"
        return d
    }
    // The pad's own profile to change: what applies when it is the pad's own (its device's slot,
    // its family's, `allId`, or anything without a pad), else a copy of it for This <pad>.
    function editable() {
        const d = current()
        if (!pad) {
            if (d.id === "")
                d.id = allId
            return d
        }
        if (d.id !== "" && (slotOf(d.match) !== "" || d.id === allId))
            return d
        d.id = deviceProfileId(pad.id)
        d.match = { device: pad.id }
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
    // The pad's settings go to that slot under its id (replacing what it held); a wider slot than
    // now also empties this pad's narrower ones, so the pad takes it. Another pad's own profile is
    // never rewritten.
    function setAppliesTo(value) {
        const v = String(value)
        if (v === appliesValue)
            return
        const d = current()
        let slot = ""
        if (v.startsWith("family:") && v.length > 7) {
            d.id = familyProfileId(v.slice(7))
            d.match = { family: v.slice(7) }
            slot = v
        } else if (v.startsWith("device:") && v.length > 7) {
            d.id = deviceProfileId(v.slice(7))
            d.match = { device: v.slice(7) }
            slot = v
        } else {
            d.id = allId
            delete d.match
        }
        const clears = []
        if (pad) {
            const mine = profiles.filter(r => r.assigned === true).map(r => r.global_slot)
            if (doc)
                mine.push(slotOf(doc.match))
            for (const s of ["device:" + pad.id, "family:" + pad.family]) {
                if (s !== "family:" && slotRank(s) > slotRank(slot) && mine.includes(s) && !clears.includes(s))
                    clears.push(s)
            }
        }
        change(d, "match", false, clears)
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

    // `clears`: the slots to empty once `d` is saved and assigned (Applies to).
    function change(d, tag, debounce, clears) {
        doc = d
        // It replaces this pad's waiting change; another pad's waits on (RUY-545 round 2).
        queue = queue.filter(q => q.padKey !== padKey).concat([{ doc: d, tag: tag, clears: clears ?? [], padKey: padKey }])
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
        if (phase !== "" || queue.length === 0 || owner === "")
            return
        inFlight = queue[0]
        queue = queue.slice(1)
        phase = "validate"
        Input.validateProfile(JSON.stringify(inFlight.doc))
    }

    function done() {
        const tag = inFlight ? inFlight.tag : ""
        phase = ""
        inFlight = null
        saved(tag)
        refresh()
        if (queue.length > 0)
            flush()
        else if (exportVolume !== "")
            startExport()
    }

    // After the save and the assignment: the next slot to empty, else done.
    function clearNext() {
        const clears = inFlight ? inFlight.clears : []
        if (clears.length === 0) {
            done()
            return
        }
        inFlight = { doc: inFlight.doc, tag: inFlight.tag, clears: clears.slice(1), padKey: inFlight.padKey }
        phase = "clear"
        Input.assignProfile(owner, "global", clears[0], "")
    }

    function fail() {
        const tag = inFlight ? inFlight.tag : ""
        phase = ""
        inFlight = null
        queue = []
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

    // Everything back to the default for the pad (and the pads of its slot): its own stored
    // profile goes (and its assignment with it) when nothing changed would apply in its place;
    // otherwise its own profile is saved with nothing in it (a copy for This <pad> when what applies
    // is not its own), so no other slot's pads are touched.
    function resetAll() {
        queue = queue.filter(q => q.padKey !== padKey)
        if (queue.length === 0)
            debounceTimer.stop()
        if (phase !== "")
            return
        const d = editable()
        const own = stored !== null && d.id === stored.id
        const below = applyingFor(pad, slotRank(slotOf(d.match)))
        if (own && !(below && below.changed === true)) {
            inFlight = { doc: null, tag: "reset", clears: [], padKey: padKey }
            phase = "delete"
            doc = null
            Input.deleteProfile(owner, stored.id)
            return
        }
        if (!own && !changed) {
            doc = null
            saved("reset")
            return
        }
        const empty = { schema_version: 1, id: d.id, name: d.name, scope: { type: "global" } }
        if (d.match)
            empty.match = d.match
        change(empty, "reset", false)
    }

    // ---- export and import -----------------------------------------------------------------------
    // The profile goes to the volume as one file; one that is not stored yet is saved first.
    function exportTo(volumeId) {
        exportVolume = volumeId
        if (!stored && phase === "" && queue.length === 0) {
            change(editable(), "export", false)
            return
        }
        if (phase === "" && queue.length === 0)
            startExport()
    }
    function startExport() {
        const volume = exportVolume
        exportVolume = ""
        Input.exportProfile(owner, stored ? stored.id : editable().id, volume)
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
            games.profiles = profiles
            games.resolve()
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
            // Shown unless a change of this pad is on its way (`doc` is null after a pad switch,
            // so another pad's save running does not hide this pad's profile).
            if ((games.phase === "" && games.queue.length === 0) || games.doc === null)
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
            const d = games.inFlight.doc
            if (games.inFlight.padKey === games.padKey)
                games.stored = d
            const slot = games.slotOf(d.match)
            if (games.profiles.some(p => p.id === profileId && p.assigned === true && p.global_slot === slot)) {
                games.clearNext()
                return
            }
            games.phase = "assign"
            Input.assignProfile(games.owner, "global", slot, profileId)
        }
        function onProfileAssigned(profile, scope, scopeId, profileId, status) {
            if ((games.phase !== "assign" && games.phase !== "clear") || profile !== games.owner)
                return
            if (status !== "ok") {
                games.fail()
                return
            }
            games.clearNext()
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
