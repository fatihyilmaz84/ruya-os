pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The whole console UI as one Item, so tests can host it in their own window.
// Flow: profile picker -> home shelf; Guide/Menu opens the system overlay from home.
FocusScope {
    id: root

    required property string version

    readonly property real u: height / 1080 * Theme.uiScale     // the UI size (Theme.uiScale) scales the 1080p unit
    readonly property real marginX: width * Theme.safeArea
    readonly property real marginY: height * Theme.safeArea
    readonly property bool signedIn: Profiles.activeProfile !== ""

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
        if (!signedIn || !component || systemPanel.open) {
            pageProbe.cancel()
            return
        }
        if (!pageProbe.waiting || pageProbe.pendingKey !== key)
            pageProbe.begin(key)            // else openSection began it, before closing the pages
        const below = slots.length > 0 ? slots[slots.length - 1] : null
        if (below)
            below.rememberFocus()
        else if (home.shown)
            rememberHomeFocus()
        const entry = { key: key, params: params ?? ({}) }
        const slot = pageSlot.createObject(pageHost, { key: key })
        if (!slot) {
            console.warn("ruya-shell: could not create the slot for page", key)
            pageProbe.cancel()
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
            pageProbe.cancel()
            return
        }
        pageProbe.created(key)
        page.u = Qt.binding(() => root.u)
        page.version = Qt.binding(() => root.version)
        page.marginX = Qt.binding(() => root.marginX)
        page.marginY = Qt.binding(() => root.marginY)
        page.anchors.fill = slot
        page.backRequested.connect(root.closePage)
        page.openRequested.connect(root.openPage)
        page.upFromTop.connect(root.focusNav)
        page.stepRequested.connect(root.stepSection)
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
        if (pageProbe.pendingKey !== "")
            pageProbe.cancel()          // closed before it settled: stop measuring (and counting frames)
        const gone = slots[slots.length - 1]
        slots = slots.slice(0, -1)
        pageStack = pageStack.slice(0, -1)
        closingSlots = closingSlots.concat([gone])
        gone.closing = true          // destroyed once its fade-out has ended and the page on top has settled
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
        closingSlots = []
        for (const s of all)
            s.destroy()
    }

    // App items (a compositor's windows, T-130) live in `appLayer`: above home and pages, below
    // toasts, modals and the Guide overlay. The shell API for a compositor: addApp(item),
    // focusApp(item), removeApp(item) (also run when the item is destroyed).
    // One record {item} per app item. A destroyed item must not be touched (QML throws), so
    // the list holds records and a guard child of each item removes its record on destruction.
    property var apps: []
    property Item focusedApp: null
    readonly property bool appOpen: apps.length > 0
    // The update service restarts the console only when no app runs, also one left behind Home
    // (input is reported by KeyRouter.onActivity).
    onAppOpenChanged: Update.noteActivity(appOpen)

    property int appSerial: 0

    function recordOf(item) {
        return apps.find(r => r.item === item)
    }

    function addApp(item) {
        if (!item || recordOf(item))
            return
        item.parent = appLayer
        item.anchors.fill = appLayer
        const record = { item: item, id: ++appSerial }
        appGuard.createObject(item, { recordId: record.id })
        apps = apps.concat([record])
        focusApp(item)
    }

    function focusApp(item) {
        if (!recordOf(item))
            return
        focusedApp = item
        if (!systemPanel.open)          // the overlay keeps the focus until it closes
            focusCurrent()
    }

    function removeApp(item) {
        const record = recordOf(item)
        if (record)
            dropRecord(record.id)
    }

    function dropRecord(id) {
        const record = apps.find(r => r.id === id)
        if (!record)
            return
        apps = apps.filter(r => r.id !== id)
        if (!focusedApp || focusedApp === record.item)
            focusedApp = apps.length > 0 ? apps[apps.length - 1].item : null
        if (!systemPanel.open)
            focusCurrent()              // the next app, else the page or Home
    }

    Component {
        id: appGuard
        QtObject {
            property int recordId
            Component.onDestruction: root.dropRecord(recordId)
        }
    }

    // Gives focus to whatever is on top: the focused app, else the open page, else Home.
    function focusCurrent() {
        if (!signedIn)
            return
        if (focusedApp)
            focusedApp.forceActiveFocus()
        else if (pageOpen)
            slots[slots.length - 1].restoreFocus()
        else
            focusHome()
    }

    // Home: the item that had focus before a page or the overlay, else Play.
    function focusHome() {
        const saved = homeSavedFocus
        homeSavedFocus = null
        if (saved && saved.enabled && saved.visible)
            saved.forceActiveFocus()
        else
            heroBlock.forceActiveFocus()
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
        if (!signedIn) {
            dropAllPages()       // the next sign-in starts at home
            homeSavedFocus = null
        }
        routeFocus()
    }
    Component.onCompleted: {
        Power.refresh()          // creates the singleton early, so the rows know what is allowed
        // Settings -> Network is the one pane whose service is not created at start by something
        // else: create it now, not in the frame that builds the pane (T-349). Its first list arrives
        // asynchronously, so the pane has it when it is first shown.
        Network.state
        if (setupNeeded) {
            setupActive = true
            setup.start()
        }
        heroArt.show(libraryEmpty ? null : heroItem)   // the change handler misses a first value
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

    // Which keys are Guide is decided in C++ (KeyRouter.isGuideKey). Menu is the context-menu
    // key (spec 02 4.2), not Guide.
    function isGuideKey(key) {
        return keyRouter.isGuideKey(key)
    }

    function guideDown(autoRepeat) {
        if (!autoRepeat) {
            systemPanel.open = true
            guideHeld = true
            guideHoldTimer.restart()
        }
    }
    function guideUp(autoRepeat) {
        if (!autoRepeat) {
            guideHeld = false
            guideHoldTimer.stop()
        }
    }

    // With an app focused the router takes the Guide keys before the app sees them (the
    // overlay, pages and tiles get them as ordinary key events, below).
    KeyRouter {
        id: keyRouter
        window: root.Window.window
        appItem: root.focusedApp
        onGuidePressed: autoRepeat => { if (root.signedIn && !systemPanel.open) root.guideDown(autoRepeat) }
        onGuideReleased: autoRepeat => root.guideUp(autoRepeat)
        // While the screen saver or the dark screen is up, the first input only wakes the console
        // (IdleClock.covered): KeyRouter eats it, so no page and no app sees it (T-202). Input in
        // the second after the screen came back is eaten too (IdleClock.wakeGapMs, T-293).
        swallowInput: IdleClock.swallowInput
        onActivity: IdleClock.noteInput()
    }

    // The one idle clock (T-202): every receiver that used to watch the input itself hears it from here.
    Connections {
        target: IdleClock
        // The update service restarts the console only when nobody is using it.
        function onInputNoted() {
            Update.noteActivity(root.appOpen)
            LiquidGate.noteInput()
            toasts.noteInput()
            presence.check()
        }
    }
    Binding {
        target: IdleClock
        property: "appOpen"
        value: root.appOpen
    }

    // The app in front, for the play ledger (T-247): the newest running app of the active profile
    // while an app item has the screen and the Guide overlay is closed. (The compositor does not
    // tell the shell which window belongs to which instance yet, T-164; with two apps running
    // the newest is assumed.)
    readonly property string foregroundInstance: {
        if (!focusedApp || systemPanel.open || !signedIn)
            return ""
        let best = null
        for (const r of Session.running) {
            if (r.profile === Profiles.activeProfile && r.state !== "stopping" && (!best || r.started >= best.started))
                best = r
        }
        return best ? best.instance : ""
    }

    UsagePresence {
        id: presence
        objectName: "usagePresence"
        signedIn: root.signedIn
        instance: root.foregroundInstance
    }

    // The liquid pill's specular clock runs only with no app in front, the window shown and input
    // within the idle period (LiquidGate, 04 §3.8): nothing keeps redrawing a still screen.
    Binding {
        target: LiquidGate
        property: "appOpen"
        value: root.appOpen
    }
    Binding {
        target: LiquidGate
        property: "screenShown"
        value: root.Window.window !== null && root.Window.window.visibility !== Window.Hidden
               && root.Window.window.visibility !== Window.Minimized
    }

    // The safety net for a page's focus (T-356). The focus has fallen out of the open page when,
    // with no app, Guide overlay or setup in front, nothing, the shell itself or the window's content
    // item holds it, or an item of a page below the top one does (a covered page that took the focus
    // back: the page's keys, Back above all, then go nowhere). Seen on the Dell (2026-11-09): the app
    // page, covered by "Your activity", gave the focus to its own button when its fade-out hid it.
    // While anything in the modal layer shows (a PIN pad, the keyboard, a dialog, between two steps
    // of a flow), the focus is that modal's business: the net stays out. It never acts on keys.
    property int focusRepairs: 0            // how often refocusIfLost() acted (tests: a page's own focus never needs it)
    function modalShown() {
        for (let i = 0; i < modalLayer.children.length; ++i) {
            const c = modalLayer.children[i]
            if (!c.visible)
                continue
            // A pane's lazily built modal sits here in a Loader that is "visible" even when it
            // holds nothing (T-349): only what it has loaded counts.
            if (c.item !== undefined) {
                if (c.item && c.item.visible)
                    return true
                continue
            }
            return true
        }
        return false
    }
    function focusIsLost() {
        const w = root.Window.window
        if (!w || !w.active || !signedIn || !pageOpen || focusedApp || systemPanel.open || setupActive || modalShown())
            return false
        const f = w.activeFocusItem
        if (f === null || f === root || f === w.contentItem)
            return true
        for (let p = f; p; p = p.parent) {
            if (p.parent === pageHost)
                return p !== slots[slots.length - 1]
        }
        return false
    }

    // Repaired once the current event is over (a page change moves the focus in several steps, the
    // last one in the page on top), and logged: `journalctl -b _UID=<ruya-shell> | grep "fell out"`.
    // A Timer, not Qt.callLater: queueing a call on every focus change reordered the pages' own
    // deferred focus calls (the Store's focusContent after a search took the wrong row).
    Connections {
        target: root.Window.window
        ignoreUnknownSignals: true
        function onActiveFocusItemChanged() { focusCheck.restart() }
        function onActiveChanged() { focusCheck.restart() }
    }
    Timer {
        id: focusCheck
        interval: 0
        onTriggered: root.refocusIfLost()
    }
    function refocusIfLost() {
        if (!focusIsLost())
            return
        const f = root.Window.window.activeFocusItem
        console.warn("ruya-shell: the focus fell out of page", currentPage, "(on",
                     f ? (f.objectName || String(f)) : "nothing", "), restoring it")
        focusRepairs += 1
        focusCurrent()
    }

    Keys.onPressed: event => {
        if (signedIn && !systemPanel.open && isGuideKey(event.key)) {
            guideDown(event.isAutoRepeat)
            event.accepted = true
        }
    }
    Keys.onReleased: event => {
        if (isGuideKey(event.key))
            guideUp(event.isAutoRepeat)
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

    // A staged update (also a rollback) needs a restart: say so once per staging.
    Connections {
        target: Update
        function onStagedReady(version) {
            Notifications.show(qsTr("Update ready. Restart to finish."), "info")
        }
    }

    // The service restarts the console by itself about two minutes after it says so: tell the
    // user, until a press calls it off (the service clears restart_at) or the restart happens.
    Connections {
        target: Update
        function onRestartPendingChanged() {
            if (Update.restartPending)
                Notifications.showSticky("update-restart",
                    qsTr("Restarting to finish the update in 2 minutes. Press any button to wait."), "warning")
            else
                Notifications.remove("update-restart")
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

    // A screen mode waiting for the owner (T-198): after the restart on a new mode the shell finds
    // Display.confirming and asks "Keep this resolution?" (ModeConfirm) over whatever it shows, so a
    // TV that cannot show the mode can always be answered, or left to revert by the countdown.
    // The Settings page on Display & motion is opened first, so that the owner lands where the
    // change was made.
    Connections {
        target: Display
        function onConfirmingChanged() {
            if (Display.confirming) {
                if (root.signedIn && root.currentPage !== "settings")
                    root.openPage("settings", { category: "display" })
                modeConfirm.shown = true
            } else {
                modeConfirm.shown = false
            }
        }
        function onModeReset() {
            Notifications.show(qsTr("The screen did not answer, so the previous resolution is back."), "warning")
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
        appDetail: appDetailPage,
        details: libraryDetailsPage,
        settings: settingsPage,
        systemInfo: systemInfoPage,
        activity: activityPage,
        activityGame: activityGamePage,
        power: powerPage
    })
    readonly property var pageComponents: Object.assign({}, builtinPages, extraPages)

    // L0: the backdrop and, on Home, the hero art of the focused Recent item. Glass blurs a
    // crop of this layer (SectionNav.Glass).
    Item {
        id: l0
        objectName: "l0"
        anchors.fill: parent

        Backdrop {
            id: backdrop
            objectName: "backdrop"
            anchors.fill: parent
            tint: Profiles.active.avatar ?? Theme.defaultTint
            shown: !wallpaperLayer.covering && !IdleClock.covered   // a wallpaper covers it (T-208); the saver covers all (T-202)
            paused: root.focusedApp !== null                         // an app in front covers it: no frames for the drift (T-293)
        }

        // The wallpaper (Settings -> Display & motion): the picture under the hero art, blurred on pages.
        WallpaperLayer {
            id: wallpaperLayer
            objectName: "wallpaperLayer"
            anchors.fill: parent
            blurred: root.pageOpen
            onFailed: (id, reason) => {
                console.warn("ruya-shell: wallpaper", id, "unusable:", reason, "- using the default look")
                Notifications.show(qsTr("Wallpaper could not be loaded"), "warning")
                DeviceSettings.wallpaper = ""
            }
        }

        // Hero art: two layers that cross-fade over tintMs when the focused item changes.
        Item {
            id: heroArt
            objectName: "heroArt"
            anchors.fill: parent
            opacity: home.opacity
            visible: opacity > 0
            property bool showB: false

            component ArtLayer: AppArt {
                anchors.fill: parent
                radius: 0
                clip: false
                monogram: false
                shimmer: false
                bare: wallpaperLayer.has     // over a wallpaper an item without art shows the wallpaper, not a colour field
                Behavior on opacity { NumberAnimation { duration: Theme.tintMs; easing.type: Easing.InOutQuad } }
            }
            ArtLayer { id: artA; objectName: "heroArtA"; u: root.u; opacity: heroArt.showB ? 0 : 1 }
            ArtLayer { id: artB; objectName: "heroArtB"; u: root.u; opacity: heroArt.showB ? 1 : 0 }

            function show(item) {
                const to = showB ? artA : artB
                const known = item && item.id
                to.appId = known ? item.id : ""
                to.appName = known ? (item.title ?? "") : ""
                to.picture = known && item.art ? (item.art.hero ?? item.art.tile ?? "") : ""
                showB = !showB
            }

            // Left scrim for the text, bottom fade for the Recent row (04 §3.1).
            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: parent.width * 0.75
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Theme.heroScrim }
                    GradientStop { position: 1.0; color: Theme.heroScrimClear }
                }
            }
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: parent.height * 0.45
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Theme.artCaptionFadeClear }
                    GradientStop { position: 1.0; color: Theme.artCaptionFade }
                }
            }
        }
    }

    // Status cluster (device batteries, profile, clock) top right, on glass; shown on Home and on pages.
    GlassPill {
        id: statusGlass
        objectName: "statusGlass"
        visible: root.signedIn
        height: Theme.buttonHeight * root.u + 2 * Theme.spaceXs * root.u
        width: statusRow.width + 2 * Theme.spaceL * root.u
        x: root.width - root.marginX - width
        y: root.marginY
        u: root.u
        source: l0
        sourceX: x
        sourceY: y

        // The cluster is sized from the room between the nav and the right margin (T-223): the
        // profile name elides to what is left (never under about six characters) and the battery
        // chips are as many as fit (the rest collapse into "+N"), so the pill never reaches the
        // nav (a Theme.spaceM gap stays) however long the name or many the devices.
        readonly property real room: root.width - root.marginX - (sectionNav.x + sectionNav.width + Theme.spaceM * root.u)
                                     - 2 * Theme.spaceL * root.u
        // Every device that earns a chip, in the order the slots are given out (T-301): pads and headsets
        // before mice, keyboards and the rest, each group lowest first (the service sorts that way), so
        // three full pads are not pushed out by a mouse at 5 % (that one shows in Settings and in its toast).
        readonly property var batteryDevices: Batteries.chips.concat(Batteries.more)
            .map((d, i) => ({ device: d, order: i, rank: statusGlass.rankOf(d) }))
            .sort((a, b) => a.rank - b.rank || a.order - b.order)
            .map(x => x.device)
        function rankOf(device) {
            return device.kind === "controller" || device.kind === "headset" ? 0 : 1
        }
        readonly property real nameFull: profileName.implicitWidth
        readonly property real nameMin: Math.min(nameFull, probeName.implicitWidth)
        // Avatar, its gap to the name, the clock and the gap between profile and clock.
        readonly property real fixedWidth: (Theme.statusAvatarSize + Theme.spaceS + Theme.spaceM) * root.u + clock.implicitWidth
        // How many chips fit, and whether the "N more" chip has to drop its words to fit (T-301).
        readonly property var fit: fitChips()
        readonly property int chipCount: fit.chips
        readonly property bool moreCompact: fit.compact
        // The pill stops growing here however much room there is (T-312): the name elides.
        readonly property real nameCap: 220 * root.u
        readonly property real nameWidth: Math.max(nameMin, Math.min(nameFull, nameCap, room - fixedWidth - batteryWidth(chipCount, moreCompact)))

        // Probes of the real fonts, never shown: a chip is budgeted with its percentage in the widest
        // digit (8) for its number of digits, the "+N" the same, and the name's minimum is six wide
        // letters, so the budget only errs on the side of fewer chips. The "N more" chip is measured by
        // itself (same component, in the translated language), at one and at two digits.
        Text { id: probePercent1; visible: false; text: "8%"; font.pixelSize: Theme.typeBody * root.u }
        Text { id: probePercent2; visible: false; text: "88%"; font.pixelSize: Theme.typeBody * root.u }
        Text { id: probePercent3; visible: false; text: "888%"; font.pixelSize: Theme.typeBody * root.u }
        BatteryMore { id: probeMore1; visible: false; count: 8; u: root.u }
        BatteryMore { id: probeMore2; visible: false; count: 88; u: root.u }
        BatteryMore { id: probeCompact1; visible: false; count: 8; compact: true; u: root.u }
        BatteryMore { id: probeCompact2; visible: false; count: 88; compact: true; u: root.u }
        Text { id: probeName; visible: false; text: "nnnnnn"; font.pixelSize: Theme.typeBody * root.u }
        Icon { id: iconProbe; visible: false; name: "battery_full"; u: root.u }

        function chipBudget(device) {
            const text = device.percent >= 100 ? probePercent3 : device.percent >= 10 ? probePercent2 : probePercent1
            return 2 * iconProbe.width + 2 * Theme.spaceXs * root.u + text.implicitWidth
        }
        // The width of the battery group with `n` chips and an "N more" chip for the rest (without its
        // words when `compact`), with its gap to the profile.
        function batteryWidth(n, compact) {
            const all = statusGlass.batteryDevices
            if (all.length === 0)
                return 0
            let w = 0
            for (let i = 0; i < n; ++i)
                w += chipBudget(all[i]) + (i > 0 ? Theme.spaceM * root.u : 0)
            if (all.length > n) {   // the "N more" chip for the rest
                const two = all.length - n >= 10
                const probe = compact ? (two ? probeCompact2 : probeCompact1) : (two ? probeMore2 : probeMore1)
                w += (n > 0 ? Theme.spaceM * root.u : 0) + probe.implicitWidth
            }
            return w + Theme.spaceM * root.u
        }
        // The most chips that fit with the "N more" chip and the shortest profile name (nameMin) in the
        // room, at the current UI size. At least one chip is kept if it fits in any form: first with the
        // words "N more", then without them; if no chip fits, the "N more" chip stands alone, with its
        // words if they fit, else without. (Nothing fits at 150 % and more: the nav takes the room.)
        function fitChips() {
            const most = Math.min(statusGlass.batteryDevices.length, Batteries.chips.length)
            for (const compact of [false, true]) {
                for (let n = most; n > 0; --n) {
                    if (batteryWidth(n, compact) + fixedWidth + nameMin <= room)
                        return { chips: n, compact: compact }
                }
            }
            return { chips: 0, compact: batteryWidth(0, false) + fixedWidth + nameMin > room }
        }

        Row {
            id: statusRow
            anchors.centerIn: parent
            spacing: Theme.spaceM * root.u

            // The battery of each wireless device (Batteries, UPower behind it), lowest first: up to
            // three chips and a "+N" for the rest; nothing without a device that needs one (T-223).
            Row {
                id: batteryStatus
                objectName: "batteryStatus"
                visible: statusGlass.batteryDevices.length > 0
                spacing: Theme.spaceM * root.u
                anchors.verticalCenter: parent.verticalCenter
                // The ids, not the entries: the delegates are kept while a level changes.
                readonly property var chipIds: statusGlass.batteryDevices.slice(0, statusGlass.chipCount).map(d => d.id)
                readonly property var overflow: statusGlass.batteryDevices.slice(statusGlass.chipCount)
                Repeater {
                    model: batteryStatus.chipIds
                    BatteryChip {
                        required property string modelData
                        objectName: "batteryChip_" + modelData
                        deviceId: modelData
                        u: root.u
                    }
                }
                // The devices without a chip of their own: one chip the pad can reach (Right from the last
                // nav pill); Accept lists them (BatteryListModal).
                BatteryMore {
                    id: batteryMore
                    objectName: "batteryMore"
                    visible: batteryStatus.overflow.length > 0
                    enabled: root.navShown && !systemPanel.open && !batteryList.shown
                    anchors.verticalCenter: parent.verticalCenter
                    u: root.u
                    count: batteryStatus.overflow.length
                    compact: statusGlass.moreCompact
                    devices: batteryStatus.overflow
                    onActivated: batteryList.open()
                    onLeftRequested: {
                        Sfx.navigate()
                        sectionNav.currentIndex = sectionNav.keys.length - 1
                        sectionNav.forceActiveFocus()
                    }
                    onDownRequested: { Sfx.navigate(); root.leaveNavDown() }
                    onBackRequested: {
                        if (root.pageOpen) {
                            Sfx.back()
                            root.closePage()
                        }
                    }
                    onStepRequested: direction => root.stepSection(direction)
                    // Lost with the chip (nothing hidden any more): the focus goes to the nav, not nowhere.
                    onActiveFocusChanged: if (!activeFocus) Qt.callLater(root.rescueFocus)
                    onVisibleChanged: if (!visible) Qt.callLater(root.rescueFocus)
                }
            }
            Row {
                spacing: Theme.spaceS * root.u
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    width: Theme.statusAvatarSize * root.u
                    height: width
                    radius: width / 2
                    color: Profiles.active.avatar ?? Theme.glass
                    Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: (Profiles.active.name ?? "?").charAt(0).toUpperCase()
                        color: Theme.text
                        font.pixelSize: Theme.typeCaption * root.u
                    }
                }
                Text {
                    id: profileName
                    objectName: "activeProfileName"
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: Profiles.active.name ?? ""
                    width: Math.min(implicitWidth, statusGlass.nameWidth)   // the full name unless the room is short
                    elide: Text.ElideRight
                    color: Theme.text
                    font.pixelSize: Theme.typeBody * root.u
                }
            }
            Text {
                id: clock
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.text
                font.pixelSize: Theme.typeHeadline * root.u
                font.weight: Theme.weightDemiBold
                objectName: "statusClock"
                text: TimeZone.clockText     // the console's time zone (T-213), ticking in the singleton
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
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
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

    // Home (04 §2, art-led): the section nav top left, the hero block of the focused Recent item
    // and the Recent row of art cards. The hero art itself is in `l0`.
    Item {
        id: home
        objectName: "home"
        anchors.fill: parent
        readonly property bool shown: root.signedIn && !root.pageOpen && !root.appOpen
        opacity: shown ? 1 : 0
        visible: shown || opacity > 0      // visible at once, so focus can be given in the same step
        enabled: shown                     // disabled while a page is open: no focus, no keys
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
        transform: Translate {
            x: home.shown ? 0 : -Theme.pageSlide * root.u
            Behavior on x { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
        }

        // LB / RB switch sections from anywhere on Home (the nav handles them itself); Back does
        // nothing here.
        Keys.onPressed: event => {
            if (event.key === Qt.Key_PageDown) {
                root.stepSection(1)
                event.accepted = true
            } else if (event.key === Qt.Key_PageUp) {
                root.stepSection(-1)
                event.accepted = true
            } else if (BackKey.isBackOrBackspace(event.key)) {
                Sfx.back()
                event.accepted = true
            }
        }

        HeroBlock {
            id: heroBlock
            objectName: "heroBlock"
            focus: true
            u: root.u
            width: Math.min(960 * root.u, root.width * 0.55)
            anchors { left: parent.left; leftMargin: root.marginX; bottom: recentRow.top; bottomMargin: Theme.spaceL * root.u }

            eyebrow: root.libraryEmpty ? "" : (root.recentIsFallback ? qsTr("Installed") : qsTr("Continue playing"))
            title: root.libraryEmpty ? qsTr("Your library is empty") : (root.heroItem.title ?? "")
            meta: root.libraryEmpty ? "" : root.sourceLabel(root.heroItem.source ?? "")
            primaryText: root.libraryEmpty ? qsTr("Open Store") : qsTr("Play")
            secondaryText: root.libraryEmpty ? "" : qsTr("Details")

            onPrimaryAccepted: root.playHero()
            onSecondaryAccepted: root.openDetails()
            onUpRequested: { Sfx.navigate(); sectionNav.forceActiveFocus() }
            onDownRequested: if (!root.libraryEmpty) { Sfx.navigate(); recentRow.forceActiveFocus() }
        }

        // Recent: the eight last played items (else the first installed ones, `recentIsFallback`).
        // Moving along it changes the hero.
        ListView {
            id: recentRow
            objectName: "recentRow"
            Accessible.role: Accessible.List
            Accessible.name: currentItem ? currentItem.Accessible.name : (root.recentIsFallback ? qsTr("Installed") : qsTr("Recent"))
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: root.marginY + hintBar.height + Theme.spaceM * root.u }
            leftMargin: root.marginX
            rightMargin: root.marginX
            height: (Theme.cardArtHeight(Theme.cardWidthShelf) + 2 * Theme.cardGap) * root.u
            orientation: ListView.Horizontal
            spacing: Theme.cardGap * root.u
            keyNavigationWraps: false
            highlightMoveDuration: Theme.focusMs
            highlightRangeMode: ListView.ApplyRange
            preferredHighlightBegin: root.marginX
            preferredHighlightEnd: width - root.marginX
            interactive: false           // no flicking...
            keyNavigationEnabled: true   // ...but keys still navigate (defaults to `interactive`)
            clip: false

            // Item ids: a model of records would rebuild the row on every library change.
            model: root.recentIds

            delegate: ArtCard {
                id: recentCard

                required property int index
                required property string modelData
                readonly property var entry: Library.item(modelData)

                objectName: "recentCard_" + modelData
                u: root.u
                width: Theme.cardWidthShelf * root.u
                y: (ListView.view.height - height) / 2
                itemId: modelData
                title: entry.title ?? ""
                picture: entry.art ? (entry.art.tile ?? "") : ""
                focused: ListView.isCurrentItem && ListView.view.activeFocus
            }

            onCurrentIndexChanged: if (activeFocus) Sfx.navigate()
            Keys.onReturnPressed: root.playRecent()
            Keys.onEnterPressed: root.playRecent()
            Keys.onUpPressed: { Sfx.navigate(); heroBlock.forceActiveFocus() }
        }
    }

    // What Home shows. The row holds ids; the hero follows its current item. Nothing played yet
    // (no `lastPlayed`) but something installed: the row falls back to the first eight installed
    // items, in the order the Games page uses (the library's: played first, then by title). The
    // empty state is for a library with nothing installed (T-183).
    readonly property bool recentIsFallback: Library.recent.length === 0 && Library.items.length > 0
    readonly property var recentIds: (recentIsFallback ? Library.items.slice(0, 8) : Library.recent).map(r => r.id)
    readonly property bool libraryEmpty: recentIds.length === 0
    readonly property var heroItem: libraryEmpty ? ({}) : Library.item(recentIds[Math.max(0, Math.min(recentRow.currentIndex, recentIds.length - 1))])
    onHeroItemChanged: heroArt.show(libraryEmpty ? null : heroItem)

    // The home item to give focus back to after a page or the overlay (set by rememberHomeFocus,
    // used once by focusHome). After an app closes, focus goes to Play.
    property Item homeSavedFocus: null

    function rememberHomeFocus() {
        const f = Window.activeFocusItem
        let p = f
        while (p && p !== home && p !== sectionNav)
            p = p.parent
        homeSavedFocus = p ? f : null
    }

    function sourceLabel(source) {
        switch (source) {
        case "steam": return "Steam"
        case "flatpak": return "Flatpak"
        }
        return source
    }

    function playHero() {
        if (libraryEmpty) {
            openSection("store")
            return
        }
        const id = heroItem.id
        Sfx.select()
        Library.launch(id)
        Notifications.show(qsTr("Starting %1…").arg(heroItem.title ?? id), "info")
    }

    // Accept on a Recent card: the card pulses, then the game starts (the hero follows the row).
    function playRecent() {
        (recentRow.currentItem as ArtCard)?.pulse()
        playHero()
    }

    function openDetails() {
        openPage("details", { id: heroItem.id })
    }

    // Opens a section from the nav or LB/RB. From Home, "home" just brings focus to Play. On a
    // section page the open pages are closed first (Back from the new one lands on Home, where
    // it started); "home" then stays there, and the page's own pill returns focus to its content.
    function openSection(key) {
        if (key !== "home" && key !== navSection)
            pageProbe.begin(key)            // the time to close the pages below counts too
        if (pageOpen) {
            if (key === navSection) {
                leaveNavDown()
                return
            }
            while (pageOpen)
                closePage()
            Sfx.page()
            if (key === "home") {
                heroBlock.forceActiveFocus()
                return
            }
        } else if (key === "home") {
            heroBlock.forceActiveFocus()
            return
        } else {
            Sfx.page()
        }
        openPage(key)
    }

    // LB / RB: the section after (or before) the focused pill, or after the one on screen when
    // focus is not in the nav.
    function stepSection(direction) {
        if (!navShown || systemPanel.open)
            return
        const inNav = sectionNav.activeFocus
        const index = (inNav ? sectionNav.currentIndex : sectionNav.keys.indexOf(navSection)) + direction
        if (index < 0 || index >= sectionNav.keys.length)
            return
        if (inNav)
            sectionNav.currentIndex = index
        openSection(sectionNav.keys[index])
    }

    // Up from the top of a section page: the nav, on the pill of that page.
    function focusNav() {
        if (!navShown || systemPanel.open)
            return
        Sfx.navigate()
        if (pageOpen)
            slots[slots.length - 1].rememberFocus()
        sectionNav.currentIndex = sectionNav.keys.indexOf(navSection)
        sectionNav.forceActiveFocus()
    }

    // The "N more" chip lost the focus because it went away: if nothing took it, the nav does.
    function rescueFocus() {
        const item = root.Window.window ? root.Window.window.activeFocusItem : null
        if (navShown && !systemPanel.open && !batteryList.shown && (item === null || item === root || !item.visible || !item.enabled)) {
            sectionNav.currentIndex = sectionNav.keys.indexOf(navSection) >= 0 ? sectionNav.keys.indexOf(navSection) : 0
            sectionNav.forceActiveFocus()
        }
    }

    // Down from the nav: the page content that had focus, or Play on Home.
    function leaveNavDown() {
        if (pageOpen)
            slots[slots.length - 1].restoreFocus()
        else
            heroBlock.forceActiveFocus()
    }

    Component { id: gamesPage; GamesPage {} }
    Component { id: mediaPage; MediaPage {} }
    Component { id: storePage; StorePage {} }
    Component { id: appDetailPage; AppDetailPage {} }
    Component { id: libraryDetailsPage; LibraryDetailsPage {} }
    Component { id: settingsPage; SettingsPage {} }
    Component { id: systemInfoPage; SystemInfoPage {} }
    Component { id: activityPage; ActivityPage {} }
    Component { id: activityGamePage; ActivityGamePage {} }
    Component { id: powerPage; PowerPage {} }

    // Hosts the page slots, one per open page (plus any still fading out). Its only
    // children are slots, which are destroyed after their fade-out.
    Item {
        id: pageHost
        objectName: "pageHost"
        anchors.fill: parent
        visible: root.slotCount > 0
        enabled: root.pageOpen && !root.appOpen
    }

    // The section nav (04 §5): one instance in the top layer, so it stays put when Home gives way
    // to a section page. Shown on Home and on the section pages (a key of `sectionNav.keys` on top
    // of the stack); a detail page, a running app, the picker and the wizard hide it, and the
    // Guide overlay disables it.
    readonly property bool navShown: signedIn && !appOpen
        && (!pageOpen || sectionNav.keys.indexOf(currentPage) >= 0)
    // The section on screen: the top section page, else Home. A detail page keeps the last one
    // (the nav fades out with it).
    property string navSection: "home"
    onCurrentPageChanged: {
        if (currentPage === "")       // not pageOpen: that binding may not have updated yet
            navSection = "home"
        else if (sectionNav.keys.indexOf(currentPage) >= 0)
            navSection = currentPage
    }
    // The focus ring follows a section page; going back to Home leaves it on the pill that opened
    // the page (Back lands on it).
    onNavSectionChanged: {
        if (navSection !== "home")
            sectionNav.currentIndex = sectionNav.keys.indexOf(navSection)
    }

    SectionNav {
        id: sectionNav
        objectName: "sectionNav"
        x: root.marginX
        y: root.marginY
        u: root.u
        section: root.navSection
        blurSource: l0
        blurX: x
        blurY: y
        opacity: root.navShown ? 1 : 0
        visible: root.navShown || opacity > 0     // visible at once, so focus can be given in the same step
        enabled: root.navShown && !systemPanel.open
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
        onActivated: key => root.openSection(key)
        onDownRequested: root.leaveNavDown()
        onEdgeRequested: {
            if (batteryMore.visible && batteryMore.enabled) {
                Sfx.navigate()
                batteryMore.forceActiveFocus()
            }
        }
        onStepRequested: direction => root.stepSection(direction)
        onBackRequested: {
            if (root.pageOpen) {
                Sfx.back()
                root.closePage()
            }
        }
    }

    // App items (addApp): above home and pages, below the toasts, modals and overlay.
    Item {
        id: appLayer
        objectName: "appLayer"
        anchors.fill: parent
        z: 5
        visible: root.appOpen
    }

    // The page on top has finished its slide and fade (or no page is open): a popped page waits
    // for this before it is destroyed, so tearing it down (a Store grid) does not cost a frame of
    // the glide of the page that replaces it (T-349).
    function topSettled() {
        return slots.length === 0 || slots[slots.length - 1].settled
    }
    // Popped slots that are not destroyed yet (closePage adds them, reap() removes them).
    property var closingSlots: []
    function reapClosed() {
        for (const s of closingSlots)
            s.reapIfDone()
    }
    onSlotsChanged: Qt.callLater(reapClosed)

    // The probe of how long a page takes to open (T-349): one log line per page open.
    PageProbe {
        id: pageProbe
        objectName: "pageProbe"
        window: root.Window.window
    }

    // One per stack entry. The top slot is shown and enabled (it fades and slides in while
    // the shelf slides out); lower ones stay alive but hidden and disabled, so their state is
    // kept. A popped slot fades out, waits until the page on top has settled and one more frame
    // is on screen, then is destroyed.
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
            property bool reapPending: false
            property Item savedFocus: null
            // Shown and at rest: the fade-in and the slide have ended.
            readonly property bool settled: shown && opacity === 1 && slide.x === 0

            anchors.fill: parent
            opacity: shown ? 1 : 0
            visible: shown || opacity > 0
            enabled: shown
            Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
            transform: Translate {
                id: slide
                x: slot.shown ? 0 : Theme.pageSlide * root.u
                Behavior on x { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
            }
            onOpacityChanged: reapIfDone()
            onClosingChanged: reapIfDone()
            onSettledChanged: {
                if (!settled)
                    return
                pageProbe.settled(key)
                root.reapClosed()
            }

            // A page popped before its fade-in has progressed is already at opacity 0.
            function reapIfDone() {
                if (!closing || opacity !== 0 || reaped || reapPending || !root.topSettled())
                    return
                const win = slot.Window.window
                if (!win) {
                    reap()
                    return
                }
                reapPending = true
                win.update()                 // a still screen draws no frame by itself
            }
            function reap() {
                if (reaped)
                    return
                reaped = true
                root.slotCount -= 1
                root.closingSlots = root.closingSlots.filter(s => s !== slot)
                destroy()
            }
            // The frame with the settled page on top is on screen: now the popped page goes.
            Connections {
                target: slot.reapPending ? slot.Window.window : null
                function onFrameSwapped() { slot.reap() }
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
                if (savedFocus && savedFocus.enabled && savedFocus.visible)
                    savedFocus.forceActiveFocus()
                else if (page)
                    page.forceActiveFocus()
                savedFocus = null
            }
        }
    }

    // Pages parent their modals (PinPad, TextEntry) here: full screen, above pages and toasts,
    // below the picker and the Guide overlay.
    ModalLayer {
        id: modalLayer
        objectName: "modalLayer"
        anchors.fill: parent
        z: 15
        glassSource: l0          // the layer the glass sheets of the picker modals blur
    }

    // The devices behind the cluster's "N more" chip (T-301): a small modal in the modal layer.
    BatteryListModal {
        id: batteryList
        objectName: "batteryList"
        parent: modalLayer
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: root.u
        devices: batteryStatus.overflow
        onClosed: Qt.callLater(root.rescueFocus)      // its return target may be gone (nothing is hidden any more)
    }

    // "Keep this resolution?" (T-198): above the hint bar and every other modal.
    ModeConfirm {
        id: modeConfirm
        objectName: "modeConfirm"
        anchors.fill: parent
        z: 40
        u: root.u
    }

    // The screen saver and the dark screen (T-202): above everything, the OSD and the dialogs too.
    ScreenSaver {
        id: screenSaver
        objectName: "screenSaver"
        anchors.fill: parent
        z: 100
        u: root.u
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

    // The hint bar (04 §5): one instance above everything, saying what the buttons do on the
    // screen on top. Pages supply their own (`Page.hints`); modals and the Guide overlay are
    // decided here. Hidden while an app is focused (the app owns the screen), never focusable.
    readonly property Item activeItem: root.Window.window ? root.Window.window.activeFocusItem : null
    function hasAncestor(item, ancestor) {
        for (let p = item; p; p = p.parent) {
            if (p === ancestor)
                return true
        }
        return false
    }
    // A modal in the modal layer may say what its buttons do: the nearest ancestor of the focused
    // item (up to the layer) with a `modalHints` list (WallpaperPicker, ZonePicker). Others: B Cancel.
    function modalHintsOf(item) {
        for (let p = item; p && p !== modalLayer; p = p.parent) {
            if (p.modalHints !== undefined)
                return p.modalHints
        }
        return [{ button: "B", text: qsTr("Cancel") }]
    }
    readonly property var hintList: {
        if (modeConfirm.shown)
            return modeConfirm.modalHints
        if (systemPanel.open)
            return [{ button: "A", text: qsTr("Select") },
                    { button: "B", text: systemPanel.powerMode ? qsTr("Back") : qsTr("Close") }]
        if (appOpen)
            return []
        const keyboard = activeItem as TextEntry     // Back deletes a letter or cancels: the keyboard says which
        if (keyboard)
            return keyboard.entryHints
        if (hasAncestor(activeItem, modalLayer))
            return modalHintsOf(activeItem)
        if (hasAncestor(activeItem, pinPadInPicker))
            return [{ button: "B", text: qsTr("Cancel") }]
        if (!signedIn)
            return setupActive ? setup.hints : [{ button: "A", text: qsTr("Select") }]
        if (pageOpen)       // slots and pageStack are updated one after the other
            return slots.length > 0 ? (slots[slots.length - 1].page?.hints ?? []) : []
        return [{ button: "A", text: qsTr("Select") },
                { buttons: ["LB", "RB"], text: qsTr("Sections") }]
    }
    readonly property Item pinPadInPicker: picker.pinPadItem

    HintBar {
        id: hintBar
        objectName: "hintBar"
        z: 30
        x: root.marginX
        y: root.height - root.marginY - height
        u: root.u
        hints: root.hintList
        enabled: false
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
        Behavior on opacity { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
        onOpenChanged: {
            powerMode = false
            if (open)
                Sfx.open()
            else
                Sfx.close()
            if (open) {
                if (home.shown)
                    root.rememberHomeFocus()
                Power.refresh()
                actions.currentIndex = 0
                actions.forceActiveFocus()
            } else {
                guideHoldTimer.stop()
                root.focusCurrent()      // the page if one is open, else Home
            }
        }

        GlassShadow {
            objectName: "guideShadow"
            anchors.fill: guidePanel
            u: root.u
            radius: Theme.radiusL * root.u
            kind: "panel"
        }
        Rectangle {
            id: guidePanel
            objectName: "guidePanel"
            anchors.centerIn: parent
            width: panelColumn.width + 96 * root.u
            height: panelColumn.height + 96 * root.u
            radius: Theme.radiusL * root.u
            color: Theme.panel

            GlassLayers {
                objectName: "guideLayers"
                anchors.fill: parent
                u: root.u
                radius: parent.radius
                grain: false            // the panel is opaque, nothing is blurred behind it
            }
        }

        Column {
            id: panelColumn
            anchors.centerIn: parent
            spacing: Theme.spaceS * root.u
            Text { text: qsTr("System"); color: Theme.text; font.pixelSize: Theme.typeTitle * root.u; font.weight: Theme.weightDemiBold; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: qsTr("Image version %1").arg(root.version); color: Theme.textDim; font.pixelSize: Theme.typeBody * root.u; anchors.horizontalCenter: parent.horizontalCenter }
            FpsMeter { font.pixelSize: Theme.typeBody * root.u; anchors.horizontalCenter: parent.horizontalCenter; visible: systemPanel.visible }

            ListView {
                id: actions
                objectName: "systemActions"
                Accessible.role: Accessible.List
                Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("System")

                anchors.horizontalCenter: parent.horizontalCenter
                width: 520 * root.u
                height: contentHeight
                spacing: Theme.spaceS * root.u
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
                    } else if (systemPanel.powerMode && BackKey.isBackOrBackspace(event.key)) {
                        Sfx.back()
                        activate("back")
                    } else if (BackKey.isBackOrBackspace(event.key) || root.isGuideKey(event.key)) {
                        systemPanel.open = false
                    }
                    event.accepted = true      // modal: nothing leaks to the shelf underneath
                }

                delegate: Rectangle {
                    id: action
                    required property int index
                    required property var modelData
                    readonly property bool focused: ListView.isCurrentItem && actions.activeFocus

                    Accessible.role: Accessible.MenuItem
                    Accessible.name: modelData.label
                    width: actions.width
                    height: Theme.buttonHeight * root.u
                    radius: height / 2
                    color: focused ? Theme.focusFill : Theme.glass
                    border.width: focused ? Theme.focusRingWidth * root.u : 1
                    border.color: focused ? Theme.focusRing : Theme.glassBorder
                    Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: action.modelData.label
                        color: Theme.text
                        font.pixelSize: Theme.typeHeadline * root.u
                        font.weight: Theme.weightDemiBold
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

    // What the console does about heat: a toast and fewer effects when hot, a notice, stopping the
    // apps and a power-off when critical. Above the overlay and its confirmation, below the volume OSD.
    ThermalPolicy {
        id: thermalPolicy
        objectName: "thermalPolicy"
        anchors.fill: parent
        z: 26
        u: root.u
    }

    // Always-on version tag: the update/rollback checks read it off the screen.
    Text {
        id: versionTag
        objectName: "versionTag"
        anchors { right: parent.right; bottom: parent.bottom; margins: root.marginY / 2 }
        text: root.version
        color: Theme.text
        font.pixelSize: Theme.typeMicro * root.u
        font.weight: Theme.weightDemiBold
    }

    Badge {
        objectName: "mockBadge"
        visible: Profiles.mock
        // Bottom right, left of the version tag: the hint bar owns the bottom left.
        anchors { right: versionTag.left; rightMargin: Theme.spaceS * root.u; verticalCenter: versionTag.verticalCenter }
        u: root.u
        kind: "warning"
        text: qsTr("mock services")
    }

    // The ambient bed behind Home and the menus (T-227): silent while an app is in front and while the
    // screen saver, the dark screen or sleep is up; see AmbientLoop.
    AmbientLoop {
        id: ambientBed
        objectName: "ambientBed"
        wanted: !root.appOpen && !IdleClock.covered
    }

    // A chosen sound theme that fails the checker is ignored (the bundled one plays); say so once.
    Connections {
        target: SoundThemes
        function onActiveChanged() {
            if (SoundThemes.selectedBroken)
                Notifications.show(qsTr("The chosen sound theme can't be used. The standard one plays instead."), "warning")
        }
    }

    // The start-up cue, once, when the first frame is on screen.
    Connections {
        id: startupCue
        target: root.Window.window
        enabled: Sfx.startupCount === 0
        function onFrameSwapped() { Sfx.startup() }
    }

    VolumeOsd {
        objectName: "volumeOsd"
        z: 30
        u: root.u
        marginY: root.marginY
    }
}
