# T-443 - In the Store: a third-party app shows its store, a Standard profile needs an admin, removed and blocked stores are said plainly

Status: todo · Phase: 3 · Depends: T-441, T-442 · Area: shell, api, services (one setting) · Size: M · Owner: builder · Complexity: normal · Developer surface: none

## Goal
A player always knows which store an app comes from and what that means, a Standard profile cannot install from a third-party store without an admin unless that store was opened to everyone, and apps whose store is gone, off or blocked say so. `docs/specs/10-stores.md` §1, §4, §5, §8.

## Read first
- `docs/specs/10-stores.md` §1, §4, §5, §8; `03` §4.4 "As built (T-111 ...)" (the existing PIN gate on the app page)
- `shell/qml/AppDetailPage.qml`, `StorePage.qml`, the card component's badge; `04-design-system.md` (badges, warning colour, copy); new tokens or components allowed: none
- `shell/src/store/` after T-441 (`store`, `store_title`, `(store, id)`)

## Scope
1. **Badge:** cards and the app page show the trust badge; for `third-party` it is the store's title (warning colour), and the app page adds the host and one line "Not checked by RuyaOS". The official and community badges stay as they are.
2. **The same id in two stores** (T-441): the app page says which store this entry installs from; no merged entry.
3. **Install gate:** for a Standard profile, Install from a third-party store, and Update when it adds any permission, ask for an admin's PIN (the existing `PinPad` collect flow and wrong-PIN behaviour); the line under the button says "Apps from <Title> need an admin". Guest never installs.
4. **"Everyone can install from this store":** `SetStoreEveryoneMayInstall` in the contract, the service's state file, mock and client, and a switch on the store's row in T-442's pane (admin, PIN). When on, the gate of scope 3 falls back to the normal rules of `03` §4.4.
5. **States on installed apps:** "Store removed: no updates", "No longer in <store>: no updates", "<store> is turned off", "Blocked by RuyaOS" on the app page and as a small mark in Library details; Open and Uninstall keep working; Update is hidden.
6. The Store page's "Show all apps" filter applies to every store alike.

## Out of scope
- A page per store and a store filter (later, `10-stores.md` §10). Child profiles (T-211 reads the same field).
- Scheduled updates.

## Acceptance criteria
- [ ] `tst_app_detail_stores.qml` (mock): badge text and colour token per trust; the gate for Standard, admin and Guest, with the switch on and off; an update adding a harmless permission still asks a Standard profile; wrong PIN stays inline; each state of scope 5 shows its sentence and hides Update; focus asserted after the PIN pad closes.
- [ ] The service refuses, not only the shell: `Install` of a third-party app for a Standard active profile without a verified admin answers `forbidden` unless the store is open to everyone (Rust test; the contract gains the admin arguments if needed, XML first).
- [ ] Screenshots reviewed (04 §8): a third-party card in a row of normal cards, the app page with a long store title, the gated Install, an app whose store was removed.
- [ ] UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; the Outcome has a `UX notes:` line.
- [ ] VM (lead run): `scripts/vm-store-check.sh stores` gains: as a Standard active profile, `Install` from the fixture store is `forbidden`, and `ok` after the switch.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; translations complete.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/10-stores.md` (built marks), `03` §4.4, `02-shell.md` (Store row of the page table).

## Hints
- Today the high-risk gate is checked by the shell through `Profiles1`; this task moves the third-party gate into the service because a store is a trust boundary. Do not move the old gate in the same task (an Inbox line).

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: vm-store-check.sh stores)`._
