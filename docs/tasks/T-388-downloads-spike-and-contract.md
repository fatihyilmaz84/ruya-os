# T-388 - Downloads: spike (bytes, rate, pause) and the job record v2 in Store1 and Update1

Status: todo · Phase: 3 · Depends: — · Area: api, services (ruya-store, ruya-update), docs · Size: M · Owner: lead · Complexity: complex · Developer surface: internal

## Goal
The facts and the contract drafts for ADR-026: where bytes, rate and ETA come from for a Flatpak transaction and for a bootc image pull, what Pause and Cancel really do, and the XML both services and the shell will build on.

## Read first
- `docs/specs/00-overview.md` ADR-026, ADR-022 (never-public list); `api/dbus/org.ruyaos.Store1.xml` (one queue, `ListJobs`, `JobProgress`), `org.ruyaos.Update1.xml` (`Download`, `progress`)
- `services/ruya-store` (drives the `flatpak` CLI, `--system --noninteractive`), `services/ruya-update` (bootc); `docs/specs/03-services-and-apps.md` §4 (Store, Update)

## Scope
1. **Flatpak bytes and rate:** what the CLI prints in non-interactive mode (sizes, rate) versus libflatpak's transaction progress (`bytes_transferred`, `get_start_time`); recommend parsing or a small libflatpak helper; measure on the Dell with a real install (STK-sized).
2. **bootc bytes:** `bootc upgrade/switch --progress-fd` (JSON events with bytes) or the OCI pull's own progress; Pause and Cancel of a pull and whether a resumed pull keeps fetched layers.
3. **Pause semantics:** for each source, does Cancel-then-Install resume from fetched objects (OSTree), and how long the partial objects live (prune); what `unsupported` must mean.
4. **Bandwidth limit:** is there a real mechanism (OSTree/curl options, a cgroup or `tc` route) worth offering; if not, ADR-026 says it is not offered.
5. **Contract drafts:** the v2 job record, actions and `GetDownloadStats` in both XMLs (marked draft), with status strings; rewrite T-389..T-392 with the facts.

## Acceptance criteria
- [ ] A spike report in this Outcome, one section per item, with commands and numbers from the Dell.
- [ ] Draft XML in `api/dbus/` for both services (no implementation), ADR-026 updated, T-389..T-392 rewritten.
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
