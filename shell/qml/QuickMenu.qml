pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The quick menu (04 §5, 02-shell §1.4/§1.5, T-147): what Guide opens. A 640 px panel on the left
// over a scrim, over the live app, the open page or Home.
//   Over an app: the app's art, title and running time, then Resume (focus first), Home, Close game,
//   Switch to <other running app> ..., Volume, Switch profile, Power.
//   Without an app: the same panel without the app part, plus Close (Resume's job when there is no app).
// Holding Guide (or choosing Power) swaps the list for the power choices (Suspend, Restart, Power off
// as logind allows, Back); a choice asks the shell to open its confirmation (`powerRequested`).
// Modal: every key is taken here. Up/Down move, Left/Right change the volume on its row, Accept acts,
// Back or Guide closes (Back leaves the power choices first). The list model holds keys only; the text
// is a binding in the delegate (translations rule). The fill is `glassOpaque` on every tier until the
// blurred glass of the quick menu is built (B-003, 04 §3.6).
Item {
    id: menu

    property real u: 1
    property real marginX: 0
    property real marginY: 0
    property string version: ""
    property bool open: false
    // The power choices instead of the actions.
    property bool powerMode: false

    // The app in front, or null: { appId, title, picture, started } (started: unix seconds).
    property var app: null
    // Other running apps with a window: [{ appId, title }].
    property var others: []
    // Keys the shell keeps for itself (Guide): a function key -> bool.
    property var guideKey: function (key) { return false }

    readonly property bool hasApp: app !== null
    readonly property alias actions: actions
    readonly property alias panel: panel

    signal closeRequested()           // Back, Guide, Resume or Close
    signal homeRequested()
    signal closeGameRequested()
    signal switchToRequested(string appId)
    signal switchProfileRequested()
    signal powerRequested(string action)

    // The keys of the list now (see rebuild()).
    property var itemKeys: []
    function keysNow() {
        if (powerMode) {
            return [...(Power.canSuspend ? ["suspend"] : []),
                    ...(Power.canRestart ? ["restart"] : []),
                    ...(Power.canPowerOff ? ["poweroff"] : []),
                    "back"]
        }
        const keys = []
        if (hasApp) {
            keys.push("resume", "home", "closeGame")
            for (const o of others)
                keys.push("to:" + o.appId)
        }
        keys.push("volume", "switch", "power")
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
    onPowerModeChanged: rebuild()

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
        }
        if (key.startsWith("to:")) {
            const found = others.find(o => o.appId === key.substring(3))
            return qsTr("Switch to %1").arg(Notifications.named(found ? found.title : key.substring(3)))
        }
        return key
    }

    // Opens the menu on its first row: Resume over an app, else Switch profile (the volume row is an
    // adjustment, not an action). Called by the shell after it has noted where the focus was.
    function present() {
        powerMode = false
        itemKeys = []
        rebuild()
        actions.currentIndex = Math.max(0, itemKeys.indexOf(hasApp ? "resume" : "switch"))
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
        } else if (key === "volume") {
            Audio.toggleMute()
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
            y: (menu.height - height) / 2
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

                // The app part: art, title, running time.
                Row {
                    id: header
                    objectName: "quickMenuApp"
                    visible: menu.hasApp
                    spacing: Theme.spaceM * menu.u
                    height: visible ? art.height : 0
                    AppArt {
                        id: art
                        objectName: "quickMenuArt"
                        u: menu.u
                        width: 200 * menu.u
                        height: Theme.cardArtHeight(width)
                        appId: menu.app ? menu.app.appId : ""
                        appName: menu.app ? menu.app.title : ""
                        picture: menu.app ? menu.app.picture : ""
                        shimmer: false
                    }
                    Column {
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
                    }
                }

                // Without an app: the system card's heading.
                Column {
                    id: systemHeader
                    objectName: "quickMenuSystem"
                    visible: !menu.hasApp
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

                ListView {
                    id: actions
                    objectName: "systemActions"
                    Accessible.role: Accessible.List
                    Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("System")

                    width: parent.width
                    height: Math.min(contentHeight, menu.height - 2 * menu.marginY - 2 * panel.pad
                                     - (header.visible ? header.height : systemHeader.height) - Theme.spaceM * menu.u)
                    spacing: Theme.spaceS * menu.u
                    interactive: false
                    keyNavigationEnabled: true
                    clip: true
                    model: menu.itemKeys

                    onCurrentIndexChanged: if (menu.open) Sfx.navigate()
                    Keys.onReturnPressed: menu.activate(menu.itemKeys[currentIndex])
                    Keys.onEnterPressed: menu.activate(menu.itemKeys[currentIndex])
                    Keys.onPressed: event => {
                        // Accepting every key (below) also skips the list's own key navigation, so
                        // Up/Down are handled here.
                        const key = menu.itemKeys[currentIndex]
                        if (event.key === Qt.Key_Down) {
                            incrementCurrentIndex()
                        } else if (event.key === Qt.Key_Up) {
                            decrementCurrentIndex()
                        } else if (key === "volume" && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
                            const toRight = event.key === (actions.LayoutMirroring.enabled ? Qt.Key_Left : Qt.Key_Right)
                            Audio.stepVolume(toRight ? 5 : -5)
                        } else if (event.isAutoRepeat) {
                            // Holding Guide repeats the key: not a second press that would close us.
                        } else if (menu.powerMode && BackKey.isBackOrBackspace(event.key)) {
                            Sfx.back()
                            menu.activate("back")
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
                        readonly property string label: menu.labelOf(modelData)

                        objectName: "quickMenuItem_" + modelData
                        Accessible.role: Accessible.MenuItem
                        Accessible.name: isVolume ? (Audio.muted ? qsTr("Volume, muted") : qsTr("Volume %1").arg(Audio.volume)) : label
                        width: actions.width
                        height: Theme.buttonHeight * menu.u
                        radius: height / 2
                        color: focused ? Theme.focusFill : Theme.glass
                        border.width: focused ? Theme.focusRingWidth * menu.u : 1
                        border.color: focused ? Theme.focusRing : Theme.glassBorder

                        Text {
                            id: itemLabel
                            x: action.isVolume ? Theme.spaceL * menu.u : (action.width - width) / 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, action.width - 2 * Theme.spaceL * menu.u)
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
                    }
                }
            }
        }
    }
}
