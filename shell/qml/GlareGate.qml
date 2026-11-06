pragma Singleton
import QtQuick

// When a card may play its focus glare (04 §3.8): focus entering a card plays it unless focus
// entered another card less than `Theme.glareGapMs` ago, so a fast scroll stays calm. Every entry,
// played or not, restarts the gap. The clock can be set by a test (`fakeNow`).
QtObject {
    property double lastEntryMs: -1e9
    property double fakeNow: -1          // >= 0: use this as "now" (tests), else the real clock

    function nowMs() { return fakeNow >= 0 ? fakeNow : Date.now() }

    // True when a glare may play for an entry now. Records the entry either way.
    function claim() {
        const now = nowMs()
        const play = now - lastEntryMs >= Theme.glareGapMs
        lastEntryMs = now
        return play
    }

    function reset() {
        lastEntryMs = -1e9
        fakeNow = -1
    }
}
