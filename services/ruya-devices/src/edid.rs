//! EDID (the TV's or monitor's identity card, `/sys/class/drm/<connector>/edid`): its name, its
//! physical size and the timings it announces. The kernel's `modes` file lists only `WxH`, so the
//! refresh rates come from here. Pure; the layout is VESA E-EDID 1.4 (base block) and CTA-861
//! (the extension block with the video data block and more detailed timings).

/// One timing the display announces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timing {
    pub width: u32,
    pub height: u32,
    /// Frames per second times 1000 (60000 = 60 Hz).
    pub refresh_mhz: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Edid {
    /// The monitor name descriptor ("DELL U2720Q"), when there is one.
    pub name: Option<String>,
    /// Physical size of the picture in millimetres; 0 when the display does not say (or says the
    /// placeholder a projector gives).
    pub width_mm: u32,
    pub height_mm: u32,
    /// Progressive timings, in the order they were found (detailed timings first).
    pub timings: Vec<Timing>,
}

const HEADER: [u8; 8] = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00];
const BLOCK: usize = 128;

fn u16le(b: &[u8]) -> u32 {
    u32::from(b[0]) | (u32::from(b[1]) << 8)
}

/// A detailed timing descriptor (18 bytes). `None` for a padding or text descriptor, an
/// interlaced timing, or numbers that are nonsense.
fn detailed(d: &[u8]) -> Option<(Timing, u32, u32)> {
    if d.len() < 18 {
        return None;
    }
    let clock_khz = u16le(d) * 10;
    if clock_khz == 0 {
        return None;
    }
    let h_active = u32::from(d[2]) | (u32::from(d[4] >> 4) << 8);
    let h_blank = u32::from(d[3]) | (u32::from(d[4] & 0x0f) << 8);
    let v_active = u32::from(d[5]) | (u32::from(d[7] >> 4) << 8);
    let v_blank = u32::from(d[6]) | (u32::from(d[7] & 0x0f) << 8);
    let w_mm = u32::from(d[12]) | (u32::from(d[14] >> 4) << 8);
    let h_mm = u32::from(d[13]) | (u32::from(d[14] & 0x0f) << 8);
    let interlaced = d[17] & 0x80 != 0;
    let total = u64::from(h_active + h_blank) * u64::from(v_active + v_blank);
    if interlaced || h_active == 0 || v_active == 0 || total == 0 {
        return None;
    }
    let refresh = (u64::from(clock_khz) * 1_000_000 / total) as u32;
    Some((
        Timing {
            width: h_active,
            height: v_active,
            refresh_mhz: refresh,
        },
        w_mm,
        h_mm,
    ))
}

/// The progressive CTA-861 video identification codes a TV announces in its video data block:
/// (width, height, refresh in mHz). Interlaced and unusual codes are left out.
fn vic(code: u8) -> Option<Timing> {
    let (width, height, refresh_mhz) = match code {
        1 => (640, 480, 59_940),
        2 | 3 => (720, 480, 59_940),
        4 => (1280, 720, 60_000),
        16 => (1920, 1080, 60_000),
        17 | 18 => (720, 576, 50_000),
        19 => (1280, 720, 50_000),
        31 => (1920, 1080, 50_000),
        32 => (1920, 1080, 24_000),
        33 => (1920, 1080, 25_000),
        34 => (1920, 1080, 30_000),
        41 => (1280, 720, 100_000),
        47 => (1280, 720, 120_000),
        60 => (1280, 720, 24_000),
        61 => (1280, 720, 25_000),
        62 => (1280, 720, 30_000),
        63 => (1920, 1080, 120_000),
        64 => (1920, 1080, 100_000),
        93 => (3840, 2160, 24_000),
        94 => (3840, 2160, 25_000),
        95 => (3840, 2160, 30_000),
        96 => (3840, 2160, 50_000),
        97 => (3840, 2160, 60_000),
        98 => (4096, 2160, 24_000),
        99 => (4096, 2160, 25_000),
        100 => (4096, 2160, 30_000),
        101 => (4096, 2160, 50_000),
        102 => (4096, 2160, 60_000),
        117 => (3840, 2160, 100_000),
        118 => (3840, 2160, 120_000),
        _ => return None,
    };
    Some(Timing {
        width,
        height,
        refresh_mhz,
    })
}

/// The "established timings" bitmap (bytes 35 to 37 of the base block).
fn established(bytes: [u8; 3]) -> Vec<Timing> {
    const TABLE: [[(u32, u32, u32); 8]; 3] = [
        [
            (720, 400, 70),
            (720, 400, 88),
            (640, 480, 60),
            (640, 480, 67),
            (640, 480, 72),
            (640, 480, 75),
            (800, 600, 56),
            (800, 600, 60),
        ],
        [
            (800, 600, 72),
            (800, 600, 75),
            (832, 624, 75),
            (0, 0, 0), // 1024x768 87 Hz interlaced
            (1024, 768, 60),
            (1024, 768, 70),
            (1024, 768, 75),
            (1280, 1024, 75),
        ],
        [
            (1152, 870, 75),
            (0, 0, 0),
            (0, 0, 0),
            (0, 0, 0),
            (0, 0, 0),
            (0, 0, 0),
            (0, 0, 0),
            (0, 0, 0),
        ],
    ];
    let mut out = Vec::new();
    for (row, byte) in TABLE.iter().zip(bytes) {
        for (bit, &(width, height, hz)) in row.iter().enumerate() {
            if width != 0 && byte & (0x80 >> bit) != 0 {
                out.push(Timing {
                    width,
                    height,
                    refresh_mhz: hz * 1000,
                });
            }
        }
    }
    out
}

/// A standard timing (two bytes): the size from the aspect ratio, the rate as 60 + the low bits.
fn standard(pair: &[u8]) -> Option<Timing> {
    if (pair[0] == 0x01 && pair[1] == 0x01) || pair[0] == 0 {
        return None;
    }
    let width = (u32::from(pair[0]) + 31) * 8;
    let height = match pair[1] >> 6 {
        0 => width * 10 / 16,
        1 => width * 3 / 4,
        2 => width * 4 / 5,
        _ => width * 9 / 16,
    };
    let hz = u32::from(pair[1] & 0x3f) + 60;
    Some(Timing {
        width,
        height,
        refresh_mhz: hz * 1000,
    })
}

fn push(list: &mut Vec<Timing>, t: Timing) {
    if !list.contains(&t) {
        list.push(t);
    }
}

/// Parses an EDID. `None` when it is too short or not an EDID at all. A wrong checksum is
/// tolerated (cheap displays have them); the numbers are bounded instead.
pub fn parse(bytes: &[u8]) -> Option<Edid> {
    if bytes.len() < BLOCK || bytes[..8] != HEADER {
        return None;
    }
    let base = &bytes[..BLOCK];
    let mut edid = Edid::default();

    // Size in centimetres; 16x9 and 4x3 are the projector's "only the shape is known".
    let (w_cm, h_cm) = (u32::from(base[21]), u32::from(base[22]));
    if w_cm > 0 && h_cm > 0 && !matches!((w_cm, h_cm), (16, 9) | (4, 3)) {
        edid.width_mm = w_cm * 10;
        edid.height_mm = h_cm * 10;
    }

    let mut first_detailed = true;
    for at in [54, 72, 90, 108] {
        let d = &base[at..at + 18];
        if d[0] != 0 || d[1] != 0 {
            if let Some((timing, w_mm, h_mm)) = detailed(d) {
                push(&mut edid.timings, timing);
                // The first detailed timing is the preferred one; its size is in millimetres.
                if first_detailed && w_mm > 0 && h_mm > 0 {
                    edid.width_mm = w_mm;
                    edid.height_mm = h_mm;
                }
            }
            first_detailed = false;
        } else if d[3] == 0xfc {
            let text: String = d[5..18]
                .iter()
                .take_while(|&&b| b != 0x0a && b != 0)
                .map(|&b| {
                    if (0x20..0x7f).contains(&b) {
                        b as char
                    } else {
                        '?'
                    }
                })
                .collect();
            let text = text.trim();
            if !text.is_empty() {
                edid.name = Some(text.to_owned());
            }
        }
    }
    for t in established([base[35], base[36], base[37]]) {
        push(&mut edid.timings, t);
    }
    for pair in base[38..54].chunks(2) {
        if let Some(t) = standard(pair) {
            push(&mut edid.timings, t);
        }
    }

    // Extension blocks: CTA-861 (tag 0x02).
    let extensions = usize::from(base[126]);
    for n in 1..=extensions {
        let Some(block) = bytes.get(n * BLOCK..(n + 1) * BLOCK) else {
            break;
        };
        if block[0] != 0x02 {
            continue;
        }
        let dtd_at = usize::from(block[2]);
        if !(4..BLOCK).contains(&dtd_at) {
            continue;
        }
        let mut i = 4;
        while i < dtd_at {
            let tag = block[i] >> 5;
            let len = usize::from(block[i] & 0x1f);
            let Some(data) = block.get(i + 1..i + 1 + len) else {
                break;
            };
            if tag == 2 {
                for &svd in data {
                    // Bit 7 marks a native mode for codes 1 to 64; above that it is part of the code.
                    let code = if svd & 0x7f <= 64 { svd & 0x7f } else { svd };
                    if let Some(t) = vic(code) {
                        push(&mut edid.timings, t);
                    }
                }
            }
            i += 1 + len;
        }
        let mut at = dtd_at;
        while at + 18 <= BLOCK - 1 {
            if let Some((timing, _, _)) = detailed(&block[at..at + 18]) {
                push(&mut edid.timings, timing);
            }
            at += 18;
        }
    }
    Some(edid)
}

/// Builds EDIDs for tests (also used by the display tests): an unsigned-minimum base block with
/// the fields the parser reads, a correct checksum, and an optional CTA-861 extension.
#[cfg(test)]
pub(crate) mod testing {
    /// A detailed timing descriptor for `w`x`h` at the given totals and clock, picture size in mm.
    pub fn dtd(
        clock_khz: u32,
        h: (u32, u32),
        v: (u32, u32),
        mm: (u32, u32),
        interlaced: bool,
    ) -> [u8; 18] {
        let (ha, hb) = h;
        let (va, vb) = v;
        let c = clock_khz / 10;
        let mut d = [0u8; 18];
        d[0] = (c & 0xff) as u8;
        d[1] = (c >> 8) as u8;
        d[2] = (ha & 0xff) as u8;
        d[3] = (hb & 0xff) as u8;
        d[4] = (((ha >> 8) << 4) | (hb >> 8)) as u8;
        d[5] = (va & 0xff) as u8;
        d[6] = (vb & 0xff) as u8;
        d[7] = (((va >> 8) << 4) | (vb >> 8)) as u8;
        d[12] = (mm.0 & 0xff) as u8;
        d[13] = (mm.1 & 0xff) as u8;
        d[14] = (((mm.0 >> 8) << 4) | (mm.1 >> 8)) as u8;
        d[17] = if interlaced { 0x80 } else { 0 };
        d
    }

    /// 1920x1080 at 60 Hz (148.5 MHz, 2200x1125 total).
    pub fn dtd_1080p60(mm: (u32, u32)) -> [u8; 18] {
        dtd(148_500, (1920, 280), (1080, 45), mm, false)
    }

    /// 3840x2160 at 60 Hz (594 MHz, 4400x2250 total).
    pub fn dtd_2160p60(mm: (u32, u32)) -> [u8; 18] {
        dtd(594_000, (3840, 560), (2160, 90), mm, false)
    }

    pub fn name_descriptor(name: &str) -> [u8; 18] {
        let mut d = [0u8; 18];
        d[3] = 0xfc;
        let mut text = name.as_bytes().to_vec();
        text.push(0x0a);
        text.resize(13, 0x20);
        d[5..18].copy_from_slice(&text);
        d
    }

    fn seal(block: &mut [u8]) {
        let sum: u32 = block[..127].iter().map(|&b| u32::from(b)).sum();
        block[127] = ((256 - sum % 256) % 256) as u8;
    }

    /// A base block. `descriptors` fill the four descriptor slots in order; `size_cm` is bytes
    /// 21 and 22; `standard` are standard-timing pairs; `extensions` is how many blocks follow.
    pub fn base(
        size_cm: (u8, u8),
        descriptors: &[[u8; 18]],
        standard: &[[u8; 2]],
        extensions: u8,
    ) -> Vec<u8> {
        let mut b = vec![0u8; 128];
        b[..8].copy_from_slice(&[0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]);
        b[18] = 1;
        b[19] = 4;
        b[21] = size_cm.0;
        b[22] = size_cm.1;
        for i in 0..8 {
            b[38 + 2 * i] = 0x01;
            b[39 + 2 * i] = 0x01;
        }
        for (i, pair) in standard.iter().enumerate().take(8) {
            b[38 + 2 * i] = pair[0];
            b[39 + 2 * i] = pair[1];
        }
        for (i, d) in descriptors.iter().enumerate().take(4) {
            b[54 + 18 * i..72 + 18 * i].copy_from_slice(d);
        }
        b[126] = extensions;
        seal(&mut b);
        b
    }

    /// A CTA-861 block with a video data block of `vics` and extra detailed timings.
    pub fn cta(vics: &[u8], dtds: &[[u8; 18]]) -> Vec<u8> {
        let mut b = vec![0u8; 128];
        b[0] = 0x02;
        b[1] = 3;
        let mut at = 4;
        b[at] = (2 << 5) | vics.len() as u8;
        b[at + 1..at + 1 + vics.len()].copy_from_slice(vics);
        at += 1 + vics.len();
        b[2] = at as u8;
        for d in dtds {
            b[at..at + 18].copy_from_slice(d);
            at += 18;
        }
        seal(&mut b);
        b
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;

    fn t(width: u32, height: u32, refresh_mhz: u32) -> Timing {
        Timing {
            width,
            height,
            refresh_mhz,
        }
    }

    #[test]
    fn name_size_and_preferred_timing_come_from_the_detailed_descriptors() {
        let bytes = base(
            (60, 34),
            &[dtd_2160p60((597, 336)), name_descriptor("DELL U2720Q")],
            &[],
            0,
        );
        let edid = parse(&bytes).unwrap();
        assert_eq!(edid.name.as_deref(), Some("DELL U2720Q"));
        // The detailed timing's millimetres win over the centimetres of byte 21/22.
        assert_eq!((edid.width_mm, edid.height_mm), (597, 336));
        assert_eq!(edid.timings[0], t(3840, 2160, 60_000));
    }

    #[test]
    fn the_size_falls_back_to_centimetres_and_a_projector_placeholder_is_unknown() {
        let no_mm = dtd_1080p60((0, 0));
        let edid = parse(&base((122, 68), &[no_mm], &[], 0)).unwrap();
        assert_eq!((edid.width_mm, edid.height_mm), (1220, 680));
        let projector = parse(&base((16, 9), &[no_mm], &[], 0)).unwrap();
        assert_eq!((projector.width_mm, projector.height_mm), (0, 0));
        let unknown = parse(&base((0, 0), &[no_mm], &[], 0)).unwrap();
        assert_eq!((unknown.width_mm, unknown.height_mm), (0, 0));
    }

    #[test]
    fn standard_and_established_timings_are_read() {
        let mut bytes = base(
            (52, 29),
            &[],
            &[[0xd1, 0xc0], [0x81, 0x80], [0x61, 0x40], [0x95, 0x00]],
            0,
        );
        // 1280x1024 75 Hz and 640x480 60 Hz from the established bitmap.
        bytes[35] = 0x20;
        bytes[36] = 0x01;
        let edid = parse(&bytes).unwrap();
        // 0xd1 -> (209 + 31) * 8 = 1920, aspect 16:9 -> 1080, rate 60 + 0 = 60.
        assert!(edid.timings.contains(&t(1920, 1080, 60_000)));
        // 0x81 -> 1280, aspect 5:4 -> 1024, rate 60.
        assert!(edid.timings.contains(&t(1280, 1024, 60_000)));
        // 0x61 -> 1024, 4:3 -> 768; 0x95 -> 1440, 16:10 -> 900.
        assert!(edid.timings.contains(&t(1024, 768, 60_000)));
        assert!(edid.timings.contains(&t(1440, 900, 60_000)));
        assert!(edid.timings.contains(&t(640, 480, 60_000)));
        assert!(edid.timings.contains(&t(1280, 1024, 75_000)));
    }

    #[test]
    fn the_cta_extension_gives_the_tv_modes_and_extra_detailed_timings() {
        // VIC 16 (native, bit 7), 4, 97 (4K60), 32 (24p), 200 (not in the table), and a
        // 3840x2160 30 Hz detailed timing after the data block.
        let extra = dtd(297_000, (3840, 560), (2160, 90), (0, 0), false);
        let mut bytes = base((0, 0), &[dtd_1080p60((1220, 690))], &[], 1);
        bytes.extend(cta(&[0x80 | 16, 4, 97, 32, 200], &[extra]));
        let edid = parse(&bytes).unwrap();
        assert_eq!((edid.width_mm, edid.height_mm), (1220, 690));
        for want in [
            t(1920, 1080, 60_000),
            t(1280, 720, 60_000),
            t(3840, 2160, 60_000),
            t(1920, 1080, 24_000),
            t(3840, 2160, 30_000),
        ] {
            assert!(edid.timings.contains(&want), "missing {want:?}");
        }
        // The same timing found twice (the detailed one and VIC 16) is listed once.
        assert_eq!(
            edid.timings
                .iter()
                .filter(|x| **x == t(1920, 1080, 60_000))
                .count(),
            1
        );
    }

    #[test]
    fn interlaced_timings_are_left_out() {
        let interlaced = dtd(74_250, (1920, 280), (540, 22), (0, 0), true);
        let edid = parse(&base((60, 34), &[interlaced], &[], 0)).unwrap();
        assert!(edid.timings.is_empty());
    }

    #[test]
    fn rubbish_is_not_an_edid() {
        assert!(parse(&[]).is_none());
        assert!(parse(&[0u8; 128]).is_none());
        let mut short = base((60, 34), &[], &[], 0);
        short.truncate(100);
        assert!(parse(&short).is_none());
        // A truncated extension is ignored, not a panic.
        let mut cut = base((60, 34), &[], &[], 1);
        cut.extend([0x02, 3, 4]);
        assert!(parse(&cut).is_some());
    }
}
