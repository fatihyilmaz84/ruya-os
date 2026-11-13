pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Controls in games -> Left stick / Right stick (RUY-465, 06 §7). Opened with params { id, side }
// (side "left" | "right"; id the pad shown, none: the first connected one). Left, not focusable, the
// preview panel: two StickPlots (Position, Response) live from the pad's test stream (StartTest
// while the page is open, StopTest when it closes; started again after the service ended it), the
// readout "In 0.74 · Out 0.71" and a legend; no pad: "Connect a controller to see the stick move.".
// Right, a pane: Inner, Outer and Anti dead zone, Response curve, Sensitivity, Invert up and down,
// Reset this stick. Every change saves at once (a held slider 300 ms after its last step) and the
// plots follow every step; a refused save puts the stored value back (GameControls).
Page {
    id: page

    readonly property string padId: String((params ?? {}).id ?? "")
    readonly property string side: (params ?? {}).side === "right" ? "right" : "left"
    readonly property var pad: GameControls.padFor(padId)
    readonly property var settings: GameControls.stick(side)

    title: side === "right" ? qsTr("Right stick") : qsTr("Left stick")
    hints: body.hints

    // The stick's position from the stream, -1..1 (y down, as the pad sends it).
    property real stickX: 0
    property real stickY: 0
    // The pad whose stream runs ("" none).
    property string testingId: ""
    property bool gone: false
    onBackRequested: gone = true

    Component.onCompleted: {
        GameControls.refresh()
        followPad()
    }
    Component.onDestruction: stopStream()
    onPadChanged: followPad()

    function followPad() {
        const id = pad ? pad.id : ""
        if (id === testingId || gone)
            return
        stopStream()
        stickX = 0
        stickY = 0
        testingId = id
        if (id !== "")
            Input.startTest(id)
    }
    function stopStream() {
        if (testingId !== "")
            Input.stopTest(testingId)
        testingId = ""
    }
    function restart() {
        if (!gone && testingId !== "" && Input.route === "shell")
            Input.startTest(testingId)
    }

    Connections {
        target: Input
        function onTestInput(deviceId, input, value, source) {
            if (deviceId !== page.testingId || page.gone)
                return
            const v = Math.max(-1, Math.min(1, value / 32767))
            if (input === page.side + "_x")
                page.stickX = v
            else if (input === page.side + "_y")
                page.stickY = v
        }
        function onTestEnded(deviceId, reason) {
            // The service ended it (idle, a route change that is over): start it again.
            if (deviceId === page.testingId && reason !== "stopped" && reason !== "gone")
                Qt.callLater(page.restart)
        }
        function onRouteChanged() {
            if (Input.route === "shell")
                Qt.callLater(page.restart)
        }
        function onServiceOwnedChanged() {
            if (Input.serviceOwned)
                Qt.callLater(page.restart)
        }
    }

    // Saved: the stick's reset says so.
    Connections {
        target: GameControls
        function onSaved(tag) {
            if (tag === "resetStick:" + page.side)
                Notifications.show(page.side === "right" ? qsTr("Right stick reset") : qsTr("Left stick reset"), "success")
        }
    }

    // "0,74" in Turkish: two decimals, the language's decimal mark.
    function decimal(v) {
        return v.toFixed(2).replace(".", Qt.locale(DeviceSettings.language).decimalPoint)
    }

    // ---- the preview -------------------------------------------------------------------------------
    Rectangle {
        id: preview
        objectName: "stickPreview"
        width: 760 * page.u
        height: Math.min(684 * page.u, parent.height)
        radius: Theme.radiusL * page.u
        color: Theme.blurMax > 0 ? Theme.glass : Theme.glassOpaque
        GlassLayers {
            anchors.fill: parent
            u: page.u
            radius: preview.radius
            grain: false
        }

        Column {
            objectName: "stickPreviewLive"
            visible: page.pad !== null
            x: Theme.spaceXl * page.u
            y: Theme.spaceXl * page.u
            width: parent.width - 2 * Theme.spaceXl * page.u
            spacing: Theme.spaceM * page.u

            Row {
                spacing: Theme.spaceM * page.u
                Column {
                    spacing: Theme.spaceXs * page.u
                    Text {
                        text: qsTr("Position")
                        color: Theme.text
                        font.pixelSize: Theme.typeCaption * page.u
                        font.weight: Theme.weightDemiBold
                    }
                    StickPlot {
                        objectName: "plotPosition"
                        u: page.u
                        kind: "position"
                        settings: page.settings
                        stickX: page.stickX
                        stickY: page.stickY
                    }
                }
                Column {
                    spacing: Theme.spaceXs * page.u
                    Text {
                        text: qsTr("Response")
                        color: Theme.text
                        font.pixelSize: Theme.typeCaption * page.u
                        font.weight: Theme.weightDemiBold
                    }
                    StickPlot {
                        id: responsePlot
                        objectName: "plotResponse"
                        u: page.u
                        kind: "response"
                        settings: page.settings
                        stickX: page.stickX
                        stickY: page.stickY
                    }
                    Item {
                        width: responsePlot.width
                        height: axisLeft.height
                        Text {
                            id: axisLeft
                            text: qsTr("Stick →")
                            color: Theme.text
                            font.pixelSize: Theme.typeCaption * page.u
                        }
                        Text {
                            anchors.right: parent.right
                            text: qsTr("↑ Game sees")
                            color: Theme.text
                            font.pixelSize: Theme.typeCaption * page.u
                        }
                    }
                }
            }

            Text {
                objectName: "stickReadout"
                text: qsTr("In %1 · Out %2").arg(page.decimal(responsePlot.r)).arg(page.decimal(responsePlot.out))
                color: Theme.text
                font.pixelSize: Theme.typeBody * page.u
                font.features: { "tnum": 1 }
            }

            // The legend: what the ring, the dot and the band are (literal 20 u markers).
            Row {
                spacing: Theme.spaceL * page.u
                Repeater {
                    model: [{ key: "ring", text: qsTr("Stick") }, { key: "dot", text: qsTr("Game sees") },
                            { key: "zone", text: qsTr("Dead zone") }]
                    Row {
                        id: legendItem
                        required property var modelData
                        spacing: Theme.spaceXs * page.u
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 20 * page.u
                            height: width
                            radius: legendItem.modelData.key === "zone" ? 0 : width / 2
                            color: legendItem.modelData.key === "dot" ? Theme.primaryFill
                                   : legendItem.modelData.key === "zone" ? Theme.selectedFill : "transparent"
                            border.width: legendItem.modelData.key === "ring" ? 3 * page.u : 0
                            border.color: Theme.text
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: legendItem.modelData.text
                            color: Theme.text
                            font.pixelSize: Theme.typeCaption * page.u
                        }
                    }
                }
            }
        }

        // No controller: the rows still work.
        Column {
            objectName: "stickPreviewEmpty"
            visible: page.pad === null
            anchors.centerIn: parent
            spacing: Theme.spaceM * page.u
            Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                u: page.u
                size: Theme.iconL
                name: "sports_esports"
            }
            Text {
                objectName: "stickPreviewEmptyText"
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(implicitWidth, 520 * page.u)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: qsTr("Connect a controller to see the stick move.")
                color: Theme.text
                font.pixelSize: Theme.typeBody * page.u
            }
        }
    }

    // ---- the settings ------------------------------------------------------------------------------
    SettingsPane {
        id: body
        objectName: "stickBody"
        anchors { left: parent.left; leftMargin: (760 + Theme.spaceXxl) * page.u; right: parent.right; top: parent.top; bottom: parent.bottom }
        u: page.u
        focus: true
        onExitRequested: page.backRequested()

        // "slider" | "choice" | "toggle" | "action"
        property string focusedKind: "slider"
        readonly property var back: ({ button: "B", text: qsTr("Back") })
        hints: focusedKind === "slider" ? [{ button: "Left/Right", text: qsTr("Adjust") }, back]
               : focusedKind === "choice" ? [{ button: "Left/Right", text: qsTr("Change") }, { button: "A", text: qsTr("Next") }, back]
               : focusedKind === "toggle" ? [{ button: "A", text: qsTr("Toggle") }, back]
               : [{ button: "A", text: qsTr("Select") }, back]

        SliderRow {
            id: innerRow
            objectName: "rowInner"
            u: page.u
            label: qsTr("Inner dead zone")
            from: 0
            to: 30
            stepSize: 1
            unit: "%"
            onActiveFocusChanged: if (activeFocus) body.focusedKind = "slider"
            onEdited: v => GameControls.setStick(page.side, "inner_deadzone", v / 100, true)
        }
        Binding { target: innerRow; property: "value"; value: Math.round(page.settings.inner_deadzone * 100) }

        SliderRow {
            id: outerRow
            objectName: "rowOuter"
            u: page.u
            label: qsTr("Outer dead zone")
            from: 0
            to: 20
            stepSize: 1
            unit: "%"
            onActiveFocusChanged: if (activeFocus) body.focusedKind = "slider"
            onEdited: v => GameControls.setStick(page.side, "outer_deadzone", v / 100, true)
        }
        Binding { target: outerRow; property: "value"; value: Math.round(page.settings.outer_deadzone * 100) }

        SliderRow {
            id: antiRow
            objectName: "rowAnti"
            u: page.u
            label: qsTr("Anti dead zone")
            from: 0
            to: 30
            stepSize: 1
            unit: "%"
            onActiveFocusChanged: if (activeFocus) body.focusedKind = "slider"
            onEdited: v => GameControls.setStick(page.side, "anti_deadzone", v / 100, true)
        }
        Binding { target: antiRow; property: "value"; value: Math.round(page.settings.anti_deadzone * 100) }

        ChoiceRow {
            id: curveRow
            objectName: "rowCurve"
            u: page.u
            label: qsTr("Response curve")
            options: [{ value: "linear", label: qsTr("Linear") }, { value: "precise", label: qsTr("Precise") },
                      { value: "aggressive", label: qsTr("Aggressive") }]
            onActiveFocusChanged: if (activeFocus) body.focusedKind = "choice"
            onEdited: v => GameControls.setStick(page.side, "curve", v, false)
            Keys.onReturnPressed: step(1)
            Keys.onEnterPressed: step(1)
        }
        Binding { target: curveRow; property: "value"; value: page.settings.curve }

        SliderRow {
            id: sensitivityRow
            objectName: "rowSensitivity"
            u: page.u
            label: qsTr("Sensitivity")
            from: 50
            to: 150
            stepSize: 5
            unit: "%"
            onActiveFocusChanged: if (activeFocus) body.focusedKind = "slider"
            onEdited: v => GameControls.setStick(page.side, "sensitivity", v / 100, true)
        }
        Binding { target: sensitivityRow; property: "value"; value: Math.round(page.settings.sensitivity * 100) }

        ToggleRow {
            id: invertRow
            objectName: "rowInvert"
            u: page.u
            label: qsTr("Invert up and down")
            onActiveFocusChanged: if (activeFocus) body.focusedKind = "toggle"
            onToggled: on => GameControls.setStick(page.side, "invert_y", on, false)
        }
        Binding { target: invertRow; property: "checked"; value: page.settings.invert_y === true }

        SettingRow {
            objectName: "rowResetStick"
            u: page.u
            label: qsTr("Reset this stick")
            onActiveFocusChanged: if (activeFocus) body.focusedKind = "action"
            onActivated: GameControls.resetStick(page.side)
        }
    }
}
