//! Which family a game controller belongs to (T-199, `org.ruyaos.Devices1.Bluetooth.ListDevices`
//! key `family`): "playstation", "xbox", "nintendo" or "generic" for a controller. The table is
//! `ruya_pads::family_of`, the same one `ruya-inputd` uses (RUY-692); this file only reads the ids
//! out of what BlueZ reports and calls it. 8BitDo is a model (`ruya_pads::model_of`), not a family.
//!
//! The source is the `Modalias` BlueZ reports from the device's Device ID record, for instance
//! `usb:v054Cp0CE6d0100` (a DualSense: vendor 0x054C = Sony, product 0x0CE6) or `bluetooth:v012D...`.
//! The vendor is the USB-IF id when the record says `usb:`; a `bluetooth:` record carries the
//! Bluetooth SIG company id, translated here to the USB id of the same maker. A modalias with an id
//! decides, whatever the pad calls itself; only a pad with no usable modalias is guessed from its
//! name. The family only picks a picture and a sentence; nothing is trusted because of it.

/// (Bluetooth SIG company id, USB vendor id of the same maker).
const BLUETOOTH_COMPANIES: &[(u16, u16)] = &[
    (0x012D, 0x054C), // Sony Corp.
    (0x0006, 0x045E), // Microsoft
    (0x0553, 0x057E), // Nintendo
];

/// A vendor id no table knows: a Bluetooth company id that is none of the three makers.
const OTHER_MAKER: u16 = 0xFFFF;

/// The (source, vendor id) of a modalias such as `usb:v054Cp0CE6d0100`, or `None`.
fn vendor_of(modalias: &str) -> Option<(&str, u16)> {
    let (source, rest) = modalias.trim().split_once(':')?;
    let hex = rest.strip_prefix('v')?.get(..4)?;
    let id = u16::from_str_radix(hex, 16).ok()?;
    Some((source, id))
}

/// The (source, vendor id, product id) of a modalias such as `usb:v054Cp0CE6d0100`, or `None`.
fn ids_of(modalias: &str) -> Option<(&str, u16, u16)> {
    let (source, vendor) = vendor_of(modalias)?;
    let rest = modalias.trim().split_once(':')?.1;
    let product = rest
        .get(5..)
        .and_then(|r| r.strip_prefix('p'))
        .and_then(|r| r.get(..4))
        .and_then(|hex| u16::from_str_radix(hex, 16).ok())
        .unwrap_or(0);
    Some((source, vendor, product))
}

/// The model of a controller (`ruya_pads::model_of`, the table of silhouettes): by the USB ids of
/// the Modalias when it is a `usb:` one, and by the device's own name (else the alias, as for the
/// family) in any case; "" when the table does not know the pad. A vendor id of the Bluetooth SIG
/// is not a USB one: such a modalias leaves only the name. Call it for controllers only.
pub fn model_of_device(modalias: &str, device_name: &str, alias: &str) -> &'static str {
    let name = if device_name.is_empty() {
        alias
    } else {
        device_name
    };
    match ids_of(modalias) {
        Some((source, vendor, product)) if source.eq_ignore_ascii_case("usb") => {
            ruya_pads::model_of(vendor, product, name)
        }
        _ => ruya_pads::model_of(0, 0, name),
    }
}

/// The family of the pad with this `Modalias` and this display name (`ruya_pads::family_of`);
/// a modalias with an id decides, else the name does. Call it for controllers only: a Sony
/// headset has the same vendor.
pub fn family_of(modalias: &str, name: &str) -> &'static str {
    match ids_of(modalias) {
        Some((source, vendor, product)) => {
            let vendor = if source.eq_ignore_ascii_case("bluetooth") {
                BLUETOOTH_COMPANIES
                    .iter()
                    .find(|(company, _)| *company == vendor)
                    .map_or(OTHER_MAKER, |(_, usb)| *usb)
            } else {
                vendor
            };
            ruya_pads::family_of(vendor, product, "", name)
        }
        None => ruya_pads::family_of(0, 0, "", name),
    }
}

/// The family of a Bluetooth device: the modalias decides when it has a usable one; otherwise the
/// device's own `Name` as BlueZ has it (the model, which a rename does not change: a pad the user
/// called "Living room pad" is still a "DualSense Wireless Controller"), and only then the alias.
pub fn family_of_device(modalias: &str, device_name: &str, alias: &str) -> &'static str {
    if vendor_of(modalias).is_some() {
        return family_of(modalias, "");
    }
    match family_of("", device_name) {
        ruya_pads::GENERIC => family_of("", alias),
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
            ("", "8BitDo Pro 2", "Retro", "generic"),
            // The device told no name: the alias is all there is.
            ("", "", "DualSense Wireless Controller", "playstation"),
            // The device's name says nothing, the alias does (a user called it so).
            ("", "Gamepad", "Xbox pad", "xbox"),
            // The device's own name wins over an alias that claims another maker.
            ("", "DualSense Wireless Controller", "Xbox", "playstation"),
            ("", "Gamepad", "Pad", "generic"),
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
                "generic",
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
    fn the_model_of_a_device_is_told_by_its_usb_ids_and_its_name() {
        // (modalias, BlueZ Name, Alias, model)
        let table = [
            // The Dell's pads (RUY-491): a DualSense over Bluetooth, a Wii U Pro.
            (
                "usb:v054Cp0CE6d0100",
                "Wireless Controller",
                "Wireless Controller",
                "dualsense",
            ),
            (
                "usb:v057Ep0330d0600",
                "Nintendo RVL-CNT-01-UC",
                "Nintendo RVL-CNT-01-UC",
                "wiiu_pro",
            ),
            (
                "usb:v045Ep0B13d0509",
                "Xbox Wireless Controller",
                "Player 2",
                "xbox_series",
            ),
            // A rename does not change the model; no Name falls back to the alias.
            (
                "",
                "DualSense Wireless Controller",
                "Living room pad",
                "dualsense",
            ),
            ("", "", "Pro Controller", "switch_pro"),
            // The Bluetooth SIG company id is no USB id: only the name is asked.
            (
                "bluetooth:v012Dp0CE6d0100",
                "Wireless Controller",
                "Pad",
                "",
            ),
            (
                "bluetooth:v012Dp0CE6d0100",
                "DualSense Wireless Controller",
                "Pad",
                "dualsense",
            ),
            // Another maker's id with a name that claims a model: no model.
            (
                "usb:v1234p0001d0100",
                "DualSense Wireless Controller",
                "DualSense",
                "",
            ),
            (
                "usb:v054Cp7777d0100",
                "Wireless Controller",
                "Wireless Controller",
                "",
            ),
            ("", "", "", ""),
        ];
        for (modalias, name, alias, want) in table {
            assert_eq!(
                model_of_device(modalias, name, alias),
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
            "generic"
        );
        // A company id of no maker we know is generic, whatever the name says.
        assert_eq!(
            family_of("bluetooth:v004Cp0000d0001", "DualSense"),
            "generic"
        );
        // A DualSense over Bluetooth, as the Dell reports it.
        assert_eq!(
            family_of("bluetooth:v012Dp0CE6d0100", "Wireless Controller"),
            "playstation"
        );
    }

    #[test]
    fn an_8bitdo_pad_is_generic_in_d_input_and_follows_its_mode_otherwise() {
        // D-input: 8BitDo's own id is no family. The model says it is an 8BitDo.
        assert_eq!(
            family_of("usb:v2DC8p6001d0100", "8BitDo SN30 Pro"),
            "generic"
        );
        assert_eq!(family_of("", "8BitDo Pro 2"), "generic");
        assert_eq!(model_of_device("", "8BitDo Pro 2", "Retro"), "8bitdo_pro2");
        // In X-input or Switch mode the pad reports Microsoft's or Nintendo's id.
        assert_eq!(family_of("usb:v045Ep028Ed0114", "8BitDo Pro 2"), "xbox");
        assert_eq!(family_of("usb:v057Ep2009d0001", "8BitDo Pro 2"), "nintendo");
    }

    #[test]
    fn an_unknown_vendor_is_generic_whatever_the_name_says() {
        assert_eq!(
            family_of("usb:v1234p6001d0100", "8BitDo SN30 Pro"),
            "generic"
        );
        assert_eq!(
            family_of("usb:v1234p6001d0100", "Xbox compatible pad"),
            "generic"
        );
        assert_eq!(family_of("usb:v0000p0000d0000", "DualSense"), "playstation");
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
        assert_eq!(family_of("", "Ruya Pad"), "generic");
        assert_eq!(family_of("", ""), "generic");
        // A modalias that is not a vendor id (garbled, too short) counts as none.
        assert_eq!(family_of("usb:", "Xbox Wireless Controller"), "xbox");
        assert_eq!(
            family_of("usb:vZZZZp0000", "Xbox Wireless Controller"),
            "xbox"
        );
        assert_eq!(family_of("v054C", "Ruya Pad"), "generic");
    }
}
