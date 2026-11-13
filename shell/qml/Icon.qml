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
        "mic": 0xe31d,
        "mic_off": 0xe02b,
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
        "monitoring": 0xf190,
        "power_settings_new": 0xf8c7,
        "info": 0xe88e,
        "check_circle": 0xf0be,
        "warning": 0xf083,
        "error": 0xf8b6,
        "usb": 0xe1e0,
        "restart_alt": 0xf053,
        "system_update": 0xf2cd,
        "notifications": 0xe7f5,
        "notifications_paused": 0xe7f8,
        "push_pin": 0xf10d,
        "clear_all": 0xe0b8,
        "device_thermostat": 0xe1ff,
        "download_done": 0xf091,
        "schedule": 0xefd6,
        "chevron_left": 0xe5cb,
        "chevron_right": 0xe5cc,
        "play_arrow": 0xe037,
        "close": 0xe5cd,
        "delete": 0xe92e,
        "bar_chart": 0xe26b,
        "more_horiz": 0xe5d3,
        "pad_8bitdo_pro2": 0xee00,
        "pad_8bitdo_sn30pro": 0xee01,
        "pad_8bitdo_ultimate": 0xee02,
        "pad_arcade_stick": 0xee03,
        "pad_dualsense": 0xee04,
        "pad_dualsense_edge": 0xee05,
        "pad_dualshock3": 0xee06,
        "pad_dualshock4": 0xee07,
        "pad_gamecube": 0xee08,
        "pad_generic_pad": 0xee09,
        "pad_joycon_left": 0xee0a,
        "pad_joycon_pair": 0xee0b,
        "pad_joycon_right": 0xee0c,
        "pad_keyboard": 0xee0d,
        "pad_n64": 0xee0e,
        "pad_retro_pad": 0xee0f,
        "pad_stadia": 0xee10,
        "pad_steam_controller": 0xee11,
        "pad_steam_deck": 0xee12,
        "pad_switch_pro": 0xee13,
        "pad_wii_remote": 0xee14,
        "pad_wii_remote_nunchuk": 0xee15,
        "pad_wiiu_pro": 0xee16,
        "pad_xbox_360": 0xee17,
        "pad_xbox_adaptive": 0xee18,
        "pad_xbox_elite": 0xee19,
        "pad_xbox_one": 0xee1a,
        "pad_xbox_series": 0xee1b
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
