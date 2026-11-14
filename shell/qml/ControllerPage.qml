pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Controllers -> a controller (RUY-39 / T-368): what the pad is and what it can do, and
// the way to its Button test and to Controls in games (RUY-465). Opened with params { id } (Input1's stable id). Left, not focusable:
// the family glyph at `cardIconSize`, the name, the kind in words, the connection, the battery and
// the player (when the record has one). Right, a pane: "Button test" (focus first), "Controls in games"
// (value "Default" / "Changed"; opens ControlsPage for this pad), "Confirm in menus" (RUY-603: this pad's
// "As on the controller" / "Bottom" / "Right" for the signed-in profile, with a note naming the buttons
// that confirm and go back on it; dimmed "Not available" without Input1), then the group
// "What it can do" with one read-only row per capability the model has (Input1.GetCapabilities, in
// descriptor order; buttons, sticks and the D-pad are one row, the battery is in the left column),
// each saying "Works", "Not passed to games", "Not available now" or "Not supported yet" (06 §4.3).
// Back (or Left) closes the page. The pad disconnecting closes it (and the Button test over it) with
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
    glyphFamily: pad.family ?? ""
    glyphConfirmMode: confirmMode
    Component.onCompleted: {
        if (current)
            pad = current
        Input.requestCapabilities(padId)
        Input.refreshConfirmButtons()
        GameControls.refresh()
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
    property bool gone: false
    onBackRequested: gone = true
    function checkGone() {
        if (gone || Input.devicesState !== "ok" || Input.devices.some(d => d.id === padId))
            return
        gone = true
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
                    DeviceIcons.kindText("controller", page.pad.family),
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

        // The note under the row: which buttons confirm and go back on this pad, after its setting.
        Item {
            id: confirmNote
            objectName: "confirmNote"
            visible: confirmRow.visible
            width: parent ? parent.width : 0
            height: visible ? noteRow.height : 0

            // This pad's own glyphs after its own Confirm choice (RUY-41: the family's printed labels;
            // Accept is the right button on a Nintendo pad as it is, and with "Right" on every pad),
            // whatever pad pressed last.
            readonly property string acceptLabel: Glyphs.glyphFor("accept", page.pad.family, page.confirmMode).name
            readonly property string backLabel: Glyphs.glyphFor("back", page.pad.family, page.confirmMode).name
            readonly property string sentence: qsTr("On this controller: %1 confirms, %2 goes back.").arg(acceptLabel).arg(backLabel)

            Row {
                id: noteRow
                objectName: "confirmNoteRow"
                spacing: Theme.spaceXs * page.u
                leftPadding: Theme.spaceL * page.u
                y: -4 * page.u                 // 4 u closer to its row than the row gap (04 §5)
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("On this controller:")
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * page.u
                }
                ButtonGlyph {
                    objectName: "confirmNoteAccept"
                    anchors.verticalCenter: parent.verticalCenter
                    u: page.u
                    action: "accept"
                    family: page.pad.family
                    confirmMode: page.confirmMode
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("confirms,")
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * page.u
                }
                ButtonGlyph {
                    objectName: "confirmNoteBack"
                    anchors.verticalCenter: parent.verticalCenter
                    u: page.u
                    action: "back"
                    family: page.pad.family
                    confirmMode: page.confirmMode
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("goes back.")
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * page.u
                }
            }
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
