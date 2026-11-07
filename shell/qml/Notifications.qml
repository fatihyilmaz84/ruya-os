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
        while (pending.length > 0 && model.count < maxVisible) {
            const next = pending[0]
            pending = pending.slice(1)
            model.append({ toastId: nextId++, text: next.text, kind: next.kind, iconText: next.iconText,
                           iconName: next.iconName, sticky: next.sticky, key: next.key })
            shown += 1
        }
    }
}
