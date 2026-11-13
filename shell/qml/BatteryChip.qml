import QtQuick
import RuyaShell

// One device's battery in the status cluster (T-223, 02 §1.1, 04 §3.7): the icon of the device's
// kind, a battery glyph that matches the level, and the percentage. Looked up by `deviceId` in
// Batteries.devices, so the chip stays put while the level changes. Never focusable; the
// accessible name says device and level. Warning colour while the device is discharging at 15 %
// or less (Batteries' `low`).
Row {
    id: chip

    property string deviceId
    property real u: 1

    // The level glyph, seven steps (04 §3.7): 0-7, 8-21, 22-35, 36-50, 51-64, 65-78, 79-100 %.
    // The alert glyph replaces it while low, the bolt one while charging, the full one when the
    // device says it is full.
    function levelIconFor(percent, state, low) {
        if (low)
            return "battery_alert"
        if (state === "charging")
            return "battery_charging_full"
        if (state === "full" || percent >= 79)
            return "battery_full"
        if (percent >= 65)
            return "battery_5_bar"
        if (percent >= 51)
            return "battery_4_bar"
        if (percent >= 36)
            return "battery_3_bar"
        if (percent >= 22)
            return "battery_2_bar"
        if (percent >= 8)
            return "battery_1_bar"
        return "battery_0_bar"
    }

    readonly property var device: Batteries.devices.find(d => d.id === chip.deviceId) ?? ({})
    readonly property string deviceName: DeviceIcons.batteryName(chip.device)
    readonly property int percent: chip.device.percent ?? 0
    readonly property string chargeState: chip.device.state ?? "unknown"
    readonly property bool low: chip.device.low ?? false
    // The glyph of the device: the one table every screen uses (DeviceIcons), with the family the
    // service told (T-260) and its model (RUY-491), so a pad looks the same here as in Settings and in the toasts.
    readonly property string kindIcon: DeviceIcons.iconFor(chip.device.kind ?? "", chip.device.family ?? "",
                                                           chip.device.model ?? "")
    readonly property string levelIcon: levelIconFor(percent, chargeState, low)
    readonly property color tone: low ? Theme.warningText : Theme.text

    spacing: Theme.spaceXs * chip.u

    Accessible.role: Accessible.StaticText
    Accessible.name: low ? qsTr("%1 battery %2 percent, low").arg(deviceName).arg(percent)
                   : chargeState === "charging" ? qsTr("%1 battery %2 percent, charging").arg(deviceName).arg(percent)
                   : qsTr("%1 battery %2 percent").arg(deviceName).arg(percent)

    Icon {
        objectName: "batteryKindIcon"
        anchors.verticalCenter: parent.verticalCenter
        u: chip.u
        name: chip.kindIcon
        color: chip.tone
    }
    Icon {
        objectName: "batteryLevelIcon"
        anchors.verticalCenter: parent.verticalCenter
        u: chip.u
        name: chip.levelIcon
        color: chip.tone
    }
    Text {
        objectName: "batteryPercent"
        anchors.verticalCenter: parent.verticalCenter
        text: chip.percent + "%"
        color: chip.tone
        font.pixelSize: Theme.typeBody * chip.u
    }
}
