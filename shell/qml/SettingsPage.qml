pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Two panes: categories on the left, the selected category's options on the right.
// Up/Down choose a category, Right/Accept enters its pane, Left/Back returns to the list,
// and Back on the list closes the page (Page.qml). Categories without content show
// "Coming soon". Panes stay alive (shown/hidden), so each remembers its last focused row.
Page {
    id: page

    title: qsTr("Settings")

    // Keys only: the list's model must not change with the language (that would reset its
    // currentIndex); the labels are bindings through labelFor().
    readonly property var categories: [
        { key: "profiles" }, { key: "network" }, { key: "bluetooth" }, { key: "display" },
        { key: "audio" }, { key: "storage" }, { key: "accessibility" }, { key: "system" }, { key: "about" },
    ]

    function labelFor(key) {
        switch (key) {
        case "profiles": return qsTr("Profiles")
        case "network": return qsTr("Network")
        case "bluetooth": return qsTr("Bluetooth & controllers")
        case "display": return qsTr("Display & motion")
        case "audio": return qsTr("Audio")
        case "storage": return qsTr("Storage")
        case "accessibility": return qsTr("Accessibility")
        case "system": return qsTr("System")
        case "about": return qsTr("About")
        }
        return key
    }
    readonly property var current: categories[categoryList.currentIndex]
    readonly property SettingsPane currentPane: current.key === "profiles" ? profilesPane
                                              : current.key === "display" ? displayPane
                                              : current.key === "network" ? networkPane
                                              : current.key === "bluetooth" ? bluetoothPane
                                              : current.key === "audio" ? audioPane
                                              : current.key === "storage" ? storagePane
                                              : current.key === "system" ? systemPane
                                              : current.key === "about" ? aboutPane : null

    // The focused pane says which hints it shows (SettingsPane.hints); the category list and a
    // category without a pane yet (A does nothing there) have their own.
    readonly property var listHints: [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]
    hints: currentPane === null ? backOnlyHints
         : currentPane.activeFocus ? currentPane.hints
         : listHints

    // `params.category` ("display") opens on that category, e.g. the Display pane after the shell
    // restarted on a new screen mode (T-198).
    Component.onCompleted: {
        const wanted = (params ?? {}).category ?? ""
        for (let i = 0; i < categories.length; ++i) {
            if (categories[i].key === wanted)
                categoryList.currentIndex = i
        }
    }

    function enterPane() {
        if (!currentPane)
            return
        Sfx.select()
        currentPane.forceActiveFocus()
    }
    function leavePane() {
        categoryList.forceActiveFocus()
    }

    ListView {
        id: categoryList
        objectName: "categoryList"
        Accessible.role: Accessible.List
        Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("Settings")
        // Whole rows only: when the nine categories don't fit above the hint bar the list ends at
        // the last row that does and scrolls by rows (the focused row is always in view).
        readonly property real availableHeight: parent.height     // the content area, above the hint bar
        readonly property real rowHeight: 72 * page.u
        readonly property real stride: rowHeight + spacing
        readonly property int fitRows: Math.max(1, Math.floor((categoryList.availableHeight + spacing) / stride))
        anchors { left: parent.left; top: parent.top }
        width: 470 * page.u
        height: Math.min(categoryList.availableHeight, count * stride - spacing, fitRows * stride - spacing)
        spacing: Theme.spaceXs * page.u
        focus: true
        interactive: false
        keyNavigationEnabled: true
        keyNavigationWraps: false
        clip: contentHeight > height + 0.5
        model: page.categories

        onCurrentIndexChanged: { Sfx.navigate(); positionViewAtIndex(currentIndex, ListView.Contain) }
        onHeightChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        Keys.onReturnPressed: page.enterPane()
        Keys.onEnterPressed: page.enterPane()
        Keys.onRightPressed: page.enterPane()

        // One highlight glides to the focused category (04 §3.8, T-205). It lives in the content
        // item (declared children of a ListView are not put there), so it scrolls with the rows; the rows keep their ring and, without the
        // highlight, their own focus fill.
        FocusGlide {
            id: glide
            objectName: "categoryGlide"
            parent: categoryList.contentItem
            u: page.u
            orientation: Qt.Vertical
            target: categoryList.currentItem
            shown: categoryList.activeFocus
        }

        delegate: Rectangle {
            id: category
            objectName: "category_" + modelData.key
            required property int index
            required property var modelData
            readonly property bool selected: ListView.isCurrentItem
            readonly property bool focused: selected && categoryList.activeFocus

            Accessible.role: Accessible.ListItem
            // Settings -> System carries the console's heat status (T-200): a mark while it is warm or hotter.
            readonly property bool heatMarked: modelData.key === "system" && Thermal.level !== "normal"
            Accessible.name: heatMarked ? page.labelFor(modelData.key) + ", " + ThermalText.levelText(Thermal.level)
                                        : page.labelFor(modelData.key)
            Accessible.selected: selected

            width: categoryList.width
            height: categoryList.rowHeight
            radius: height / 2
            color: focused ? (glide.active ? "transparent" : Theme.focusFill) : selected ? Theme.selectedFill : "transparent"
            border.width: focused ? Theme.focusRingWidth * page.u : selected ? Theme.hairlineAt(page.u) : 0
            border.color: focused ? Theme.focusRing : Theme.glassBorder
            Behavior on color { ColorAnimation { duration: Theme.focusMs } }

            Text {
                anchors { left: parent.left; leftMargin: Theme.spaceL * page.u; right: parent.right; rightMargin: Theme.spaceM * page.u; verticalCenter: parent.verticalCenter }
                text: page.labelFor(category.modelData.key)
                color: Theme.text
                font.pixelSize: Theme.typeBody * page.u
                elide: Text.ElideRight
            }

            Rectangle {
                objectName: "categoryHeatMark_" + category.modelData.key
                visible: category.heatMarked
                anchors { right: parent.right; rightMargin: Theme.spaceM * page.u; verticalCenter: parent.verticalCenter }
                width: Theme.spaceM * page.u
                height: width
                radius: width / 2
                color: ThermalText.levelColor(Thermal.level)
            }
        }
    }

    Item {
        id: paneArea
        anchors { left: categoryList.right; leftMargin: Theme.spaceXxl * page.u; right: parent.right; top: parent.top; bottom: parent.bottom }

        ProfilesPane {
            id: profilesPane
            objectName: "paneProfiles"
            anchors.fill: parent
            u: page.u
            overlay: page.overlay
            visible: page.current.key === "profiles"
            enabled: visible
            onExitRequested: page.leavePane()
        }
        DisplayPane {
            id: displayPane
            objectName: "paneDisplay"
            anchors.fill: parent
            u: page.u
            overlay: page.overlay
            visible: page.current.key === "display"
            enabled: visible
            onExitRequested: page.leavePane()
        }
        NetworkPane {
            id: networkPane
            objectName: "paneNetwork"
            anchors.fill: parent
            u: page.u
            overlay: page.overlay
            visible: page.current.key === "network"
            enabled: visible
            onExitRequested: page.leavePane()
        }
        BluetoothPane {
            id: bluetoothPane
            objectName: "paneBluetooth"
            anchors.fill: parent
            u: page.u
            overlay: page.overlay
            visible: page.current.key === "bluetooth"
            enabled: visible
            onExitRequested: page.leavePane()
        }
        AudioPane {
            id: audioPane
            objectName: "paneAudio"
            anchors.fill: parent
            u: page.u
            visible: page.current.key === "audio"
            enabled: visible
            onExitRequested: page.leavePane()
        }
        StoragePane {
            id: storagePane
            objectName: "paneStorage"
            anchors.fill: parent
            u: page.u
            visible: page.current.key === "storage"
            enabled: visible
            onExitRequested: page.leavePane()
        }
        SystemPane {
            id: systemPane
            objectName: "paneSystem"
            anchors.fill: parent
            u: page.u
            overlay: page.overlay
            visible: page.current.key === "system"
            enabled: visible
            onExitRequested: page.leavePane()
        }
        AboutPane {
            id: aboutPane
            objectName: "paneAbout"
            anchors.fill: parent
            u: page.u
            version: page.version
            visible: page.current.key === "about"
            enabled: visible
            onExitRequested: page.leavePane()
            onSystemInfoRequested: page.openRequested("systemInfo", ({}))
        }
        Column {
            objectName: "paneComingSoon"
            visible: page.currentPane === null
            spacing: Theme.spaceS * page.u
            Text {
                text: page.labelFor(page.current.key)
                color: Theme.text
                font.pixelSize: Theme.typeTitle * page.u
                font.weight: Theme.weightDemiBold
            }
            Text {
                text: qsTr("Coming soon")
                color: Theme.text
                font.pixelSize: Theme.typeHeadline * page.u
                font.weight: Theme.weightDemiBold
            }
        }
    }
}
