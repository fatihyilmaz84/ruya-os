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

    readonly property var categories: [
        { key: "profiles", label: qsTr("Profiles") },
        { key: "network", label: qsTr("Network") },
        { key: "bluetooth", label: qsTr("Bluetooth & controllers") },
        { key: "display", label: qsTr("Display & motion") },
        { key: "audio", label: qsTr("Audio") },
        { key: "storage", label: qsTr("Storage") },
        { key: "accessibility", label: qsTr("Accessibility") },
        { key: "system", label: qsTr("System") },
        { key: "about", label: qsTr("About") },
    ]
    readonly property var current: categories[categoryList.currentIndex]
    readonly property SettingsPane currentPane: current.key === "profiles" ? profilesPane
                                              : current.key === "display" ? displayPane
                                              : current.key === "about" ? aboutPane : null

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
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: 470 * page.u
        spacing: 10 * page.u
        focus: true
        interactive: false
        keyNavigationEnabled: true
        keyNavigationWraps: false
        clip: false
        model: page.categories

        onCurrentIndexChanged: Sfx.navigate()
        Keys.onReturnPressed: page.enterPane()
        Keys.onEnterPressed: page.enterPane()
        Keys.onRightPressed: page.enterPane()

        delegate: Rectangle {
            id: category
            required property int index
            required property var modelData
            readonly property bool selected: ListView.isCurrentItem
            readonly property bool focused: selected && categoryList.activeFocus

            width: categoryList.width
            height: 72 * page.u
            radius: height / 2
            color: focused ? Theme.focusFill : selected ? Theme.selectedFill : "transparent"
            border.width: focused ? 4 * page.u : selected ? Math.max(1, page.u) : 0
            border.color: focused ? Theme.focusRing : Theme.glassBorder
            Behavior on color { ColorAnimation { duration: Theme.focusMs } }

            Text {
                anchors { left: parent.left; leftMargin: 32 * page.u; right: parent.right; rightMargin: 24 * page.u; verticalCenter: parent.verticalCenter }
                text: category.modelData.label
                color: category.selected ? Theme.text : Theme.textDim
                font.pixelSize: 30 * page.u
                elide: Text.ElideRight
            }
        }
    }

    Item {
        id: paneArea
        anchors { left: categoryList.right; leftMargin: 60 * page.u; right: parent.right; top: parent.top; bottom: parent.bottom }

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
            visible: page.current.key === "display"
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
        }
        Column {
            objectName: "paneComingSoon"
            visible: page.currentPane === null
            spacing: 16 * page.u
            Text {
                text: page.current.label
                color: Theme.text
                font.pixelSize: 44 * page.u
                font.weight: Font.Light
            }
            Text {
                text: qsTr("Coming soon")
                color: Theme.textDim
                font.pixelSize: 32 * page.u
            }
        }
    }
}
