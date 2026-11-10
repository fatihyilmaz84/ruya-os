# RuyaOS — Stores

ADR-032 (decision), ADR-005 (Flatpak only), ADR-011 (`ruya-store` drives the `flatpak` CLI). The service as built is described in `03-services-and-apps.md` §4.2-4.4; this file is the target for **more than one store**. Marks: **built** (in the code today), **planned** (a task exists), **later** (an epic line in §10, no task file yet).

## 1. What a store is

A store is a small **store file** that names up to two shelves, both plain static files over HTTPS:

- a **signed Flatpak repository** (`Url`, `GPGKey`): ordinary Flatpaks with the AppStream data and `x-ruya-*` keys the developer guide describes;
- a **signed `.play` index** (§11): a list of `.play` packages (`05-play-packages.md`) the console downloads and imports.

The store file is a standard `.flatpakrepo` keyfile (`Title`, optional `Homepage`, `Comment`, `Icon`, and `Url` + `GPGKey` when it has Flatpaks) with an optional group `[Ruya Store]` (`PlayIndex`, `PlayKey`) when it has `.play` packages. At least one shelf is required. There is no account and no server of ours in the path: anyone who can host static files can run a store. The **store fingerprint** is the SHA-256 over the key material of both shelves; it is what the admin sees, what the blocklist names and what "the same store" means.

| Store | Trust (wire value) | Who adds it | Can be removed |
|---|---|---|---|
| **RuyaOS** (`ruyaos`, our key): our apps, runners, curated entries | `official` | in the image (planned: the remote does not exist yet, T-444) | no; cannot be turned off |
| **Flathub** (`flathub`), filtered to controller-ready apps unless "Show all apps" | `community` | in the image (**built**, T-140) | no; an admin can turn it off |
| **Any other store** | `third-party` (today the code says `developer`; renamed by T-440) | an admin, on the console | yes |

The player sees one Store. Every app carries its store's badge; a third-party app's badge is the store's title and host, in the warning colour.

## 2. Adding a store (planned: T-440 service, T-442 Settings)

Settings > Stores > Add a store, admins only.

1. **Address.** The admin types an address with the on-screen keyboard. Accepted: a full `https://` URL of a store file, or just a host (`games.example.org`), which means `https://<host>/.well-known/ruyaos-store`. Later (§10): a `.flatpakrepo` file picked from a USB drive, and Ruya Web.
2. **Preview** (`PreviewStore`). The service fetches the file and the repository summary and answers with: title, host, key fingerprint, number of apps, and a token. Nothing is changed yet.
3. **Confirm.** A sheet shows the title, the host, the fingerprint, the app count and the fixed text of §8. Confirm asks for the admin PIN, then `AddStore(token)`.
4. The catalogue refreshes; the new store's apps appear with its badge.

Refused, each with its own status and plain message:

| Case | Status |
|---|---|
| Not HTTPS, a redirect to another scheme, more than 3 redirects, a host that is an IP literal, `localhost` or resolves to a private, loopback or link-local address | `invalid-address` |
| The file is over 64 KB, not a store file, names no shelf, a shelf has no key, or a shelf is not signed by its key | `unsigned` |
| A `.flatpakref` (one app, not a store) | `not-a-store` |
| The same URL or a key of a store already added (the built-in ones included) | `already-added` |
| The key or the URL is on the blocklist (§6) | `blocked` |
| 16 third-party stores exist | `too-many` |
| No network, DNS failure, TLS error, timeout (20 s) | `network` |
| The preview token is older than 5 minutes or the file changed since | `expired` |

Rules: the remote's internal name is made by the service (`s-` plus 12 hex characters of the fingerprint), never taken from the file. The title is cleaned (control characters and markup removed, 40 characters at most) and **frozen at add time**; it is always shown together with the host, and it may not contain "RuyaOS", "Ruya", "Official" or "Flathub" (replaced by the host). A store that later changes its `Title` does not change what the console shows.

## 3. What a third-party store may and may not do (planned: T-441)

A store is somebody else's server. These hold for every third-party store, are enforced by `ruya-store` (Flatpak remote priority, a per-remote filter, origin pinning) and are tested against a hostile fixture repository:

1. **It cannot replace anything.** An app or runtime that the official or community store offers, or that is installed from another store, is never installed or updated from a third-party store, whatever version it claims. Installed apps stay pinned to the store they came from.
2. **Reserved names.** It cannot offer ids under `org.ruyaos.`, `org.freedesktop.` or `play.` and no id that the official store offers; such entries are dropped from its catalogue and logged. `play.` is the namespace of imported `.play` packages (05 §7.1): only the console's own importer creates those, so a Flatpak called `play.x` in a store's repository is refused (it would skip the importer's permission vocabulary and art vetting).
3. **Runtimes.** An app from a third-party store takes its runtime from the official or community store. A third-party store may carry only apps and extensions of its own apps. An app whose runtime no trusted store has fails with `missing-runtime`.
4. **Same id in two third-party stores:** both are listed, each under its store; the app page names the store it will install from; the installed one stays with its store.
5. **Sandbox as always.** Its apps run in the Flatpak sandbox as the profile user (invariant). The permission list, the high-risk warning and the "update adds permissions" gate (03 §4.4, built) apply unchanged.
6. **Its metadata is hostile input.** AppStream data is size-capped per store (20 MB unpacked, 5 000 apps; the rest is dropped and the store is marked "partly shown"); texts are length-capped; pictures are fetched only over HTTPS from public addresses, with size and decode limits; nothing from a store is ever executed or interpreted outside the sandbox.
7. **A broken store breaks only itself.** Each store is refreshed on its own; one that is unreachable, slow (20 s) or fails its signature keeps its last good catalogue, shows a state (§5) and never delays the others.

## 4. Who may install (planned: T-443; parental part T-211)

- From the official and community stores: as today (03 §4.4).
- From a third-party store: an **admin** installs directly; a **Standard** profile needs an admin's PIN for every install and for every update that adds a permission. Per store an admin can switch "Everyone can install from this store" on (default off).
- **Child profiles (T-211):** third-party stores are hidden unless the parent allows that store; age ratings in such a store are the store's own claim and "not rated" counts as 18+ (built).
- Guest: never.

## 5. A store's life after it was added

| Situation | What the console does |
|---|---|
| Unreachable | State "Can't reach <host>", the last catalogue stays, installs from it fail with `network`; installed apps keep working. |
| Its signature fails or the key changed | State "Needs attention": nothing is installed or updated from it; installed apps keep working. The new key is never accepted silently: the admin removes the store and adds it again, seeing the new fingerprint. |
| The repository moved (the `.flatpakrepo` at the old address names a new `Url`, same key) | Followed on the next refresh if the new URL passes §2; otherwise "Needs attention". |
| An app disappears from the store | The installed app stays, marked "No longer in <store>: no updates". |
| The admin turns the store off | Its apps leave the catalogue; installed ones stay and get no updates. |
| The admin removes the store | The sheet asks: **Keep its apps** (default; they stay installed, marked "Store removed: no updates") or **Remove its N apps too** (saves are kept, 03 §4.5a). Runtimes nobody uses are cleaned up. A running app of that store is stopped first only in the second case. |
| The same store is added again later | Kept apps are recognised by id and key and get updates again. |
| It lands on the blocklist (§6) | Turned off at once, state "Blocked by RuyaOS", its apps are marked and can still be opened or removed; an admin sees why. |
| Factory reset | All third-party stores and their apps are gone. |
| Updates | Nothing updates by itself today (03 §4.3). When scheduled updates come (§10), third-party stores are excluded unless the admin turns it on per store. |

## 6. The blocklist (planned: T-441)

A file in the image, `/usr/share/ruyaos/store-blocklist` (key fingerprints and URL hosts, one per line, with a reason), updated only with OS updates and therefore signed with them. The service reads it at start and after an OS update. Empty at first. Only the owner adds an entry (malware, a stolen key), each with a reason an admin can read on the console (owner, 2026-11-10).

## 7. Contract (`org.ruyaos.Store1`, draft until the first release; planned: T-440)

- `ListStores() -> aa{sv}` replaces `ListRemotes`: `id`, `title`, `host`, `trust`, `enabled`, `removable`, `fingerprint`, `state` (`ok` | `unreachable` | `needs-attention` | `blocked` | `partly-shown`), `apps` (count), `everyone_may_install`.
- `PreviewStore(address) -> (status, a{sv} store, token)`; `AddStore(token, admin_id, admin_pin) -> (status, id)` replaces `AddRemote`.
- `RemoveStore(id, remove_apps, admin_id, admin_pin) -> status`; `SetStoreEnabled(id, enabled, admin_id, admin_pin)`; `SetStoreEveryoneMayInstall(id, allowed, admin_id, admin_pin)`.
- Signal `StoresChanged`; `CatalogChanged` as today.
- The app record gains `kind` (`flatpak` | `play`), `store` (the store id) and `store_title`; `source` carries the trust value (`third-party` replaces `developer`). `Install` and `GetApp` take the app as `(store, id)` so that the same id in two stores is unambiguous; an empty store means "the best trusted one".
- Admin calls are verified by the service through `Profiles1.VerifyAdmin` (PIN hashes never leave `ruya-profiles`), as `Session1.ClearHistory` does. The bus policy stays shell and root only. Stores are not part of the public developer surface as an API (tier A, shell-private); the **format** a store author follows is public (§9).

## 8. Words the player sees (04 §3 copy rules apply; the confirm text approved by the owner, 2026-11-10)

- Confirm sheet: "<Title> (<host>) is not run or checked by RuyaOS. Its apps can only do what their permissions allow, but nobody has reviewed them. Add this store only if you trust who runs it."
- Badge on cards and the app page: "<Title>" with the host on the app page.
- Install gate for a Standard profile: "Apps from <Title> need an admin."

## 9. For store authors (planned: T-445)

The public format is small: the store file served over HTTPS, optionally at `/.well-known/ruyaos-store` so players type only the host; a signed Flatpak repository (GPG) with AppStream data and the `x-ruya-*` keys; and, once `.play` exists, the index of §11 made by `ruya-pack`. The chapter `docs/developers/your-own-store.md` and a sample script that builds a store from `samples/hello-game` are the reference; the rules of §3 are stated there as "what the console will refuse".

## 10. Later (epic lines; a task file is written when the line is next)

- The official store itself: hosting, key custody, submissions, curated entries for Flathub apps (T-444, waits for the owner).
- Add a store from a `.flatpakrepo` on a USB drive (an explicit action; the file is hostile input); add a store from Ruya Web (T-406 onward; an admin action with the PIN).
- Scheduled app updates and the per-store "update automatically" switch.
- A store's own page (its apps, its description) and a "Stores" filter on the Store page beyond the badge.
- Stores that need a sign-in or sell apps (Flatpak authenticators): not supported; an app that needs one fails with a clear message.
- `ruya store check <address>` in the developer CLI (T-416): runs §2 and §3 against a store before its author publishes the address.
- A sideloaded `.play` (from USB) taking its updates from a store that offers the same id signed by the same developer key ("Get updates from <store>").

## 11. `.play` packages in a store (planned: T-446, after the `.play` epic T-228 is unparked)

**One rule decides the design: a `.play` reaches the console as a `.play`, whatever store it comes from, and the console's own importer turns it into an app** (05 §0 principle 3, §7.3). A store never ships a ready-made `play.<id>` Flatpak. This replaces 05 §11 way 1 ("the Store updates it like any other app, OSTree deltas"): that route would have let a store supply the Flatpak metadata and the art that the importer exists to generate and vet. It also means a `.play` author needs no Flatpak or OSTree tooling to run a store: `ruya-pack` on any OS and a static host.

**The index.** `PlayIndex` is the HTTPS URL of `play-index.json`, with `play-index.json.sig` next to it, signed by `PlayKey` (Ed25519, the same signature encoding T-231 fixes for packages; the store key may be the developer's own key or a different one). `ruya-pack index <folder of packages>` writes both.

```json
{ "format": 1, "expires": "2027-01-31T00:00:00Z",
  "packages": [ { "id": "com.example.starhopper", "build": 143, "version": "1.4.3",
    "url": "https://example.com/files/starhopper-1.4.3.play.zip", "size": 4900000000, "sha256": "...",
    "play_json_sha256": "...", "signer_key_id": "...",
    "name": { "en": "Star Hopper" }, "summary": { "en": "..." }, "genres": ["platformer"],
    "controller": "full", "age_rating": { "scheme": "oars-1.1", "content": { } },
    "permissions": { "network": false, "input": "controllers" },
    "installed_mb": 4800, "icon": "https://example.com/art/icon.webp", "hero": "https://example.com/art/hero.webp" } ] }
```

Rules:
1. **The index is the store's claim; the package is the truth.** The catalogue and the app page are drawn from the index (texts capped and cleaned like 05 §4.1, pictures under the limits of §3.6, permissions in plain words from the same closed vocabulary). After the download the importer inspects the package (05 §7.3 step 2) and compares `id`, `build`, `play_json_sha256`, `signer_key_id` and the permissions with the entry the player confirmed: any difference refuses the install with "This package does not match its store listing", before unpacking.
2. **Signed packages only.** A store cannot carry `unverified` packages (those need developer mode and a USB stick, 05 §7.2). The tier of a package from a third-party store is 05's `developer` tier; `official` still needs RuyaOS's `store.sig`, whichever store hosts the file.
3. **Key continuity holds across stores** (05 §9.2): an installed id accepts updates only from the same developer key. Another store offering the same id with another key cannot update it; with the app not installed, both entries are listed, each under its store (§3.4).
4. **Download:** HTTPS only, public addresses, at most 3 redirects, each re-checked; the size and SHA-256 are the index's and are enforced while streaming; resumable; a job in the one job record (ADR-026, T-388) so it shows on the Downloads page. Peak disk use is the archive plus the unpacked package; the free-space check runs before the download, not after.
5. **Updates** come from the index of the store the package was installed from, on that store's normal refresh: a higher `build` with the same developer key. The manifest's own `update.feed` is ignored for store installs (05 §11), so no developer server is contacted. `expires` works as in 05 §11: a stale index offers nothing new and the store shows "Needs attention" after it has been stale for 30 days.
6. **Who installs** is §4, unchanged: a third-party store's `.play` needs an admin for a Standard profile. (05 §7.2 lets a Standard profile install low and medium packages; for store and USB installs the stricter rule of §4 wins: owner, 2026-11-10, 05 §18 item 4.)
7. **Removal, turning off, blocklist** are §5, unchanged; a removed store's packages stay installed and get no updates. The blocklist of §6 and 05's revocation list are one file with two sections (stores; package keys, ids and hashes).
8. **Who does what:** `ruya-store` owns the stores, fetches and verifies the index, serves one catalogue (`kind`) and queues the job; `ruya-play` downloads nothing on its own for store installs: it is handed the file and the confirmed entry, runs its pipeline, and its Flatpak commit goes into `/var/lib/flatpak` through `ruya-store`'s single transaction queue (two services must not run Flatpak transactions side by side).
9. **Edge cases:** an entry whose `url` 404s or whose hash fails: `network` or `signature` for that package only; an index over 8 MB or 5 000 packages: `partly-shown`; the same `id` twice in one index: the higher `build` only; an index listing a build lower than the installed one: ignored (never a downgrade); a package that needs a newer `format` than the console knows: listed, with "Needs a newer RuyaOS" instead of Install; a store with only a `.play` shelf while the console has no `.play` support yet (before T-446): the store can be added, and shows "Nothing this console can install yet".
