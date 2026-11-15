pragma Singleton
import QtQuick
import RuyaShell

// Short, non-blocking system messages, and the one entry point of the notification centre
// (RUY-413, T-245 scope 4). Anything may call Notifications.show(); the item is kept in the
// signed-in profile's history (NotificationCentre, org.ruyaos.Notifications1) and, unless a quiet
// rule holds it back, shown as a toast: the ToastLayer in Shell shows at most `maxVisible` at a time
// and each dismisses itself after `durationMs`. Extra messages wait in a queue, in order. Toasts are
// never focusable. A sticky toast (showSticky) stays until remove(key) is called.
//
// Quiet rules (02-shell 5.1):
//   - quiet mode (NotificationCentre.quiet): no toast and no cue; the item is kept and counted (a
//     pinned one too); a sticky toast is held and shows again when quiet mode ends, if still on;
//   - an app in front with "Don't interrupt games" on (the default): only critical items show, as
//     the compact toast; with it off, or with the Hub over the app, warnings, errors and critical ones;
//   - the screen saver (IdleClock.covered): a toast waits until the screen is back; it is never
//     drawn over the saver and wakes nothing;
//   - quiet hours (RUY-414, NotificationCentre.quietHours): the same as quiet mode while the console's
//     clock is inside the span; the manual flag is not touched;
//   - a source turned off (NotificationCentre.sourcesEnabled): no item and no toast.
QtObject {
    id: notifications

    readonly property int maxVisible: 3
    // How long a toast stays: the profile's "Show each for" (NotificationCentre.toastSeconds, RUY-414);
    // tests assign a short one, which replaces the binding.
    property int durationMs: NotificationCentre.toastSeconds * 1000

    // Toasts on screen, oldest first: { toastId, text, kind, iconText, iconName, detail, footer,
    // footerAction, footerIcon, sticky, key, urgency }.
    readonly property ListModel model: ListModel {}
    readonly property int pendingCount: pending.length
    readonly property int shownCount: shown        // toasts that have appeared, ever
    // Toasts quiet mode kept off the screen (their items are in the centre).
    property int quietedCount: 0

    // True while an app (or the launch splash) has the screen (set by Shell, T-147): only some toasts
    // are drawn then (the rules above); every other toast waits in the queue until the shell is in
    // front again (02-shell 1.5). One that was on screen when the app took over goes back to the
    // head of the queue.
    property bool appInFront: false
    // The Hub is open over the app (set by Shell): the player looks at the shell, so "Don't interrupt
    // games" does not hold back its answers.
    property bool overlayOpen: false
    readonly property bool saverOn: IdleClock.covered
    // Quiet mode, by hand or by the schedule: the manual flag stays what the player set, quiet hours only
    // add to it (RUY-414).
    readonly property bool quiet: NotificationCentre.quiet || inQuietHours
    readonly property bool inQuietHours: quietNow(NotificationCentre.quietHours, clockNow)
    // "HH:MM" on the centre's clock in the console's zone; read again at each minute change.
    property string clockNow: ""
    Component.onCompleted: readClock()
    // "HH:MM" -> minutes since midnight; -1 when it is not a time.
    function minutesOf(text) {
        const m = /^([01][0-9]|2[0-3]):([0-5][0-9])$/.exec(String(text ?? ""))
        return m ? Number(m[1]) * 60 + Number(m[2]) : -1
    }
    // Is `clock` inside the schedule {enabled, from, to}? `to` may be before `from` (over midnight); from
    // equal to to is an empty span.
    function quietNow(hours, clock) {
        if (!hours || hours.enabled !== true)
            return false
        const from = minutesOf(hours.from)
        const to = minutesOf(hours.to)
        const now = minutesOf(clock)
        if (from < 0 || to < 0 || now < 0 || from === to)
            return false
        return from < to ? (now >= from && now < to) : (now >= from || now < to)
    }
    function readClock() {
        clockNow = TimeZone.formatClock(NotificationCentre.nowMs())
        // The minute timer runs only while a schedule is on (RUY-638).
        if (NotificationCentre.quietHours.enabled === true) {
            clockTimer.interval = TimeZone.msToNextTick(NotificationCentre.nowMs())
            clockTimer.restart()
        } else {
            clockTimer.stop()
        }
    }
    readonly property Connections scheduleLink: Connections {
        target: NotificationCentre
        function onSettingsChanged() { notifications.readClock() }
    }
    // One single-shot timer for the schedule, armed for the next minute; it does not depend on the Hub
    // (the Hub's budgets: nothing polls while it is hidden).
    readonly property Timer clockTimer: Timer {
        repeat: false
        onTriggered: notifications.readClock()
    }
    // The zone or the clock was set (a test pins it): read again at once.
    readonly property Connections clockLink: Connections {
        target: TimeZone
        function onClockTextChanged() { notifications.readClock() }
        function onTimezoneChanged() { notifications.readClock() }
    }
    // The end of the span while quiet hours hold ("" otherwise): the Quiet mode rows name it.
    readonly property string quietUntil: inQuietHours ? NotificationCentre.quietHours.to : ""

    // Does the profile want items of this source? `source`: "system" | "updates" | "devices" | "store" |
    // "app" (then `appId`). A source that is not listed is on (SourcesEnabled).
    function sourceOn(source, appId) {
        const key = source === "app" ? "app:" + (appId ?? "") : source
        return NotificationCentre.sourcesEnabled[key] !== false
    }
    readonly property bool dontInterrupt: NotificationCentre.dontInterruptGames

    onAppInFrontChanged: reconsider()
    onOverlayOpenChanged: reconsider()
    onDontInterruptChanged: reconsider()
    onSaverOnChanged: promote()
    // Quiet mode turned on: what still waits is not shown any more (the items are kept), and a sticky
    // toast (a lasting state: the restart notice) leaves the screen but is held; turned off, the held
    // ones whose state still lasts come back (RUY-413).
    onQuietChanged: {
        if (quiet) {
            let hold = pending.filter(p => p.sticky)
            for (let i = model.count - 1; i >= 0; --i) {
                const t = model.get(i)
                if (!t.sticky)
                    continue
                hold.unshift({ text: t.text, kind: t.kind, iconText: t.iconText, iconName: t.iconName,
                               detail: t.detail, footer: t.footer, footerAction: t.footerAction,
                               footerIcon: t.footerIcon, sticky: true, key: t.key, urgency: t.urgency })
                model.remove(i)
            }
            held = held.concat(hold)
            pending = []
        } else {
            const back = held.filter(h => h.key in keyed)
            held = []
            back.forEach(h => enqueue(h))
        }
    }
    // Sticky toasts quiet mode keeps off the screen until it ends.
    property var held: []

    function reconsider() {
        requeue()
        promote()
    }

    function eligible(entry) {
        if (saverOn)
            return false
        if (!appInFront)
            return true
        if (entry.urgency === "critical")
            return true
        if (dontInterrupt && !overlayOpen)
            return false
        return entry.kind === "error" || entry.kind === "warning"
    }
    function requeue() {
        const back = []
        for (let i = model.count - 1; i >= 0; --i) {
            const t = model.get(i)
            if (eligible(t))
                continue
            back.unshift({ text: t.text, kind: t.kind, iconText: t.iconText, iconName: t.iconName,
                           detail: t.detail, footer: t.footer, footerAction: t.footerAction,
                           footerIcon: t.footerIcon, sticky: t.sticky, key: t.key, urgency: t.urgency })
            model.remove(i)
        }
        pending = back.concat(pending)
    }

    // How long ago an item came: "Just now", "2 min ago", the local time today (T-213), "Yesterday",
    // "3 days ago". `nowMs` is the clock it is read against (NotificationCentre.nowMs()). The centre sheet
    // and the Hub's Notifications panel both say it this way.
    function ageText(ms, nowMs) {
        const diff = Math.max(0, nowMs - ms)
        if (diff < 60000)
            return qsTr("Just now")
        if (diff < 3600000)
            return qsTr("%n min ago", "", Math.floor(diff / 60000))
        const day = TimeZone.formatIsoDate(ms)
        if (day === TimeZone.formatIsoDate(nowMs))
            return TimeZone.formatClock(ms)
        if (day === TimeZone.formatIsoDate(nowMs - 86400000))
            return qsTr("Yesterday")
        return qsTr("%n days ago", "", Math.max(2, Math.round(diff / 86400000)))
    }

    // A name that came from outside (a game, an app, a device) as it may appear in a toast: at most
    // `max` characters, cut with an ellipsis, so the rest of the sentence always survives (04 section 6).
    function named(name, max) {
        const limit = max ?? 30
        const text = String(name ?? "")
        return text.length > limit ? text.slice(0, limit - 1).replace(/\s+$/, "") + "…" : text
    }

    property var pending: []
    property int shown: 0
    property int nextId: 1
    // The keyed states posted to the centre ({ key: entry }), so a profile that signs in later gets
    // them too (the restart notice, thermal critical); remove(key) ends them.
    property var keyed: ({})

    function normalKind(kind) {
        return ["info", "success", "warning", "error"].includes(kind) ? kind : "info"
    }

    // The item for the centre (NotificationCentre.post). `options` (all optional): source ("system",
    // "updates", "devices", "store"), urgency ("low", "normal", "critical"), actions ([{ id, label }],
    // at most two, the first the main one; Shell.runNotificationAction runs them), pinned, appId.
    function keep(key, text, kind, iconName, detail, options) {
        const o = options ?? {}
        const entry = { key: key, source: o.source ?? "system", appId: o.appId ?? "", kind: kind,
                        title: String(text ?? ""), body: String(detail ?? ""), icon: iconName ?? "",
                        actions: (o.actions ?? []).slice(0, 2), urgency: o.urgency ?? "normal",
                        pinned: o.pinned === true }
        if (key !== "") {
            const next = Object.assign({}, keyed)
            next[key] = entry
            keyed = next
        }
        NotificationCentre.post(entry)
    }

    // The footer of a toast whose item has actions: where to find them (RUY-413).
    function linkFooter(actions) {
        return actions && actions.length > 0 ? qsTr("%1 is in Notifications").arg(actions[0].label) : ""
    }

    function enqueue(entry) {
        if (quiet) {
            quietedCount += 1           // no toast, no cue: the item is in the centre and counted
            if (entry.sticky)
                held = held.filter(h => h.key !== entry.key).concat([entry])
            return
        }
        pending = pending.concat([entry])
        promote()
    }

    // kind: "info" | "success" | "warning" | "error". iconText is a character drawn in the toast's colour;
    // iconName (T-199) is the name of a glyph of the icon font (Icon.qml) drawn instead, e.g. the
    // icon of the device the toast is about (DeviceIcons.iconFor). `text` is the title (one line, the
    // fact); `detail` (RUY-412) is an optional second line. Both are drawn as plain text. `options`:
    // see keep().
    function show(text, kind, iconText, iconName, detail, options) {
        const k = normalKind(kind)
        const o = options ?? {}
        if (!sourceOn(o.source ?? "system", o.appId))
            return                      // a source turned off makes no toast and keeps no item (RUY-414)
        keep("", text, k, iconName, detail, o)
        const link = linkFooter(o.actions)
        enqueue({ text: text, kind: k, iconText: iconText ?? "", iconName: iconName ?? "",
                  detail: detail ?? "", footer: link, footerAction: "", footerIcon: link !== "" ? "notifications" : "",
                  sticky: false, key: "", urgency: o.urgency ?? "normal" })
    }

    // A toast that does not dismiss itself; it stays until remove(key). One per key: showing
    // the same key again replaces the earlier one (its item in the centre too). `footer` is an
    // instruction line under the text; `footerAction` (an action: "accept", "back", ...) draws its glyph before
    // it. Without a footer of its own, an item with actions gets the link footer.
    function showSticky(key, text, kind, iconText, detail, footer, footerAction, options) {
        dropToast(key)
        const k = normalKind(kind)
        const o = options ?? {}
        if (!sourceOn(o.source ?? "system", o.appId))
            return
        keep(key, text, k, "", detail, o)
        const own = footer ?? ""
        const link = own === "" ? linkFooter(o.actions) : ""
        enqueue({ text: text, kind: k, iconText: iconText ?? "", iconName: "",
                  detail: detail ?? "", footer: link !== "" ? link : own, footerAction: link !== "" ? "" : (footerAction ?? ""),
                  footerIcon: link !== "" ? "notifications" : "", sticky: true, key: key, urgency: o.urgency ?? "normal" })
    }

    // Takes a sticky toast away, on screen or still waiting, and ends its item in the centre.
    function remove(key) {
        dropToast(key)
        if (key in keyed) {
            const next = Object.assign({}, keyed)
            delete next[key]
            keyed = next
            NotificationCentre.withdraw(key)
        }
    }

    function dropToast(key) {
        pending = pending.filter(p => p.key !== key)
        held = held.filter(h => h.key !== key)
        for (let i = 0; i < model.count; ++i) {
            if (model.get(i).key === key) {
                model.remove(i)
                break
            }
        }
        promote()
    }

    function dismiss(toastId) {
        for (let i = 0; i < model.count; ++i) {
            if (model.get(i).toastId === toastId) {
                model.remove(i)
                break
            }
        }
        promote()
    }

    function promote() {
        while (model.count < maxVisible) {
            const at = pending.findIndex(p => eligible(p))
            if (at < 0)
                break
            const next = pending[at]
            pending = pending.slice(0, at).concat(pending.slice(at + 1))
            model.append({ toastId: nextId++, text: next.text, kind: next.kind, iconText: next.iconText,
                           iconName: next.iconName, detail: next.detail, footer: next.footer,
                           footerAction: next.footerAction, footerIcon: next.footerIcon, sticky: next.sticky,
                           key: next.key, urgency: next.urgency })
            shown += 1
            if (!NotificationCentre.sounds)
                continue
            // The cue says how much attention it wants: a sticky or warning toast has its own.
            if (next.sticky || next.kind === "warning" || next.kind === "error")
                Sfx.warning()
            else
                Sfx.notification()
        }
    }

    // An app's notification arrived through the bridge (RUY-88): it is kept already, so only the toast.
    // And when someone signs in (or switches), the lasting states are theirs too.
    readonly property Connections centreLink: Connections {
        target: NotificationCentre
        function onArrived(item) {
            const actions = item.actions ?? []
            const link = notifications.linkFooter(actions)
            notifications.enqueue({ text: item.title, kind: notifications.normalKind(item.kind), iconText: "",
                                    iconName: item.icon ?? "", detail: item.body ?? "", footer: link, footerAction: "",
                                    footerIcon: link !== "" ? "notifications" : "", sticky: false, key: "",
                                    urgency: item.urgency ?? "normal" })
        }
        function onSettingsChanged() { notifications.readClock() }      // the schedule was set
        function onProfileChanged() {
            const keys = Object.keys(notifications.keyed)
            for (let i = 0; i < keys.length; ++i)
                NotificationCentre.post(notifications.keyed[keys[i]])
        }
    }
}
