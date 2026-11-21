pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// One .play package on a drive (05 §7.3 steps 2 and 3, 04 §5.4, RUY-98): opened as
// Shell.openPage("installPackage", { path }) from the sources list. It shows what Inspect found (art, trust,
// permissions, size) before a byte is copied, installs the package by controller, and ends in a result.
//
//  - Install is dimmed, with the reason under the buttons, when the service's verdict says the install would
//    fail (invalid, changed, revoked, unsupported, another developer, unsigned without developer mode).
//  - Install opens the confirm sheet; a profile that is not an admin's then enters an admin's PIN (the pad's
//    admin mode, as the Uninstall dialog). The page asks the service with `admin_approved`.
//  - The job's progress replaces the buttons. Back leaves the page and the job goes on; Cancel is explicit and
//    goes away from `committing` on. The result is a toast (Installed, Install cancelled) or a dialog (any
//    other status), and the page then offers Play.
Page {
    id: page

    // ---- What the page is about ----
    readonly property string path: params.path ?? ""
    property var info: null
    property bool loading: true

    title: info ? (info.name ?? "") : ""

    // What an update adds to the installed build's requests, only when the service could read them.
    readonly property var added: info && info.updateKnown === true ? (info.permissionsAdded ?? []) : []
    readonly property bool addsHighRisk: added.some(p => p.risk === "high")
    readonly property string addedText: added.map(p => PlayTrust.permissionWords(p.key, p.words)).join(", ")
    readonly property bool isAdmin: (Profiles.active.role ?? "") === "admin"
    readonly property string blocked: PlayCopy.blockReason(info)
    readonly property var trust: PlayTrust.describe(info)
    readonly property bool installed: info !== null && (info.installedBuild ?? 0) > 0 && info.installedBuild >= info.build
    // Installed, then put on the block list: it will not start; Remove takes the place of Play.
    readonly property bool revokedInstalled: installed && info.revoked === true
    // The Library item that starts the installed game (Play); absent until the Library has listed it.
    readonly property var libraryItem: info ? (Library.items.find(i => Library.sessionAppId(i.id) === appId) ?? null) : null

    // The job: a request of this page that is not finished, or a job the service runs for this path (also one
    // started by an earlier visit to this page: closing the page does not cancel).
    property bool requested: false
    readonly property var job: Play.jobs[path] ?? null
    // The installed app's Remove (keyed by its app id): from the call on (Play.inFlight), or a job the service
    // runs for it. Remove is not offered again while it runs, and it has no Cancel.
    readonly property var removeJob: appId !== "" ? (Play.jobs[appId] ?? null) : null
    readonly property bool removing: appId !== "" && (removeJob !== null || Play.inFlight.indexOf(appId) >= 0)
    readonly property bool working: requested || job !== null || removing
    readonly property string phase: job ? (job.phase ?? "") : removing ? "removing" : "staging"
    readonly property int percent: job ? job.percent : removeJob ? removeJob.percent : 0
    readonly property bool cancelShown: working && !removing && PlayCopy.cancelAllowed(phase)
    readonly property bool anyModal: confirmSheet.shown || signerSheet.shown || resultDialog.shown || pad.shown

    // "loading" | "install" | "play" | "busy" | "none": which buttons there are (keys only, so a progress tick
    // does not rebuild the focus order).
    readonly property string mode: loading ? "loading" : working ? (cancelShown ? "cancel" : "busy") : installed ? (revokedInstalled ? "remove" : "play") : info ? "install" : "none"

    // ---- Words ----
    readonly property real freeBytes: Storage.internal.valid ? Storage.internal.freeBytes : -1
    // What a disk-full install needs the player to free: the package's size less the free space.
    readonly property string toFree: info ? Storage.formatBytes(freeBytes >= 0 && info.size > freeBytes ? info.size - freeBytes : info.size) : ""

    // The facts of Information, in reading order; one with no value is left out.
    readonly property var facts: {
        const out = []
        if (!info)
            return out
        const add = (id, label, value) => {
            if (value !== undefined && value !== null && String(value) !== "")
                out.push({ id: id, label: label, value: String(value) })
        }
        add("developer", qsTr("Developer"), info.developer)
        add("version", qsTr("Version"), info.version)
        add("installedSize", qsTr("Installed size"), info.size > 0 ? Storage.formatBytes(info.size) : "")
        add("age", qsTr("Age rating"), PlayCopy.ageText(info.ageLabel))
        add("controller", qsTr("Controller"), PlayCopy.controllerText(info.controller))
        add("appId", qsTr("App ID"), info.id)
        return out
    }
    readonly property string factKeys: facts.map(f => f.id).join("|")
    readonly property var shotList: info ? (info.screenshots ?? []).map(p => ({ image: p, thumb: p, caption: "" })) : []

    // ---- Actions ----
    function inspect() {
        if (path !== "")
            Play.inspect(path)
    }

    function askInstall() {
        if (working || !info)
            return
        if (blocked !== "") {
            Sfx.error()         // the reason is on the page, under the buttons
            return
        }
        confirmSheet.open(info, installButton)
    }

    function confirmed() {
        if (isAdmin) {
            start()
            return
        }
        const admin = Profiles.profiles.find(p => p.role === "admin")
        if (!admin) {
            Sfx.error()
            Notifications.show(ProfileStatus.describe("not-allowed", 0, 0), "error")
            focusMain()
            return
        }
        pad.verifyAdmin(qsTr("Enter an admin's PIN"), admin.id)
    }

    function start() {
        if (working)
            return
        requested = true
        Play.install(path, true)
    }

    function cancelInstall() {
        Play.cancel(path)
    }

    function play() {
        if (libraryItem)
            Library.launch(libraryItem.id)
    }

    // The Flatpak id of the installed app (the key of its Remove job).
    readonly property string appId: info ? "play." + info.id : ""

    // Remove an installed game that was revoked: the Shell's Uninstall dialog (it asks an admin's PIN itself,
    // and asks Play to remove it). The context makes the Shell toast how it ended; this page re-inspects when
    // the job is over (`onJobFinished`).
    function removeGame() {
        if (info)
            uninstallConfirm?.open(appId, title, { itemId: "", surface: "package", title: title })
    }

    function press(which) {
        if (which === "install")
            askInstall()
        else if (which === "play")
            play()
        else if (which === "remove")
            removeGame()
        else if (which === "cancel")
            cancelInstall()
    }

    Component.onCompleted: {
        inspect()
        Qt.callLater(focusMain)
    }

    Connections {
        target: Play
        function onInspected(inspected, record) {
            if (inspected !== page.path)
                return
            page.info = record
            page.loading = false
            // The page starts on its main button (Install, or Play, or Cancel): the screenshot row holds the focus
            // flag by default, so a plain "nothing is focused" check would leave it there.
            Qt.callLater(page.focusStart)
            Qt.callLater(page.ensureFocus)
        }
        function onAnswered(op, key, status) {
            if (status === "ok")
                return
            if (op === "inspect" && key === page.path) {
                page.loading = false
                Sfx.error()
                Notifications.show(PlayCopy.methodStatusText(status), "error")
                page.backRequested()
            } else if (op === "install" && key === page.path) {
                page.requested = false
                Sfx.error()
                Notifications.show(PlayCopy.methodStatusText(status), "error")
                Qt.callLater(page.focusMain)
            } else if (op === "cancel" && key === page.path) {
                Sfx.error()
                Notifications.show(PlayCopy.methodStatusText(status), "error")
            } else if (op === "remove" && key === page.appId) {
                // Refused: the Shell toasts it (uninstallFinished); the page is no longer busy, so Remove is back.
                Qt.callLater(page.focusMain)
            }
        }
        function onJobFinished(key, status, kind) {
            if (kind === "remove" && key === page.appId) {
                // The app is gone (or still there, when Flatpak failed): what the page offers follows Inspect;
                // the busy page had no button, so the focus goes back to the main one.
                page.inspect()
                Qt.callLater(page.focusMain)
                return
            }
            if (key !== page.path)
                return
            page.requested = false
            page.inspect()          // the installed build, and what Install would end with now
            if (status === "ok") {
                Notifications.show(PlayCopy.installedToast(), "success", "", "", page.info ? page.info.name : "")
                Qt.callLater(page.focusMain)
            } else if (status === "cancelled") {
                Notifications.show(qsTr("Install cancelled"), "info")
                Qt.callLater(page.focusMain)
            } else {
                resultDialog.open(status, page.toFree)
            }
        }
        // An admin turned developer mode on or off: what Install would end with changes.
        function onDeveloperModeChanged() {
            page.inspect()
        }
    }

    // ---- The modals, in the shell's modal layer ----
    InstallConfirmSheet {
        id: confirmSheet
        objectName: "installConfirm"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
        onConfirmed: page.confirmed()
    }

    SignerSheet {
        id: signerSheet
        objectName: "installSigner"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
        info: page.info
    }

    InstallResultDialog {
        id: resultDialog
        objectName: "installResult"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
        onClosed: Qt.callLater(page.focusMain)
        onRetryRequested: page.confirmed()      // the same start as Install's: an admin's PIN again for a Standard profile
    }

    PinPad {
        id: pad
        objectName: "installPinPad"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
        onVerified: page.start()
        onCancelled: Qt.callLater(page.focusMain)
    }

    // ---- Focus: stops in reading order, rows of one or two; Up/Down between rows, Left/Right in a row ----
    function stopRows() {
        const rows = []
        if (trustRow.opensSheet && info)
            rows.push([trustRow])
        const buttons = [installButton, playButton, removeButton, cancelButton].filter(b => b.visible)
        if (buttons.length > 0)
            rows.push(buttons)
        if (shotsSection.visible && shotsSection.count > 0)
            rows.push([shotsSection.strip])
        if (permsBlock.visible)
            rows.push([permsBlock])
        for (let i = 0; i < factRepeater.count; i += 2)
            rows.push([factRepeater.itemAt(i), factRepeater.itemAt(i + 1)].filter(f => f))
        return rows.filter(r => r.length > 0)
    }

    // The button the page starts on: Install, Play, or Cancel while the job runs.
    function mainButton() {
        return [installButton, playButton, removeButton, cancelButton].find(b => b.visible) ?? null
    }

    // The first time the record is in and the page is on screen: onto the main button, once.
    property bool started: false
    function focusStart() {
        if (started || info === null || !page.activeFocus || !mainButton())
            return
        started = true
        focusMain()
    }
    onVisibleChanged: Qt.callLater(focusStart)

    function focusMain() {
        if (anyModal)
            return
        const main = mainButton()
        if (main)
            main.forceActiveFocus()
    }

    // After a stop has gone (or the record came): the focus goes to the main button. Only while the page itself has the
    // focus, so a page covered by another one is not pulled out from under it (T-356).
    function ensureFocus() {
        if (anyModal || !page.activeFocus)
            return
        const rows = stopRows()
        if (rows.length === 0 || rows.some(r => r.some(s => s.activeFocus)))
            return
        const main = mainButton()
        if (main)
            main.forceActiveFocus()
        else
            rows[0][0].forceActiveFocus()
    }

    readonly property string stopKey: mode + "#" + factKeys + "#" + (trustRow.opensSheet && info !== null) + "#" + shotList.length
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
        to.forceActiveFocus()
    }

    // ---- Scrolling: the column moves so the focused block's section is at the top ----
    property Item scrollTo: header
    readonly property real offset: scrollTo === header ? 0 : Math.max(0, Math.min(scrollTo.y, column.height - viewHeight))
    // `fact`: the stop only reads (permissions, information): Back is its one button.
    property bool onFactStop: false
    function stopFocused(section, fact) {
        scrollTo = section
        onFactStop = fact === true
    }

    readonly property real sideBleed: marginX
    readonly property real underHints: marginY + (Theme.glyphSize + Theme.spaceM) * u
    readonly property real viewHeight: viewport.height - underHints

    hints: cancelButton.activeFocus ? [{ action: "accept", text: qsTr("Cancel") }, { action: "back", text: qsTr("Back") }]
         : shotsSection.strip.activeFocus ? shotsSection.hints
         : onFactStop ? backOnlyHints
         // Select would do nothing here: Install is dimmed, or the job is past Cancel (RUY-809).
         : (installButton.activeFocus && blocked !== "") || (mode === "busy" && !trustRow.activeFocus) ? backOnlyHints : [
        { action: "accept", text: qsTr("Select") },
        { action: "back", text: qsTr("Back") }
    ]

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
        objectName: "installViewport"
        anchors.fill: parent
        anchors.leftMargin: -page.sideBleed
        anchors.rightMargin: -page.sideBleed
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
            objectName: "installColumn"
            x: page.sideBleed
            width: parent.width - 2 * page.sideBleed
            y: -page.offset
            spacing: Theme.spaceXxl * page.u
            Behavior on y {
                NumberAnimation { duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
            }

            // ---- Header ----
            Item {
                id: header
                width: parent.width
                height: Math.max(396 * page.u, left.height)      // token-ok: AppDetailPage's header, 04 §5.4

                Column {
                    id: left
                    width: 960 * page.u                          // token-ok: AppDetailPage's header, 04 §5.4
                    spacing: Theme.spaceS * page.u

                    Text {
                        objectName: "installLoading"
                        visible: page.loading
                        textFormat: Text.PlainText
                        text: qsTr("Loading…")
                        color: Theme.text
                        font.pixelSize: Theme.typeBody * page.u
                    }

                    Row {
                        id: badges
                        objectName: "installBadges"
                        spacing: Theme.spaceXs * page.u
                        height: 36 * page.u                      // token-ok: AppDetailPage's badge row
                        visible: page.info !== null

                        Badge {
                            objectName: "installTrustBadge"
                            u: page.u
                            solid: true             // a trust badge is always solid (04 §5.4)
                            kind: page.trust.kind ?? "error"
                            text: page.trust.badge ?? ""
                        }
                        Badge {
                            objectName: "installAgeBadge"
                            u: page.u
                            text: PlayCopy.ageText(page.info ? page.info.ageLabel : "")
                        }
                        Badge {
                            objectName: "installInstalledBadge"
                            visible: page.installed
                            u: page.u
                            kind: "success"
                            text: qsTr("Installed")
                        }
                    }

                    TrustRow {
                        id: trustRow
                        objectName: "installTrustRow"
                        visible: page.info !== null
                        u: page.u
                        info: page.info
                        onActivated: signerSheet.open(page.info, trustRow)
                        onActiveFocusChanged: if (activeFocus) page.stopFocused(header)
                    }

                    Text {
                        objectName: "installMeta"
                        visible: page.info !== null
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: PlayCopy.metaLine(page.info, page.info ? Storage.formatBytes(page.info.size) : "")
                        color: Theme.text
                        font.pixelSize: Theme.typeCaption * page.u
                    }

                    Text {
                        objectName: "installSummary"
                        visible: page.info !== null && text !== ""
                        width: parent.width
                        textFormat: Text.PlainText      // the package's own text
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        lineHeightMode: Text.FixedHeight
                        lineHeight: 40 * page.u         // token-ok: AppDetailPage's summary
                        text: page.info ? (page.info.summary ?? "") : ""
                        color: Theme.text
                        font.pixelSize: Theme.typeBody * page.u
                    }

                    // The buttons, or the progress in their place.
                    Item {
                        id: buttonArea
                        width: parent.width
                        visible: page.info !== null
                        height: (page.working ? progress.height : Theme.rowHeight * page.u) + Theme.spaceXl * page.u

                        Row {
                            id: buttonRow
                            y: Theme.spaceXl * page.u
                            spacing: Theme.spaceM * page.u
                            visible: !page.working

                            PrimaryButton {
                                id: installButton
                                objectName: "installButton"
                                visible: !page.working && !page.installed && page.info !== null
                                width: Math.max(280 * page.u, implicitWidth)        // token-ok: AppDetailPage's buttons
                                u: page.u
                                text: qsTr("Install")
                                dimmed: page.blocked !== ""
                                onAccepted: page.askInstall()
                                onActiveFocusChanged: if (activeFocus) page.stopFocused(header)
                            }
                            PrimaryButton {
                                id: playButton
                                objectName: "installPlay"
                                visible: !page.working && page.installed && !page.revokedInstalled
                                width: Math.max(280 * page.u, implicitWidth)        // token-ok: AppDetailPage's buttons
                                u: page.u
                                text: qsTr("Play")
                                onAccepted: page.play()
                                onActiveFocusChanged: if (activeFocus) page.stopFocused(header)
                            }
                            PrimaryButton {
                                id: removeButton
                                objectName: "installRemove"
                                visible: !page.working && page.revokedInstalled
                                width: Math.max(280 * page.u, implicitWidth)        // token-ok: AppDetailPage's buttons
                                u: page.u
                                text: PlayCopy.removeLabel()
                                onAccepted: page.removeGame()
                                onActiveFocusChanged: if (activeFocus) page.stopFocused(header)
                            }
                        }

                        Column {
                            id: progress
                            y: Theme.spaceXl * page.u
                            width: parent.width
                            visible: page.working
                            spacing: Theme.spaceS * page.u

                            ProgressBar {
                                objectName: "installProgress"
                                fillName: "installProgressFill"
                                width: 704 * page.u             // token-ok: 04 §5.4 Progress
                                u: page.u
                                trackColor: Theme.glassOpaque
                                value: page.percent / 100
                            }
                            Text {
                                objectName: "installPhase"
                                width: parent.width
                                textFormat: Text.PlainText
                                text: PlayCopy.progressLine(page.phase, page.percent)
                                color: Theme.text
                                font.pixelSize: Theme.typeBody * page.u
                            }
                            SecondaryButton {
                                id: cancelButton
                                objectName: "installCancel"
                                visible: page.cancelShown
                                width: Math.max(280 * page.u, implicitWidth)        // token-ok: AppDetailPage's buttons
                                u: page.u
                                text: qsTr("Cancel")
                                onAccepted: page.cancelInstall()
                                onActiveFocusChanged: if (activeFocus) page.stopFocused(header)
                            }
                        }
                    }

                    Text {
                        objectName: "installBlocked"
                        visible: page.info !== null && !page.working && (page.revokedInstalled || (!page.installed && page.blocked !== ""))
                        width: parent.width
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        text: page.revokedInstalled ? PlayCopy.revokedInstalledLine() : page.blocked
                        color: page.info && page.info.verdict === "bad-signature" ? Theme.errorText : Theme.text
                        font.pixelSize: Theme.typeBody * page.u
                    }
                }

                AppArt {
                    id: art
                    objectName: "installHero"
                    visible: page.info !== null
                    x: parent.width - width      // page x 1120..1824
                    width: 704 * page.u          // token-ok: AppDetailPage's hero, 04 §5.4
                    height: 396 * page.u         // token-ok: AppDetailPage's hero, 04 §5.4
                    radius: Theme.radiusM * page.u
                    u: page.u
                    appId: page.info ? page.info.id : ""
                    appName: page.title
                    picture: page.info && page.info.art ? (page.info.art.hero || page.info.art.card || page.info.art.icon || "") : ""
                }
            }

            // ---- Screenshots ----
            ScreenshotRow {
                id: shotsSection
                objectName: "installScreenshots"
                visible: page.shotList.length > 0
                u: page.u
                shots: page.shotList
                overlay: page.overlay
                reach: page.sideBleed
                strip.onActiveFocusChanged: if (strip.activeFocus) page.stopFocused(shotsSection)
            }

            // ---- This game can ----
            Column {
                id: permsSection
                objectName: "installPermissionsSection"
                width: parent.width
                spacing: Theme.spaceS * page.u
                visible: page.info !== null

                Heading { text: qsTr("This game can") }

                // An update says what it adds (as the sheet and AppDetailPage's "The update adds:").
                Text {
                    objectName: "installUpdateAdds"
                    visible: page.addedText !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    text: qsTr("The update adds: %1").arg(page.addedText)
                    color: page.addsHighRisk ? Theme.warningText : Theme.text
                    font.pixelSize: Theme.typeBody * page.u
                }

                SettingControl {
                    id: permsBlock
                    objectName: "installPermissions"
                    width: parent.width
                    height: permsGrid.height + 2 * Theme.spaceM * page.u
                    u: page.u
                    label: qsTr("This game can")
                    labelVisible: false
                    flat: true
                    cornerRadius: Theme.radiusL * page.u
                    hintKind: "info"
                    accessibleValue: permsGrid.summary
                    onActiveFocusChanged: if (activeFocus) page.stopFocused(permsSection, true)

                    PermissionList {
                        id: permsGrid
                        objectName: "installPermissionList"
                        x: Theme.spaceL * page.u
                        y: Theme.spaceM * page.u
                        width: permsBlock.width - 2 * Theme.spaceL * page.u
                        u: page.u
                        always: true
                        entries: page.info ? (page.info.permissions ?? []) : []
                    }
                }
            }

            // ---- Information ----
            Column {
                id: infoSection
                objectName: "installInformation"
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
                            objectName: "installFact_" + modelData
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
            }
        }
    }
}
