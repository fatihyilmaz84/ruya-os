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
// Controllers that were already paired when the screen opened are not listed (they are in the
// paired list of the pane).
FocusScope {
    id: onb

    property real u: 1
    property bool shown: false
    property string stage: "pair"                 // "pair" | "try"
    property string family: "playstation"         // whose steps show
    property string tryName: ""                    // the pad on the try screen
    property Item returnTo: null

    readonly property int maxRows: 4
    readonly property var chipFamilies: ["playstation", "xbox", "nintendo", "8bitdo", ""]
    readonly property bool windowOpen: hint.armed
    readonly property ControllerPairHint pairHint: hint
    readonly property int rowCount: found.count
    // What the buttons do on the screen on top (Shell's hint bar).
    readonly property var modalHints: stage === "try"
        ? [{ button: "Start", text: qsTr("Continue") }, { button: "B", text: qsTr("Close") }]
        : [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Close") }]

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
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
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

    function reasonText(status) {
        switch (status) {
        case "pairing-failed": return qsTr("Pairing failed. Put the controller in pairing mode again.")
        case "timeout": return qsTr("The controller did not answer.")
        case "unavailable": return qsTr("Bluetooth is off.")
        case "unknown-device": return qsTr("The controller went away.")
        }
        return qsTr("Could not pair the controller.")
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
            const entry = { devId: d.id, name: DeviceIcons.plain(d.name), family: d.family ?? "", phase: phaseOf(d),
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
            tryName = r.name
            stage = "try"
            test.forceActiveFocus()
        } else if (r.phase !== "pairing") {
            Sfx.select()
            startPair(r.devId)
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
    Accessible.name: stage === "try" ? qsTr("Try your controller") : qsTr("Pair a controller")

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
        function onGamepadConnected(id, name, family, transport) {
            // Not while a row is still pairing: its result would be lost behind the try screen.
            const pairing = Object.values(onb.phases).some(p => p.phase === "pairing")
            if (onb.shown && onb.stage === "pair" && transport === "usb" && !pairing) {
                onb.tryName = DeviceIcons.padName(id, name, family)
                onb.stage = "try"
                test.forceActiveFocus()
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
            text: onb.stage === "try" ? qsTr("Try your controller") : qsTr("Pair a controller")
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
                        required property string family
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
                        Accessible.name: name + ", " + DeviceIcons.kindText("controller", family) + ", " + stateText
                        Accessible.focusable: true
                        Icon {
                            id: rowGlyph
                            u: onb.u
                            name: DeviceIcons.iconFor("controller", row.family)
                            anchors { left: parent.left; leftMargin: Theme.spaceM * onb.u; verticalCenter: parent.verticalCenter }
                        }
                        Text {
                            id: rowName
                            anchors { left: rowGlyph.right; leftMargin: Theme.spaceM * onb.u; verticalCenter: parent.verticalCenter }
                            objectName: "onbRowName_" + row.devId
                            width: Math.min(implicitWidth, row.width * 0.4)
                            elide: Text.ElideRight
                            // A name the device chose: plain text, never markup (T-260).
                            textFormat: Text.PlainText
                            text: row.name
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
                onContinued: { Sfx.select(); onb.close() }
                onClosed: { Sfx.back(); onb.close() }
            }
        }
    }

    // The words on a family chip: its maker's pad family, short.
    function chipName(f) {
        switch (f) {
        case "playstation": return qsTr("PlayStation")
        case "xbox": return qsTr("Xbox")
        case "nintendo": return qsTr("Switch")
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
