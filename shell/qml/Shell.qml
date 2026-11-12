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
    // toasts, modals and the Guide overlay. The shell API for a compositor: addApp(item, profile),
    // focusApp(item), removeApp(item) (also run when the item is destroyed).
    // One record {item, id, profile} per app item. A destroyed item must not be touched (QML
    // throws), so the list holds records and a guard child of each item removes its record on
    // destruction.
    // Whose app it is (T-164): `profile` is the profile the app runs as, "" for the shell's own
    // (a test client). An app is shown only while someone is signed in, and only to its own
    // profile; the others wait hidden, without focus (T-165 decides what a switch does to them).
    property var apps: []
    property Item focusedApp: null
    // The user sent the running apps behind Home (quick menu -> Home, T-147): they keep running and
    // keep their records (so `appRunning` stays true), but Home is in front until one is resumed
    // (Accept on its Running card) or a new window appears.
    property bool appsBehindHome: false
    readonly property var shownApps: apps.filter(r => appShownTo(r.profile))
    readonly property bool appOpen: shownApps.length > 0 && !appsBehindHome

    function appShownTo(profile) {
        return signedIn && (profile === "" || profile === Profiles.activeProfile)
    }

    // Shows and hides the app items as the signed-in profile changes, and moves the app focus
    // off an app that is hidden now (to the newest shown one, else none).
    onShownAppsChanged: {
        for (const r of apps)
            r.item.visible = appShownTo(r.profile)
        if (shownApps.length === 0)
            appsBehindHome = false
        if (shownApps.some(r => r.item === focusedApp))
            return
        const next = appsBehindHome ? null : fallbackFront()
        if (next === null && shownApps.length > 0)
            appsBehindHome = true               // only frozen apps left: Home, their Running cards bring them back (T-464)
        if (next !== focusedApp) {
            focusedApp = next
            if (!systemPanel.open)
                focusCurrent()
        }
    }
    // The update service restarts the console only when no app runs, also one left behind Home
    // or hidden from the signed-in profile (T-164 review: a game of a locked or switched-away
    // profile still runs). Input is reported by KeyRouter.onActivity.
    readonly property bool appRunning: apps.length > 0
    onAppRunningChanged: Update.noteActivity(appRunning)

    property int appSerial: 0
    property int appRaise: 0

    function recordOf(item) {
        return apps.find(r => r.item === item)
    }
    // The window of a running app of the signed-in profile, by its application id (appIdOf: the
    // instance's first), or undefined.
    function windowOf(appId) {
        return appId === "" ? undefined : apps.find(r => appIdOf(r) === appId && appShownTo(r.profile))
    }

    // The running instance (Session1 record) a window belongs to, or undefined (T-467): the one its
    // process belongs to (Session.instanceOfPid, T-459), else the one running the application id the
    // window gives itself in the window's profile, else the only running app of the signed-in profile
    // that no other window claims (`unclaimedInstance`: the Hub's pygame or SDL game whose window
    // names neither its Flatpak id nor a process Session1 can map). Everything about "the game behind
    // this window" (its app id, whether it is frozen, its Hub header, Resume, Play, Switch to) goes
    // through it, so they cannot disagree.
    function instanceOfWindow(record) {
        if (!record)
            return undefined
        if (record.instance !== "")
            return Session.running.find(r => r.instance === record.instance)
        const profile = record.profile !== "" ? record.profile : Profiles.activeProfile
        if (record.appId !== "") {
            const mine = Session.running.filter(r => r.appId === record.appId && r.profile === profile)
            const own = mine.find(r => r.state !== "stopping") ?? mine[0]
            if (own)
                return own
        }
        if (record.pending || !appShownTo(record.profile))
            return undefined                // the answer may still come; a hidden window is not guessed at
        const instance = unclaimedInstance(record)
        return instance !== "" ? Session.running.find(r => r.instance === instance) : undefined
    }

    // The application id of a window's app (T-459): that of the running instance it belongs to, else
    // the one the window gives itself, which is not always its Flatpak id ("python3.12" for a pygame game).
    function appIdOf(record) {
        if (!record)
            return ""
        const run = instanceOfWindow(record)
        return run ? run.appId : record.appId
    }

    // An app the Hub froze (or any frozen one) stays frozen until the player resumes it (T-464): it is
    // never the front app by itself, or HubPause would thaw it behind the window that took the screen.
    function appFrozen(record) {
        const run = instanceOfWindow(record)
        return run ? (run.frozen === true || hubPause.asked.includes(run.instance)) : false
    }

    // The app that takes the screen when the front one goes away: the newest shown app that is not
    // frozen, else none (Home).
    function fallbackFront() {
        for (let i = shownApps.length - 1; i >= 0; --i) {
            if (!appFrozen(shownApps[i]))
                return shownApps[i].item
        }
        return null
    }

    function addApp(item, profile) {
        if (!item || recordOf(item))
            return
        item.parent = appLayer
        item.anchors.fill = appLayer
        // The application id the window gives itself, when the compositor knows it (Compositor.qml),
        // and the running instance its client's process belongs to, asked of Session1 by the pid
        // (T-459; "" until the answer, and for a process of no instance; `pending` until it comes).
        const record = { item: item, id: ++appSerial, profile: profile ?? "", appId: item.appId ?? "",
                         pid: item.pid ?? 0, instance: "", pending: (item.pid ?? 0) > 0 }
        item.visible = appShownTo(record.profile)
        appGuard.createObject(item, { recordId: record.id, appItem: item })
        apps = apps.concat([record])
        // The window of the app being launched ends the splash (T-147); any other window is added
        // behind it and takes the screen when the splash is gone.
        if (launchState && appShownTo(record.profile) && (record.appId === "" || record.appId === launchState.appId))
            endLaunch(false)
        focusApp(item)
        if (record.pid > 0)
            Session.instanceOfPid(record.pid)
    }

    // Session1 answered for a window's process (T-459): on "ok" the record takes the instance (unless
    // the instance is known to run as another profile than the window's), and a window that is the
    // app being launched after all (its own app id did not say so) ends the splash. A Close game that
    // waited for this answer goes on.
    function instanceArrived(pid, status, instance) {
        const record = apps.find(r => r.pid === pid && r.pending)
        if (!record)
            return
        const run = Session.running.find(r => r.instance === instance)
        const ok = status === "ok" && instance !== "" && !(run && record.profile !== "" && run.profile !== record.profile)
        if (status !== "ok")
            console.warn("ruya-shell: InstanceOfPid", pid, "answered", status, "(the window goes by its app id)")
        else if (!ok)
            console.warn("ruya-shell: InstanceOfPid", pid, "named", instance, "of another profile: ignored")
        apps = apps.map(r => r.id === record.id ? Object.assign({}, r, { instance: ok ? instance : "", pending: false }) : r)
        if (closeWaitsFor === record.id) {
            closeWaitsFor = -1
            closeWaitTimer.stop()
            if (systemPanel.open && focusedApp === record.item)
                closeFrontGame(true)
        }
        if (!ok)
            return
        const st = launchState
        if (st && appShownTo(record.profile) && (st.instance === instance || appIdOf(recordOf(record.item)) === st.appId)) {
            endLaunch(false)
            focusApp(record.item)
        }
    }

    function focusApp(item) {
        const record = recordOf(item)
        if (!record || !appShownTo(record.profile))
            return
        appsBehindHome = false
        item.z = ++appRaise             // the newest on top: "Switch to" and Resume bring one to the front
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
        // (A destroyed item has already cleared focusedApp; null means "none" unless the apps are behind Home.)
        const wasFront = focusedApp === record.item || (!focusedApp && !appsBehindHome)
        apps = apps.filter(r => r.id !== id)
        if (!focusedApp || wasFront)
            focusedApp = appsBehindHome ? null : fallbackFront()
        // An app that was behind Home going away leaves the focus where the user put it.
        if (!systemPanel.open && (wasFront || focusedApp !== null))
            focusCurrent()              // the next app, else the page or Home
    }

    // The window named its application id after it was added (T-435): Electron sets the xdg
    // toplevel's app_id right after the toplevel exists, so the compositor hands the window over
    // with an empty one. The record takes the id, so Resume, "Switch to" and the quick menu find it.
    function appIdArrived(id, appId) {
        const record = apps.find(r => r.id === id)
        if (!record || appId === "" || record.appId === appId)
            return
        apps = apps.map(r => r.id === id ? Object.assign({}, r, { appId: appId }) : r)
    }

    Component {
        id: appGuard
        QtObject {
            id: guard
            property int recordId
            property var appItem: null
            property Connections follow: Connections {
                target: guard.appItem
                ignoreUnknownSignals: true          // a test stand-in may have no appId
                function onAppIdChanged() { root.appIdArrived(guard.recordId, guard.appItem.appId ?? "") }
            }
            Component.onDestruction: root.dropRecord(recordId)
        }
    }

    // Gives focus to whatever is on top: the focused app, else the open page, else Home.
    function focusCurrent() {
        if (!signedIn)
            return
        if (launchState || closeState)
            launchSplash.forceActiveFocus()         // input to the shell is locked while an app starts or closes
        else if (focusedApp)
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
            endLaunch(false)     // nobody to start it for; the app, if it starts, waits hidden (T-164)
            dropCloseScreen()
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
            Update.noteActivity(root.appRunning)
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
    // while an app item has the screen and the Guide overlay is closed. (The compositor maps a
    // window to its profile (T-164) but not to its instance; with two apps running the newest
    // is assumed.)
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
            Notifications.show(qsTr("Sound moved to %1").arg(Audio.defaultSinkName), "info")
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

    // ---- Launching, running and leaving apps (the call: T-386; the flow: T-147) ----
    // Play on a game (Home hero, a Recent card, the Games grid): the Library says what to start and
    // `launchApp` runs the launch: the splash comes up and takes the input (Guide still works),
    // Session1.Launch starts the app as the signed-in profile, and the splash goes when the app's
    // first window arrives (`addApp`). A failure answers with an error toast and the focus back
    // where Play was; after `launchStillMs` (20 s) without a window the splash says "Still starting"
    // and offers Close. One launch at a time: a second Accept while one is pending is ignored. An item
    // with no Session1 path (a Steam game: `Library.sessionAppId` is "") is never offered Play, so
    // nothing asks for it. The pending launch is { appId, title, picture, profile, ok, instance,
    // slow, restore }; its toasts name `title`, the request's own, never the raw launch spec.
    property var launchState: null
    property int launchStillMs: 20000
    readonly property bool launching: launchState !== null

    Connections {
        target: Library
        function onLaunchRequested(id, launchSpec) {
            const appId = Library.sessionAppId(id)
            if (appId === "") {
                console.warn("ruya-shell: no Session1 launch path for", id, "(" + launchSpec + ")")
                return
            }
            const item = Library.item(id)
            root.launchApp(appId, item.title ?? id, item.art ? (item.art.hero ?? item.art.tile ?? "") : "")
        }
    }

    function launchApp(appId, title, picture) {
        if (!signedIn || launchState)
            return
        if (closingAppIds.includes(appId)) {        // T-458: nothing to resume or start until it has ended
            Notifications.show(qsTr("%1 is still closing.").arg(Notifications.named(title)), "info")
            return
        }
        dropCloseScreen()               // another game is started from the Hub while one closes: its splash takes over
        const open = windowOf(appId)
        if (open) {                     // already on screen behind Home or the menu: bring it back
            focusApp(open.item)
            return
        }
        launchState = { appId: appId, title: title, picture: picture ?? "", profile: Profiles.activeProfile,
                        ok: false, instance: "", slow: false, restore: Window.activeFocusItem }
        launchStillTimer.restart()
        Session.launch(appId, Profiles.activeProfile)
        if (!systemPanel.open)
            focusCurrent()
    }

    // Ends the splash. `restoreFocus`: it failed, so the focus goes back to where Play was.
    function endLaunch(restoreFocus) {
        launchStillTimer.stop()
        const st = launchState
        launchState = null
        if (!restoreFocus || !st || systemPanel.open)
            return
        const target = st.restore
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        else
            focusCurrent()
    }

    Timer {
        id: launchStillTimer
        interval: root.launchStillMs
        onTriggered: {
            if (!root.launchState)
                return
            root.launchState = Object.assign({}, root.launchState, { slow: true })
            if (!systemPanel.open)
                launchSplash.focusClose()
        }
    }

    function titleOfApp(appId) {
        for (const it of Library.items) {
            if (Library.sessionAppId(it.id) === appId)
                return it.title
        }
        return Store.app(appId).name || appId
    }

    Connections {
        target: Session
        function onLaunchFinished(appId, profile, status, instance) {
            const st = root.launchState
            if (!st || st.appId !== appId || st.profile !== profile)
                return                      // not the launch the splash is for
            if (status === "ok") {
                root.launchState = Object.assign({}, st, { ok: true, instance: instance })
                return
            }
            const name = Notifications.named(st.title)
            const open = root.windowOf(appId)
            root.endLaunch(true)
            if (status === "already-running") {
                // Already there: bring it to the front, or, with no window yet, say so.
                if (open)
                    root.focusApp(open.item)
                else
                    Notifications.show(qsTr("%1 is already running").arg(name), "info")
                return
            }
            Notifications.show(qsTr("%1 could not be started. Try again.").arg(name), "error")
        }
        function onInstanceOfPidFinished(pid, status, instance) {
            root.instanceArrived(pid, status, instance)
        }
        function onStopFinished(instance, status) {
            if (status !== "ok" && status !== "unknown-instance")
                Notifications.show(qsTr("The game could not be closed. Try again."), "error")
            if (status !== "ok")                // nothing is closing (T-458): "unknown-instance" is that nothing runs
                root.stopRefused(instance)
        }
        function onRunningChanged() {
            // An instance that is no longer listed has ended: it is not closing any more.
            const listed = root.closingInstances.filter(i => Session.running.some(r => r.instance === i))
            if (listed.length !== root.closingInstances.length)
                root.closingInstances = listed
        }
        // An app that crashed or never got to run is the only exit the user hears about; a normal
        // quit (including a Stop from the shell) is silent. A launch that was waiting for it ends.
        function onAppExited(instance, appId, exitCode, reason) {
            const st = root.launchState
            const waiting = st !== null && st.appId === appId && (st.instance === "" || st.instance === instance)
            const title = waiting ? st.title : root.titleOfApp(appId)
            if (waiting)
                root.endLaunch(true)
            root.closeEnded(instance, appId, reason)
            if (reason !== "crashed" && reason !== "launch-failed")
                return
            const name = Notifications.named(title)
            Notifications.show(reason === "crashed" ? qsTr("%1 stopped unexpectedly. Try again.").arg(name)
                                                    : qsTr("%1 could not be started. Try again.").arg(name), "error")
        }
    }

    // The running record (Session1) of the app a window belongs to: by the instance of the window's
    // process (T-459), else by the application id the window gives itself, else (a client that names
    // none, as in tests) the newest of the profile's apps.
    function runningFor(record) {
        const mine = Session.running.filter(r => r.profile === Profiles.activeProfile && r.state !== "stopping")
        const run = instanceOfWindow(record)
        if (run)
            return mine.find(r => r.instance === run.instance)
        if (record && (record.instance !== "" || record.appId !== ""))
            return undefined
        return newestRunning()
    }

    // The newest running app of the signed-in profile (not one that is stopping), or undefined.
    function newestRunning() {
        const mine = Session.running.filter(r => r.profile === Profiles.activeProfile && r.state !== "stopping")
        let best
        for (const r of mine) {
            if (!best || r.started >= best.started)
                best = r
        }
        return best
    }

    // What the quick menu shows of the app in front (null: none, so the panel has no app part), and
    // the other apps it can switch to.
    readonly property var quickMenuApp: {
        if (!focusedApp)
            return null
        const record = recordOf(focusedApp)
        const run = runningFor(record)
        const appId = (run ? run.appId : "") || (record ? record.appId : "")
        const found = Library.items.find(i => appId !== "" && Library.sessionAppId(i.id) === appId)
        return { appId: appId,
                 title: appId !== "" ? titleOfApp(appId) : qsTr("Running app"),
                 picture: found && found.art ? (found.art.hero ?? found.art.tile ?? "") : "",
                 started: run ? run.started : Date.now() / 1000,
                 instance: run ? run.instance : "",
                 frozen: run ? (run.frozen ?? false) : false }
    }
    // The Hub's Switch to rows (T-467): every running app of the signed-in profile except the one in
    // front (frozen or not, with or without a window yet), then any other window whose app Session1 does
    // not list (a client of a test). { appId, title, hasWindow }.
    readonly property var quickMenuOthers: {
        if (!signedIn)
            return []
        const frontRun = quickMenuApp ? quickMenuApp.instance : ""
        const frontId = quickMenuApp ? quickMenuApp.appId : ""
        const rows = []
        for (const run of Session.running) {
            if (run.profile !== Profiles.activeProfile || run.state === "stopping" || run.instance === frontRun)
                continue
            rows.push({ appId: run.appId, title: titleOfApp(run.appId), hasWindow: windowOf(run.appId) !== undefined })
        }
        for (const r of shownApps) {
            const id = appIdOf(r)
            if (r.item !== focusedApp && id !== "" && id !== frontId && !rows.some(x => x.appId === id))
                rows.push({ appId: id, title: titleOfApp(id), hasWindow: true })
        }
        return rows
    }
    // The Hub's Recent rows (T-448, 02 §1.6): up to four of `Library.recent` that Session1 can start and
    // that are not running (the running ones are the app header and the Switch to rows); over an app
    // only two, so the tiles stay near the top.
    readonly property var quickMenuRecent: Library.recent
        .filter(i => Library.sessionAppId(i.id) !== "" && !runningAppIds.includes(Library.sessionAppId(i.id)))
        .slice(0, quickMenuApp ? 2 : 4)
        .map(i => ({ id: i.id, title: i.title ?? i.id, picture: i.art ? (i.art.tile ?? i.art.hero ?? "") : "" }))

    // Home from the quick menu: the apps keep running behind it and lose the focus; Home shows the
    // card of the one that was in front, with its Running pill, and the focus is on it.
    function sendAppsHome() {
        const appId = quickMenuApp ? quickMenuApp.appId : ""
        while (pageOpen)
            closePage()
        const found = Library.items.find(i => appId !== "" && Library.sessionAppId(i.id) === appId)
        const at = found ? recentIds.indexOf(found.id) : -1
        appsBehindHome = true
        focusedApp = null
        if (at >= 0) {
            recentRow.currentIndex = at
            homeSavedFocus = recentRow
        } else {
            homeSavedFocus = null
        }
        systemPanel.open = false        // -> focusCurrent(): Home
    }

    // A Hub panel's link to Settings (02 §1.6, level 3: it leaves the Hub): over an app it is Home's
    // route (the apps keep running behind), then the Settings page opens on `category`; Back from it
    // lands on Home. Pages already open are closed first, so Settings is never stacked on itself.
    function openSettingsFromHub(category) {
        if (quickMenuApp) {
            sendAppsHome()
        } else {
            while (pageOpen)
                closePage()
            systemPanel.open = false
        }
        Sfx.page()
        openPage("settings", { category: category })
    }

    // Close game: ask the service to stop the app in front and go Home; the card's pill goes when the
    // service reports AppExited. The instance is the window's own (its process's, T-459), else that of
    // the app id it gives itself (one already stopping is asked again, the service says "ok"). A window
    // that names no running app (Session1 could not tell and its own id is not its Flatpak id, or it
    // names none) closes the profile's one running app that no other window claims, and only when that
    // is unambiguous (`unclaimedInstance`); while Session1's answer for the window is on its way, Close
    // waits for it (at most `closeWaitMs`). With no instance nothing is stopped: a warning says so and
    // the Hub stays, never a silent Home with the game still running, and never the wrong game.
    property int closeWaitsFor: -1
    property int closeWaitMs: 2000
    Timer {
        id: closeWaitTimer
        interval: root.closeWaitMs
        onTriggered: {
            const id = root.closeWaitsFor
            root.closeWaitsFor = -1
            const record = root.apps.find(r => r.id === id)
            if (record && systemPanel.open && root.focusedApp === record.item)
                root.closeFrontGame(true)
        }
    }

    function closeFrontGame(answerLate) {
        const record = focusedApp ? recordOf(focusedApp) : undefined
        let instance = record ? record.instance : ""
        if (instance === "" && record && record.appId !== "") {
            const mine = Session.running.filter(r => r.profile === Profiles.activeProfile && r.appId === record.appId)
            const own = mine.find(r => r.state !== "stopping") ?? mine[0]
            instance = own ? own.instance : ""
        }
        if (instance === "" && record && record.pending && !answerLate) {
            closeWaitsFor = record.id       // instanceArrived goes on
            closeWaitTimer.restart()
            return
        }
        if (instance === "" && record)
            instance = unclaimedInstance(record)
        if (instance === "") {
            const title = quickMenuApp ? quickMenuApp.title : ""
            Notifications.show(title !== "" && title !== qsTr("Running app")
                               ? qsTr("Could not close %1.").arg(Notifications.named(title))
                               : qsTr("Could not close the running app."), "warning")
            return
        }
        const run = Session.running.find(r => r.instance === instance)
        const app = quickMenuApp
        closeState = { instance: instance, appId: run ? run.appId : (app ? app.appId : ""), title: app ? app.title : "",
                       picture: app ? app.picture : "" }
        closingInstances = closingInstances.includes(instance) ? closingInstances : closingInstances.concat([instance])
        closeSplashTimer.restart()
        Session.stop(instance)          // a frozen game: the service thaws it first, so it can quit (T-457)
        sendAppsHome()                  // Home behind the closing screen, the focus held by the screen
    }

    // ---- The closing screen (T-458, 02 §1.5) ----
    // Close game shows the splash in its closing mode over Home until the instance has ended
    // (AppExited, or Stop answering that nothing runs); after `closeSplashMs` Home comes back anyway
    // and the game's card says Closing (not Running) until the service has dropped the instance.
    // `closingInstances` are the instances Close asked to stop. A game the service reports "killed"
    // that is still listed after `killCheckMs` did not close: a warning, and the card is Running again.
    property var closeState: null                  // { instance, appId, title, picture } while the screen is up
    property var closingInstances: []
    property var killChecks: []                    // [{ instance, title }] waiting for the list to be refreshed
    property int closeSplashMs: 5000
    property int killCheckMs: 1000
    readonly property bool closingScreen: closeState !== null
    readonly property var closingAppIds: Session.running
        .filter(r => r.profile === Profiles.activeProfile && closingInstances.includes(r.instance)).map(r => r.appId)

    Timer {
        id: closeSplashTimer
        interval: root.closeSplashMs
        onTriggered: root.endClose()
    }
    Timer {
        id: killCheckTimer
        interval: root.killCheckMs
        onTriggered: {
            const checks = root.killChecks
            root.killChecks = []
            for (const c of checks) {
                if (!Session.running.some(r => r.instance === c.instance))
                    continue
                root.closingInstances = root.closingInstances.filter(i => i !== c.instance)
                Notifications.show(qsTr("%1 did not close. Restart the console if it keeps running.").arg(Notifications.named(c.title)), "warning")
            }
        }
    }

    function dropCloseScreen() {
        closeSplashTimer.stop()
        closeState = null
    }

    // Home in front again with the focus where Close left it (unless the Hub is open: it keeps the focus).
    function endClose() {
        if (!closeState)
            return
        dropCloseScreen()
        if (!systemPanel.open)
            focusCurrent()
    }

    // The service refused or could not Stop `instance`: it is not closing.
    function stopRefused(instance) {
        closingInstances = closingInstances.filter(i => i !== instance)
        if (closeState && closeState.instance === instance)
            endClose()
    }

    // AppExited for an instance Close asked to stop ends the screen; "killed" is checked once the list has
    // been refreshed (the kill itself needs no message, an instance still listed after it does).
    function closeEnded(instance, appId, reason) {
        if (closeState && closeState.instance === instance)
            endClose()
        if (reason === "killed" && closingInstances.includes(instance)) {
            killChecks = killChecks.concat([{ instance: instance, title: titleOfApp(appId) }])
            killCheckTimer.restart()
        }
    }

    // The running app of the signed-in profile a window that names none could be (T-459): the only one
    // (not stopping) that no other window shown to the profile claims, by its instance or its app id;
    // "" when there is none, more than one, or another window names none either.
    function unclaimedInstance(record) {
        const active = Profiles.activeProfile
        const others = apps.filter(r => r.id !== record.id && appShownTo(r.profile))
        const claimed = []
        for (const r of others) {
            if (r.instance !== "") {
                claimed.push(r.instance)
                continue
            }
            const run = r.appId !== "" ? Session.running.find(x => x.profile === active && x.appId === r.appId) : undefined
            if (!run)
                return ""                   // another window that names no running app: ambiguous
            claimed.push(run.instance)
        }
        const free = Session.running.filter(x => x.profile === active && x.state !== "stopping" && !claimed.includes(x.instance))
        return free.length === 1 ? free[0].instance : ""
    }

    // Opening the Hub over an app freezes it, returning to it thaws it (T-457, 02 §1.6).
    HubPause {
        id: hubPause
        hubOpen: systemPanel.open
        front: root.appOpen && root.quickMenuApp ? root.quickMenuApp.instance : ""
        pauseOn: DeviceSettings.pauseGamesInHub
        profile: root.signedIn ? Profiles.activeProfile : ""
    }

    function switchToApp(appId) {
        const record = windowOf(appId)
        if (!record) {                  // running, but its window has not come (T-467): the Hub stays
            Notifications.show(qsTr("%1 has no window yet.").arg(Notifications.named(titleOfApp(appId))), "info")
            return
        }
        focusApp(record.item)           // the menu is open: the focus moves when it closes
        systemPanel.open = false
    }

    // While an app (or the launch splash) has the screen only errors and warnings are drawn.
    Binding {
        target: Notifications
        property: "appInFront"
        value: root.appOpen || root.launching || root.closingScreen
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
        // An app in front covers it all: nothing is drawn or sampled behind it (T-376). Opacity 0, not
        // `visible: false`: the renderer draws nothing of a subtree at opacity 0
        // and L0 keeps its place in the scene graph. On the Dell the flat glass sheet after an app came
        // with the `visible` toggle (A/B 0.0.59 vs 0.0.60, T-387); the sheet's own cause is in GlassSheet.
        opacity: root.appOpen ? 0 : 1

        Backdrop {
            id: backdrop
            objectName: "backdrop"
            anchors.fill: parent
            tint: Profiles.active.avatar ?? Theme.defaultTint
            shown: !wallpaperLayer.covering && !IdleClock.covered   // a wallpaper covers it (T-208); the saver covers all (T-202)
            // An app in front (T-293) or the Home hero covers it: no frames for a drift nobody sees. And,
            // like the liquid pill's specular, it rests 30 s after the last input (LiquidGate): a still
            // page does not redraw 60 times a second for it (T-421).
            paused: root.focusedApp !== null || heroArt.covers || !LiquidGate.running
            blurred: root.pageOpen                                   // on pages the blobs are blurred like a wallpaper (T-421)
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
            // Settled on Home over no wallpaper: an art layer's fill is opaque (not `bare`), so nothing
            // of the backdrop under it can be seen (T-421).
            readonly property bool covers: opacity >= 1 && !wallpaperLayer.has

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
        // Fades out when an app takes the screen and is not drawn once settled: its glass would sample the hidden L0 (T-376).
        opacity: root.appOpen ? 0 : 1
        visible: root.signedIn && (!root.appOpen || opacity > 0)
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
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
        // False when not even the "+N" chip alone fits beside the shortest name (fitChips' last case): the
        // pill then reaches into the nav's gap. Where that starts depends on the fonts (tests, lead-9).
        readonly property bool fitsRoom: batteryWidth(chipCount, moreCompact) + fixedWidth + nameMin <= room

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
            primaryText: root.libraryEmpty ? qsTr("Open Store") : (root.heroClosing ? qsTr("Closing…") : root.heroRunning ? qsTr("Resume") : qsTr("Play"))
            primaryShown: root.libraryEmpty || Library.sessionAppId(root.heroItem.id ?? "") !== ""
            primaryDimmed: root.heroClosing
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
                running: root.runningAppIds.includes(Library.sessionAppId(modelData))
                         && !root.closingAppIds.includes(Library.sessionAppId(modelData))
                closing: root.closingAppIds.includes(Library.sessionAppId(modelData))
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
    // Running apps of the signed-in profile (T-147): their application ids, and the library items they
    // are (a string, so that the row is rebuilt only when this set changes, not on every Session1
    // state change). An app that is running but not among the recent ones comes first in the row.
    readonly property var runningAppIds: Session.running.filter(r => r.profile === Profiles.activeProfile).map(r => r.appId)
    readonly property string runningItemKey: Library.items.filter(i => runningAppIds.includes(Library.sessionAppId(i.id)))
                                                          .map(i => i.id).join("|")
    readonly property var recentIds: {
        const base = (recentIsFallback ? Library.items.slice(0, 8) : Library.recent).map(r => r.id)
        const extra = runningItemKey === "" ? [] : runningItemKey.split("|").filter(id => !base.includes(id))
        return extra.concat(base).slice(0, 8)
    }
    readonly property bool heroClosing: !libraryEmpty && closingAppIds.includes(Library.sessionAppId(heroItem.id ?? ""))
    readonly property bool heroRunning: !libraryEmpty && !heroClosing && runningAppIds.includes(Library.sessionAppId(heroItem.id ?? ""))
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
        if (Library.sessionAppId(id) === "")
            return                      // no Play for it (the button is not drawn); see playRecent
        Sfx.select()
        Library.launch(id)              // the splash is the feedback (launchApp); a running app comes back
    }

    // Accept on a Recent card: the card pulses, then the game starts (the hero follows the row). A
    // card with no launch path opens its details instead.
    function playRecent() {
        if (!libraryEmpty && Library.sessionAppId(heroItem.id) === "") {
            Sfx.select()
            openDetails()
            return
        }
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
    // is on screen, then is destroyed (at once if the window showed no frame while it closed).
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
            // The window has shown a frame since `closing` was set (T-460).
            property bool framesWhileClosing: false
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
            // The wait for one more frame keeps the teardown out of a glide that is on screen. A
            // window that has shown no frame since this slot began to close is not presenting (the
            // display is asleep: not one frameSwapped in a whole `shots` test, T-460) and update()
            // brings none either: there is nothing to protect, so the slot goes at once.
            function reapIfDone() {
                if (!closing || opacity !== 0 || reaped || reapPending || !root.topSettled())
                    return
                const win = slot.Window.window
                if (!win || !framesWhileClosing) {
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
            // Frames shown while closing tell that the window presents. Once the reap is pending, the
            // frame with the settled page on top is on screen: now the popped page goes.
            Connections {
                target: slot.closing && !slot.reaped ? slot.Window.window : null
                function onFrameSwapped() {
                    slot.framesWhileClosing = true
                    if (slot.reapPending)
                        slot.reap()
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
            return systemPanel.hints
        if (launching || closingScreen)
            return launchSplash.hints
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

    // The launch splash (T-147): over home, pages and the app layer until the app's first window.
    LaunchSplash {
        id: launchSplash
        objectName: "launchSplash"
        anchors.fill: parent
        z: 6
        u: root.u
        shown: root.launching || root.closingScreen
        closing: !root.launching && root.closingScreen
        appId: root.launchState ? root.launchState.appId : (root.closeState ? root.closeState.appId : "")
        title: root.launchState ? root.launchState.title : (root.closeState ? root.closeState.title : "")
        picture: root.launchState ? root.launchState.picture : (root.closeState ? root.closeState.picture : "")
        started: root.launchState ? root.launchState.ok : false
        slow: root.launchState ? root.launchState.slow : false
        guideKey: key => root.isGuideKey(key)
        onCloseRequested: {
            const instance = root.launchState ? root.launchState.instance : ""
            if (instance !== "")
                Session.stop(instance)
            root.endLaunch(true)
        }
    }

    // The performance overlay (T-469): the Hub's switch for the signed-in profile, a game in front (not Home,
    // not a page: appOpen), and nothing covering it: not the Hub, the launch or closing splash, the screen
    // saver or the dark screen. Above the game, below the toasts; the right corner also gives way to a toast.
    PerformanceReadout {
        id: perfReadout
        objectName: "perfOverlay"
        anchors.fill: parent
        z: 7
        u: root.u
        marginX: root.marginX
        marginY: root.marginY
        shown: root.signedIn && DeviceSettings.performanceOverlayProfiles[Profiles.activeProfile] === true
               && root.appOpen && root.focusedApp !== null && !systemPanel.open && !root.launching
               && !root.closingScreen && !IdleClock.covered
        rightBlocked: toasts.visibleCount > 0
    }

    // A deleted profile loses its overlay switch, so a profile created later with the same id starts with it off.
    Connections {
        target: Profiles
        function onDeleteFinished(id, status) {
            if (status === "ok")
                DeviceSettings.setPerformanceOverlay(id, false)
        }
    }

    // The quick menu (T-147; Guide opens it from Home, a page, a launch or over a running app; it
    // replaced the centred Guide card). Also shows the image version, which the update tests read.
    QuickMenu {
        id: systemPanel
        objectName: "systemPanel"
        z: 20
        u: root.u
        marginX: root.marginX
        marginY: root.marginY
        bottomReserve: hintBar.height + Theme.spaceM * root.u
        version: root.version
        app: root.quickMenuApp
        others: root.quickMenuOthers
        recent: root.quickMenuRecent
        guideKey: key => root.isGuideKey(key)

        onOpenChanged: {
            if (open) {
                if (home.shown && !root.closingScreen)      // the closing screen holds the focus: keep where Close left it
                    root.rememberHomeFocus()
                Power.refresh()
                present()
            } else {
                guideHoldTimer.stop()
                root.focusCurrent()      // the app, else the page if one is open, else Home
            }
        }
        onCloseRequested: open = false
        onHomeRequested: root.sendAppsHome()
        onCloseGameRequested: root.closeFrontGame(false)
        onSwitchToRequested: appId => root.switchToApp(appId)
        // A Recent row: close the Hub first (focus goes to the app or the page), then start the game
        // as Home's Play does (Library.launch -> launchApp: the splash).
        onLaunchRequested: id => {
            open = false
            Library.launch(id)
        }
        onSwitchProfileRequested: {
            open = false                     // first, so the game's Thaw goes out while the profile is signed in (T-457)
            Profiles.lock()                  // signedIn -> false; routeFocus() shows the picker
        }
        onSettingsRequested: category => root.openSettingsFromHub(category)
        onPowerRequested: action => powerConfirm.open(action)    // focus returns here if cancelled
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
        onClosed: if (systemPanel.open) systemPanel.actions.forceActiveFocus()
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
        quiet: systemPanel.open
        z: 30
        u: root.u
        marginY: root.marginY
    }
}
