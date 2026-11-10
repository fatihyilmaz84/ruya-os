import QtQuick
import RuyaShell

// The Ruya Hub pauses the game (T-457, 02 §1.6, ADR-033 point 3). When the Hub opens over an app it
// asks Session1 to freeze that app; whenever the Hub is closed and an app this object froze is the
// one in front again, it thaws it. So Resume, B and Guide thaw the app they return to, Home leaves it
// frozen behind Home (ADR-019) until its Running card brings it back, and "Switch to" brings the
// chosen app to the front (thawed if it was frozen) while the old one stays frozen. Close game is a
// plain Stop: ruya-session thaws a frozen app before it stops it. With the setting off nothing is
// frozen, so nothing is thawed either.
//
// `asked` holds the instances this object asked to freeze and has not thawed: a Freeze still on its
// way counts (a quick B after Guide sends Thaw right behind it; the service answers in order). A
// refused or failed Freeze takes the instance out again, so no Thaw follows and nothing is shown as
// paused (the Hub reads the record's `frozen`, which only the service's answer sets).
QtObject {
    id: pause

    // The Hub (QuickMenu) is open.
    property bool hubOpen: false
    // The Session1 instance of the app in front ("" when none is: Home, a page, nobody signed in).
    property string front: ""
    // DeviceSettings.pauseGamesInHub.
    property bool pauseOn: true

    property var asked: []

    function forget(instance) {
        if (asked.includes(instance))
            asked = asked.filter(i => i !== instance)
    }

    // Thaws `instance` if it was frozen here.
    function release(instance) {
        if (instance === "" || !asked.includes(instance))
            return
        forget(instance)
        Session.thaw(instance)
    }

    // The app in front, with the Hub closed, runs: thaw it if it was frozen here.
    function sync() {
        if (!hubOpen && front !== "")
            release(front)
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

    property Connections answers: Connections {
        target: Session
        function onFreezeFinished(instance, status) {
            if (status !== "ok")
                pause.forget(instance)          // the game keeps running: no Thaw will be needed
        }
        function onAppExited(instance) {
            pause.forget(instance)
        }
    }
}
