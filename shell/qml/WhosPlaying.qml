pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import RuyaShell

// "Who's playing?" for a new controller (RUY-122, ADR-017 points 2-3 and 6, 02 §1.9): a pad with no
// player connects (a slot-0 pad in a new device list), presses a button (Input.foreignInput "press",
// unless it chose Not now: quiet) or presses Guide (always), and this opens while a profile is signed
// in. It waits while the screen saver or another modal is up; asking pads wait in arrival order, and a
// waiting pad that disconnects is dropped. While it is open the asking pad drives the UI
// (Input.setNavigator), the keyboard too; the Shell pauses a game behind it as the Hub does
// (HubPause.overlayOpen) and routes Input "overlay".
//
// Step "pick": the console's kept profiles (any role) as cards; Accept on a free profile opens step
// "confirm" (Join or Switch), on a profile that plays now with a pad step "move" (RUY-628), on one that
// plays with no pad (player 1 after a keyboard sign-in or a hold that ran out) the PIN or the join at once.
// Step "pin": PinPad's player mode (Profiles.verifyPin, never a sign-in) for a profile with a PIN, typed
// with the asking pad; Back on an empty pad returns to the step before.
// Join and Move: Input.joinPlayer(pad, id), closed on "ok". Switch: Profiles.lock(), switchTo(id, pin),
// then joinPlayer(pad, id) once the new profile's seats exist. A refused join is a toast and the step
// before again. While seat 1 has no pad a seated pad's Guide ("player-guide") asks too, so a console
// with only seated pads left gets player 1 back without a keyboard (lead, RUY-628).
// Not now keeps the pad quiet: over a game until that game exits, over Home until the pad disconnects
// or the profile changes.
//
// Wake mode (RUY-707, ADR-017 amendment 7): a resume from sleep (`wake()`, from IdleClock.resumed) while
// seat 1 has no connected pad opens step "pick" with no asking pad: the signed-in profile's card first
// and focused ("Continue as <name>."), the other kept profiles after it (Accept = Switch, through its
// PIN), no Guest card and no Not now. Accept on the signed-in card, Back and Guide continue (no PIN):
// with a pad it joins as player 1, with the keyboard alone the prompt just closes. The keyboard drives
// it; the first pad that connects (or presses) takes it over as the navigator, the focus staying put.
FocusScope {
    id: prompt

    property real u: 1
    property real marginX: 0
    property real marginY: 0
    // The Shell: a profile is signed in and neither the picker nor Setup is up.
    property bool allowed: false
    // The Shell: the screen saver or another modal is up, so an asking pad waits.
    property bool blocked: false
    // The Shell: a game is in front (paused behind this), with its name and Session1 instance.
    property bool overGame: false
    property string gameName: ""
    property string gameInstance: ""
    // What the shared backdrop blur shows: the game's frozen frame, or Home's L0.
    property Item blurSource: null

    property bool shown: false
    property string step: "pick"         // "pick" | "confirm" | "move" | "pin"
    property string pad: ""              // the asking pad (stable id; "" in wake mode until a pad takes over)
    // Wake mode (RUY-707): opened by a resume, kept until the next open (so the row does not change
    // while it fades out). `wakePending`: a resume asked for it while it could not open yet.
    property bool wakeMode: false
    property bool wakePending: false
    // After a resume with seat 1's pad still listed, its removal may come late (a Bluetooth or 2.4 GHz pad
    // drops over its own path, in no order with the resume): for this long a removal still opens wake mode.
    property int wakeWatchMs: 10000
    property var queue: []               // pads waiting to ask, in arrival order
    // Not now (pad id -> { instance } over a game, { profile } over Home).
    property var quiet: ({})
    property var chosen: null            // the profile record of steps "confirm", "move" and "pin"
    // What the PIN step leads to and where its Back returns: "join" | "switch" (step "confirm"), "move",
    // "pick" (a profile that plays with no pad).
    property string pinFor: ""
    // A JoinPlayer on its way from here: { pad, id, from: "pick" | "confirm" | "move" | "switch" }.
    property var joining: null
    // A Switch between its Lock and the join: { pad, id, name, signedIn }.
    property var switching: null
    property var knownPads: []
    property bool padsPrimed: false
    // What had the focus when it opened (the Shell gives it back on close when it can still take it).
    property Item returnTo: null
    // Between two asking pads: the prompt closed for one and opens for the next in the same turn, so the
    // game stays frozen and the Shell moves no focus (RUY-122 round 2).
    property bool bridging: false
    // It pauses a game behind it (the Shell's HubPause and InputRoute): open, or between two prompts.
    readonly property bool pausing: shown || bridging
    // A Switch whose seat never came (the service did not answer) gives up after this (tests shorten it).
    property int switchTimeoutMs: 10000

    // Emitted before it hides for good (not between two prompts): the Shell may open the Hub then.
    signal aboutToClose()
    // `target`: the item that had the focus before (null when none).
    signal closed(Item target)

    // Every kept profile is a card, whatever its role (RUY-680: a guest-role profile is a person on this
    // console); only temporary guests (RUY-125, Profiles.guests, never in `profiles`) are the Guest card's.
    // In wake mode the signed-in profile's card comes first, the others keep the picker's order.
    readonly property var cards: {
        const kept = Profiles.profiles.filter(p => !Profiles.guests.some(g => g.id === p.id))
        if (!wakeMode)
            return kept
        const active = Profiles.activeProfile
        return kept.filter(p => p.id === active).concat(kept.filter(p => p.id !== active))
    }
    // The Guest card ends the row (RUY-631); its name is the card's own qsTr, so a language change never
    // replaces the model (that would reset the current index, RUY-664). A seated pad never asks (mayAsk),
    // so it is never offered a guest again; the one exception, a seated pad's Guide while seat 1 has no
    // pad, may make another. Wake mode has no Guest card (lead ruling, RUY-707: a temporary guest can never
    // be the active profile, so it cannot answer who takes over; guests join afterwards as usual).
    readonly property var entries: wakeMode ? cards
        : cards.concat([{ kind: "guest", id: "", name: "", avatar: "", hasPin: false }])
    readonly property int guestIndex: wakeMode ? -1 : cards.length

    readonly property var padRecord: Input.devices.find(d => d.id === prompt.pad)
    readonly property string padName: padRecord
        ? DeviceIcons.padNameFit(padRecord.id, padRecord.name ?? "", padRecord.family ?? "", 30)
        : ""
    readonly property string padIcon: padRecord
        ? DeviceIcons.iconFor("controller", padRecord.family ?? "", padRecord.model ?? "") : "sports_esports"
    readonly property var player1: Input.players.find(s => s.slot === 1)
    readonly property string player1Name: player1 ? Profiles.nameOf(player1.profile) : ""

    // Temporary guests (RUY-631). `createPads`: the requests ({ pad, seq }) whose CreateGuest has no answer
    // yet, in order; `seq` is the prompt (`openSeq`) that asked. `guestJoins`: guest id -> { pad, number,
    // answered } for a join of its own: it ends when the guest has its seat in the player list, or at the
    // next change of the list after the join answered ok, or after `seatWaitMs`. `ownGuests`: guests this
    // shell made or saw seated; the sweep removes
    // only these. `removing` / `removeTries`: RemoveGuest in flight, and how often it was sent per guest.
    property var createPads: []
    property var guestJoins: ({})
    property var ownGuests: ({})
    property var removing: ({})
    property var removeTries: ({})
    // The upper bound of the wait above, for a seat the player list never shows and a list that never
    // changes (a lost PlayersChanged). A slow bus must not end it earlier (RUY-664: the old fixed 3 s
    // removed a seated guest); a D-Bus call times out after 25 s, so nothing on a live bus takes longer.
    property int seatWaitMs: 30000
    // Counts the prompts that opened: a CreateGuest answer from an earlier one finds its prompt gone.
    property int openSeq: 0
    property string guestSession: ""

    // What the hint bar says (Shell.hintList).
    // In wake mode Back continues; with no pad yet the keyboard's key caps (Enter, Esc) are drawn.
    readonly property var modalHints: {
        const hints = step === "pin" ? pinPad.modalHints
            : step === "pick"
            ? [{ action: "accept", text: qsTr("Select") }, { action: "back", text: wakeMode ? qsTr("Continue") : qsTr("Not now") }]
            : [{ action: "accept", text: qsTr("Select") }, { action: "back", text: qsTr("Back") }]
        return wakeMode && pad === "" ? hints.map(h => Object.assign({ family: "keyboard" }, h)) : hints
    }

    // "%1 ... %2" filled in one pass, so a name with "%2" in it stays a name.
    function fill(template, one, two) {
        return template.replace(/%([12])/g, (m, n) => n === "1" ? one : two)
    }

    function seatOf(profileId) {
        return Input.players.find(s => s.profile === profileId)
    }
    // Player 1's profile while seat 1 has no pad (not held): picking it gives seat 1 this pad, no Move.
    function padlessPlayer1(profileId) {
        const s = seatOf(profileId)
        return s !== undefined && s.slot === 1 && (s.device_id ?? "") === "" && s.held !== true
    }
    // Seat 1 is signed in and has no pad (a keyboard sign-in, a hold that ran out).
    readonly property bool seat1Padless: player1 !== undefined && (player1.device_id ?? "") === "" && player1.held !== true
    function hasPad(profileId) {
        const s = seatOf(profileId)
        return s !== undefined && !padlessPlayer1(profileId)
    }
    // The profile sits on the asking pad itself (a seated pad that asked with its Guide).
    function onThisPad(profileId) {
        const s = seatOf(profileId)
        return s !== undefined && pad !== "" && (s.device_id ?? "") === pad
    }
    // The name of the pad a playing profile is on now ("another controller" for a held seat's gone pad).
    function seatPadName(profileId) {
        const s = seatOf(profileId)
        const d = s ? Input.devices.find(x => x.id === s.device_id) : undefined
        return d ? DeviceIcons.padNameFit(d.id, d.name ?? "", d.family ?? "", 30) : Notifications.named(qsTr("another controller"))
    }
    function guestName(number) {
        return number <= 1 ? qsTr("Guest") : qsTr("Guest %1").arg(number)
    }
    // The number the next guest gets: the lowest free one, as ruya-profiles numbers them.
    function nextGuestNumber() {
        const taken = Profiles.guests.map(g => g.number)
        let n = 1
        while (taken.includes(n))
            ++n
        return n
    }
    function guestDetail() {
        if (Profiles.guests.length >= 3)
            return qsTr("Three guests are already playing. One must leave first.")
        const n = nextGuestNumber()
        return n <= 1
            ? qsTr("Joins as a guest. Nothing is kept after it leaves.")
            : qsTr("Joins as Guest %1. Nothing is kept after it leaves.").arg(n)
    }
    // The profile the asking pad plays now (a seated pad that asked with its Guide), or "".
    function ownSeatProfile() {
        const s = pad === "" ? undefined : Input.players.find(x => (x.device_id ?? "") === pad)
        return s ? s.profile : ""
    }
    // A game or app of the signed-in profile runs (a wake Switch pauses and keeps it).
    readonly property bool signedInRunning: Session.running.some(r => r.profile === Profiles.activeProfile
                                                                       && r.state !== "stopping")
    // Wake mode: Continue on the signed-in card, a Switch on the others.
    function wakeDetailFor(record) {
        const name = Notifications.named(record.name)
        if (record.id === Profiles.activeProfile)
            return qsTr("Continue as %1.").arg(name)
        return signedInRunning
            ? fill(qsTr("Switches to %1. %2's games are paused and kept."), name,
                   Notifications.named(Profiles.nameOf(Profiles.activeProfile)))
            : qsTr("Switches to %1.").arg(name)
    }
    function detailFor(record) {
        if (record && wakeMode && record.kind !== "guest")
            return wakeDetailFor(record)
        if (record && record.kind === "guest")
            return guestDetail()
        // Picking the padless player 1 gives it this pad: the pad stops playing as its own profile (RUY-664).
        if (record && padlessPlayer1(record.id) && ownSeatProfile() !== "")
            return qsTr("This controller stops playing as %1.").arg(Notifications.named(Profiles.nameOf(ownSeatProfile())))
        if (!record || !hasPad(record.id) || onThisPad(record.id))
            return ""
        return fill(qsTr("Now on %2. Picking it moves %1 here."), record.name, seatPadName(record.id))
    }

    function inside(item) {
        for (let p = item; p; p = p.parent) {
            if (p === prompt)
                return true
        }
        return false
    }
    function connected(id) {
        return Input.devices.some(d => d.id === id)
    }
    function seated(id) {
        return Input.players.some(s => (s.device_id ?? "") === id)
    }
    // A pad that may ask now: an unseated one, or while seat 1 has no pad a seat 2-4 pad (its Guide).
    function mayAsk(id) {
        return !seated(id) || (seat1Padless && Input.players.some(s => s.slot > 1 && (s.device_id ?? "") === id))
    }

    // A pad asks (reason "connect", "press" or "guide").
    function ask(id, reason) {
        if (!allowed || id === "")
            return
        if (reason === "press" && quiet[id] !== undefined)
            return
        if (mayTakeOver(id)) {
            takeOver(id)                // the wake step with no pad yet: this pad drives it, no second prompt
            return
        }
        if ((shown && pad === id) || queue.includes(id) || !mayAsk(id) || (seated(id) && reason !== "player-guide"))
            return
        queue = queue.concat([id])
        Qt.callLater(prompt.tryOpen)
    }

    // ---- wake mode (RUY-707) ----
    // Seat 1's pad is there (a USB pad stays connected through a sleep): a wake changes nothing then.
    // A held seat 1 (RUY-627) has lost its pad, even while the device list still names it.
    function seat1PadConnected() {
        const id = player1 ? (player1.device_id ?? "") : ""
        return id !== "" && player1.held !== true && connected(id)
    }
    function wakeWanted() {
        return allowed && Profiles.activeProfile !== "" && !seat1PadConnected()
    }
    // A resume from sleep (the Shell routes IdleClock.resumed here): with a profile signed in and no
    // connected pad on seat 1 the prompt opens in wake mode, at once or as soon as nothing blocks it.
    // With seat 1's pad still connected the wake watch runs (`wakeWatchMs`): a removal inside it is a wake.
    function wake() {
        if (shown && wakeMode)
            return
        if (!wakeWanted()) {
            if (allowed && Profiles.activeProfile !== "")
                wakeWatch.restart()
            return
        }
        wakeWatch.stop()
        wakePending = true
        tryOpen()
    }
    // The watch runs and seat 1's pad has just gone (the device list, or the seat held): the wake after all.
    // The Shell calls it first on a players change, so it opens before any lost-pad Hub.
    function checkLateWake() {
        if (!wakeWatch.running || !wakeWanted())
            return
        console.info("ruya-shell: seat 1's pad went just after the wake: Who's playing? opens in wake mode")
        wake()
    }
    Timer {
        id: wakeWatch
        objectName: "whosPlayingWakeWatch"
        interval: prompt.wakeWatchMs
    }
    // The wake step has no pad yet: a pad that connects or presses drives it, an unseated one or seat 1's
    // own pad rebinding into its held seat (RUY-627). A seat 2-4 pad keeps its seat and its normal prompt.
    function mayTakeOver(id) {
        return shown && wakeMode && pad === "" && id !== ""
               && (!seated(id) || (player1 !== undefined && (player1.device_id ?? "") === id))
    }
    function takeOver(id) {
        pad = id
        Input.setNavigator(id)
        if (step === "pin")
            pinPad.deviceId = id        // the PIN step's pad line names it too
    }

    function tryOpen() {
        if (!shown && allowed && !blocked && switching === null) {
            if (wakePending) {
                wakePending = false
                if (wakeWanted()) {
                    open("", true)
                    return
                }
            }
            while (queue.length > 0) {
                const id = queue[0]
                queue = queue.slice(1)
                if (connected(id) && mayAsk(id)) {
                    open(id)
                    return
                }
            }
        }
        endBridge()
    }

    // A bridge that leads nowhere (the next pad went, a modal came): the prompt is closed for good now.
    function endBridge() {
        if (!bridging)
            return
        bridging = false
        aboutToClose()                  // a lost-pad Hub held back for the prompt opens now (RUY-122 review)
        const target = returnTo
        returnTo = null
        closed(target)
    }

    // `wake`: wake mode, with no asking pad (`id` "").
    function open(id, wake) {
        if (!bridging) {
            const f = Window.activeFocusItem
            returnTo = f && !inside(f) ? f : null
        }
        openSeq += 1
        wakeMode = wake === true        // before the focus: the row (the model) is the wake row now
        if (wakeMode)
            wakeWatch.stop()
        if (wakeMode)
            console.info("ruya-shell: woke with no pad on seat 1: Who's playing? opens in wake mode")
        pad = id
        step = "pick"
        chosen = null
        pinFor = ""
        joining = null
        downKey = 0
        shown = true
        bridging = false                // after `shown`, so `pausing` never drops between two prompts
        if (id !== "")
            Input.setNavigator(id)
        focusFirst()
    }

    // Player 1 without a pad, else the asking pad's owner (the last profile that played on it, RUY-124;
    // focus only: the PIN is asked as always, and a profile that plays on another pad still gets it,
    // Accept then being Move), else the first profile without a pad, else the Guest card (Not now when
    // the profiles are not there).
    function focusFirst() {
        // Wake mode: the signed-in profile's card, always (ahead of the owner rule; it is the first card).
        if (wakeMode) {
            if (Profiles.available && cards.length > 0) {
                cardList.currentIndex = 0
                cardList.forceActiveFocus()
            } else {
                prompt.forceActiveFocus()   // no cards to focus: Back and Guide still continue
            }
            return
        }
        // Seat 1 without a pad: player 1's card first (the one-press way back, lead RUY-122 round 2).
        const own = Profiles.available ? cards.findIndex(p => padlessPlayer1(p.id)) : -1
        const owner = Profiles.available && padRecord && padRecord.owner ? cards.findIndex(p => p.id === padRecord.owner) : -1
        const i = own >= 0 ? own : owner >= 0 ? owner : Profiles.available ? cards.findIndex(p => !hasPad(p.id)) : -1
        if (i >= 0) {
            cardList.currentIndex = i
            cardList.forceActiveFocus()
        } else if (Profiles.available) {
            cardList.currentIndex = guestIndex      // no profile is free: the Guest card (the empty board)
            cardList.forceActiveFocus()
        } else {
            notNowButton.forceActiveFocus()
        }
    }

    // Closes; `quietPad`: Not now (the pad stays quiet as above).
    function close(quietPad) {
        if (!shown)
            return
        if (quietPad && connected(pad)) {
            const next = Object.assign({}, quiet)
            next[pad] = overGame ? { instance: gameInstance, profile: "" } : { instance: "", profile: Profiles.activeProfile }
            quiet = next
        }
        // Another pad waits and may ask now (or a wake does): keep the pause and the focus for it.
        bridging = allowed && !blocked && switching === null
                   && ((wakePending && wakeWanted()) || queue.some(i => i !== pad && connected(i) && mayAsk(i)))
        if (!bridging)
            aboutToClose()
        shown = false
        if (pinPad.shown)
            pinPad.close()              // a half-typed PIN never outlives the prompt
        step = "pick"
        chosen = null
        pinFor = ""
        joining = null
        const was = pad
        pad = ""
        if (was !== "" && Input.navigator === was)
            Input.setNavigator("")
        if (!bridging) {
            const target = returnTo
            returnTo = null
            closed(target)
        }
        Qt.callLater(prompt.tryOpen)
    }

    function notNow() {
        Sfx.back()
        close(true)
    }

    // Wake mode: Continue as the signed-in profile, no PIN (sleep does not lock the console, lead ruling
    // RUY-707). With a pad it joins as player 1 (closed on "ok"); with the keyboard alone it just closes and
    // seat 1 stays as it was.
    function continueAsSignedIn() {
        if (joining !== null)
            return
        if (pad === "" || !connected(pad)) {
            close(false)
            return
        }
        chosen = cards.find(p => p.id === Profiles.activeProfile) ?? null
        join(Profiles.activeProfile, "pick")
    }
    // Wake mode: Back and Guide on any card continue (the one-press way back to the game or Home).
    function wakeBack() {
        if (joining !== null)
            return
        Sfx.back()
        continueAsSignedIn()
    }
    // Wake mode: Accept on another profile is a Switch, through its PIN when it has one (no Join or Switch).
    function acceptWakeCard(record) {
        Sfx.select()
        if (record.id === Profiles.activeProfile) {
            continueAsSignedIn()
            return
        }
        chosen = record
        if (record.hasPin)
            askPin("switch")
        else
            switchTo("")
    }

    function acceptCard(index) {
        if (joining !== null || index < 0 || index >= entries.length)
            return
        if (wakeMode) {
            acceptWakeCard(cards[index])
            return
        }
        if (index === guestIndex) {
            acceptGuest()
            return
        }
        const record = cards[index]
        Sfx.select()
        chosen = record
        if (onThisPad(record.id)) {
            join(record.id, "pick")     // it plays on this pad already: the service changes nothing, it closes
        } else if (hasPad(record.id)) {
            step = "move"
            moveCancelButton.forceActiveFocus()
        } else if (seatOf(record.id) !== undefined) {
            // It plays with no pad (player 1 after a keyboard sign-in or its hold): no Move to confirm.
            if (record.hasPin)
                askPin("pick")
            else
                join(record.id, "pick")
        } else {
            step = "confirm"
            joinButton.forceActiveFocus()
        }
    }

    // Accept on Guest: a temporary guest is made, then the pad joins it at once (no PIN, no step 2). With
    // three guests playing there is nothing to make: the back sound and no call.
    function acceptGuest() {
        if (Profiles.guests.length >= 3) {
            Sfx.back()
            return
        }
        Sfx.select()
        chosen = null
        createPads = createPads.concat([{ pad: pad, seq: openSeq }])
        joining = { pad: pad, id: "", from: "guest", number: 0 }
        Profiles.createGuest()
    }

    function guestCreated(status, id, number) {
        if (createPads.length === 0)
            return                              // not made for the prompt
        const p = createPads[0].pad
        const seq = createPads[0].seq
        createPads = createPads.slice(1)
        const own = joining !== null && joining.from === "guest" && joining.id === "" && joining.pad === p
        if (status !== "ok") {
            if (own) {
                joining = null
                refused(qsTr("Guest"))
                if (shown && pad === p)
                    cardList.forceActiveFocus()
            }
            return
        }
        ownGuests[id] = true
        if (!shown || seq !== openSeq) {
            // Not now or Guide came before the answer: nobody said yes to this guest, so it is not seated.
            // It stays unseated and the sweep removes it (RUY-664).
            sweepSoon()
            return
        }
        guestJoins[id] = { pad: p, number: number, answered: false }
        if (own)
            joining = { pad: p, id: id, from: "guest", number: number }
        Input.joinPlayer(p, id)
        sweepSoon()
    }

    // The answer to the join of a guest of this prompt (whether or not the prompt is still up).
    function guestJoinFinished(profile, status) {
        const gj = guestJoins[profile]
        if (joining !== null && joining.from === "guest" && joining.id === profile)
            joining = null
        if (status === "ok") {
            gj.answered = true
            // Its seat may be in the list already (PlayersChanged came first); else the next change of the
            // list ends the wait (onPlayersChanged), the seat showing up does (sweepGuests), or the bound.
            if (Input.players.some(s => s.profile === profile))
                delete guestJoins[profile]
            else
                seatWait.restart()
            if (shown && pad === gj.pad)
                close(false)
        } else {
            delete guestJoins[profile]
            refused(guestName(gj.number))
            if (shown && pad === gj.pad)
                cardList.forceActiveFocus()
        }
        sweepSoon()
    }

    // One sweep (RUY-631): every guest of ours that has no seat and no join on its way is removed, all in
    // one go: a guest that left (LeavePlayer, the 60 s hold, its pad took another profile), a guest whose
    // join was refused, one made for a prompt that went. After a Lock or Switch ruya-profiles has wiped
    // them (the list is empty, or RemoveGuest answers unknown-profile, which counts as done).
    function sweepSoon() {
        Qt.callLater(prompt.sweepGuests)
    }
    function sweepGuests() {
        if (Profiles.activeProfile === "")
            return
        const seated = Input.players.map(s => s.profile)
        const listed = Profiles.guests.map(g => g.id)
        for (const id of seated) {
            if (listed.includes(id))
                ownGuests[id] = true
            if (guestJoins[id] !== undefined && guestJoins[id].answered)
                delete guestJoins[id]           // its seat is in the player list: the join is over
        }
        for (const id in ownGuests) {
            if (!listed.includes(id) && removing[id] === undefined) {
                delete ownGuests[id]
                delete removeTries[id]
            }
        }
        const todo = listed.filter(id => ownGuests[id] === true && !seated.includes(id)
                                         && guestJoins[id] === undefined && removing[id] === undefined
                                         && (removeTries[id] ?? 0) < 2)
        for (const id of todo) {
            removing[id] = true
            removeTries[id] = (removeTries[id] ?? 0) + 1
            Profiles.removeGuest(id)
        }
    }
    function guestRemoved(id, status) {
        if (removing[id] === undefined)
            return
        delete removing[id]
        if (status === "ok" || status === "unknown-profile") {
            delete ownGuests[id]
            delete removeTries[id]
        } else {
            console.warn("ruya-shell: RemoveGuest " + id + " failed: " + status + " (try " + (removeTries[id] ?? 1) + ")")
        }
    }
    Timer {
        id: seatWait
        interval: prompt.seatWaitMs
        onTriggered: {
            for (const id in prompt.guestJoins) {
                if (prompt.guestJoins[id].answered)
                    delete prompt.guestJoins[id]    // the upper bound: the sweep decides
            }
            prompt.sweepGuests()
        }
    }

    function askPin(forWhat) {
        pinFor = forWhat
        step = "pin"
        pinPad.verifyPlayer(chosen, pad)
    }

    // Join, Move or Switch on the chosen profile, through its PIN when it has one.
    function proceed(forWhat) {
        if (!chosen || joining !== null)
            return
        Sfx.select()
        if (chosen.hasPin)
            askPin(forWhat)
        else if (forWhat === "switch")
            switchTo("")
        else
            join(chosen.id, forWhat === "move" ? "move" : "confirm")
    }

    // The PIN was right: the step it came from again (shown while the join is on its way; a refused one
    // puts the focus on its first button), then the action. On Move the focus waits on Move, not Cancel,
    // and Accept and Back do nothing until the join answers. The PIN goes only to a Switch's switchTo.
    function pinVerified(pin) {
        if (!shown || step !== "pin" || !chosen)
            return
        const forWhat = pinFor
        pinFor = ""
        if (forWhat === "switch") {
            step = "confirm"
            switchTo(pin)
        } else if (forWhat === "move") {
            step = "move"
            moveButton.forceActiveFocus()
            join(chosen.id, "move")
        } else if (forWhat === "join") {
            step = "confirm"
            joinButton.forceActiveFocus()
            join(chosen.id, "confirm")
        } else {
            backToCard()
            join(chosen.id, "pick")
        }
    }

    // Back on an empty PIN pad: the step before, on its first button (or the card).
    function pinCancelled() {
        if (!shown || step !== "pin")
            return
        const forWhat = pinFor
        pinFor = ""
        if (forWhat === "move") {
            step = "move"
            moveCancelButton.forceActiveFocus()
        } else if (forWhat === "switch" && wakeMode) {
            backToCard()                // the wake step on that card
            chosen = null
        } else if (forWhat === "join" || forWhat === "switch") {
            step = "confirm"
            joinButton.forceActiveFocus()
        } else {
            backToCard()
        }
    }

    function join(id, from) {
        joining = { pad: pad, id: id, from: from }
        Input.joinPlayer(pad, id)
    }

    // `pin`: the profile's PIN, right (checked by the PIN step) or "" for none; it is not kept.
    function switchTo(pin) {
        if (!chosen || joining !== null)
            return
        switching = { pad: pad, id: chosen.id, name: chosen.name, signedIn: false }
        switchGuard.restart()
        close(false)
        Profiles.lock()
        Profiles.switchTo(switching.id, pin)
    }

    // The new profile is signed in and its seats exist: the pad becomes its player 1.
    function joinAfterSwitch() {
        if (switching && switching.signedIn && switching.pad === "") {
            switching = null            // a wake Switch with the keyboard: nobody to seat, it ends here
            switchGuard.stop()
            return
        }
        if (!switching || !switching.signedIn || !player1 || player1.profile !== switching.id)
            return
        const s = switching
        switching = null
        switchGuard.stop()
        joining = { pad: s.pad, id: s.id, from: "switch" }
        Input.joinPlayer(s.pad, s.id)
    }

    // The name is the caller's: a refused Switch may be about a profile that is gone.
    function refused(name) {
        Notifications.show(qsTr("%1 could not join").arg(Notifications.named(name)), "error", "", "",
                           qsTr("Try again."))
    }

    // Back (or Cancel) on Join or Switch and on Move: step 1 on that card.
    function backFromConfirm() {
        Sfx.back()
        backToCard()
        chosen = null
    }

    // Step "pick" on the chosen profile's card.
    function backToCard() {
        const i = chosen ? cards.findIndex(p => p.id === chosen.id) : -1
        step = "pick"
        if (i >= 0)
            cardList.currentIndex = i
        cardList.forceActiveFocus()
    }

    // Quiet pads and the queue follow the pads, the games and the profile.
    function devicesUpdated() {
        const ids = Input.devices.map(d => d.id)
        if (padsPrimed && allowed) {
            for (const d of Input.devices) {
                if (!knownPads.includes(d.id) && ((d.slot ?? 0) === 0 || mayTakeOver(d.id)))
                    ask(d.id, "connect")
            }
        }
        knownPads = ids
        if (!padsPrimed && Input.devicesState === "ok")
            padsPrimed = true
        const kept = {}
        for (const k in quiet) {
            if (ids.includes(k))
                kept[k] = quiet[k]
        }
        quiet = kept
        queue = queue.filter(i => ids.includes(i))
        if (switching && switching.pad !== "" && !ids.includes(switching.pad))
            abandonSwitch()                     // the pad that asked is gone: no seat will come
        if (shown && wakeMode && pad !== "" && !ids.includes(pad)) {
            // The wake step's pad is gone: the keyboard drives it again (it stays open).
            const was = pad
            pad = ""
            if (Input.navigator === was)
                Input.setNavigator("")
            if (step === "pin")
                pinPad.deviceId = ""
        } else if (shown && !wakeMode && !ids.includes(pad)) {
            close(true)                 // the asking pad is gone: as Not now
        }
        checkLateWake()
    }

    onAllowedChanged: {
        if (!allowed) {
            queue = []
            wakePending = false
            wakeWatch.stop()
            close(false)
        } else {
            Qt.callLater(prompt.tryOpen)
        }
    }
    onBlockedChanged: if (!blocked) Qt.callLater(prompt.tryOpen)
    Component.onCompleted: {
        knownPads = Input.devices.map(d => d.id)
        padsPrimed = Input.devicesState === "ok"
    }

    Connections {
        target: Input
        function onDevicesChanged() { prompt.devicesUpdated() }
        function onDevicesStateChanged() {
            if (!prompt.padsPrimed && Input.devicesState === "ok") {
                prompt.knownPads = Input.devices.map(d => d.id)
                prompt.padsPrimed = true
            }
        }
        function onForeignInput(deviceId, kind) {
            if (kind === "press" || kind === "guide" || kind === "player-guide")
                prompt.ask(deviceId, kind)
        }
        function onPlayersChanged() {
            // A join that answered ok waited for this change of the list; the sweep decides now (a guest
            // seated in the list stays).
            for (const id in prompt.guestJoins) {
                if (prompt.guestJoins[id].answered)
                    delete prompt.guestJoins[id]
            }
            prompt.joinAfterSwitch()
            prompt.sweepSoon()
            // A late wake on a players change: the Shell calls checkLateWake() first, before its lost-pad Hub.
        }
        function onJoinFinished(deviceId, profile, status, slot) {
            if (status === "ok" && prompt.quiet[deviceId] !== undefined) {
                // A join that landed after Not now (it was on its way): the pad plays, so it is not quiet.
                const next = Object.assign({}, prompt.quiet)
                delete next[deviceId]
                prompt.quiet = next
            }
            const gj = prompt.guestJoins[profile]
            if (gj !== undefined && gj.pad === deviceId && !gj.answered) {
                prompt.guestJoinFinished(profile, status)
                return
            }
            const j = prompt.joining
            if (!j || j.pad !== deviceId || j.id !== profile)
                return
            prompt.joining = null
            if (status === "ok") {
                if (prompt.shown)
                    prompt.close(false)
                return
            }
            prompt.refused(Profiles.nameOf(profile))
            if (!prompt.shown)
                return
            if (j.from === "confirm")
                joinButton.forceActiveFocus()
            else if (j.from === "move")
                moveCancelButton.forceActiveFocus()
            else
                cardList.forceActiveFocus()
        }
    }
    Connections {
        target: Profiles
        function onActiveProfileChanged() {
            if (prompt.guestSession !== Profiles.activeProfile) {
                prompt.guestSession = Profiles.activeProfile
                prompt.ownGuests = {}           // a new session: its guests are wiped by ruya-profiles
                prompt.guestJoins = {}
                prompt.removeTries = {}
            }
            const next = {}
            for (const k in prompt.quiet) {
                if (prompt.quiet[k].instance !== "")
                    next[k] = prompt.quiet[k]
            }
            prompt.quiet = next
            if (prompt.switching && Profiles.activeProfile === prompt.switching.id)
                prompt.switching = Object.assign({}, prompt.switching, { signedIn: true })
            else if (prompt.switching && Profiles.activeProfile !== "")
                prompt.abandonSwitch()          // another profile signed in: this Switch has no seat to wait for
            prompt.joinAfterSwitch()
        }
        function onGuestsChanged() { prompt.sweepSoon() }
        function onGuestCreated(status, id, number) { prompt.guestCreated(status, id, number) }
        function onGuestRemoved(id, status) { prompt.guestRemoved(id, status) }
        function onSwitchFinished(id, status) {
            const s = prompt.switching
            if (!s || s.id !== id || status === "ok")
                return
            prompt.switching = null      // the picker stays up
            switchGuard.stop()
            prompt.refused(s.name)
        }
    }
    // A Switch that never gets its seat (the service did not answer, the asking pad went, another profile
    // signed in): it gives up, with the error toast, so it never keeps the prompt shut for the session.
    function abandonSwitch() {
        const s = switching
        if (!s)
            return
        switching = null
        switchGuard.stop()
        refused(s.name)
        Qt.callLater(prompt.tryOpen)
    }
    Timer {
        id: switchGuard
        interval: prompt.switchTimeoutMs
        onTriggered: prompt.abandonSwitch()
    }

    Connections {
        target: Session
        function onAppExited(instance) {
            const next = {}
            for (const k in prompt.quiet) {
                if (prompt.quiet[k].instance !== instance)
                    next[k] = prompt.quiet[k]
            }
            prompt.quiet = next
        }
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    // L0 of the prompt: the frozen frame (or Home) under the shared backdrop blur, then the scrim.
    Item {
        id: frame
        objectName: "whosPlayingFrame"
        anchors.fill: parent
        readonly property bool blurred: Theme.blurMax > 0

        ShaderEffectSource {
            id: frameCopy
            anchors.fill: parent
            visible: !frame.blurred
            sourceItem: prompt.shown || prompt.visible ? prompt.blurSource : null
            textureSize: frame.blurred ? Qt.size(Math.max(1, prompt.width / 4), Math.max(1, prompt.height / 4))
                                       : Qt.size(Math.max(1, prompt.width), Math.max(1, prompt.height))
        }
        MultiEffect {
            objectName: "whosPlayingBlur"
            anchors.fill: parent
            visible: frame.blurred
            source: frameCopy
            autoPaddingEnabled: false
            blurEnabled: true
            blur: 1.0
            blurMax: Theme.blurMax
        }
    }
    Rectangle {
        objectName: "whosPlayingScrim"
        anchors.fill: parent
        color: Theme.scrim
    }

    // Over a game: "Paused · <game>" at the safe area's top-left (04 proposal 6).
    GlassPill {
        id: pausedPill
        objectName: "whosPlayingPausedPill"
        visible: prompt.overGame
        x: prompt.marginX
        y: prompt.marginY
        height: 80 * prompt.u
        width: pausedText.implicitWidth + 2 * Theme.spaceL * prompt.u
        u: prompt.u
        source: frame
        sourceX: x
        sourceY: y

        Text {
            id: pausedText
            objectName: "whosPlayingPausedText"
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: qsTr("Paused · %1").arg(Notifications.named(prompt.gameName))
            color: Theme.text
            font.pixelSize: Theme.typeBody * prompt.u
            font.weight: Theme.weightDemiBold
        }
    }

    // The pad line: its icon and "<pad> wants to play".
    component PadLine: Row {
        id: line
        property real u: 1
        property string icon
        property string label
        spacing: Theme.spaceS * u
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            u: line.u
            size: Theme.iconM
            name: line.icon
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: line.label
            color: Theme.text
            font.pixelSize: Theme.typeBody * line.u
        }
    }
    // Wake mode with no pad yet: the generic pad icon (padIcon) and the call to turn one on.
    readonly property string padLineText: wakeMode && pad === "" ? qsTr("Turn on a controller to play")
                                                                 : qsTr("%1 wants to play").arg(padName)

    // ---- step "pick" ----------------------------------------------------------------------------
    Column {
        id: pickStep
        objectName: "whosPlayingPick"
        anchors.centerIn: parent
        visible: prompt.step === "pick"
        width: prompt.width

        PadLine {
            objectName: "whosPlayingPadLine"
            anchors.horizontalCenter: parent.horizontalCenter
            u: prompt.u
            icon: prompt.padIcon
            label: prompt.padLineText
        }
        Item { width: 1; height: Theme.spaceM * prompt.u }
        Text {
            id: pickTitle
            objectName: "whosPlayingTitle"
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Who's playing?")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * prompt.u
            font.weight: Theme.weightLight
        }
        Item { width: 1; height: Theme.spaceXxl * prompt.u }
        Item {
            id: cardSlot
            objectName: "whosPlayingCardSlot"
            width: parent.width
            height: Theme.cardProfileHeight * prompt.u

            ListView {
                id: cardList
                objectName: "whosPlayingCards"
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(contentWidth, prompt.width * 0.9)
                height: parent.height
                visible: Profiles.available
                orientation: ListView.Horizontal
                spacing: Theme.spaceXl * prompt.u
                interactive: false
                keyNavigationEnabled: true
                Accessible.role: Accessible.List
                Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("Profiles")
                model: prompt.entries

                delegate: ProfileCard {
                    u: prompt.u
                    playerSlot: {
                        const s = modelData.id === "" ? undefined : prompt.seatOf(modelData.id)
                        return s ? s.slot : 0
                    }
                }

                Keys.onPressed: event => {
                    event.accepted = true
                    if (event.key === Qt.Key_Left) {
                        if (currentIndex > 0) {
                            Sfx.navigate()
                            decrementCurrentIndex()
                        }
                    } else if (event.key === Qt.Key_Right) {
                        if (currentIndex < count - 1) {
                            Sfx.navigate()
                            incrementCurrentIndex()
                        }
                    } else if (event.key === Qt.Key_Down) {
                        if (!prompt.wakeMode) {             // wake mode has no button under the cards
                            Sfx.navigate()
                            notNowButton.forceActiveFocus()
                        }
                    } else {
                        event.accepted = false      // Accept, Back and the rest: the prompt's own handler
                    }
                }
            }

            Text {
                objectName: "whosPlayingWaiting"
                anchors.centerIn: parent
                visible: !Profiles.available
                text: qsTr("Waiting for the profiles service…")
                color: Theme.text
                font.pixelSize: Theme.typeBody * prompt.u
            }
        }
        Item { width: 1; height: Theme.spaceL * prompt.u }
        Text {
            id: detailLine
            objectName: "whosPlayingDetail"
            anchors.horizontalCenter: parent.horizontalCenter
            width: prompt.width * 0.9               // fixed, so the line keeps its place in the column when empty
            height: Theme.spaceL * prompt.u        // 36 u, reserved even when empty
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: cardList.activeFocus && Profiles.available ? prompt.detailFor(prompt.entries[cardList.currentIndex]) : ""
            color: Theme.text
            font.pixelSize: Theme.typeBody * prompt.u
        }
        // Wake mode ends the column at the detail line (no Not now, so it is 120 u shorter and re-centres).
        Item { width: 1; height: Theme.spaceL * prompt.u; visible: !prompt.wakeMode }
        SecondaryButton {
            id: notNowButton
            objectName: "whosPlayingNotNow"
            visible: !prompt.wakeMode
            anchors.horizontalCenter: parent.horizontalCenter
            u: prompt.u
            width: Math.max(300 * prompt.u, implicitWidth)
            text: qsTr("Not now")
            acceptOnRelease: true                   // the prompt acts on the release (below)
            Keys.onUpPressed: {
                if (cardList.visible && cardList.count > 0) {
                    Sfx.navigate()
                    cardList.forceActiveFocus()
                }
            }
        }
    }

    // ---- steps "confirm" (Join or Switch) and "move": the Dialog card of PowerConfirm --------------
    Rectangle {
        objectName: "whosPlayingConfirmPanel"
        anchors.centerIn: parent
        visible: prompt.step === "confirm" || prompt.step === "move"
        width: confirmColumn.width + 2 * 60 * prompt.u
        height: confirmColumn.height + 2 * Theme.spaceXl * prompt.u
        radius: Theme.radiusL * prompt.u
        color: Theme.panel
        border.color: Theme.glassBorder

        Column {
            id: confirmColumn
            anchors.centerIn: parent
            spacing: Theme.spaceL * prompt.u
            readonly property real maxWidth: 1300 * prompt.u - 2 * 60 * prompt.u

            PadLine {
                anchors.horizontalCenter: parent.horizontalCenter
                u: prompt.u
                icon: prompt.padIcon
                label: prompt.padLineText
            }
            Rectangle {
                objectName: "whosPlayingConfirmAvatar"
                anchors.horizontalCenter: parent.horizontalCenter
                width: 120 * prompt.u
                height: width
                radius: width / 2
                color: prompt.chosen ? prompt.chosen.avatar : Theme.glass
                Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: prompt.chosen ? prompt.chosen.name.charAt(0).toUpperCase() : ""
                    color: Theme.text
                    font.pixelSize: Theme.typeDisplay * prompt.u
                    font.weight: Theme.weightLight
                }
            }
            Text {
                objectName: "whosPlayingConfirmTitle"
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(implicitWidth, confirmColumn.maxWidth)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: (prompt.step === "move" ? qsTr("Move %1 to this controller?") : qsTr("Join in or switch to %1?"))
                    .arg(prompt.chosen ? Notifications.named(prompt.chosen.name) : "")
                color: Theme.text
                font.pixelSize: Theme.typeTitle * prompt.u
                font.weight: Theme.weightDemiBold
            }
            Text {
                objectName: "whosPlayingConfirmDetail"
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(implicitWidth, 1100 * prompt.u)
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: prompt.step === "move"
                      ? prompt.fill(qsTr("%2 stops playing as %1."),
                                    prompt.chosen ? Notifications.named(prompt.chosen.name) : "",
                                    prompt.chosen ? prompt.seatPadName(prompt.chosen.id) : "")
                      : prompt.fill(qsTr("Join: %1 plays alongside %2. Switch: %1 becomes player 1, and %2's games are paused and kept."),
                                    prompt.chosen ? Notifications.named(prompt.chosen.name) : "",
                                    Notifications.named(prompt.player1Name))
                color: Theme.textDim
                font.pixelSize: Theme.typeBody * prompt.u
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: prompt.step === "confirm"
                spacing: Theme.spaceM * prompt.u

                PrimaryButton {
                    id: joinButton
                    objectName: "whosPlayingJoin"
                    u: prompt.u
                    height: Theme.buttonHeight * prompt.u
                    width: Math.max(300 * prompt.u, implicitWidth)
                    text: qsTr("Join")
                    acceptOnRelease: true
                    Keys.onRightPressed: { Sfx.navigate(); switchButton.forceActiveFocus() }
                }
                SecondaryButton {
                    id: switchButton
                    objectName: "whosPlayingSwitch"
                    u: prompt.u
                    height: Theme.buttonHeight * prompt.u
                    width: Math.max(300 * prompt.u, implicitWidth)
                    text: qsTr("Switch")
                    acceptOnRelease: true
                    Keys.onLeftPressed: { Sfx.navigate(); joinButton.forceActiveFocus() }
                }
            }
            // Move: Cancel first (focused), then Move.
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: prompt.step === "move"
                spacing: Theme.spaceM * prompt.u

                SecondaryButton {
                    id: moveCancelButton
                    objectName: "whosPlayingMoveCancel"
                    u: prompt.u
                    height: Theme.buttonHeight * prompt.u
                    width: Math.max(300 * prompt.u, implicitWidth)
                    text: qsTr("Cancel")
                    acceptOnRelease: true
                    Keys.onRightPressed: { Sfx.navigate(); moveButton.forceActiveFocus() }
                }
                PrimaryButton {
                    id: moveButton
                    objectName: "whosPlayingMove"
                    u: prompt.u
                    height: Theme.buttonHeight * prompt.u
                    width: Math.max(300 * prompt.u, implicitWidth)
                    text: qsTr("Move")
                    acceptOnRelease: true
                    Keys.onLeftPressed: { Sfx.navigate(); moveCancelButton.forceActiveFocus() }
                }
            }
        }
    }

    // ---- step "pin": PinPad's player mode, on the prompt's scrim ----------------------------------
    PinPad {
        id: pinPad
        objectName: "whosPlayingPin"
        anchors.fill: parent
        u: prompt.u
        scrimShown: false               // the prompt's blurred frame and scrim are its backdrop
        onVerified: pin => prompt.pinVerified(pin)
        onCancelled: prompt.pinCancelled()
    }

    // Accept on what has the focus (on the key's release, below).
    function activate() {
        if (cardList.activeFocus) {
            acceptCard(cardList.currentIndex)
        } else if (notNowButton.activeFocus) {
            Sfx.select()
            close(true)
        } else if (joinButton.activeFocus) {
            proceed("join")
        } else if (switchButton.activeFocus) {
            proceed("switch")
        } else if (moveCancelButton.activeFocus) {
            backFromConfirm()
        } else if (moveButton.activeFocus) {
            proceed("move")
        } else if (wakeMode && step === "pick" && prompt.activeFocus) {
            Sfx.select()
            continueAsSignedIn()        // no cards to focus (the profiles are not there): continue
        }
    }

    // The key whose press the prompt saw, so that its release acts (0 for none).
    property int downKey: 0

    // Modal: every key is taken, its release too. Accept, Back and Guide act on the release, so the
    // release of the key that closes the prompt never reaches the game it gives the focus back to, and
    // a release whose press came before the prompt opened does nothing. Back is Not now on step 1 and
    // back to the card on Join or Switch and on Move (Cancel); Guide closes like Not now (as it closes
    // the Hub), except on the PIN step. In wake mode Back and Guide on step 1 continue as the signed-in
    // profile instead (RUY-707).
    Keys.onPressed: event => {
        event.accepted = true
        if (!event.isAutoRepeat)
            downKey = event.key
    }
    Keys.onReleased: event => {
        event.accepted = true
        if (event.isAutoRepeat || event.key !== downKey)
            return
        downKey = 0
        if (joining !== null && event.key !== Qt.Key_HomePage)
            return                      // a join is on its way: Accept and Back wait for its answer
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            activate()
        } else if (BackKey.isBackOrBackspace(event.key)) {
            if (step === "confirm" || step === "move")
                backFromConfirm()
            else if (step === "pick" && wakeMode)
                wakeBack()              // continue as the signed-in profile, from any card
            else if (step === "pick")
                notNow()
        } else if (event.key === Qt.Key_HomePage && step !== "pin") {
            if (wakeMode)
                wakeBack()
            else
                notNow()
        }
        // Step "pin": the PIN pad takes every press (Back deletes a digit, else returns to the step before),
        // so no release there matches a press seen here.
    }
}
