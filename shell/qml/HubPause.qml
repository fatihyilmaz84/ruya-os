import QtQuick
import RuyaShell

// The Ruya Hub pauses the game (T-457, 02 §1.6, ADR-033 point 3), and so does "Who's playing?" (RUY-122,
// 02 §1.9): `overlayOpen` is either of them, and the rest reads "the Hub" for both. When the Hub opens over an app it
// asks Session1 to freeze that app; whenever the Hub is closed and an app this object froze is the
// one in front again, it thaws it. So Resume, B and Guide thaw the app they return to, Home leaves it
// frozen behind Home (ADR-019) until its Running card brings it back, and "Switch to" brings the
// chosen app to the front (thawed if it was frozen) while the old one stays frozen. Close game is a
// plain Stop: ruya-session thaws a frozen app before it stops it. With the setting off nothing is
// frozen by the Hub.
//
// `asked` holds the instances this object asked to freeze and has not thawed: a Freeze still on its
// way counts (a quick B after Guide sends Thaw right behind it; the service serves them in order). A
// refused or failed Freeze takes the instance out again, so no Thaw follows and nothing is shown as
// paused (the Hub reads the record's `frozen`, which only the service's answer sets). `thawing` holds
// the Thaws on their way; an instance leaves it only with the answer. A failed Thaw says so in a toast;
// the game is then frozen and in neither list, so the sweep (below) or the next Hub over it retries.
//
// The sweep: a frozen app of the signed-in profile that is in neither list (nor a child of one that
// is: the service freezes a Steam game with Steam's instance, and thaws it with it) was frozen behind this
// object's back (a shell restart while a game was frozen, a Thaw the service refused because the
// profile was switched as the Hub closed, a Freeze served after its Thaw, which since RUY-570 can only
// happen for `asked` apps: the service announces the profile change's freezes inside the freezer's turn): it is thawed. It runs on
// every change of the running list and of the signed-in profile.
//
// The belt (T-464): an app in `asked` that runs again while another app or Home is in front is frozen
// again (`rebelt`). Shell never makes a frozen app the front app by itself (Shell.fallbackFront).
QtObject {
    id: pause

    // A pausing overlay is open: the Hub (QuickMenu) or "Who's playing?" (RUY-122). Both pause alike.
    property bool overlayOpen: false
    // The Session1 instance of the app in front ("" when none is: Home, a page, nobody signed in).
    property string front: ""
    // DeviceSettings.pauseGamesInHub.
    property bool pauseOn: true
    // Profiles.activeProfile: only its apps can be thawed (Session1 refuses the others).
    property string profile: ""

    // The Hub closed over a game this object froze and its Thaw goes out (Resume, B, Guide; the sweep's
    // Thaws are not this): the shell times it (HubProbe, RUY-405).
    signal resuming(string instance)

    property var asked: []
    property var thawing: []
    // The Freezes on their way (the Hub's and the belt's, below); an instance leaves it with the answer.
    property var freezing: []

    function forget(instance) {
        if (asked.includes(instance))
            asked = asked.filter(i => i !== instance)
    }

    function thaw(instance) {
        forget(instance)
        if (!thawing.includes(instance))
            thawing = thawing.concat([instance])
        Session.thaw(instance)
    }

    // Thaws `instance` if it was frozen here.
    function release(instance) {
        if (instance !== "" && asked.includes(instance)) {
            resuming(instance)
            thaw(instance)
        }
    }

    // The app in front, with the Hub closed, runs: thaw it if it was frozen here.
    function sync() {
        if (!overlayOpen && front !== "")
            release(front)
    }

    // An instance this object asked to freeze (or is thawing) covers its children: the service freezes
    // a parent's games with it and thaws them with it (ADR-041 point 7, ADR-042), so they are not
    // frozen behind this object's back.
    function covered(r) {
        return asked.includes(r.instance) || thawing.includes(r.instance)
            || (r.parent !== undefined && r.parent !== "" && (asked.includes(r.parent) || thawing.includes(r.parent)))
    }

    function sweep() {
        if (profile === "")
            return
        for (const r of Session.running) {
            if (r.profile === profile && r.frozen === true && !covered(r))
                thaw(r.instance)
        }
    }

    // The belt (T-464): an app this object froze that runs again while another app (or Home) is in
    // front was thawed by something else, and would run unseen: it is frozen again. This lives here,
    // not in Shell, because `asked` is this object's state and the Thaws it sends itself leave `asked`
    // first (a Resume, Switch to and B are never undone). Only a running instance is frozen again: a
    // game being closed (Close game, a thermal stop) is thawed on purpose so that it can quit.
    function rebelt() {
        if (profile === "")
            return
        for (const r of Session.running) {
            if (r.profile === profile && r.frozen !== true && r.state === "running" && r.instance !== front
                    && asked.includes(r.instance) && !freezing.includes(r.instance)) {
                freezing = freezing.concat([r.instance])
                Session.freeze(r.instance)
            }
        }
    }

    onOverlayOpenChanged: {
        if (overlayOpen) {
            if (pauseOn && front !== "" && !asked.includes(front)) {
                asked = asked.concat([front])
                freezing = freezing.concat([front])
                Session.freeze(front)
            }
        } else {
            sync()
        }
    }
    onFrontChanged: sync()
    onProfileChanged: sweep()

    property Connections answers: Connections {
        target: Session
        function onRunningChanged() {
            pause.sweep()
            pause.rebelt()
        }
        function onFreezeFinished(instance, status) {
            pause.freezing = pause.freezing.filter(i => i !== instance)
            if (status !== "ok")
                pause.forget(instance)          // the game keeps running: no Thaw will be needed
        }
        function onThawFinished(instance, status) {
            pause.thawing = pause.thawing.filter(i => i !== instance)
            if (status === "failed") {
                // Still frozen: the next Hub over it freezes it again (a no-op for the service) and
                // its close thaws it; the sweep also tries again on the next change of the list.
                // Critical (RUY-413): the game stays frozen in front, so the player must see how to go on.
                Notifications.show(qsTr("Could not resume the game. Open Ruya Hub and choose Resume."), "warning", "", "", "",
                                   { urgency: "critical" })
            }
            // "not-allowed" (the profile changed as the Hub closed): the sweep thaws it when the
            // profile is back; "not-running": it is gone.
        }
        function onAppExited(instance) {
            pause.forget(instance)
            pause.thawing = pause.thawing.filter(i => i !== instance)
            pause.freezing = pause.freezing.filter(i => i !== instance)
        }
    }
}
