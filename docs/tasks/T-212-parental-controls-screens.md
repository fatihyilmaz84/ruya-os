# T-212 — Parental controls, screens: Settings -> Parental, "Ask a parent", "Time is up"

Status: todo · Phase: 3 · Depends: T-211 · Area: shell · Size: M · Owner: builder

## Goal
Parents set the rules in Settings -> Parental; children see friendly screens when something is not allowed or time runs out, and a parent can approve with the admin PIN from the sofa. Owner request, 2026-11-06. The services and contract are T-211.

## Read first
- T-211 and its Outcome (the contract: `Profiles1.GetPolicy/SetPolicy/ApproveAction`, `Session1` statuses `age-restricted`, `time-limit`, `bedtime`, `PlaytimeWarning`, `PlaytimeEnded`, `GetUsage`, `ExtendTime`, `Store1` status `needs-admin`)
- `docs/specs/02-shell.md` (Settings, the Guide overlay, modals, PIN pad), `04-design-system.md` §4-§8 (components, copy rules §6: plain, kind words), `shell/PATTERNS.md`, `shell/CLAUDE.md` (late-reply guards, test member lint), the PIN pad (`PinPad.qml`) and admin flows in `ProfileManageFlow.qml`, the Store page and app page, the `Profiles`/`Session`/`Store` facades with their mocks

## Scope
1. **Settings -> Parental** (visible to admins only; hidden for others): a list of Standard profiles (avatar, name); per profile a page with: Age limit (Off / Everyone / 7+ / 12+ / 16+), "Ask a parent to install apps" toggle, Daily play time (Weekdays and Weekends: Off / 30 min / 1 h / 2 h / 3 h / custom stepper), Bedtime (Off or from/to by hour/half-hour steppers), "Allowed apps / Blocked apps" (pick from the installed list, with the rating shown), and "Playtime this week" (a bar per day and the top apps from `GetUsage`). A separate "Guest" page with the age limit and bedtime. Changes use the admin PIN once per visit (like the other admin pages) and apply at once; copy plain and kind (`04` §6); Turkish.
2. **Child-facing screens:** (a) launching a restricted app: a modal "This game is for ages 12 and up" / "Play time is used up for today" / "It is bedtime" with "Ask a parent" and "OK"; (b) the Store and app pages mark apps above the limit ("Not for your age": the Install button turns into "Ask a parent" or is replaced, per T-211 rules) and `Search` results keep them listed but marked; (c) the **warnings** at 15, 5 and 1 minutes as a toast, and the **"Time is up"** full-screen scene (calm, uses the screen-saver look if T-202 exists, else the plain modal layer) when `PlaytimeEnded` arrives: apps are already stopped, the profile is locked, "Ask a parent" is the only action besides switching profile; (d) **Ask a parent**: the admin PIN pad (the existing `PinPad`), then the parent chooses "Allow this once" / "+15 / +30 / +60 min today" / "Allow this app for <name>" as fits the situation; failures use the usual wrong-PIN/lockout feedback.
3. **Facades and mocks:** `Profiles.policyOf(id)`, `Session.usage(profile, days)`, new statuses mapped to the screens, the late-reply guards on every new list/refresh, the mock with scripted situations (limit hit, minutes running out, bedtime), so tests and screenshots do not need services.
4. **Accessibility:** every new control has a name and role; the warnings are announced; the "Time is up" scene never traps the controller (switch profile and Guide always work).

## Out of scope
- Anything in T-211's out-of-scope list, parent notifications outside the console, a PIN recovery flow, custom per-app time limits.

## Acceptance criteria
- [ ] `tst_parental.qml` (mock): the Parental section is hidden for a non-admin and shown for an admin; each setting writes the policy through `SetPolicy` and updates in place with focus kept; the child-facing modals show the right text for each refusal status; "Ask a parent" runs the PIN flow (right PIN approves once, wrong PIN counts toward the lockout and is reported); the warnings toast at 15/5/1; `PlaytimeEnded` shows the scene and locks the profile; extending time dismisses it; the Store marks apps above the limit and swaps the install action; everything reachable and operable with the controller keys only, focus asserted after each step.
- [ ] Screenshots: Settings -> Parental (list, profile page, usage week), the three refusal modals, a warning toast, "Time is up", the Store with a marked app; English and Turkish; read against `04` §8 and §6 (tone).
- [ ] VM (lead run): the real-bus path through the shell's own `Session`/`Profiles` clients (a probe like `vm-session-probe.qml`) for one refusal and one extension; `Verified: host (vm pending: ...)`.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `02-shell.md` (Settings -> Parental and the child-facing screens), `03` §1.3 pointer, `04` §8 if a component is added, `docs/dev-setup.md`.

## Hints
- Reuse `ProfileManageFlow`'s admin-PIN pattern and `PinPad`; the "Time is up" scene is a modal on the existing top layer (L3, `04` §3.5), not a page.
- Texts a child reads: short, no blame ("Time's up for today. Ask a parent if you need more.").

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
