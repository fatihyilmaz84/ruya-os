pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// First-boot setup (spec 01 §5.2), shown instead of the profile picker while no profile exists.
// Controller only: Accept (Return) continues, Back (Escape) goes to the previous step.
//
//   0 welcome -> 1 language -> 2 time zone -> 3 network (placeholder) -> 4 create the admin -> 5 done
//
// Before step 0, when the console has no keyboard or controller at all (Bluetooth.inputPresent
// is false), comes the pairing stage (T-203): the controller pairing window is open and the
// screen says to hold the pairing button. It ends when a controller pairs (the wizard goes on
// to the welcome step), or with Back (skip). It is not one of the numbered steps.
//
// Step 2 (T-213) is "Where are you?": a region list and a city list (ZoneChooser), starting on a
// zone that fits the language. Accept on a city asks Devices1.Time to set it (no admin is needed: no
// profile exists yet) and goes on; Start skips the step and leaves the zone alone.
//
// Step 4 collects a name (on-screen keyboard) and a PIN (PIN pad, entered twice), then calls
// Profiles.createProfile with no admin credentials (the first profile needs none). The Done
// step is the only way out (finished()), so the picker never flashes between "profile created"
// and "all set". The shell hosts this and leaves it on finished().
FocusScope {
    id: setup

    property real u: 1

    readonly property int stepCount: 6
    // The steps, by number.
    readonly property int stepZone: 2
    readonly property int stepAdmin: 4
    readonly property int stepDone: 5
    property int step: 0
    property string adminName: ""
    property string message: ""
    property string zoneChoice: ""     // the city chosen in the time zone step ("" = none yet)
    property bool busy: false          // createProfile is in flight
    property bool created: false       // the admin exists; only Done is left
    // Once the account is being (or has been) created the shell must not drop setup, even
    // though the profile list is no longer empty.
    readonly property bool committed: busy || created

    // The controller pairing stage (T-203). `pairingSkipped`: it was left, do not come back.
    property bool pairingStage: false
    property bool pairingSkipped: false
    readonly property bool needsController: Bluetooth.inputKnown && !Bluetooth.inputPresent
    onNeedsControllerChanged: maybeEnterPairing()

    function maybeEnterPairing() {
        if (!enabled || pairingStage || pairingSkipped || step !== 0 || committed || !needsController)
            return
        pairingStage = true
        focusStep()
    }

    function leavePairing(skip) {
        if (!pairingStage)
            return
        if (skip)
            Sfx.back()
        else
            Sfx.select()
        pairingStage = false
        pairingSkipped = true
        focusStep()
    }

    // What A and B do on this step, for the shell's hint bar. Not on the first step (nothing
    // before it) nor once the account exists (B does nothing); the keyboard and the PIN pad take B.
    readonly property var hints: {
        if (pairingStage)
            return pairHint.timedOut ? [{ button: "A", text: qsTr("Try again") }, { button: "B", text: qsTr("Skip") }]
                                     : [{ button: "B", text: qsTr("Skip") }]
        if (nameEntry.shown || pad.shown)
            return [{ button: "B", text: qsTr("Cancel") }]
        const a = { button: "A", text: step === stepAdmin || step === stepZone ? qsTr("Select") : qsTr("Next") }
        if (step === 0 || step === stepDone || busy)
            return step === 0 || step === stepDone ? [a] : []
        if (step === stepZone)
            return [a, { button: "B", text: qsTr("Back") }, { button: "Start", text: qsTr("Skip") }]
        return [a, { button: "B", text: qsTr("Back") }]
    }

    signal finished()

    function start() {
        step = 0
        adminName = ""
        zoneChoice = ""
        message = ""
        busy = false
        created = false
        // Starting again while the pairing stage shows leaves it, and its window, alone.
        if (!(pairingStage && needsController))
            pairingStage = false
        pairingSkipped = false
        focusStep()
        maybeEnterPairing()
    }

    function focusStep() {
        if (step === 1) {
            languageRow.forceActiveFocus()
        } else if (step === stepZone) {
            enterZone()
        } else if (step === stepAdmin) {
            (adminName.length > 0 ? createRow : nameRow).forceActiveFocus()
        } else
            keySink.forceActiveFocus()
    }

    // The time zone step: begin on the choice made before, else on the zone the console already has
    // (if it is not the factory UTC), else on one that fits the language.
    function enterZone() {
        const set = TimeZone.timezone
        const fallback = set !== "UTC" ? set : TimeZone.defaultZoneFor(DeviceSettings.language)
        zoneChooser.current = set
        zoneChooser.start(zoneChoice.length > 0 ? zoneChoice : fallback)
        zoneChooser.forceActiveFocus()
    }

    // ListTimezones can answer after the wizard reached the step: begin again, so the default for
    // the language is not lost to the zone the console has now (UTC).
    Connections {
        target: TimeZone
        function onTimezonesChanged() {
            if (setup.step === setup.stepZone && setup.zoneChoice.length === 0 && TimeZone.timezones.length > 0)
                setup.enterZone()
        }
    }

    function chooseZone(zone) {
        zoneChoice = zone
        TimeZone.setTimezone(zone)      // the answer needs no waiting for: Settings can change it later
        next()
    }

    function skipZone() {
        Sfx.select()
        next()
    }

    function next() {
        if (step >= stepCount - 1) {
            Sfx.select()
            finished()
            return
        }
        Sfx.select()
        step += 1
        focusStep()
    }

    function back() {
        Sfx.back()
        if (step === 0 || step === stepDone || busy)
            return                      // nothing before the start; the account exists once Done shows
        step -= 1
        focusStep()
    }

    function startCreate() {
        if (busy)
            return
        if (adminName.trim().length === 0) {
            Sfx.back()
            message = qsTr("Enter a name first.")
            return
        }
        message = ""
        pad.collect(qsTr("Choose a PIN"), true)
    }

    Keys.onPressed: event => {
        if (pairingStage) {
            // Nothing but Try again and Skip here; the pad that pairs ends the stage by itself.
            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !event.isAutoRepeat) {
                if (pairHint.timedOut) {
                    Sfx.select()
                    pairHint.retry()
                }
            } else if (BackKey.isBackOrBackspace(event.key) && !event.isAutoRepeat) {
                leavePairing(true)
            }
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (step !== stepAdmin && step !== stepZone)
                next()
        } else if (event.key === Qt.Key_Menu && step === stepZone) {
            if (!event.isAutoRepeat)
                skipZone()
        } else if (BackKey.isBackOrBackspace(event.key)) {
            back()
        }
        event.accepted = true           // modal: nothing leaks to the picker or the home shelf
    }

    // Receives keys on the steps that have no control of their own.
    Item {
        id: keySink
        focus: true
        Accessible.role: Accessible.Pane
        // Per step, so a screen reader says where the wizard is (steps 1, 2 and 4 focus their own controls).
        Accessible.name: setup.pairingStage ? qsTr("Connect a controller")
                       : setup.step === setup.stepDone ? qsTr("You're all set")
                       : setup.step === 3 ? qsTr("Network")
                       : qsTr("Welcome to RuyaOS")
    }

    Connections {
        target: Profiles
        function onCreateFinished(status) {
            if (!setup.busy)
                return
            setup.busy = false
            if (status === "ok") {
                setup.created = true
                setup.message = ""
                setup.step = setup.stepDone
                setup.focusStep()
            } else {
                Sfx.back()
                setup.message = ProfileStatus.describe(status, 0, 0)
                createRow.forceActiveFocus()
            }
        }
    }

    component Pill: Rectangle {
        id: pill
        property string label
        implicitWidth: pillText.implicitWidth + 96 * setup.u
        implicitHeight: Theme.rowHeight * setup.u
        radius: height / 2
        color: Theme.focusFill
        border.width: Theme.focusRingWidth * setup.u
        border.color: Theme.focusRing
        Text {
            id: pillText
            anchors.centerIn: parent
            text: pill.label
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * setup.u
            font.weight: Theme.weightDemiBold
        }
    }

    // ---- progress ----
    Column {
        visible: !setup.pairingStage
        anchors { top: parent.top; topMargin: 2 * Theme.spaceXxxl * setup.u; horizontalCenter: parent.horizontalCenter }
        spacing: Theme.spaceS * setup.u

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spaceS * setup.u
            Repeater {
                model: setup.stepCount
                Rectangle {
                    required property int index
                    width: 16 * setup.u
                    height: width
                    radius: width / 2
                    color: index <= setup.step ? Theme.text : "transparent"
                    border.color: Theme.textDim
                    border.width: 2 * setup.u
                }
            }
        }
        Text {
            objectName: "setupStepLabel"
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Step %1 of %2").arg(setup.step + 1).arg(setup.stepCount)
            color: Theme.text
            font.pixelSize: Theme.typeCaption * setup.u
        }
    }

    // ---- pairing stage: no keyboard or controller yet ----
    Column {
        objectName: "setupPairing"
        visible: setup.pairingStage
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: Theme.spaceM * setup.u
        Text {
            objectName: "setupPairingTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Connect a controller")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Theme.weightLight
        }
        ControllerPairHint {
            id: pairHint
            objectName: "setupPairHint"
            width: parent.width
            u: setup.u
            active: setup.pairingStage && setup.enabled
            onPaired: setup.leavePairing(false)
        }
        Pill {
            objectName: "setupPairRetry"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: pairHint.timedOut
            label: qsTr("Press A to try again")
        }
    }

    // ---- step 0: welcome ----
    Column {
        objectName: "setupWelcome"
        visible: setup.step === 0 && !setup.pairingStage
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: Theme.spaceM * setup.u
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Welcome to RuyaOS")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Theme.weightLight
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Let's get your console ready. It only takes a minute, and you only need your controller.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * setup.u
        }
        Pill { anchors.horizontalCenter: parent.horizontalCenter; label: qsTr("Press A to start") }
    }

    // ---- step 1: language ----
    Column {
        objectName: "setupLanguage"
        visible: setup.step === 1
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: Theme.spaceM * setup.u
        Text {
            objectName: "setupLanguageTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Language")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Theme.weightLight
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Use left and right to choose. You can change this later in Settings.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * setup.u
        }
        ChoiceRow {
            id: languageRow
            objectName: "setupLanguageRow"
            u: setup.u
            label: qsTr("Language")
            options: [
                { value: "en", label: "English" },
                { value: "tr", label: "Türkçe" },
            ]
            onEdited: v => DeviceSettings.language = v
        }
        Binding { target: languageRow; property: "value"; value: DeviceSettings.language }
        Pill { anchors.horizontalCenter: parent.horizontalCenter; label: qsTr("Press A to continue") }
    }

    // ---- step 2: time zone ----
    Column {
        objectName: "setupZone"
        visible: setup.step === setup.stepZone
        anchors { top: parent.top; topMargin: 3 * Theme.spaceXxxl * setup.u; horizontalCenter: parent.horizontalCenter }
        width: 1100 * setup.u
        spacing: Theme.spaceM * setup.u
        Text {
            objectName: "setupZoneTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Where are you?")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Theme.weightLight
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Choose your region, then your city, so the clock is right. You can change this later in Settings.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * setup.u
        }
        ZoneChooser {
            id: zoneChooser
            objectName: "setupZoneChooser"
            prefix: "setupZone"
            anchors.horizontalCenter: parent.horizontalCenter
            u: setup.u
            visibleRows: 4
            onChosen: zone => setup.chooseZone(zone)
            onCancelled: setup.back()
        }
    }

    // ---- step 3: network (placeholder) ----
    Column {
        objectName: "setupNetwork"
        visible: setup.step === 3
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: Theme.spaceM * setup.u
        Text {
            objectName: "setupNetworkTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Network")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Theme.weightLight
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Network setup comes later. A wired connection works without any setup.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * setup.u
        }
        Pill { anchors.horizontalCenter: parent.horizontalCenter; label: qsTr("Press A to continue") }
    }

    // ---- step 4: create the admin ----
    Column {
        objectName: "setupAdmin"
        visible: setup.step === setup.stepAdmin
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: Theme.spaceM * setup.u
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Create your profile")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Theme.weightLight
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("You will be the admin of this console. Choose a name and a PIN of 4 to 6 digits.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * setup.u
        }
        SettingRow {
            id: nameRow
            objectName: "setupNameRow"
            u: setup.u
            label: qsTr("Name")
            value: setup.adminName.length > 0 ? setup.adminName : qsTr("Not set")
            KeyNavigation.down: createRow
            onActivated: nameEntry.open(qsTr("Your name"), setup.adminName, { maxLength: 32, layout: "text" })
        }
        SettingRow {
            id: createRow
            objectName: "setupCreateRow"
            u: setup.u
            label: qsTr("Choose a PIN and finish")
            value: setup.busy ? qsTr("Creating…") : ""
            KeyNavigation.up: nameRow
            onActivated: setup.startCreate()
        }
        Text {
            objectName: "setupMessage"
            width: parent.width
            height: 40 * setup.u
            horizontalAlignment: Text.AlignHCenter
            text: setup.message
            color: Theme.errorText
            font.pixelSize: Theme.typeBody * setup.u
            wrapMode: Text.Wrap
        }
    }

    // ---- step 5: done ----
    Column {
        objectName: "setupDone"
        visible: setup.step === setup.stepDone
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: Theme.spaceM * setup.u
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("You're all set")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Theme.weightLight
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Welcome, %1.").arg(setup.adminName.trim())
            color: Theme.text
            font.pixelSize: Theme.typeBody * setup.u
        }
        Pill { anchors.horizontalCenter: parent.horizontalCenter; label: qsTr("Press A to continue") }
    }

    // Full-screen layer for the keyboard and the PIN pad.
    Item {
        id: modalLayer
        anchors.fill: parent
        z: 5

        TextEntry {
            id: nameEntry
            objectName: "setupNameEntry"
            width: parent.width
            height: parent.height
            u: setup.u
            onAccepted: text => {
                setup.adminName = text
                setup.message = ""
                createRow.forceActiveFocus()
            }
        }

        PinPad {
            id: pad
            objectName: "setupPinPad"
            width: parent.width
            height: parent.height
            u: setup.u
            onClosed: createRow.forceActiveFocus()
            onCollected: pin => {
                setup.busy = true
                Profiles.createProfile("", "", setup.adminName.trim(), "admin", pin)
            }
        }
    }
}
