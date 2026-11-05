pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Section nav (04 §5): a glass pill of section pills (Home, Games, Media, Store, Settings).
// The current section is filled with `primaryFill`; the focused pill carries the white ring.
// Left/Right move between pills, Accept emits `activated(key)`, Down leaves downwards, LB/RB
// ask for the next/previous section (`stepRequested`), Back asks to go back (`backRequested`).
// One instance lives in the shell's top layer and is shown on Home and the section pages.
// The glass blurs a crop of `blurSource` (the shared backdrop layer); with no blur (the
// Performance tier) it is `glassOpaque`.
FocusScope {
    id: nav

    property real u: 1
    property var keys: ["home", "games", "media", "store", "settings"]   // keys only: labels follow the language
    property string section: "home"      // the section on screen
    property int currentIndex: 0         // the pill that has (or last had) focus
    property Item blurSource
    property real blurX: 0               // position of this item in `blurSource` coordinates
    property real blurY: 0

    readonly property string currentKey: keys[currentIndex]

    signal activated(string key)
    signal downRequested()
    signal stepRequested(int direction)
    signal backRequested()

    function label(key) {
        switch (key) {
        case "home": return qsTr("Home")
        case "games": return qsTr("Games")
        case "media": return qsTr("Media")
        case "store": return qsTr("Store")
        case "settings": return qsTr("Settings")
        }
        return key
    }

    implicitWidth: pills.width + 2 * Theme.spaceXs * u
    implicitHeight: Theme.buttonHeight * u + 2 * Theme.spaceXs * u
    width: implicitWidth
    height: implicitHeight

    Accessible.role: Accessible.PageTabList
    // The nav holds focus, not its pills: the name follows the current pill.
    Accessible.name: label(currentKey)

    GlassPill {
        objectName: "sectionNavGlass"
        anchors.fill: parent
        u: nav.u
        source: nav.blurSource
        sourceX: nav.blurX
        sourceY: nav.blurY
    }

    Row {
        id: pills
        anchors.centerIn: parent
        spacing: Theme.spaceXxs * nav.u

        Repeater {
            model: nav.keys

            delegate: Item {
                id: pill

                required property int index
                required property string modelData
                readonly property bool isSection: modelData === nav.section
                readonly property bool focused: nav.activeFocus && index === nav.currentIndex

                objectName: "navPill_" + modelData
                width: Math.max(height, text.implicitWidth + 2 * Theme.spaceL * nav.u)
                height: Theme.buttonHeight * nav.u

                Accessible.role: Accessible.PageTab
                Accessible.name: nav.label(modelData)
                Accessible.selected: isSection

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: pill.isSection ? Theme.primaryFill : (pill.focused ? Theme.focusFill : "transparent")
                    border.width: pill.focused && !pill.isSection ? Theme.focusRingWidth * nav.u : 0
                    border.color: Theme.focusRing
                }
                // The current pill is white, so its ring sits outside with a gap (PrimaryButton).
                Rectangle {
                    objectName: "navPillRing_" + pill.modelData
                    anchors.fill: parent
                    anchors.margins: -Theme.focusRingOffset * nav.u
                    radius: height / 2
                    color: "transparent"
                    border.width: Theme.focusRingWidth * nav.u
                    border.color: Theme.focusRing
                    visible: pill.focused && pill.isSection
                }
                Text {
                    id: text
                    anchors.centerIn: parent
                    text: pill.modelData === "settings" ? "" : nav.label(pill.modelData)
                    color: pill.isSection ? Theme.onPrimary : Theme.text
                    font.pixelSize: Theme.typeBody * nav.u
                    font.weight: pill.isSection ? Theme.weightDemiBold : Theme.weightRegular
                }
                // The Settings pill is an icon, filled while Settings is the section on screen; its
                // name is the accessible name of the pill.
                Icon {
                    objectName: "navIcon_" + pill.modelData
                    anchors.centerIn: parent
                    visible: pill.modelData === "settings"
                    name: pill.modelData === "settings" ? "settings" : ""
                    u: nav.u
                    filled: pill.isSection
                    color: pill.isSection ? Theme.onPrimary : Theme.text
                }
            }
        }
    }

    onCurrentIndexChanged: if (activeFocus) Sfx.navigate()

    Keys.onPressed: event => {
        // Left/Right are visual: under a mirrored layout Left is the next pill.
        const step = nav.LayoutMirroring.enabled ? -1 : 1
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            const next = currentIndex + (event.key === Qt.Key_Right ? step : -step)
            if (next >= 0 && next < keys.length)
                currentIndex = next
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            nav.downRequested()
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            event.accepted = true          // the top of the screen
        } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
            nav.stepRequested(event.key === Qt.Key_PageDown ? 1 : -1)
            event.accepted = true
        } else if (BackKey.isBackOrBackspace(event.key)) {
            nav.backRequested()
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            Sfx.select()
            nav.activated(currentKey)
            event.accepted = true
        }
    }
}
