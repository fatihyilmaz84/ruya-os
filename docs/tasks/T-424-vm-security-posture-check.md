# T-424 - `vm-security-check.sh`: hardening scores, listening ports, SELinux and setuid files have a baseline

Status: done · Phase: 2 · Depends: — · Area: scripts, image (baseline files only), docs · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
The invariant "services keep their systemd hardening" and the spec lines "SELinux enforcing" and "nothing listens unless asked" are checked by a script on every booted image, against a checked-in baseline. Today each `vm-*-check.sh` prints `systemd-analyze security` for a person to read, and nothing checks ports, SELinux or setuid files (plan audit 2026-11-10).

## Read first
- `docs/specs/01-platform.md` §3 (security), root `CLAUDE.md` Security invariants, `image/CLAUDE.md`
- `scripts/vm-session-check.sh` (structure, PASS/FAIL lines, JSON parsing), `scripts/lint-vm-checks.ps1`, `scripts/vm-queue.ps1`
- `docs/tasks/PLANNING.md`, Lessons (VM checks parse JSON; a step never SKIPs for a missing tool)

## Scope
1. `scripts/vm-security-check.sh`, run in the booted VM over SSH like the other checks, with these steps:
   - **Units:** for every `ruya-*.service` in the image (found, not listed by hand): `systemd-analyze security --json=short <unit>`; the exposure must be at or below the unit's value in `image/security-baseline.json`. A unit missing from the baseline fails.
   - **Ports:** the listening TCP and UDP sockets (`ss -H -tuln`) equal the expected set in the baseline. Today that set contains what the development image really opens (sshd, DHCP client and so on): write down what is there, each with a one-line reason.
   - **SELinux:** `getenforce` is `Enforcing`; no `ruya-*` process runs `unconfined_service_t` unless the baseline names it with a reason.
   - **Files:** the setuid and setgid files under `/usr` equal the baseline list; nothing under `/usr` or `/etc` is world-writable.
   - **Accounts:** only the accounts in the baseline have a login shell or a usable password field.
2. `image/security-baseline.json`: the first baseline, taken from the current image. A looser value later needs a reason field in the same commit (the reviewer checks it).
3. Add the script to the VM queue list (`vm-queue.ps1`) so the lead runs it on every image.
4. The per-service checks stop printing `systemd-analyze security | tail`; they point to this script (one place).

## Out of scope
- Tightening any unit, closing any port, a release image profile (T-425). This task records and guards the present state; every weakness it shows is an Inbox line.
- Kernel and sysctl hardening choices (T-426).

## Acceptance criteria
- [ ] `scripts/test-vm-checks.sh` (or the existing self-test pattern) proves each step can fail: a fixture with a higher exposure, an extra port, `Permissive`, an extra setuid file and an extra login account each give FAIL (test named in the Outcome). No step SKIPs when a tool is missing (`lint-vm-checks.ps1` green).
- [ ] VM (lead run): `scripts/vm-security-check.sh` on the next image: every step PASS against the baseline; numbers in the Outcome.
- [ ] The Outcome lists what the first baseline shows that should not ship (each also an Inbox line).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/dev-setup.md` (the check and how to update the baseline), `docs/specs/01-platform.md` §3 (what is checked).

## Hints
- The image has no `jq`: python3, as `vm-update-check.sh` does.
- The lead can give a booted VM of the last image to try the script on (LEAD.md 4b); take the baseline from that VM.
- `systemd-analyze security` exposure is a number from 0 to 10; compare with a small tolerance of 0.

## Outcome
Verified: vm (script and baseline against image 0.0.61 over SSH; the queue run on the next image stays the lead's)
Lead, 2026-11-10: `vm-security-check.sh` PASS in the 0.0.62 queue.

Built `scripts/vm-security-check.sh` (modes `check`, `measure`), `image/security-baseline.json`, a queue entry (and the queue copies the baseline next to the script), and the per-service checks (library, profiles, session x2, store, update, usage x2) now print a pointer instead of `systemd-analyze security | tail`. Docs: `dev-setup.md`, `01-platform.md` section 3 item 8.

**VM run on 0.0.61 (round 2).** `measure` then `check`: every step PASS, `ALL CHECKS PASSED`, exit 0. Real output confirmed the parsing (text line "Overall exposure level for ...", `ss -H -tuln` columns incl. `127.0.0.53%lo:53`, `ps -e -o label= -o comm=`). The baseline was replaced by the measured values, each with a reason. Exposure: boot-marker 9.6, compositor@ 9.2, flathub-remote 8.7, update 4.8, grub-menu 3.8, inputd 3.5, store 3.3, profiles 1.6, session 1.1, library 0.8. Ports: tcp 22, tcp 53, tcp 5355, udp 53, udp 5355, udp 323. 17 setuid/setgid files under /usr. Nothing world-writable. Login accounts: root only. SELinux Enforcing.

Deviations: exposure is parsed from the text line "Overall exposure level for <unit>: N" of `systemd-analyze security --no-pager`, not `--json=short` (I could not confirm where the overall figure sits in the JSON on this systemd; the text line is stable). A template unit (`ruya-compositor@.service`) is analysed as instance `ruya-compositor@check.service`. Ports compare as `proto:port` (addresses vary with DHCP).

Tests (`scripts/test-vm-checks.sh`, section "vm-security-check.sh: each step fails on a worse fixture", run by `lint-vm-checks.ps1`): fixture with exposure 1.2 vs 1.1, an extra port, Permissive, an unnamed unconfined `ruya-*` process, an extra setuid file, a world-writable file, an extra login shell, a usable password on a nologin account, a failing `ss`, a failing `systemd-analyze` (FAIL, never SKIP), a unit not in the baseline, and `measure` output. Revert checks (undone one at a time in the script, tests went red each time): the exposure comparison, the SELinux test, the world-writable test, the account comparison, and the `systemd-analyze` failure handling.

What the first baseline shows that should not ship (each is an Inbox line in the HANDOFF):
- sshd listens on all interfaces and root is a login account (dev channel only; T-425).
- Every ruya-* process (inputd, library, profiles, session, shell, store, update) runs `unconfined_service_t`: there is no SELinux policy for our services, so "SELinux enforcing" protects nothing of ours.
- systemd-resolved listens on tcp/udp 5355 (LLMNR) on all interfaces.
- `ruya-boot-marker` 9.6, `ruya-compositor@` 9.2 and `ruya-flathub-remote` 8.7 are barely hardened.
- sudo, pkexec and pam_timestamp_check are setuid on a console OS with no interactive user.
