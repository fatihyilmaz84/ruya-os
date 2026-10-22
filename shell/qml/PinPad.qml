pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Modal PIN entry, fully controller-driven: D-pad moves over the keypad, Accept presses the
// focused key, Back deletes a digit (or closes when empty), Menu/Start submits.
// Keyboards can also type digits, Backspace, and Enter (keypad) to submit.
//
// Modes:
//   "verify"           open(profile): checks the PIN with Profiles.switchTo (sign-in).
//   "collect"          collect(prompt, false): hands the PIN to the caller (collected(pin)),
//                      calls no service.
//   "collect-confirm"  collect(prompt, true): asks twice; on a mismatch shows "PINs don't
//                      match" and starts over.
// In the collect modes Back on an empty pad also emits cancelled() (after closed()).
FocusScope {
    id: pad

    property real u: 1
    property var profile: ({})
    property string entered: ""
    property string message: ""
    property bool busy: false
    property int lockSecs: 0
    property bool shown: false
    property string mode: "verify"     // "verify" | "collect" | "collect-confirm"
    property string prompt: ""         // title in the collect modes
    property int stage: 0              // collect-confirm: 0 = first entry, 1 = confirmation
    property string firstEntry: ""

    readonly property int minDigits: 4
    readonly property int maxDigits: 6

    signal closed()
    signal collected(string pin)        // collect modes: the PIN the user entered (and confirmed)
    signal cancelled()                  // collect modes: closed without a PIN

    function collect(promptText, confirm) {
        mode = confirm ? "collect-confirm" : "collect"
        prompt = promptText
        profile = {}
        stage = 0
        firstEntry = ""
        entered = ""
        message = ""
        lockSecs = 0
        busy = false
        shown = true
        keys.currentIndex = 0
        keys.forceActiveFocus()
    }

    function open(p) {
        mode = "verify"
        profile = p
        stage = 0
        firstEntry = ""
        entered = ""
        message = ""
        busy = false
        shown = true
        keys.currentIndex = 0
        keys.forceActiveFocus()
    }

    function close() {
        shown = false
        closed()
    }

    function press(key) {
        if (busy)
            return
        if (key === "del") {
            entered = entered.slice(0, -1)
        } else if (key === "ok") {
            submit()
        } else if (entered.length < maxDigits) {
            entered += key
            message = lockSecs > 0 ? message : ""
        }
    }

    function cancel() {
        const wasCollecting = mode !== "verify"
        close()
        if (wasCollecting)
            cancelled()
    }

    function finishCollect() {
        const pin = entered
        entered = ""
        close()                        // first: the caller may open the pad again from collected()
        collected(pin)
    }

    // Error feedback for the dots; skipped under reduced motion (the message and sound remain).
    function shakeDots() {
        if (!Theme.reducedMotion)
            shake.restart()
    }

    function submit() {
        if (busy || lockSecs > 0 || entered.length < minDigits)
            return
        if (mode === "verify") {
            busy = true
            Profiles.switchTo(profile.id, entered)
        } else if (mode === "collect") {
            Sfx.select()
            finishCollect()
        } else if (stage === 0) {
            Sfx.select()
            firstEntry = entered
            entered = ""
            message = ""
            stage = 1
        } else if (entered === firstEntry) {
            Sfx.select()
            finishCollect()
        } else {
            message = qsTr("PINs don't match")
            Sfx.back()
            shakeDots()
            entered = ""
            firstEntry = ""
            stage = 0
        }
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }

    Connections {
        target: Profiles
        function onSwitchFinished(id, status, attemptsLeft, retryAfterSecs) {
            if (!pad.shown || pad.mode !== "verify" || id !== pad.profile.id)
                return
            pad.busy = false
            pad.entered = ""
            if (status === "ok") {
                Sfx.select()
                pad.close()
            } else if (status === "locked-out") {
                pad.lockSecs = retryAfterSecs
                Sfx.back()
                pad.shakeDots()
            } else if (status === "wrong-pin") {
                pad.message = qsTr("Wrong PIN. %n attempt(s) left.", "", attemptsLeft)
                Sfx.back()
                pad.shakeDots()
            } else {
                pad.message = qsTr("Could not sign in (%1).").arg(status)
            }
        }
    }

    Timer {
        running: pad.lockSecs > 0
        interval: 1000
        repeat: true
        onTriggered: pad.lockSecs -= 1
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Column {
        id: content
        anchors.centerIn: parent
        spacing: 28 * pad.u

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: pad.mode === "verify" ? qsTr("Enter PIN for %1").arg(pad.profile.name ?? "")
                : pad.stage === 1 ? qsTr("Confirm PIN") : pad.prompt
            color: Theme.text
            font.pixelSize: 44 * pad.u
        }

        Row {
            id: dots
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 18 * pad.u
            Repeater {
                model: Math.max(pad.minDigits, pad.entered.length)
                Rectangle {
                    required property int index
                    width: 22 * pad.u
                    height: width
                    radius: width / 2
                    color: index < pad.entered.length ? Theme.text : "transparent"
                    border.color: Theme.textDim
                    border.width: 2 * pad.u
                }
            }
            SequentialAnimation {
                id: shake
                objectName: "pinShake"
                loops: 2
                NumberAnimation { target: dots; property: "anchors.horizontalCenterOffset"; to: Theme.shakeDistance * pad.u; duration: Theme.shakeQuickMs }
                NumberAnimation { target: dots; property: "anchors.horizontalCenterOffset"; to: -Theme.shakeDistance * pad.u; duration: Theme.shakeSlowMs }
                NumberAnimation { target: dots; property: "anchors.horizontalCenterOffset"; to: 0; duration: Theme.shakeQuickMs }
            }
        }

        Text {
            objectName: "pinMessage"
            anchors.horizontalCenter: parent.horizontalCenter
            height: 36 * pad.u
            text: pad.lockSecs > 0 ? qsTr("Too many attempts. Try again in %1 s.").arg(pad.lockSecs) : pad.message
            color: Theme.errorText
            font.pixelSize: 26 * pad.u
        }

        GridView {
            id: keys
            objectName: "pinKeys"

            readonly property real key: 120 * pad.u

            anchors.horizontalCenter: parent.horizontalCenter
            width: cellWidth * 3
            height: cellHeight * 4
            cellWidth: key + 20 * pad.u
            cellHeight: key + 20 * pad.u
            interactive: false
            keyNavigationEnabled: true
            focus: true
            model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "del", "0", "ok"]

            onCurrentIndexChanged: if (pad.shown) Sfx.navigate()
            Keys.onReturnPressed: pad.press(model[currentIndex])

            delegate: Item {
                id: keyCell
                required property int index
                required property string modelData
                readonly property bool focused: GridView.isCurrentItem && keys.activeFocus
                readonly property bool isAction: modelData === "del" || modelData === "ok"

                width: keys.cellWidth
                height: keys.cellHeight

                Rectangle {
                    anchors.centerIn: parent
                    width: keys.key
                    height: keys.key
                    radius: width / 2
                    scale: keyCell.focused ? 1.1 : 1.0
                    Behavior on scale { NumberAnimation { duration: Theme.focusMs } }
                    color: keyCell.focused ? Theme.keyFocusFill : Theme.glass
                    border.width: keyCell.focused ? 4 * pad.u : 1
                    border.color: keyCell.focused ? Theme.focusRing : Theme.glassBorder
                    opacity: keyCell.modelData === "ok" && pad.entered.length < pad.minDigits ? 0.4 : 1

                    Text {
                        anchors.centerIn: parent
                        text: keyCell.modelData === "del" ? qsTr("Del") : keyCell.modelData === "ok" ? qsTr("OK") : keyCell.modelData
                        color: Theme.text
                        font.pixelSize: (keyCell.isAction ? 34 : 48) * pad.u
                    }
                }
            }
        }
    }

    Keys.onPressed: event => {
        if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
            press(String(event.key - Qt.Key_0))
        } else if (event.key === Qt.Key_Backspace) {
            press("del")
        } else if (event.key === Qt.Key_Enter || event.key === Qt.Key_Menu) {
            submit()
        } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
            Sfx.back()
            if (entered.length > 0)
                press("del")
            else
                cancel()
        }
        event.accepted = true   // modal: nothing reaches the picker underneath
    }
}
