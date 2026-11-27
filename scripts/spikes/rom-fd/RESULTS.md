# RUY-1152 spike results: ROM fds through the door (ADR-048 A4)

Dell, 2026-11-28, RuyaOS image 0.0.109 (Fedora 44 bootc, kernel 7.3.4-200.fc44), Flatpak 1.18.4, xdg-dbus-proxy 0.1.9, dbus-broker 37, `/var` on XFS, Intel Core i5-10500T (12 threads), profile p1 (`ruya-p1`, uid 1000) signed in. The engineer of RUY-1152 ran everything below over SSH; raw log of the final run: `check.log` in that session's scratchpad (not committed), every number below is copied from it.

## Method

Nothing of this is in the image. [`scripts/vm-roms-check.sh`](../../vm-roms-check.sh) (a DRAFT VM check, modes `check facts paths bench setup clean`) builds the chain, runs the three facts and removes everything again; [`scripts/vm-roms-probe.py`](../../vm-roms-probe.py) is every process in it (plain python3 of the image with a minimal D-Bus connection that negotiates unix fds, `NEGOTIATE_UNIX_FD` and `SCM_RIGHTS`, the same code inside and outside the sandbox).

```
sandbox (flatpak run, ruya-p1)  --D-Bus-->  xdg-dbus-proxy (flatpak's, --system-talk-name=org.ruyaos.SpikeDoor)
  --> dbus-broker --> "door" (stand-in for ruya-platform, sysuser ruyaspike-door)
  --> dbus-broker --> "stand-in" (for ruya-gamedata, sysuser ruyaspike-gd): OpenRom(s id) -> (s status, a(sh) members)
```

- **The collection:** `/var/lib/ruyaspike-roms/nes/<entry>/<files>`, every directory 0700 `ruyaspike-gd`, files 0644 `ruyaspike-gd`. Entries: `small` (64 KiB), `big` (4 GiB, `fallocate`), `set` (cue + 2 bins), `m250` and `m300` (250 and 300 files of 16 bytes), `wr` (a 0666 file), `own` (0644, owned by `ruya-p1`).
- **The stand-in** opens each member `O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NOCTTY` and replies with the fds, then closes its copies. **The door** calls the stand-in on its own connection, hands the reply's body and fds on unchanged (the `h` values are indices into the message's fd list, so the body needs no rewriting) and closes its copies. Both run as transient units (`systemd-run -p Type=dbus -p User=...`) with exactly `ruya-platform.service`'s `[Service]` hardening (`CapabilityBoundingSet=` empty, `ProtectSystem=strict`, `PrivateTmp`, `PrivateNetwork`, `RestrictAddressFamilies=AF_UNIX`, `SystemCallFilter=@system-service`, `MemoryDenyWriteExecute`, `ProtectProc=invisible`, ...). Mode `ro` (default) gives the stand-in nothing writable; fact 1b restarts it with `ReadWritePaths=/var/lib/ruyaspike-roms`, as a gamedata that also imports would have.
- **Why stand-ins, not the real ruya-platform:** 0.0.109's ruya-platform has no ROM method to forward and still runs as root (ADR-047 is not in the image yet: `id ruya-platform` = no such user). The door stand-in has the shape ADR-047 asks for: its own sysuser, no capabilities, a per-method allow-list towards the internal service.
- **Bus policy** (`/etc/dbus-1/system.d/ruyaspike.conf`, then `systemctl reload dbus-broker`): `ruyaspike-gd` owns `org.ruyaos.SpikeGamedata`, which only `ruyaspike-door` may call, and only `OpenRom` (root may call it for the per-hop numbers); `ruyaspike-door` owns `org.ruyaos.SpikeDoor`, whose `OpenRom` every user may call (Platform1's public-door shape).
- **The sandbox:** a local Flatpak app `org.ruyaos.SpikeRomClient` on a minimal runtime (sh and its libraries), `--system-talk-name=org.ruyaos.SpikeDoor` and `--filesystem=host-os:ro` (only to run the image's python3 from `/run/host`, as `vm-platform-check.sh` does), run as the profile with `systemd-run --machine=ruya-p1@.host --user --wait --pipe flatpak run --command=probe org.ruyaos.SpikeRomClient ...`. Its system bus is Flatpak's xdg-dbus-proxy.

Re-run: copy `vm-roms-check.sh` and `vm-roms-probe.py` into one folder on the VM or Dell, sign a profile in, `bash vm-roms-check.sh` (54 s; `ALL PASS` on 2026-11-28).

## Fact 1: the fd arrives in the sandbox, reads, and reopens read-only only: **holds**

Through the real xdg-dbus-proxy: `OpenRom small` = `ok`, one member, one fd; `fcntl(F_GETFL)` = `O_RDONLY`; the first MiB's sha256 matches the file; `pread` at the end works. On the fd and on `/proc/self/fd/N` (the stand-in's collection on a read-only mount, the default):

| Attempt in the sandbox | Result |
|---|---|
| `open("/proc/self/fd/N", O_RDONLY)` | ok, same bytes |
| `open(..., O_RDWR)`, `O_WRONLY\|O_APPEND` | `EACCES` |
| `open(..., O_RDONLY\|O_TRUNC)` | `EROFS` |
| `write(fd)` | `EBADF` |
| `fcntl(F_SETFL, O_RDWR)` | no effect: the access mode stays `O_RDONLY` |
| `ftruncate` | `EINVAL` |
| `fchmod 0666`, `fchown`, `setxattr user.x`, `ioctl FS_IOC_SETFLAGS` | `EROFS` |
| `mmap(MAP_SHARED, PROT_WRITE)` / `mmap(MAP_PRIVATE, PROT_READ)` | `EACCES` / ok |
| `openat(fd, "..")`, `open("/proc/self/fd/N/..")` | `ENOTDIR` |
| `link("/proc/self/fd/N", <app data>)` with `AT_SYMLINK_FOLLOW` | `EXDEV` (`fs.protected_hardlinks` is 1 as well) |
| `readlink("/proc/self/fd/N")` | **the host path**, `/var/lib/ruyaspike-roms/nes/small/small.nes` |
| `fstat` | size right, uid 65534 (the stand-in's uid is not mapped into the sandbox), mode 0644 |

- **4 GiB file:** `fstat` size 4294967296, the last page reads. **A set:** 3 members, 3 fds, names in order. **250 fds in one reply:** arrive (24.8 ms for that one call). **300 fds:** the stand-in's `sendmsg` fails `EINVAL` (the kernel's `SCM_MAX_FD` = 253 per message), so the reply is `failed`.
- **The `wr` (0666) and `own` (profile-owned) files on the read-only mount:** reopen `O_RDWR` is **`EROFS`**. The fd carries the mount it was opened through, and the stand-in's namespace (`ProtectSystem=strict`) has the collection read-only, so the reopen inherits that mount's `ro` flag, whatever the file's mode.

**Fact 1b (collection writable in the stand-in's namespace, `ReadWritePaths`):** the 0644 file of another user still refuses (`O_RDWR`, `O_WRONLY`, `O_TRUNC`: `EACCES`; `fchmod`: `EPERM`), but the **0666 file and the profile-owned file reopen `O_RDWR` and `O_TRUNC` successfully** (the probe truncated them: sha256 of the empty string afterwards), and `fchmod` of the profile-owned file works. So with a writable mount the file's mode and owner are the only guard, as A4 says; with a read-only mount there is a second one.

## Fact 2: no path to the collection: **holds**

- **In the sandbox:** `/var/lib/ruyaspike-roms`, `.../nes`, `.../nes/small`, `.../small.nes`, `/var/lib`, `/run/host/var/lib/ruyaspike-roms`, `/run/host/root`: all `ENOENT` (stat, list and open). The sandbox has no `/var/lib` at all.
- **The profile user outside a sandbox** (`runuser -u ruya-p1`): `stat` of the top directory works (its parent is 0755: the name is not secret), listing and opening it `EACCES`; `stat`, list and open of an entry or a file `EACCES`. The 0700 directory is the access control, as A4 says.
- **The door user** cannot stat the collection either (`EACCES`, from the door's own journal line): the middle hop never needs a path.
- **The allow-list:** the door calling the stand-in's `Delete` is `AccessDenied` (dbus-broker); the sandbox calling the stand-in directly gets `ServiceUnknown` from xdg-dbus-proxy (the name is not in its `--talk` list).

## Fact 3: the cost per OpenRom: **negligible**

Warm: 200 calls on one connection, after one warm-up call; ms, median / p95. Each caller closes the fds it gets.

| Entry (fds) | root -> stand-in | root -> door -> stand-in | sandbox -> proxy -> door -> stand-in |
|---|---|---|---|
| `__none__` (0, same chain, no fd) | 0.129 / 0.177 | 0.246 / 0.320 | 0.309 / 0.391 |
| `small` 64 KiB (1) | 0.179 / 0.219 | 0.299 / 0.459 | 0.367 / 0.414 |
| `big` 4 GiB (1) | 0.149 / 0.211 | 0.318 / 0.407 | 0.360 / 0.415 |
| `set` (3) | 0.174 / 0.223 | 0.353 / 0.423 | 0.370 / 0.495 |

`ruya-p1` outside a sandbox -> door -> stand-in, `small`: 0.290 / 0.383. Per hop (medians): the stand-in about 0.13-0.18, the door about +0.12-0.17 (one more bus round trip), xdg-dbus-proxy about +0.02-0.07. The fd itself (`small` against `__none__`, including the `open`) adds about 0.05 ms end to end. **A 4 GiB file costs nothing more** (0.360 against 0.367): an fd is a reference, its size is never touched. An earlier run of the same mode gave the same picture (sandbox `small` 0.327 / 0.490).

Cold: 50 runs, `echo 3 > /proc/sys/vm/drop_caches` before each, a new process and connection each time (in the sandbox: a new `flatpak run`, so a new proxy too; the numbers exclude the sandbox's start):

| Cold | connect (auth, fd negotiation, Hello) | first OpenRom |
|---|---|---|
| root -> door, `small` | 0.332 / 0.503 | 1.510 / 1.862 |
| sandbox -> door, `small` (first call of a new app) | 1.091 / 1.416 | 1.531 / 1.953 |
| sandbox -> door, `big` 4 GiB | 1.117 / 1.686 | 1.174 / 1.493 |

The door and stand-in are Python here; the bus, the proxy and the kernel are the image's. A Rust door (zbus) will not be slower than this. Only a 250-member reply is noticeable (about 25 ms, about 0.1 ms per fd).

## What breaks or needs care (findings)

1. **The fd carries the opener's mount, and that decides more than the file mode.** Opened through a read-only mount, nothing can reopen it for writing (`EROFS`, measured); through a writable one, a file that is 0666 or owned by the profile reopens `O_RDWR` and can be truncated (measured). A4's "files 0644" is right but not enough on its own: ruya-gamedata also writes its collection (A5 moves imports in), so its unit needs the collection writable, and fds opened through that writable view would rely on the mode alone. **Proposal:** ruya-gamedata opens every fd it hands out through a read-only view of the collection (`BindReadOnlyPaths=` of the collection onto a second path in its own namespace, writes only through the first), and refuses to hand out a file that is not a regular file, is group- or other-writable, or is owned by anything but ruya-gamedata (internal) or the drive's mount owner (in place). Reasoned, not measured: a drive mounted **after** ruya-gamedata started propagates into its namespace with the drive's own (rw) flags, not `ProtectSystem`'s; in-place fds therefore need their own read-only bind too (a RUY-1155 check, below).
2. **In-place drives today** (measured on the Dell: the exFAT stick is `rw,uid=972,gid=972,fmask=0022,dmask=0022` under `/run/media/ruya-shell/`): files 0644 owned by `ruya-shell`, so ruya-gamedata can read them and a sandbox's `O_RDWR` reopen would be `EACCES` (owner is not the profile). That holds only while drives are mounted with the shell's uid and `fmask=0022`; a mount with a profile's uid or a looser fmask would make in-place ROMs writable through their fds, unless (1) is done.
3. **`readlink("/proc/self/fd/N")` shows the host path** (`/var/lib/.../<system>/<entry-id>/<name>`). It grants nothing (fact 2), but: it tells the app the layout and the entry id; and `realpath()` of `ruya_rom_materialise_set()`'s symlinks resolves through the magic link to that host path, which does not exist in the sandbox. An emulator that canonicalises its content path before opening it (or to find a cue's sibling files) will then fail `ENOENT`. Reasoned from the measured `readlink`; RUY-1155's sample must test `realpath` on a materialised set, and the client library's docs must say "open the path as given, do not canonicalise".
4. **SCM_RIGHTS limit:** at most 253 fds per message (measured: 250 ok, 300 `EINVAL` at the sender). A set larger than that cannot be one `OpenRom` reply; A4 should cap members per entry (the import helper, A5) well below it.
5. **What the middle hop must do (ruya-platform under ADR-047):** nothing privileged. It needs no capability, no path and no `O_PATH`: receiving fds in a reply and sending them in its own reply is plain `SCM_RIGHTS` on its two bus connections (measured with the stand-in under ruya-platform's hardening). In zbus 5 (the services' 5.19), the reply type is `(String, Vec<(String, zvariant::OwnedFd)>)` on both sides; fd passing is negotiated on unix transports. It must drop (close) its copies right after replying and record only the fact "handed to instance X" (A4's held-open record), never keep the fds, or its `RLIMIT_NOFILE` (1024 soft) becomes a limit. zbus details are reasoned from its API, not run.
6. **xdg-dbus-proxy forwards fds** for a name in its `--talk` list (measured: `--system-talk-name`, Flatpak 1.18.4, proxy 0.1.9); a name not in the list is `ServiceUnknown`. Platform1 is already `--system-talk-name` for apps, so nothing changes there.
7. **The fd must be `O_RDONLY`, not `O_PATH`:** an emulator reads the fd or reopens `/proc/self/fd/N`; an `O_PATH` fd cannot be read directly. Sealing does not apply (memfd seals are for memfds, not for files on XFS), and it is not needed: the reopen check is the inode's mode plus the mount's `ro` flag, as measured. Reasoned for `O_PATH` and seals; not run.

## Proposed paragraph for ADR-048 (for the lead to paste after A4)

**Spike result (RUY-1152, 2026-11-28, Dell image 0.0.109).** A4 holds, with two additions. Measured with stand-ins for ruya-gamedata and ruya-platform (own sysusers, ruya-platform's hardening, a per-method allow-list) and a Flatpak app behind the real xdg-dbus-proxy (`scripts/vm-roms-check.sh`, `scripts/spikes/rom-fd/RESULTS.md`): the fds arrive in the sandbox `O_RDONLY` and read; `/proc/self/fd/N` reopens read-only and never for writing (`EACCES`, `EROFS`); the sandbox has no path to the collection and the profile user outside it is refused by the 0700 directory; the whole chain costs 0.37 ms median and 0.41 ms p95 warm, about 1.5 ms for an app's first call, and a 4 GiB file costs the same as a small one. **(a) Read-only view:** ruya-gamedata opens every fd it hands out through a read-only bind of the collection (and of each in-place location) in its own namespace, never through the path it writes; it hands out only regular files that are not group- or other-writable and not owned by a profile. Through a writable mount a 0666 or profile-owned file reopens `O_RDWR`; through a read-only one nothing does. **(b) Limits:** an entry has at most 64 members (one `SCM_RIGHTS` message carries at most 253 fds); ruya-platform closes the fds it forwards right after the reply and keeps only the held-open record. `ruya_rom_materialise_set()`'s documentation says to open the given path and never canonicalise it: `readlink` of `/proc/self/fd/N` shows the host path, which does not exist in the sandbox.

## Open questions

1. The 64-member cap in (b) is a proposal: is there a real disc set with more files (a PS1 multi-track game is at most 99 tracks plus a cue)? If so, 128 still fits under 253.
2. Does the read-only bind (finding 1) also cover drives mounted after ruya-gamedata started, or does ruya-devices need to make a read-only bind of each location for it (mount propagation)? Not measured.
3. Is the host-path leak in `readlink` acceptable for a tier-B experimental door (it reveals the entry id and the system, which `ListRoms` gives the app anyway), or should the stand-in path be a neutral one (open through a bind like `/run/ruyaos/roms-ro/<entry-id>/<name>`, which then also is what `readlink` shows)?
4. Rate limiting: OpenRom costs microseconds, but a 250-member reply costs 25 ms of broker and door time; Platform1's `rate-limited` should count fds, not calls.

## Tickets the findings imply (for the lead to file)

- **RUY-1153 (gamedata skeleton):** the unit gets the collection writable for its own moves and a `BindReadOnlyPaths=` view it opens handed-out fds through; a mode and owner check before any fd leaves (regular file, not group/other-writable, owner gamedata or the drive's mount owner, never a profile uid); a unit test for that check.
- **RUY-1155 (Roms door):** `OpenRom` replies carry at most the entry's members (capped, see RUY-1156); ruya-platform drops forwarded fds right after the reply and records the instance; `vm-roms-check.sh` is promoted from this draft to the real services (ruya-gamedata, ruya-platform, the sample emulator instead of the probe app), plus `EROFS` for an in-place drive file plugged in after ruya-gamedata started, and `realpath` of a materialised set; host fixtures in `test-vm-checks.sh`.
- **RUY-1156 (import helper):** writes every imported file 0644 owned by ruya-gamedata (never group- or other-writable, never a profile owner) and refuses entries with more members than the cap.
- **RUY-1154 (permissions v2):** nothing new from this spike; the Privacy note's "fds already handed out stay valid until closed" is kernel semantics and stays.
- **Platform client library (ADR-015):** `ruya_rom_materialise_set()` docs and sample: open the path as given, never `realpath` it.
- **Inbox:** ADR-047 (ruya-platform as its own user) is not in image 0.0.109 yet; fd passing does not depend on it.
