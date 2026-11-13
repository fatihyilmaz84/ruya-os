pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Controllers -> a controller (RUY-39 / T-368): what the pad is and what it can do, and
// the way to its Button test. Opened with params { id } (Input1's stable id). Left, not focusable:
// the family glyph at `cardIconSize`, the name, the kind in words, the connection, the battery and
// the player (when the record has one). Right, a pane: "Button test" (focus first), then the group
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
    Component.onCompleted: {
        if (current)
            pad = current
        Input.requestCapabilities(padId)
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
    }

    // The pad disconnected: the page closes (once), with a toast that names it.
    property bool gone: false
    function checkGone() {
        if (gone || Input.devicesState !== "ok" || Input.devices.some(d => d.id === padId))
            return
        gone = true
        Notifications.show(qsTr("Controller disconnected"), "info", "", DeviceIcons.iconFor("controller", pad.family),
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
            name: DeviceIcons.iconFor("controller", page.pad.family)
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
        // The capability rows are read-only: Back only while one has focus.
        hints: testRow.activeFocus ? [{ button: "A", text: qsTr("Open") }, { button: "B", text: qsTr("Back") }]
                                   : [{ button: "B", text: qsTr("Back") }]
        onExitRequested: page.backRequested()

        SettingRow {
            id: testRow
            objectName: "rowButtonTest"
            u: page.u
            label: qsTr("Button test")
            onActivated: page.openRequested("buttonTest", ({ id: page.padId }))
        }

        // The group label (04 §5 "Pane group label"): not focusable, 8 u more above it than a row gap.
        Item {
            objectName: "capsHeading"
            visible: page.capsState !== "loading"
            width: parent ? parent.width : 0
            height: headingText.height + Theme.spaceXs * page.u
            Text {
                id: headingText
                anchors { left: parent.left; leftMargin: Theme.spaceL * page.u; bottom: parent.bottom }
                text: qsTr("What it can do")
                color: Theme.text
                font.pixelSize: Theme.typeCaption * page.u
                font.weight: Theme.weightDemiBold
            }
        }

        SettingRow {
            objectName: "capsFailed"
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
                u: page.u
                inert: true
                label: page.capabilityLabel(modelData.name)
                value: page.levelText(modelData.level)
            }
        }
    }
}
