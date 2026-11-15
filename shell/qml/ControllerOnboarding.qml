pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Pair a controller" (T-260): the guided pairing screen, opened from Settings -> Bluetooth &
// controllers ("Pair a new controller"). Full-screen modal, controller-only (B closes).
//
//  - Stage "pair": a row of controller families (Left/Right) and, under it, the steps for the
//    family in focus (ControllerPairHint.stepsFor: the one place for the wording). While the
//    screen is open the controller pairing window of T-203 is open (the hint below), so the
//    service's scan lists every controller in pairing mode as it is found, with its family glyph:
//    Down moves into that list, A pairs the one in focus (progress, "Connected, remembered", or the
//    reason and A to try again). The list keeps its focus while devices come and go.
//  - Stage "try": ButtonTest. Entered with A on a connected pad, or by itself when a pad is
//    plugged in over USB while the screen is open. Start continues, B closes.
//  - Stage "games" (RUY-503): after "try", once, when the tried pad is a Nintendo one whose
//    layout in games is still Standard (GameControls, for that pad's own profile): "Buttons in
//    games", By position / Nintendo labels. A sets the layout in that pad's own device slot
//    (GameControls.setOwnLayout: a shared profile is copied, never changed) and closes when the save is done;
//    a refused save keeps the screen open on its row (GameControls toasts it); B closes.
// Controllers that were already paired when the screen opened are not listed (they are in the
// paired list of the pane).
FocusScope {
    id: onb

    property real u: 1
    property bool shown: false
    property string stage: "pair"                 // "pair" | "try" | "games"
    property string family: "playstation"         // whose steps show
    property string tryName: ""                    // the pad on the try screen
    property string tryFamily: ""                  // its family, connection and raw name (for the games step)
    property string tryTransport: ""
    property string tryRawName: ""
    property bool tryPadGone: false               // the tried pad left Input1: never look for another
    property var padsAtOpen: []                    // Input1 ids listed when the screen opened
    property string tryPadId: ""                   // its Input1 id, once Input1 lists it; kept for the games step
    property bool choosing: false                  // the games step waits for its save
    property string chosen: ""                     // the layout being saved
    property Item returnTo: null

    readonly property int maxRows: 4
    // The "8bitdo" chip names how to pair (its steps), not the pad's family: a connected 8BitDo pad is
    // xbox, nintendo or generic by its mode, and its model says 8BitDo (RUY-692).
    readonly property var chipFamilies: ["playstation", "xbox", "nintendo", "8bitdo", ""]
    readonly property bool windowOpen: hint.armed
    readonly property ControllerPairHint pairHint: hint
    readonly property int rowCount: found.count
    // What the buttons do on the screen on top (Shell's hint bar).
    readonly property var modalHints: stage === "try"
        ? [{ action: "options", text: qsTr("Continue") }, { action: "back", text: qsTr("Close") }]
        : [{ action: "accept", text: qsTr("Select") }, { action: "back", text: qsTr("Close") }]

    signal closed()

    // Devices paired when the screen opened (never listed) and how each listed one is doing:
    // id -> { phase: "pairing" | "failed" | "done", reason }.
    property var pairedBefore: ({})
    property var phases: ({})

    ListModel { id: found }

    function open() {
        returnTo = Window.activeFocusItem
        pairedBefore = {}
        for (const d of Bluetooth.devices) {
            if (d.paired)
                pairedBefore[d.id] = true
        }
        padsAtOpen = Input.devices.map(d => d.id)
        phases = {}
        stage = "pair"
        family = "playstation"
        found.clear()
        sync()
        shown = true
        chipFor(family).forceActiveFocus()
    }

    function close() {
        if (!shown)
            return
        shown = false
        choosing = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    // The pairing chip of a connected pad: 8BitDo by its model (whatever family its mode gives), else its family.
    function chipOf(padFamily, padModel) {
        if (String(padModel ?? "").startsWith("8bitdo_"))
            return "8bitdo"
        return chipFamilies.includes(padFamily) ? padFamily : ""
    }

    function chipFor(f) {
        return chips.itemAt(chipFamilies.indexOf(f))
    }

    function rowFor(id) {
        for (let i = 0; i < rows.count; ++i) {
            const r = rows.itemAt(i)
            if (r && r.objectName === "onbRow_" + id)
                return r
        }
        return null
    }

    // The words under a pad that failed to pair: the mapping the Bluetooth pane shares (BluetoothText).
    function reasonText(status) {
        return BluetoothText.statusText("pair", status, "controller")
    }

    function phaseOf(d) {
        const set = phases[d.id]
        if (d.paired && d.connected)
            return "done"
        if (d.paired)                             // bonded: the connection is on its way, unless the pair call ended
            return set && set.phase === "done" ? "done" : "pairing"
        return set ? set.phase : "idle"
    }

    // Controllers found or newly paired, by id, updated in place so the focus stays on a row.
    function sync() {
        const focusedId = rows.focusedId()
        const list = Bluetooth.devices.filter(d => d.kind === "controller" && !pairedBefore[d.id]).slice(0, maxRows)
        for (let i = found.count - 1; i >= 0; --i) {
            const id = found.get(i).devId
            if (!list.some(d => d.id === id))
                found.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const d = list[i]
            const set = phases[d.id]
            // The name the Bluetooth pane shows: the end of the address is added for a like-named pad.
            const parts = DeviceIcons.shownParts(Bluetooth.devices, d)
            const entry = { devId: d.id, name: parts.name, tail: parts.tail, family: d.family ?? "", silhouette: d.model ?? "", phase: phaseOf(d),
                            reason: set && set.reason ? set.reason : "" }
            let at = -1
            for (let j = 0; j < found.count; ++j) {
                if (found.get(j).devId === d.id) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                found.insert(i, entry)
            } else {
                found.set(at, entry)
                if (at !== i)
                    found.move(at, i, 1)
            }
        }
        Qt.callLater(onb.keepFocus, focusedId)
    }

    // A row that was in focus and vanished hands the focus to the one now at its place, or to the
    // chips when none is left. Nothing else moves.
    function keepFocus(focusedId) {
        if (!shown || !onb.activeFocus || stage !== "pair" || focusedId === "")
            return
        if (rowFor(focusedId))
            return
        if (rows.count > 0)
            rows.itemAt(Math.min(rows.lastIndex, rows.count - 1)).forceActiveFocus()
        else
            chipFor(family).forceActiveFocus()
    }

    function startPair(id) {
        const set = phases[id]
        if (set && set.phase === "pairing")
            return                                  // a second A or a key repeat does nothing
        phases[id] = { phase: "pairing", reason: "" }
        sync()
        Bluetooth.pair(id)
    }

    function activateRow(r) {
        if (r.phase === "done") {
            const d = Bluetooth.devices.find(x => x.id === r.devId)
            startTry(r.name, r.family, "bluetooth", d ? d.name : r.name)
            test.forceActiveFocus()
        } else if (r.phase !== "pairing") {
            Sfx.select()
            startPair(r.devId)
        }
    }

    function startTry(name, family, transport, rawName) {
        tryName = name
        tryFamily = family
        tryTransport = transport
        tryRawName = rawName
        tryPadId = ""
        tryPadGone = false
        stage = "try"
        resolveTried()
    }

    // The tried pad's Input1 id is resolved once and kept (GamepadConnected can arrive before
    // Input1 lists the pad, so it is tried again whenever the list changes). The layout of a
    // Nintendo pad is read while it is being tried, so Start knows it.
    function resolveTried() {
        if (tryPadId !== "" || tryPadGone)
            return
        const id = triedPadId()
        if (id === "")
            return
        tryPadId = id
        if (GameControls.owner !== "")
            GameControls.show(id)
    }

    // The tried pad left Input1: nothing is saved for it any more.
    function checkTriedPad() {
        if (!shown || (stage !== "try" && stage !== "games"))
            return
        if (tryPadId === "") {
            resolveTried()
        } else if (!Input.devices.some(d => d.id === tryPadId)) {
            tryPadId = ""
            tryPadGone = true
            if (stage === "games")
                onb.close()
        }
    }

    // The Input1 id of the pad being tried, else "". Only Nintendo pads get the games step. A pad
    // that is new since the screen opened qualifies (the name decides where several do); a pad that
    // was already listed is taken only over USB and only when its name is the tried pad's.
    function triedPadId() {
        if (tryFamily !== "nintendo")
            return ""
        const plain = n => DeviceIcons.plain(n).toLowerCase()
        const list = Input.devices.filter(d => d.family === "nintendo" && d.connection === tryTransport)
        const isNew = d => !padsAtOpen.includes(d.id)
        const sameName = d => plain(d.name) === plain(tryRawName)
        const fresh = list.filter(isNew)
        // Over Bluetooth the tried pad was paired in this screen, so a pad listed before is another one.
        const pool = fresh.length > 0 || tryTransport === "bluetooth" ? fresh : list
        const named = pool.filter(sameName)
        if (named.length === 1)
            return named[0].id
        return pool.length === 1 && isNew(pool[0]) ? pool[0].id : ""
    }

    // Start on the try stage: the games step for a Nintendo pad that still has the Standard layout
    // and whose profile can be saved; otherwise the screen closes.
    function continueFromTry() {
        const id = tryPadId
        if (id !== "" && GameControls.owner !== "" && GameControls.padId === id
                && GameControls.loadState === "ok" && GameControls.layout === "standard") {
            stage = "games"
            positionRow.forceActiveFocus()
        } else {
            onb.close()
        }
    }

    // A on a layout of the games step: the current one changes nothing; otherwise it is saved and
    // the screen closes when the save has ended (a refusal keeps it open, GameControls toasts).
    function chooseLayout(value) {
        if (choosing)
            return
        Sfx.select()
        // Never another pad's profile (GameControls.padFor falls back to the first pad).
        if (tryPadId === "" || !GameControls.pad || GameControls.pad.id !== tryPadId) {
            onb.close()
            return
        }
        if (value === GameControls.layout) {
            onb.close()
            return
        }
        choosing = true
        chosen = value
        // Nothing is saved while GameControls is not ready (RUY-714): the screen closes, not locks.
        if (!GameControls.setOwnLayout(value)) {
            choosing = false
            onb.close()
        }
    }

    function moveChips(delta) {
        const at = chipFamilies.indexOf(family)
        const next = Math.max(0, Math.min(chipFamilies.length - 1, at + delta))
        if (next !== at) {
            Sfx.navigate()
            family = chipFamilies[next]
            chipFor(family).forceActiveFocus()
        }
    }

    function moveRows(from, delta) {
        const next = from + delta
        if (next < 0) {
            Sfx.navigate()
            chipFor(family).forceActiveFocus()
        } else if (next < rows.count) {
            Sfx.navigate()
            rows.itemAt(next).forceActiveFocus()
        }
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Accessible.role: Accessible.Dialog
    Accessible.name: stage === "games" ? qsTr("Buttons in games")
                     : stage === "try" ? qsTr("Try your controller") : qsTr("Pair a controller")

    Connections {
        target: Bluetooth
        function onDevicesChanged() { if (onb.shown) onb.sync() }
        function onFinished(op, id, status) {
            if (op !== "pair" || !onb.shown || !(id in onb.phases))
                return
            const d = Bluetooth.devices.find(x => x.id === id)
            if (status === "ok" || (d && d.paired)) {
                onb.phases[id] = { phase: "done", reason: "" }
            } else {
                Sfx.back()
                onb.phases[id] = { phase: "failed", reason: onb.reasonText(status) }
            }
            onb.sync()
        }
        // A pad plugged in over USB while we wait: nothing to pair, go and try it.
        function onGamepadConnected(id, name, family, transport, model) {
            // Not while a row is still pairing: its result would be lost behind the try screen.
            const pairing = Object.values(onb.phases).some(p => p.phase === "pairing")
            if (onb.shown && onb.stage === "pair" && transport === "usb" && !pairing) {
                onb.family = onb.chipOf(family, model)
                onb.startTry(DeviceIcons.padName(id, name, family), family, transport, name)
                test.forceActiveFocus()
            }
        }
    }

    Connections {
        target: Input
        function onDevicesChanged() { onb.checkTriedPad() }
    }

    Connections {
        target: GameControls
        function onSaved(tag) {
            if (onb.choosing && tag === "layout") {
                onb.choosing = false
                onb.close()
            }
        }
        function onFailed(tag) {
            if (onb.choosing && tag === "layout") {
                onb.choosing = false
                const row = onb.chosen === "nintendo" ? nintendoRow : positionRow
                row.forceActiveFocus()
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        objectName: "onboardingPanel"
        anchors.centerIn: parent
        width: 1500 * onb.u
        height: content.height + 2 * Theme.spaceXl * onb.u
        radius: Theme.radiusL * onb.u
        color: Theme.panel
        border.color: Theme.glassBorder
    }

    Column {
        id: content
        anchors.centerIn: parent
        width: 1400 * onb.u
        spacing: Theme.spaceM * onb.u

        Text {
            objectName: "onboardingTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: onb.stage === "games" ? qsTr("Buttons in games")
                  : onb.stage === "try" ? qsTr("Try your controller") : qsTr("Pair a controller")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * onb.u
            font.weight: Theme.weightDemiBold
        }

        // ---- stage "pair" ----
        Column {
            objectName: "onboardingPair"
            width: parent.width
            visible: onb.stage === "pair"
            spacing: Theme.spaceM * onb.u

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("What kind of controller is it?")
                color: Theme.textDim
                font.pixelSize: Theme.typeCaption * onb.u
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spaceS * onb.u
                Repeater {
                    id: chips
                    model: onb.chipFamilies
                    delegate: Rectangle {
                        id: chip
                        required property string modelData
                        readonly property bool current: onb.family === modelData
                        objectName: "onbChip_" + (modelData === "" ? "other" : modelData)
                        width: 250 * onb.u
                        height: Theme.buttonHeight * onb.u
                        radius: height / 2
                        color: activeFocus ? Theme.focusFill : (current ? Theme.selectedFill : Theme.glass)
                        border.width: activeFocus ? Theme.focusRingWidth * onb.u : Theme.hairlineAt(onb.u)
                        border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: onb.pairHint.titleFor(modelData)
                        Accessible.checked: current
                        Accessible.focusable: true
                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.spaceS * onb.u
                            Icon {
                                u: onb.u
                                name: DeviceIcons.iconFor("controller", chip.modelData)
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: chip.modelData === "" ? qsTr("Other") : onb.chipName(chip.modelData)
                                color: Theme.text
                                font.pixelSize: Theme.typeBody * onb.u
                                font.weight: Theme.weightDemiBold
                            }
                        }
                        onActiveFocusChanged: if (activeFocus) onb.family = modelData
                    }
                }
            }

            Text {
                objectName: "onboardingSteps"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: onb.pairHint.stepsFor(onb.family)
                color: Theme.text
                font.pixelSize: Theme.typeBody * onb.u
                Accessible.role: Accessible.StaticText
                Accessible.name: onb.pairHint.titleFor(onb.family) + ". " + text
            }
            Text {
                objectName: "onboardingReceiverSteps"
                width: parent.width
                visible: onb.family === "xbox"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: onb.pairHint.receiverSteps
                color: Theme.textDim
                font.pixelSize: Theme.typeCaption * onb.u
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            // The pairing window (T-203) and its words: waiting, nothing found, a device ignored.
            ControllerPairHint {
                id: hint
                objectName: "onboardingHint"
                width: parent.width
                u: onb.u
                active: onb.shown && onb.stage === "pair"
                onPurpose: true
            }

            Pill {
                objectName: "onboardingSearchAgain"
                anchors.horizontalCenter: parent.horizontalCenter
                visible: hint.timedOut
                label: qsTr("Press A to search again")
            }

            Text {
                objectName: "onboardingFoundTitle"
                width: parent.width
                text: onb.rowCount > 0 ? qsTr("Found nearby") : qsTr("Nothing found yet")
                color: Theme.textDim
                font.pixelSize: Theme.typeCaption * onb.u
            }

            Column {
                id: list
                width: parent.width
                spacing: Theme.spaceXs * onb.u
                Repeater {
                    id: rows
                    model: found
                    readonly property int lastIndex: count - 1

                    function focusedId() {
                        for (let i = 0; i < count; ++i) {
                            const r = itemAt(i)
                            if (r && r.activeFocus)
                                return r.objectName.slice("onbRow_".length)
                        }
                        return ""
                    }

                    delegate: Rectangle {
                        id: row
                        required property int index
                        required property string devId
                        required property string name
                        required property string tail
                        required property string family
                        required property string silhouette   // the controller model
                        required property string phase
                        required property string reason
                        objectName: "onbRow_" + devId
                        width: list.width
                        height: Theme.rowHeight * onb.u
                        radius: Theme.radiusS * onb.u
                        color: activeFocus ? Theme.focusFill : Theme.glass
                        border.width: activeFocus ? Theme.focusRingWidth * onb.u : Theme.hairlineAt(onb.u)
                        border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
                        readonly property string stateText: {
                            switch (phase) {
                            case "pairing": return qsTr("Pairing…")
                            case "done": return qsTr("Connected, remembered · A: try its buttons")
                            case "failed": return qsTr("%1 A: try again").arg(reason)
                            }
                            return qsTr("A: pair")
                        }
                        Accessible.role: Accessible.Button
                        Accessible.name: name + tail + ", " + DeviceIcons.kindText("controller", family, silhouette) + ", " + stateText
                        Accessible.focusable: true
                        Icon {
                            id: rowGlyph
                            objectName: "onbRowGlyph"
                            u: onb.u
                            name: DeviceIcons.iconFor("controller", row.family, row.silhouette)
                            anchors { left: parent.left; leftMargin: Theme.spaceM * onb.u; verticalCenter: parent.verticalCenter }
                        }
                        // A name the device chose: plain text (TailText), cut at the end of the name and never in the end
                        // of its address (T-260, T-359).
                        TailText {
                            id: rowName
                            anchors { left: rowGlyph.right; leftMargin: Theme.spaceM * onb.u; verticalCenter: parent.verticalCenter }
                            objectName: "onbRowName_" + row.devId
                            maxWidth: row.width * 0.4
                            width: Math.min(implicitWidth, maxWidth)
                            name: row.name
                            tail: row.tail
                            color: Theme.text
                            font.pixelSize: Theme.typeBody * onb.u
                            font.weight: Theme.weightDemiBold
                        }
                        Text {
                            objectName: "onbRowState_" + row.devId
                            anchors { right: parent.right; rightMargin: Theme.spaceM * onb.u; verticalCenter: parent.verticalCenter }
                            width: Math.max(0, Math.min(implicitWidth, parent.width - rowName.width - rowGlyph.width - 4 * Theme.spaceM * onb.u))
                            elide: Text.ElideRight
                            text: row.stateText
                            color: row.phase === "failed" ? Theme.errorText : Theme.textDim
                            font.pixelSize: Theme.typeCaption * onb.u
                        }
                    }
                }
            }
        }

        // ---- stage "games" (RUY-503) ----
        Column {
            objectName: "onboardingGames"
            width: parent.width
            visible: onb.stage === "games"
            spacing: Theme.spaceM * onb.u

            Text {
                objectName: "onboardingGamesBody"
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width, 1100 * onb.u)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: qsTr("Menus confirm with A on this controller. Games can see the buttons by their letters, or by position like an Xbox controller.")
                color: Theme.text
                font.pixelSize: Theme.typeBody * onb.u
            }

            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 900 * onb.u
                spacing: Theme.spaceS * onb.u

                SettingRow {
                    id: positionRow
                    objectName: "gamesRowPosition"
                    kind: "item"
                    u: onb.u
                    width: parent.width
                    label: qsTr("By position")
                    detail: qsTr("The bottom button is A in games, as on Xbox.")
                    value: GameControls.layout === "standard" ? qsTr("Current", "the button layout in use") : ""
                    onActivated: onb.chooseLayout("standard")
                }
                SettingRow {
                    id: nintendoRow
                    objectName: "gamesRowNintendo"
                    kind: "item"
                    u: onb.u
                    width: parent.width
                    label: qsTr("Nintendo labels")
                    detail: qsTr("Games see each button by the letter on it.")
                    value: GameControls.layout === "nintendo" ? qsTr("Current", "the button layout in use") : ""
                    onActivated: onb.chooseLayout("nintendo")
                }
            }

            Text {
                objectName: "onboardingGamesNote"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("You can change this later in Settings > Controllers.")
                color: Theme.text
                font.pixelSize: Theme.typeCaption * onb.u
            }
        }

        // ---- stage "try" ----
        Column {
            objectName: "onboardingTry"
            width: parent.width
            visible: onb.stage === "try"
            spacing: Theme.spaceM * onb.u

            Text {
                objectName: "onboardingTryName"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText      // the pad's name came from the pad
                text: qsTr("%1 is connected. Press its buttons: they light up here.").arg(onb.tryName)
                color: Theme.text
                font.pixelSize: Theme.typeBody * onb.u
                wrapMode: Text.Wrap
            }

            ButtonTest {
                id: test
                objectName: "onboardingButtonTest"
                anchors.horizontalCenter: parent.horizontalCenter
                u: onb.u
                padName: onb.tryName
                onContinued: { Sfx.select(); onb.continueFromTry() }
                onClosed: { Sfx.back(); onb.close() }
            }
        }
    }

    // The words on a family chip: its maker's pad family, short.
    function chipName(f) {
        switch (f) {
        case "playstation": return qsTr("PlayStation")
        case "xbox": return qsTr("Xbox")
        case "nintendo": return qsTr("Nintendo")
        case "8bitdo": return qsTr("8BitDo")
        }
        return qsTr("Other")
    }

    // Modal: every key stops here. The chips and the rows are the only focus stops of the pair
    // stage; the try stage hands everything to ButtonTest.
    Keys.onPressed: event => {
        event.accepted = true
        if (onb.stage === "try" || event.isAutoRepeat)
            return
        if (onb.stage === "games") {
            if (onb.choosing)
                return
            if (BackKey.isBackOrBackspace(event.key)) {
                Sfx.back()
                onb.close()
            } else if (event.key === Qt.Key_Up && nintendoRow.activeFocus) {
                Sfx.navigate()
                positionRow.forceActiveFocus()
            } else if (event.key === Qt.Key_Down && positionRow.activeFocus) {
                Sfx.navigate()
                nintendoRow.forceActiveFocus()
            }
            return
        }
        const focused = Window.activeFocusItem
        const key = event.key
        const rowAt = (() => {
            for (let i = 0; i < rows.count; ++i) {
                if (rows.itemAt(i) === focused)
                    return i
            }
            return -1
        })()
        if (BackKey.isBackOrBackspace(key)) {
            Sfx.back()
            onb.close()
        } else if (rowAt >= 0) {
            if (key === Qt.Key_Up)
                onb.moveRows(rowAt, -1)
            else if (key === Qt.Key_Down)
                onb.moveRows(rowAt, 1)
            else if (key === Qt.Key_Return || key === Qt.Key_Enter)
                onb.activateRow(focused)
        } else {
            if (key === Qt.Key_Left)
                onb.moveChips(-1)
            else if (key === Qt.Key_Right)
                onb.moveChips(1)
            else if (key === Qt.Key_Down && rows.count > 0)
                onb.moveRows(-1, 1)
            else if ((key === Qt.Key_Return || key === Qt.Key_Enter) && hint.timedOut)
                hint.retry()
        }
    }
    // The Pill of the setup wizard, for "Press A to search again".
    component Pill: Rectangle {
        property string label
        implicitWidth: pillText.implicitWidth + 2 * Theme.spaceL * onb.u
        implicitHeight: Theme.buttonHeight * onb.u
        radius: height / 2
        color: Theme.primaryFill
        Text {
            id: pillText
            anchors.centerIn: parent
            text: parent.label
            color: Theme.onPrimary
            font.pixelSize: Theme.typeBody * onb.u
            font.weight: Theme.weightDemiBold
        }
    }
}
