> **Owner input, 2026-11-09.** Requirements for "Ruya Hub", the Guide-button overlay (in the specs: the Guide overlay and the quick menu, T-147), drafted by the owner with ChatGPT without full project context. A requirements list, not a design: where it differs from an *Accepted* ADR (ADR-002 A: the shell is the compositor; ADR-019 freeze; ADR-020; ADR-022 Platform1), the ADR wins until changed. Not to be confused with ADR-020's game data service `ruya-hub` / `Hub1` (naming question for the owner, lead-7). The lead's gap analysis is summarised in `docs/LEAD-NOTES.md`.

# Ruya OS --- Ruya Hub

## Implementation Plan & Technical Specification

**Project:** Ruya OS\
**Component:** Ruya Hub\
**Type:** Native system-level gaming overlay\
**Priority:** Core OS functionality\
**Implementation approach:** Incremental, architecture-first

------------------------------------------------------------------------

# 1. Objective

Implement Ruya Hub, the system-level gaming overlay opened through the
controller's Home/Guide button.

Ruya Hub provides instant access to game management, system settings,
performance information, audio, controllers, notifications and power
management without leaving the running game.

The experience must feel like a native console interface rather than a
desktop application.

The implementation must integrate with the existing Ruya OS architecture
and reuse existing services wherever possible.

Do not create parallel implementations of functionality already provided
by Ruya OS.

# 2. Mandatory architectural constraints

Before implementation, inspect the complete existing codebase and
architecture.

The following constraints are mandatory:

1.  Native UI must use Qt 6 / QML and the existing Ruya design system.
2.  Backend services must use the established Rust architecture.
3.  Inter-process communication must use documented, typed D-Bus
    contracts.
4.  Controller input must integrate with the existing Ruya Input
    service.
5.  Game session management must integrate with `ruya-session-manager`.
6.  Overlay rendering must integrate with the existing
    Gamescope/compositor architecture.
7.  System operations must use existing Ruya OS services.
8.  Apps and UI components must never access privileged system resources
    directly.
9.  Do not introduce direct database access or private filesystem
    conventions into the UI.
10. All service interfaces must have documented contracts, permissions
    and error handling.

Do not implement a Steam replacement.

Do not inject code into games or modify game files to display the
overlay.

Do not assume every controller, GPU or game supports identical
functionality.

# 3. Repository and architecture discovery

This is the first implementation task.

Inspect:

-   Repository structure.
-   Existing application architecture.
-   Qt/QML implementation conventions.
-   Ruya design system and HIG.
-   Rust service architecture.
-   D-Bus interfaces.
-   Ruya Input implementation.
-   Controller mapping and device ownership.
-   Gamescope integration.
-   `ruya-session-manager`.
-   Quick Resume implementation.
-   Audio management.
-   Performance monitoring.
-   Power management.
-   Notification infrastructure.
-   Configuration and settings management.
-   Existing test and documentation conventions.

Identify which existing APIs can be reused.

Produce an architecture assessment containing:

  ----------------------------------------------------------------------------
  Area              Existing          Required integration   Missing
                    implementation                           functionality
  ----------------- ----------------- ---------------------- -----------------
  Controller input  Inspect           Ruya Input             Identify gaps

  Overlay rendering Inspect           Gamescope/compositor   Identify gaps

  Game management   Inspect           Session Manager        Identify gaps

  Performance       Inspect           Hardware services      Identify gaps

  Audio             Inspect           Audio service          Identify gaps

  Power             Inspect           Power service          Identify gaps
  ----------------------------------------------------------------------------

Do not begin implementing the full feature before this assessment is
complete.

If an essential dependency is missing, implement the required
foundational capability in the appropriate existing component before
building the Hub integration.

Do not invent APIs or assume functionality exists merely because it
appears in a previous design document.

# 4. Product requirements

## 4.1 Overlay activation

The primary activation mechanism is the controller Home/Guide button.

Requirements:

-   Global activation regardless of the active game.
-   Support controller-specific button capabilities.
-   Configurable activation shortcuts.
-   Configurable keyboard shortcut.
-   Correct input ownership and routing.
-   No duplicate Home button events reaching the game unintentionally.
-   No interference with ordinary controller input.
-   Support multiple connected controllers.
-   Correct behavior when a controller disconnects.
-   Ability to configure system-button passthrough where supported.

Suggested default behavior:

-   Short Home press: Open Hub.
-   Home press while Hub is open: Close Hub.
-   B/Circle: Back or close.
-   Long Home press: Power menu, configurable.
-   Additional shortcuts: Configurable by the user.

Do not hardcode button identifiers across controller models.

Use semantic Ruya Input actions.

Avoid combinations that conflict with common controller or game
shortcuts.

## 4.2 Overlay behavior

The overlay must:

-   Appear above fullscreen games.
-   Work with Vulkan, OpenGL and Proton/DXVK games.
-   Support controller navigation.
-   Support keyboard and mouse navigation.
-   Preserve the underlying game session.
-   Avoid forcing a game pause when opened.
-   Correctly manage focus and input routing.
-   Adapt to display resolution and refresh-rate changes.
-   Handle display mode transitions.
-   Recover from compositor or UI process failures without terminating
    the game.

The default behavior is that games continue running while the Hub is
open.

Game suspension must only happen through an explicit user action.

## 4.3 Main Hub interface

Implement a compact control-center interface.

The initial view should provide:

-   System status.
-   Current time.
-   Network status.
-   Battery status where applicable.
-   Currently running game.
-   Recent games or game switching shortcut.
-   Quick Settings.
-   Performance shortcut.
-   Audio shortcut.
-   Controller shortcut.
-   Notifications.
-   Power menu.

Avoid excessive information on the initial screen.

The interface must remain readable on televisions and low-resolution
displays.

Use controller focus indicators, generous interaction targets and
predictable navigation.

# 5. Expanded panels

Implement the following panels.

## 5.1 Games

Display:

-   Currently running game.
-   Running game sessions.
-   Recently played games.
-   Game session state.
-   Available Quick Resume sessions.
-   Game switching actions.
-   Return to Ruya home.
-   Close game.

Use `ruya-session-manager` as the source of truth for session state.

Distinguish between:

-   Running.
-   Suspended.
-   Hibernated.
-   Restorable.
-   Unavailable.
-   Terminated.

Only show actions that are valid for the current session state.

Do not implement a second session manager.

## 5.2 Quick Settings

Implement:

-   Master volume.
-   Brightness where supported.
-   Audio output selection.
-   Microphone mute where supported.
-   Wi-Fi status and basic controls.
-   Bluetooth status and basic controls.
-   Display information.
-   Resolution and refresh-rate selection where supported.
-   HDR status and controls where supported.

Frequently used controls should be directly accessible without entering
another screen.

Use existing Ruya services.

Unsupported functionality must be represented explicitly.

Do not display fake or nonfunctional controls.

## 5.3 Performance

Implement a performance information panel.

Initial metrics:

-   FPS when available.
-   Frame time when available.
-   CPU utilization.
-   GPU utilization.
-   CPU temperature.
-   GPU temperature.
-   RAM usage.
-   VRAM usage.
-   Power consumption where available.

Use capability-based reporting.

The UI must distinguish:

-   Supported.
-   Unsupported.
-   Unavailable.
-   Temporarily unavailable.

Do not invent values or substitute misleading estimates.

Performance monitoring must have configurable update intervals and avoid
unnecessary resource consumption.

Advanced controls such as fan curves, overclocking, frame generation,
upscaling and FPS limiting are outside the initial implementation scope.

## 5.4 Audio

Implement:

-   Master volume.
-   Mute.
-   Audio output selection.
-   Microphone mute where supported.
-   Current audio device.
-   Basic media playback controls when an application exposes media
    information through the Ruya application integration APIs.

Do not create a separate media management system.

## 5.5 Controllers

Implement:

-   Connected controller list.
-   Controller identification.
-   Battery level where supported.
-   Connection type.
-   Controller configuration shortcut.
-   Button mapping shortcut.
-   Controller profile selection where available.

Use the existing Ruya Input architecture.

Do not duplicate controller mapping or virtual-device functionality.

## 5.6 Notifications

Integrate with the existing Ruya notification infrastructure.

Support:

-   System notifications.
-   Download completion.
-   Installation completion.
-   Controller battery warnings.
-   System update notifications.
-   Important system errors.

Notifications must not unnecessarily interrupt gameplay.

Support Do Not Disturb.

## 5.7 Power

Implement:

-   Sleep.
-   Restart.
-   Shutdown.
-   Return to Ruya home.

All actions must go through the existing Ruya Power Service.

Require appropriate confirmation for destructive or potentially
disruptive actions.

Do not directly execute privileged shell commands from QML.

# 6. Technical architecture

The implementation should maintain the following separation.

## Ruya Hub UI

Responsibilities:

-   Presentation.
-   Controller-first navigation.
-   User interaction.
-   Panel state.
-   Loading and error states.
-   Accessibility.
-   Display adaptation.

Technology: Qt 6 / QML.

## Ruya Hub Service

Responsibilities:

-   Coordinate Hub operations.
-   Maintain overlay state.
-   Consume existing service APIs.
-   Expose typed UI-facing contracts.
-   Manage permissions.
-   Handle service availability and errors.

Technology: Rust.

## Ruya Input

Responsibilities:

-   Global shortcut detection.
-   Home/Guide button handling.
-   Input ownership.
-   Input routing.
-   Controller capability detection.

Ruya Hub must not independently monitor raw controller devices.

## Compositor Integration

Responsibilities:

-   Display the Hub above games.
-   Manage overlay visibility.
-   Manage focus.
-   Handle input routing.
-   Handle display transitions.
-   Restore correct game focus when closed.

Investigate the existing Gamescope architecture and implement the
appropriate integration.

Use a compositor adapter boundary to avoid unnecessary UI coupling to
compositor-specific details.

Do not assume a regular Wayland layer-shell window will always appear
above Gamescope-managed fullscreen content.

## Existing Ruya Services

Reuse:

-   Game/session manager.
-   Performance manager.
-   Audio manager.
-   Controller/input manager.
-   Notification service.
-   Power manager.
-   Settings service.

The Hub must remain a consumer of these services rather than becoming
the owner of their responsibilities.

# 7. UI and design requirements

Follow the existing Ruya design system and native application HIG.

Design principles:

-   Console-first.
-   Minimal.
-   Elegant.
-   Controller-first.
-   Consistent spacing and typography.
-   Clear focus states.
-   Smooth but restrained transitions.
-   Dark gaming environment optimized.
-   Orange Ruya accent color.
-   Readable at television viewing distances.

Use existing design tokens and components.

Do not introduce a separate visual design system.

The UI should have three interaction levels:

1.  Quick Hub: compact initial control center.
2.  Expanded panels: detailed controls and information.
3.  Full Ruya interface: complete application experiences.

The Hub should not evolve into a second desktop environment.

# 8. Performance requirements

The overlay is a system-critical gaming component.

Requirements:

-   Fast activation.
-   Minimal idle CPU usage.
-   Minimal memory consumption.
-   No continuous unnecessary rendering when hidden.
-   No unnecessary high-frequency D-Bus polling.
-   Efficient state updates.
-   No blocking UI operations.
-   Asynchronous service calls.
-   Graceful degradation when services are unavailable.
-   No unnecessary GPU resource consumption.

Establish measurable performance baselines during implementation.

Measure activation latency, UI responsiveness, idle CPU usage, memory
usage and game performance impact.

Do not claim performance targets are met without measurements.

# 9. Security and reliability

-   Do not expose privileged operations directly to QML.
-   Validate all incoming service requests.
-   Use explicit D-Bus permissions.
-   Handle service crashes and reconnections.
-   Avoid stale game-session information.
-   Do not trust application-provided game metadata for privileged
    operations.
-   Ensure that the overlay cannot be impersonated by ordinary
    applications.
-   Avoid game injection and game-file modifications.
-   Handle malformed device events safely.

The game must remain running if the Hub UI crashes.

# 10. Explicitly excluded from V1

Do not implement:

-   Friends/social network.
-   Achievements.
-   Background video recording.
-   Screenshot gallery.
-   Game-specific widgets.
-   Advanced GPU tuning.
-   Fan curves.
-   Overclocking.
-   Game notes.
-   Cloud synchronization.
-   A replacement for Steam Input.
-   A replacement for the Ruya game/session manager.

Create appropriate architectural extension points where useful, but do
not build speculative infrastructure.

# 11. Implementation phases

## Phase 0 --- Architecture assessment

Deliver:

-   Repository assessment.
-   Existing API inventory.
-   Dependency map.
-   Missing functionality report.
-   Rendering integration investigation.
-   Input ownership investigation.
-   Implementation proposal.

Acceptance criteria:

-   No duplicate services proposed.
-   No undocumented dependencies.
-   Rendering and input integration approach validated against the
    actual repository.
-   Dependencies and implementation order documented.

## Phase 1 --- Foundation

Implement:

-   Ruya Hub service.
-   UI application structure.
-   Typed D-Bus contracts.
-   Service integration layer.
-   Configuration integration.
-   Compositor adapter interface.
-   Input activation integration.

Acceptance criteria:

-   Hub can be opened and closed using the configured Home action.
-   Existing game remains running.
-   Input routing works correctly.
-   UI survives unavailable backend services.
-   No duplicate input processing.

## Phase 2 --- Core interface

Implement:

-   Main Hub.
-   Controller navigation.
-   Keyboard navigation.
-   Focus management.
-   System status.
-   Expanded panel framework.
-   Display adaptation.

Acceptance criteria:

-   Entire Hub can be navigated using a controller.
-   Correct focus restoration when closed.
-   Consistent Ruya visual design.
-   Functional behavior at supported TV resolutions.

## Phase 3 --- Essential functionality

Implement:

-   Games panel.
-   Quick Settings.
-   Audio panel.
-   Controller panel.
-   Power menu.
-   Notification integration.

Acceptance criteria:

-   All actions use existing service APIs.
-   Session states are correctly represented.
-   Unsupported features are handled explicitly.
-   Power operations are protected appropriately.

## Phase 4 --- Performance panel

Implement:

-   Performance metrics.
-   Hardware capability detection.
-   Efficient telemetry updates.
-   Monitoring configuration.

Acceptance criteria:

-   Correct metrics on supported hardware.
-   Correct unavailable/unsupported states.
-   No misleading values.
-   Measured performance overhead.

## Phase 5 --- Integration and hardening

Test with:

-   AMD GPU.
-   NVIDIA GPU.
-   Intel GPU.
-   Vulkan games.
-   OpenGL games.
-   Proton/DXVK games.
-   Steam.
-   Heroic.
-   Emulators.
-   Native Ruya applications.
-   Xbox controllers.
-   PlayStation controllers.
-   Generic controllers.
-   Multiple connected controllers.
-   Keyboard and mouse.

Also test:

-   Controller disconnection while Hub is open.
-   Game crash while Hub is open.
-   Hub crash while game is running.
-   Backend service restart.
-   Display resolution changes.
-   Refresh-rate changes.
-   Sleep and wake.
-   Input ownership conflicts with Steam.

Document actual compatibility results. Do not claim universal support
based on a limited test matrix.

# 12. Documentation requirements

Update the existing Ruya documentation.

Create or update:

-   Ruya Hub architecture documentation.
-   Ruya Hub API reference.
-   D-Bus contract documentation.
-   Controller shortcut documentation.
-   Compositor integration documentation.
-   UI component documentation.
-   Developer integration guide.
-   Testing and troubleshooting guide.

Include:

-   Architecture diagrams.
-   Service responsibilities.
-   API examples.
-   Error handling.
-   Permission requirements.
-   Supported capabilities.
-   Versioning and compatibility rules.

Documentation must reflect the implemented system, not merely the
intended design.

# 13. Testing requirements

Implement automated tests for:

-   Hub state management.
-   Shortcut recognition.
-   Input ownership.
-   Session state presentation.
-   Service communication.
-   Permission handling.
-   Capability detection.
-   UI navigation.
-   Focus restoration.
-   Service reconnection.
-   Error handling.

Add integration tests for compositor and game-session interactions.

Use hardware-independent mocks for unit tests and real hardware testing
where required.

No phase is complete merely because the code compiles.

# 14. Development rules for Claude

These rules are mandatory throughout the project.

1.  Inspect existing architecture before modifying it.
2.  Reuse existing services and APIs.
3.  Follow established coding conventions.
4.  Do not introduce unnecessary dependencies.
5.  Do not create duplicate functionality.
6.  Do not leave TODOs, placeholders or fake implementations.
7.  Do not silently ignore errors.
8.  Do not hide unsupported functionality.
9.  Keep changes focused and reviewable.
10. Add tests alongside implementation.
11. Update documentation alongside implementation.
12. Preserve backward compatibility unless an explicit migration is
    designed.
13. Do not rewrite unrelated parts of Ruya OS.
14. Do not declare a feature complete without verification.

For every phase, report:

-   What was inspected.
-   What was implemented.
-   Which existing services were reused.
-   Files created or modified.
-   API changes.
-   Tests executed and their results.
-   Remaining blockers.
-   Documentation updated.

If an architectural decision conflicts with the existing implementation,
stop and document the conflict before introducing a workaround.

# 15. Definition of Done

Ruya Hub V1 is complete when:

-   Home/Guide button activation works reliably.
-   The overlay appears above supported fullscreen games.
-   Games remain running when the Hub opens.
-   Controller and keyboard navigation work.
-   Input routing does not interfere with games or Steam.
-   Game management integrates with Ruya Session Manager.
-   Essential settings work through existing services.
-   Performance information is accurate where supported.
-   Power management works through the Power Service.
-   UI and backend failures do not terminate the running game.
-   Automated tests pass.
-   Integration tests have documented results.
-   Documentation is complete.

**Final instruction:** Build Ruya Hub as an integrated part of Ruya OS.
Do not build an isolated overlay application that happens to run on
Linux. The result must be a maintainable, documented, extensible system
component that future Ruya applications and AI coding agents can
integrate with through stable public APIs.
