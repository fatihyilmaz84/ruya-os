//! Which controller model a pad is (RUY-491): the one table behind the `model` key of
//! `org.ruyaos.Devices1` (Bluetooth devices, gamepads, batteries) and `org.ruyaos.Input1` (device
//! records). A model is the file stem of a silhouette in `shell/art/pads/` (`dualsense`,
//! `wiiu_pro`, ...); the shell draws `pad_<model>` from its icon font.
//!
//! The ids are USB vendor:product from the public Linux driver tables (`hid-ids.h`, `xpad`,
//! `hid-nintendo`, `hid-wiimote`, `hid-steam`) and SDL, as listed in `shell/art/pads/README.md`;
//! none but the DualSense and the Wii U Pro was checked on hardware. A pad this table does not
//! know is "", and the shell falls back to the silhouette of the pad's family, then to the generic
//! gamepad glyph. Nothing is trusted because of the model: it only picks a picture.
//!
//! Resolution, the first rule that matches wins:
//! 1. **Names that beat ids** ([`Model::name_first`]): pads whose ids are shared or vary with the
//!    mode (the 8BitDo pads report Microsoft's id in X-input mode), the combined Joy-Cons and the
//!    arcade sticks.
//! 2. **Ids** (vendor, product). `057e:0330` is shared by the Wii U Pro (name ends "-UC") and the
//!    Wii Remote Plus ("-TR"): the name decides, and a name with neither is "".
//! 3. **Names** (a lower-case fragment of the device's own name), for a model's own maker's pads or
//!    when the vendor is not known ([`Model::maker`]).
//!
//! A vendor of 0 means the vendor is not known (a Bluetooth device whose Device ID record is not
//! a USB one): only the names are asked.

/// A model: its file stem, the ids that identify it and the name fragments that do.
pub struct Model {
    pub name: &'static str,
    /// The vendor that makes it, 0 for a model any maker's pad can be (the 8BitDo pads, a retro
    /// pad, an arcade stick, a generic gamepad). A name only counts when the pad's vendor is this
    /// one or not known: a third-party pad called "Xbox 360 pad" is not one.
    pub maker: u16,
    /// (USB vendor, USB product).
    pub ids: &'static [(u16, u16)],
    /// Lower-case fragments of the device's name. The first model whose fragment is in the name wins,
    /// so a more specific model is listed before the one whose fragment it contains.
    pub names: &'static [&'static str],
    /// The names are tried before the ids (see the module comment).
    pub name_first: bool,
}

const fn m(
    name: &'static str,
    maker: u16,
    ids: &'static [(u16, u16)],
    names: &'static [&'static str],
) -> Model {
    Model {
        name,
        maker,
        ids,
        names,
        name_first: false,
    }
}

const fn named(name: &'static str, names: &'static [&'static str]) -> Model {
    Model {
        name,
        maker: 0,
        ids: &[],
        names,
        name_first: true,
    }
}

const SONY: u16 = 0x054c;
const MICROSOFT: u16 = 0x045e;
const NINTENDO: u16 = 0x057e;
const VALVE: u16 = 0x28de;

/// Every model there is a silhouette for, one entry per file in `shell/art/pads/` (a test lists
/// the folder). `keyboard` and `wii_remote_nunchuk` have no rule: a keyboard is a kind, not a pad
/// (the shell keeps Material's glyph for it), and a Nunchuk is an extension `hid-wiimote` reports,
/// not an id.
pub const TABLE: &[Model] = &[
    named("8bitdo_pro2", &["8bitdo pro 2"]),
    named("8bitdo_sn30pro", &["sn30 pro"]),
    named("8bitdo_ultimate", &["8bitdo ultimate"]),
    // 0x200e is the charging grip, which presents the two Joy-Cons as one device.
    Model {
        name: "joycon_pair",
        maker: NINTENDO,
        ids: &[(NINTENDO, 0x200e)],
        names: &["combined joy-con"],
        name_first: true,
    },
    named("arcade_stick", &["fight stick", "arcade"]),
    m(
        "dualsense_edge",
        SONY,
        &[(SONY, 0x0df2)],
        &["dualsense edge"],
    ),
    m("dualsense", SONY, &[(SONY, 0x0ce6)], &["dualsense"]),
    m(
        "dualshock4",
        SONY,
        &[(SONY, 0x05c4), (SONY, 0x09cc), (SONY, 0x0ba0)],
        &["dualshock 4", "dualshock4"],
    ),
    m(
        "dualshock3",
        SONY,
        &[(SONY, 0x0268)],
        &["dualshock 3", "dualshock3", "playstation(r)3"],
    ),
    m(
        "xbox_series",
        MICROSOFT,
        &[(MICROSOFT, 0x0b12), (MICROSOFT, 0x0b13)],
        &["xbox series"],
    ),
    m(
        "xbox_elite",
        MICROSOFT,
        &[
            (MICROSOFT, 0x02e3),
            (MICROSOFT, 0x0b00),
            (MICROSOFT, 0x0b05),
            (MICROSOFT, 0x0b22),
        ],
        &["xbox elite", "elite series"],
    ),
    m(
        "xbox_one",
        MICROSOFT,
        &[
            (MICROSOFT, 0x02d1),
            (MICROSOFT, 0x02dd),
            (MICROSOFT, 0x02ea),
            (MICROSOFT, 0x02e0),
            (MICROSOFT, 0x02fd),
            (MICROSOFT, 0x0b20),
        ],
        &["xbox one"],
    ),
    m(
        "xbox_360",
        MICROSOFT,
        &[
            (MICROSOFT, 0x028e),
            (MICROSOFT, 0x0719),
            (MICROSOFT, 0x0291),
        ],
        &["xbox 360"],
    ),
    m(
        "xbox_adaptive",
        MICROSOFT,
        &[(MICROSOFT, 0x0b0a)],
        &["adaptive controller"],
    ),
    m(
        "switch_pro",
        NINTENDO,
        &[(NINTENDO, 0x2009)],
        &["pro controller"],
    ),
    m(
        "joycon_left",
        NINTENDO,
        &[(NINTENDO, 0x2006)],
        &["joy-con (l)", "joy-con l"],
    ),
    m(
        "joycon_right",
        NINTENDO,
        &[(NINTENDO, 0x2007)],
        &["joy-con (r)", "joy-con r"],
    ),
    m("wiiu_pro", NINTENDO, &[], &["rvl-cnt-01-uc"]),
    m(
        "wii_remote",
        NINTENDO,
        &[(NINTENDO, 0x0306)],
        &["rvl-cnt-01"],
    ),
    m("wii_remote_nunchuk", NINTENDO, &[], &[]),
    m("gamecube", NINTENDO, &[(NINTENDO, 0x0337)], &["gamecube"]),
    m("n64", NINTENDO, &[(NINTENDO, 0x2019)], &["nintendo 64"]),
    m("retro_pad", 0, &[(NINTENDO, 0x2017)], &["sn30", "snes"]),
    m(
        "steam_controller",
        VALVE,
        &[(VALVE, 0x1102), (VALVE, 0x1142), (VALVE, 0x1106)],
        &["steam controller"],
    ),
    m("steam_deck", VALVE, &[(VALVE, 0x1205)], &["steam deck"]),
    m("stadia", 0x18d1, &[(0x18d1, 0x9400)], &["stadia"]),
    m("generic_pad", 0, &[], &["gamepad"]),
    m("keyboard", 0, &[], &[]),
];

/// The names of every model, in table order.
pub fn models() -> impl Iterator<Item = &'static str> {
    TABLE.iter().map(|model| model.name)
}

fn by_name(lower: &str, first: bool, vendor: u16) -> Option<&'static str> {
    TABLE
        .iter()
        .filter(|model| model.name_first == first)
        .filter(|model| model.maker == 0 || vendor == 0 || vendor == model.maker)
        .find(|model| model.names.iter().any(|fragment| lower.contains(fragment)))
        .map(|model| model.name)
}

/// The model of the pad with these USB ids and this name, or "" when this table does not know
/// it. `vendor` 0 says the ids are not known: only the name is asked.
pub fn model_of(vendor: u16, product: u16, name: &str) -> &'static str {
    let lower = name.to_lowercase();
    if let Some(model) = by_name(&lower, true, vendor) {
        return model;
    }
    if vendor == NINTENDO && product == 0x0330 {
        // The Wii U Pro and the Wii Remote Plus share this id; only the name tells them apart.
        return if lower.contains("-uc") {
            "wiiu_pro"
        } else if lower.contains("-tr") {
            "wii_remote"
        } else {
            ""
        };
    }
    if vendor != 0 {
        if let Some(model) = TABLE
            .iter()
            .find(|model| model.ids.contains(&(vendor, product)))
        {
            return model.name;
        }
    }
    by_name(&lower, false, vendor).unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn the_readmes_ids_name_their_models() {
        // (vendor, product, name, model): the inventory of shell/art/pads/README.md.
        let table = [
            (0x054c, 0x0ce6, "Wireless Controller", "dualsense"),
            (0x054c, 0x0ce6, "DualSense Wireless Controller", "dualsense"),
            (0x054c, 0x0df2, "DualSense Edge", "dualsense_edge"),
            (0x054c, 0x05c4, "Wireless Controller", "dualshock4"),
            (0x054c, 0x09cc, "Wireless Controller", "dualshock4"),
            (0x054c, 0x0ba0, "Wireless Controller", "dualshock4"),
            (0x054c, 0x0268, "PLAYSTATION(R)3 Controller", "dualshock3"),
            (0x045e, 0x0b12, "Xbox Wireless Controller", "xbox_series"),
            (0x045e, 0x0b13, "Xbox Wireless Controller", "xbox_series"),
            (0x045e, 0x02d1, "Microsoft X-Box One pad", "xbox_one"),
            (0x045e, 0x0b20, "Xbox Wireless Controller", "xbox_one"),
            (0x045e, 0x02e3, "Xbox One Elite", "xbox_elite"),
            (0x045e, 0x0b00, "Xbox Elite Series 2", "xbox_elite"),
            (0x045e, 0x0b22, "Xbox Wireless Controller", "xbox_elite"),
            (0x045e, 0x028e, "Microsoft X-Box 360 pad", "xbox_360"),
            (0x045e, 0x0719, "Xbox 360 Controller", "xbox_360"),
            (0x045e, 0x0b0a, "Xbox Adaptive Controller", "xbox_adaptive"),
            (0x057e, 0x2009, "Pro Controller", "switch_pro"),
            (0x057e, 0x2006, "Joy-Con (L)", "joycon_left"),
            (0x057e, 0x2007, "Joy-Con (R)", "joycon_right"),
            (0x057e, 0x200e, "Joy-Con Charging Grip", "joycon_pair"),
            (0x057e, 0x0330, "Nintendo RVL-CNT-01-UC", "wiiu_pro"),
            (0x057e, 0x0330, "Nintendo RVL-CNT-01-TR", "wii_remote"),
            (0x057e, 0x0306, "Nintendo RVL-CNT-01", "wii_remote"),
            (0x057e, 0x0337, "Nintendo GameCube Controller", "gamecube"),
            (0x057e, 0x2019, "Nintendo Switch Online N64", "n64"),
            (0x057e, 0x2017, "SNES Controller", "retro_pad"),
            (0x28de, 0x1102, "Steam Controller", "steam_controller"),
            (0x28de, 0x1142, "Steam Controller", "steam_controller"),
            (0x28de, 0x1106, "Steam Controller", "steam_controller"),
            (0x28de, 0x1205, "Steam Deck Controller", "steam_deck"),
            (0x18d1, 0x9400, "Stadia Controller", "stadia"),
        ];
        for (vendor, product, name, model) in table {
            assert_eq!(
                model_of(vendor, product, name),
                model,
                "{vendor:04x}:{product:04x} {name:?}"
            );
        }
    }

    #[test]
    fn a_name_beats_an_id_that_a_mode_shares() {
        // An 8BitDo pad in X-input mode reports Microsoft's Xbox 360 id.
        assert_eq!(model_of(0x045e, 0x028e, "8BitDo Pro 2"), "8bitdo_pro2");
        assert_eq!(
            model_of(0x045e, 0x028e, "8BitDo SN30 Pro"),
            "8bitdo_sn30pro"
        );
        assert_eq!(
            model_of(0x2dc8, 0x3106, "8BitDo Ultimate"),
            "8bitdo_ultimate"
        );
        assert_eq!(model_of(0x2dc8, 0x3106, "8BitDo Pro 2"), "8bitdo_pro2");
        assert_eq!(model_of(0x2dc8, 0x3106, "Controller"), "");
        assert_eq!(model_of(0x045e, 0x028e, "Xbox 360 pad"), "xbox_360");
        assert_eq!(model_of(0x057e, 0x2008, "Combined Joy-Cons"), "joycon_pair");
        assert_eq!(
            model_of(0x0079, 0x0006, "Arcade Fight Stick"),
            "arcade_stick"
        );
        assert_eq!(model_of(0x0079, 0x0006, "SN30 Retro"), "retro_pad");
    }

    #[test]
    fn the_wii_u_pro_and_the_wii_remote_plus_share_an_id_and_the_name_decides() {
        assert_eq!(
            model_of(0x057e, 0x0330, "Nintendo RVL-CNT-01-UC"),
            "wiiu_pro"
        );
        assert_eq!(
            model_of(0x057e, 0x0330, "nintendo rvl-cnt-01-uc"),
            "wiiu_pro"
        );
        assert_eq!(
            model_of(0x057e, 0x0330, "Nintendo RVL-CNT-01-TR"),
            "wii_remote"
        );
        assert_eq!(model_of(0x057e, 0x0330, ""), "");
        assert_eq!(model_of(0x057e, 0x0330, "Controller"), "");
    }

    #[test]
    fn a_pad_without_ids_is_told_by_its_name_alone() {
        assert_eq!(model_of(0, 0, "DualSense Wireless Controller"), "dualsense");
        assert_eq!(
            model_of(0, 0, "DualSense Edge Wireless Controller"),
            "dualsense_edge"
        );
        assert_eq!(model_of(0, 0, "DUALSHOCK 4"), "dualshock4");
        assert_eq!(model_of(0, 0, "Pro Controller"), "switch_pro");
        assert_eq!(model_of(0, 0, "Joy-Con (L)"), "joycon_left");
        assert_eq!(model_of(0, 0, "Xbox Wireless Controller"), "");
        assert_eq!(model_of(0, 0, "USB Gamepad"), "generic_pad");
        // The id is not asked when it is not known: 054c:0ce6 in the table does not apply to vendor 0.
        assert_eq!(model_of(0, 0x0ce6, "Wireless Controller"), "");
    }

    #[test]
    fn an_unknown_pad_is_no_model() {
        assert_eq!(model_of(0x054c, 0x7777, "Wireless Controller"), "");
        assert_eq!(model_of(0x1234, 0x0001, "Ruya Pad"), "");
        assert_eq!(model_of(0, 0, ""), "");
        // A third-party pad that calls itself after another maker's is not that pad.
        assert_eq!(model_of(0x1234, 0x0001, "Xbox 360 pad"), "");
        assert_eq!(model_of(0x1234, 0x0001, "DualSense clone"), "");
        assert_eq!(model_of(0x1234, 0x0001, "Pro Controller"), "");
        // A pad of a known maker with an unknown product is its family's business, not this table's.
        assert_eq!(model_of(0x045e, 0x7777, "Xbox Wireless Controller"), "");
    }

    #[test]
    fn every_silhouette_has_an_entry_and_every_entry_a_silhouette() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../shell/art/pads");
        let files: BTreeSet<String> = fs::read_dir(&dir)
            .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
            .filter_map(Result::ok)
            .filter_map(|entry| {
                let name = entry.file_name().to_string_lossy().into_owned();
                name.strip_suffix(".svg").map(str::to_owned)
            })
            .collect();
        let table: BTreeSet<String> = models().map(str::to_owned).collect();
        assert_eq!(
            files, table,
            "shell/art/pads/*.svg and ruya-pads TABLE differ"
        );
        assert_eq!(table.len(), TABLE.len(), "a model is listed twice");
    }

    #[test]
    fn every_entry_but_the_two_reserved_ones_has_a_rule_that_finds_it() {
        for model in TABLE {
            if matches!(model.name, "keyboard" | "wii_remote_nunchuk") {
                assert!(
                    model.ids.is_empty() && model.names.is_empty(),
                    "{}",
                    model.name
                );
                continue;
            }
            let found = model
                .ids
                .iter()
                .map(|&(vendor, product)| model_of(vendor, product, ""))
                .chain(model.names.iter().map(|name| model_of(0, 0, name)))
                .collect::<Vec<_>>();
            assert!(!found.is_empty(), "{} has no rule", model.name);
            assert!(
                found.iter().all(|got| *got == model.name),
                "{}: its rules find {found:?}",
                model.name
            );
        }
    }

    #[test]
    fn the_ids_of_the_table_are_unique() {
        let mut seen = BTreeSet::new();
        for model in TABLE {
            for id in model.ids {
                assert!(seen.insert(*id), "{id:04x?} is in two models");
            }
        }
    }
}
