# T-338 - Dell: why did the second DualSense drop after 21 seconds? (live repro and report)

Status: todo · Phase: 2 · Depends: T-335 · Area: hardware (Dell, no code) · Size: S · Owner: lead

## Goal
Owner report: "the second DualSense overrides the first". The read-only look at the Dell (image 0.0.53) found both pads paired, bonded and trusted; the new pad (88:03:4C:3F:60:E1) connected at 19:27:27 and dropped 21 s later (`ruya-inputd: ... gone: No such device`) while the first (24:A6:FA:AD:DD:EA) never left. Nobody knows why it dropped: the owner switched it off, the link timed out, or a rule disconnected it. This task reproduces it on the Dell with the logs T-335 adds and a controller trace, and reports the cause. The Dell is a pure test machine (root `CLAUDE.md`, Host): do anything over SSH, report afterwards (`Dell: <what was done>`).

## Read first
- `docs/LEAD-NOTES.md` "Owner report the second DualSense overrides the first" (the finding and the code places)
- `docs/tasks/T-335-bluetooth-info-logging.md` (the INFO lines to read), `T-336` (the second adapter), `T-334` (the code-level two-pad tests)
- `services/ruya-devices/src/idle_pads.rs` (`decide`: a pad is disconnected only after its own `timeout` since it was first seen connected and a global idle at least as long), `bluetooth.rs` `report_idle`
- Dell access: 192.168.178.109, root, `~/.ssh/ruyaos_dev`, `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`

## Scope
1. Ask the owner what exactly they saw (which pad stopped, did a Settings row vanish, did pad 1 stop responding) if it is not already in the report; otherwise proceed.
2. On the Dell (image with T-335 or later; without it, still do 3-4): note `bluetoothctl list`/`show` for both adapters (`hci0`, `hci1`), the configured idle timeout in Settings > Power and what `report_idle` is sent (journal of the shell), `bluetoothctl info` for both pads.
3. With `journalctl -f -u bluetooth -t ruya-devices -t ruya-inputd` and `btmon -w /tmp/pad2.btsnoop` running, put pad 2 in pairing mode (PS + Create), let the window pair it, leave both pads untouched for 2 minutes, then press buttons on each. Repeat once with pad 1 switched off first, once with pad 2 paired through Settings > Bluetooth by hand.
4. Read the capture: the HCI disconnect reason code of pad 2 (`btmon`: "Disconnect Complete ... Reason: Connection Timeout / Remote User Terminated / ...") and which side asked; match it with the `ruya-devices` lines (idle disconnect? agent? sweep?) and the `ruya-inputd` `gone` line.
5. Report in the Outcome: reproduced yes/no, the reason code, the cause, whether any pad ever replaced another, and the follow-up (a task for the cause, or "the owner switched it off"). Copy the minimal log excerpt (no keys). If the cause is a bug, add an Inbox line for the lead to plan; do not fix it here.

## Out of scope
- Code changes (T-334..T-337 hold the code work), reinstalling the Dell, anything on the owner's PC.

## Acceptance criteria
- [ ] The Outcome names the HCI reason code and who sent it, with the matching `ruya-devices`/`ruya-inputd` lines, for at least one drop (or says the drop did not reproduce in N attempts and what was tried).
- [ ] The Outcome states whether pad 1 was affected at any moment (connection state and input) with the evidence.
- [ ] `Dell: <what was done>` line in the Outcome (settings changed, files put in `/etc`, restarts).
- [ ] The two-adapter question is answered: which adapter each pad is bonded on and why there are two (`hciconfig -a`, `btmgmt info`, `lsusb`).

## Verification
Hardware (lead): the steps above; no `dev.ps1` run needed.

## Docs to update
- This Outcome; `docs/LEAD-NOTES.md` is rewritten by the lead at the end of the session anyway.

## Hints
- Pairing mode on a DualSense: hold PS and Create until the light bar flashes quickly.
- A runtime overlay vanishes at reboot; put nothing on the Dell that the result depends on without noting it.

## Outcome
_Filled in by the lead._
