pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// T-203: what a screen says while it waits for a controller to pair itself, and the pairing
// window behind it (Bluetooth.startControllerPairing, org.ruyaos.Devices1.Bluetooth). Used where
// nobody has an input device yet: the first step of the setup wizard and the profile picker.
//
// While `active` the window is open; it is closed when `active` turns false or the item goes.
// The window ends by itself when a controller pairs ("paired", then `paired()`), when
// its time is up (`timedOut`; with `autoRetry` it is opened again at once, for a screen on
// which nobody can press Retry, but only `maxAutoWindows` windows in a row: then `exhausted`
// says "Press A to start pairing" and `newSeries()` starts again), or when the service cannot
// open it (`failed`). The words are in `message` and, per controller family (T-260), in
// `familySteps`: the one place for the pairing wording. `showFamilies` lists the steps of every
// family under the message (the screens with nobody to press a button); ControllerOnboarding
// shows the steps of the one family the player picks.
Item {
    id: hint

    property real u: 1
    property bool active: false
    property bool autoRetry: false
    property int maxAutoWindows: 3
    // Show the steps of every family under the message.
    property bool showFamilies: false
    // The screen was opened on purpose by somebody who already has an input device (Settings): the
    // waiting message does not say that no controller or keyboard was found.
    property bool onPurpose: false

    // How to put a controller of each family into pairing mode. The order is the order shown; the
    // last entry (family "") is every other pad. Titles come from DeviceIcons.kindText. The 8BitDo
    // keys are from the pads' manuals (X-input and Switch mode), not tried here (T-261 checks them).
    readonly property var familySteps: [
        { family: "playstation",
          steps: qsTr("Hold PS and Create (Share on a DualShock 4) until the light bar flashes.") },
        { family: "xbox",
          steps: qsTr("Press the pairing button on top until the Xbox logo flashes fast.") },
        { family: "nintendo",
          steps: qsTr("Press the small sync button on top until the lights run back and forth.") },
        { family: "8bitdo",
          steps: qsTr("Hold Start with X (X-input mode) or Y (Switch mode) to turn it on in Bluetooth mode, then hold the pair button until the light flashes fast.") },
        { family: "",
          steps: qsTr("Hold its pairing button until the light blinks. Pick the Bluetooth mode if it has several.") }
    ]

    // An Xbox 360 pad with its wireless receiver (RUY-154) pairs by the buttons, not by Bluetooth:
    // the pad then shows up as an ordinary Xbox controller. Shown under the Xbox steps.
    readonly property string receiverSteps: qsTr("Xbox 360 pad with a wireless receiver: press the sync button on the receiver, then on the controller.")

    function titleFor(family) {
        return family === "" ? qsTr("Other controller") : DeviceIcons.kindText("controller", family)
    }
    function stepsFor(family) {
        const entry = familySteps.find(e => e.family === family)
        return entry ? entry.steps : familySteps[familySteps.length - 1].steps
    }

    // The window ended because its time was up.
    readonly property bool timedOut: active && armed && sawOpen && Bluetooth.controllerPairing === "timeout"
    // A controller paired (or an input device showed up some other way).
    readonly property bool succeeded: active && armed && ((sawOpen && Bluetooth.controllerPairing === "paired")
                                                           || (!inputWasPresent && Bluetooth.inputPresent))
    // The service could not open the window (no Bluetooth, ...).
    readonly property bool failed: active && startStatus !== "" && startStatus !== "ok" && startStatus !== "busy"

    // Every automatic window of this series ran out: nothing more opens by itself.
    readonly property bool exhausted: autoRetry && timedOut && windows >= maxAutoWindows

    readonly property string message: {
        if (succeeded)
            return qsTr("Controller connected.")
        if (exhausted)
            return qsTr("Press A to start pairing.")
        if (startStatus === "unavailable")
            return qsTr("Bluetooth is off or missing, so a controller cannot be paired here.")
        if (failed)
            return qsTr("Could not start looking for controllers.")
        if (timedOut)
            return qsTr("No controller was found. Hold the pairing button on your controller (on a DualSense: PS + Create) and try again.")
        if (onPurpose)
            return qsTr("Looking for controllers in pairing mode…")
        return qsTr("No controller or keyboard found. Hold the pairing button on your controller (on a DualSense: PS + Create) until its light blinks.")
    }

    signal paired()

    // Internal.
    property bool armed: false              // the service answered the start
    property bool sawOpen: false            // the state was "open" since the start
    property bool inputWasPresent: true
    property bool rejected: false          // a device that is not a controller was turned away
    property string startStatus: ""        // the service's answer to the start
    property bool reported: false
    property int windows: 0                // windows opened in this series (the first, then each automatic one)
    property int startsSent: 0             // replies are matched to the newest start only
    property int startsAnswered: 0

    implicitHeight: column.implicitHeight
    implicitWidth: column.implicitWidth

    // Opens the window (again).
    function begin() {
        armed = false
        sawOpen = false
        rejected = false
        reported = false
        startStatus = ""
        inputWasPresent = Bluetooth.inputPresent
        windows += 1
        startsSent += 1
        Bluetooth.startControllerPairing()
    }

    // After the automatic windows ran out: a new series (the screen's A).
    function newSeries() {
        if (!active || !exhausted)
            return
        windows = 0
        begin()
    }

    function end() {
        const open = armed || Bluetooth.controllerPairing === "open"
        armed = false
        startStatus = ""
        if (open)
            Bluetooth.stopControllerPairing()
    }

    // After a timeout the caller may ask for another go.
    function retry() {
        if (active && timedOut)
            begin()
    }

    // A handler of the facade's change signal can run before the bindings above have seen the
    // change: look at the state a moment later.
    function evaluate() {
        Qt.callLater(hint.check)
    }

    function check() {
        if (!active)
            return
        if (Bluetooth.controllerPairing === "open")
            sawOpen = true
        if (succeeded && !reported) {
            reported = true
            hint.paired()
        } else if (timedOut && autoRetry && !exhausted) {
            hint.retry()
        }
    }

    // One window per time `active` is true, however the item came to be active.
    property bool started: false
    function start() {
        if (started)
            return
        started = true
        windows = 0
        begin()
    }
    function stop() {
        started = false
        end()
    }
    onActiveChanged: {
        if (active)
            start()
        else
            stop()
    }
    Component.onCompleted: if (active) start()
    Component.onDestruction: if (armed) Bluetooth.stopControllerPairing()

    Connections {
        target: Bluetooth
        function onFinished(op, id, status) {
            // Only the answer to the newest start counts: not a stop's, not an older start's.
            if (op !== "controller-pairing" || id !== "start")
                return
            hint.startsAnswered += 1
            if (hint.startsAnswered < hint.startsSent || !hint.active)
                return
            hint.startStatus = status
            hint.armed = status === "ok" || status === "busy"
            hint.evaluate()
        }
        function onControllerStateChanged() { hint.evaluate() }
        function onControllerRejected() {
            if (hint.active)
                hint.rejected = true
        }
    }

    Column {
        id: column
        width: hint.width
        spacing: Theme.spaceS * hint.u

        Text {
            objectName: hint.objectName + "Text"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: hint.message
            color: Theme.text
            font.pixelSize: Theme.typeBody * hint.u
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
        Column {
            objectName: hint.objectName + "Families"
            width: hint.width
            visible: hint.showFamilies && !hint.succeeded
            spacing: Theme.spaceXs * hint.u
            Repeater {
                model: hint.familySteps
                delegate: Row {
                    id: familyRow
                    required property var modelData
                    objectName: hint.objectName + "Family_" + (modelData.family === "" ? "other" : modelData.family)
                    width: hint.width
                    spacing: Theme.spaceM * hint.u
                    Icon {
                        id: familyGlyph
                        u: hint.u
                        size: Theme.typeCaption
                        name: DeviceIcons.iconFor("controller", familyRow.modelData.family)
                        color: Theme.textDim
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        objectName: "familyText"
                        width: familyRow.width - familyGlyph.width - familyRow.spacing
                        wrapMode: Text.Wrap
                        text: "<b>" + hint.titleFor(familyRow.modelData.family) + ".</b> " + familyRow.modelData.steps
                        textFormat: Text.StyledText
                        color: Theme.textDim
                        font.pixelSize: Theme.typeCaption * hint.u
                        Accessible.role: Accessible.StaticText
                        Accessible.name: hint.titleFor(familyRow.modelData.family) + ". " + familyRow.modelData.steps
                    }
                }
            }
        }
        Text {
            objectName: hint.objectName + "Receiver"
            width: hint.width
            visible: hint.showFamilies && !hint.succeeded
            wrapMode: Text.Wrap
            text: hint.receiverSteps
            color: Theme.textDim
            font.pixelSize: Theme.typeCaption * hint.u
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
        Text {
            objectName: hint.objectName + "Ignored"
            width: parent.width
            visible: hint.rejected && !hint.succeeded
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("A device that is not a controller tried to connect and was ignored.")
            color: Theme.textDim
            font.pixelSize: Theme.typeCaption * hint.u
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
    }
}
