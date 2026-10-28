pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// First-boot setup (spec 01 §5.2), shown instead of the profile picker while no profile exists.
// Controller only: Accept (Return) continues, Back (Escape) goes to the previous step.
//
//   0 welcome -> 1 language -> 2 network (placeholder) -> 3 create the admin -> 4 done
//
// Step 3 collects a name (on-screen keyboard) and a PIN (PIN pad, entered twice), then calls
// Profiles.createProfile with no admin credentials (the first profile needs none). The Done
// step is the only way out (finished()), so the picker never flashes between "profile created"
// and "all set". The shell hosts this and leaves it on finished().
FocusScope {
    id: setup

    property real u: 1

    readonly property int stepCount: 5
    property int step: 0
    property string adminName: ""
    property string message: ""
    property bool busy: false          // createProfile is in flight
    property bool created: false       // the admin exists; only Done is left
    // Once the account is being (or has been) created the shell must not drop setup, even
    // though the profile list is no longer empty.
    readonly property bool committed: busy || created

    signal finished()

    function start() {
        step = 0
        adminName = ""
        message = ""
        busy = false
        created = false
        focusStep()
    }

    function focusStep() {
        if (step === 1)
            languageRow.forceActiveFocus()
        else if (step === 3)
            (adminName.length > 0 ? createRow : nameRow).forceActiveFocus()
        else
            keySink.forceActiveFocus()
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
        if (step === 0 || step === 4 || busy)
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
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (step !== 3)
                next()
        } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
            back()
        }
        event.accepted = true           // modal: nothing leaks to the picker or the home shelf
    }

    // Receives keys on the steps that have no control of their own.
    Item { id: keySink; focus: true }

    Connections {
        target: Profiles
        function onCreateFinished(status) {
            if (!setup.busy)
                return
            setup.busy = false
            if (status === "ok") {
                setup.created = true
                setup.message = ""
                setup.step = 4
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
        implicitHeight: 84 * setup.u
        radius: height / 2
        color: Theme.focusFill
        border.width: 4 * setup.u
        border.color: Theme.focusRing
        Text {
            id: pillText
            anchors.centerIn: parent
            text: pill.label
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * setup.u
        }
    }

    // ---- progress ----
    Column {
        anchors { top: parent.top; topMargin: 200 * setup.u; horizontalCenter: parent.horizontalCenter }
        spacing: 14 * setup.u

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 14 * setup.u
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
            color: Theme.textDim
            font.pixelSize: Theme.typeCaption * setup.u
        }
    }

    // ---- step 0: welcome ----
    Column {
        objectName: "setupWelcome"
        visible: setup.step === 0
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: 28 * setup.u
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Welcome to RuyaOS")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Font.Light
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Let's get your console ready. It only takes a minute, and you only need your controller.")
            color: Theme.textDim
            font.pixelSize: Theme.typeHeadline * setup.u
        }
        Pill { anchors.horizontalCenter: parent.horizontalCenter; label: qsTr("Press A to start") }
    }

    // ---- step 1: language ----
    Column {
        objectName: "setupLanguage"
        visible: setup.step === 1
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: 28 * setup.u
        Text {
            objectName: "setupLanguageTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Language")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Font.Light
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Use left and right to choose. You can change this later in Settings.")
            color: Theme.textDim
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

    // ---- step 2: network (placeholder) ----
    Column {
        objectName: "setupNetwork"
        visible: setup.step === 2
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: 28 * setup.u
        Text {
            objectName: "setupNetworkTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Network")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Font.Light
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Network setup comes later. A wired connection works without any setup.")
            color: Theme.textDim
            font.pixelSize: Theme.typeHeadline * setup.u
        }
        Pill { anchors.horizontalCenter: parent.horizontalCenter; label: qsTr("Press A to continue") }
    }

    // ---- step 3: create the admin ----
    Column {
        objectName: "setupAdmin"
        visible: setup.step === 3
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: 24 * setup.u
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Create your profile")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Font.Light
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("You will be the admin of this console. Choose a name and a PIN of 4 to 6 digits.")
            color: Theme.textDim
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

    // ---- step 4: done ----
    Column {
        objectName: "setupDone"
        visible: setup.step === 4
        anchors.centerIn: parent
        width: 1000 * setup.u
        spacing: 28 * setup.u
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("You're all set")
            color: Theme.text
            font.pixelSize: Theme.typeDisplay * setup.u
            font.weight: Font.Light
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Welcome, %1.").arg(setup.adminName.trim())
            color: Theme.textDim
            font.pixelSize: Theme.typeHeadline * setup.u
        }
        Pill { anchors.horizontalCenter: parent.horizontalCenter; label: qsTr("Press A to continue") }
    }

    // Back hint (not on the first step, nor once the account exists).
    Text {
        visible: setup.step > 0 && setup.step < 4
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 120 * setup.u; bottomMargin: 120 * setup.u }
        text: qsTr("B  Back")
        color: Theme.textDim
        font.pixelSize: Theme.typeCaption * setup.u
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
