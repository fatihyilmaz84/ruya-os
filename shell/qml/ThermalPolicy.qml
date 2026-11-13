pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// What the console does about heat (T-200; docs/specs/01-platform.md, "Thermal policy"). The
// service measures and classifies (Thermal.level); this is the response, in steps:
//   warm      nothing changes (Settings -> System shows it).
//   hot       one toast naming the sensor; the effects quality drops to "performance" for this
//             session (DeviceSettings.thermalLimited; the owner's setting is not rewritten) and
//             stays there until the level is back to normal. No second toast until then.
//   critical  a notice (ThermalNotice), every running app is asked to stop (Session.stop), and if
//             the level still holds `poweroffMs` later, the console powers off (Power.powerOff).
// Fans are never controlled here. The Item holds the notice; Shell places it above the Guide
// overlay.
Item {
    id: policy

    property real u: 1
    // How long a critical level may hold before the console powers off.
    property int poweroffMs: 60000

    readonly property bool noticeShown: notice.shown
    readonly property bool poweroffPending: poweroffTimer.running

    property bool hotNotified: false
    property bool inCritical: false
    // Instances Stop was already sent to in this critical spell.
    property var asked: ({})
    property double deadline: 0

    function sensorName() {
        return ThermalText.nameOf(Thermal.levelSensor)
    }

    function sensorText() {
        const sensor = Thermal.sensor(Thermal.levelSensor)
        return sensor.id ? qsTr("%1 is at %2").arg(sensorName()).arg(ThermalText.valueText(sensor)) : ""
    }

    function apply() {
        const level = Thermal.level
        if (level === "critical") {
            DeviceSettings.thermalLimited = true
            hotNotified = true
            enterCritical()
            return
        }
        leaveCritical()
        if (level === "hot") {
            DeviceSettings.thermalLimited = true
            if (!hotNotified) {
                hotNotified = true
                Notifications.show(qsTr("The console is running hot (%1). Effects are reduced.").arg(sensorName()), "warning", "",
                                   "device_thermostat")
            }
        } else if (level === "normal") {
            DeviceSettings.thermalLimited = false
            hotNotified = false
        }
        // warm: whatever was in force stays; nothing new starts.
    }

    function enterCritical() {
        if (inCritical)
            return
        inCritical = true
        asked = ({})
        deadline = Date.now() + poweroffMs
        notice.sensorText = sensorText()
        tick()
        notice.open()
        // Pinned in the notification centre until the console has cooled down (RUY-413); no toast,
        // the notice above says it.
        Notifications.keep("thermal-critical", qsTr("The console is too hot"), "error", "device_thermostat",
                           sensorText(), { source: "system", urgency: "critical", pinned: true })
        stopApps()
        poweroffTimer.interval = poweroffMs
        poweroffTimer.restart()
        countdown.restart()
    }

    function leaveCritical() {
        if (!inCritical)
            return
        inCritical = false
        asked = ({})
        poweroffTimer.stop()
        countdown.stop()
        notice.close()
        Notifications.remove("thermal-critical")
    }

    function stopApps() {
        for (const record of Session.running) {
            if (!asked[record.instance]) {
                asked[record.instance] = true
                Session.stop(record.instance)
            }
        }
    }

    function tick() {
        notice.secondsLeft = Math.max(0, Math.ceil((deadline - Date.now()) / 1000))
        notice.sensorText = sensorText()
    }

    Connections {
        target: Thermal
        function onLevelChanged() { policy.apply() }
    }

    // An app that starts while the console is critical is stopped, too.
    Connections {
        target: Session
        function onRunningChanged() {
            if (policy.inCritical)
                policy.stopApps()
        }
    }

    Timer {
        id: poweroffTimer
        objectName: "thermalPoweroffTimer"
        onTriggered: {
            if (Thermal.level === "critical")
                Power.powerOff()
        }
    }

    Timer {
        id: countdown
        interval: 250       // refreshes the seconds shown; not a duration of any effect
        repeat: true
        onTriggered: policy.tick()
    }

    ThermalNotice {
        id: notice
        objectName: "thermalNotice"
        anchors.fill: parent
        u: policy.u
    }

    Component.onCompleted: apply()
}
