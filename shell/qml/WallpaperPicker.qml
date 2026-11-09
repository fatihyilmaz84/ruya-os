pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Display & motion -> Wallpaper (T-208): a modal grid of thumbnails. The first tile is
// the default look (the animated blobs), then the bundled pictures, then the owner's copies.
// Accept on a tile chooses it and closes. Below the grid: "Add from USB drive..." (while a mounted
// drive has pictures in Wallpapers/ or Pictures/) opens the drive's pictures in the same grid, and
// Accept on one copies it (off the GUI thread: the grid shows "Copying..."); "Delete" removes the
// copy that is highlighted. Back closes, or returns from the drive's pictures to the library.
// Modal: it accepts every key. Focus returns to the item that had it before open().
FocusScope {
    id: picker

    property real u: 1
    property bool shown: false
    property Item returnTo: null
    property string mode: "library"          // "library" | "usb"
    property string message: ""              // why the last copy failed (shown in the drive's grid)
    property bool awaitingCopy: false        // a copy asked for by this picker is running

    // What the buttons do while it is open (Shell.modalHintsOf, the hint bar).
    readonly property var modalHints: [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Cancel") }]

    signal closed()

    readonly property int columns: 4
    readonly property bool usbMode: mode === "usb"
    readonly property var entries: usbMode ? Wallpapers.usbImages : libraryEntries
    // Keys of the library tiles: names are looked up in the delegate, so a change of language never
    // resets the grid's current index.
    readonly property var libraryEntries: {
        const list = [{ id: "", kind: "default", source: "" }]
        for (const b of Wallpapers.bundled)
            list.push({ id: b.id, kind: "bundled", source: b.source })
        for (const w of Wallpapers.user)
            list.push({ id: w.id, kind: "user", source: w.source })
        return list
    }
    readonly property var currentEntry: grid.currentIndex >= 0 && grid.currentIndex < entries.length ? entries[grid.currentIndex] : null
    readonly property bool canDelete: !usbMode && currentEntry !== null && currentEntry.kind === "user"
    readonly property bool canAdd: !usbMode && Wallpapers.usbImages.length > 0
    readonly property bool copying: Wallpapers.copyState === "copying"
    // A button that goes away (the drive is pulled, the highlighted copy is deleted) must not keep focus.
    onCanAddChanged: if (!canAdd && addButton.activeFocus) grid.forceActiveFocus()
    onCanDeleteChanged: if (!canDelete && deleteButton.activeFocus) grid.forceActiveFocus()

    function usbMounts() {
        return Storage.volumes.filter(v => v.mounted && v.removable && v.mountPoint.length > 0).map(v => v.mountPoint)
    }
    function rescan() {
        Wallpapers.scanUsb(usbMounts())
    }

    function indexOfId(id) {
        for (let i = 0; i < libraryEntries.length; ++i) {
            if (libraryEntries[i].id === id)
                return i
        }
        return 0
    }

    function open() {
        returnTo = Window.activeFocusItem
        message = ""
        mode = "library"
        rescan()
        grid.currentIndex = indexOfId(DeviceSettings.wallpaper)
        grid.positionViewAtIndex(grid.currentIndex, GridView.Contain)
        shown = true
        grid.forceActiveFocus()
    }

    function close() {
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    function showLibrary(selectId) {
        mode = "library"
        message = ""
        grid.currentIndex = indexOfId(selectId ?? DeviceSettings.wallpaper)
        grid.positionViewAtIndex(grid.currentIndex, GridView.Contain)
        grid.forceActiveFocus()
    }

    function showUsb() {
        rescan()
        message = ""
        mode = "usb"
        grid.currentIndex = 0
        grid.positionViewAtIndex(0, GridView.Beginning)
        grid.forceActiveFocus()
    }

    function accept() {
        const entry = currentEntry
        if (!entry)
            return
        Sfx.select()
        if (usbMode) {
            message = ""
            awaitingCopy = true
            Wallpapers.importFile(entry.path, Theme.background)
        } else {
            DeviceSettings.wallpaper = entry.id
            close()
        }
    }

    function deleteCurrent() {
        const entry = currentEntry
        if (!canDelete || !entry)
            return
        Sfx.select()
        const at = grid.currentIndex
        if (DeviceSettings.wallpaper === entry.id)
            DeviceSettings.wallpaper = ""           // before the file goes, so the layer never sees a missing one
        Wallpapers.remove(entry.id)
        Notifications.show(qsTr("Wallpaper deleted"), "info")
        grid.currentIndex = Math.min(at, grid.count - 1)
        grid.forceActiveFocus()
    }

    function failureText(status) {
        switch (status) {
        case "limit": return qsTr("You can keep up to %1 wallpapers. Delete one first.").arg(Wallpapers.userLimit)
        case "too-large": return qsTr("This picture is too large.")
        case "unsupported": return qsTr("This kind of picture is not supported.")
        }
        return qsTr("This picture could not be copied.")
    }

    // The next control in the row under the grid, from `from` (-1: from the grid), by `step`.
    function stepButton(step) {
        const list = [addButton, deleteButton].filter(b => b.visible)
        if (list.length === 0)
            return
        let at = list.findIndex(b => b.activeFocus)
        if (at < 0) {
            list[step > 0 ? 0 : list.length - 1].forceActiveFocus()
            return
        }
        const next = at + step
        if (next >= 0 && next < list.length) {
            Sfx.navigate()
            list[next].forceActiveFocus()
        }
    }

    function moveInGrid(key) {
        const before = grid.currentIndex
        const row = Math.floor(before / columns)
        const lastRow = Math.floor((grid.count - 1) / columns)
        if (key === Qt.Key_Left) {
            if (before % columns > 0)
                grid.currentIndex = before - 1
        } else if (key === Qt.Key_Right) {
            if (before % columns < columns - 1 && before + 1 < grid.count)
                grid.currentIndex = before + 1
        } else if (key === Qt.Key_Up) {
            if (row > 0)
                grid.currentIndex = before - columns
        } else if (key === Qt.Key_Down) {
            if (row < lastRow)
                grid.currentIndex = Math.min(grid.count - 1, before + columns)
            else if (addButton.visible || deleteButton.visible) {
                Sfx.navigate()
                stepButton(1)
                return
            }
        }
        if (grid.currentIndex !== before)
            Sfx.navigate()
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Connections {
        target: Storage
        function onVolumesChanged() { picker.rescan() }
    }
    // A drive that went away while its pictures were open: back to the library.
    Connections {
        target: Wallpapers
        function onUsbImagesChanged() {
            if (picker.usbMode && Wallpapers.usbImages.length === 0 && !picker.copying)
                picker.showLibrary()
        }
        function onCopyFinished(status, id, name) {
            if (!picker.awaitingCopy)
                return
            picker.awaitingCopy = false
            if (status === "ok") {
                DeviceSettings.wallpaper = id
                Notifications.show(qsTr("Wallpaper added"), "success")
                picker.showLibrary(id)
            } else {
                picker.message = picker.failureText(status)
                Notifications.show(qsTr("Could not add the wallpaper"), "error")
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    GlassSheet {
        id: panel
        objectName: "wallpaperPanel"
        anchors.centerIn: parent
        width: gridFrame.width + 2 * Theme.spaceXl * picker.u
        height: content.height + 2 * Theme.spaceXl * picker.u
        u: picker.u
        shown: picker.shown
    }

    Column {
        id: content
        anchors.centerIn: panel
        spacing: Theme.spaceM * picker.u

        Text {
            objectName: "wallpaperTitle"
            text: picker.usbMode ? qsTr("Pictures on the USB drive") : qsTr("Wallpaper")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * picker.u
            font.weight: Theme.weightDemiBold
        }

        // The grid sits in a clipping frame that is `ringPad` larger on every side, so the focus ring, which is
        // drawn outside the art, is never cut at the edge of the first row or column.
        Item {
            id: gridFrame
            objectName: "wallpaperGridFrame"
            readonly property real ringPad: (Theme.focusRingOffset + Theme.focusRingWidth) * picker.u
            width: grid.width + 2 * ringPad
            height: grid.height + 2 * ringPad
            clip: true

        GridView {
            id: grid
            objectName: "wallpaperGrid"
            x: gridFrame.ringPad
            y: gridFrame.ringPad
            readonly property real tileWidth: 320 * picker.u
            readonly property real tileHeight: 180 * picker.u
            readonly property real captionHeight: Theme.typeCaption * picker.u * 1.5
            cellWidth: tileWidth + Theme.spaceM * picker.u
            cellHeight: tileHeight + captionHeight + Theme.spaceM * picker.u
            width: cellWidth * picker.columns
            // As many rows as there are (at most two); with more tiles a third row shows half, so the
            // cut-off row says "scroll".
            readonly property int rows: Math.max(1, Math.ceil(grid.count / picker.columns))
            height: rows > 2 ? cellHeight * 2.5 : cellHeight * rows
            clip: false                          // the frame clips (a view's own clip would cut the ring)
            interactive: false
            keyNavigationEnabled: false          // the picker moves the selection (modal: it takes every key)
            keyNavigationWraps: false
            model: picker.entries
            focus: true
            Accessible.role: Accessible.List
            Accessible.name: picker.currentEntry ? (picker.usbMode ? picker.currentEntry.name : DisplayText.wallpaperName(picker.currentEntry.id)) : qsTr("Wallpaper")
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)

            delegate: Item {
                id: tile
                required property int index
                required property var modelData
                readonly property bool isCurrent: GridView.isCurrentItem
                readonly property bool focused: isCurrent && grid.activeFocus
                readonly property bool chosen: !picker.usbMode && modelData.id === DeviceSettings.wallpaper
                readonly property string label: picker.usbMode ? modelData.name : DisplayText.wallpaperName(modelData.id)

                width: grid.cellWidth
                height: grid.cellHeight
                Accessible.role: Accessible.ListItem
                Accessible.name: chosen ? qsTr("%1, current").arg(label) : label
                Accessible.selected: isCurrent

                // The tile's art: the default look or the picture, cut to the tile's rounded shape by a mask
                // (a `clip` is rectangular), so the picture, the hairline and the focus ring share one
                // radius. On the software renderer, where `MultiEffect` draws nothing, the content is
                // drawn as it is (square corners).
                Item {
                    id: art
                    objectName: "wallpaperTile_" + (picker.usbMode ? tile.index : tile.modelData.id)
                    width: grid.tileWidth
                    height: grid.tileHeight
                    readonly property real radius: Theme.radiusM * picker.u
                    readonly property bool masked: GraphicsInfo.api !== GraphicsInfo.Software
                                                   && GraphicsInfo.api !== GraphicsInfo.Null
                                                   && GraphicsInfo.api !== GraphicsInfo.Unknown
                    readonly property real maskRadius: artMask.radius       // tests read it

                    Item {
                        id: artContent
                        anchors.fill: parent
                        clip: !art.masked
                        visible: !art.masked
                        layer.enabled: art.masked
                        layer.smooth: true
                        // The default look: the backdrop's gradient and two soft blobs.
                        Rectangle {
                            anchors.fill: parent
                            radius: art.masked ? 0 : art.radius     // the mask rounds it (a second antialiased edge would thin the corner)
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: Theme.backdropTop(Theme.blobTintA(Theme.defaultTint)) }
                                GradientStop { position: 1.0; color: Theme.background }
                            }
                        }
                        Rectangle {
                            visible: !picker.usbMode && tile.modelData.kind === "default"
                            width: parent.width * 0.7
                            height: width
                            radius: width / 2
                            x: -width * 0.2
                            y: -height * 0.5
                            color: Theme.blobTintA(Theme.defaultTint)
                            opacity: Theme.blobOpacityA
                        }
                        Image {
                            anchors.fill: parent
                            visible: status === Image.Ready
                            source: tile.modelData.source ?? ""
                            asynchronous: true
                            cache: false
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(grid.tileWidth, grid.tileHeight)
                        }
                    }
                    Rectangle {
                        id: artMask
                        anchors.fill: parent
                        radius: art.radius
                        visible: false
                        layer.enabled: art.masked
                        layer.smooth: true
                    }
                    SmoothMask {
                        objectName: "wallpaperTileMask_" + (picker.usbMode ? tile.index : tile.modelData.id)
                        anchors.fill: parent
                        visible: art.masked
                        source: artContent
                        maskSource: artMask
                    }
                    // Selected but focus is elsewhere (the buttons): a hairline.
                    Rectangle {
                        objectName: "wallpaperHairline_" + (picker.usbMode ? tile.index : tile.modelData.id)
                        anchors.fill: parent
                        radius: art.radius
                        color: "transparent"
                        border.width: tile.isCurrent && !tile.focused ? Theme.hairlineAt(picker.u) : 0
                        border.color: Theme.glassBorder
                    }
                    Badge {
                        objectName: "wallpaperCurrent_" + tile.modelData.id
                        visible: tile.chosen
                        anchors { left: parent.left; top: parent.top; margins: Theme.spaceXs * picker.u }
                        u: picker.u
                        text: qsTr("Current")
                        kind: "info"
                    }
                }
                // The focus ring: outside the art at `focusRingOffset`, as on the primary buttons (04 §4), so it
                // reads on a white thumbnail and in either ring colour.
                Rectangle {
                    objectName: "wallpaperRing_" + (picker.usbMode ? tile.index : tile.modelData.id)
                    visible: tile.focused
                    x: art.x - Theme.focusRingOffset * picker.u
                    y: art.y - Theme.focusRingOffset * picker.u
                    width: art.width + 2 * Theme.focusRingOffset * picker.u
                    height: art.height + 2 * Theme.focusRingOffset * picker.u
                    radius: art.radius + Theme.focusRingOffset * picker.u
                    color: "transparent"
                    border.width: Theme.focusRingWidth * picker.u
                    border.color: Theme.focusRing
                }
                Text {
                    anchors { top: art.bottom; topMargin: Theme.spaceXs * picker.u; left: art.left; right: art.right }
                    objectName: "wallpaperLabel_" + (picker.usbMode ? tile.index : tile.modelData.id)
                    textFormat: Text.PlainText      // a name from a drive is never markup
                    text: tile.label
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * picker.u
                    elide: Text.ElideRight
                }
            }
        }

            // While a copy runs the grid shows only that.
            Rectangle {
                objectName: "wallpaperCopying"
                x: grid.x
                y: grid.y
                width: grid.width
                height: grid.height
                visible: picker.copying
                radius: Theme.radiusM * picker.u
                color: Theme.panel
                opacity: 0.92
                Text {
                    anchors.centerIn: parent
                    text: qsTr("Copying…")
                    color: Theme.text
                    font.pixelSize: Theme.typeHeadline * picker.u
                    font.weight: Theme.weightDemiBold
                }
            }
        }

        Text {
            objectName: "wallpaperMessage"
            visible: picker.usbMode
            width: gridFrame.width
            textFormat: Text.PlainText
            text: picker.message.length > 0 ? picker.message
                : qsTr("Choose a picture to copy to this console. It is shrunk to fit the screen.")
            color: picker.message.length > 0 ? Theme.errorText : Theme.text
            font.pixelSize: Theme.typeCaption * picker.u
            wrapMode: Text.Wrap
        }

        Row {
            id: buttons
            visible: !picker.usbMode && (picker.canAdd || picker.canDelete)
            spacing: Theme.spaceM * picker.u

            SecondaryButton {
                id: addButton
                objectName: "wallpaperAddUsb"
                visible: picker.canAdd
                u: picker.u
                text: qsTr("Add from USB drive…")
                onAccepted: picker.showUsb()
            }
            SecondaryButton {
                id: deleteButton
                objectName: "wallpaperDelete"
                visible: picker.canDelete
                u: picker.u
                text: qsTr("Delete")
                onAccepted: picker.deleteCurrent()
            }
        }
    }

    Keys.onPressed: event => {
        event.accepted = true                    // modal: nothing leaks to the page underneath
        if (!picker.shown || picker.copying)
            return
        const key = event.key
        if (BackKey.isBackOrBackspace(key)) {
            Sfx.back()
            if (picker.usbMode)
                picker.showLibrary()
            else
                picker.close()
        } else if (grid.activeFocus) {
            if (key === Qt.Key_Return || key === Qt.Key_Enter)
                picker.accept()
            else
                picker.moveInGrid(key)
        } else if (key === Qt.Key_Left) {
            picker.stepButton(-1)
        } else if (key === Qt.Key_Right) {
            picker.stepButton(1)
        } else if (key === Qt.Key_Up) {
            Sfx.navigate()
            grid.forceActiveFocus()
        }
    }
}
