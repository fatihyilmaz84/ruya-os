//! Which family a game controller belongs to (T-199, `org.ruyaos.Devices1.Bluetooth.ListDevices`
//! key `family`): "playstation", "xbox", "nintendo", or "" when we cannot tell. One small table in
//! one place: the controller-family audit (T-261) extends `VENDORS` and `NAMES`, nothing else
//! decides a family.
//!
//! The source is the `Modalias` BlueZ reports from the device's Device ID record, for instance
//! `usb:v054Cp0CE6d0100` (a DualSense: vendor 0x054C = Sony, product 0x0CE6) or `bluetooth:v012D...`.
//! The vendor is the USB-IF id when the record says `usb:` and the Bluetooth SIG company id when it
//! says `bluetooth:`. A vendor that is in the table decides; a vendor that is not (a
//! generic pad) is "" whatever the pad calls itself, because a third-party pad named "Xbox
//! compatible" is not one. Only a pad that has no usable modalias is guessed from its name.
//! The family only picks a picture and a sentence; nothing is trusted because of it.

pub const PLAYSTATION: &str = "playstation";
pub const XBOX: &str = "xbox";
pub const NINTENDO: &str = "nintendo";
pub const EIGHTBITDO: &str = "8bitdo";

/// (modalias source, vendor id, family). Vendor ids as printed in the modalias.
const VENDORS: &[(&str, u16, &str)] = &[
    ("usb", 0x054C, PLAYSTATION),       // Sony Interactive Entertainment
    ("usb", 0x045E, XBOX),              // Microsoft
    ("usb", 0x057E, NINTENDO),          // Nintendo
    ("usb", 0x2DC8, EIGHTBITDO), // 8BitDo (D-input mode; X-input mode reports Microsoft's id)
    ("bluetooth", 0x012D, PLAYSTATION), // Sony Corp. (Bluetooth SIG company id)
    ("bluetooth", 0x0006, XBOX), // Microsoft (Bluetooth SIG company id)
    ("bluetooth", 0x0553, NINTENDO), // Nintendo (Bluetooth SIG company id)
];

/// (lower-case fragment of the device name, family), for a pad without a usable modalias. The
/// first match wins, so the generic fragment is last: Sony's pads call themselves "Wireless
/// Controller", which is also the end of "Xbox Wireless Controller".
const NAMES: &[(&str, &str)] = &[
    ("dualsense", PLAYSTATION),
    ("dualshock", PLAYSTATION),
    ("playstation", PLAYSTATION),
    ("xbox", XBOX),
    ("pro controller", NINTENDO),
    ("joy-con", NINTENDO),
    ("nintendo", NINTENDO),
    ("8bitdo", EIGHTBITDO),
    ("wireless controller", PLAYSTATION),
];

/// The (source, vendor id) of a modalias such as `usb:v054Cp0CE6d0100`, or `None`.
fn vendor_of(modalias: &str) -> Option<(&str, u16)> {
    let (source, rest) = modalias.trim().split_once(':')?;
    let hex = rest.strip_prefix('v')?.get(..4)?;
    let id = u16::from_str_radix(hex, 16).ok()?;
    Some((source, id))
}

/// The family of the pad with this `Modalias` and this display name; "" when unknown. Call it for
/// controllers only: a Sony headset has the same vendor.
pub fn family_of(modalias: &str, name: &str) -> &'static str {
    if let Some((source, id)) = vendor_of(modalias) {
        return VENDORS
            .iter()
            .find(|(s, v, _)| s.eq_ignore_ascii_case(source) && *v == id)
            .map_or("", |(_, _, family)| family);
    }
    let name = name.to_lowercase();
    NAMES
        .iter()
        .find(|(fragment, _)| name.contains(fragment))
        .map_or("", |(_, family)| family)
}

/// The family of a Bluetooth device: the modalias decides when it has a usable one; otherwise the
/// device's own `Name` as BlueZ has it (the model, which a rename does not change: a pad the user
/// called "Living room pad" is still a "DualSense Wireless Controller"), and only then the alias.
pub fn family_of_device(modalias: &str, device_name: &str, alias: &str) -> &'static str {
    if vendor_of(modalias).is_some() {
        return family_of(modalias, "");
    }
    match family_of("", device_name) {
        "" => family_of("", alias),
        family => family,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_renamed_pad_keeps_its_family_from_its_own_name() {
        // (modalias, BlueZ Name, Alias, family)
        let table = [
            (
                "",
                "DualSense Wireless Controller",
                "Living room pad",
                "playstation",
            ),
            ("", "Wireless Controller", "Kids", "playstation"),
            ("", "Xbox Wireless Controller", "Player 2", "xbox"),
            ("", "Pro Controller", "Zelda", "nintendo"),
            ("", "8BitDo Pro 2", "Retro", "8bitdo"),
            // The device told no name: the alias is all there is.
            ("", "", "DualSense Wireless Controller", "playstation"),
            // The device's name says nothing, the alias does (a user called it so).
            ("", "Gamepad", "Xbox pad", "xbox"),
            // The device's own name wins over an alias that claims another maker.
            ("", "DualSense Wireless Controller", "Xbox", "playstation"),
            ("", "Gamepad", "Pad", ""),
            // A usable modalias decides whatever the names say.
            (
                "usb:v045Ep0B13d0509",
                "DualSense Wireless Controller",
                "DualSense",
                "xbox",
            ),
            (
                "usb:v1234p0001d0100",
                "DualSense Wireless Controller",
                "DualSense",
                "",
            ),
        ];
        for (modalias, name, alias, want) in table {
            assert_eq!(
                family_of_device(modalias, name, alias),
                want,
                "{modalias:?} {name:?} {alias:?}"
            );
        }
    }

    #[test]
    fn sony_microsoft_and_nintendo_pads_by_their_usb_vendor() {
        assert_eq!(
            family_of("usb:v054Cp0CE6d0100", "Wireless Controller"),
            "playstation"
        ); // DualSense
        assert_eq!(
            family_of("usb:v054Cp09CCd0100", "Wireless Controller"),
            "playstation"
        ); // DualShock 4 v2
        assert_eq!(
            family_of("usb:v045Ep0B13d0509", "Xbox Wireless Controller"),
            "xbox"
        );
        assert_eq!(
            family_of("usb:v057Ep2009d0001", "Pro Controller"),
            "nintendo"
        );
        // Lower-case hex and a different case of the source are the same ids.
        assert_eq!(family_of("USB:v054cp0ce6d0100", ""), "playstation");
    }

    #[test]
    fn the_bluetooth_sig_company_ids_of_the_three_makers() {
        assert_eq!(family_of("bluetooth:v012Dp0000d0001", ""), "playstation");
        assert_eq!(family_of("bluetooth:v0006p0000d0001", ""), "xbox");
        assert_eq!(family_of("bluetooth:v0553p0000d0001", ""), "nintendo");
        // The same number means another maker under the other source: 0x0006 is not a USB id we know.
        assert_eq!(
            family_of("usb:v0006p0000d0001", "Xbox Wireless Controller"),
            ""
        );
    }

    #[test]
    fn an_8bitdo_pad_is_told_by_its_own_vendor_id_or_failing_that_its_name() {
        assert_eq!(
            family_of("usb:v2DC8p6001d0100", "8BitDo SN30 Pro"),
            "8bitdo"
        );
        assert_eq!(family_of("", "8BitDo Pro 2"), "8bitdo");
        // In X-input or Switch mode the pad reports Microsoft's or Nintendo's id and is
        // that family to the system (the audit, T-261, says what that means for the steps).
        assert_eq!(family_of("usb:v045Ep028Ed0114", "8BitDo Pro 2"), "xbox");
    }

    #[test]
    fn an_unknown_vendor_is_no_family_whatever_the_name_says() {
        assert_eq!(family_of("usb:v1234p6001d0100", "8BitDo SN30 Pro"), "");
        assert_eq!(family_of("usb:v1234p6001d0100", "Xbox compatible pad"), "");
        assert_eq!(family_of("usb:v0000p0000d0000", "DualSense"), "");
    }

    #[test]
    fn a_pad_without_a_usable_modalias_is_guessed_from_its_name() {
        assert_eq!(
            family_of("", "DualSense Wireless Controller"),
            "playstation"
        );
        assert_eq!(family_of("", "Wireless Controller"), "playstation");
        assert_eq!(family_of("", "DUALSHOCK 4"), "playstation");
        assert_eq!(family_of("", "Xbox Wireless Controller"), "xbox");
        assert_eq!(family_of("", "Pro Controller"), "nintendo");
        assert_eq!(family_of("", "Joy-Con (L)"), "nintendo");
        assert_eq!(family_of("", "Ruya Pad"), "");
        assert_eq!(family_of("", ""), "");
        // A modalias that is not a vendor id (garbled, too short) counts as none.
        assert_eq!(family_of("usb:", "Xbox Wireless Controller"), "xbox");
        assert_eq!(
            family_of("usb:vZZZZp0000", "Xbox Wireless Controller"),
            "xbox"
        );
        assert_eq!(family_of("v054C", "Ruya Pad"), "");
    }
}
