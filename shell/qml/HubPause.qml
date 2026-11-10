import QtQuick
import RuyaShell

// The Ruya Hub pauses the game (T-457, 02 §1.6, ADR-033 point 3). When the Hub opens over an app it
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
// The sweep: a frozen app of the signed-in profile that is in neither list was frozen behind this
// object's back (a shell restart while a game was frozen, a Thaw the service refused because the
// profile was switched as the Hub closed, a Freeze served after its Thaw): it is thawed. It runs on
// every change of the running list and of the signed-in profile.
QtObject {
    id: pause

    // The Hub (QuickMenu) is open.
    property bool hubOpen: false
    // The Session1 instance of the app in front ("" when none is: Home, a page, nobody signed in).
    property string front: ""
    // DeviceSettings.pauseGamesInHub.
    property bool pauseOn: true
    // Profiles.activeProfile: only its apps can be thawed (Session1 refuses the others).
    property string profile: ""

    property var asked: []
    property var thawing: []

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
        if (instance !== "" && asked.includes(instance))
            thaw(instance)
    }

    // The app in front, with the Hub closed, runs: thaw it if it was frozen here.
    function sync() {
        if (!hubOpen && front !== "")
            release(front)
    }

    function sweep() {
        if (profile === "")
            return
        for (const r of Session.running) {
            if (r.profile === profile && r.frozen === true && !asked.includes(r.instance) && !thawing.includes(r.instance))
                thaw(r.instance)
        }
    }

    onHubOpenChanged: {
        if (hubOpen) {
            if (pauseOn && front !== "" && !asked.includes(front)) {
                asked = asked.concat([front])
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
        }
        function onFreezeFinished(instance, status) {
            if (status !== "ok")
                pause.forget(instance)          // the game keeps running: no Thaw will be needed
        }
        function onThawFinished(instance, status) {
            pause.thawing = pause.thawing.filter(i => i !== instance)
            if (status === "failed") {
                // Still frozen: the next Hub over it freezes it again (a no-op for the service) and
                // its close thaws it; the sweep also tries again on the next change of the list.
                Notifications.show(qsTr("Could not resume the game. Open Ruya Hub and choose Resume."), "warning")
            }
            // "not-allowed" (the profile changed as the Hub closed): the sweep thaws it when the
            // profile is back; "not-running": it is gone.
        }
        function onAppExited(instance) {
            pause.forget(instance)
            pause.thawing = pause.thawing.filter(i => i !== instance)
        }
    }
}
