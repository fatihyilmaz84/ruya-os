import QtQuick
import QtTest
import RuyaShell

// RUY-743: two connected controllers with the same shown name are "X" and "X 2" (then 3, 4) in the
// toasts, the battery chips, the Hub pads and the controller rows; the numbers are stable while the
// pads are connected; the paired list in Settings > Bluetooth keeps the address tail.
Item {
    id: host
    width: 400
    height: 300

    ControllerToasts { id: toasts }

    TestCase {
        id: tc
        name: "PadNumbers"
        when: windowShown

        function init() {
            Bluetooth.mockReset()
            Batteries.mockReset()
            DeviceIcons.padNumbers.holdMs = 60000
            // No pad at the start: the mock's one paired pad goes.
            Bluetooth.disconnectDevice("bt-pad-main")
            tryVerify(() => Bluetooth.gamepads.length === 0)
        }

        function cleanup() {
            Bluetooth.mockReset()
            Batteries.mockReset()
            DeviceIcons.padNumbers.holdMs = 60000
        }

        function plug(id, name, family) {
            Bluetooth.mockGamepad(true, id, name, family, "usb")
            tryVerify(() => Bluetooth.gamepads.some(g => g.id === id))
        }

        function unplug(id) {
            Bluetooth.mockGamepad(false, id, "x", "playstation", "usb")
            tryVerify(() => !Bluetooth.gamepads.some(g => g.id === id))
        }

        function toast(id) {
            return toasts.displayName(id, "DualSense", "playstation")
        }

        function test_two_wired_pads_of_a_kind_are_x_and_x_2_and_three_x_3() {
            plug("usb-a", "DualSense", "playstation")
            compare(toast("usb-a"), "PlayStation controller")
            plug("usb-b", "DualSense", "playstation")
            compare(toast("usb-a"), "PlayStation controller")
            compare(toast("usb-b"), "PlayStation controller 2")
            plug("usb-c", "DualSense", "playstation")
            compare(toast("usb-c"), "PlayStation controller 3")
        }

        function test_a_leaving_pad_does_not_renumber_and_the_lowest_free_number_is_taken() {
            plug("usb-a", "DualSense", "playstation")
            plug("usb-b", "DualSense", "playstation")
            unplug("usb-a")
            compare(toast("usb-b"), "PlayStation controller 2", "pad 2 stays 2")
            plug("usb-c", "DualSense", "playstation")
            compare(toast("usb-c"), "PlayStation controller", "the new pad takes the lowest free number")
            compare(toast("usb-b"), "PlayStation controller 2")
        }

        function test_a_reconnect_inside_the_hold_keeps_its_number_and_the_disconnect_toast_names_it() {
            plug("usb-a", "DualSense", "playstation")
            plug("usb-b", "DualSense", "playstation")
            unplug("usb-b")
            compare(toast("usb-b"), "PlayStation controller 2", "the disconnect toast names it as before")
            plug("usb-b", "DualSense", "playstation")
            compare(toast("usb-b"), "PlayStation controller 2", "its old number, still free")
        }

        function test_a_reconnect_inside_the_hold_does_not_take_a_number_that_is_taken() {
            plug("usb-a", "DualSense", "playstation")
            plug("usb-b", "DualSense", "playstation")
            unplug("usb-b")
            plug("usb-c", "DualSense", "playstation")
            compare(toast("usb-c"), "PlayStation controller 2", "usb-c took the free 2")
            plug("usb-b", "DualSense", "playstation")
            compare(toast("usb-b"), "PlayStation controller 3", "2 is taken: the lowest free")
        }

        function test_a_reconnect_after_the_hold_is_a_new_pad() {
            DeviceIcons.padNumbers.holdMs = 0
            plug("usb-a", "DualSense", "playstation")
            plug("usb-b", "DualSense", "playstation")
            plug("usb-c", "DualSense", "playstation")
            unplug("usb-b")
            plug("usb-d", "DualSense", "playstation")
            compare(toast("usb-d"), "PlayStation controller 2")
            unplug("usb-c")
            plug("usb-c", "DualSense", "playstation")
            compare(toast("usb-c"), "PlayStation controller 3", "the hold is over: the lowest free number")
        }

        function test_pads_with_other_names_get_no_number() {
            plug("usb-a", "DualSense", "playstation")
            plug("usb-b", "Xbox Wired", "xbox")
            compare(toasts.displayName("usb-a", "DualSense", "playstation"), "PlayStation controller")
            compare(toasts.displayName("usb-b", "Xbox Wired", "xbox"), "Xbox controller")
        }

        function test_the_hub_pads_are_numbered_by_their_own_names() {
            plug("usb-a", "Same Pad", "generic")
            plug("usb-b", "Same Pad", "generic")
            plug("usb-c", "Other Pad", "generic")
            const names = ControllerPads.hubPads().map(p => p.name).sort()
            compare(names.join("|"), "Other Pad|Same Pad|Same Pad 2")
        }

        function test_the_controller_rows_are_numbered() {
            const one = "usb-1111-0001-aaaaaaaaaaa1"
            const two = "usb-1111-0001-aaaaaaaaaaa2"
            plug("usb-a", "Twin Pad", "generic")
            plug("usb-b", "Twin Pad", "generic")
            Input.mockAddDevice({ id: one, name: "Twin Pad", family: "generic", connection: "usb" })
            Input.mockAddDevice({ id: two, name: "Twin Pad", family: "generic", connection: "usb" })
            tryVerify(() => ControllerPads.controllers().filter(p => p.name.startsWith("Twin Pad")).length === 2)
            const names = ControllerPads.controllers().map(p => p.name).filter(n => n.startsWith("Twin Pad")).sort()
            compare(names.join("|"), "Twin Pad|Twin Pad 2")
            compare(DeviceIcons.padName(two, "Twin Pad", "generic"), "Twin Pad 2", "Who's playing and the PIN pad")
            Input.mockRemoveDevice(one)
            Input.mockRemoveDevice(two)
        }

        // A number never changes while the pad stays connected: A connects, then B; A keeps its name in every list.
        function test_a_pad_keeps_its_name_in_every_list_when_another_connects() {
            const one = "usb-1111-0002-aaaaaaaaaaa1"
            const two = "usb-1111-0002-aaaaaaaaaaa2"
            plug("usb-a", "Twin Pad", "generic")
            Input.mockAddDevice({ id: one, name: "Twin Pad", family: "generic", connection: "usb" })
            Batteries.mockClear()
            Batteries.mockSet("up-a", 50, "discharging", "controller", "Twin Pad", "generic")
            tryVerify(() => Batteries.devices.length === 1)
            tryVerify(() => ControllerPads.controllers().some(p => p.id === one))
            const seen = () => [DeviceIcons.padName("usb-a", "Twin Pad", "generic"),
                                DeviceIcons.padName(one, "Twin Pad", "generic"),
                                ControllerPads.controllers().find(p => p.id === one).name,
                                ControllerPads.hubPads().find(p => p.id === "usb-a").name,
                                DeviceIcons.batteryName(Batteries.devices.find(b => b.id === "up-a"))]
            compare(seen().join("|"), "Twin Pad|Twin Pad|Twin Pad|Twin Pad|Twin Pad")
            plug("usb-b", "Twin Pad", "generic")
            Input.mockAddDevice({ id: two, name: "Twin Pad", family: "generic", connection: "usb" })
            Batteries.mockSet("up-b", 60, "discharging", "controller", "Twin Pad", "generic")
            tryVerify(() => Batteries.devices.length === 2)
            tryVerify(() => ControllerPads.controllers().some(p => p.id === two))
            compare(seen().join("|"), "Twin Pad|Twin Pad|Twin Pad|Twin Pad|Twin Pad", "A is unchanged in every list")
            compare(DeviceIcons.padName("usb-b", "Twin Pad", "generic"), "Twin Pad 2")
            compare(DeviceIcons.padName(two, "Twin Pad", "generic"), "Twin Pad 2")
            compare(ControllerPads.controllers().find(p => p.id === two).name, "Twin Pad 2")
            compare(DeviceIcons.batteryName(Batteries.devices.find(b => b.id === "up-b")), "Twin Pad 2")
            Input.mockRemoveDevice(one)
            Input.mockRemoveDevice(two)
        }

        // Controls in games: "DualSense" and "DualSense 2", the number kept after the shortened name.
        function test_controls_in_games_tells_two_dualsense_pads_apart() {
            Bluetooth.mockSetName("bt-pad-main", "DualSense Wireless Controller")
            Bluetooth.mockSetName("bt-pad-old", "DualSense Wireless Controller")
            Bluetooth.connectDevice("bt-pad-main")
            Bluetooth.connectDevice("bt-pad-old")
            tryVerify(() => Bluetooth.gamepads.length === 2)
            const one = "bluetooth-054c-0ce6-aa0000000004"
            const two = "bluetooth-054c-0ce6-3f2a9c41d0b7"   // the mock's own DualSense, there from the start
            Input.mockAddDevice({ id: one, name: "DualSense Wireless Controller", family: "playstation", connection: "bluetooth" })
            tryVerify(() => ControllerPads.controllers().filter(p => p.id === one || p.id === two).length === 2)
            const rows = ControllerPads.controllers().filter(p => p.id === one || p.id === two)
            const shorts = rows.map(p => GameControls.shortName(p.nameBase, p.nameTail)).sort()
            compare(shorts.join("|"), "DualSense|DualSense 2")
            // A long name is cut, never its number.
            compare(GameControls.shortName("W".repeat(48), " 2").length, 30)
            verify(GameControls.shortName("W".repeat(48), " 2").endsWith(" 2"))
            Input.mockRemoveDevice(one)
        }

        function test_two_bluetooth_pads_with_one_alias_are_numbered_and_the_paired_list_keeps_the_address_tail() {
            Bluetooth.mockSetName("bt-pad-main", "Wireless Controller")
            Bluetooth.mockSetName("bt-pad-old", "Wireless Controller")
            Bluetooth.connectDevice("bt-pad-main")
            Bluetooth.connectDevice("bt-pad-old")
            tryVerify(() => Bluetooth.gamepads.length === 2)
            const first = Bluetooth.gamepads[0].id
            const second = Bluetooth.gamepads[1].id
            compare(DeviceIcons.padName(first, "Wireless Controller", "playstation"), "Wireless Controller")
            compare(DeviceIcons.padName(second, "Wireless Controller", "playstation"), "Wireless Controller 2")
            compare(ControllerPads.hubPads().map(p => p.name).sort().join("|"), "Wireless Controller|Wireless Controller 2")
            // The paired list: the address tail, never the number.
            const paired = Bluetooth.devices.filter(d => d.name === "Wireless Controller")
            compare(paired.length, 2)
            verify(DeviceIcons.shownName(Bluetooth.devices, paired[0]).indexOf("(") > 0)
        }

        function test_two_pads_renamed_differently_get_no_number() {
            Bluetooth.mockSetName("bt-pad-main", "Red Pad")
            Bluetooth.mockSetName("bt-pad-old", "Blue Pad")
            Bluetooth.connectDevice("bt-pad-main")
            Bluetooth.connectDevice("bt-pad-old")
            tryVerify(() => Bluetooth.gamepads.length === 2)
            compare(DeviceIcons.padName("bt-pad-main", "x", "playstation"), "Red Pad")
            compare(DeviceIcons.padName("bt-pad-old", "x", "playstation"), "Blue Pad")
        }

        function test_two_controller_batteries_of_a_name_are_numbered() {
            Batteries.mockClear()
            Batteries.mockSet("up-1", 50, "discharging", "controller", "Twin Pad", "xbox")
            Batteries.mockSet("up-2", 60, "discharging", "controller", "Twin Pad", "xbox")
            tryVerify(() => Batteries.devices.length === 2)
            compare(DeviceIcons.batteryName(Batteries.devices.find(b => b.id === "up-1")), "Twin Pad")
            compare(DeviceIcons.batteryName(Batteries.devices.find(b => b.id === "up-2")), "Twin Pad 2")
            Batteries.mockRemove("up-1")
            tryVerify(() => Batteries.devices.length === 1)
            compare(DeviceIcons.batteryName(Batteries.devices[0]), "Twin Pad 2", "stays 2")
        }
    }
}
