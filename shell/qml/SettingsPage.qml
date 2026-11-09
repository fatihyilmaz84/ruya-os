pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Two panes: categories on the left, the selected category's options on the right.
// Up/Down choose a category, Right/Accept enters its pane, Left/Back returns to the list,
// and Back on the list closes the page (Page.qml). Categories without content show
// "Coming soon". A pane is built the first time its category is selected (T-349: Settings opens
// with one pane, not ten) and then stays alive (shown/hidden), so it remembers its last focused row.
Page {
    id: page

    title: qsTr("Settings")

    // Keys only: the list's model must not change with the language (that would reset its
    // currentIndex); the labels are bindings through labelFor(). "Manage profiles" (key
    // "profiles") is listed for an admin only (T-315): for anyone else it is not in the list at
    // all, so Up/Down and the nav keys never reach it. Only a change of the signed-in profile's
    // role changes the list (refreshCategories), and the selected category stays selected.
    readonly property bool showManage: (Profiles.active.role ?? "") === "admin"
    // Assigned, never bound: the list changes only in refreshCategories().
    property var categories: buildCategories(false)
    property bool refreshing: false
    function buildCategories(withManage) {
        const keys = ["myprofile"]
        if (withManage)
            keys.push("profiles")
        keys.push("network", "bluetooth", "display", "audio", "storage", "accessibility", "power", "system", "about")
        return keys.map(k => ({ key: k }))
    }
    // The signed-in profile became (or stopped being) an admin, or Settings just opened: rebuild
    // the list, keep the selected category when it is still there, and if it was Manage profiles
    // (gone now) leave its pane: focus goes to the category list, which shows My profile.
    function refreshCategories() {
        const key = current.key
        const hadPaneFocus = currentPane !== null && currentPane.activeFocus
        refreshing = true
        categories = buildCategories(showManage)
        categoryList.currentIndex = Math.max(0, categories.findIndex(c => c.key === key))
        refreshing = false
        if (hadPaneFocus && current.key !== key)
            leavePane()
    }
    onShowManageChanged: refreshCategories()

    function labelFor(key) {
        switch (key) {
        case "myprofile": return qsTr("My profile")
        case "profiles": return qsTr("Manage profiles")
        case "network": return qsTr("Network")
        case "bluetooth": return qsTr("Bluetooth & controllers")
        case "display": return qsTr("Display & motion")
        case "audio": return qsTr("Audio")
        case "storage": return qsTr("Storage")
        case "accessibility": return qsTr("Accessibility")
        case "power": return qsTr("Power saving")
        case "system": return qsTr("System")
        case "about": return qsTr("About")
        }
        return key
    }
    readonly property var current: categories[categoryList.currentIndex] ?? categories[0]
    // The panes are built only once the opening category is known (Component.onCompleted), so
    // `params.category` builds that pane and not My profile first.
    property bool ready: false
    readonly property SettingsPane currentPane: (current.key === "myprofile" ? myProfileSlot.item
                                               : current.key === "profiles" ? manageProfilesSlot.item
                                               : current.key === "display" ? displaySlot.item
                                               : current.key === "network" ? networkSlot.item
                                               : current.key === "bluetooth" ? bluetoothSlot.item
                                               : current.key === "audio" ? audioSlot.item
                                               : current.key === "storage" ? storageSlot.item
                                               : current.key === "power" ? powerSlot.item
                                               : current.key === "system" ? systemSlot.item
                                               : current.key === "about" ? aboutSlot.item : null) as SettingsPane

    // The focused pane says which hints it shows (SettingsPane.hints); the category list and a
    // category without a pane yet (A does nothing there) have their own.
    readonly property var listHints: [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]
    hints: currentPane === null ? backOnlyHints
         : currentPane.activeFocus ? currentPane.hints
         : listHints

    // `params.category` ("display") opens on that category, e.g. the Display pane after the shell
    // restarted on a new screen mode (T-198).
    Component.onCompleted: {
        refreshCategories()
        const wanted = (params ?? {}).category ?? ""
        for (let i = 0; i < categories.length; ++i) {
            if (categories[i].key === wanted)
                categoryList.currentIndex = i
        }
        ready = true
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

    // One slot per pane (T-349): the pane is built when its category is first selected and is then
    // kept (latched), hidden while another category is selected. The slot fills the pane area and the
    // pane fills the slot (by anchors, as before: a test squeezes a pane through them); the pane
    // reads as visible and enabled only while it is selected. A pane built after the page opened
    // lays its rows out at once (SettingsPane.reflow: a Column filled late was seen unlaid in a
    // real window until the next repaint, T-226).
    component PaneSlot: Loader {
        property bool selected: false
        property bool built: false
        anchors.fill: parent
        active: selected || built
        visible: selected
        enabled: selected
        onLoaded: {
            built = true
            const pane = item as SettingsPane
            if (pane)
                pane.reflow()
        }
    }

    ListView {
        id: categoryList
        objectName: "categoryList"
        Accessible.role: Accessible.List
        Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("Settings")
        // Whole rows only: when the ten categories don't fit above the hint bar the list ends at
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

        onCurrentIndexChanged: { if (!page.refreshing) Sfx.navigate(); positionViewAtIndex(currentIndex, ListView.Contain) }
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

        PaneSlot {
            id: myProfileSlot
            selected: page.ready && page.current.key === "myprofile"
            sourceComponent: Component {
                MyProfilePane {
                    objectName: "paneMyProfile"
                    anchors.fill: parent
                    u: page.u
                    overlay: page.overlay
                    onExitRequested: page.leavePane()
                    onActivityRequested: page.openRequested("activity", ({}))
                }
            }
        }
        PaneSlot {
            id: manageProfilesSlot
            selected: page.ready && page.current.key === "profiles"
            sourceComponent: Component {
                ManageProfilesPane {
                    objectName: "paneProfiles"
                    anchors.fill: parent
                    u: page.u
                    overlay: page.overlay
                    onExitRequested: page.leavePane()
                }
            }
        }
        PaneSlot {
            id: displaySlot
            selected: page.ready && page.current.key === "display"
            sourceComponent: Component {
                DisplayPane {
                    objectName: "paneDisplay"
                    anchors.fill: parent
                    u: page.u
                    overlay: page.overlay
                    onExitRequested: page.leavePane()
                }
            }
        }
        PaneSlot {
            id: networkSlot
            selected: page.ready && page.current.key === "network"
            sourceComponent: Component {
                NetworkPane {
                    objectName: "paneNetwork"
                    anchors.fill: parent
                    u: page.u
                    overlay: page.overlay
                    onExitRequested: page.leavePane()
                }
            }
        }
        PaneSlot {
            id: bluetoothSlot
            selected: page.ready && page.current.key === "bluetooth"
            sourceComponent: Component {
                BluetoothPane {
                    objectName: "paneBluetooth"
                    anchors.fill: parent
                    u: page.u
                    overlay: page.overlay
                    onExitRequested: page.leavePane()
                }
            }
        }
        PaneSlot {
            id: audioSlot
            selected: page.ready && page.current.key === "audio"
            sourceComponent: Component {
                AudioPane {
                    objectName: "paneAudio"
                    anchors.fill: parent
                    u: page.u
                    overlay: page.overlay
                    onExitRequested: page.leavePane()
                }
            }
        }
        PaneSlot {
            id: storageSlot
            selected: page.ready && page.current.key === "storage"
            sourceComponent: Component {
                StoragePane {
                    objectName: "paneStorage"
                    anchors.fill: parent
                    u: page.u
                    onExitRequested: page.leavePane()
                }
            }
        }
        PaneSlot {
            id: powerSlot
            selected: page.ready && page.current.key === "power"
            sourceComponent: Component {
                PowerSavingPane {
                    objectName: "panePower"
                    anchors.fill: parent
                    u: page.u
                    onExitRequested: page.leavePane()
                }
            }
        }
        PaneSlot {
            id: systemSlot
            selected: page.ready && page.current.key === "system"
            sourceComponent: Component {
                SystemPane {
                    objectName: "paneSystem"
                    anchors.fill: parent
                    u: page.u
                    overlay: page.overlay
                    onExitRequested: page.leavePane()
                }
            }
        }
        PaneSlot {
            id: aboutSlot
            selected: page.ready && page.current.key === "about"
            sourceComponent: Component {
                AboutPane {
                    objectName: "paneAbout"
                    anchors.fill: parent
                    u: page.u
                    version: page.version
                    onExitRequested: page.leavePane()
                    onSystemInfoRequested: page.openRequested("systemInfo", ({}))
                }
            }
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
