pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Controllers -> a controller -> Button test (RUY-39 / T-368): a drawn pad (PadDiagram)
// whose buttons, sticks and triggers light up live from Input1's button test (StartTest when the
// page opens, StopTest when it closes; TestInput for every input of that pad), the raw values beside
// it, and a message line. Opened with params { id }.
//
// Leaving: Back pressed twice (the second press within 1000 ms of the first) or held 1000 ms. Nothing
// else leaves: every other key is taken here, except Guide, which opens the Hub as usual (the
// service ends the test on the route change; it starts again when the route is "shell" again). One
// Back press only says "Press [back] again to leave." and shows on the drawing like any button. When
// the service ends the test after 2 minutes without input the page closes with the toast "Button
// test ended". The pad disconnecting closes it (the controller page below says so).
Page {
    id: page

    readonly property string padId: String((params ?? {}).id ?? "")
    readonly property var current: ControllerPads.controllers().find(p => p.id === padId) ?? null
    property var pad: ({ id: padId, name: "", family: "", connection: "", percent: -1, state: "", slot: 0 })
    onCurrentChanged: if (current) pad = current

    title: qsTr("Button test")
    hints: [{ button: "B", text: qsTr("Press twice or hold to leave") }]

    // What the stream said: input -> held now / pressed once; axis -> value; the newest input.
    property var held: ({})
    property var tried: ({})
    property var axes: ({})
    property string lastInput: ""
    property string lastSource: ""
    // The test runs (StartTest answered ok or busy, and no TestEnded since).
    property bool running: false
    // One Back press waits for the second (1000 ms).
    readonly property bool awaitingSecondBack: againTimer.running
    property bool gone: false

    Component.onCompleted: {
        if (current)
            pad = current
        Input.startTest(padId)
    }
    Component.onDestruction: {
        if (!gone)
            Input.stopTest(padId)
    }

    function restart() {
        if (!gone && !running)
            Input.startTest(padId)
    }

    function leave() {
        if (gone)
            return
        gone = true
        againTimer.stop()
        holdTimer.stop()
        Input.stopTest(padId)
        page.backRequested()
    }

    // ---- the stream ----------------------------------------------------------------------------------
    readonly property var axisNames: ["left_x", "left_y", "right_x", "right_y", "left_trigger", "right_trigger",
                                      "gyro_x", "gyro_y", "gyro_z"]
    function apply(input, value, source) {
        lastSource = source
        if (axisNames.includes(input)) {
            const a = Object.assign({}, axes)
            a[input] = value
            axes = a
            // A trigger pulled past a quarter counts as pressed, for the drawing.
            if (input === "left_trigger" || input === "right_trigger")
                mark(input, value >= 8192)
            if (!input.startsWith("gyro_") && Math.abs(value) >= 8192)
                lastInput = input
            return
        }
        mark(input, value !== 0)
        if (value !== 0)
            lastInput = input
    }
    function mark(input, down) {
        const h = Object.assign({}, held)
        if (down)
            h[input] = true
        else
            delete h[input]
        held = h
        if (down && tried[input] !== true) {
            const t = Object.assign({}, tried)
            t[input] = true
            tried = t
        }
    }

    Connections {
        target: Input
        function onTestStartFinished(deviceId, status) {
            if (deviceId === page.padId)
                page.running = status === "ok" || status === "busy"
        }
        function onTestInput(deviceId, input, value, source) {
            if (deviceId === page.padId && !page.gone)
                page.apply(input, value, source)
        }
        function onTestEnded(deviceId, reason) {
            if (deviceId !== page.padId || page.gone)
                return
            page.running = false
            // Ended by a route change that is already over (back in the shell): start again.
            if (reason === "route" && Input.route === "shell")
                Qt.callLater(page.restart)
            if (reason === "idle") {
                page.gone = true
                Notifications.show(qsTr("Button test ended"), "info", "", "", qsTr("No input for 2 minutes."))
                page.backRequested()
            }
        }
        function onRouteChanged() {
            // Back from the Hub: the service ended the test on the route change; start it again.
            // Later: the facade announces the route before it sends SetRoute.
            if (Input.route === "shell" && !page.running && !page.gone)
                Qt.callLater(page.restart)
        }
        function onServiceOwnedChanged() {
            if (Input.serviceOwned && !page.gone)
                Input.startTest(page.padId)       // a restarted service has no test
        }
        function onDevicesChanged() {
            if (!page.gone && Input.devicesState === "ok" && !Input.devices.some(d => d.id === page.padId)) {
                page.gone = true
                page.backRequested()              // the controller page below shows the toast
            }
        }
    }

    // ---- leaving -----------------------------------------------------------------------------------
    Timer {
        id: againTimer
        interval: 1000          // the second Back press counts within 1 s of the first (not a Theme duration)
    }
    Timer {
        id: holdTimer
        interval: 1000          // Back held 1 s leaves
        onTriggered: page.leave()
    }

    // The Guide keys of KeyRouter::isGuideKey (C++, not reachable from a page): they bubble to the shell.
    function isGuide(key) {
        return key === Qt.Key_HomePage || key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_Meta
    }

    FocusScope {
        id: catcher
        objectName: "buttonTestKeys"
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            if (page.isGuide(event.key))
                return                          // the Hub opens as usual
            event.accepted = true
            if (!BackKey.isBack(event.key) || event.isAutoRepeat)
                return
            if (againTimer.running) {
                page.leave()
                return
            }
            againTimer.restart()
            holdTimer.restart()
        }
        Keys.onReleased: event => {
            if (page.isGuide(event.key))
                return
            event.accepted = true
            if (BackKey.isBack(event.key) && !event.isAutoRepeat)
                holdTimer.stop()
        }
    }

    // ---- the drawing -------------------------------------------------------------------------------
    PadDiagram {
        id: diagram
        objectName: "padDiagram"
        x: 34 * page.u
        y: 12 * page.u
        u: page.u
        family: page.pad.family
        held: page.held
        tried: page.tried
        axes: page.axes
    }

    // ---- the raw values ----------------------------------------------------------------------------
    // "−1 204": a real minus and space-separated groups, the same in every language.
    function num(n) {
        const digits = String(Math.abs(Math.round(n)))
        let out = ""
        for (let i = 0; i < digits.length; ++i) {
            if (i > 0 && (digits.length - i) % 3 === 0)
                out += " "
            out += digits[i]
        }
        return (n < 0 ? "−" : "") + out
    }
    function dec(v) {
        const s = (Math.abs(v) / 16).toFixed(1).replace(".", Qt.locale().decimalPoint)
        return (v < 0 ? "−" : "") + s
    }
    function stickText(side) {
        const x = axes[side + "_x"]
        const y = axes[side + "_y"]
        if (x === undefined && y === undefined)
            return "—"
        return qsTr("x %1  y %2").arg(num(x ?? 0)).arg(num(y ?? 0))
    }
    function triggerText() {
        const l = axes.left_trigger
        const r = axes.right_trigger
        if (l === undefined && r === undefined)
            return "—"
        return qsTr("%1 · %2").arg(num(l ?? 0)).arg(num(r ?? 0))
    }
    function gyroText() {
        if (axes.gyro_x === undefined && axes.gyro_y === undefined && axes.gyro_z === undefined)
            return "—"
        return qsTr("x %1  y %2  z %3 °/s").arg(dec(axes.gyro_x ?? 0)).arg(dec(axes.gyro_y ?? 0)).arg(dec(axes.gyro_z ?? 0))
    }
    // "Cross (south)": the family's word for a face button, then its position.
    function inputText(input) {
        const ps = pad.family === "playstation"
        switch (input) {
        case "": return qsTr("None")
        case "south": return ps ? qsTr("Cross (south)") : qsTr("A (south)")
        case "east": return ps ? qsTr("Circle (east)") : qsTr("B (east)")
        case "west": return ps ? qsTr("Square (west)") : qsTr("X (west)")
        case "north": return ps ? qsTr("Triangle (north)") : qsTr("Y (north)")
        case "l1": return ps ? "L1" : "LB"
        case "r1": return ps ? "R1" : "RB"
        case "left_trigger": return ps ? "L2" : "LT"
        case "right_trigger": return ps ? "R2" : "RT"
        case "l3": return qsTr("Left stick click")
        case "r3": return qsTr("Right stick click")
        case "left_x":
        case "left_y": return qsTr("Left stick")
        case "right_x":
        case "right_y": return qsTr("Right stick")
        case "select": return ps ? qsTr("Create") : qsTr("View")
        case "start": return ps ? qsTr("Options") : qsTr("Menu")
        case "guide": return qsTr("Guide")
        case "dpad_up": return qsTr("D-pad up")
        case "dpad_down": return qsTr("D-pad down")
        case "dpad_left": return qsTr("D-pad left")
        case "dpad_right": return qsTr("D-pad right")
        }
        return input            // a raw input: its source is its name
    }

    Rectangle {
        id: rawPanel
        objectName: "rawPanel"
        x: (1290 - 96) * page.u
        width: 534 * page.u
        height: rawColumn.height + 2 * Theme.spaceXl * page.u
        radius: Theme.radiusL * page.u
        color: Theme.blurMax > 0 ? Theme.glass : Theme.glassOpaque
        GlassLayers {
            anchors.fill: parent
            u: page.u
            radius: rawPanel.radius
            grain: false
        }
        Column {
            id: rawColumn
            x: Theme.spaceXl * page.u
            y: Theme.spaceXl * page.u
            width: parent.width - 2 * Theme.spaceXl * page.u
            spacing: Theme.spaceM * page.u
            Column {
                width: parent.width
                Text {
                    objectName: "rawName"
                    width: parent.width
                    textFormat: Text.PlainText
                    text: page.pad.name
                    color: Theme.text
                    font.pixelSize: Theme.typeHeadline * page.u
                    font.weight: Theme.weightDemiBold
                    elide: Text.ElideRight
                }
                Text {
                    objectName: "rawDetail"
                    width: parent.width
                    text: [ControllerPads.connectionText(page.pad.connection), ControllerPads.playerText(page.pad.slot)]
                          .filter(t => t !== "").join(qsTr(" · "))
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * page.u
                    elide: Text.ElideRight
                }
            }
            Column {
                width: parent.width
                spacing: Theme.spaceS * page.u
                Repeater {
                    model: [
                        { key: "left", label: qsTr("Left stick"), value: page.stickText("left") },
                        { key: "right", label: qsTr("Right stick"), value: page.stickText("right") },
                        { key: "triggers", label: page.pad.family === "playstation" ? qsTr("L2 · R2") : qsTr("LT · RT"), value: page.triggerText() },
                        { key: "gyro", label: qsTr("Gyro"), value: page.gyroText() },
                        { key: "last", label: qsTr("Last input"), value: page.inputText(page.lastInput) },
                        { key: "source", label: qsTr("Source"), value: page.lastSource !== "" ? page.lastSource : "\u2014" }
                    ]
                    // One row per reading: the label (200 u, caption DemiBold), then the value (body, tabular figures).
                    delegate: Row {
                        id: reading
                        required property var modelData
                        spacing: Theme.spaceM * page.u
                        Text {
                            width: 200 * page.u
                            anchors.baseline: valueText.baseline
                            text: reading.modelData.label
                            color: Theme.text
                            font.pixelSize: Theme.typeCaption * page.u
                            font.weight: Theme.weightDemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            id: valueText
                            objectName: "raw_" + reading.modelData.key
                            width: rawColumn.width - 200 * page.u - Theme.spaceM * page.u
                            textFormat: Text.PlainText
                            text: reading.modelData.value
                            color: Theme.text
                            font.pixelSize: Theme.typeBody * page.u
                            font.features: { "tnum": 1 }
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }

    // ---- the message line ----------------------------------------------------------------------------
    Row {
        id: message
        objectName: "testMessage"
        readonly property var parts: (page.awaitingSecondBack
                                      ? qsTr("Press %1 again to leave.")
                                      : qsTr("Press any button to see it light up. Press %1 twice or hold it to leave.")).split("%1")
        readonly property string text: parts.join("B")
        x: 34 * page.u
        y: 628 * page.u
        spacing: Theme.spaceXs * page.u
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: message.parts[0].trim()
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
        }
        ButtonGlyph {
            anchors.verticalCenter: parent.verticalCenter
            u: page.u
            button: "B"
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: (message.parts[1] ?? "").trim()
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
        }
    }
}
