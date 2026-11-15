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
// Step "pick": the console's profiles (no guest-role ones) as cards; Accept on a free profile without a
// PIN opens step "confirm" (Join or Switch). A PIN profile or one that plays now (Move) does nothing
// until RUY-628. Until then, player 1's own profile while seat 1 has no pad (a keyboard sign-in, a hold
// that ran out: the seat gate leaves no other way back) joins the pad at once as player 1.
// Join: Input.joinPlayer(pad, id), closed on "ok". Switch: Profiles.lock(), switchTo(id, ""), then
// joinPlayer(pad, id) once the new profile's seats exist. A refused join is a toast and step 2 again.
// Not now keeps the pad quiet: over a game until that game exits, over Home until the pad disconnects
// or the profile changes.
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
    property string step: "pick"         // "pick" | "confirm"
    property string pad: ""              // the asking pad (stable id)
    property var queue: []               // pads waiting to ask, in arrival order
    // Not now (pad id -> { instance } over a game, { profile } over Home).
    property var quiet: ({})
    property var chosen: null            // the profile record of step "confirm"
    // A JoinPlayer on its way from here: { pad, id, from: "pick" | "confirm" | "switch" }.
    property var joining: null
    // A Switch between its Lock and the join: { pad, id, name, signedIn }.
    property var switching: null
    property var knownPads: []
    property bool padsPrimed: false
    // What had the focus when it opened (the Shell gives it back on close when it can still take it).
    property Item returnTo: null

    // `target`: the item that had the focus before (null when none).
    signal closed(Item target)

    readonly property var cards: Profiles.profiles.filter(p => p.role !== "guest")
    readonly property var padRecord: Input.devices.find(d => d.id === prompt.pad)
    readonly property string padName: padRecord
        ? Notifications.named(DeviceIcons.padName(padRecord.id, padRecord.name ?? "", padRecord.family ?? ""))
        : ""
    readonly property string padIcon: padRecord
        ? DeviceIcons.iconFor("controller", padRecord.family ?? "", padRecord.model ?? "") : "sports_esports"
    readonly property var player1: Input.players.find(s => s.slot === 1)
    readonly property string player1Name: player1 ? Profiles.nameOf(player1.profile) : ""

    // What the hint bar says (Shell.hintList).
    readonly property var modalHints: step === "pick"
        ? [{ action: "accept", text: qsTr("Select") }, { action: "back", text: qsTr("Not now") }]
        : [{ action: "accept", text: qsTr("Select") }, { action: "back", text: qsTr("Back") }]

    // "%1 ... %2" filled in one pass, so a name with "%2" in it stays a name.
    function fill(template, one, two) {
        return template.replace(/%([12])/g, (m, n) => n === "1" ? one : two)
    }

    function seatOf(profileId) {
        return Input.players.find(s => s.profile === profileId)
    }
    // Player 1's profile while seat 1 has no pad (not held): picking it gives seat 1 this pad.
    function padlessPlayer1(profileId) {
        const s = seatOf(profileId)
        return s !== undefined && s.slot === 1 && (s.device_id ?? "") === "" && s.held !== true
    }
    function hasPad(profileId) {
        const s = seatOf(profileId)
        return s !== undefined && !padlessPlayer1(profileId)
    }
    function detailFor(record) {
        if (!record)
            return ""
        if (padlessPlayer1(record.id))
            return qsTr("Picking it makes this controller player 1.")
        const s = seatOf(record.id)
        if (!s || (s.device_id ?? "") === "")
            return ""
        const d = Input.devices.find(x => x.id === s.device_id)
        const name = d ? DeviceIcons.padName(d.id, d.name ?? "", d.family ?? "") : qsTr("another controller")
        return fill(qsTr("Now on %2. Picking it moves %1 here."), record.name, Notifications.named(name))
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

    // A pad asks (reason "connect", "press" or "guide").
    function ask(id, reason) {
        if (!allowed || id === "")
            return
        if (reason === "press" && quiet[id] !== undefined)
            return
        if ((shown && pad === id) || queue.includes(id) || seated(id))
            return
        queue = queue.concat([id])
        Qt.callLater(prompt.tryOpen)
    }

    function tryOpen() {
        if (shown || !allowed || blocked || switching !== null)
            return
        while (queue.length > 0) {
            const id = queue[0]
            queue = queue.slice(1)
            if (connected(id) && !seated(id)) {
                open(id)
                return
            }
        }
    }

    function open(id) {
        const f = Window.activeFocusItem
        returnTo = f && !inside(f) ? f : null
        pad = id
        step = "pick"
        chosen = null
        joining = null
        downKey = 0
        shown = true
        Input.setNavigator(id)
        focusFirst()
    }

    // The first profile without a pad, else Not now (also when the profiles are not there).
    function focusFirst() {
        const i = Profiles.available ? cards.findIndex(p => !hasPad(p.id)) : -1
        if (i >= 0) {
            cardList.currentIndex = i
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
        shown = false
        step = "pick"
        chosen = null
        joining = null
        const was = pad
        pad = ""
        if (was !== "" && Input.navigator === was)
            Input.setNavigator("")
        const target = returnTo
        returnTo = null
        closed(target)
        Qt.callLater(prompt.tryOpen)
    }

    function notNow() {
        Sfx.back()
        close(true)
    }

    function acceptCard(index) {
        if (joining !== null || index < 0 || index >= cards.length)
            return
        const record = cards[index]
        if (padlessPlayer1(record.id)) {
            Sfx.select()
            join(record.id, "pick")
            return
        }
        // Move (a profile that plays now) and the PIN are RUY-628: nothing yet.
        if (seatOf(record.id) !== undefined || record.hasPin)
            return
        Sfx.select()
        chosen = record
        step = "confirm"
        joinButton.forceActiveFocus()
    }

    function join(id, from) {
        joining = { pad: pad, id: id, from: from }
        Input.joinPlayer(pad, id)
    }

    function switchTo() {
        if (!chosen || joining !== null)
            return
        switching = { pad: pad, id: chosen.id, name: chosen.name, signedIn: false }
        close(false)
        Profiles.lock()
        Profiles.switchTo(switching.id, "")
    }

    // The new profile is signed in and its seats exist: the pad becomes its player 1.
    function joinAfterSwitch() {
        if (!switching || !switching.signedIn || !player1 || player1.profile !== switching.id)
            return
        const s = switching
        switching = null
        joining = { pad: s.pad, id: s.id, from: "switch" }
        Input.joinPlayer(s.pad, s.id)
    }

    // The name is the caller's: a refused Switch may be about a profile that is gone.
    function refused(name) {
        Notifications.show(qsTr("%1 could not join").arg(Notifications.named(name)), "error", "", "",
                           qsTr("Try again."))
    }

    function backFromConfirm() {
        Sfx.back()
        const i = chosen ? cards.findIndex(p => p.id === chosen.id) : -1
        step = "pick"
        chosen = null
        if (i >= 0)
            cardList.currentIndex = i
        cardList.forceActiveFocus()
    }

    // Quiet pads and the queue follow the pads, the games and the profile.
    function devicesUpdated() {
        const ids = Input.devices.map(d => d.id)
        if (padsPrimed && allowed) {
            for (const d of Input.devices) {
                if (!knownPads.includes(d.id) && (d.slot ?? 0) === 0)
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
        if (shown && !ids.includes(pad))
            close(true)                 // the asking pad is gone: as Not now
    }

    onAllowedChanged: {
        if (!allowed) {
            queue = []
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
            if (kind === "press" || kind === "guide")
                prompt.ask(deviceId, kind)
        }
        function onPlayersChanged() { prompt.joinAfterSwitch() }
        function onJoinFinished(deviceId, profile, status, slot) {
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
            else
                cardList.forceActiveFocus()
        }
    }
    Connections {
        target: Profiles
        function onActiveProfileChanged() {
            const next = {}
            for (const k in prompt.quiet) {
                if (prompt.quiet[k].instance !== "")
                    next[k] = prompt.quiet[k]
            }
            prompt.quiet = next
            if (prompt.switching && Profiles.activeProfile === prompt.switching.id)
                prompt.switching = Object.assign({}, prompt.switching, { signedIn: true })
            prompt.joinAfterSwitch()
        }
        function onSwitchFinished(id, status) {
            const s = prompt.switching
            if (!s || s.id !== id || status === "ok")
                return
            prompt.switching = null      // the picker stays up
            prompt.refused(s.name)
        }
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
    readonly property string padLineText: qsTr("%1 wants to play").arg(padName)

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
                model: prompt.cards

                delegate: ProfileCard {
                    u: prompt.u
                    playerSlot: {
                        const s = prompt.seatOf(modelData.id)
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
                        Sfx.navigate()
                        notNowButton.forceActiveFocus()
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
            text: cardList.activeFocus && Profiles.available ? prompt.detailFor(prompt.cards[cardList.currentIndex]) : ""
            color: Theme.text
            font.pixelSize: Theme.typeBody * prompt.u
        }
        Item { width: 1; height: Theme.spaceL * prompt.u }
        SecondaryButton {
            id: notNowButton
            objectName: "whosPlayingNotNow"
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

    // ---- step "confirm": Join or Switch (the Dialog card of PowerConfirm) ------------------------
    Rectangle {
        objectName: "whosPlayingConfirmPanel"
        anchors.centerIn: parent
        visible: prompt.step === "confirm"
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
                text: qsTr("Join in or switch to %1?").arg(prompt.chosen ? Notifications.named(prompt.chosen.name) : "")
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
                text: prompt.fill(qsTr("Join: %1 plays alongside %2. Switch: %1 becomes player 1, and %2's games are paused and kept."),
                                  prompt.chosen ? Notifications.named(prompt.chosen.name) : "",
                                  Notifications.named(prompt.player1Name))
                color: Theme.textDim
                font.pixelSize: Theme.typeBody * prompt.u
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
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
        }
    }

    // Accept on what has the focus (on the key's release, below).
    function activate() {
        if (cardList.activeFocus) {
            acceptCard(cardList.currentIndex)
        } else if (notNowButton.activeFocus) {
            Sfx.select()
            close(true)
        } else if (joinButton.activeFocus) {
            if (chosen && joining === null) {
                Sfx.select()
                join(chosen.id, "confirm")
            }
        } else if (switchButton.activeFocus) {
            Sfx.select()
            switchTo()
        }
    }

    // The key whose press the prompt saw, so that its release acts (0 for none).
    property int downKey: 0

    // Modal: every key is taken, its release too. Accept, Back and Guide act on the release, so the
    // release of the key that closes the prompt never reaches the game it gives the focus back to, and
    // a release whose press came before the prompt opened does nothing. Back is Not now on step 1 and
    // back to the card on step 2; Guide closes like Not now (as it closes the Hub).
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
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            activate()
        } else if (BackKey.isBackOrBackspace(event.key)) {
            if (step === "confirm")
                backFromConfirm()
            else
                notNow()
        } else if (event.key === Qt.Key_HomePage) {
            notNow()
        }
    }
}
