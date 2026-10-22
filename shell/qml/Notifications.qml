pragma Singleton
import QtQuick
import RuyaShell

// Short, non-blocking system messages. Anything may call Notifications.show(); the
// ToastLayer in Shell shows at most `maxVisible` at a time and each dismisses itself after
// `durationMs`. Extra messages wait in a queue, in order. Toasts are never focusable.
QtObject {
    id: notifications

    readonly property int maxVisible: 3
    property int durationMs: Theme.toastMs          // overridable (tests use a short one)

    // Toasts on screen, oldest first: { toastId, text, kind, iconText }.
    readonly property ListModel model: ListModel {}
    readonly property int pendingCount: pending.length
    readonly property int shownCount: shown        // toasts that have appeared, ever

    property var pending: []
    property int shown: 0
    property int nextId: 1

    // kind: "info" | "success" | "warning" | "error"
    function show(text, kind, iconText) {
        const k = ["info", "success", "warning", "error"].includes(kind) ? kind : "info"
        pending = pending.concat([{ text: text, kind: k, iconText: iconText ?? "" }])
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
        while (pending.length > 0 && model.count < maxVisible) {
            const next = pending[0]
            pending = pending.slice(1)
            model.append({ toastId: nextId++, text: next.text, kind: next.kind, iconText: next.iconText })
            shown += 1
        }
    }
}
