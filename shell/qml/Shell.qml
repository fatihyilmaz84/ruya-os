pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import RuyaShell

// The whole console UI as one Item, so tests can host it in their own window.
// Flow: profile picker -> home shelf; Guide/Menu opens the system overlay from home.
FocusScope {
    id: root

    required property string version

    readonly property real u: height / 1080
    readonly property real marginX: width * Theme.safeArea
    readonly property real marginY: height * Theme.safeArea
    readonly property bool signedIn: Profiles.activeProfile !== ""
    readonly property Tile currentTile: tiles.currentItem as Tile

    // Open pages, oldest first, as {key, params}; only the last one is shown. Every entry
    // keeps its own live page item (in `slots`), so a page below keeps its state.
    // Reassign, never mutate (QML change notification).
    property var pageStack: []
    readonly property string currentPage: pageStack.length > 0 ? pageStack[pageStack.length - 1].key : ""
    readonly property var currentParams: pageStack.length > 0 ? pageStack[pageStack.length - 1].params : ({})
    readonly property bool pageOpen: currentPage !== ""
    // Pages a test or a later module registers without editing this file: key -> Component.
    property var extraPages: ({})
    // Slot items of the live stack entries (same order as pageStack), and how many slot
    // items exist including those still fading out after a pop.
    property var slots: []
    property int slotCount: 0

    function openPage(key, params) {
        const component = pageComponents[key]
        if (!signedIn || !component || systemPanel.open)
            return
        const below = slots.length > 0 ? slots[slots.length - 1] : null
        if (below)
            below.rememberFocus()
        const entry = { key: key, params: params ?? ({}) }
        const slot = pageSlot.createObject(pageHost, { key: key })
        if (!slot) {
            console.warn("ruya-shell: could not create the slot for page", key)
            return
        }
        const page = component.createObject(slot, {
            objectName: "page_" + key,
            params: entry.params,
            overlay: modalLayer
        }) as Page
        if (!page) {
            console.warn("ruya-shell: could not create page", key)
            slot.destroy()
            return
        }
        page.u = Qt.binding(() => root.u)
        page.version = Qt.binding(() => root.version)
        page.marginX = Qt.binding(() => root.marginX)
        page.marginY = Qt.binding(() => root.marginY)
        page.anchors.fill = slot
        page.backRequested.connect(root.closePage)
        slot.page = page
        slotCount += 1
        if (below)
            below.shown = false
        slots = slots.concat([slot])
        pageStack = pageStack.concat([entry])
        slot.shown = true
        focusCurrent()
    }

    function closePage() {
        if (!pageOpen)
            return
        const gone = slots[slots.length - 1]
        slots = slots.slice(0, -1)
        pageStack = pageStack.slice(0, -1)
        gone.closing = true          // destroyed once its fade-out has ended
        gone.shown = false
        if (slots.length > 0)
            slots[slots.length - 1].shown = true
        focusCurrent()
    }

    function dropAllPages() {
        const all = Array.from(pageHost.children)
        slots = []
        pageStack = []
        slotCount = 0
        for (const s of all)
            s.destroy()
    }

    function tileTitle(key) {
        switch (key) {
        case "games": return qsTr("Games")
        case "media": return qsTr("Media")
        case "store": return qsTr("Store")
        case "settings": return qsTr("Settings")
        case "power": return qsTr("Power")
        }
        return key
    }

    // Gives focus to whatever is on top: the open page, else the home tiles.
    function focusCurrent() {
        if (!signedIn)
            return
        if (pageOpen)
            slots[slots.length - 1].restoreFocus()
        else
            tiles.forceActiveFocus()
    }

    // First boot: no profile exists, so the setup wizard replaces the picker. It stays up
    // until its Done step (setupActive), even though the list is no longer empty by then.
    readonly property bool setupNeeded: Profiles.available && Profiles.profiles.length === 0
    property bool setupActive: false

    // The single place that decides where focus goes after a state change.
    function routeFocus() {
        systemPanel.open = false
        if (setupActive) {
            setup.focusStep()
        } else if (signedIn) {
            focusCurrent()
        } else {
            picker.reset()
        }
    }

    onSetupNeededChanged: {
        if (setupNeeded && !setupActive) {
            setupActive = true
            setup.start()
        } else if (!setupNeeded && setupActive && !setup.committed) {
            setupActive = false      // a profile appeared some other way: nothing left to set up
        }
        routeFocus()
    }
    onSignedInChanged: {
        if (!signedIn)
            dropAllPages()       // the next sign-in starts at home
        routeFocus()
    }
    Component.onCompleted: {
        Power.refresh()          // creates the singleton early, so the rows know what is allowed
        if (setupNeeded) {
            setupActive = true
            setup.start()
        }
        routeFocus()
    }

    // The Guide button opens the overlay from home or from any page; pages and tiles leave
    // it unhandled. (The overlay itself and the PIN pad are modal and accept every key.)
    //
    // Holding Guide for Theme.guideHoldMs switches the open overlay to the power choices
    // (spec 01 §2.2). A short press still opens the overlay at once; the hold is timed from
    // that press and cancelled by the release. Autorepeat events are ignored: they are the
    // same physical press.
    property bool guideHeld: false

    // The controller's Guide button arrives as HomePage (ruya-inputd); on a keyboard it is
    // Super, left or right (Qt reports the Windows key as Meta on the Windows host). Menu is
    // the context-menu key (spec 02 4.2), not Guide.
    function isGuideKey(key) {
        return key === Qt.Key_HomePage || key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_Meta
    }

    Keys.onPressed: event => {
        if (signedIn && !systemPanel.open && isGuideKey(event.key)) {
            if (!event.isAutoRepeat) {
                systemPanel.open = true
                Sfx.select()
                guideHeld = true
                guideHoldTimer.restart()
            }
            event.accepted = true
        }
    }
    Keys.onReleased: event => {
        if (isGuideKey(event.key) && !event.isAutoRepeat) {
            guideHeld = false
            guideHoldTimer.stop()
        }
    }
    Timer {
        id: guideHoldTimer
        interval: Theme.guideHoldMs
        onTriggered: {
            if (root.guideHeld && systemPanel.open && !systemPanel.powerMode)
                systemPanel.showPower()
        }
    }

    // A refused or failed action (polkit, no support) is the only result the user sees; a
    // successful one ends the session or suspends the machine.
    Connections {
        target: Power
        function onDone(action, ok) {
            if (!ok)
                Notifications.show(qsTr("Could not %1.").arg(action === "suspend" ? qsTr("suspend")
                                   : action === "restart" ? qsTr("restart") : qsTr("power off")), "error")
        }
    }

    // The default output changed after start-up: by policy (a headset was plugged in or
    // removed) or by the user. The name comes from the service and is not translated.
    Connections {
        target: Audio
        function onOutputSwitched() {
            Notifications.show(qsTr("Audio output: %1").arg(Audio.defaultSinkName), "info")
        }
    }

    // An app that crashed or never got to run is the only exit the user hears about; a normal
    // quit (including a Stop from the shell) is silent.
    Connections {
        target: Session
        function onAppExited(instance, appId, exitCode, reason) {
            if (reason !== "crashed" && reason !== "launch-failed")
                return
            const name = Store.app(appId).name || appId
            Notifications.show(qsTr("%1 stopped unexpectedly").arg(name), "error")
        }
    }

    // Volume keys work in every state, modals included. A Shortcut is matched before key
    // events reach the focus item, so no modal can swallow them and focus never moves.
    Shortcut { sequences: ["Volume Up"]; context: Qt.ApplicationShortcut; onActivated: Audio.stepVolume(5) }
    Shortcut { sequences: ["Volume Down"]; context: Qt.ApplicationShortcut; onActivated: Audio.stepVolume(-5) }
    Shortcut { sequences: ["Volume Mute"]; context: Qt.ApplicationShortcut; onActivated: Audio.toggleMute() }

    readonly property var builtinPages: ({
        games: gamesPage,
        media: mediaPage,
        store: storePage,
        settings: settingsPage,
        power: powerPage
    })
    readonly property var pageComponents: Object.assign({}, builtinPages, extraPages)

    Backdrop {
        id: backdrop
        objectName: "backdrop"
        anchors.fill: parent
        tint: root.signedIn && root.currentTile ? root.currentTile.accent
                                                : (Profiles.active.avatar ?? Theme.defaultTint)
    }

    // Header
    Text {
        id: brand
        objectName: "brand"
        x: root.marginX
        y: root.marginY
        text: "RuyaOS"
        color: Theme.text
        font.pixelSize: Theme.typeTitle * root.u
        font.weight: Font.Bold
    }
    Row {
        anchors { right: parent.right; rightMargin: root.marginX; verticalCenter: brand.verticalCenter }
        spacing: 28 * root.u

        Row {
            visible: root.signedIn
            spacing: 14 * root.u
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
                width: 48 * root.u
                height: width
                radius: width / 2
                color: Profiles.active.avatar ?? Theme.glass
                Text {
                    anchors.centerIn: parent
                    text: (Profiles.active.name ?? "?").charAt(0).toUpperCase()
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * root.u
                }
            }
            Text {
                objectName: "activeProfileName"
                anchors.verticalCenter: parent.verticalCenter
                text: Profiles.active.name ?? ""
                color: Theme.text
                font.pixelSize: Theme.typeBody * root.u
            }
        }
        Text {
            id: clock
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * root.u
            text: Qt.formatTime(new Date(), "HH:mm")
            Timer {
                interval: 10000; running: true; repeat: true
                onTriggered: clock.text = Qt.formatTime(new Date(), "HH:mm")
            }
        }
    }

    ProfilePicker {
        id: picker
        objectName: "profilePicker"
        anchors.fill: parent
        u: root.u
        z: 20                              // modal: above the toasts
        readonly property bool shown: !root.signedIn && !root.setupActive
        opacity: shown ? 1 : 0
        visible: shown || opacity > 0      // visible at once, so focus can be given in the same step
        enabled: shown
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }
    }

    Setup {
        id: setup
        objectName: "setup"
        anchors.fill: parent
        u: root.u
        z: 20                              // modal, like the picker
        visible: root.setupActive
        enabled: root.setupActive
        onFinished: {
            root.setupActive = false
            root.routeFocus()
        }
    }

    Item {
        id: home
        objectName: "home"
        anchors.fill: parent
        readonly property bool shown: root.signedIn && !root.pageOpen
        opacity: shown ? 1 : 0
        visible: shown || opacity > 0      // visible at once, so focus can be given in the same step
        enabled: shown                     // disabled while a page is open: no focus, no keys
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }
        transform: Translate {
            x: home.shown ? 0 : -Theme.pageSlide * root.u
            Behavior on x { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }
        }

        // Frosted shelf: blurs only the backdrop region behind it (one shared source, no
        // second render of the scene).
        Item {
            id: shelf
            anchors {
                left: parent.left; right: parent.right
                bottom: parent.bottom; bottomMargin: root.marginY + 60 * root.u
            }
            height: 380 * root.u
            clip: true

            MultiEffect {
                objectName: "shelfBlur"
                visible: Theme.blurMax > 0     // performance tier: no blur, opaque panel below
                x: -shelf.x
                y: -shelf.y
                width: root.width
                height: root.height
                source: backdrop
                autoPaddingEnabled: false
                blurEnabled: true
                blur: 1.0
                blurMax: Theme.blurMax
                brightness: -0.08
                saturation: 0.15
            }
            Rectangle {
                anchors.fill: parent
                color: Theme.blurMax > 0 ? Theme.glass : Theme.glassOpaque
                Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top } height: Math.max(1, root.u); color: Theme.glassBorder }
                Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: Math.max(1, root.u); color: Theme.glassBorder }
            }
        }

        Text {
            anchors { left: shelf.left; leftMargin: root.marginX; bottom: shelf.top; bottomMargin: 20 * root.u }
            text: root.currentTile ? root.currentTile.title : ""
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * root.u
            font.weight: Font.Light
        }

        ListView {
            id: tiles
            objectName: "tiles"

            anchors { left: shelf.left; right: shelf.right; verticalCenter: shelf.verticalCenter }
            leftMargin: root.marginX
            rightMargin: root.marginX
            height: 260 * root.u
            orientation: ListView.Horizontal
            spacing: 36 * root.u
            keyNavigationWraps: false
            highlightMoveDuration: Theme.focusMs
            highlightRangeMode: ListView.ApplyRange
            preferredHighlightBegin: root.marginX
            preferredHighlightEnd: width - root.marginX
            interactive: false           // no flicking...
            keyNavigationEnabled: true   // ...but keys still navigate (defaults to `interactive`)
            clip: false

            // Keys only: a model whose contents change (e.g. translated titles) would reset
            // currentIndex when the language changes. The title is a binding in the delegate.
            model: ["games", "media", "store", "settings", "power"]

            delegate: Tile {
                required property string modelData
                key: modelData
                title: root.tileTitle(modelData)
                u: root.u
                width: 400 * root.u
                height: tiles.height
            }

            onCurrentIndexChanged: Sfx.navigate()
            function accept() {
                root.currentTile.pulse()
                Sfx.select()
                root.openPage(root.currentTile.key)
            }
            Keys.onReturnPressed: accept()
            Keys.onEnterPressed: accept()
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                    Sfx.back()
                    event.accepted = true
                }
            }
        }
    }

    Component { id: gamesPage; GamesPage {} }
    Component { id: mediaPage; MediaPage {} }
    Component { id: storePage; StorePage {} }
    Component { id: settingsPage; SettingsPage {} }
    Component { id: powerPage; PowerPage {} }

    // Hosts the page slots, one per open page (plus any still fading out). Its only
    // children are slots, which are destroyed after their fade-out.
    Item {
        id: pageHost
        objectName: "pageHost"
        anchors.fill: parent
        visible: root.slotCount > 0
        enabled: root.pageOpen
    }

    // One per stack entry. The top slot is shown and enabled (it fades and slides in while
    // the shelf slides out); lower ones stay alive but hidden and disabled, so their state is
    // kept. A popped slot fades out, then is destroyed.
    Component {
        id: pageSlot
        FocusScope {
            id: slot
            objectName: "pageSlot_" + key

            property string key
            property Item page
            property bool shown: false
            property bool closing: false
            property bool reaped: false
            property Item savedFocus: null

            anchors.fill: parent
            opacity: shown ? 1 : 0
            visible: shown || opacity > 0
            enabled: shown
            Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }
            transform: Translate {
                x: slot.shown ? 0 : Theme.pageSlide * root.u
                Behavior on x { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }
            }
            onOpacityChanged: reapIfDone()
            onClosingChanged: reapIfDone()

            // A page popped before its fade-in has progressed is already at opacity 0.
            function reapIfDone() {
                if (closing && opacity === 0 && !reaped) {
                    reaped = true
                    root.slotCount -= 1
                    destroy()
                }
            }

            // Disabling a slot drops its focus, so the focused item is noted when a page
            // is pushed over it and given focus again when it is on top once more.
            function rememberFocus() {
                const f = Window.activeFocusItem
                let p = f
                while (p && p !== page)
                    p = p.parent
                savedFocus = p ? f : null
            }
            function restoreFocus() {
                if (savedFocus && savedFocus.enabled)
                    savedFocus.forceActiveFocus()
                else if (page)
                    page.forceActiveFocus()
                savedFocus = null
            }
        }
    }

    // Pages parent their modals (PinPad, TextEntry) here: full screen, above pages and toasts,
    // below the picker and the Guide overlay.
    Item {
        id: modalLayer
        objectName: "modalLayer"
        anchors.fill: parent
        z: 15
    }

    // Toasts sit above pages and below the modals (picker, overlay); the volume OSD is above all.
    ToastLayer {
        id: toasts
        objectName: "toastLayer"
        anchors.fill: parent
        z: 10
        u: root.u
        marginX: root.marginX
        marginY: root.marginY
    }

    // Placeholder for the Guide overlay; also shows build info used by the update tests.
    Rectangle {
        id: systemPanel
        objectName: "systemPanel"
        z: 20

        property bool open: false
        // The overlay shows the power choices instead of the system actions.
        property bool powerMode: false

        function showPower() {
            powerMode = true
            actions.currentIndex = 0
            Sfx.navigate()
        }

        anchors.fill: parent
        color: Theme.scrimOverlay
        opacity: open ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.OutCubic } }
        onOpenChanged: {
            powerMode = false
            if (open) {
                Power.refresh()
                actions.currentIndex = 0
                actions.forceActiveFocus()
            } else {
                guideHoldTimer.stop()
                root.focusCurrent()      // the page if one is open, else the tiles
            }
        }

        Rectangle {
            anchors.centerIn: parent
            width: panelColumn.width + 96 * root.u
            height: panelColumn.height + 96 * root.u
            radius: 32 * root.u
            color: Theme.panel
            border.color: Theme.glassBorder
        }

        Column {
            id: panelColumn
            anchors.centerIn: parent
            spacing: 18 * root.u
            Text { text: qsTr("System"); color: Theme.text; font.pixelSize: Theme.typeTitle * root.u; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: qsTr("Image version %1").arg(root.version); color: Theme.textDim; font.pixelSize: Theme.typeBody * root.u; anchors.horizontalCenter: parent.horizontalCenter }
            FpsMeter { font.pixelSize: Theme.typeBody * root.u; anchors.horizontalCenter: parent.horizontalCenter; visible: systemPanel.visible }

            ListView {
                id: actions
                objectName: "systemActions"

                anchors.horizontalCenter: parent.horizontalCenter
                width: 520 * root.u
                height: contentHeight
                spacing: 14 * root.u
                interactive: false
                keyNavigationEnabled: true
                readonly property var systemItems: [
                    { key: "switch", label: qsTr("Switch profile") },
                    { key: "power", label: qsTr("Power") },
                    { key: "close", label: qsTr("Close") },
                ]
                // Only what logind allows; "Back" returns to the system actions.
                readonly property var powerItems: [
                    ...(Power.canSuspend ? [{ key: "suspend", label: qsTr("Suspend") }] : []),
                    ...(Power.canRestart ? [{ key: "restart", label: qsTr("Restart") }] : []),
                    ...(Power.canPowerOff ? [{ key: "poweroff", label: qsTr("Power off") }] : []),
                    { key: "back", label: qsTr("Back") },
                ]
                model: systemPanel.powerMode ? powerItems : systemItems

                function activate(key) {
                    Sfx.select()
                    if (key === "power") {
                        systemPanel.showPower()
                    } else if (key === "back") {
                        systemPanel.powerMode = false
                        currentIndex = 1                       // on "Power"
                    } else if (key === "suspend" || key === "restart" || key === "poweroff") {
                        powerConfirm.open(key)                 // focus returns here if cancelled
                    } else {
                        if (key === "switch")
                            Profiles.lock()    // signedIn -> false; routeFocus() shows the picker
                        systemPanel.open = false
                    }
                }

                onCurrentIndexChanged: if (systemPanel.open) Sfx.navigate()
                Keys.onReturnPressed: activate(model[currentIndex].key)
                Keys.onEnterPressed: activate(model[currentIndex].key)
                Keys.onPressed: event => {
                    // Accepting every key (below) also skips the list's own key navigation, so
                    // Up/Down are handled here.
                    if (event.key === Qt.Key_Down) {
                        incrementCurrentIndex()
                    } else if (event.key === Qt.Key_Up) {
                        decrementCurrentIndex()
                    } else if (event.isAutoRepeat) {
                        // Holding Guide repeats the key: not a second press that would close us.
                    } else if (systemPanel.powerMode && (event.key === Qt.Key_Escape || event.key === Qt.Key_Back)) {
                        Sfx.back()
                        activate("back")
                    } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back || root.isGuideKey(event.key)) {
                        systemPanel.open = false
                        Sfx.back()
                    }
                    event.accepted = true      // modal: nothing leaks to the shelf underneath
                }

                delegate: Rectangle {
                    id: action
                    required property int index
                    required property var modelData
                    readonly property bool focused: ListView.isCurrentItem && actions.activeFocus

                    width: actions.width
                    height: 76 * root.u
                    radius: height / 2
                    color: focused ? Theme.focusFill : Theme.glass
                    border.width: focused ? 4 * root.u : 1
                    border.color: focused ? Theme.focusRing : Theme.glassBorder
                    Text {
                        anchors.centerIn: parent
                        text: action.modelData.label
                        color: Theme.text
                        font.pixelSize: Theme.typeHeadline * root.u
                    }
                }
            }
        }
    }

    // Confirmation for the overlay's power choices (the Power page has its own instance in
    // the modal layer). Above the overlay, below the volume OSD.
    PowerConfirm {
        id: powerConfirm
        objectName: "overlayPowerConfirm"
        anchors.fill: parent
        z: 25
        u: root.u
        onConfirmed: systemPanel.open = false
        // Cancelled: back to the choices. (The dialog's own restore would land on a list
        // delegate that may be gone, so name the list.)
        onClosed: if (systemPanel.open) actions.forceActiveFocus()
    }

    // Always-on version tag: the update/rollback checks read it off the screen.
    Text {
        anchors { right: parent.right; bottom: parent.bottom; margins: root.marginY / 2 }
        text: root.version
        color: Theme.textDim
        font.pixelSize: Theme.typeMicro * root.u
    }

    Text {
        visible: Profiles.mock
        anchors { left: parent.left; bottom: parent.bottom; margins: root.marginY / 2 }
        text: qsTr("mock services")
        color: Theme.warningText
        font.pixelSize: Theme.typeMicro * root.u
    }

    VolumeOsd {
        objectName: "volumeOsd"
        z: 30
        u: root.u
        marginY: root.marginY
    }
}
