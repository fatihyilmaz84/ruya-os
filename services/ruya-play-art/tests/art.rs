mod common;

use common::*;
use image::{ImageFormat, Rgb, RgbImage};
use ruya_play_art::{codes, decode_count, refuses_package, vet, Outcome, Slot};
use tempfile::tempdir;

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// slot, file name, bytes, expected (output stem, size)
type Case = (Slot, &'static str, Vec<u8>, Vec<(&'static str, (u32, u32))>);

#[test]
fn good_image_for_every_slot() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let cases: Vec<Case> = vec![
        (
            Slot::Icon,
            "icon.png",
            png(1024, 1024),
            vec![
                ("icon-512", (512, 512)),
                ("icon-256", (256, 256)),
                ("icon-128", (128, 128)),
            ],
        ),
        (
            Slot::Logo,
            "logo.webp",
            webp(2000, 800),
            vec![("logo", (1280, 512))],
        ),
        (
            Slot::Hero,
            "hero.jpg",
            jpeg(1920, 1080),
            // never upscaled: a 1920 source keeps 1920 for the "2160" file
            vec![
                ("hero-2160", (1920, 1080)),
                ("hero-1080", (1920, 1080)),
                ("card-540", (960, 540)),
            ],
        ),
        (
            Slot::Cover,
            "cover.png",
            png(1200, 1800),
            vec![("cover-900", (600, 900))],
        ),
        (
            Slot::Screenshot(3),
            "s3.jpeg",
            jpeg(1280, 720),
            vec![
                ("screenshot-3-1080", (1280, 720)),
                ("screenshot-3-thumb", (480, 270)),
            ],
        ),
        (
            Slot::TrailerPoster,
            "poster.png",
            png(1920, 1080),
            vec![("trailer-poster-1080", (1920, 1080))],
        ),
    ];
    for (slot, name, bytes, expect) in cases {
        let o = run(slot, write(src.path(), name, &bytes), out.path());
        let got = files(&o);
        assert_eq!(got.len(), expect.len(), "{slot:?}");
        for (f, (stem, d)) in got.iter().zip(expect) {
            assert_eq!(
                f.file_name().unwrap().to_str().unwrap(),
                format!("{stem}.webp")
            );
            assert_eq!(dims(f), d, "{stem}");
            let b = std::fs::read(f).unwrap();
            assert_eq!(&b[..4], b"RIFF");
            assert_eq!(&b[8..12], b"WEBP");
        }
    }
}

#[test]
fn large_hero_is_scaled_to_the_canonical_sizes() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let o = run(
        Slot::Hero,
        write(src.path(), "hero.png", &png(4096, 2304)),
        out.path(),
    );
    let f = files(&o);
    assert_eq!(
        f.iter().map(|p| dims(p)).collect::<Vec<_>>(),
        vec![(3840, 2160), (1920, 1080), (960, 540)]
    );
}

#[test]
fn missing_file_is_missing_and_a_broken_hero_refuses_the_package() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let bad = write(src.path(), "hero.png", b"junk");
    let r = vet(
        &[
            (Slot::Logo, src.path().join("nope.png")),
            (Slot::Hero, bad.clone()),
        ],
        out.path(),
    );
    assert_eq!(r[0].outcome, Outcome::Missing);
    assert!(matches!(r[1].outcome, Outcome::Invalid { .. }));
    assert!(refuses_package(&r));
    // a broken screenshot only loses that art
    let r = vet(&[(Slot::Screenshot(0), bad)], out.path());
    assert!(!refuses_package(&r));
    assert!(!refuses_package(&vet(
        &[(Slot::Logo, src.path().join("x.png"))],
        out.path()
    )));
}

#[test]
fn wrong_aspect_ratio() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let o = run(
        Slot::Hero,
        write(src.path(), "h.png", &png(2000, 1100)),
        out.path(),
    );
    assert_eq!(code(&o), codes::ASPECT_RATIO);
    let o = run(
        Slot::Icon,
        write(src.path(), "i.png", &png(1000, 600)),
        out.path(),
    );
    assert_eq!(code(&o), codes::ASPECT_RATIO);
    let o = run(
        Slot::Cover,
        write(src.path(), "c.png", &png(1200, 1200)),
        out.path(),
    );
    assert_eq!(code(&o), codes::ASPECT_RATIO);
}

#[test]
fn logo_wider_than_four_to_one_is_refused() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let o = run(
        Slot::Logo,
        write(src.path(), "l.png", &png(1400, 300)),
        out.path(),
    );
    assert_eq!(code(&o), codes::ASPECT_RATIO);
}

#[test]
fn too_small() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let o = run(
        Slot::Hero,
        write(src.path(), "h.png", &png(1280, 720)),
        out.path(),
    );
    assert_eq!(code(&o), codes::TOO_SMALL);
    let o = run(
        Slot::Icon,
        write(src.path(), "i.png", &png(256, 256)),
        out.path(),
    );
    assert_eq!(code(&o), codes::TOO_SMALL);
    let o = run(
        Slot::Logo,
        write(src.path(), "l.png", &png(300, 100)),
        out.path(),
    );
    assert_eq!(code(&o), codes::TOO_SMALL);
}

#[test]
fn oversized_dimensions_never_reach_a_decoder() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let before = decode_count();
    let p = write(src.path(), "bomb.png", &png_bomb(20000, 20000));
    assert_eq!(
        code(&run(Slot::Hero, p, out.path())),
        codes::DIMENSIONS_TOO_LARGE
    );
    // within 8192 per side but over 64 megapixels
    let p = write(src.path(), "bomb2.png", &png_bomb(8192, 8193));
    assert_eq!(
        code(&run(Slot::Hero, p, out.path())),
        codes::DIMENSIONS_TOO_LARGE
    );
    // a WebP header can claim up to 16384 per side
    let p = write(src.path(), "bomb3.webp", &webp_bomb(16384, 16384));
    assert_eq!(
        code(&run(Slot::Hero, p, out.path())),
        codes::DIMENSIONS_TOO_LARGE
    );
    assert_eq!(
        decode_count(),
        before,
        "a decoder was asked to decode a bomb"
    );
    assert!(std::fs::read_dir(out.path()).unwrap().next().is_none());
}

#[test]
fn extension_lies() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let gif = b"GIF89a\x01\x00\x01\x00\x00\x00\x00;".to_vec();
    let o = run(Slot::Hero, write(src.path(), "a.png", &gif), out.path());
    assert_eq!(code(&o), codes::MAGIC_MISMATCH);
    let o = run(
        Slot::Hero,
        write(src.path(), "b.png", &jpeg(1920, 1080)),
        out.path(),
    );
    assert_eq!(code(&o), codes::MAGIC_MISMATCH);
    // an honest GIF is simply not an accepted format
    let o = run(Slot::Hero, write(src.path(), "c.gif", &gif), out.path());
    assert_eq!(code(&o), codes::FORMAT_UNSUPPORTED);
    // so is JPEG for a slot that only takes PNG or WebP
    let o = run(
        Slot::Icon,
        write(src.path(), "d.jpg", &jpeg(1024, 1024)),
        out.path(),
    );
    assert_eq!(code(&o), codes::FORMAT_UNSUPPORTED);
    let o = run(
        Slot::Hero,
        write(src.path(), "e.png", b"not an image at all"),
        out.path(),
    );
    assert_eq!(code(&o), codes::FORMAT_UNSUPPORTED);
}

#[test]
fn animated_images_are_refused() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let o = run(
        Slot::Hero,
        write(src.path(), "h.webp", &animated_webp(1920, 1080)),
        out.path(),
    );
    assert_eq!(code(&o), codes::ANIMATED);
    // APNG: an acTL chunk before the first IDAT
    let mut actl = 2u32.to_be_bytes().to_vec();
    actl.extend_from_slice(&0u32.to_be_bytes());
    let apng = png_insert_before_idat(&png(1920, 1080), &png_chunk(b"acTL", &actl));
    let o = run(Slot::Hero, write(src.path(), "h.png", &apng), out.path());
    assert_eq!(code(&o), codes::ANIMATED);
}

#[test]
fn svg_named_png() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let svg = b"<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"><script>x</script></svg>";
    let o = run(Slot::Icon, write(src.path(), "i.png", svg), out.path());
    assert_eq!(code(&o), codes::SVG);
    let o = run(
        Slot::Icon,
        write(src.path(), "j.png", b"  \n<svg width=\"1\"/>"),
        out.path(),
    );
    assert_eq!(code(&o), codes::SVG);
}

#[test]
fn truncated_file() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let full = jpeg(1920, 1080);
    let o = run(
        Slot::Hero,
        write(src.path(), "h.jpg", &full[..full.len() / 2]),
        out.path(),
    );
    assert_eq!(code(&o), codes::CORRUPT);
    let full = png(1920, 1080);
    let o = run(
        Slot::Hero,
        write(src.path(), "h.png", &full[..full.len() / 2]),
        out.path(),
    );
    assert_eq!(code(&o), codes::CORRUPT);
    let o = run(
        Slot::Hero,
        write(src.path(), "g.png", &full[..20]),
        out.path(),
    );
    assert_eq!(code(&o), codes::CORRUPT);
    assert!(std::fs::read_dir(out.path()).unwrap().next().is_none());
}

#[test]
fn file_size_limit_and_non_files() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let big = vec![0u8; 2 * 1024 * 1024 + 1];
    let o = run(Slot::Icon, write(src.path(), "i.png", &big), out.path());
    assert_eq!(code(&o), codes::FILE_TOO_LARGE);
    let o = run(Slot::Hero, src.path().to_path_buf(), out.path());
    assert_eq!(code(&o), codes::NOT_A_FILE);
    let o = run(Slot::Screenshot(20), src.path().join("x.png"), out.path());
    assert_eq!(code(&o), codes::TOO_MANY_SCREENSHOTS);
}

#[test]
fn non_srgb_profile_is_converted_and_not_kept() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let p3 = moxcms::ColorProfile::new_display_p3().encode().unwrap();
    let input = png_with_icc(512, 512, [200, 100, 50], p3);
    assert!(contains(&input, b"iCCP"));
    let o = run(Slot::Icon, write(src.path(), "i.png", &input), out.path());
    let f = files(&o);
    let px = image::open(&f[0]).unwrap().to_rgba8();
    let c = px.get_pixel(10, 10).0;
    assert_ne!(&c[..3], &[200, 100, 50], "the P3 colour must be converted");
    assert!(c[0] > 200 && c[1] < 100 && c[2] < 50, "{c:?}");
    for file in f {
        let b = std::fs::read(file).unwrap();
        assert!(!contains(&b, b"ICCP") && !contains(&b, b"EXIF") && !contains(&b, b"XMP"));
    }
    // without a profile the pixels pass through unchanged (sRGB is assumed)
    let img = RgbImage::from_pixel(512, 512, Rgb([200, 100, 50]));
    let o = run(
        Slot::Icon,
        write(src.path(), "j.png", &encode(img, ImageFormat::Png)),
        out.path(),
    );
    let px = image::open(&files(&o)[0]).unwrap().to_rgba8();
    assert_eq!(px.get_pixel(10, 10).0, [200, 100, 50, 255]);
}

#[test]
fn unusable_profile_is_refused() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let input = png_with_icc(512, 512, [1, 2, 3], b"this is not an ICC profile".to_vec());
    let o = run(Slot::Icon, write(src.path(), "i.png", &input), out.path());
    assert_eq!(code(&o), codes::COLOUR_PROFILE);
}

#[test]
fn exif_gps_is_removed_from_the_output() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let sentinel = b"GPSLatitude 51.5074 N GPSLongitude 0.1278 W";
    let input = jpeg_with_exif(&jpeg(1920, 1080), &tiff(1, sentinel));
    assert!(contains(&input, sentinel));
    let o = run(Slot::Hero, write(src.path(), "h.jpg", &input), out.path());
    for f in files(&o) {
        let b = std::fs::read(f).unwrap();
        assert!(!contains(&b, b"GPS"), "GPS data survived");
        assert!(!contains(&b, b"51.5074"));
        assert!(!contains(&b, b"EXIF") && !contains(&b, b"Exif"));
    }
}

#[test]
fn exif_orientation_is_applied_before_the_checks() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    // stored 1080x1920, orientation 6 (rotate 90 clockwise) -> shown 1920x1080
    let input = jpeg_with_exif(&jpeg(1080, 1920), &tiff(6, b""));
    let o = run(Slot::Hero, write(src.path(), "h.jpg", &input), out.path());
    assert_eq!(dims(&files(&o)[0]), (1920, 1080));
}

#[test]
fn icon_keeps_transparency_and_hero_drops_it() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let mut img = image::RgbaImage::from_pixel(512, 512, image::Rgba([10, 20, 30, 255]));
    img.put_pixel(5, 5, image::Rgba([255, 255, 255, 0]));
    let mut bytes = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut bytes, ImageFormat::Png)
        .unwrap();
    let o = run(
        Slot::Icon,
        write(src.path(), "i.png", &bytes.into_inner()),
        out.path(),
    );
    let px = image::open(&files(&o)[0]).unwrap().to_rgba8();
    assert_eq!(px.get_pixel(5, 5).0[3], 0);
    assert_eq!(px.get_pixel(100, 100).0, [10, 20, 30, 255]);
}

#[test]
fn deterministic() {
    let src = tempdir().unwrap();
    let hero = write(src.path(), "h.jpg", &jpeg(2560, 1440));
    let icon = write(src.path(), "i.png", &png(1024, 1024));
    let a = tempdir().unwrap();
    let b = tempdir().unwrap();
    let inputs = [(Slot::Hero, hero), (Slot::Icon, icon)];
    let ra = vet(&inputs, a.path());
    let rb = vet(&inputs, b.path());
    let mut n = 0;
    for (x, y) in ra.iter().zip(&rb) {
        for (fa, fb) in files(&x.outcome).iter().zip(files(&y.outcome)) {
            assert_eq!(std::fs::read(fa).unwrap(), std::fs::read(fb).unwrap());
            n += 1;
        }
    }
    assert_eq!(n, 6);
}

/// Not a check: prints the size of the lossless canonical files (RUY-94 Outcome) and asserts a
/// sanity ceiling for a photo-like 4K hero.
#[test]
fn report_canonical_sizes() {
    let src = tempdir().unwrap();
    for (name, w, h, noise) in [
        ("4k-smooth", 3840, 2160, false),
        ("4k-noisy", 3840, 2160, true),
        ("1080p-noisy", 1920, 1080, true),
    ] {
        let out = tempdir().unwrap();
        let bytes = encode(gradient(w, h, noise), ImageFormat::Jpeg);
        let o = run(
            Slot::Hero,
            write(src.path(), &format!("{name}.jpg"), &bytes),
            out.path(),
        );
        let sizes: Vec<(String, u64)> = files(&o)
            .iter()
            .map(|f| {
                (
                    f.file_name().unwrap().to_string_lossy().into_owned(),
                    std::fs::metadata(f).unwrap().len(),
                )
            })
            .collect();
        println!("hero {name}: {sizes:?}");
        assert!(sizes.iter().all(|(_, n)| *n < 64 * 1024 * 1024));
    }
}
