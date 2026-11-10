pragma Singleton
import QtQuick
import RuyaShell

// Short, non-blocking system messages. Anything may call Notifications.show(); the
// ToastLayer in Shell shows at most `maxVisible` at a time and each dismisses itself after
// `durationMs`. Extra messages wait in a queue, in order. Toasts are never focusable.
// A sticky toast (showSticky) stays until remove(key) is called.
QtObject {
    id: notifications

    readonly property int maxVisible: 3
    property int durationMs: Theme.toastMs          // overridable (tests use a short one)

    // Toasts on screen, oldest first: { toastId, text, kind, iconText, iconName, sticky, key }.
    readonly property ListModel model: ListModel {}
    readonly property int pendingCount: pending.length
    readonly property int shownCount: shown        // toasts that have appeared, ever

    // True while an app (or the launch splash) has the screen (set by Shell, T-147): only errors and
    // warnings are drawn then; every other toast waits in the queue until the shell is in front again
    // (02-shell 1.5). One that was on screen when the app took over goes back to the head of the queue.
    property bool appInFront: false
    onAppInFrontChanged: {
        if (appInFront)
            requeue()
        promote()
    }
    function eligible(kind) {
        return !appInFront || kind === "error" || kind === "warning"
    }
    function requeue() {
        const back = []
        for (let i = model.count - 1; i >= 0; --i) {
            const t = model.get(i)
            if (eligible(t.kind))
                continue
            back.unshift({ text: t.text, kind: t.kind, iconText: t.iconText, iconName: t.iconName,
                           sticky: t.sticky, key: t.key })
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

    // kind: "info" | "success" | "warning" | "error". iconText is a character drawn in the toast's colour;
    // iconName (T-199) is the name of a glyph of the icon font (Icon.qml) drawn instead, e.g. the
    // icon of the device the toast is about (DeviceIcons.iconFor).
    function show(text, kind, iconText, iconName) {
        const k = ["info", "success", "warning", "error"].includes(kind) ? kind : "info"
        pending = pending.concat([{ text: text, kind: k, iconText: iconText ?? "", iconName: iconName ?? "",
                                    sticky: false, key: "" }])
        promote()
    }

    // A toast that does not dismiss itself; it stays until remove(key). One per key: showing
    // the same key again replaces the earlier one.
    function showSticky(key, text, kind, iconText) {
        remove(key)
        const k = ["info", "success", "warning", "error"].includes(kind) ? kind : "info"
        pending = pending.concat([{ text: text, kind: k, iconText: iconText ?? "", iconName: "", sticky: true, key: key }])
        promote()
    }

    // Takes a sticky toast away, on screen or still waiting.
    function remove(key) {
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
            const at = pending.findIndex(p => eligible(p.kind))
            if (at < 0)
                break
            const next = pending[at]
            pending = pending.slice(0, at).concat(pending.slice(at + 1))
            model.append({ toastId: nextId++, text: next.text, kind: next.kind, iconText: next.iconText,
                           iconName: next.iconName, sticky: next.sticky, key: next.key })
            shown += 1
            // The cue says how much attention it wants: a sticky or warning toast has its own.
            if (next.sticky || next.kind === "warning" || next.kind === "error")
                Sfx.warning()
            else
                Sfx.notification()
        }
    }
}
