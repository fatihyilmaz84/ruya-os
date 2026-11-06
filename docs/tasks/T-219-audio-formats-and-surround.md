# T-219 — Audio formats and surround: HDMI formats, channel layout, passthrough, delay

Status: todo · Phase: 4 · Depends: — · Area: api, services, shell, image · Size: M · Owner: lead

## Goal
The console outputs the best audio the TV or receiver can take, and the player can see and choose it. Owner request, 2026-11-06: "audio things like Dolby etc., whatever is possible on Linux". Today Settings -> Audio picks the output and per-channel volumes (T-128, `Devices1.Audio`); the format and channel layout are whatever PipeWire negotiates, usually stereo PCM.

## What Linux can do (verify on hardware)
- **HDMI/DP audio capabilities** come from the sink's EDID/ELD (`/proc/asound/card*/eld#*`): channels, sample rates and the **compressed formats** it accepts (AC-3 = "Dolby Digital", E-AC-3 = "Dolby Digital Plus", DTS, DTS-HD MA, TrueHD).
- **Multichannel PCM** (5.1, 7.1 LPCM) works through ALSA/PipeWire when the ELD allows it: the safest high-quality route (no codec involved on our side).
- **Bitstream passthrough** (the player sends the encoded stream, the receiver decodes): PipeWire/WirePlumber can expose IEC958 passthrough (`api.alsa.iec958.codecs` on the ALSA node) for AC-3, E-AC-3, DTS (and with HDMI raw: TrueHD/DTS-HD where the driver allows); an app opts in (Kodi, mpv with `--audio-spdif`, Jellyfin via mpv). Dolby **Atmos** reaches the receiver only as E-AC-3 JOC / TrueHD-Atmos bitstream from an app that passes it through; the console cannot decode Atmos itself.
- **Licensing:** Dolby and DTS are trademarks and patent-licensed formats. Shipping decoders for the codecs is already covered by ADR-009 (ffmpeg's AC-3/E-AC-3/DTS decoders in the image); **using the names "Dolby"/"DTS" or logos in the UI needs a licence**: until the owner decides, the UI says "Surround (AC-3)", "Surround Plus (E-AC-3)", "DTS" in neutral words and shows no logos. (Owner-level: Inbox.)
- Spatial audio for headphones (virtual surround through HRTF filters, PipeWire `filter-chain`) and EQ presets are possible but are phase B.

## Scope
1. **Contract (`Devices1.Audio`):** per sink: `capabilities` (channels, rates, formats from the ELD, read-only), `channel_layout` setting (`auto` | `stereo` | `5.1` | `7.1`), `passthrough` list setting (`ac3`, `eac3`, `dts`, `truehd`, `dtshd`: only offered when the sink reports them), `av_delay_ms` (-200..+500, default 0), a `PlayTestSound(layout)` call (per-speaker voice/pink-noise test), signals on change. Statuses as the existing methods.
2. **Service (`ruya-devices`, user unit of `ruya-shell` next to PipeWire):** read ELD per HDMI/DP card (pure parser with fixtures from the Dell's ELD, tested), apply the chosen channel layout and passthrough codecs through WirePlumber/PipeWire (`pw-metadata`/node properties/`wpctl`; a settings file under the shell's state dir that a WirePlumber snippet reads; decide which is robust and say why), the A/V delay as a per-sink `node.latency`/delay filter if feasible (otherwise state why it is deferred). Everything survives a reboot and a sink hot-plug (HDMI re-plug re-reads the ELD).
3. **Shell:** Settings -> Audio gets, for the selected output: a read-only line "This TV/receiver supports: Stereo, 5.1, 7.1; Surround (AC-3), Surround Plus (E-AC-3), DTS" (empty and plain for stereo-only), **Speaker layout** (Auto / Stereo / 5.1 / 7.1), **Passthrough** toggles per supported format with a one-line explanation ("Lets apps send surround sound straight to your receiver; the console's own sounds stay stereo"), **Audio delay (lip sync)** stepper, **Test sound**; copy plain, Turkish; mocks cover stereo-only, 5.1 and a receiver with all formats.
4. **Apps:** document in `docs/developers/` (audio chapter, T-214) what an app sees (a 5.1 or 8-channel sink, passthrough for apps that open the IEC958 device), and add a Flatpak test (an app plays a multichannel test file) to the VM/hardware checks.
5. **Phase B (file as Inbox, not built here):** headphone virtual surround (HRTF, licence-clean data), night mode (dynamic range compression), EQ presets, loudness normalisation per output.

## Out of scope
- Decoding Dolby Atmos or DTS:X on the console, Dolby/DTS branding, HDMI-CEC/ARC control of the receiver (a later task), microphone processing, Bluetooth LE audio.

## Acceptance criteria
- [ ] Rust tests: the ELD parser (stereo-only TV, 5.1 AVR, a receiver listing AC-3/E-AC-3/DTS/TrueHD; the Dell's real ELD as a fixture), mapping of settings to PipeWire properties, the available-options rules (never offer a format the sink does not report), persistence and re-read on hot-plug (fake events).
- [ ] `tst_audio*.qml` (mock): the capability line and rows per mock sink, passthrough rows only for supported formats, layout/delay/test writes with the late-reply guard, focus asserted after every move, controller-only operation; screenshots (English and Turkish) read against `04` §8.
- [ ] VM (lead run): `vm-devices-check.sh` audio part extended: capabilities of the virtual sound card, a layout change visible in `pw-dump`/`wpctl`, persistence after a service restart.
- [ ] Hardware (lead, the Dell over HDMI/DP and, if available, an AV receiver): the ELD matches the parsed capabilities, 5.1 is accepted (or refused with the reason when the TV only does stereo), a multichannel test plays on the right speakers, passthrough of an AC-3 test file reaches the receiver (the receiver's display shows the format).
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `03` §2.3 Audio (formats), `Devices1.xml`, `00-overview.md` ADR-010 note and an owner-level Inbox item on the "Dolby"/"DTS" names, `docs/developers/` audio chapter, `docs/dev-setup.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
