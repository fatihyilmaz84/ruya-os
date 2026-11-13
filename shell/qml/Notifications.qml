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
//   - quiet mode (NotificationCentre.quiet): no toast and no cue; the item is kept and counted;
//   - an app in front with "Don't interrupt games" on (the default): only critical items show, as
//     the compact toast; with it off, or with the Hub over the app, warnings, errors and critical ones;
//   - the screen saver (IdleClock.covered): a toast waits until the screen is back; it is never
//     drawn over the saver and wakes nothing.
QtObject {
    id: notifications

    readonly property int maxVisible: 3
    property int durationMs: Theme.toastMs          // overridable (tests use a short one)

    // Toasts on screen, oldest first: { toastId, text, kind, iconText, iconName, detail, footer,
    // footerButton, footerIcon, sticky, key, urgency }.
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
    readonly property bool quiet: NotificationCentre.quiet
    readonly property bool dontInterrupt: NotificationCentre.dontInterruptGames

    onAppInFrontChanged: reconsider()
    onOverlayOpenChanged: reconsider()
    onDontInterruptChanged: reconsider()
    onSaverOnChanged: promote()
    // Quiet mode turned on: what still waits is not shown any more (the items are kept).
    onQuietChanged: if (quiet) pending = []

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
                           detail: t.detail, footer: t.footer, footerButton: t.footerButton,
                           footerIcon: t.footerIcon, sticky: t.sticky, key: t.key, urgency: t.urgency })
            model.remove(i)
        }
        pending = back.concat(pending)
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
        keep("", text, k, iconName, detail, o)
        const link = linkFooter(o.actions)
        enqueue({ text: text, kind: k, iconText: iconText ?? "", iconName: iconName ?? "",
                  detail: detail ?? "", footer: link, footerButton: "", footerIcon: link !== "" ? "notifications" : "",
                  sticky: false, key: "", urgency: o.urgency ?? "normal" })
    }

    // A toast that does not dismiss itself; it stays until remove(key). One per key: showing
    // the same key again replaces the earlier one (its item in the centre too). `footer` is an
    // instruction line under the text; `footerButton` ("A", "B", ...) draws that button's glyph before
    // it. Without a footer of its own, an item with actions gets the link footer.
    function showSticky(key, text, kind, iconText, detail, footer, footerButton, options) {
        dropToast(key)
        const k = normalKind(kind)
        const o = options ?? {}
        keep(key, text, k, "", detail, o)
        const own = footer ?? ""
        const link = own === "" ? linkFooter(o.actions) : ""
        enqueue({ text: text, kind: k, iconText: iconText ?? "", iconName: "",
                  detail: detail ?? "", footer: link !== "" ? link : own, footerButton: link !== "" ? "" : (footerButton ?? ""),
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
                           footerButton: next.footerButton, footerIcon: next.footerIcon, sticky: next.sticky,
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
                                    iconName: item.icon ?? "", detail: item.body ?? "", footer: link, footerButton: "",
                                    footerIcon: link !== "" ? "notifications" : "", sticky: false, key: "",
                                    urgency: item.urgency ?? "normal" })
        }
        function onProfileChanged() {
            const keys = Object.keys(notifications.keyed)
            for (let i = 0; i < keys.length; ++i)
                NotificationCentre.post(notifications.keyed[keys[i]])
        }
    }
}
