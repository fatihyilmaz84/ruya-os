import QtQuick
import RuyaShell

// A Material Symbols Rounded glyph by name (04 §3.7). The table below is kept in step with
// fonts/icons.txt (scripts/lint-icons.ps1); an unknown name draws nothing and warns once.
// `filled` is for the current or selected state. Decorative: the owner carries the accessible name.
Item {
    id: icon

    property string name
    property real u: 1
    property real size: Theme.iconM         // design px, multiplied by `u`
    property color color: Theme.text
    property bool filled: false

    readonly property var codePoints: ({
        "settings": 0xe8b8,
        "volume_up": 0xe050,
        "volume_off": 0xe04f,
        "battery_full": 0xe1a5,
        "battery_alert": 0xe19c,
        "battery_charging_full": 0xe1a3,
        "battery_0_bar": 0xebdc,
        "battery_1_bar": 0xf09c,
        "battery_2_bar": 0xf09d,
        "battery_3_bar": 0xf09e,
        "battery_4_bar": 0xf09f,
        "battery_5_bar": 0xf0a0,
        "sports_esports": 0xea28,
        "headphones": 0xf01f,
        "speaker": 0xe32d,
        "mouse": 0xe323,
        "keyboard": 0xe312,
        "bluetooth": 0xe1a7,
        "bluetooth_disabled": 0xe1a9,
        "wifi": 0xe63e,
        "wifi_off": 0xe648,
        "lan": 0xeb2f,
        "smartphone": 0xe7ba,
        "pad_playstation": 0xe005,
        "pad_xbox": 0xe006,
        "pad_switch": 0xe007
    })
    readonly property bool known: name in codePoints

    implicitWidth: known ? glyph.implicitWidth : 0
    implicitHeight: known ? size * u : 0
    width: implicitWidth
    height: implicitHeight

    Accessible.ignored: true

    property bool warned: false
    function warnIfUnknown() {
        if (name !== "" && !known && !warned) {
            warned = true
            console.warn("Icon: unknown icon name '" + name + "'")
        }
    }
    onNameChanged: warnIfUnknown()
    Component.onCompleted: warnIfUnknown()

    Text {
        id: glyph
        anchors.centerIn: parent
        text: icon.known ? String.fromCodePoint(icon.codePoints[icon.name]) : ""
        color: icon.color
        font.family: icon.filled ? Theme.iconFamilyFilled : Theme.iconFamily
        font.pixelSize: icon.size * icon.u
    }
}
