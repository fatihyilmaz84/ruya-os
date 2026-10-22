pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtMultimedia

// Phase 0 hello shell: proves fullscreen Wayland rendering, a shared-backdrop blur,
// controller/keyboard focus navigation and UI sound. Not the real home screen.
Window {
    id: root

    required property string version
    property bool windowed: false        // --windowed, development only

    readonly property real u: height / 1080
    readonly property Tile currentTile: tiles.currentItem as Tile
    readonly property real marginX: width * Theme.safeArea
    readonly property real marginY: height * Theme.safeArea

    width: 1920
    height: 1080
    visibility: windowed ? Window.Windowed : Window.FullScreen   // implies visible; don't also set `visible`
    color: Theme.background
    title: "RuyaOS"

    SoundEffect { id: sfxNavigate; source: "qrc:/qt/qml/RuyaShell/sounds/navigate.wav"; volume: 0.6 }
    SoundEffect { id: sfxSelect; source: "qrc:/qt/qml/RuyaShell/sounds/select.wav" }
    SoundEffect { id: sfxBack; source: "qrc:/qt/qml/RuyaShell/sounds/back.wav" }

    Backdrop {
        id: backdrop
        anchors.fill: parent
        tint: root.currentTile ? root.currentTile.accent : "#3a5bd9"
    }

    // Header
    Text {
        id: brand
        x: root.marginX
        y: root.marginY
        text: "RuyaOS"
        color: Theme.text
        font.pixelSize: 44 * root.u
        font.weight: Font.Bold
    }
    Text {
        id: clock
        anchors { right: parent.right; rightMargin: root.marginX; verticalCenter: brand.verticalCenter }
        color: Theme.text
        font.pixelSize: 36 * root.u
        text: Qt.formatTime(new Date(), "HH:mm")
        Timer {
            interval: 10000; running: true; repeat: true
            onTriggered: clock.text = Qt.formatTime(new Date(), "HH:mm")
        }
    }

    // Frosted shelf: blurs only the backdrop region behind it (one shared source, no
    // second render of the scene).
    Item {
        id: shelf
        anchors {
            left: parent.left; right: parent.right
            bottom: parent.bottom; bottomMargin: root.marginY + 60 * root.u
        }
        height: 380 * root.u
        clip: true

        MultiEffect {
            x: -shelf.x
            y: -shelf.y
            width: root.width
            height: root.height
            source: backdrop
            autoPaddingEnabled: false
            blurEnabled: true
            blur: 1.0
            blurMax: Theme.blurMax
            brightness: -0.08
            saturation: 0.15
        }
        Rectangle {
            anchors.fill: parent
            color: Theme.glass
            Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top } height: Math.max(1, root.u); color: Theme.glassBorder }
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: Math.max(1, root.u); color: Theme.glassBorder }
        }
    }

    Text {
        anchors { left: shelf.left; leftMargin: root.marginX; bottom: shelf.top; bottomMargin: 20 * root.u }
        text: root.currentTile ? root.currentTile.title : ""
        color: Theme.text
        font.pixelSize: 64 * root.u
        font.weight: Font.Light
    }

    ListView {
        id: tiles
        objectName: "tiles"

        anchors { left: shelf.left; right: shelf.right; verticalCenter: shelf.verticalCenter }
        leftMargin: root.marginX
        rightMargin: root.marginX
        height: 260 * root.u
        orientation: ListView.Horizontal
        spacing: 36 * root.u
        focus: true
        keyNavigationWraps: false
        highlightMoveDuration: Theme.focusMs
        highlightRangeMode: ListView.ApplyRange
        preferredHighlightBegin: root.marginX
        preferredHighlightEnd: width - root.marginX
        interactive: false           // no flicking...
        keyNavigationEnabled: true   // ...but keys still navigate (defaults to `interactive`)
        clip: false

        model: ListModel {
            ListElement { title: "Games"; accent: "#3a5bd9" }
            ListElement { title: "Media"; accent: "#d9483a" }
            ListElement { title: "Store"; accent: "#2fa37a" }
            ListElement { title: "Settings"; accent: "#7a5bd9" }
            ListElement { title: "Power"; accent: "#5a6478" }
        }

        delegate: Tile {
            u: root.u
            width: 400 * root.u
            height: tiles.height
        }

        onCurrentIndexChanged: sfxNavigate.play()
        Keys.onReturnPressed: { root.currentTile.pulse(); sfxSelect.play() }
        Keys.onEnterPressed: { root.currentTile.pulse(); sfxSelect.play() }
        Keys.onPressed: event => {
            if (event.key === Qt.Key_HomePage || event.key === Qt.Key_Menu) {
                systemPanel.open = true
                sfxSelect.play()
                event.accepted = true
            } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                sfxBack.play()
                event.accepted = true
            }
        }
    }

    // Placeholder for the Guide overlay: build/version info used by the update tests.
    Rectangle {
        id: systemPanel

        property bool open: false

        anchors.fill: parent
        color: "#b0000000"
        opacity: open ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }
        onOpenChanged: open ? panelFocus.forceActiveFocus() : tiles.forceActiveFocus()

        FocusScope {
            id: panelFocus
            objectName: "systemPanelFocus"
            anchors.fill: parent
            Keys.onPressed: event => {
                if ([Qt.Key_Escape, Qt.Key_Back, Qt.Key_HomePage, Qt.Key_Menu].includes(event.key)) {
                    systemPanel.open = false
                    sfxBack.play()
                }
                event.accepted = true      // modal: nothing leaks to the shelf underneath
            }
        }

        Column {
            anchors.centerIn: parent
            spacing: 16 * root.u
            Text { text: "System"; color: Theme.text; font.pixelSize: 56 * root.u; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: "Image version " + root.version; color: Theme.textDim; font.pixelSize: 32 * root.u; anchors.horizontalCenter: parent.horizontalCenter }
            FpsMeter { font.pixelSize: 32 * root.u; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: "Back to close"; color: Theme.textDim; font.pixelSize: 24 * root.u; anchors.horizontalCenter: parent.horizontalCenter }
        }
    }

    // Always-on version tag: the update/rollback checks read it off the screen.
    Text {
        anchors { right: parent.right; bottom: parent.bottom; margins: root.marginY / 2 }
        text: root.version
        color: Theme.textDim
        font.pixelSize: 20 * root.u
    }
}
