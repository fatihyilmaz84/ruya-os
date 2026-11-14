pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Controls in games -> Import from USB drive (RUY-465, 06 §7): a picker modal like the Mode picker
// (04 §5): a GlassSheet with the title, the drive's label under it and the `.json` files at the top
// of the drive (Storage.listFiles, newest first) as rows 900 u wide, at most six visible: the file
// name (one line, elided) and its date ("12 Nov"). Up/Down clamp, Accept imports the focused file
// (GameControls.importFrom: read with the 64 KiB cap, validated, saved, assigned); it closes when the
// import is done, and stays open on the file when it was refused (the toast says why). No file: the
// unavailable line "No controls files on this drive.". Back closes it; the focus returns to the row
// that opened it. Modal: it accepts every key.
FocusScope {
    id: picker

    property real u: 1
    property bool shown: false
    property Item returnTo: null
    property int visibleRows: 6
    property string volumeId: ""
    property string driveLabel: ""
    // "loading" | "ok" | "failed" (the listing was refused or failed)
    property string listState: "loading"
    // [{ name, sizeBytes, modified }], newest first (the service's order).
    property var files: []
    readonly property bool empty: listState !== "loading" && files.length === 0

    readonly property var modalHints: empty ? [{ button: "B", text: qsTr("Cancel") }]
                                            : [{ button: "A", text: qsTr("Import") }, { button: "B", text: qsTr("Cancel") }]

    signal closed()

    function open(drive) {
        returnTo = Window.activeFocusItem
        volumeId = drive ? drive.id : ""
        driveLabel = drive ? drive.label : ""
        files = []
        listState = "loading"
        shown = true
        picker.forceActiveFocus()
        Storage.listFiles(volumeId, ".json")
    }

    function close() {
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    function choose() {
        if (list.currentIndex < 0 || list.currentIndex >= files.length || GameControls.importing)
            return
        Sfx.select()
        GameControls.importFrom(volumeId, files[list.currentIndex].name)
    }

    // "12 Nov" in the language of the shell.
    function dateText(seconds) {
        return Qt.locale(DeviceSettings.language).toString(new Date(seconds * 1000), "d MMM")
    }

    Connections {
        target: Storage
        function onFilesListed(id, suffix, status, files) {
            if (!picker.shown || id !== picker.volumeId)
                return
            picker.files = status === "ok" ? files : []
            picker.listState = status === "ok" ? "ok" : "failed"
            list.currentIndex = 0
            if (picker.files.length > 0) {
                list.positionViewAtIndex(0, ListView.Contain)
                if (list.currentItem)
                    list.currentItem.forceActiveFocus()
            }
        }
    }
    Connections {
        target: GameControls
        function onImported(fileName) {
            if (picker.shown)
                picker.close()
        }
        function onImportRefused(fileName, status) {
            // The sheet stays, on that file.
            if (picker.shown && list.currentItem)
                list.currentItem.forceActiveFocus()
        }
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    GlassSheet {
        objectName: "controlsImportPanel"
        anchors.centerIn: parent
        width: 996 * picker.u
        height: content.height + 2 * Theme.spaceXl * picker.u
        u: picker.u
        shown: picker.shown
    }

    Column {
        id: content
        anchors.centerIn: parent
        width: 900 * picker.u
        spacing: Theme.spaceM * picker.u

        Column {
            width: parent.width
            Text {
                objectName: "controlsImportTitle"
                text: qsTr("Import from USB drive")
                color: Theme.text
                font.pixelSize: Theme.typeTitle * picker.u
                font.weight: Theme.weightDemiBold
            }
            Text {
                objectName: "controlsImportDrive"
                width: parent.width
                textFormat: Text.PlainText      // a drive's own label
                text: picker.driveLabel
                color: Theme.text
                font.pixelSize: Theme.typeBody * picker.u
                elide: Text.ElideRight
            }
        }

        SettingRow {
            objectName: "controlsImportNone"
            kind: "info"
            visible: picker.empty
            enabled: false                     // an unavailable line (04 §5)
            u: picker.u
            label: picker.listState === "failed" ? qsTr("This drive can't be read right now.")
                                                 : qsTr("No controls files on this drive.")
        }

        ListView {
            id: list
            objectName: "controlsImportList"
            visible: picker.files.length > 0
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Import from USB drive")
            width: parent.width
            readonly property real rowStep: (Theme.rowHeight + Theme.spaceS) * picker.u
            height: Math.min(Math.max(1, picker.files.length), picker.visibleRows) * rowStep - Theme.spaceS * picker.u
            clip: true
            interactive: false
            spacing: Theme.spaceS * picker.u
            model: picker.files
            currentIndex: 0
            onCurrentIndexChanged: {
                positionViewAtIndex(currentIndex, ListView.Contain)
                if (currentItem && picker.shown)
                    currentItem.forceActiveFocus()
            }

            delegate: SettingRow {
                id: entry
                required property int index
                required property var modelData
                objectName: "controlsImportFile_" + index
                kind: "item"
                width: list.width
                u: picker.u
                label: modelData.name
                labelVisible: false              // the name is drawn below, elided before the date
                value: picker.dateText(modelData.modified)
                onActivated: {
                    list.currentIndex = entry.index
                    picker.choose()
                }
                Text {
                    objectName: "fileName"
                    anchors { left: parent.left; leftMargin: Theme.spaceL * picker.u; verticalCenter: parent.verticalCenter }
                    width: parent.width - 2 * Theme.spaceL * picker.u - entry.trailingWidth
                    textFormat: Text.PlainText   // a name from a drive
                    text: entry.modelData.name
                    color: Theme.text
                    font.pixelSize: Theme.typeBody * picker.u
                    elide: Text.ElideRight
                }
            }
        }
    }

    // Modal: every key stops here. Up/Down move the list by hand.
    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key)) {
            if (!event.isAutoRepeat) {
                Sfx.back()
                picker.close()
            }
        } else if (event.key === Qt.Key_Down && list.currentIndex < picker.files.length - 1) {
            Sfx.navigate()
            list.incrementCurrentIndex()
        } else if (event.key === Qt.Key_Up && list.currentIndex > 0) {
            Sfx.navigate()
            list.decrementCurrentIndex()
        }
        event.accepted = true
    }
}
