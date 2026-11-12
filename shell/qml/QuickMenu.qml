pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The quick menu, the Quick Hub (04 §5, 02-shell §1.4/§1.5/§1.6, T-147, T-448, T-471): what Guide opens. A
// 640 px panel on the left over a scrim, over the live app, the open page or Home. One screen, no scroll,
// at most five focus stops (layout A, owner 2026-11-12):
//   a status row first (clock, network, the muted microphone, device batteries; not focusable), then
//   over an app: the game card (the app's art, title and "Paused · 12 min": the Resume control, focus first),
//   Home | Close game (one row, Left/Right between them), the running strip (one art tile per other running
//   app, Left/Right along it, Accept switches to it; absent when nothing else runs), Volume (Left/Right by 5,
//   Accept mutes) and the panel icons (Audio, Controllers, Performance, Power: Left/Right between them,
//   Accept opens the panel). Without an app: the strip, Volume and the icons; focus on the first that exists.
// Power (its icon, or holding Guide) swaps the list for the power choices (Suspend, Restart, Power off
// as logind allows, then Switch profile and Back); a power choice asks the shell to open its confirmation
// (`powerRequested`). Modal: every key is taken here. Up/Down move between the rows, Left/Right move inside
// a row of several controls or change the value of a slider or choice row, Accept acts, Back or Guide closes
// (Back leaves a panel or the power choices first). The list model holds keys only; the text is a binding in
// the delegate (translations rule). The fill is `glassOpaque` on every tier until the blurred glass of the
// quick menu is built (B-003, 04 §3.6).
Item {
    id: menu

    property real u: 1
    property real marginX: 0
    property real marginY: 0
    // Room kept free at the bottom for the hint bar (the shell sets it, T-448): the panel never reaches it.
    property real bottomReserve: 0
    property bool open: false
    // Open and at rest: the fade and the slide have ended (the open-time probe, T-455).
    readonly property bool settled: open && opacity === 1 && slide.x === 0
    // The power choices instead of the actions.
    property bool powerMode: false
    // The panel shown in place of the Quick Hub's content ("" = the Quick Hub itself; T-450, 02 §1.6).
    // To add a panel: list it in `panelIds` and give it a table of row descriptors in `panelDef` (below).
    property string panelId: ""
    // 0 -> 1 while the rows change between the Hub and a panel (the cross-fade; a cut under reduced motion).
    property real swap: 1
    NumberAnimation {
        id: swapAnimation
        target: menu
        property: "swap"
        from: 0
        to: 1
        duration: Theme.focusMs
        easing.type: Easing.Bezier
        easing.bezierCurve: Theme.easeSnap
    }

    // The app in front, or null: { appId, title, picture, started, frozen } (started: unix seconds;
    // frozen: Session1 froze it, T-457, so the game card says "Paused").
    property var app: null
    // The other running apps (T-467): [{ appId, title, picture, hasWindow }], the running strip's tiles.
    // One with no window yet (hasWindow false) says so in its name.
    property var others: []
    // Keys the shell keeps for itself (Guide): a function key -> bool.
    property var guideKey: function (key) { return false }

    readonly property bool hasApp: app !== null
    readonly property alias actions: actions
    readonly property alias panel: panel

    signal closeRequested()           // Back, Guide or the game card (Resume)
    signal homeRequested()
    signal closeGameRequested()
    signal switchToRequested(string appId)
    signal switchProfileRequested()
    signal powerRequested(string action)
    signal settingsRequested(string category) // a panel's link to Settings: the shell leaves the Hub and opens it

    // A pad came or went (the Controllers panel's rows): the list follows and the focus stays in the panel.
    Connections {
        target: Bluetooth
        function onGamepadsChanged() { menu.rebuild() }
    }
    Connections {
        target: Audio
        function onInputsChanged() { menu.rebuild(); menu.settleChoices() }   // a microphone came or went: the panel's rows
        function onOutputsChanged() { menu.settleChoices() }
        function onSetOutputFinished(id, status) {
            menu.answerChoice("audio:output", id, status)
            if (menu.open && menu.panelId === "audio" && status !== "ok")
                Notifications.show(qsTr("Could not switch the audio output."), "warning")
        }
        function onSetInputFinished(id, status) {
            menu.answerChoice("audio:mic", id, status)
            if (menu.open && menu.panelId === "audio" && status !== "ok")
                Notifications.show(qsTr("Could not switch the microphone."), "warning")
        }
    }

    // The status row's content: at most two battery chips (lowest first, as the service sorts them)
    // and a "+N" for the rest.
    readonly property var chipIds: Batteries.chips.slice(0, 2).map(d => d.id)
    readonly property int chipOverflow: Batteries.chips.length + Batteries.more.length - chipIds.length

    // ---- the Quick Hub's rows (T-471) ---------------------------------------------------------------------
    // A row is one focus stop: "resume" (the game card), "leave" (Home | Close game), "running" (the strip),
    // "volume" and "panels" (the icons). A row of several controls keeps the column Left/Right stand on;
    // every open starts each row on its first control.
    readonly property var leaveIds: ["home", "closeGame"]
    // The panel icons, in order (02 §1.6): the panels that exist, then Power (the power choices).
    readonly property var iconIds: [...panelIds, "power"]
    property int leaveCol: 0
    property int iconCol: 0
    // The strip follows the app, not the place: a tile that comes or goes before it keeps the focus on the same app.
    property int runningCol: 0
    property string runningId: ""
    readonly property int runningIndex: {
        const at = others.findIndex(o => o.appId === runningId)
        return at >= 0 ? at : Math.max(0, Math.min(runningCol, others.length - 1))
    }

    // The controls of a row, as keys: "home", "closeGame"; "to:<appId>"; "panel:<id>" (Power is "panel:power").
    function controlsOf(row) {
        if (row === "leave")
            return leaveIds
        if (row === "running")
            return others.map(o => "to:" + o.appId)
        if (row === "panels")
            return iconIds.map(id => "panel:" + id)
        return [row]
    }
    // The row a control sits in (tests and Back use it to find a control again).
    function rowKeyOf(key) {
        if (powerMode || panelId !== "")
            return key
        if (key === "home" || key === "closeGame")
            return "leave"
        if (key.startsWith("to:"))
            return "running"
        if (key.startsWith("panel:"))
            return "panels"
        return key
    }
    function columnOf(key) { return Math.max(0, controlsOf(rowKeyOf(key)).indexOf(key)) }
    function columnIn(row) {
        return row === "leave" ? leaveCol : row === "running" ? runningIndex : row === "panels" ? iconCol : 0
    }
    // Left/Right in a row of several controls: the next one, stopping at the ends.
    function stepColumn(row, delta) {
        const count = controlsOf(row).length
        const at = columnIn(row)
        const next = Math.max(0, Math.min(count - 1, at + delta))
        if (next === at)
            return
        if (row === "leave") {
            leaveCol = next
        } else if (row === "running") {
            runningCol = next
            runningId = others[next].appId
        } else {
            iconCol = next
        }
        Sfx.navigate()
    }

    // ---- the Hub at large UI sizes (RUY-401) ----------------------------------------------------------------
    // The Hub never scrolls. Above 100 % UI size the game card's art and the running strip's tiles shrink to
    // `artFit` (1 = full size) until the five rows fit the room; the text and the focus ring keep the UI size.
    // The line under the strip and under the icon row for the focused item's name opens with the focus, so the
    // fit counts it as open (`nameFull`): the art does not change when the focus moves.
    property real artFit: 1
    readonly property real artFitMin: 0.35
    property real stripCentre: 0
    property real iconCentre: 0
    readonly property real nameFull: Theme.spaceXs * u + nameProbe.implicitHeight
    // The text of the game card is as tall as it is (a two-line title and the state), whatever the art does.
    property real cardInfoHeight: 0
    // The art's heights at full size: the card's, and a tile's.
    readonly property real cardArtNominal: Theme.cardArtHeight(256 * u)
    readonly property real tileNominal: Theme.cardArtHeight((listBox.width - 2 * Theme.spaceM * u - 2 * Theme.spaceS * u) / 3)
    // What does not scale (the card's padding, the pills, the strip's margins, the name line, the gaps).
    readonly property real fixedHeight: {
        const pill = Theme.buttonHeight * u
        return (hasApp ? 2 * Theme.spaceS * u + pill : 0) + (others.length > 0 ? 2 * Theme.spaceS * u : 0) + 2 * pill
               + nameFull + Math.max(0, itemKeys.length - 1) * Theme.spaceS * u
    }
    // What changes the room or the rows: the fit is worked out again (a function of these alone, no loop).
    readonly property string fitKey: [listBox.room, listBox.width, u, hasApp, others.length, powerMode, panelId, itemKeys.length,
                                      Math.round(cardInfoHeight), Math.round(nameFull)].join("|")
    onFitKeyChanged: refit()
    function refit() {
        if (powerMode || panelId !== "" || listBox.width <= 0)
            return
        const room = listBox.room - fixedHeight
        const card = hasApp ? cardArtNominal : 0
        const tiles = others.length > 0 ? tileNominal : 0
        let fit = 1
        if (card + tiles > room) {
            fit = room / (card + tiles)
            // The card is never shorter than its text: past that, the tiles take all that is left.
            if (hasApp && fit * card < cardInfoHeight && tiles > 0)
                fit = (room - cardInfoHeight) / tiles
        }
        fit = Math.max(artFitMin, Math.min(1, fit))
        if (Math.abs(fit - artFit) > 0.001)
            artFit = fit
    }
    Text {
        id: nameProbe
        visible: false
        text: "Ag"
        font.pixelSize: Theme.typeCaption * menu.u
        font.weight: Theme.weightDemiBold
    }

    // The rows of the list now (see rebuild()).
    property var itemKeys: []
    readonly property string currentRow: itemKeys[actions.currentIndex] ?? ""
    // The control that has the focus ("" while the list is empty): the shell words the A hint after it.
    readonly property string currentKey: {
        const row = currentRow
        if (row === "" || powerMode || panelId !== "")
            return row
        return controlsOf(row)[columnIn(row)] ?? ""
    }
    // The column of the focused row (0 in a row of one control).
    readonly property int currentColumn: columnIn(currentRow)

    function keysNow() {
        if (powerMode) {
            return [...(Power.canSuspend ? ["suspend"] : []),
                    ...(Power.canRestart ? ["restart"] : []),
                    ...(Power.canPowerOff ? ["poweroff"] : []),
                    "switch", "back"]
        }
        if (panelId !== "")
            return panelKeys(panelId)
        const keys = []
        if (hasApp)
            keys.push("resume", "leave")
        if (others.length > 0)
            keys.push("running")
        keys.push("volume", "panels")
        return keys
    }
    // Assigning a new array resets the list's current index, so the keys are replaced only when they
    // changed (an app that exits while the menu is open) and the current key is found again.
    function rebuild() {
        const next = keysNow()
        if (JSON.stringify(next) === JSON.stringify(itemKeys))
            return
        const was = actions.currentIndex             // read before the new model resets it
        const current = was >= 0 && was < itemKeys.length ? itemKeys[was] : ""
        itemKeys = next
        const at = next.indexOf(current)
        // A row that vanished (a pad unplugged, the last other app) hands the focus to the row that took its place.
        actions.currentIndex = at >= 0 ? at : Math.min(Math.max(0, was), next.length - 1)
    }
    onHasAppChanged: rebuild()
    onOthersChanged: rebuild()
    onPowerModeChanged: rebuild()
    onPanelIdChanged: { pendingChoice = ({}); rebuild() }

    // ---- panels (T-450, T-452): a panel replaces the Quick Hub's rows in this same list ---------------------
    // The panels that exist, in the order of their icons (02 §1.6); an icon appears only when its panel is built.
    readonly property var panelIds: ["audio", "controllers", "performance"]
    onPanelIdsChanged: rebuild()

    // A panel is a table of row descriptors (T-452), the one place a row's behaviour is written:
    //   { key, label, kind: "toggle" | "choice" | "slider" | "info" | "action",
    //     value(): the text at the right (toggle, choice, slider) or under the label (info; none: the label alone),
    //     icon: an icon name before an info row's text (optional),
    //     fraction(): 0..1, how far a slider's bar is full (slider),
    //     activate(): Accept (toggle, action; a slider's is optional: Volume mutes),
    //     adjust(delta): Left/Right, delta -1 or +1 (slider),
    //     choices(): [{ id, name, current }] and select(id) (choice; `async` when the answer comes later) }
    // The hint bar, the delegate, Accept and Left/Right all derive from `kind`. To add a panel: list it in
    // `panelIds`, give it a table in `panelDef` and an icon in `iconOf`; nothing else in this file changes. Keys
    // are "<id>:<row>" (the shared "volume" row may also sit in a panel). Descriptors are built on demand, so a
    // row that depends on the hardware (the microphone) is simply not in the table.
    function panelDef(id) {
        if (id === "audio") {
            return { title: qsTr("Audio"), rows: [
                volumeRow(),
                { key: "audio:mute", label: qsTr("Mute"), kind: "toggle",
                  value: () => Audio.muted ? qsTr("On") : qsTr("Off"),
                  activate: () => Audio.toggleMute() },
                { key: "audio:output", label: qsTr("Output"), kind: "choice", async: true,
                  // an output whose route says "no" is not offered
                  choices: () => Audio.outputs.filter(o => o.available !== "no").map(o => ({ id: o.id, name: o.name, current: o.isDefault })),
                  value: () => (Audio.outputs.find(o => o.isDefault) ?? { name: "" }).name,
                  select: id => Audio.setOutput(id) },
                ...(Audio.inputs.length > 0 ? [
                    { key: "audio:mic", label: qsTr("Microphone"), kind: "choice", async: true,
                      choices: () => Audio.inputs.map(i => ({ id: i.id, name: i.name, current: i.isDefault })),
                      value: () => (Audio.inputs.find(i => i.isDefault) ?? { name: "" }).name,
                      select: id => Audio.setInput(id) },
                    { key: "audio:micmute", label: qsTr("Mute microphone"), kind: "toggle",
                      value: () => Audio.inputMuted ? qsTr("On") : qsTr("Off"),
                      activate: () => Audio.toggleInputMute() }
                ] : [])
            ] }
        }
        if (id === "controllers") {
            const pads = controllerPads()
            return { title: qsTr("Controllers"), rows: [
                ...(pads.length === 0 ? [
                    { key: "controllers:none", label: qsTr("No controllers connected."), kind: "info" }
                ] : pads.map(p => ({ key: "controllers:pad:" + p.id, label: p.name, kind: "info",
                                     icon: DeviceIcons.iconFor("controller", p.family),
                                     value: () => padText(p) }))),
                { key: "controllers:settings", label: qsTr("Controller settings"), kind: "action",
                  activate: () => menu.settingsRequested("bluetooth") }
            ] }
        }
        if (id === "performance") {
            return { title: qsTr("Performance"), rows: [
                // The numbers are drawn over the game by PerformanceReadout (T-469), not here: the Hub freezes the game.
                { key: "performance:overlay", label: qsTr("Performance overlay"), kind: "toggle",
                  value: () => perfOverlayOn() ? qsTr("On") : qsTr("Off"),
                  activate: () => DeviceSettings.setPerformanceOverlay(Profiles.activeProfile, !perfOverlayOn()) },
                { key: "performance:interval", label: qsTr("Update every"), kind: "choice",
                  choices: () => [500, 1000, 2000, 5000].map(ms => ({ id: ms, name: intervalText(ms), current: ms === DeviceSettings.performanceIntervalMs })),
                  value: () => intervalText(DeviceSettings.performanceIntervalMs),
                  select: ms => { DeviceSettings.performanceIntervalMs = ms } }
            ] }
        }
        return null
    }
    // A panel icon's glyph and name (the name shows under the focused icon and is its accessible name).
    function iconOf(id) {
        switch (id) {
        case "audio": return "volume_up"
        case "controllers": return "sports_esports"
        case "performance": return "monitoring"
        case "power": return "power_settings_new"
        }
        return ""
    }
    function titleOf(id) {
        if (id === "power")
            return qsTr("Power")
        const def = panelDef(id)
        return def ? def.title : id
    }
    // The Hub's Volume row, also the first row of the Audio panel: Left/Right by 5, Accept mutes.
    function volumeRow() {
        return { key: "volume", label: qsTr("Volume"), kind: "slider",
                 fraction: () => Audio.muted ? 0 : Audio.volume / 100,
                 value: () => Audio.muted ? qsTr("Muted") : String(Audio.volume),
                 adjust: delta => Audio.stepVolume(5 * delta), activate: () => Audio.toggleMute() }
    }
    // The descriptor of a row of the panel now open (or the Volume row anywhere); null for the Hub's other rows.
    function rowOf(key) {
        if (key === "volume")
            return volumeRow()
        const def = panelId !== "" ? panelDef(panelId) : null
        return def ? (def.rows.find(r => r.key === key) ?? null) : null
    }
    function panelKeys(id) {
        const def = panelDef(id)
        return def ? def.rows.map(r => r.key) : []
    }

    // ---- the Controllers panel (T-453, 02 §1.6) ---------------------------------------------------------
    // The pads present now are the service's (`Bluetooth.gamepads`, ListGamepads: USB or Bluetooth, the
    // transport is its word). Each pad's battery is looked up: by Bluetooth address in `Batteries` (UPower),
    // else the paired device's own level; a wired pad takes the one address-less controller battery of its
    // family when the match is unambiguous. No reading: "Battery not reported". Sorted by name, then id, so
    // a battery change never moves a row.
    // [{ id, name, family, transport: "usb" | "bluetooth" | "other", percent (-1: not reported), state }]
    function controllerPads() {
        const batteries = Batteries.devices.filter(b => b.kind === "controller")
        const used = ({})
        const pads = []
        for (const g of Bluetooth.gamepads) {
            const bt = g.transport === "bluetooth"
            const id = bt ? String(g.id).toLowerCase() : g.id
            const paired = bt ? Bluetooth.devices.find(d => String(d.id).toLowerCase() === id) : undefined
            const battery = bt ? batteries.find(b => String(b.address ?? "").toLowerCase() === id) : undefined
            if (battery)
                used[battery.id] = true
            pads.push({ id: id,
                        name: paired ? DeviceIcons.shownName(Bluetooth.devices, paired) : DeviceIcons.plain(g.name),
                        family: g.family !== "" ? g.family : (paired ? paired.family : ""),
                        transport: g.transport,
                        percent: battery ? battery.percent : (paired && paired.battery >= 0 ? paired.battery : -1),
                        state: battery ? battery.state : "" })
        }
        for (const p of pads) {
            if (p.transport === "bluetooth" || p.percent >= 0 || p.family === "")
                continue
            const alike = pads.filter(q => q.transport !== "bluetooth" && q.percent < 0 && q.family === p.family)
            const spare = batteries.filter(b => !used[b.id] && String(b.address ?? "") === "" && b.family === p.family)
            if (alike.length === 1 && spare.length === 1) {
                used[spare[0].id] = true
                p.percent = spare[0].percent
                p.state = spare[0].state
            }
        }
        pads.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        return pads
    }
    // "Battery 62 %, charging · Bluetooth": every word in `text` (04 §7), the words carry the state.
    function padText(p) {
        const battery = p.percent < 0 ? qsTr("Battery not reported")
                      : p.state === "full" ? qsTr("Battery full")
                      : p.state === "charging" ? qsTr("Battery %1 %, charging").arg(p.percent)
                      : qsTr("Battery %1 %").arg(p.percent)
        if (p.transport !== "usb" && p.transport !== "bluetooth")
            return battery
        return qsTr("%1 · %2").arg(battery).arg(p.transport === "usb" ? qsTr("USB") : qsTr("Bluetooth"))
    }

    // ---- the Performance panel's texts (02 §1.6) -------------------------------------------------------
    // The switch is per profile (DeviceSettings.performanceOverlayProfiles); the readings are PerformanceReadout's.
    function perfOverlayOn() { return DeviceSettings.performanceOverlayProfiles[Profiles.activeProfile] === true }
    function intervalText(ms) { return ms === 500 ? qsTr("0.5 s") : qsTr("%1 s").arg(ms / 1000) }

    // ---- choice rows -----------------------------------------------------------------------------------
    // A choice that asks the service (`async`) changes the row only with the answer, so presses that come
    // before it would all step from the old value. The target of the last press is kept until the answer
    // lands (setOutputFinished / setInputFinished, then the list shows it): the next press steps from there.
    // key -> { target, answered }
    property var pendingChoice: ({})
    function answerChoice(key, id, status) {
        const pending = pendingChoice[key]
        if (!pending || pending.target !== id)
            return                       // an older press's answer: the newer one is still on its way
        if (status !== "ok")
            delete pendingChoice[key]    // refused: the row shows what the service has
        else
            pending.answered = true
        settleChoices()
    }
    function settleChoices() {
        for (const key of Object.keys(pendingChoice)) {
            const pending = pendingChoice[key]
            const row = rowOf(key)
            const now = row ? row.choices().find(o => o.current) : undefined
            if (!row || (pending.answered && now && now.id === pending.target))
                delete pendingChoice[key]
        }
    }
    // Left/Right on a choice row: the next or previous *usable* choice (in the service's order, wrapping).
    function stepChoice(key, delta) {
        const row = rowOf(key)
        if (!row || row.kind !== "choice")
            return
        const options = row.choices()
        if (options.length < 2)
            return
        const pending = pendingChoice[key]
        let at = pending ? options.findIndex(o => o.id === pending.target) : -1
        if (at < 0)
            at = options.findIndex(o => o.current)
        const next = options[at < 0 ? 0 : (at + delta + options.length) % options.length]
        Sfx.navigate()
        if (row.async)
            pendingChoice[key] = { target: next.id, answered: false }
        row.select(next.id)
    }
    function openPanel(id) {
        panelId = id
        actions.currentIndex = 0               // the panel's first row
        actions.positionViewAtBeginning()
        swapAnimation.restart()
    }
    // The Quick Hub again with the focus on the icon of `id` (Back from a panel or the power choices).
    function focusIcon(id) {
        iconCol = Math.max(0, iconIds.indexOf(id))
        actions.currentIndex = Math.max(0, itemKeys.indexOf("panels"))
    }
    // Back in a panel: the Quick Hub again, with the focus on the icon that was opened.
    function closePanel() {
        const id = panelId
        panelId = ""
        focusIcon(id)
        swapAnimation.restart()
    }
    // What the buttons do on the focused control: the hint bar's list (02 §1.6), derived from the row's kind.
    // Left/Right is named where it changes a value.
    readonly property var hints: {
        const key = currentKey
        const back = { button: "B", text: powerMode || panelId !== "" ? qsTr("Back") : (hasApp ? qsTr("Resume") : qsTr("Close")) }
        if (powerMode)
            return [{ button: "A", text: qsTr("Select") }, back]
        const row = rowOf(key)
        if (row) {
            switch (row.kind) {
            case "slider": return [...(row.activate ? [{ button: "A", text: qsTr("Mute") }] : []),
                                   { button: "Left/Right", text: qsTr("Adjust") }, back]
            case "choice": return row.choices().length < 2 ? [back]
                                  : [{ button: "A", text: qsTr("Next") }, { button: "Left/Right", text: qsTr("Change") }, back]
            case "toggle": return [{ button: "A", text: qsTr("Toggle") }, back]
            case "action": return [{ button: "A", text: qsTr("Open") }, back]
            }
            return [back]               // info: nothing to press
        }
        if (key === "resume")           // B resumes too, but the verb is shown once (RUY-401)
            return [{ button: "A", text: qsTr("Resume") }]
        if (key === "home" || key === "closeGame")      // the hint names the button (UX review, T-471)
            return [{ button: "A", text: labelOf(key) }, back]
        if (key.startsWith("to:"))
            return [{ button: "A", text: qsTr("Switch") }, back]
        if (key.startsWith("panel:"))
            return [{ button: "A", text: qsTr("Open") }, back]
        return [{ button: "A", text: qsTr("Select") }, back]
    }

    // The name of a control or a row (a delegate's label, a control's accessible name).
    function labelOf(key) {
        const row = rowOf(key)
        if (row)
            return row.label
        switch (key) {
        case "resume": return qsTr("Resume")
        case "home": return qsTr("Home")
        case "closeGame": return qsTr("Close game")
        case "switch": return qsTr("Switch profile")
        case "suspend": return qsTr("Suspend")
        case "restart": return qsTr("Restart")
        case "poweroff": return qsTr("Power off")
        case "back": return qsTr("Back")
        }
        if (key.startsWith("panel:"))
            return titleOf(key.substring(6))
        if (key.startsWith("to:")) {
            const found = others.find(o => o.appId === key.substring(3))
            const name = Notifications.named(found ? found.title : key.substring(3))
            return found && found.hasWindow === false ? qsTr("Switch to %1 (no window yet)").arg(name) : qsTr("Switch to %1").arg(name)
        }
        return key
    }
    // A running tile's name under it: the title, and that it has no window yet.
    function runningName(o) {
        const name = Notifications.named(o.title)
        return o.hasWindow === false ? qsTr("%1 (no window yet)").arg(name) : name
    }

    // The game card's second line: "Paused · 12 min" while Session1 reports the game frozen (T-457: only once
    // it says so, so a failed freeze never shows it), else "Running for 12 min"; under a minute "Paused" /
    // "Just started".
    readonly property real elapsed: app ? now - app.started : 0
    readonly property bool paused: app !== null && (app.frozen ?? false)
    readonly property string appState: !app ? ""
        : paused ? (elapsed < 60 ? qsTr("Paused") : qsTr("Paused · %1").arg(DurationText.plain(elapsed)))
        : (elapsed < 60 ? qsTr("Just started") : qsTr("Running for %1").arg(DurationText.plain(elapsed)))

    // Opens the menu on its first row: the game card over an app, else the running strip, else Volume. Nothing
    // of an earlier visit is remembered (every row starts on its first control). Called by the shell after it
    // has noted where the focus was.
    function present() {
        powerMode = false
        panelId = ""
        leaveCol = 0
        iconCol = 0
        runningCol = 0
        runningId = ""
        itemKeys = []
        rebuild()
        actions.currentIndex = 0
        actions.positionViewAtBeginning()
        actions.forceActiveFocus()
    }

    function showPower() {
        powerMode = true
        actions.currentIndex = 0
        Sfx.navigate()
    }

    function activate(key) {
        const row = rowOf(key)
        if (row && row.kind === "info")
            return                          // read-only: Accept does nothing
        Sfx.select()
        if (key === "resume") {
            menu.closeRequested()
        } else if (key === "home") {
            menu.homeRequested()
        } else if (key === "closeGame") {
            menu.closeGameRequested()
        } else if (key.startsWith("to:")) {
            menu.switchToRequested(key.substring(3))
        } else if (row) {
            if (row.kind === "choice")
                stepChoice(key, 1)
            else if (row.activate)
                row.activate()
        } else if (key === "panel:power") {
            showPower()
        } else if (key.startsWith("panel:")) {
            openPanel(key.substring(6))
        } else if (key === "switch") {
            menu.switchProfileRequested()
        } else if (key === "back") {
            powerMode = false
            focusIcon("power")
        } else {
            menu.powerRequested(key)        // suspend | restart | poweroff: the shell confirms
        }
    }

    // How long the app has been running, read again every 15 s while the menu is open.
    property real now: Date.now() / 1000
    Timer {
        interval: 15000
        repeat: true
        running: menu.open && menu.hasApp
        triggeredOnStart: true
        onTriggered: menu.now = Date.now() / 1000
    }

    anchors.fill: parent
    opacity: open ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
    onOpenChanged: {
        powerMode = false
        panelId = ""
        if (open)
            Sfx.open()
        else
            Sfx.close()
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrimOverlay
    }

    // The panel slides in from the left over overlayMs.
    Item {
        id: slide
        x: menu.open ? 0 : -(panel.width + menu.marginX)
        width: panel.width
        height: parent.height
        Behavior on x { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

        GlassShadow {
            objectName: "guideShadow"
            anchors.fill: panel
            u: menu.u
            radius: Theme.radiusL * menu.u
            kind: "panel"
        }
        Rectangle {
            id: panel
            objectName: "guidePanel"
            readonly property real pad: Theme.spaceL * menu.u
            // The room the panel may take: inside the safe area, above the hint bar.
            readonly property real room: menu.height - 2 * menu.marginY - menu.bottomReserve
            x: menu.marginX
            y: menu.marginY + (room - height) / 2
            width: 640 * menu.u
            height: content.height + 2 * pad
            radius: Theme.radiusL * menu.u
            color: Theme.glassOpaque

            GlassLayers {
                objectName: "guideLayers"
                anchors.fill: parent
                u: menu.u
                radius: parent.radius
                grain: false            // opaque until B-003: nothing is blurred behind it
            }

            Column {
                id: content
                x: panel.pad
                y: panel.pad
                width: panel.width - 2 * panel.pad
                spacing: Theme.spaceM * menu.u

                // The status row (T-448): the clock, the network, the muted microphone (T-471) and the device
                // batteries. Never focusable.
                Item {
                    id: status
                    objectName: "hubStatus"
                    width: parent.width
                    height: Math.max(clock.implicitHeight, Theme.iconM * menu.u)
                    Accessible.role: Accessible.StaticText
                    Accessible.name: micMuted.visible ? qsTr("%1, %2, microphone muted").arg(clock.text).arg(networkText.text)
                                                      : qsTr("%1, %2").arg(clock.text).arg(networkText.text)

                    Text {
                        id: clock
                        objectName: "hubClock"
                        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                        text: TimeZone.clockText
                        color: Theme.text
                        font.pixelSize: Theme.typeHeadline * menu.u
                        font.weight: Theme.weightDemiBold
                    }
                    Row {
                        id: batteries
                        objectName: "hubBatteries"
                        visible: menu.chipIds.length > 0
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: Theme.spaceM * menu.u
                        Repeater {
                            model: menu.chipIds
                            BatteryChip {
                                required property string modelData
                                objectName: "hubBattery_" + modelData
                                deviceId: modelData
                                u: menu.u
                            }
                        }
                        Text {
                            objectName: "hubBatteryMore"
                            visible: menu.chipOverflow > 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: "+" + menu.chipOverflow
                            color: Theme.textDim
                            font.pixelSize: Theme.typeBody * menu.u
                        }
                    }
                    Row {
                        id: network
                        objectName: "hubNetwork"
                        anchors { right: batteries.visible ? batteries.left : parent.right
                                  rightMargin: batteries.visible ? Theme.spaceM * menu.u : 0
                                  verticalCenter: parent.verticalCenter }
                        spacing: Theme.spaceXs * menu.u
                        // The microphone is muted (the Audio panel's Mute microphone): the glyph says so mid-game.
                        Icon {
                            id: micMuted
                            objectName: "hubMicMuted"
                            visible: Audio.inputMuted && Audio.inputs.length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            u: menu.u
                            name: "mic_off"
                        }
                        Item {
                            visible: micMuted.visible
                            width: Theme.spaceXs * menu.u
                            height: 1
                        }
                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            u: menu.u
                            name: Network.state === "disconnected" ? "wifi_off"
                                  : (Network.primary.kind === "ethernet" ? "lan" : "wifi")
                        }
                        Text {
                            id: networkText
                            objectName: "hubNetworkName"
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText      // a network's name comes from outside
                            text: Network.state === "disconnected" ? qsTr("Not connected") : (Network.primary.name ?? "")
                            width: Math.min(implicitWidth, Math.max(0, status.width - clock.implicitWidth
                                            - (batteries.visible ? batteries.width + Theme.spaceM * menu.u : 0)
                                            - (micMuted.visible ? micMuted.width + 2 * Theme.spaceXs * menu.u : 0)
                                            - Theme.iconM * menu.u - 2 * Theme.spaceM * menu.u))
                            elide: Text.ElideRight
                            color: Theme.text
                            font.pixelSize: Theme.typeBody * menu.u
                        }
                    }
                }

                // A panel's title row (T-450; the power choices' too): not focusable, under the status row.
                Item {
                    id: panelTitleText
                    visible: menu.panelId !== "" || menu.powerMode
                    width: parent.width
                    height: visible ? panelTitle.implicitHeight : 0
                    opacity: menu.swap
                    Text {
                        id: panelTitle
                        objectName: "hubPanelTitle"
                        width: parent.width
                        textFormat: Text.PlainText
                        text: menu.powerMode ? qsTr("Power") : (menu.panelId !== "" ? (menu.panelDef(menu.panelId)?.title ?? "") : "")
                        color: Theme.text
                        font.pixelSize: Theme.typeTitle * menu.u
                        font.weight: Theme.weightDemiBold
                    }
                }

                // The list and its scroll cues. The Quick Hub fits without scrolling at the default UI size (T-471);
                // a panel with many rows (pads) may not: what is left under the status row and the title (gaps of
                // the column) scrolls so the current row stays in view and clear of the fades, and a fade at the
                // edge that hides rows says there are more.
                Item {
                    id: listBox
                    objectName: "hubListBox"
                    width: parent.width
                    // The room under the status row and the title (gaps of the column).
                    readonly property real room: panel.room - 2 * panel.pad - status.height
                                                 - (panelTitleText.visible ? panelTitleText.height + Theme.spaceM * menu.u : 0) - Theme.spaceM * menu.u
                    height: Math.min(actions.contentHeight, room)
                    // Changing from the Hub to a panel and back: the rows fade in and slide by `pageSlide`
                    // (both are 0 under reduced motion, so it is a cut).
                    opacity: menu.swap
                    transform: Translate { x: (1 - menu.swap) * Theme.pageSlide * menu.u }

                    ListView {
                        id: actions
                        objectName: "systemActions"
                        Accessible.role: Accessible.List
                        Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("Ruya Hub")

                        anchors.fill: parent
                        spacing: Theme.spaceS * menu.u
                        interactive: false
                        keyNavigationEnabled: true
                        clip: true
                        model: menu.itemKeys

                        // Brings the current row into view and keeps it clear of the fade at the edge that hides
                        // rows (`spaceL` high, T-450): it is never drawn under a fade it could have been moved from.
                        function reveal() {
                            if (currentIndex < 0)
                                return
                            positionViewAtIndex(currentIndex, ListView.Contain)
                            const item = itemAtIndex(currentIndex)
                            if (!item || contentHeight <= height)
                                return
                            const fade = Theme.spaceL * menu.u
                            if (item.y - contentY < fade)
                                contentY = Math.max(originY, item.y - fade)
                            else if (item.y + item.height - contentY > height - fade)
                                contentY = Math.min(originY + contentHeight - height, item.y + item.height + fade - height)
                        }
                        // The panel's height or the rows' heights change after the row was placed (the game card
                        // grows when "Paused" arrives): put the current row clear of the fades again.
                        onHeightChanged: reveal()
                        onContentHeightChanged: reveal()
                        onCurrentIndexChanged: {
                            reveal()
                            if (menu.open)
                                Sfx.navigate()
                        }
                        Keys.onReturnPressed: menu.activate(menu.currentKey)
                        Keys.onEnterPressed: menu.activate(menu.currentKey)
                        Keys.onPressed: event => {
                            // Accepting every key (below) also skips the list's own key navigation, so
                            // Up/Down are handled here.
                            const key = menu.currentKey
                            const rowKey = menu.currentRow
                            const row = menu.rowOf(key)
                            const sideways = event.key === Qt.Key_Left || event.key === Qt.Key_Right
                            const toRight = event.key === (actions.LayoutMirroring.enabled ? Qt.Key_Left : Qt.Key_Right)
                            if (event.key === Qt.Key_Down) {
                                incrementCurrentIndex()
                            } else if (event.key === Qt.Key_Up) {
                                // Up into Home | Close game lands on the column nearest to where it came from.
                                const centre = rowKey === "running" ? menu.stripCentre : rowKey === "panels" ? menu.iconCentre : -1
                                decrementCurrentIndex()
                                if (centre >= 0 && menu.currentRow === "leave" && !menu.powerMode && menu.panelId === "")
                                    menu.leaveCol = centre < actions.width / 2 ? 0 : 1
                            } else if (row && row.kind === "slider" && sideways) {
                                row.adjust(toRight ? 1 : -1)
                            } else if (row && row.kind === "choice" && sideways) {
                                menu.stepChoice(key, toRight ? 1 : -1)
                            } else if (sideways && !menu.powerMode && menu.panelId === ""
                                       && (rowKey === "leave" || rowKey === "running" || rowKey === "panels")) {
                                menu.stepColumn(rowKey, toRight ? 1 : -1)
                            } else if (event.isAutoRepeat) {
                                // Holding Guide repeats the key: not a second press that would close us.
                            } else if (menu.powerMode && BackKey.isBackOrBackspace(event.key)) {
                                Sfx.back()
                                menu.activate("back")
                            } else if (menu.panelId !== "" && BackKey.isBackOrBackspace(event.key)) {
                                Sfx.back()
                                menu.closePanel()
                            } else if (BackKey.isBackOrBackspace(event.key) || menu.guideKey(event.key)) {
                                menu.closeRequested()
                            }
                            event.accepted = true      // modal: nothing leaks to what lies underneath
                        }

                        delegate: Rectangle {
                            id: action
                            required property int index
                            required property string modelData
                            readonly property bool focused: ListView.isCurrentItem && actions.activeFocus
                            readonly property bool isVolume: modelData === "volume"
                            // The Quick Hub's own rows (T-471): drawn by their components, not as a pill.
                            readonly property bool isCard: modelData === "resume" && !menu.powerMode && menu.panelId === ""
                            readonly property bool isLeave: modelData === "leave" && !menu.powerMode && menu.panelId === ""
                            readonly property bool isStrip: modelData === "running" && !menu.powerMode && menu.panelId === ""
                            readonly property bool isIcons: modelData === "panels" && !menu.powerMode && menu.panelId === ""
                            readonly property bool special: isCard || isLeave || isStrip || isIcons
                            // The row's descriptor (a panel's rows and the Volume row; null for the Hub's other rows).
                            readonly property var row: menu.rowOf(modelData)
                            readonly property bool isPanelRow: row !== null && !isVolume
                            readonly property bool isChoice: row !== null && row.kind === "choice"
                            readonly property bool isInfo: row !== null && row.kind === "info"
                            readonly property bool isSlider: row !== null && row.kind === "slider"
                            readonly property bool isAction: row !== null && row.kind === "action"
                            // (each reads `row` itself: the flags above may not have followed a changed `row` yet)
                            readonly property string rowText: row !== null && !isVolume && row.kind !== "slider" && row.value ? row.value() : ""
                            readonly property string sliderText: row !== null && row.kind === "slider" && row.value ? row.value() : ""
                            readonly property string label: menu.labelOf(modelData)
                            // The control of a row of several (Home | Close game, the strip, the icons) that Left/Right stand on.
                            readonly property string control: special ? (menu.controlsOf(modelData)[menu.columnIn(modelData)] ?? "") : modelData

                            objectName: "quickMenuItem_" + modelData
                            Accessible.role: isCard ? Accessible.Button : Accessible.MenuItem
                            Accessible.name: isVolume ? (Audio.muted ? qsTr("Volume, muted") : qsTr("Volume %1").arg(Audio.volume))
                                             : isCard ? qsTr("Resume %1, %2").arg(menu.app ? menu.app.title : "").arg(menu.appState)
                                             : special ? menu.labelOf(control)
                                             : isSlider ? qsTr("%1, %2").arg(label).arg(sliderText)
                                             : isPanelRow && rowText !== "" ? qsTr("%1, %2").arg(label).arg(rowText) : label
                            width: actions.width
                            height: special ? (rowContent.item ? (rowContent.item as Item).height : 0) : Theme.buttonHeight * menu.u
                            radius: height / 2
                            color: special ? "transparent" : (focused ? Theme.focusFill : Theme.glass)
                            border.width: special ? 0 : (focused ? Theme.focusRingWidth * menu.u : 1)
                            border.color: focused ? Theme.focusRing : Theme.glassBorder

                            // The Quick Hub's own rows (T-471), built only where they are used.
                            Loader {
                                id: rowContent
                                width: parent.width
                                active: action.special
                                sourceComponent: action.isCard ? cardComponent : action.isLeave ? leaveComponent
                                                 : action.isStrip ? stripComponent : iconsComponent
                            }
                            Component {
                                id: cardComponent
                                HubGameCard {
                                    objectName: "hubGameCard"
                                    width: action.width
                                    u: menu.u
                                    appId: menu.app ? menu.app.appId : ""
                                    title: menu.app ? menu.app.title : ""
                                    picture: menu.app ? menu.app.picture : ""
                                    stateText: menu.appState
                                    paused: menu.paused
                                    focused: action.focused
                                    fit: menu.artFit
                                    onInfoHeightChanged: menu.cardInfoHeight = infoHeight
                                    Component.onCompleted: menu.cardInfoHeight = infoHeight
                                }
                            }
                            // Home | Close game: two pills of half the row, `spaceS` apart.
                            Component {
                                id: leaveComponent
                                Row {
                                    id: leaveRow
                                    objectName: "hubLeaveRow"
                                    width: action.width
                                    height: Theme.buttonHeight * menu.u
                                    spacing: Theme.spaceS * menu.u
                                    Repeater {
                                        model: menu.leaveIds
                                        Rectangle {
                                            id: leavePill
                                            required property int index
                                            required property string modelData
                                            readonly property bool focused: action.focused && menu.leaveCol === index
                                            readonly property string label: menu.labelOf(modelData)
                                            objectName: "quickMenuItem_" + modelData
                                            Accessible.role: Accessible.Button
                                            Accessible.name: label
                                            width: (leaveRow.width - leaveRow.spacing) / 2
                                            height: leaveRow.height
                                            radius: height / 2
                                            color: focused ? Theme.focusFill : Theme.glass
                                            border.width: focused ? Theme.focusRingWidth * menu.u : 1
                                            border.color: focused ? Theme.focusRing : Theme.glassBorder
                                            Text {
                                                anchors.centerIn: parent
                                                width: Math.min(implicitWidth, parent.width - 2 * Theme.spaceM * menu.u)
                                                textFormat: Text.PlainText
                                                text: leavePill.label
                                                color: Theme.text
                                                font.pixelSize: Theme.typeHeadline * menu.u
                                                font.weight: Theme.weightDemiBold
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }
                                }
                            }
                            Component {
                                id: stripComponent
                                RunningStrip {
                                    objectName: "hubRunningStrip"
                                    width: action.width
                                    u: menu.u
                                    apps: menu.others.map(o => ({ appId: o.appId, title: o.title, picture: o.picture ?? "",
                                                                  name: menu.runningName(o), label: menu.labelOf("to:" + o.appId) }))
                                    currentIndex: menu.runningIndex
                                    focused: action.focused
                                    fit: menu.artFit
                                    onCurrentCentreChanged: menu.stripCentre = currentCentre
                                    Component.onCompleted: menu.stripCentre = currentCentre
                                }
                            }
                            Component {
                                id: iconsComponent
                                HubIconRow {
                                    objectName: "hubIconRow"
                                    width: action.width
                                    u: menu.u
                                    items: menu.iconIds.map(id => ({ key: "panel:" + id, icon: menu.iconOf(id), label: menu.titleOf(id) }))
                                    currentIndex: menu.iconCol
                                    focused: action.focused
                                    onCurrentCentreChanged: menu.iconCentre = currentCentre
                                    Component.onCompleted: menu.iconCentre = currentCentre
                                }
                            }

                            Text {
                                id: itemLabel
                                visible: !action.special && !action.isInfo
                                readonly property real leftEdge: Theme.spaceL * menu.u
                                // Slider and panel rows start at the left edge; the others are centred.
                                x: action.isSlider || (action.isPanelRow && !action.isAction) ? leftEdge : (action.width - width) / 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, action.width - leftEdge - Theme.spaceL * menu.u
                                                - (action.isPanelRow && !action.isSlider ? panelValue.width + Theme.spaceM * menu.u : 0))
                                textFormat: Text.PlainText
                                text: action.label
                                color: Theme.text
                                font.pixelSize: Theme.typeHeadline * menu.u
                                font.weight: Theme.weightDemiBold
                                elide: Text.ElideRight
                            }
                            // A slider row (Volume): a bar and the number (the same as the volume OSD).
                            Rectangle {
                                id: track
                                objectName: action.isVolume ? "quickMenuVolumeTrack" : "quickMenuSliderTrack"
                                visible: action.isSlider
                                anchors { left: itemLabel.right; leftMargin: Theme.spaceM * menu.u; right: valueText.left; rightMargin: Theme.spaceM * menu.u; verticalCenter: parent.verticalCenter }
                                height: 12 * menu.u
                                radius: height / 2
                                color: Theme.glass
                                Rectangle {
                                    objectName: "quickMenuSliderFill"
                                    width: parent.width * (action.row !== null && action.row.fraction ? action.row.fraction() : 0)
                                    height: parent.height
                                    radius: parent.radius
                                    color: Theme.text
                                }
                            }
                            Text {
                                id: valueText
                                objectName: action.isVolume ? "quickMenuVolumeValue" : "quickMenuSliderValue"
                                visible: action.isSlider
                                anchors { right: parent.right; rightMargin: Theme.spaceL * menu.u; verticalCenter: parent.verticalCenter }
                                width: 70 * menu.u
                                horizontalAlignment: Text.AlignRight
                                text: action.sliderText
                                color: Theme.text
                                font.pixelSize: Theme.typeBody * menu.u
                            }
                            // A panel row's value at the right ("On", the chosen output). A choice with a neighbour to
                            // step to has its arrows, as Settings' choice rows do; only the name is elided.
                            Row {
                                id: panelValue
                                objectName: "hubRowValue"
                                visible: action.isPanelRow && !action.isInfo && !action.isSlider
                                anchors { right: parent.right; rightMargin: Theme.spaceL * menu.u; verticalCenter: parent.verticalCenter }
                                spacing: Theme.spaceXs * menu.u
                                readonly property bool arrows: action.isChoice && action.row.choices().length > 1
                                // What the label leaves, less a little slack (the two arrows differ in width by a pixel): a device's name
                                // elides before the label does.
                                readonly property real room: action.width - 2 * Theme.spaceL * menu.u - Theme.spaceM * menu.u - Theme.spaceXs * menu.u - itemLabel.implicitWidth
                                Text {
                                    id: leftArrow
                                    visible: panelValue.arrows
                                    text: "‹"
                                    color: Theme.text
                                    font.pixelSize: Theme.typeBody * menu.u
                                }
                                Text {
                                    id: valueName
                                    objectName: "hubValueText"
                                    width: Math.min(implicitWidth, panelValue.room - (panelValue.arrows ? 2 * (leftArrow.implicitWidth + panelValue.spacing) : 0))
                                    textFormat: Text.PlainText      // a device's name comes from outside
                                    text: action.rowText
                                    color: Theme.text
                                    font.pixelSize: Theme.typeBody * menu.u
                                    elide: Text.ElideRight
                                }
                                Text {
                                    visible: panelValue.arrows
                                    text: "›"
                                    color: Theme.text
                                    font.pixelSize: Theme.typeBody * menu.u
                                }
                            }
                            // A reading (an info row, T-452): the label small above, the value under it at the full width, so
                            // "Not available on this console" is never cut off. The value is always `text` (contrast, 04 §7):
                            // the words carry the state.
                            // An info row's glyph (a pad's family, T-453).
                            Icon {
                                id: infoIcon
                                objectName: "hubInfoIcon"
                                visible: action.isInfo && action.row.icon !== undefined
                                x: Theme.spaceL * menu.u
                                anchors.verticalCenter: parent.verticalCenter
                                u: menu.u
                                name: action.isInfo && action.row.icon ? action.row.icon : ""
                            }
                            Column {
                                id: infoRow
                                visible: action.isInfo
                                x: Theme.spaceL * menu.u + (infoIcon.visible ? infoIcon.width + Theme.spaceS * menu.u : 0)
                                anchors.verticalCenter: parent.verticalCenter
                                width: action.width - x - Theme.spaceL * menu.u
                                Text {
                                    objectName: "hubInfoLabel"
                                    width: parent.width
                                    textFormat: Text.PlainText      // a device's name comes from outside
                                    text: action.label
                                    color: Theme.text
                                    // A row with no value is one line of body text ("No controllers connected.").
                                    font.pixelSize: (action.rowText === "" ? Theme.typeBody : Theme.typeCaption) * menu.u
                                    font.weight: Theme.weightDemiBold
                                    elide: Text.ElideRight
                                }
                                Text {
                                    objectName: "hubInfoValue"
                                    visible: action.rowText !== ""
                                    width: parent.width
                                    textFormat: Text.PlainText
                                    text: action.rowText
                                    color: Theme.text
                                    font.pixelSize: Theme.typeBody * menu.u
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }

                    Rectangle {
                        objectName: "hubMoreAbove"
                        readonly property bool needed: actions.contentY > actions.originY + 1
                        visible: needed
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: Theme.spaceL * menu.u
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Theme.glassOpaque }
                            GradientStop { position: 1.0; color: Qt.alpha(Theme.glassOpaque, 0) }
                        }
                    }
                    Rectangle {
                        objectName: "hubMoreBelow"
                        readonly property bool needed: actions.contentY + actions.height < actions.originY + actions.contentHeight - 1
                        visible: needed
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: Theme.spaceL * menu.u
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.alpha(Theme.glassOpaque, 0) }
                            GradientStop { position: 1.0; color: Theme.glassOpaque }
                        }
                    }
                }
            }
        }
    }
}
