pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Install from USB (05 §7.3 step 1, 04 §5.4, RUY-98): the .play packages found on the mounted drives, one pill
// per package under its drive. Opened as Shell.openPage("installSources", { drive }) from the Store (every
// drive) and from Settings -> Storage (`drive`: only that one). Accept opens the package page; Back leaves.
// Nothing on a drive is opened here: the service lists names and sizes (SourcesChanged refreshes the list).
//
// After an install finished while the player was on the package page, the focus comes back to the package
// after it in the list (the one just installed is done), else to the one before.
Page {
    id: page

    title: qsTr("Install from USB")

    // Only this drive's packages ("" = all drives).
    readonly property string drive: params.drive ?? ""
    readonly property var sources: Play.sources.filter(s => page.drive === "" || s.drive === page.drive)
    readonly property bool empty: sources.length === 0
    // Paths whose install finished ok since the list last had the focus.
    property var installedPaths: []

    // A row of the list per source. A heading is the drive's, drawn by the ListView's section.
    function openPackage(path) {
        Sfx.select()
        page.openRequested("installPackage", { path: path })
    }

    function capacityOf(driveId) {
        const v = Storage.volumes.find(x => x.id === driveId)
        return v && v.sizeBytes > 0 ? Storage.formatBytes(v.sizeBytes) : ""
    }

    // Where the focus goes when the list gets it back after an install.
    function afterInstalled() {
        if (installedPaths.length === 0 || list.count === 0)
            return
        const done = installedPaths
        installedPaths = []
        const at = page.sources.findIndex(s => done.indexOf(s.path) >= 0)
        if (at < 0)
            return
        list.currentIndex = at + 1 < list.count ? at + 1 : Math.max(0, at - 1)
    }

    hints: empty ? backOnlyHints : [
        { action: "accept", text: qsTr("Select") },
        { action: "back", text: qsTr("Back") }
    ]

    Connections {
        target: Play
        function onJobFinished(key, status) {
            if (status === "ok" && page.installedPaths.indexOf(key) < 0)
                page.installedPaths = page.installedPaths.concat([key])
        }
        function onSourcesChanged() {
            Qt.callLater(page.keepFocus)
        }
    }

    // The list lost its rows under the focus (a drive was unplugged): the focus goes to the page, which has
    // nothing to select, and Back still works.
    function keepFocus() {
        if (!empty && !list.activeFocus && page.activeFocus)
            list.forceActiveFocus()
        if (empty)
            page.forceActiveFocus()
    }

    Component.onCompleted: {
        Play.refreshSources()
        Qt.callLater(keepFocus)
    }

    Text {
        id: subtitle
        objectName: "sourcesSubtitle"
        width: parent.width
        textFormat: Text.PlainText
        text: qsTr("Games found on your USB drives")
        color: Theme.text
        font.pixelSize: Theme.typeBody * page.u
    }

    ListView {
        id: list
        objectName: "sourcesList"
        anchors { left: parent.left; right: parent.right; top: subtitle.bottom; topMargin: Theme.spaceL * page.u; bottom: parent.bottom }
        visible: !page.empty
        focus: !page.empty
        clip: true
        spacing: Theme.spaceS * page.u
        keyNavigationEnabled: true
        highlightMoveDuration: 0
        // Rows keep their place by the package path: a new list from the service does not move the focus.
        model: page.sources
        currentIndex: 0
        topMargin: Theme.spaceS * page.u
        bottomMargin: Theme.spaceS * page.u

        Accessible.role: Accessible.List
        Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("Install from USB")

        section.property: "drive"
        section.criteria: ViewSection.FullString
        section.delegate: Item {
            id: head
            required property string section
            readonly property var first: page.sources.find(s => s.drive === section) ?? ({})
            width: list.width
            height: Theme.iconM * page.u + 2 * Theme.spaceM * page.u

            Row {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Theme.spaceXs * page.u
                spacing: Theme.spaceS * page.u

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    u: page.u
                    name: "usb"
                }
                Text {
                    objectName: "sourcesDrive"
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText      // the drive's own label
                    readonly property string capacity: page.capacityOf(head.section)
                    text: (head.first.driveLabel ?? "") + (capacity !== "" ? " · " + capacity : "")
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * page.u
                    font.weight: Theme.weightDemiBold
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: Theme.typeCaption * page.u * 0.06
                }
            }
        }

        delegate: FocusScope {
            id: row
            required property int index
            required property var modelData
            readonly property bool lit: ListView.isCurrentItem && list.activeFocus

            objectName: "source_" + modelData.name
            width: 1200 * page.u                // token-ok: 04 §5.4 Install from USB
            height: Theme.rowHeight * page.u

            Accessible.role: Accessible.Button
            Accessible.name: modelData.name + ", " + PlayCopy.kindText(modelData.kind)
            Accessible.focusable: true

            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: row.lit ? Theme.focusFill : Theme.glass
                border.width: row.lit ? Theme.focusRingWidth * page.u : Theme.hairlineAt(page.u)
                border.color: row.lit ? Theme.focusRing : Theme.glassBorder
            }
            GlassLayers {
                anchors.fill: parent
                u: page.u
                radius: height / 2
                grain: false
                rim: !row.lit
            }

            Icon {
                id: lead
                x: Theme.spaceL * page.u
                anchors.verticalCenter: parent.verticalCenter
                u: page.u
                name: "sports_esports"
            }

            Column {
                x: lead.x + lead.width + Theme.spaceM * page.u
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - x - sizeText.width - 2 * Theme.spaceL * page.u
                Text {
                    objectName: "sourceName"
                    width: parent.width
                    textFormat: Text.PlainText      // a file name from outside
                    elide: Text.ElideRight
                    text: row.modelData.name
                    color: Theme.text
                    font.pixelSize: Theme.typeBody * page.u
                }
                Text {
                    width: parent.width
                    text: PlayCopy.kindText(row.modelData.kind)
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * page.u
                }
            }

            Text {
                id: sizeText
                objectName: "sourceSize"
                anchors { right: parent.right; rightMargin: Theme.spaceL * page.u; verticalCenter: parent.verticalCenter }
                text: row.modelData.size > 0 ? Storage.formatBytes(row.modelData.size) : ""
                color: Theme.text
                font.pixelSize: Theme.typeBody * page.u
            }
        }

        Keys.onReturnPressed: event => {
            if (event.isAutoRepeat || currentIndex < 0 || currentIndex >= page.sources.length) {
                event.accepted = event.isAutoRepeat
                return
            }
            page.openPackage(page.sources[currentIndex].path)
            event.accepted = true
        }
        Keys.onEnterPressed: event => {
            if (event.isAutoRepeat || currentIndex < 0 || currentIndex >= page.sources.length) {
                event.accepted = event.isAutoRepeat
                return
            }
            page.openPackage(page.sources[currentIndex].path)
            event.accepted = true
        }
        // Up from the first row has nowhere to go on this page; Down at the last stays (no wrap).
        Keys.onUpPressed: event => {
            if (currentIndex > 0) {
                Sfx.navigate()
                decrementCurrentIndex()
            }
            event.accepted = true
        }
        Keys.onDownPressed: event => {
            if (currentIndex < count - 1) {
                Sfx.navigate()
                incrementCurrentIndex()
            }
            event.accepted = true
        }
        onActiveFocusChanged: if (activeFocus) page.afterInstalled()
    }

    // Nothing on the drives: an unavailable row and how to put a game there.
    Column {
        id: emptyState
        objectName: "sourcesEmpty"
        visible: page.empty
        anchors { left: parent.left; right: parent.right; top: subtitle.bottom; topMargin: Theme.spaceL * page.u }
        spacing: Theme.spaceM * page.u

        Rectangle {
            width: 1200 * page.u                // token-ok: 04 §5.4 Install from USB
            height: Theme.rowHeight * page.u
            radius: height / 2
            color: Theme.glass
            border.width: Theme.hairlineAt(page.u)
            border.color: Theme.glassBorder
            opacity: Theme.disabledOpacity

            Row {
                x: Theme.spaceL * page.u
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spaceM * page.u

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    u: page.u
                    name: "usb"
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("No games on USB drives")
                    color: Theme.text
                    font.pixelSize: Theme.typeBody * page.u
                }
            }
        }

        Text {
            objectName: "sourcesEmptyHelp"
            width: 1200 * page.u                // token-ok: 04 §5.4 Install from USB
            wrapMode: Text.Wrap
            text: qsTr("Copy a .play folder, or a .zip of one, to a USB drive, then plug it in.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
        }
    }
}
