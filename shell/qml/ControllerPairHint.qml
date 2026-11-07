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
// which nobody can press Retry), or when the service cannot open it (`failed`).
Item {
    id: hint

    property real u: 1
    property bool active: false
    property bool autoRetry: false

    // The window ended because its time was up.
    readonly property bool timedOut: active && armed && sawOpen && Bluetooth.controllerPairing === "timeout"
    // A controller paired (or an input device showed up some other way).
    readonly property bool succeeded: active && armed && ((sawOpen && Bluetooth.controllerPairing === "paired")
                                                           || (!inputWasPresent && Bluetooth.inputPresent))
    // The service could not open the window (no Bluetooth, ...).
    readonly property bool failed: active && startStatus !== "" && startStatus !== "ok" && startStatus !== "busy"

    readonly property string message: {
        if (succeeded)
            return qsTr("Controller connected.")
        if (startStatus === "unavailable")
            return qsTr("Bluetooth is off or missing, so a controller cannot be paired here.")
        if (failed)
            return qsTr("Could not start looking for controllers.")
        if (timedOut)
            return qsTr("No controller was found. Hold the pairing button on your controller and try again.")
        return qsTr("No controller or keyboard found. Hold the pairing button on your controller until its light blinks.")
    }

    signal paired()

    // Internal.
    property bool armed: false              // the service answered the start
    property bool sawOpen: false            // the state was "open" since the start
    property bool inputWasPresent: true
    property bool rejected: false          // a device that is not a controller was turned away
    property string startStatus: ""        // the service's answer to the start
    property bool reported: false

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
        Bluetooth.startControllerPairing()
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
        } else if (timedOut && autoRetry) {
            hint.retry()
        }
    }

    // One window per time `active` is true, however the item came to be active.
    property bool started: false
    function start() {
        if (started)
            return
        started = true
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
            if (op !== "controller-pairing" || !hint.active || hint.startStatus !== "")
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
            text: hint.message
            color: Theme.text
            font.pixelSize: Theme.typeBody * hint.u
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
