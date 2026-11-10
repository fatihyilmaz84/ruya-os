# T-440 - Stores in `Store1`: preview, add, remove, turn off, states (contract, service, mock, client)

Status: todo · Phase: 3 · Depends: — · Area: api, services, shell (client and mock only) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

## Goal
An admin can add a third-party store by its address, see what it is before it is added, turn it off and remove it, all through `Store1`; the shell's client and mock follow. No screen yet (T-442). ADR-032, `docs/specs/10-stores.md` §2, §5, §7.

## Read first
- `docs/specs/10-stores.md` (all; it is short), ADR-032 in `00-overview.md`
- `docs/specs/03-services-and-apps.md` §4.2, and in §4.3 only the paragraph "As built (T-134 ...)" up to "Job table"
- `api/dbus/org.ruyaos.Store1.xml`; `services/ruya-store/src/` (`flatpak.rs` trait and fake, `flatpak_cli.rs`, `service.rs`, `dbus.rs`); `services/CLAUDE.md`
- `shell/src/store/` (backend, mock, `RequestSequence`), `shell/PATTERNS.md` (backends)
- `api/dbus/org.ruyaos.Session1.xml` `ClearHistory` and its service code: the pattern for `admin_id, admin_pin` checked through `Profiles1.VerifyAdmin`

## Scope
1. **XML first** (`10-stores.md` §7): `ListStores`, `PreviewStore`, `AddStore`, `RemoveStore`, `SetStoreEnabled`, signal `StoresChanged`; `ListRemotes` and `AddRemote` are removed (nothing calls them); the app record gains `store` and `store_title`; `source` value `developer` becomes `third-party`; the statuses of §2's table. `Install`/`GetApp` keep their signatures in this task (the `(store, id)` form is T-441's, with the collision rules).
2. **Preview** in the pure core behind two traits with fakes: a `Fetcher` (HTTPS GET with redirect and size limits, 20 s) and a resolver. Every row of §2's refusal table is a unit test. The address rules: `https` only, host form expands to the well-known path, no IP literals, no private, loopback or link-local result (checked on the resolved address the connection uses, not on a second lookup), at most 3 redirects, each re-checked.
3. **Add:** the token names a preview kept in memory for 5 minutes (at most 8 pending; the file's bytes are kept and used, not fetched again). The remote name is `s-<12 hex of the fingerprint>`; the title is cleaned and frozen (§2 rules); the key is imported from the previewed bytes; never `--no-gpg-verify`; a remote that ends up unsigned is removed (the existing rule). Limit 16.
4. **Store records and states** (§5): a small state file in the unit's `StateDirectory` (frozen title, host, fingerprint, enabled, added time), read as untrusted input like `jobs`. Per-store refresh: a store that fails keeps its last catalogue and gets `unreachable` or `needs-attention`; the other stores are not delayed (test with a fake that hangs one store).
5. **Remove:** `remove_apps=false` keeps the apps (they are listed with `store` set and a flag `orphaned`); `true` queues their removal as normal jobs (data kept), then deletes the remote. Built-in stores answer `forbidden`; Flathub can only be turned off.
6. **Admin check:** `AddStore`, `RemoveStore`, `SetStoreEnabled` call `Profiles1.VerifyAdmin(admin_id, admin_pin)`; answers `wrong-pin`, `locked-out`, `forbidden` pass through. Root may pass an empty admin (the VM check).
7. Mock and D-Bus client in `shell/src/store`: the same methods, statuses and states; mock controls `mockAddStorePreview(record)`, `mockStoreState(id, state)`. No QML screen.

## Out of scope
- The Settings pane (T-442), badges and the install gate (T-443).
- Replacement, reserved-name and runtime rules, `(store, id)` installs, the blocklist, catalogue caps (T-441): until T-441 is merged the pane task must not ship in an image; say so in the HANDOFF.
- USB and Ruya Web as ways to add a store; `SetStoreEveryoneMayInstall` (T-443).

## Acceptance criteria
- [ ] Each refusal of `10-stores.md` §2 has a Rust test named after its status; the private-address test resolves a public name to `10.0.0.5` and to `::1` and is refused both ways; a redirect to `http://` is refused (tests: `stores::preview::*`).
- [ ] Add, list, turn off, remove (both forms) against the fake Flatpak: the records, `StoresChanged` and `CatalogChanged` come as §5 and §7 say; a changed title at the source does not change the stored one (tests named in the Outcome).
- [ ] A hanging or failing store does not delay or empty another store's catalogue (test with a fake clock or a blocked fake).
- [ ] Trust boundary: the state file and the fetched `.flatpakrepo` are parsed as hostile input (oversized, binary, missing keys, a `Title` with control characters and with "Official"): tests named. Nothing fetched reaches a command line unvalidated.
- [ ] Contracts agree: XML, service, mock, client (`tst_store_stores.qml` drives the mock through preview, add, state change, remove; a D-Bus client test or the existing probe pattern for the real path).
- [ ] VM (lead run): `scripts/vm-store-check.sh stores` builds a small signed repository inside the VM (or uses one copied in; never SKIP for a missing tool), serves it over HTTPS on the VM itself, previews, adds, lists, installs one app from it, turns it off, removes it keeping the app, removes the app; and shows that an unsigned copy and a `.flatpakref` are refused. The private-address rule is lifted for this check only by `RUYA_STORE_TEST_PRIVATE_OK=1` in a unit drop-in the check writes and removes (Inbox line for T-425: a release image ignores it).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; revert checks named in the Outcome.

## Verification
```powershell
.\scripts\dev.ps1 rust
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/10-stores.md` (built marks, any deviation), `03` §4.2/§4.3 (the as-built paragraph), `docs/developers/publishing.md` ("developer remote" wording and its Sources footer), `docs/dev-setup.md` (the new check mode).

## Hints
- `ruya-store` already validates every id, remote name and URL before the command line and already has the unit's network access; no new capability should be needed. If the unit or the bus policy must change, stop and tell the lead (that makes it "VM (this task)").
- Flatpak: `flatpak remote-add --system --from <file>`, `remote-modify --disable/--enable`, `remote-delete`; `remote-delete` refuses while refs are installed unless forced: keeping apps means the refs stay with a remote that no longer exists (check what `flatpak list` and `update` do then, and describe it in the Outcome).

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: vm-store-check.sh stores)`._
