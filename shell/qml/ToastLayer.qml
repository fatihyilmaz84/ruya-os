pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Toast stack at the top right, below the header. Never takes focus and never accepts
// input, so it can sit above pages without touching the focus chain.
Item {
    id: layer

    property real u: 1
    property real marginX: 0
    property real marginY: 0

    readonly property int visibleCount: list.count

    // A game controller was plugged in, paired or lost (T-260). The Shell tells it about every key
    // so that "disconnected" is shown only for a pad that was in use.
    readonly property ControllerToasts controllerToasts: ControllerToasts {
        objectName: "controllerToasts"
    }
    function noteInput() { controllerToasts.noteInput() }

    // A connected Bluetooth device's battery is low (once per crossing, Bluetooth.batteryLow).
    Connections {
        target: Bluetooth
        function onBatteryLow(id, name, percent, kind, family) {
            Notifications.show(qsTr("%1: battery low (%2%)").arg(name).arg(percent), "warning", "",
                               DeviceIcons.iconFor(kind, family))
        }
    }

    // A controller (UPower) is discharging at 15 % or less (once per crossing, Batteries.batteryLow).
    // This is the only low-battery toast for controllers: Bluetooth.batteryLow skips them.
    Connections {
        target: Batteries
        function onBatteryLow(id, name, percent, family) {
            Notifications.show(qsTr("Controller battery low"), "warning", "", DeviceIcons.iconFor("controller", family),
                               qsTr("%1 · %2%").arg(DeviceIcons.padName(id, name, family)).arg(percent))
        }
    }

    // A drive was plugged in (once per drive and insert, when its volumes are in the list; a stick
    // with several partitions names the first and counts the rest), and an eject finished.
    // No actions yet; nothing on the drive is opened or run.
    Connections {
        target: Storage
        function onDriveAdded(drive, label, volumeCount) {
            Notifications.show(qsTr("Drive inserted"), "info", "", "usb",
                               volumeCount > 1 ? qsTr("%1 (and %n more)", "", volumeCount - 1).arg(label)
                                               : label)
        }
        function onFinished(op, id, status) {
            if (op === "eject" && status === "ok")
                Notifications.show(qsTr("Safe to remove"), "success")
        }
    }

    // Over an app (02-shell 1.5) the toast is the compact variant: 480 u, title only, at the safe
    // area (there is no top bar over an app).
    readonly property bool compact: Notifications.appInFront
    property bool gpu: GraphicsInfo.api !== GraphicsInfo.Software   // overridable, so tests reach the GPU path offscreen

    ListView {
        id: list
        objectName: "toastList"
        anchors {
            right: parent.right; rightMargin: layer.marginX
            top: parent.top; topMargin: layer.marginY + (layer.compact ? 0 : Theme.spaceXxxl * layer.u)
        }
        width: (layer.compact ? 480 : 600) * layer.u
        height: Notifications.maxVisible * 180 * layer.u
        spacing: Theme.spaceS * layer.u
        interactive: false
        keyNavigationEnabled: false
        activeFocusOnTab: false
        model: Notifications.model

        add: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap }
                NumberAnimation { property: "x"; from: Theme.pageSlide * layer.u; to: 0; duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap }
            }
        }
        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap }
        }
        displaced: Transition {
            NumberAnimation { property: "y"; duration: Theme.focusMs; easing.type: Easing.OutCubic }
        }

        delegate: Item {
            id: toast
            required property int toastId
            required property string text
            required property string kind
            required property string iconText
            required property string iconName
            required property string detail
            required property string footer
            required property string footerButton
            required property bool sticky

            readonly property color accent: Theme.toastColor(kind)
            readonly property bool compact: layer.compact
            readonly property bool hasDetail: !compact && detail !== ""
            // A sticky toast keeps its footer over an app too: a title-only restart notice would not say how to wait.
            readonly property bool hasFooter: footer !== "" && (!compact || sticky)
            // A sticky toast over an app (the restart notice) is never cut off: its title may wrap to two
            // lines and its footer spans the card's full inner width.
            readonly property bool fullSticky: compact && sticky
            readonly property real pad: Theme.spaceM * layer.u
            readonly property real badgeSize: (compact ? 48 : 64) * layer.u
            // The card: 112 u with a detail, 96 u without, 80 u compact; a footer adds its own line.
            readonly property real baseHeight: (compact ? 80 : hasDetail ? 112 : 96) * layer.u
            // The hook for a source's art as the badge (T-246, planned): nothing is built on it yet.
            property string badgeSource: ""

            width: list.width
            height: hasFooter ? footerRow.y + footerRow.implicitHeight + Theme.spaceS * layer.u : baseHeight

            GlassShadow {
                objectName: "toastShadow"
                z: -1                   // behind the toast's own fill
                anchors.fill: parent
                u: layer.u
                radius: card.radius
                kind: "panel"
            }
            Rectangle {
                id: card
                objectName: "toastCard"
                anchors.fill: parent
                radius: Theme.radiusL * layer.u
                color: Theme.toastBackground
            }
            GlassLayers {
                objectName: "toastLayers"
                anchors.fill: parent
                u: layer.u
                radius: card.radius
                grain: false            // a toast is not blurred
            }

            Rectangle {
                id: badge
                objectName: "toastBadge"
                x: toast.pad
                y: (toast.baseHeight - height) / 2
                width: toast.badgeSize
                height: width
                radius: width / 2
                color: Theme.toastBadgeFill(toast.kind)

                Icon {
                    id: glyph
                    objectName: "toastIcon"
                    anchors.centerIn: parent
                    u: layer.u
                    size: toast.compact ? 32 : Theme.iconM
                    // A device icon wins over the kind's default; a text character (iconText) replaces both.
                    visible: name !== ""
                    name: toast.iconName !== "" ? toast.iconName
                        : toast.iconText !== "" ? ""
                        : toast.kind === "success" ? "check_circle"
                        : toast.kind === "warning" ? "warning"
                        : toast.kind === "error" ? "error" : "info"
                    color: toast.accent
                }
                Text {
                    anchors.centerIn: parent
                    visible: toast.iconName === "" && toast.iconText !== ""
                    text: toast.iconText
                    color: toast.accent
                    font.pixelSize: Theme.typeHeadline * layer.u
                    font.weight: Theme.weightDemiBold
                }
            }

            Column {
                id: texts
                x: badge.x + badge.width + toast.pad
                width: toast.width - x - toast.pad
                y: toast.fullSticky ? Math.max(Theme.spaceS * layer.u, (toast.baseHeight - height) / 2) : (toast.baseHeight - height) / 2
                Item {
                    objectName: "toastTitle"      // the title line; its Text is "toastText" (the toast's own words)
                    width: parent.width
                    height: titleText.implicitHeight
                    Text {
                        id: titleText
                        objectName: "toastText"
                        width: parent.width
                        // A toast may carry a name a device gave itself: never markup (T-260).
                        text: toast.text
                        textFormat: Text.PlainText
                        color: Theme.text
                        font.pixelSize: Theme.typeBody * layer.u
                        font.weight: Theme.weightDemiBold
                        elide: Text.ElideRight
                        wrapMode: toast.fullSticky ? Text.Wrap : Text.NoWrap
                        maximumLineCount: toast.fullSticky ? 2 : 1
                    }
                }
                Text {
                    objectName: "toastDetail"
                    visible: toast.hasDetail
                    width: parent.width
                    text: toast.detail
                    textFormat: Text.PlainText
                    color: Theme.textDim
                    font.pixelSize: Theme.typeCaption * layer.u
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }

            // A sticky instruction ("Press any button to wait"), under the text column.
            Row {
                id: footerRow
                objectName: "toastFooter"
                visible: toast.hasFooter
                x: toast.fullSticky ? toast.pad : texts.x
                y: texts.y + texts.height + 24 * layer.u      // the footer starts 24 u under the text column
                width: toast.width - x - toast.pad
                spacing: Theme.spaceS * layer.u
                ButtonGlyph {
                    id: footerGlyph
                    visible: toast.footerButton !== ""
                    button: toast.footerButton
                    u: layer.u
                }
                Text {
                    objectName: "toastFooterText"
                    width: parent.width - (footerGlyph.visible ? footerGlyph.width + parent.spacing : 0)
                    text: toast.footer
                    textFormat: Text.PlainText
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * layer.u
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }

            // The time left: a thin line along the bottom edge, cut to the rounded corners on a GPU.
            // Not on a sticky toast, and not under reduced motion.
            Item {
                id: timerClip
                anchors.fill: parent
                visible: !toast.sticky && Theme.motionScale > 0
                clip: true              // rectangular; the software renderer has no rounded mask
                layer.enabled: visible && layer.gpu
                layer.smooth: true
                layer.effect: SmoothMask { maskSource: timerMask }
                Rectangle {
                    id: timerMask
                    anchors.fill: parent
                    radius: card.radius
                    visible: false
                    layer.enabled: timerClip.layer.enabled
                    layer.smooth: true
                }
                Rectangle {
                    objectName: "toastTimer"
                    anchors { left: parent.left; bottom: parent.bottom }
                    height: 3 * layer.u
                    width: parent.width
                    color: Theme.toastTimerColor(toast.kind)
                    NumberAnimation on width {
                        from: timerClip.width; to: 0
                        duration: Notifications.durationMs
                        running: timerClip.visible
                    }
                }
            }

            Timer {
                interval: Notifications.durationMs
                running: !toast.sticky
                onTriggered: Notifications.dismiss(toast.toastId)
            }
        }
    }

    // The toasts waiting behind the ones on screen, while the shell is in front.
    Rectangle {
        id: overflow
        objectName: "toastOverflow"
        visible: Notifications.pendingCount > 0 && !Notifications.appInFront
        anchors.right: list.right
        y: list.y + list.contentHeight + Theme.spaceS * layer.u
        height: 56 * layer.u
        width: chipRow.implicitWidth + 2 * Theme.spaceM * layer.u
        radius: height / 2
        color: Theme.toastBackground
        GlassShadow { z: -1; anchors.fill: parent; u: layer.u; radius: overflow.radius; kind: "pill" }
        GlassLayers { anchors.fill: parent; u: layer.u; radius: overflow.radius; grain: false }
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: Theme.spaceS * layer.u
            Icon { name: "notifications"; size: 32; u: layer.u; color: Theme.textDim }
            Text {
                objectName: "toastOverflowText"
                text: qsTr("%n more", "", Notifications.pendingCount)
                color: Theme.text
                font.pixelSize: Theme.typeCaption * layer.u
            }
        }
    }
}
