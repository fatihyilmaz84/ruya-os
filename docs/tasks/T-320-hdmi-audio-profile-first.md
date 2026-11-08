# T-320 — Sound reaches the monitor: the HDMI audio profile is chosen first

Status: done · Phase: 2 · Depends: — · Area: image (WirePlumber rule) · Size: S · Owner: lead

## Goal
On the Dell (OptiPlex 7080, Gigabyte G32QC behind a DP-to-HDMI adapter) the owner heard no UI sound or ambient. Cause found by read-only diagnosis on 2026-11-08 (image 0.0.53): the sound card (HDA Intel PCH, ALC3246 plus three HDMI/DP PCMs) had the profile `output:analog-stereo+input:analog-stereo` active, so PipeWire exposed only the analog jack as a sink (default, 40 %); the kernel saw the monitor (`/proc/asound/card0/eld#2.0`: `monitor_present 1`, `eld_valid 1`, `monitor_name G32QC`) and the card had `output:hdmi-stereo...` profiles, but nobody selected one. The shell's streams were linked to the analog jack, so the sound went nowhere.

## Scope
1. `image/rootfs/usr/share/wireplumber/wireplumber.conf.d/90-ruya-hdmi-first.conf`: a `monitor.alsa.rules` entry sets `device.profile = "output:hdmi-stereo+input:analog-stereo"` for `alsa_card.pci-*`. WirePlumber 0.5's `find-best-profile.lua` uses it when that profile is not `available = no`, else falls back to its normal choice (no display, or a display without audio).

## Out of scope
- Letting the player choose another output of the same card (Settings > Audio lists sinks, and a card exposes one profile's sinks at a time): follow-up below.

## Acceptance criteria
- [x] The rule file is in the image sources (installed by the Containerfile's `cp -r` of `image/rootfs`).
- [x] On the Dell (done with the rule copied to /etc, 2026-11-08; the image copy comes with 0.0.55): `wpctl status` shows `Built-in Audio Digital Stereo (HDMI) [G32QC]` as the default sink and the `ruya-shell` stream linked to it; the owner hears the cues and the ambient bed (vm pending: only real hardware has an HDMI codec, the VM's HDA has none).

## Verification
Dell, over SSH after the image is installed (or by dropping the file into `/etc/wireplumber/wireplumber.conf.d/` (the image installs it under `/usr/share/wireplumber/wireplumber.conf.d/`) and `systemctl --user -M ruya-shell@.host restart wireplumber`):
```bash
runuser -u ruya-shell -- env XDG_RUNTIME_DIR=/run/user/$(id -u ruya-shell) wpctl status | sed -n '/Sinks:/,/Sources:/p'
```

## Docs to update
- `docs/dev-setup.md` if the audio look-at list changes.

## Outcome
**Superseded (lead, 2026-11-08, same day):** the owner's Dell has internal speakers and a monitor without any, so HDMI-first is the wrong default. The rule file was removed from `image/rootfs` again and from the Dell; the real work is T-321 (the shell's own sounds never start) and T-322 (output policy and chooser). What is below is the diagnosis.

Verified: hw (Dell: the rule works and survives a reboot; audibility is for the owner to confirm).

On 2026-11-08 the lead switched the Dell's card profile at runtime with `pw-cli set-param 42 Profile { index: 3, save: false }` (reversible: it returns to analog on the next WirePlumber restart or reboot): a sink `Built-in Audio Digital Stereo (HDMI) [G32QC]` appeared, became the default (volume 40 %) and the shell's stream moved to it. This proved the cause. Installing the rule on the Dell itself was refused by the auto-mode classifier (a remote write needs the owner's own authorization): the owner can run the command above after copying the file.

**Dell, later the same day (owner: "go ahead on the Dell"):** the rule file was copied to `/etc/wireplumber/wireplumber.conf.d/90-ruya-hdmi-first.conf`, wireplumber of `ruya-shell` restarted: the default sink became `Built-in Audio Digital Stereo (HDMI) [G32QC]`; after `systemctl reboot` it was still the default (`wpctl status`: the `ruya-shell` stream linked to `G32QC:playback_FL/FR`). The file stays on the Dell until a 0.0.55 image ships it under `/usr/share`; the owner should now hear the cues and the ambient bed on the monitor (not heard by the lead: no way to hear it). `Verified: hw (Dell: sink and stream routing after a reboot; audibility to be confirmed by the owner)`.

Follow-ups: (1) Settings > Audio should offer the card's other outputs (the analog jack, the other HDMI outputs) by switching the card profile, not only the sinks of the active profile; (2) a `vm`-style check that the rule parses (WirePlumber starts and the default sink exists) with the next image; (3) volume 40 % default on the HDMI sink is low for a first start: look at the first-boot level.
