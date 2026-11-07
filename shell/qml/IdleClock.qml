pragma Singleton
import QtQuick
import RuyaShell

// The console's one idle clock and the power-saving timeline (T-202, 01 Â§2.2, 02 "Power saving").
//
// The shell is the compositor, so every key, button and pointer event of every app passes it
// (`KeyRouter.activity` -> `noteInput()`). From that one stamp come
//   - `idleSeconds`: time since the last input. What the update service's report, the controller
//     idle rule and the play ledger are based on.
//   - `quietSeconds`: the same, but time during which something holds the console awake (an
//     `IdleInhibit` reason: an app's Wayland idle-inhibitor, a Store job, an update being fetched,
//     audio playing) counts as activity. The countdown of the stages below runs on this one, so
//     "nothing idles while something is going on" is a single rule.
//   - `stage`: "active" -> "saver" -> "off" -> "sleep", entered when `quietSeconds` reaches the
//     times of DeviceSettings (Off/never = 0 skips a stage). A stage is only ever left by input
//     (`noteInput()`), or by the machine having been asleep (a jump of the clock).
//
// Every time is derived in one place (`secs()`), divided by `IdleInhibit.timeDivisor`
// (RUYA_IDLE_DIVISOR, for the VM and the Dell). Tests replace `now` with a fake clock and call
// `evaluate()`; nothing in here sleeps or polls faster than it must: one timer, set to the next
// deadline, stopped while the console is held awake and while the screen is off.
QtObject {
    id: clock

    // ---- test hooks and inputs ----
    // The wall clock in ms. Replaced in tests.
    property var now: () => Date.now()
    // An app has the screen (set by Shell): the idle-controller rule never switches pads off then,
    // because the shell does not see every button a game uses.
    property bool appOpen: false

    // ---- the timeline, in seconds (0 = this step is off) ----
    function secs(minutes) {
        return minutes > 0 ? Math.max(1, Math.round(minutes * 60 / IdleInhibit.timeDivisor)) : 0
    }
    readonly property int saverAfter: secs(DeviceSettings.saverMinutes)
    readonly property int offAfter: secs(DeviceSettings.screenOffMinutes)
    // Only offered where suspend works (Power.sleepAllowed); otherwise the step does not exist.
    readonly property int sleepAfter: Power.sleepAllowed ? secs(DeviceSettings.sleepMinutes) : 0
    readonly property int padAfter: secs(DeviceSettings.padIdleMinutes)

    // ---- state ----
    property double lastInputMs: now()
    property double lastBusyMs: lastInputMs
    property double lastEvalMs: lastInputMs
    property double lastPadReportMs: 0
    property bool padReported: false
    property int idleSeconds: 0
    property int quietSeconds: 0
    property string stage: "active"        // "active" | "saver" | "off" | "sleep"
    readonly property bool covered: stage !== "active"
    readonly property bool held: IdleInhibit.held
    // Why the console is held awake right now, for the Power saving pane ("" when it is not).
    readonly property string heldBy: IdleInhibit.reasons.join(", ")

    // The saver (or a deeper stage) just began; input ended it; the console is about to suspend.
    signal saverStarted()
    signal displayOffStarted()
    signal sleepRequested()
    signal woke()
    // Every input, for the receivers that act on it themselves (the update report, toasts, the
    // presence report); they no longer keep a clock of their own.
    signal inputNoted()

    function rank(name) {
        return name === "sleep" ? 3 : name === "off" ? 2 : name === "saver" ? 1 : 0
    }

    function stageFor(quiet) {
        if (sleepAfter > 0 && quiet >= sleepAfter)
            return "sleep"
        if (offAfter > 0 && quiet >= offAfter)
            return "off"
        if (saverAfter > 0 && quiet >= saverAfter)
            return "saver"
        return "active"
    }

    // Input of any kind (a key, a button, the pointer, the Guide button). The first one after the
    // saver or the dark screen only wakes: KeyRouter has already eaten it (`swallowInput`).
    function noteInput() {
        lastInputMs = now()
        lastEvalMs = lastInputMs
        if (padReported) {
            padReported = false
            Bluetooth.reportIdle(0, padAfter, false)
        }
        if (stage !== "active")
            wake()
        idleSeconds = 0
        quietSeconds = 0
        inputNoted()
        schedule()
    }

    function wake() {
        const was = stage
        stage = "active"
        if (was === "off" || was === "sleep")
            ScreenPower.setOn(true)
        woke()
    }

    // The time since the last input or the last time something held the console awake, now.
    // (UsagePresence asks this every few seconds.)
    function sample() {
        evaluate()
        return quietSeconds
    }

    function evaluate() {
        const t = now()
        // A clock that jumped far ahead of the last look: the console slept (suspend) and something
        // woke it that was not a key the shell saw (the power button). That is activity.
        if (stage === "sleep" && t - lastEvalMs > 30000 / IdleInhibit.timeDivisor + 1000) {
            lastEvalMs = t
            lastInputMs = t
            wake()
        }
        lastEvalMs = t
        if (held)
            lastBusyMs = t
        idleSeconds = Math.max(0, Math.floor((t - lastInputMs) / 1000))
        quietSeconds = Math.max(0, Math.floor((t - Math.max(lastInputMs, lastBusyMs)) / 1000))

        const target = stageFor(quietSeconds)
        if (rank(target) > rank(stage))
            enter(target)

        // The idle controllers: the service decides, it needs to hear from us while the console is
        // idle (every minute) and when it stops being idle (noteInput).
        if (padAfter > 0 && idleSeconds >= padAfter
                && t - lastPadReportMs >= Math.max(1000, 60000 / IdleInhibit.timeDivisor)) {
            lastPadReportMs = t
            padReported = true
            Bluetooth.reportIdle(idleSeconds, padAfter, appOpen || held)
        }
        schedule()
    }

    function enter(target) {
        if (stage === "active")
            saverStarted()          // the first step away from active, whichever stage it lands on
        const from = stage
        stage = target
        if (target === "off" || target === "sleep") {
            if (rank(from) < 2) {
                ScreenPower.setOn(false)
                displayOffStarted()
            }
        }
        if (target === "sleep") {
            sleepRequested()
            Power.suspend()
        }
    }

    // Tests only: back to "just had input" at the current time.
    function reset() {
        IdleInhibit.releaseAll()
        stage = "active"
        lastInputMs = now()
        lastBusyMs = lastInputMs
        lastEvalMs = lastInputMs
        lastPadReportMs = 0
        padReported = false
        idleSeconds = 0
        quietSeconds = 0
        ScreenPower.setOn(true)
        evaluate()
    }

    // One timer, aimed at the next thing that can happen.
    function schedule() {
        let next = -1
        const consider = ms => { if (next < 0 || ms < next) next = ms }
        const t = now()
        if (stage === "sleep") {
            consider(5000)                      // the resume check
        } else if (!held) {
            const quiet = (t - Math.max(lastInputMs, lastBusyMs)) / 1000
            for (const at of [saverAfter, offAfter, sleepAfter]) {
                if (at > 0 && at > quiet)
                    consider((at - quiet) * 1000)
            }
        }
        if (padAfter > 0 && stage !== "sleep") {
            const idle = (t - lastInputMs) / 1000
            if (idle < padAfter)
                consider((padAfter - idle) * 1000)
            else
                consider(Math.max(1000, 60000 / IdleInhibit.timeDivisor))
        }
        if (next < 0) {
            tick.stop()
            return
        }
        tick.interval = Math.min(60000, Math.max(200, Math.ceil(next) + 50))
        tick.restart()
    }

    onHeldChanged: {
        // The countdown starts again from the moment the last holder lets go.
        lastBusyMs = now()
        evaluate()
    }
    onSaverAfterChanged: evaluate()
    onOffAfterChanged: evaluate()
    onSleepAfterChanged: evaluate()
    onPadAfterChanged: {
        // Never (or a new time): the service forgets what it knew.
        if (padAfter === 0 && padReported) {
            padReported = false
            Bluetooth.reportIdle(0, 0, false)
        }
        evaluate()
    }

    // ---- what holds the console awake (other than apps' idle-inhibitors, which the compositor adds) ----
    function syncHolds() {
        IdleInhibit.setHeld("job", Object.keys(Store.jobs).length > 0)
        IdleInhibit.setHeld("update", Update.state === "checking" || Update.state === "downloading")
        IdleInhibit.setHeld("audio", Audio.playing)
    }

    readonly property Connections storeWatch: Connections {
        target: Store
        function onJobsChanged() { clock.syncHolds() }
    }
    readonly property Connections updateWatch: Connections {
        target: Update
        function onStatusChanged() { clock.syncHolds() }
    }
    readonly property Connections audioWatch: Connections {
        target: Audio
        function onPlayingChanged() { clock.syncHolds() }
    }

    readonly property Timer tick: Timer {
        objectName: "idleTick"
        repeat: false
        onTriggered: clock.evaluate()
    }

    Component.onCompleted: {
        syncHolds()
        evaluate()
    }
}
