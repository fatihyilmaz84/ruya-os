pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// The game page (spec 02 §1.8, 04 §5 "Game page"; part 1: RUY-524): one page per Library or Store item,
// a header that changes with the state, then the sections This app can, Information and Manage (Your
// activity, Screenshots and About join in their own tickets). Opened as
// Shell.openPage("appDetail", { id }) with a Library item id (the Home hero, every Options menu's
// Details) or { appId } with a Flatpak app id (the Store); both show the same item.
Page {
    id: page

    // ---- What the page is about ----
    readonly property string paramAppId: params.appId ?? ""
    // The Library item: by id, or the one that starts the app id's Flatpak. Empty: a Store app that is not installed.
    readonly property var item: {
        const items = Library.items
        if ((params.id ?? "") !== "")
            return items.find(i => i.id === params.id) ?? ({})
        return paramAppId !== "" ? (items.find(i => Library.sessionAppId(i.id) === paramAppId) ?? ({})) : ({})
    }
    readonly property bool hasItem: item.id !== undefined
    readonly property string liveAppId: paramAppId !== "" ? paramAppId : (hasItem ? Library.sessionAppId(item.id) : "")
    // Kept once known: after Uninstall… the Library drops the item, and the page falls back to the Store record (Install).
    property string keptAppId: ""
    onLiveAppIdChanged: if (liveAppId !== "") keptAppId = liveAppId
    readonly property string appId: liveAppId !== "" ? liveAppId : keptAppId
    readonly property var app: appId === "" ? ({}) : (Store.catalogue.find(a => a.id === appId) ?? ({}))
    readonly property bool hasRecord: app.id !== undefined
    readonly property bool isSteam: hasItem && item.source === "steam"
    readonly property bool isApp: hasItem && item.kind === "app"
    // An item the Library lists but Session1 cannot start (a Steam game).
    readonly property bool noLaunch: hasItem && Library.sessionAppId(item.id) === ""
    readonly property var job: appId === "" ? null : (Store.jobs[appId] ?? null)
    readonly property bool installed: hasRecord ? (app.installed ?? false) : hasItem
    readonly property bool hasUpdate: hasRecord && installed && (app.updateAvailable ?? false)
    // False: the app needs a newer API level than this console has (RUY-156). An older service does not say.
    readonly property bool compatible: app.compatible ?? true
    readonly property var highRisk: ["all-devices", "host-files", "session-bus"]

    // A Standard profile needs an admin's PIN to install an app with a high-risk permission, and to
    // update one whose update adds a high-risk permission (03 §4.4).
    readonly property var newPermissions: installed && hasUpdate ? (app.newPermissions ?? []) : []
    readonly property bool hasHighRisk: (app.permissions ?? []).some(p => highRisk.indexOf(p) >= 0)
    readonly property bool addsHighRisk: newPermissions.some(p => highRisk.indexOf(p) >= 0)
    readonly property bool needsAdminPin: (installed ? addsHighRisk : hasHighRisk) && (Profiles.active.role ?? "") !== "admin"

    // The state of the item's game, from the rows of its Options menu (the Shell knows the sessions):
    // Play when it can start, Resume and Close when it runs, none of them while it closes.
    readonly property var rowIds: hasItem && optionRows ? optionRows("page", item.id).map(r => r.id) : []
    readonly property bool running: rowIds.includes("close")
    readonly property bool canResume: rowIds.includes("resume")
    readonly property bool closing: hasItem && !noLaunch && !running && !rowIds.includes("play")

    // The permissions are read from the service when the page opens; Install and Update wait for
    // them, because the PIN gate depends on them.
    property bool detailsReady: false
    property bool detailsFailed: false
    property bool actionPending: false

    property string pinStep: "idle"    // idle | pin | working
    property string adminId: ""
    // A request of this page is unanswered (it may be queued behind another job, with no progress
    // yet), or a job of this app runs: started here, by another page, or found by the Store when
    // the shell started (Store.jobs, T-191).
    property bool requested: false
    readonly property bool working: requested || job !== null
    property string kind: ""       // "install" | "update" | "uninstall" while requested
    property string errorText: ""

    // Which sections are there (the stops depend on these, not on the visibility, which a covered page loses too).
    // Your activity (RUY-532): for a signed-in profile that is not a Guest, on an installed item or one the
    // ledger has runs of; never for a Steam item (the ledger has no per-Steam-game runs). The block is a
    // focus stop only when there is something to open.
    property int ledgerTick: 0
    readonly property var ledger: Usage.game(ledgerTick >= 0 ? activityKey : "")
    readonly property string activityKey: appId !== "" ? appId : (hasItem ? item.id : "")
    Connections {
        target: Usage
        function onDataChanged() { page.ledgerTick++ }
    }
    readonly property bool activityShown: Profiles.activeProfile !== "" && (Profiles.active.role ?? "") !== "guest"
        && !isSteam && activityKey !== "" && (installed || (Usage.ready && (ledger.total ?? 0) > 0))
    readonly property bool activityStop: activityShown && Usage.ready && (ledger.total ?? 0) > 0
    onVisibleChanged: Usage.setWatching(page, visible)
    readonly property bool permsSectionShown: hasRecord && !isSteam && !detailsFailed
    readonly property bool permsListed: permsSectionShown && (app.permissions ?? []).length > 0
    readonly property bool manageShown: hasRecord && installed && !isSteam && !working
    readonly property bool uninstallShown: manageShown && !running && !closing

    // The Store does not answer about this item: GetApp failed, the service is away, or the Library lists a Flatpak the Store has no record of.
    readonly property bool storeDown: detailsFailed || (appId !== "" && !Store.available) || (!hasRecord && hasItem && appId !== "")

    title: hasRecord ? (app.name ?? "") : hasItem ? (item.title ?? "") : (appId.split(".").pop() ?? "")

    // ---- Header: the buttons by state (keys only: the models never change with a progress tick or the language) ----
    // "" none | install | update | play | resume | close | busy (a Store job) | closing
    readonly property string primaryKind: {
        if (working)
            return "busy"
        if (!installed)
            return hasRecord ? "install" : ""
        if (noLaunch)
            return ""
        if (!hasItem)       // installed, but the Library does not list it (yet): nothing to start, an update is the verb
            return hasUpdate ? "update" : ""
        if (closing)
            return "closing"
        if (running)
            return canResume ? "resume" : "close"
        return "play"
    }
    // The secondary buttons, "|" separated: update | close | retry.
    readonly property string secondaryKeys: {
        const keys = []
        if (!working && installed && !closing) {
            if (running && canResume)
                keys.push("close")
            if (primaryKind === "play" && hasUpdate)
                keys.push("update")
        }
        if (!working && storeDown && !noLaunch)
            keys.push("retry")
        return keys.join("|")
    }

    function primaryText() {
        switch (primaryKind) {
        case "install": return qsTr("Install")
        case "update": return qsTr("Update")
        case "play": return isApp ? qsTr("Open", "Button: start an app (a game says Play)") : qsTr("Play")
        case "resume": return qsTr("Resume")
        case "close": return isApp ? qsTr("Close app") : qsTr("Close game")
        case "busy": return phaseText()
        case "closing": return qsTr("Closing…")
        }
        return ""
    }

    // Dimmed (04 Buttons): unavailable now, but it keeps the focus and Accept still says why.
    function primaryDimmed() {
        switch (primaryKind) {
        case "busy":
        case "closing": return true
        case "install":
        case "update": return !compatible
        }
        return false
    }

    function secondaryText(key) {
        switch (key) {
        case "update": return qsTr("Update")
        case "close": return isApp ? qsTr("Close app") : qsTr("Close game")
        case "retry": return qsTr("Try again")
        }
        return ""
    }

    function press(key) {
        switch (key) {
        case "busy":
            Notifications.show(describe("busy"), "info")
            break
        case "install":
        case "update":
            primaryAction()
            break
        case "play":
        case "resume":
            if (hasItem && !noLaunch && !closing)
                Library.launch(item.id)
            break
        case "close":
            if (hasItem && runOption)
                runOption(item.id, "close")
            break
        case "retry":
            loadDetails()
            break
        }
    }

    // ---- Words ----
    function sourceKind(source) {
        return source === "official" ? "success" : source === "developer" ? "warning" : "info"
    }

    function sourceText(source) {
        return source === "official" ? qsTr("Official") : source === "developer" ? qsTr("Developer") : qsTr("Community")
    }

    function controllerText(level) {
        return level === "full" ? qsTr("Full controller support")
             : level === "partial" ? qsTr("Partial controller support")
             : qsTr("Needs a keyboard or mouse")
    }

    function ageText(rating) {
        // No rating in the metadata is not "all ages": the contract sends an empty rating.
        return rating === "all" ? qsTr("All ages") : !rating ? qsTr("Not rated") : qsTr("Ages %1").arg(rating)
    }

    function permissionText(id) {
        switch (id) {
        case "audio": return qsTr("Plays sound")
        case "gamepad": return qsTr("Uses game controllers")
        case "network": return qsTr("Uses the network")
        case "home-files": return qsTr("Reads and writes files in your home folder")
        case "host-files": return qsTr("Reads and writes all files on this device")
        case "all-devices": return qsTr("Accesses all devices")
        case "session-bus": return qsTr("Can control other programs on this device")
        }
        return id
    }

    // The words for a Freedesktop category; "" for one we do not show.
    function categoryText(id) {
        switch (id) {
        case "ActionGame": return qsTr("Action")
        case "AdventureGame": return qsTr("Adventure")
        case "ArcadeGame": return qsTr("Arcade")
        case "BoardGame": return qsTr("Board")
        case "CardGame": return qsTr("Card")
        case "LogicGame": return qsTr("Puzzle")
        case "RolePlaying": return qsTr("Role-playing")
        case "Shooter": return qsTr("Shooter")
        case "Simulation": return qsTr("Simulation")
        case "SportsGame": return qsTr("Sports")
        case "StrategyGame": return qsTr("Strategy")
        case "AudioVideo": return qsTr("Audio & video")
        case "Player": return qsTr("Player")
        case "Education": return qsTr("Education")
        case "Network": return qsTr("Internet")
        case "Utility": return qsTr("Utilities")
        }
        return ""
    }

    function dayText(unix) {
        const iso = TimeZone.formatIsoDate(unix * 1000)
        const ago = Usage.daysAgo(iso)
        return ago < 0 || ago > 6 ? Qt.locale(DeviceSettings.language).toString(new Date(iso + "T12:00:00"), "d MMM yyyy")
                                  : DurationText.dayWord(ago, iso)
    }

    function phaseText() {
        if (!page.job)
            return qsTr("Waiting…")
        switch (page.job.phase) {
        case "download": return qsTr("Downloading…")
        case "install": return qsTr("Installing…")
        case "update": return qsTr("Updating…")
        case "remove": return qsTr("Removing…")
        }
        return qsTr("Working…")
    }

    function describe(status) {
        switch (status) {
        case "network": return qsTr("No network connection. Check it and try again.")
        case "signature": return qsTr("This app could not be verified, so it was not installed.")
        case "missing-runtime": return qsTr("A part this app needs could not be found.")
        case "disk-full": return qsTr("There is not enough space on this device.")
        case "busy": return qsTr("Another change is running. Try again in a moment.")
        }
        return qsTr("Something went wrong. You can try again.")
    }

    // ---- Information: the facts, in reading order; one with no value is left out ----
    readonly property var facts: {
        const out = []
        const add = (id, label, value) => {
            if (value !== undefined && value !== null && String(value) !== "")
                out.push({ id: id, label: label, value: String(value) })
        }
        if (isSteam) {
            add("source", qsTr("Source"), qsTr("Steam"))
            add("steamId", qsTr("Steam app ID"), item.id.slice(item.id.indexOf(":") + 1))
            add("lastPlayed", qsTr("Last played"), (item.lastPlayed ?? 0) > 0 ? dayText(item.lastPlayed) : "")
            return out
        }
        const bytes = n => (n ?? 0) > 0 ? Storage.formatBytes(n) : ""
        add("developer", qsTr("Developer"), app.developer)
        add("source", qsTr("Source"), hasRecord ? sourceText(app.source ?? "") : qsTr("Flatpak"))
        add("version", qsTr("Version"), installed ? (app.installedVersion || app.version) : app.version)
        add("updated", qsTr("Updated"), (app.releaseDate ?? 0) > 0 ? Qt.locale(DeviceSettings.language).toString(new Date(TimeZone.formatIsoDate(app.releaseDate * 1000) + "T12:00:00"), "d MMM yyyy") : "")
        if (installed) {
            add("size", qsTr("Size on disk"), bytes(app.installedSize))
        } else {
            add("downloadSize", qsTr("Download size"), bytes(app.downloadSize))
            add("installedSize", qsTr("Installed size"), bytes(app.installedSize))
        }
        add("license", qsTr("Licence"), app.license)
        add("categories", qsTr("Categories"), (app.categories ?? []).map(c => categoryText(c)).filter(w => w !== "").slice(0, 3).join(", "))
        add("age", qsTr("Age rating"), hasRecord ? ageText(app.ageRating ?? "") : "")
        add("controller", qsTr("Controller"), hasRecord ? controllerText(app.controller ?? "none") : "")
        add("appId", qsTr("App ID"), appId)
        return out
    }
    readonly property string factKeys: facts.map(f => f.id).join("|")

    // ---- Actions ----
    function start(what) {
        if (page.working)
            return
        page.errorText = ""
        page.kind = what
        page.requested = true
        if (what === "install")
            Store.install(page.appId)
        else if (what === "update")
            Store.update(page.appId)
    }

    function startAdminPin() {
        const admin = Profiles.profiles.find(p => p.role === "admin")
        if (!admin) {
            page.errorText = ProfileStatus.describe("not-allowed", 0, 0)
            return
        }
        page.errorText = ""
        page.pinStep = "pin"
        page.adminId = admin.id
        pad.collect(qsTr("Enter an admin's PIN"), false)
    }

    function loadDetails() {
        page.detailsReady = false
        page.detailsFailed = false
        if (page.appId !== "")
            Store.loadApp(page.appId)
    }

    function primaryAction() {
        if (!page.compatible || page.working || page.pinStep !== "idle")
            return
        if (!page.detailsReady) {
            // Not known yet whether a PIN is needed: do it as soon as the permissions are in.
            page.actionPending = true
            if (page.detailsFailed)
                page.loadDetails()
            return
        }
        if (!page.installed) {
            if (page.needsAdminPin)
                page.startAdminPin()
            else
                page.start("install")
        } else if (page.hasUpdate) {
            if (page.needsAdminPin)
                page.startAdminPin()
            else
                page.start("update")
        }
    }

    // The Uninstall dialog asked the Store (it closed, the focus is back on its row).
    function uninstallStarted() {
        page.errorText = ""
        page.kind = "uninstall"
        page.requested = true
    }

    Component.onCompleted: {
        if (liveAppId !== "")
            keptAppId = liveAppId
        loadDetails()
        Usage.setWatching(page, visible)
        Qt.callLater(ensureFocus)
    }
    onHasUpdateChanged: loadDetails()      // an update just finished: its permissions are the app's now
    onAppIdChanged: loadDetails()

    Connections {
        target: Store
        function onAppLoaded(id) {
            if (id !== page.appId)
                return
            page.detailsReady = true
            if (page.actionPending) {
                page.actionPending = false
                page.primaryAction()
            }
        }
        function onAppLoadFailed(id) {
            if (id !== page.appId)
                return
            page.detailsFailed = true
            if (page.actionPending) {
                page.actionPending = false
                page.errorText = page.describe("failed")
            }
        }
        function onJobFinished(id, status) {
            if (id !== page.appId)
                return
            page.requested = false
            page.errorText = status === "ok" ? "" : page.describe(status)
        }
    }

    PinPad {
        id: pad
        objectName: "detailPinPad"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
        onCollected: pin => {
            if (page.pinStep === "pin") {
                page.pinStep = "working"
                Profiles.verifyAdmin(page.adminId, pin)
            }
        }
        onCancelled: {
            if (page.pinStep === "pin") {
                page.pinStep = "idle"
                page.focusFirst()
            }
        }
    }

    Connections {
        target: Profiles
        function onVerifyAdminFinished(adminId, status, attemptsLeft, retryAfterSecs) {
            if (page.pinStep !== "working")
                return
            page.pinStep = "idle"
            page.focusFirst()
            if (status === "ok") {
                page.start(page.installed ? "update" : "install")
            } else {
                Sfx.back()
                page.errorText = ProfileStatus.describe(status, attemptsLeft, retryAfterSecs)
            }
        }
    }

    // The Uninstall dialog is the Shell's (the Options menu uses it too, RUY-499; `Page.uninstallConfirm`).
    // It asks for an admin's PIN itself and starts the Store job; this page then follows the job as
    // for an install.
    Connections {
        target: page.uninstallConfirm
        function onStarted(id) {
            if (id === page.appId)
                page.uninstallStarted()
        }
    }

    // ---- Focus: stops in reading order, rows of one to three; Up/Down between rows, Left/Right in a row ----
    // The rows of focus stops now on the page: the buttons, This app can, the facts two by two, Uninstall.
    function stopRows() {
        const rows = []
        const buttons = []
        const primaryItem = primaryButtons.itemAt(0)
        if (primaryItem)
            buttons.push(primaryItem)
        for (let i = 0; i < secondaryButtons.count; ++i)
            buttons.push(secondaryButtons.itemAt(i))
        if (buttons.length > 0)
            rows.push(buttons)
        if (activityStop)
            rows.push([activitySection.block])
        if (permsListed)
            rows.push([permsBlock])
        for (let i = 0; i < factRepeater.count; i += 2)
            rows.push([factRepeater.itemAt(i), factRepeater.itemAt(i + 1)].filter(f => f))
        if (uninstallShown)
            rows.push([uninstallRow])
        return rows.filter(r => r.length > 0)
    }

    function focusFirst() {
        const rows = stopRows()
        if (rows.length > 0)
            rows[0][0].forceActiveFocus()
    }

    // After a stop has gone (a button hid, a fact came): the focus goes to the first stop. `focus`, not
    // forceActiveFocus(): a page covered by another one also hides things when its fade-out ends, and
    // forcing the focus then pulled it out of the page on top (T-356).
    function ensureFocus() {
        const rows = stopRows()
        if (rows.length === 0 || rows.some(r => r.some(s => s.focus)))
            return
        rows[0][0].focus = true
    }

    readonly property string stopKey: primaryKind + "#" + secondaryKeys + "#" + factKeys + "#" + activityStop + "#" + permsListed + "#" + uninstallShown
    onStopKeyChanged: Qt.callLater(ensureFocus)

    function moveFocus(dx, dy) {
        const rows = stopRows()
        let r = -1
        let c = -1
        for (let i = 0; i < rows.length && r < 0; ++i) {
            const at = rows[i].findIndex(s => s.activeFocus)
            if (at >= 0) {
                r = i
                c = at
            }
        }
        if (r < 0)
            return
        let to = null
        if (dy !== 0) {
            const next = r + dy
            if (next >= 0 && next < rows.length)
                to = rows[next][Math.min(c, rows[next].length - 1)]
        } else if (c + dx >= 0 && c + dx < rows[r].length) {
            to = rows[r][c + dx]
        }
        if (!to)
            return
        Sfx.navigate()
        moved = true
        to.forceActiveFocus()
    }

    // ---- Scrolling: the column moves so the focused block's section heading is at the top ----
    property Item scrollTo: header
    property bool onFactStop: false
    // The column follows the focus once the player has moved it: the focus the page starts with (the first fact
    // of a Steam game) leaves the header in view.
    property bool moved: false
    // The Your activity block is on the first screen, but the Page frame can leave its bottom edge and ring past
    // the viewport's clip (RUY-532): while it has the focus the column moves up by the overflow only.
    readonly property real activityOverflow: activitySection.block.activeFocus
        ? Math.max(0, activitySection.y + activitySection.height + (Theme.focusRingOffset + Theme.focusRingWidth) * u - viewHeight) : 0
    readonly property real offset: scrollTo === header ? activityOverflow
        : Math.max(0, Math.min(scrollTo.y, column.height - viewHeight))

    hints: activitySection.block.activeFocus ? activitySection.block.hints : onFactStop ? backOnlyHints : [
        { action: "accept", text: qsTr("Select") },
        { action: "back", text: qsTr("Back") }
    ]

    // A line of the header's status block.
    component Status: Text {
        width: 960 * page.u
        textFormat: Text.PlainText
        color: Theme.text
        font.pixelSize: Theme.typeCaption * page.u
        wrapMode: Text.Wrap
    }

    // The viewport clips the scrolled column, but a focus ring is drawn outside its item (focusRingOffset +
    // focusRingWidth): the viewport reaches that far past the content's left and right edges, and the column
    // is inset by as much, so a stop at x 96 (Play, Install) keeps its whole ring (owner, lead-27).
    readonly property real ringBleed: (Theme.focusRingOffset + Theme.focusRingWidth) * u
    // Below, the viewport reaches the screen's bottom edge (under the hint bar's band), so scrolled content
    // runs into the Shell's hint shade and fades instead of ending in a hard line (owner, lead-27). The
    // scroll still uses the room above the hints: `viewHeight`.
    readonly property real underHints: marginY + (Theme.glyphSize + Theme.spaceM) * u
    readonly property real viewHeight: viewport.height - underHints

    component Heading: Text {
        width: column.width
        textFormat: Text.PlainText
        color: Theme.text
        font.pixelSize: Theme.typeHeadline * page.u
        font.weight: Theme.weightDemiBold
        elide: Text.ElideRight
    }

    Item {
        id: viewport
        objectName: "detailViewport"
        anchors.fill: parent
        anchors.leftMargin: -page.ringBleed
        anchors.rightMargin: -page.ringBleed
        anchors.bottomMargin: -page.underHints
        clip: true

        Keys.onPressed: event => {
            const dx = event.key === Qt.Key_Left ? -1 : event.key === Qt.Key_Right ? 1 : 0
            const dy = event.key === Qt.Key_Up ? -1 : event.key === Qt.Key_Down ? 1 : 0
            if (dx === 0 && dy === 0)
                return
            page.moveFocus(dx, dy)
            event.accepted = true
        }

        Column {
            id: column
            objectName: "detailColumn"
            x: page.ringBleed
            width: parent.width - 2 * page.ringBleed
            y: -page.offset
            spacing: Theme.spaceXxl * page.u
            Behavior on y {
                NumberAnimation { duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
            }

            // ---- Header ----
            Item {
                id: header
                width: parent.width
                height: Math.max(396 * page.u, left.height)

                Column {
                    id: left
                    width: 960 * page.u

                    Row {
                        id: badges
                        spacing: Theme.spaceXs * page.u
                        height: 36 * page.u
                        visible: page.hasRecord || page.isSteam || page.running || page.hasUpdate

                        Badge {
                            id: sourceBadge
                            objectName: "detailSource"
                            visible: page.hasRecord || page.isSteam
                            u: page.u
                            text: page.hasRecord ? page.sourceText(page.app.source ?? "") : qsTr("Steam")
                            kind: page.hasRecord ? page.sourceKind(page.app.source ?? "") : "neutral"
                        }
                        Badge {
                            id: ageBadge
                            objectName: "detailAge"
                            visible: page.hasRecord
                            u: page.u
                            text: page.ageText(page.app.ageRating ?? "")
                        }
                        Badge {
                            id: runningBadge
                            objectName: "detailRunning"
                            visible: page.running
                            u: page.u
                            kind: "success"
                            text: qsTr("Running")
                        }
                        Badge {
                            id: updateBadge
                            objectName: "detailUpdateBadge"
                            visible: page.hasUpdate
                            u: page.u
                            kind: "info"
                            text: qsTr("Update ready")
                        }
                    }

                    Text {
                        objectName: "detailDeveloper"
                        visible: text !== ""
                        width: parent.width
                        topPadding: Theme.spaceS * page.u
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: page.hasRecord ? (page.app.developer ?? "") : page.isSteam ? qsTr("Installed through Steam") : ""
                        color: Theme.text
                        font.pixelSize: Theme.typeBody * page.u
                    }

                    Row {
                        objectName: "detailControllerLine"
                        visible: page.hasRecord
                        topPadding: Theme.spaceXs * page.u
                        height: 40 * page.u + topPadding
                        spacing: Theme.spaceXs * page.u

                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            u: page.u
                            name: "sports_esports"
                        }
                        Text {
                            objectName: "detailController"
                            anchors.verticalCenter: parent.verticalCenter
                            text: page.controllerText(page.app.controller ?? "none")
                            color: Theme.text
                            font.pixelSize: Theme.typeCaption * page.u
                        }
                    }

                    Text {
                        objectName: "detailSummary"
                        visible: page.hasRecord && text !== ""
                        width: parent.width
                        topPadding: Theme.spaceS * page.u
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        lineHeightMode: Text.FixedHeight
                        lineHeight: 40 * page.u
                        text: page.app.summary ?? ""
                        color: Theme.text
                        font.pixelSize: Theme.typeBody * page.u
                    }

                    // The buttons, or the message that there are none.
                    Item {
                        id: buttonArea
                        width: parent.width
                        visible: page.primaryKind !== "" || page.noLaunch
                        height: visible ? Theme.rowHeight * page.u + (Theme.spaceXl - Theme.spaceS) * page.u : 0

                        Row {
                            id: buttonRow
                            y: (Theme.spaceXl - Theme.spaceS) * page.u
                            spacing: Theme.spaceM * page.u

                            Repeater {
                                id: primaryButtons
                                model: page.primaryKind !== "" ? 1 : 0
                                delegate: PrimaryButton {
                                    objectName: "detailPrimary"
                                    width: Math.max(280 * page.u, implicitWidth)
                                    height: Theme.rowHeight * page.u
                                    u: page.u
                                    text: page.primaryText()
                                    dimmed: page.primaryDimmed()
                                    onAccepted: page.press(page.primaryKind)
                                    onActiveFocusChanged: if (activeFocus) page.stopFocused(header, false)
                                }
                            }
                            Repeater {
                                id: secondaryButtons
                                model: page.secondaryKeys !== "" ? page.secondaryKeys.split("|") : []
                                delegate: SecondaryButton {
                                    id: secondary
                                    required property string modelData
                                    objectName: "detail_" + modelData
                                    width: Math.max(280 * page.u, implicitWidth)
                                    height: Theme.rowHeight * page.u
                                    u: page.u
                                    text: page.secondaryText(modelData)
                                    onAccepted: page.press(modelData)
                                    onActiveFocusChanged: if (activeFocus) page.stopFocused(header, false)
                                }
                            }
                        }

                        // No launch path (a Steam game): a message in place of the buttons.
                        SettingRow {
                            objectName: "detailNoLaunch"
                            visible: page.noLaunch && page.primaryKind === ""
                            y: (Theme.spaceXl - Theme.spaceS) * page.u
                            width: parent.width
                            u: page.u
                            kind: "info"
                            enabled: false
                            label: qsTr("Start this game from Steam for now.")
                        }
                    }

                    Item {
                        width: parent.width
                        visible: page.working
                        height: visible ? 2 * Theme.spaceS * page.u : 0

                        ProgressBar {
                            objectName: "detailProgress"
                            fillName: "detailProgressFill"
                            visible: page.working
                            y: Theme.spaceS * page.u
                            width: parent.width
                            u: page.u
                            trackColor: Theme.blurMax > 0 ? Theme.glass : Theme.glassOpaque
                            value: (page.job ? page.job.percent : 0) / 100
                        }
                    }

                    Column {
                        id: status
                        width: parent.width
                        topPadding: Theme.spaceS * page.u
                        spacing: Theme.spaceXs * page.u

                        Status {
                            objectName: "detailPhase"
                            visible: page.working
                            text: qsTr("%1 % · It keeps going if you leave this page.").arg(page.job ? page.job.percent : 0)
                        }
                        Status {
                            objectName: "detailDownload"
                            visible: text !== "" && !page.working && !page.installed
                            readonly property string download: (page.app.downloadSize ?? 0) > 0 ? Storage.formatBytes(page.app.downloadSize) : ""
                            readonly property string disk: (page.app.installedSize ?? 0) > 0 ? Storage.formatBytes(page.app.installedSize) : ""
                            text: download !== "" && disk !== "" ? qsTr("Download %1 · %2 on disk").arg(download).arg(disk)
                                : download !== "" ? qsTr("Download %1").arg(download)
                                : disk !== "" ? qsTr("%1 on disk").arg(disk) : ""
                        }
                        Status {
                            objectName: "detailUpdateReady"
                            visible: page.hasUpdate && !page.working
                            text: (page.app.version ?? "") !== "" ? qsTr("Update ready: version %1").arg(page.app.version) : qsTr("Update ready")
                        }
                        // An app that needs a newer RuyaOS cannot be installed; one already installed keeps running.
                        Status {
                            objectName: "detailCompat"
                            visible: !page.compatible
                            text: page.installed ? qsTr("Needs a newer RuyaOS than this console has. It stays installed.") : qsTr("Needs a newer RuyaOS")
                            font.weight: Theme.weightDemiBold
                        }
                        Status {
                            objectName: "detailUpdateAdds"
                            visible: page.newPermissions.length > 0
                            text: qsTr("The update adds: %1").arg(page.newPermissions.map(p => page.permissionText(p)).join(", "))
                            color: page.addsHighRisk ? Theme.warningText : Theme.text
                        }
                        Status {
                            objectName: "detailAdminNote"
                            visible: page.needsAdminPin
                            text: page.installed ? qsTr("An admin's PIN is needed to update this app.")
                                                 : qsTr("An admin's PIN is needed to install this app.")
                        }
                        Status {
                            objectName: "detailStoreDown"
                            visible: page.storeDown && !page.noLaunch
                            text: qsTr("Store details are unavailable right now.")
                        }
                        Status {
                            objectName: "detailError"
                            visible: page.errorText.length > 0
                            text: page.errorText
                            color: Theme.errorText
                        }
                    }
                }

                AppArt {
                    id: art
                    objectName: "detailHero"
                    x: parent.width - width      // page x 1120..1824: the header starts at the content's left edge (x 96)
                    width: 704 * page.u
                    height: 396 * page.u
                    radius: Theme.radiusM * page.u
                    u: page.u
                    appId: page.appId !== "" ? page.appId : (page.item.id ?? "")
                    appName: page.title
                    picture: page.app.hero || (page.item.art ? (page.item.art.hero || page.item.art.tile || "") : "")
                }
            }

            // ---- Your activity ----
            GameActivity {
                id: activitySection
                objectName: "detailActivitySection"
                visible: page.activityShown
                u: page.u
                game: page.ledger
                ready: Usage.ready
                isApp: page.isApp
                onOpenRequested: page.openRequested("activityGame", { appId: page.activityKey })
                block.onActiveFocusChanged: if (block.activeFocus) page.stopFocused(header, false)
            }

            // ---- This app can ----
            Column {
                id: permsSection
                objectName: "detailPermissionsSection"
                width: parent.width
                spacing: Theme.spaceS * page.u
                // The Store's words; a Steam game and an item with no record have none. Not while GetApp failed.
                visible: page.permsSectionShown

                Heading { text: qsTr("This app can") }

                SettingControl {
                    id: permsBlock
                    objectName: "detailPermissions"
                    visible: page.permsListed
                    width: parent.width
                    height: permsGrid.height + 2 * Theme.spaceM * page.u
                    u: page.u
                    label: qsTr("This app can")
                    labelVisible: false
                    flat: true
                    cornerRadius: Theme.radiusL * page.u
                    hintKind: "info"
                    accessibleValue: (page.app.permissions ?? []).map(p => page.permissionText(p)).join(", ")
                    onActiveFocusChanged: if (activeFocus) page.stopFocused(permsSection, true)

                    Grid {
                        id: permsGrid
                        x: Theme.spaceL * page.u
                        y: Theme.spaceM * page.u
                        columns: 2
                        columnSpacing: Theme.spaceM * page.u
                        rowSpacing: Theme.spaceXs * page.u

                        Repeater {
                            model: page.app.permissions ?? []

                            delegate: Row {
                                id: perm

                                required property string modelData
                                readonly property bool risky: page.highRisk.indexOf(modelData) >= 0

                                objectName: "permission_" + modelData
                                width: (permsBlock.width - 2 * Theme.spaceL * page.u - Theme.spaceM * page.u) / 2
                                height: 44 * page.u
                                spacing: Theme.spaceS * page.u

                                Badge {
                                    objectName: "riskFlag_" + perm.modelData
                                    visible: perm.risky
                                    anchors.verticalCenter: parent.verticalCenter
                                    u: page.u
                                    kind: "warning"
                                    text: qsTr("High risk")
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, parent.width - (perm.risky ? 120 * page.u : 0))
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText      // an id the service sent shows raw
                                    text: page.permissionText(perm.modelData)
                                    color: perm.risky ? Theme.warningText : Theme.text
                                    font.pixelSize: Theme.typeBody * page.u
                                }
                            }
                        }
                    }
                }

                SettingRow {
                    objectName: "detailPermissionsNote"
                    visible: !permsBlock.visible
                    width: parent.width
                    u: page.u
                    kind: "info"
                    enabled: false
                    label: page.detailsReady ? qsTr("No special permissions.") : qsTr("Loading…")
                }
            }

            // ---- Information ----
            Column {
                id: infoSection
                objectName: "detailInformation"
                width: parent.width
                spacing: Theme.spaceS * page.u
                visible: page.facts.length > 0

                Heading { text: qsTr("Information") }

                Grid {
                    width: parent.width
                    columns: 2
                    columnSpacing: Theme.spaceM * page.u

                    Repeater {
                        id: factRepeater
                        model: page.factKeys !== "" ? page.factKeys.split("|") : []

                        delegate: SettingRow {
                            id: fact
                            required property string modelData
                            readonly property var shown: page.facts.find(f => f.id === modelData) ?? ({})
                            objectName: "fact_" + modelData
                            width: (infoSection.width - Theme.spaceM * page.u) / 2
                            u: page.u
                            kind: "info"
                            ruleBelow: true
                            label: shown.label ?? ""
                            value: shown.value ?? ""
                            onActiveFocusChanged: if (activeFocus) page.stopFocused(infoSection, true)
                        }
                    }
                }

                SettingRow {
                    objectName: "detailSteamPlayTime"
                    visible: page.isSteam
                    width: parent.width
                    u: page.u
                    kind: "info"
                    enabled: false
                    label: qsTr("Play time for Steam games is not counted yet.")
                }
            }

            // ---- Manage ----
            Column {
                id: manageSection
                objectName: "detailManage"
                width: parent.width
                spacing: Theme.spaceS * page.u
                // An installed Flatpak the Store knows, with no job on it.
                visible: page.manageShown

                Heading { text: qsTr("Manage") }

                SettingRow {
                    id: uninstallRow
                    objectName: "detailUninstall"
                    visible: page.uninstallShown
                    width: parent.width
                    u: page.u
                    kind: "action"
                    label: qsTr("Uninstall…")
                    onActivated: page.uninstallConfirm?.open(page.appId, page.title)
                    onActiveFocusChanged: if (activeFocus) page.stopFocused(manageSection, false)
                }

                SettingRow {
                    objectName: "detailManageNote"
                    visible: page.manageShown && !page.uninstallShown
                    width: parent.width
                    u: page.u
                    kind: "info"
                    enabled: false
                    label: page.isApp ? qsTr("Close the app to uninstall it.") : qsTr("Close the game to uninstall it.")
                }
            }
        }
    }

    // A stop took the focus: scroll to its section, and the hints of its kind.
    function stopFocused(section, fact) {
        if (moved)
            scrollTo = section
        onFactStop = fact
    }
}
