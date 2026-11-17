pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Controllers -> a controller (RUY-39 / T-368): what the pad is and what it can do, and
// the way to its Button test and to Controls in games (RUY-465). Opened with params { id } (Input1's stable id). Left, not focusable:
// the family glyph at `cardIconSize`, the name, the kind in words, the connection, the battery and
// the player (when the record has one). Right, a pane: "Button test" (focus first), "Controls in games"
// (value "Default" / "Changed"; opens ControlsPage for this pad), "Confirm in menus" (RUY-603: this pad's
// "As on the controller" / "Bottom" / "Right" for the signed-in profile, with a note naming the buttons
// that confirm and go back on it; dimmed "Not available" without Input1), "Button layout in games"
// (RUY-500: By position / Nintendo labels for this pad's own profile, with a note naming the buttons
// games see as A and B; dimmed "Not available" when the profiles can't be read), then the group
// "What it can do" with one read-only row per capability the model has (Input1.GetCapabilities, in
// descriptor order; buttons, sticks and the D-pad are one row, the battery is in the left column),
// each saying "Works", "Not passed to games", "Not available now" or "Not supported yet" (06 §4.3).
// Back (or Left) closes the page. A Bluetooth pad matched to exactly one device also has "Rename %1" and "Forget %1" (RUY-504: the Bluetooth pane's keyboard and confirmation, BluetoothDeviceActions) after the settings rows, before the group; forgetting closes the page without the toast. The pad disconnecting closes it (and the Button test over it) with
// the toast "Controller disconnected".
Page {
    id: page

    readonly property string padId: String((params ?? {}).id ?? "")
    // The pad as the shell shows it; the last one seen stays while the page closes.
    readonly property var current: ControllerPads.controllers().find(p => p.id === padId) ?? null
    property var pad: ({ id: padId, name: "", family: "", connection: "", percent: -1, state: "", slot: 0 })
    onCurrentChanged: if (current) pad = current
    // This pad's Confirm button for the signed-in profile (RUY-603): "family" | "south" | "east".
    readonly property string confirmMode: String(Input.confirmButtons[padId] ?? "family")
    // Button layout in games is editable while GameControls can read the profiles (RUY-500).
    readonly property bool layoutAvailable: Input.confirmButtonsAvailable && GameControls.loadState === "ok"
                                                 && GameControls.pad !== null && GameControls.pad.id === page.padId
    // The Bluetooth device this pad was matched to (exactly one, ControllerPads), for Rename and Forget (RUY-504).
    readonly property var btDevice: (pad.btId ?? "") !== "" ? (Bluetooth.devices.find(d => d.id === pad.btId) ?? null) : null
    readonly property var btShown: btDevice ? DeviceIcons.shownParts(Bluetooth.devices, btDevice) : ({ name: "", tail: "" })
    glyphFamily: pad.family ?? ""
    glyphConfirmMode: confirmMode
    Component.onCompleted: {
        if (current)
            pad = current
        Input.requestCapabilities(padId)
        Input.refreshConfirmButtons()
        GameControls.show(padId)
    }

    title: pad.name

    hints: body.hints

    // "loading" | "ok" | "failed"
    property string capsState: "loading"
    property var capabilities: []

    // Words for a capability's four booleans (06 §4.3), worst first.
    function level(c) {
        return !c.driver ? 3 : !c.available ? 2 : !c.output ? 1 : 0
    }
    function levelText(n) {
        switch (n) {
        case 0: return qsTr("Works")
        case 1: return qsTr("Not passed to games")
        case 2: return qsTr("Not available now")
        }
        return qsTr("Not supported yet")
    }
    function capabilityLabel(name) {
        switch (name) {
        case "buttons": return qsTr("Buttons and sticks")
        case "analog_triggers": return qsTr("Analog triggers")
        case "rumble": return qsTr("Rumble")
        case "trigger_rumble": return qsTr("Trigger rumble")
        case "adaptive_triggers": return qsTr("Adaptive triggers")
        case "gyro": return qsTr("Gyro")
        case "accelerometer": return qsTr("Accelerometer")
        case "touchpad": return qsTr("Touchpad")
        case "lightbar": return qsTr("Light bar")
        case "player_leds": return qsTr("Player lights")
        case "speaker": return qsTr("Speaker")
        case "microphone": return qsTr("Microphone")
        }
        return name
    }
    // The rows: [{ name, level }] for the capabilities the model has, in descriptor order. Buttons,
    // sticks and the D-pad are one row ("buttons") with the worst of the three; battery has none.
    function capabilityRows(caps) {
        const rows = []
        const core = caps.filter(c => c.hardware && (c.name === "buttons" || c.name === "sticks" || c.name === "dpad"))
        if (core.length > 0)
            rows.push({ name: "buttons", level: Math.max(...core.map(c => page.level(c))) })
        for (const c of caps) {
            if (!c.hardware || c.name === "buttons" || c.name === "sticks" || c.name === "dpad" || c.name === "battery")
                continue
            rows.push({ name: c.name, level: page.level(c) })
        }
        return rows
    }

    Connections {
        target: Input
        function onCapabilitiesFinished(deviceId, status, capabilities) {
            if (deviceId !== page.padId)
                return
            page.capabilities = status === "ok" ? page.capabilityRows(capabilities) : []
            page.capsState = status === "ok" ? "ok" : "failed"
            Qt.callLater(body.reflow)
        }
        function onDevicesChanged() { page.checkGone() }
        function onConfirmButtonRefused(deviceId) {
            if (deviceId === page.padId)
                Notifications.show(qsTr("Could not change the confirm button"), "error", "", "", qsTr("Try again."))
        }
    }

    // The pad disconnected: the page closes (once), with a toast that names it. A page that is
    // closing for any reason (Back too) never asks to close again: that would close the page below.
    // A pad the player forgot here left on purpose: it closes the page without the toast.
    property bool gone: false
    property bool forgotOnPurpose: false
    onBackRequested: gone = true
    function checkGone() {
        if (gone || Input.devicesState !== "ok" || Input.devices.some(d => d.id === padId))
            return
        gone = true
        if (!forgotOnPurpose)
            Notifications.show(qsTr("Controller disconnected"), "info", "", DeviceIcons.iconFor("controller", pad.family, pad.model),
                               pad.name)
        page.backRequested()
    }

    Column {
        objectName: "controllerFacts"
        width: 470 * page.u
        spacing: Theme.spaceS * page.u

        Icon {
            objectName: "controllerGlyph"
            u: page.u
            size: Theme.cardIconSize      // the page's literal size for the family glyph (04 §5)
            name: DeviceIcons.iconFor("controller", page.pad.family, page.pad.model)
        }
        Text {
            objectName: "controllerName"
            width: parent.width
            textFormat: Text.PlainText
            text: page.pad.name
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * page.u
            font.weight: Theme.weightDemiBold
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
        Column {
            width: parent.width
            spacing: Theme.spaceXs * page.u
            Repeater {
                model: [
                    DeviceIcons.kindText("controller", page.pad.family, page.pad.model ?? ""),
                    ControllerPads.connectionText(page.pad.connection),
                    ControllerPads.batteryText(page.pad.percent, page.pad.state),
                    ControllerPads.playerText(page.pad.slot)
                ].filter(t => t !== "")
                Text {
                    required property string modelData
                    width: 470 * page.u
                    textFormat: Text.PlainText
                    text: modelData
                    color: Theme.text
                    font.pixelSize: Theme.typeBody * page.u
                    elide: Text.ElideRight
                }
            }
        }
    }

    BluetoothDeviceActions {
        id: actions
        u: page.u
        overlay: page.overlay
        onForgetConfirmed: page.forgotOnPurpose = true
    }
    Connections {
        target: Bluetooth
        function onFinished(op, id, status) {
            if (op === "forget" && status !== "ok")
                page.forgotOnPurpose = false       // refused: the pad is still here
        }
    }

    SettingsPane {
        id: body
        objectName: "controllerBody"
        anchors { left: parent.left; leftMargin: (470 + Theme.spaceXxl) * page.u; right: parent.right; top: parent.top; bottom: parent.bottom }
        u: page.u
        focus: true
        onExitRequested: page.backRequested()

        SettingRow {
            id: testRow
            objectName: "rowButtonTest"
            kind: "page"
            u: page.u
            label: qsTr("Button test")
            onActivated: page.openRequested("buttonTest", ({ id: page.padId }))
        }

        SettingRow {
            id: controlsRow
            objectName: "rowControlsInGames"
            kind: "page"
            u: page.u
            label: qsTr("Controls in games")
            value: GameControls.changedFor(page.pad) ? qsTr("Changed") : qsTr("Default")
            onActivated: page.openRequested("controls", ({ id: page.padId }))
        }

        // Confirm in menus (RUY-603, 06 §11.2): this pad's own choice for the signed-in profile
        // (Input.confirmButtons; Left/Right apply it at once through Input1.SetConfirmButton, a refusal
        // puts the stored value back and toasts); dimmed "Not available" without Input1.
        ChoiceRow {
            id: confirmRow
            objectName: "rowConfirmButton"
            visible: Input.confirmButtonsAvailable
            u: page.u
            label: qsTr("Confirm in menus")
            options: [
                { value: "family", label: qsTr("As on the controller") },
                { value: "south", label: qsTr("Bottom") },
                { value: "east", label: qsTr("Right") },
            ]
            value: page.confirmMode
            // The row shows the stored value: Input.confirmButtons changes at once and goes back on a refusal.
            onEdited: v => {
                Input.setConfirmButton(page.padId, v)
                confirmRow.value = Qt.binding(() => page.confirmMode)
            }
            accessibleValue: currentLabel + ". " + confirmNote.sentence
        }
        SettingRow {
            objectName: "rowConfirmButtonUnavailable"
            kind: "item"
            visible: !Input.confirmButtonsAvailable
            dimmed: true
            u: page.u
            label: qsTr("Confirm in menus")
            value: qsTr("Not available")
            onActivated: Notifications.show(qsTr("%1: %2.").arg(label).arg(value), "info")
        }

        // The note under the row: which buttons confirm and go back on this pad, after its setting
        // (RUY-41: the family's printed labels; Accept is the right button on a Nintendo pad as it is,
        // and with "Right" on every pad), whatever pad pressed last.
        GlyphNote {
            id: confirmNote
            objectName: "confirmNote"
            visible: confirmRow.visible
            u: page.u
            text: qsTr("On this controller: %1 confirms, %2 goes back.")
            family: page.pad.family
            confirmMode: page.confirmMode
            firstAction: "accept"
            secondAction: "back"
            firstName: "confirmNoteAccept"
            secondName: "confirmNoteBack"
        }

        // Button layout in games (RUY-500, 06 §7, §11.2): this pad's own profile through GameControls,
        // as Controls in games edits it (Left/Right save at once, a refusal puts it back and toasts);
        // dimmed "Not available" when the profiles can't be read.
        ChoiceRow {
            id: gamesLayoutRow
            objectName: "rowGamesLayout"
            visible: page.layoutAvailable
            u: page.u
            label: qsTr("Button layout in games")
            options: [
                { value: "standard", label: qsTr("By position") },
                { value: "nintendo", label: qsTr("Nintendo labels") },
            ]
            onEdited: v => GameControls.setLayout(v)
            accessibleValue: currentLabel + (gamesNote.visible ? ". " + gamesNote.sentence : "")
        }
        Binding { target: gamesLayoutRow; property: "value"; value: GameControls.layout }
        SettingRow {
            objectName: "rowGamesLayoutUnavailable"
            kind: "item"
            visible: !page.layoutAvailable
            dimmed: true
            u: page.u
            label: qsTr("Button layout in games")
            value: qsTr("Not available")
            onActivated: Notifications.show(qsTr("%1: %2.").arg(label).arg(value), "info")
        }

        // What games see of this pad's buttons (06 §7); hidden when a button is remapped away.
        GlyphNote {
            id: gamesNote
            objectName: "gamesNote"
            readonly property var buttons: GameControls.gamesButtons()
            visible: gamesLayoutRow.visible && buttons !== null
            u: page.u
            text: GameControls.gamesNoteText(buttons ? buttons.unlike : false)
            family: page.pad.family
            firstPosition: buttons ? buttons.a : ""
            secondPosition: buttons ? buttons.b : ""
            firstName: "gamesNoteA"
            secondName: "gamesNoteB"
        }

        // Rename and Forget for a Bluetooth pad (RUY-504), the Bluetooth pane's own flows.
        SettingRow {
            objectName: "rowPadRename"
            kind: "action"
            visible: page.btDevice !== null
            u: page.u
            label: qsTr("Rename %1").arg(page.btShown.name)
            labelTail: page.btShown.tail
            onActivated: actions.askRename(page.btDevice.id, page.btDevice.name, DeviceIcons.shownName(Bluetooth.devices, page.btDevice))
        }
        SettingRow {
            objectName: "rowPadForget"
            kind: "action"
            visible: page.btDevice !== null
            u: page.u
            label: qsTr("Forget %1").arg(page.btShown.name)
            labelTail: page.btShown.tail
            onActivated: actions.askForget(page.btDevice.id, DeviceIcons.shownName(Bluetooth.devices, page.btDevice))
        }

        GroupLabel {
            objectName: "capsHeading"
            u: page.u
            visible: page.capsState !== "loading"
            text: qsTr("What it can do")
        }

        SettingRow {
            objectName: "capsFailed"
            kind: "info"
            visible: page.capsState === "failed"
            enabled: false
            u: page.u
            label: qsTr("Controllers can't be read right now.")
        }

        Repeater {
            model: page.capabilities
            SettingRow {
                required property var modelData
                objectName: "cap_" + modelData.name
                kind: "info"
                u: page.u
                label: page.capabilityLabel(modelData.name)
                value: page.levelText(modelData.level)
            }
        }
    }
}
