pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The quick menu, the Quick Hub (04 §5, 02-shell §1.4/§1.5/§1.6, T-147, T-448): what Guide opens. A
// 640 px panel on the left over a scrim, over the live app, the open page or Home.
//   A status row first (clock, network, device batteries; not focusable), then
//   over an app: the app's art, title and running time, then Resume (focus first), Home, Close game,
//   Switch to <other running app> ...; then the recent games that are not running (Accept starts one
//   and the Hub closes), Volume, the quick tiles (Wi-Fi, Bluetooth, Mute: Left/Right inside the row,
//   Accept flips what the backend says, the tile shows the backend's answer), Power, Switch profile.
//   Without an app: the same panel without the app part, plus Close (Resume's job when there is no app).
// Holding Guide (or choosing Power) swaps the list for the power choices (Suspend, Restart, Power off
// as logind allows, Back); a choice asks the shell to open its confirmation (`powerRequested`).
// Modal: every key is taken here. Up/Down move, Left/Right change the volume on its row or move
// along the tiles, Accept acts, Back or Guide closes (Back leaves the power choices first). The list
// model holds keys only; the text is a binding in the delegate (translations rule). The fill is
// `glassOpaque` on every tier until the blurred glass of the quick menu is built (B-003, 04 §3.6).
Item {
    id: menu

    property real u: 1
    property real marginX: 0
    property real marginY: 0
    // Room kept free at the bottom for the hint bar (the shell sets it, T-448): the panel never reaches it.
    property real bottomReserve: 0
    property string version: ""
    property bool open: false
    // The power choices instead of the actions.
    property bool powerMode: false
    // The panel shown in place of the Quick Hub's content ("" = the Quick Hub itself; T-450, 02 §1.6).
    // To add a panel: list it in `panelIds` (when it exists), give it keys in `panelKeys`, a title in
    // `panelTitle`, its entry label in `labelOf` ("panel:<id>") and its rows in `labelOf`, `rowValue`,
    // `rowChoices`, `rowStep`, `rowActivate`. Rows are keys "<id>:<row>" (the shared "volume" row may also
    // sit in a panel); nothing else in this file changes.
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
    // frozen: Session1 froze it, T-457, so the header says "Paused").
    property var app: null
    // Other running apps with a window: [{ appId, title }].
    property var others: []
    // Recent games that can be started and are not running, newest first, at most four (two over an app):
    // [{ id, title, picture }] (the shell filters them, T-448).
    property var recent: []
    // Keys the shell keeps for itself (Guide): a function key -> bool.
    property var guideKey: function (key) { return false }

    readonly property bool hasApp: app !== null
    readonly property alias actions: actions
    readonly property alias panel: panel

    signal closeRequested()           // Back, Guide, Resume or Close
    signal homeRequested()
    signal closeGameRequested()
    signal switchToRequested(string appId)
    signal launchRequested(string id) // a Recent row: the shell starts it (and the Hub closes)
    signal switchProfileRequested()
    signal powerRequested(string action)

    // The quick tiles whose backend exists, in order, and the lines of three they wrap into. A tile
    // whose backend is missing or "unsupported" is absent, never greyed (02 §1.6).
    readonly property var tileIds: ["wifi", "bluetooth", "mute", "mic"].filter(id => (id !== "wifi" || Network.wifi !== "unsupported")
                                                                              && (id !== "mic" || Audio.inputs.length > 0))
    readonly property int tilesPerLine: 3
    readonly property int tileLineCount: Math.ceil(tileIds.length / tilesPerLine)
    function tileLine(line) { return tileIds.slice(line * tilesPerLine, (line + 1) * tilesPerLine) }
    // The tile Left/Right stand on in the tiles row (kept across lines, clamped to the line's length).
    property int tileCol: 0
    function tileColIn(line) { return Math.max(0, Math.min(tileCol, tileLine(line).length - 1)) }
    function tileLabel(id) {
        switch (id) {
        case "wifi": return qsTr("Wi-Fi")
        case "bluetooth": return qsTr("Bluetooth")
        case "mute": return qsTr("Mute")
        case "mic": return qsTr("Mute mic")
        }
        return id
    }
    function tileOn(id) {
        switch (id) {
        case "wifi": return Network.wifi === "on"
        case "bluetooth": return Bluetooth.powered
        case "mute": return Audio.muted
        case "mic": return Audio.inputMuted
        }
        return false
    }
    // The Wi-Fi tile's second line: the joined network, else the words.
    function tileDetail(id) {
        switch (id) {
        case "wifi": {
            if (Network.wifi !== "on")
                return qsTr("Off")
            const joined = Network.networks.find(n => n.active)
            return joined ? joined.ssid : qsTr("Not connected")
        }
        case "bluetooth": return Bluetooth.powered ? qsTr("On") : qsTr("Off")
        case "mute": return Audio.muted ? qsTr("Muted") : qsTr("Off")
        case "mic": return Audio.inputMuted ? qsTr("Muted") : qsTr("Off")
        }
        return ""
    }
    // A tile asks its backend to flip; the tile changes only with the answer.
    function toggleTile(id) {
        if (id === "wifi")
            Network.setWifiEnabled(Network.wifi !== "on")
        else if (id === "bluetooth")
            Bluetooth.setPowered(!Bluetooth.powered)
        else if (id === "mute")
            Audio.toggleMute()
        else if (id === "mic")
            Audio.toggleInputMute()
    }
    Connections {
        target: Network
        function onWifiFinished(status) {
            if (menu.open && status !== "ok")
                Notifications.show(qsTr("Could not change Wi-Fi."), "warning")
        }
    }
    Connections {
        target: Audio
        function onInputsChanged() { menu.rebuild() }           // a microphone came or went: the tile and the panel's rows
        function onSetOutputFinished(id, status) {
            if (menu.open && menu.panelId === "audio" && status !== "ok")
                Notifications.show(qsTr("Could not switch the audio output."), "warning")
        }
        function onSetInputFinished(id, status) {
            if (menu.open && menu.panelId === "audio" && status !== "ok")
                Notifications.show(qsTr("Could not switch the microphone."), "warning")
        }
    }
    Connections {
        target: Bluetooth
        function onFinished(op, id, status) {
            if (menu.open && op === "power" && status !== "ok")
                Notifications.show(qsTr("Could not change Bluetooth."), "warning")
        }
    }

    // The status row's content: at most two battery chips (lowest first, as the service sorts them)
    // and a "+N" for the rest.
    readonly property var chipIds: Batteries.chips.slice(0, 2).map(d => d.id)
    readonly property int chipOverflow: Batteries.chips.length + Batteries.more.length - chipIds.length

    // The keys of the list now (see rebuild()).
    property var itemKeys: []
    // The row that has the focus ("" while the list is empty): the shell words the A hint after it.
    readonly property string currentKey: itemKeys[actions.currentIndex] ?? ""
    function keysNow() {
        if (powerMode) {
            return [...(Power.canSuspend ? ["suspend"] : []),
                    ...(Power.canRestart ? ["restart"] : []),
                    ...(Power.canPowerOff ? ["poweroff"] : []),
                    "back"]
        }
        if (panelId !== "")
            return panelKeys(panelId)
        const keys = []
        if (hasApp) {
            keys.push("resume", "home", "closeGame")
            for (const o of others)
                keys.push("to:" + o.appId)
        }
        for (const r of recent)
            keys.push("recent:" + r.id)
        keys.push("volume")
        for (let line = 0; line < tileLineCount; ++line)
            keys.push("tiles:" + line)
        for (const id of panelIds)
            keys.push("panel:" + id)
        keys.push("power", "switch")
        if (!hasApp)
            keys.push("close")
        return keys
    }
    // Assigning a new array resets the list's current index, so the keys are replaced only when they
    // changed (an app that exits while the menu is open) and the current key is found again.
    function rebuild() {
        const next = keysNow()
        if (JSON.stringify(next) === JSON.stringify(itemKeys))
            return
        const current = actions.currentIndex >= 0 && actions.currentIndex < itemKeys.length ? itemKeys[actions.currentIndex] : ""
        itemKeys = next
        const at = next.indexOf(current)
        actions.currentIndex = at >= 0 ? at : Math.min(Math.max(0, actions.currentIndex), next.length - 1)
    }
    onHasAppChanged: rebuild()
    onOthersChanged: rebuild()
    onRecentChanged: rebuild()
    onTileIdsChanged: rebuild()
    onPowerModeChanged: rebuild()
    onPanelIdChanged: rebuild()

    // ---- panels (T-450): a panel replaces the Quick Hub's rows in this same list ---------------------------
    // The panels that exist, in the order of their entries (02 §1.6); an entry appears only when its panel is built.
    readonly property var panelIds: ["audio"]
    function panelKeys(id) {
        if (id === "audio") {
            return ["volume", "audio:mute", "audio:output",
                    ...(Audio.inputs.length > 0 ? ["audio:mic", "audio:micmute"] : [])]
        }
        return []
    }
    function panelTitle(id) {
        return id === "audio" ? qsTr("Audio") : ""
    }
    function isPanelRow(key) { return panelId !== "" && key.startsWith(panelId + ":") }
    // The usable choices of a choice row: [{ id, name, current }], in the service's order (an output whose
    // route says "no" is not offered). A row with fewer than two has nothing to step through.
    function rowChoices(key) {
        if (key === "audio:output")
            return Audio.outputs.filter(o => o.available !== "no").map(o => ({ id: o.id, name: o.name, current: o.isDefault }))
        if (key === "audio:mic")
            return Audio.inputs.map(i => ({ id: i.id, name: i.name, current: i.isDefault }))
        return []
    }
    function isChoiceRow(key) { return key === "audio:output" || key === "audio:mic" }
    // The text at the right of a panel row.
    function rowValue(key) {
        if (key === "audio:mute")
            return Audio.muted ? qsTr("On") : qsTr("Off")
        if (key === "audio:micmute")
            return Audio.inputMuted ? qsTr("On") : qsTr("Off")
        if (isChoiceRow(key)) {
            const all = key === "audio:output" ? Audio.outputs : Audio.inputs
            const now = all.find(o => o.isDefault)
            return now ? now.name : ""
        }
        return ""
    }
    // Left/Right on a choice row: the next or previous choice is asked to become the default; the row
    // changes with the service's answer, not before.
    function rowStep(key, delta) {
        const options = rowChoices(key)
        if (options.length < 2)
            return
        const at = options.findIndex(o => o.current)
        const next = options[at < 0 ? 0 : (at + delta + options.length) % options.length]
        Sfx.navigate()
        if (key === "audio:output")
            Audio.setOutput(next.id)
        else
            Audio.setInput(next.id)
    }
    function rowActivate(key) {
        if (key === "audio:mute")
            Audio.toggleMute()
        else if (key === "audio:micmute")
            Audio.toggleInputMute()
        else if (isChoiceRow(key))
            rowStep(key, 1)
    }
    function openPanel(id) {
        panelId = id
        actions.currentIndex = 0               // the panel's first actionable row
        actions.positionViewAtBeginning()
        swapAnimation.restart()
    }
    // Back in a panel: the Quick Hub again, with the focus on the entry that was opened.
    function closePanel() {
        const entry = "panel:" + panelId
        panelId = ""
        actions.currentIndex = Math.max(0, itemKeys.indexOf(entry))
        swapAnimation.restart()
    }
    // What the buttons do on the focused row: the hint bar's list (02 §1.6). Left/Right is named where it works.
    readonly property var hints: {
        const key = currentKey
        const back = { button: "B", text: powerMode || panelId !== "" ? qsTr("Back") : (hasApp ? qsTr("Resume") : qsTr("Close")) }
        if (powerMode)
            return [{ button: "A", text: qsTr("Select") }, back]
        if (key === "volume")
            return [{ button: "A", text: qsTr("Mute") }, { button: "Left/Right", text: qsTr("Adjust") }, back]
        if (isChoiceRow(key)) {
            return rowChoices(key).length < 2 ? [back]
                   : [{ button: "A", text: qsTr("Next") }, { button: "Left/Right", text: qsTr("Change") }, back]
        }
        if (key === "audio:mute" || key === "audio:micmute" || key.startsWith("tiles:"))
            return [{ button: "A", text: qsTr("Toggle") }, back]
        if (key.startsWith("recent:"))
            return [{ button: "A", text: qsTr("Start") }, back]
        return [{ button: "A", text: qsTr("Select") }, back]
    }

    function labelOf(key) {
        switch (key) {
        case "resume": return qsTr("Resume")
        case "home": return qsTr("Home")
        case "closeGame": return qsTr("Close game")
        case "volume": return qsTr("Volume")
        case "switch": return qsTr("Switch profile")
        case "power": return qsTr("Power")
        case "close": return qsTr("Close")
        case "suspend": return qsTr("Suspend")
        case "restart": return qsTr("Restart")
        case "poweroff": return qsTr("Power off")
        case "back": return qsTr("Back")
        case "panel:audio": return qsTr("Audio")
        case "audio:mute": return qsTr("Mute")
        case "audio:output": return qsTr("Output")
        case "audio:mic": return qsTr("Microphone")
        case "audio:micmute": return qsTr("Mute microphone")
        }
        if (key.startsWith("to:")) {
            const found = others.find(o => o.appId === key.substring(3))
            return qsTr("Switch to %1").arg(Notifications.named(found ? found.title : key.substring(3)))
        }
        if (key.startsWith("recent:")) {
            const game = recent.find(r => r.id === key.substring(7))
            return game ? game.title : key.substring(7)
        }
        return key
    }

    // Opens the menu on its first row: Resume over an app, else the first Recent row, else Switch
    // profile (the volume row is an adjustment, not an action). Nothing of an earlier visit is
    // remembered. Called by the shell after it has noted where the focus was.
    function present() {
        powerMode = false
        panelId = ""
        tileCol = 0
        itemKeys = []
        rebuild()
        const first = hasApp ? "resume" : (recent.length > 0 ? "recent:" + recent[0].id : "switch")
        actions.currentIndex = Math.max(0, itemKeys.indexOf(first))
        actions.positionViewAtBeginning()
        actions.forceActiveFocus()
    }

    function showPower() {
        powerMode = true
        actions.currentIndex = 0
        Sfx.navigate()
    }

    function activate(key) {
        Sfx.select()
        if (key === "resume" || key === "close") {
            menu.closeRequested()
        } else if (key === "home") {
            menu.homeRequested()
        } else if (key === "closeGame") {
            menu.closeGameRequested()
        } else if (key.startsWith("to:")) {
            menu.switchToRequested(key.substring(3))
        } else if (key.startsWith("recent:")) {
            menu.launchRequested(key.substring(7))
        } else if (key.startsWith("tiles:")) {
            const line = parseInt(key.substring(6))
            toggleTile(tileLine(line)[tileColIn(line)])
        } else if (key === "volume") {
            Audio.toggleMute()
        } else if (key.startsWith("panel:")) {
            openPanel(key.substring(6))
        } else if (isPanelRow(key)) {
            rowActivate(key)
        } else if (key === "switch") {
            menu.switchProfileRequested()
        } else if (key === "power") {
            showPower()
        } else if (key === "back") {
            powerMode = false
            actions.currentIndex = Math.max(0, itemKeys.indexOf("power"))
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
            x: menu.marginX
            y: menu.marginY + (menu.height - 2 * menu.marginY - menu.bottomReserve - height) / 2
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

                // The status row (T-448): the clock, the network and the device batteries. Never focusable.
                Item {
                    id: status
                    objectName: "hubStatus"
                    width: parent.width
                    height: Math.max(clock.implicitHeight, Theme.iconM * menu.u)
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("%1, %2").arg(clock.text).arg(networkText.text)

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
                                            - Theme.iconM * menu.u - 2 * Theme.spaceM * menu.u))
                            elide: Text.ElideRight
                            color: Theme.text
                            font.pixelSize: Theme.typeBody * menu.u
                        }
                    }
                }

                // The app part: art, title, running time and "Paused". As tall as the taller of the art and
                // the text (a two-line title over "Paused" is taller than the art, T-457).
                Row {
                    id: header
                    objectName: "quickMenuApp"
                    visible: menu.hasApp && menu.panelId === ""
                    spacing: Theme.spaceM * menu.u
                    height: visible ? Math.max(art.height, appInfo.height) : 0
                    AppArt {
                        id: art
                        objectName: "quickMenuArt"
                        anchors.verticalCenter: parent.verticalCenter
                        u: menu.u
                        width: 200 * menu.u
                        height: Theme.cardArtHeight(width)
                        appId: menu.app ? menu.app.appId : ""
                        appName: menu.app ? menu.app.title : ""
                        picture: menu.app ? menu.app.picture : ""
                        shimmer: false
                    }
                    Column {
                        id: appInfo
                        objectName: "quickMenuAppInfo"
                        anchors.verticalCenter: parent.verticalCenter
                        width: content.width - art.width - Theme.spaceM * menu.u
                        spacing: Theme.spaceXs * menu.u
                        Text {
                            objectName: "quickMenuTitle"
                            width: parent.width
                            textFormat: Text.PlainText
                            text: menu.app ? menu.app.title : ""
                            color: Theme.text
                            font.pixelSize: Theme.typeTitle * menu.u
                            font.weight: Theme.weightDemiBold
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        Text {
                            objectName: "quickMenuTime"
                            width: parent.width
                            textFormat: Text.PlainText
                            text: !menu.app ? ""
                                  : (menu.now - menu.app.started < 60 ? qsTr("Just started")
                                                                      : qsTr("Running for %1").arg(DurationText.plain(menu.now - menu.app.started)))
                            color: Theme.text
                            font.pixelSize: Theme.typeBody * menu.u
                            elide: Text.ElideRight
                        }
                        // The game is frozen while the Hub is open (T-457): only once the service
                        // says so, so a failed freeze never shows it.
                        Text {
                            objectName: "quickMenuPaused"
                            visible: menu.app !== null && (menu.app.frozen ?? false)
                            width: parent.width
                            textFormat: Text.PlainText
                            text: qsTr("Paused")
                            color: Theme.text
                            font.pixelSize: Theme.typeBody * menu.u
                            font.weight: Theme.weightDemiBold
                            elide: Text.ElideRight
                        }
                    }
                }

                // Without an app: the system card's heading.
                Column {
                    id: systemHeader
                    objectName: "quickMenuSystem"
                    visible: !menu.hasApp && menu.panelId === ""
                    width: parent.width
                    spacing: Theme.spaceXs * menu.u
                    height: visible ? implicitHeight : 0
                    Text {
                        width: parent.width
                        text: qsTr("System")
                        color: Theme.text
                        font.pixelSize: Theme.typeTitle * menu.u
                        font.weight: Theme.weightDemiBold
                    }
                    Text {
                        width: parent.width
                        text: qsTr("Image version %1").arg(menu.version)
                        color: Theme.text
                        font.pixelSize: Theme.typeBody * menu.u
                        elide: Text.ElideRight
                    }
                    FpsMeter { font.pixelSize: Theme.typeBody * menu.u; visible: menu.visible; color: Theme.text }
                }

                // A panel's title row (T-450): not focusable; it takes the place of the app part or the system heading.
                Item {
                    id: panelTitleText
                    visible: menu.panelId !== ""
                    width: parent.width
                    height: visible ? panelTitle.implicitHeight : 0
                    opacity: menu.swap
                    Text {
                        id: panelTitle
                        objectName: "hubPanelTitle"
                        width: parent.width
                        textFormat: Text.PlainText
                        text: menu.panelTitle(menu.panelId)
                        color: Theme.text
                        font.pixelSize: Theme.typeTitle * menu.u
                        font.weight: Theme.weightDemiBold
                    }
                }

                // The list and its scroll cues. What is left under the status row and the header or the panel's
                // title (two gaps of the column); a longer list scrolls so the current row stays in view and clear
                // of the fades, and a fade at the edge that hides rows says there are more.
                Item {
                    id: listBox
                    width: parent.width
                    height: Math.min(actions.contentHeight, menu.height - 2 * menu.marginY - menu.bottomReserve - 2 * panel.pad
                                     - status.height - header.height - systemHeader.height - panelTitleText.height - 2 * Theme.spaceM * menu.u)
                    // Changing from the Hub to a panel and back: the rows fade in and slide by `pageSlide`
                    // (both are 0 under reduced motion, so it is a cut).
                    opacity: menu.swap
                    transform: Translate { x: (1 - menu.swap) * Theme.pageSlide * menu.u }

                    ListView {
                        id: actions
                        objectName: "systemActions"
                        Accessible.role: Accessible.List
                        Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("System")

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
                        // The panel's height or the rows' heights change after the row was placed (the app header
                        // grows when "Paused" arrives): put the current row clear of the fades again.
                        onHeightChanged: reveal()
                        onContentHeightChanged: reveal()
                        onCurrentIndexChanged: {
                            reveal()
                            if (menu.open)
                                Sfx.navigate()
                        }
                        Keys.onReturnPressed: menu.activate(menu.itemKeys[currentIndex])
                        Keys.onEnterPressed: menu.activate(menu.itemKeys[currentIndex])
                        Keys.onPressed: event => {
                            // Accepting every key (below) also skips the list's own key navigation, so
                            // Up/Down are handled here.
                            const key = menu.itemKeys[currentIndex]
                            const sideways = event.key === Qt.Key_Left || event.key === Qt.Key_Right
                            const toRight = event.key === (actions.LayoutMirroring.enabled ? Qt.Key_Left : Qt.Key_Right)
                            if (event.key === Qt.Key_Down) {
                                incrementCurrentIndex()
                            } else if (event.key === Qt.Key_Up) {
                                decrementCurrentIndex()
                            } else if (key === "volume" && sideways) {
                                Audio.stepVolume(toRight ? 5 : -5)
                            } else if (menu.isChoiceRow(key) && sideways) {
                                menu.rowStep(key, toRight ? 1 : -1)
                            } else if (key && key.startsWith("tiles:") && sideways) {
                                const line = parseInt(key.substring(6))
                                const at = menu.tileColIn(line)
                                const next = Math.max(0, Math.min(menu.tileLine(line).length - 1, at + (toRight ? 1 : -1)))
                                if (next !== at) {
                                    menu.tileCol = next
                                    Sfx.navigate()
                                }
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
                            readonly property bool isRecent: modelData.startsWith("recent:")
                            readonly property bool isTiles: modelData.startsWith("tiles:")
                            readonly property bool isPanelRow: menu.isPanelRow(modelData)
                            readonly property bool isChoice: menu.isChoiceRow(modelData)
                            readonly property string rowText: isPanelRow ? menu.rowValue(modelData) : ""
                            readonly property int line: isTiles ? parseInt(modelData.substring(6)) : 0
                            readonly property string label: menu.labelOf(modelData)
                            readonly property var game: isRecent ? menu.recent.find(r => r.id === modelData.substring(7)) : undefined

                            objectName: "quickMenuItem_" + modelData
                            Accessible.role: Accessible.MenuItem
                            Accessible.name: isVolume ? (Audio.muted ? qsTr("Volume, muted") : qsTr("Volume %1").arg(Audio.volume))
                                             : isTiles ? tilesRow.focusedName
                                             : isPanelRow && rowText !== "" ? qsTr("%1, %2").arg(label).arg(rowText) : label
                            width: actions.width
                            height: isTiles ? tilesRow.height : Theme.buttonHeight * menu.u
                            radius: height / 2
                            color: isTiles ? "transparent" : (focused ? Theme.focusFill : Theme.glass)
                            border.width: isTiles ? 0 : (focused ? Theme.focusRingWidth * menu.u : 1)
                            border.color: focused ? Theme.focusRing : Theme.glassBorder

                            // A Recent row's picture (`iconL` square, `radiusS`).
                            AppArt {
                                id: thumb
                                objectName: "quickMenuThumb"
                                visible: action.isRecent
                                x: Theme.spaceS * menu.u
                                anchors.verticalCenter: parent.verticalCenter
                                u: menu.u
                                width: Theme.iconL * menu.u
                                height: width
                                radius: Theme.radiusS * menu.u
                                appId: action.game ? action.game.id : ""
                                appName: action.game ? action.game.title : ""
                                picture: action.game ? action.game.picture : ""
                                monogram: false
                                shimmer: false
                            }
                            Text {
                                id: itemLabel
                                visible: !action.isTiles
                                // Volume and Recent rows start at the left edge; the others are centred.
                                readonly property real leftEdge: action.isRecent ? thumb.x + thumb.width + Theme.spaceS * menu.u
                                                                                  : Theme.spaceL * menu.u
                                x: action.isVolume || action.isRecent || action.isPanelRow ? leftEdge : (action.width - width) / 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, action.width - leftEdge - Theme.spaceL * menu.u
                                                - (action.isPanelRow ? panelValue.width + Theme.spaceM * menu.u : 0))
                                textFormat: Text.PlainText
                                text: action.label
                                color: Theme.text
                                font.pixelSize: Theme.typeHeadline * menu.u
                                font.weight: Theme.weightDemiBold
                                elide: Text.ElideRight
                            }
                            // The volume row: a bar and the number (the same as the volume OSD).
                            Rectangle {
                                id: track
                                objectName: "quickMenuVolumeTrack"
                                visible: action.isVolume
                                anchors { left: itemLabel.right; leftMargin: Theme.spaceM * menu.u; right: valueText.left; rightMargin: Theme.spaceM * menu.u; verticalCenter: parent.verticalCenter }
                                height: 12 * menu.u
                                radius: height / 2
                                color: Theme.glass
                                Rectangle {
                                    width: parent.width * (Audio.muted ? 0 : Audio.volume) / 100
                                    height: parent.height
                                    radius: parent.radius
                                    color: Theme.text
                                }
                            }
                            Text {
                                id: valueText
                                objectName: "quickMenuVolumeValue"
                                visible: action.isVolume
                                anchors { right: parent.right; rightMargin: Theme.spaceL * menu.u; verticalCenter: parent.verticalCenter }
                                width: 70 * menu.u
                                horizontalAlignment: Text.AlignRight
                                text: Audio.muted ? qsTr("Muted") : String(Audio.volume)
                                color: Theme.text
                                font.pixelSize: Theme.typeBody * menu.u
                            }
                            // A panel row's value at the right ("On", the chosen output). A choice with a neighbour to
                            // step to has its arrows, as Settings' choice rows do; only the name is elided.
                            Row {
                                id: panelValue
                                objectName: "hubRowValue"
                                visible: action.isPanelRow
                                anchors { right: parent.right; rightMargin: Theme.spaceL * menu.u; verticalCenter: parent.verticalCenter }
                                spacing: Theme.spaceXs * menu.u
                                readonly property bool arrows: action.isChoice && menu.rowChoices(action.modelData).length > 1
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
                            // A line of quick tiles: three across the panel, `spaceS` apart.
                            Row {
                                id: tilesRow
                                objectName: "quickTiles_" + action.line
                                visible: action.isTiles
                                spacing: Theme.spaceS * menu.u
                                readonly property real tileWidth: (action.width - (menu.tilesPerLine - 1) * spacing) / menu.tilesPerLine
                                readonly property string focusedName: {
                                    const ids = action.isTiles ? menu.tileLine(action.line) : []
                                    const id = ids[menu.tileColIn(action.line)]
                                    return id ? (menu.tileOn(id) ? qsTr("%1, on").arg(menu.tileLabel(id)) : qsTr("%1, off").arg(menu.tileLabel(id))) : ""
                                }
                                Repeater {
                                    model: action.isTiles ? menu.tileLine(action.line) : []
                                    QuickTile {
                                        id: quickTile
                                        required property int index
                                        required property string modelData
                                        objectName: "quickTile_" + modelData
                                        u: menu.u
                                        width: tilesRow.tileWidth
                                        height: implicitHeight
                                        iconOn: modelData === "wifi" ? "wifi" : modelData === "bluetooth" ? "bluetooth"
                                                : modelData === "mic" ? "mic_off" : "volume_off"
                                        iconOff: modelData === "wifi" ? "wifi_off" : modelData === "bluetooth" ? "bluetooth_disabled"
                                                 : modelData === "mic" ? "mic" : "volume_up"
                                        label: menu.tileLabel(modelData)
                                        detail: menu.tileDetail(modelData)
                                        on: menu.tileOn(modelData)
                                        focused: action.focused && index === menu.tileColIn(action.line)
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        objectName: "hubMoreAbove"
                        readonly property bool needed: actions.contentY > 1
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
                        readonly property bool needed: actions.contentY + actions.height < actions.contentHeight - 1
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
