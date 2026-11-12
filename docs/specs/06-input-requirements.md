> **Appendix of [`06-input.md`](06-input.md)** (the design, T-366 / RUY-2, 2026-11-12). **Owner input, 2026-11-09.** Requirements for the input subsystem, drafted by the owner with ChatGPT and handed to the lead as the target. It is a requirements list, not a design: where it differs from an *Accepted* ADR, the ADR wins until changed. How RuyaOS meets each part, in which order, is [ADR-024](00-overview.md) and the tasks T-366..T-374; the design is written in `06-input.md` (T-366). Section 19 ("Instructions to Claude") is covered by the root `CLAUDE.md`.

# Ruya Input
## Technical Architecture & Implementation Specification

**Project:** Ruya OS  
**Subsystem:** Ruya Input  
**Document type:** Engineering specification  
**Status:** Proposed architecture – implementation target  
**Priority:** Core OS subsystem

---

# 1. Objective

Implement Ruya Input, a native controller and input management framework for Ruya OS.

Ruya Input provides a unified input layer for:

- Native Ruya applications.
- Steam and Steam games.
- Heroic Launcher and other Wine/Proton applications.
- RPCS3 and other console emulators.
- Retro gaming applications.
- Applications requiring keyboard and mouse input.
- The Ruya system interface itself.

The system must work independently of Steam, Proton, Heroic and any individual emulator.

Ruya Input must support a broad range of physical controllers, provide advanced remapping capabilities and expose a consistent API to native Ruya applications.

The objective is to provide an experience comparable to or better than Steam Input while establishing Ruya-owned APIs and infrastructure.

## 1.1 Core principles

1. OS-native: Ruya owns the input configuration and management experience.
2. Application-independent: No dependency on Steam or another launcher.
3. Hardware-independent: Support different manufacturers and controller types.
4. Capability-driven: Expose available hardware capabilities dynamically.
5. Controller-first: The entire Ruya interface must be navigable using a controller.
6. Backward-compatible: Support games that only understand conventional gamepads, keyboard or mouse.
7. Extensible: New controllers, output formats and input capabilities must be addable without redesigning the architecture.
8. AI-first: All APIs, schemas and documentation must be structured for AI-assisted software development.
9. Safe: Never silently create duplicate or conflicting input devices.
10. Recoverable: Input failures must never leave users unable to navigate Ruya.

# 2. Architecture

Implement Ruya Input as a collection of clearly separated components.

## 2.1 High-level architecture

Physical devices
- USB controllers
- Bluetooth controllers
- Wireless receivers
- Generic HID devices

↓

Device discovery and capability detection

↓

Input normalization engine

↓

Input processing and mapping engine
- Button mapping
- Axis mapping
- Dead zones
- Sensitivity curves
- Gyroscope processing
- Touchpad processing
- Action layers
- Chords and macros

↓

Routing and ownership manager

↓

Output adapters
- Native Ruya Input API
- Virtual Xbox-compatible gamepad
- Virtual PlayStation-compatible gamepad where feasible
- Virtual keyboard
- Virtual mouse
- Other supported virtual devices

↓

Consumers
- Ruya Shell
- Native Ruya applications
- Steam
- Heroic
- Proton/Wine games
- RPCS3
- Emulators

## 2.2 Recommended implementation components

Use the following technologies where compatible with the existing Ruya architecture.

| Component | Technology |
|---|---|
| Physical input | Linux evdev |
| Device identification | udev, sysfs and HID metadata |
| Gamepad normalization | SDL3 mappings and Linux gamepad conventions |
| Virtual input | Linux uinput |
| Virtual device helper | libevdev |
| Advanced HID support | hidraw where necessary |
| Native service API | D-Bus |
| Application SDK | Ruya SDK |
| Configuration storage | Ruya configuration and database infrastructure |
| User interface | Existing Ruya UI framework |

Do not introduce a second configuration framework or duplicate existing Ruya SDK infrastructure.

Before implementation, inspect the existing codebase and reuse established service, IPC, logging, configuration and packaging conventions.

## 2.3 Service architecture

Use two logical service responsibilities.

### Ruya Input Service

Runs within the active user session.

Responsibilities:

- Discover and track available input devices.
- Normalize input events.
- Manage active profiles.
- Execute mapping rules.
- Manage action layers.
- Route input to consumers.
- Manage virtual device lifecycle.
- Publish device and profile events.
- Expose the public D-Bus API.

### Ruya Device Access

Provide the minimum required system-level permissions for accessing physical and virtual input devices.

Responsibilities:

- Device permissions.
- Secure device access.
- Virtual device creation permissions.
- Device lifecycle coordination.

Do not run the entire input processing engine as root.

Use existing system device access mechanisms where possible. Do not introduce unnecessary privileged processes.

# 3. Device management

## 3.1 Supported controller families

Initial target support:

### PlayStation
- DualShock 4
- DualSense
- DualSense Edge

### Xbox
- Xbox 360
- Xbox One
- Xbox Series X/S
- Xbox Elite controllers

### Nintendo
- Switch Pro Controller
- Joy-Con
- Joy-Con pairs

### Third-party
- 8BitDo
- Logitech
- Generic USB HID gamepads
- Generic Bluetooth gamepads

The architecture must not hardcode this list as its complete supported-device catalogue.

Unknown HID controllers must be discoverable and should be usable through generic input mapping where possible.

## 3.2 Device identification

Each controller must have a stable internal device identifier.

Identify devices using available information:

- USB vendor ID.
- USB product ID.
- Bluetooth identifiers.
- HID identifiers.
- Manufacturer.
- Product name.
- Connection type.
- Serial number when available and appropriate.
- Physical device characteristics.

Do not use Linux event node names such as event5 as persistent identifiers.

Device identifiers must remain stable across reconnects where sufficient identifying information exists.

Handle identical controllers without serial numbers using a deterministic fallback identity and connection-instance identifier.

## 3.3 Capability detection

Each device must expose a capability descriptor.

Example:

{
  "device_id": "controller-dualsense-001",
  "manufacturer": "Sony",
  "model": "DualSense",
  "connection": "bluetooth",
  "capabilities": {
    "buttons": true,
    "analog_sticks": true,
    "analog_triggers": true,
    "gyro": true,
    "accelerometer": true,
    "touchpad": true,
    "rumble": true,
    "adaptive_triggers": true,
    "speaker": true,
    "microphone": true
  }
}

This is an illustrative schema. Only report capabilities that have actually been detected and can be accessed through the relevant driver or protocol.

Capabilities must be individually represented. For example, rumble support must not imply adaptive trigger support.

The system must distinguish between:

- Hardware capability.
- Driver support.
- Currently available capability.
- Capability supported by the selected output adapter.

## 3.4 Connection lifecycle

Handle:

- Device connected.
- Device disconnected.
- Device reconnected.
- Bluetooth reconnect.
- USB/Bluetooth switching.
- Device battery changes where available.
- Controller firmware or driver changes where detectable.

A disconnected controller must not leave an orphaned virtual device.

Reconnection should restore its applicable profile and routing configuration.

# 4. Input normalization engine

Create a common internal representation of controller inputs.

Do not make application developers work with arbitrary hardware-specific button numbers.

## 4.1 Standard gamepad representation

Use a normalized gamepad model containing:

### Buttons
- South
- East
- West
- North
- Left shoulder
- Right shoulder
- Left stick click
- Right stick click
- Start
- Select
- Guide
- D-pad up/down/left/right

### Axes
- Left stick X/Y
- Right stick X/Y
- Left trigger
- Right trigger

### Additional inputs
- Gyroscope
- Accelerometer
- Touchpad contacts
- Paddle buttons
- Controller-specific buttons

Preserve the original hardware identity and physical input information so advanced profiles can access inputs that are not part of the standardized gamepad model.

## 4.2 SDL3 integration

Use SDL3's gamepad mapping infrastructure as a reference and compatibility layer.

Do not make SDL3 the sole source of device detection or hardware capabilities.

Ruya must be able to:

- Load SDL controller mappings.
- Add Ruya-specific mappings.
- Override incorrect mappings.
- Identify unknown devices.
- Maintain its own device capability database.

Keep SDL mapping data separate from Ruya profile data.

# 5. Mapping engine

The mapping engine is the core of Ruya Input.

It translates physical inputs into logical actions or virtual output events.

## 5.1 Mapping types

Support:

- Button to button.
- Button to keyboard key.
- Button to mouse button.
- Button to mouse movement.
- Axis to axis.
- Axis to mouse movement.
- Axis to keyboard input.
- Axis inversion.
- Axis scaling.
- Dead zones.
- Sensitivity curves.
- Trigger thresholds.
- Button combinations.
- Long press.
- Double press.
- Toggle actions.
- Hold actions.
- Turbo/repeated input.

## 5.2 Axis processing

Support configurable:

- Inner dead zone.
- Outer dead zone.
- Anti-dead zone.
- Sensitivity.
- Response curves.
- Inversion.
- Smoothing where appropriate.
- Separate horizontal and vertical settings.

Provide standard presets such as Linear, Precise and Aggressive.

Avoid unnecessary latency. Smoothing must be optional and disabled by default.

## 5.3 Action layers

Action layers allow mappings to change depending on the current context.

Example:

Normal layer:
- Left stick: Movement.
- Right stick: Camera.
- A: Jump.
- B: Crouch.

Modifier layer:
- Left stick: Mouse movement.
- Right stick: Scroll.
- A: Confirm.
- B: Cancel.

Support:

- Momentary layers.
- Toggle layers.
- Conditional layers.
- Layer priorities.
- Layer activation/deactivation events.

Layer changes must be deterministic and must not create stuck buttons or axes.

## 5.4 Chords and macros

Support multiple physical inputs triggering one logical action.

Example:

Guide + X = Screenshot.

Guide + Y = Open Quick Resume.

Guide + B = Return to Ruya Shell.

Macros must support:

- Sequential actions.
- Configurable delays.
- Hold duration.
- Cancellation.
- Execution limits.

Do not allow unrestricted scripts or arbitrary code execution in controller profiles.

# 6. Input routing and ownership

This is a critical architectural component.

A physical controller must have a clearly defined input owner for each active application/session.

## 6.1 Ownership modes

Support at least:

### Direct passthrough

The application receives the physical controller directly.

No Ruya remapping is applied.

Use for applications with their own controller handling or special compatibility requirements.

### Ruya-managed input

Ruya processes the physical controller and creates the configured virtual output device.

The target application receives the virtual device.

The original physical device must not generate duplicate gameplay input for that target.

### Native semantic input

Native Ruya applications receive standardized semantic actions through the Ruya SDK.

They do not need access to physical input devices.

### Steam-managed input

Steam receives the physical controller and manages its own input configuration.

Ruya must not simultaneously process and remap that same controller for the same Steam session.

## 6.2 Routing rules

The routing manager must:

- Track the active application.
- Track the selected input mode.
- Assign controllers to applications.
- Prevent conflicting mappings.
- Manage virtual devices per application or session.
- Restore the previous routing configuration when an application exits.
- Handle application crashes.
- Handle Quick Resume suspension and restoration.

Never globally grab all physical controller devices by default.

Use device grabbing only when necessary and explicitly enabled for a routing mode.

## 6.3 Steam integration

Steam Input must remain fully functional.

Provide a launcher integration contract allowing Steam to declare that it will manage the physical controller.

When Steam owns the controller:

- Ruya must not apply its own mappings.
- Ruya must not create duplicate virtual gamepads for the same controller.
- Ruya must preserve normal controller access for Steam.
- Ruya must restore its previous routing state after Steam exits.

Ruya-managed input must remain available for non-Steam applications.

Do not attempt to inject mappings into Steam's private configuration format or depend on undocumented Steam internals.

# 7. Virtual output devices

Implement output adapters independently from the mapping engine.

## 7.1 Virtual gamepads

Initial output target:

- Xbox-compatible gamepad.

Additional targets:

- PlayStation-compatible gamepad where practical.
- Generic Linux gamepad.
- Configurable gamepad layouts.

Use uinput and libevdev where appropriate.

The virtual device must expose correct button and axis capabilities.

## 7.2 Keyboard and mouse

Support virtual keyboard and mouse output.

This enables controller-only gameplay for games without native controller support.

Examples:

- WASD movement.
- Mouse camera movement.
- Left/right mouse clicks.
- Keyboard shortcuts.
- Scroll wheel.
- Virtual mouse pointer.

Keep keyboard and mouse mappings separate from gamepad mappings.

Respect the active application and desktop session boundaries.

## 7.3 Haptics and force feedback

Implement a separate output capability interface.

Support, where technically possible:

- Basic rumble.
- Left/right motor control.
- Advanced haptic effects.
- Adaptive trigger effects.

Do not claim advanced haptic support simply because basic rumble works.

The mapping and routing architecture must allow feedback events to travel back from the game to the physical controller when supported.

# 8. Gyroscope and touchpad

These are advanced capabilities and should not be treated as ordinary buttons.

## 8.1 Gyroscope

Support:

- Gyro to mouse.
- Gyro to right stick.
- Gyro activation while aiming.
- Gyro activation through a button.
- Sensitivity configuration.
- Axis inversion.
- Calibration.
- Dead zones.
- Smoothing.

Support controller-specific sensor data when available.

Do not require gyroscope support from every controller.

## 8.2 Touchpad

Support:

- Touchpad as mouse.
- Touchpad as button.
- Touchpad regions.
- Touchpad gestures where hardware permits.
- Touchpad-based radial menus.
- Touchpad scrolling.

Expose touchpad contact information through the capability API.

# 9. Profile management

Profiles must be portable, versioned and human-readable.

Use JSON or another established Ruya configuration format. Prefer JSON for interoperability unless the existing architecture has an established alternative.

## 9.1 Profile hierarchy

Implement this precedence:

1. Game profile.
2. Platform/application profile.
3. Global profile.
4. Built-in default.

A profile can inherit from a parent and override individual mappings.

Avoid copying all parent configuration into child profiles.

## 9.2 Profile types

### Global profile

Default controller behavior throughout Ruya.

### Platform profile

Examples:

- Steam.
- Heroic.
- RPCS3.
- RetroArch.

### Game profile

Individual game configuration.

Game profiles should be associated with stable Ruya game identifiers rather than executable filenames alone.

## 9.3 Example profile

{
  "schema_version": 1,
  "id": "cyberpunk-2077",
  "name": "Cyberpunk 2077",
  "scope": {
    "type": "game",
    "game_id": "ruya-game-example"
  },
  "inherits": "global-default",
  "output": {
    "type": "xbox"
  },
  "mappings": [],
  "layers": [],
  "settings": {
    "gyro_enabled": false,
    "rumble_enabled": true
  }
}

This is a simplified example. Define and validate a complete schema before implementing profile persistence.

## 9.4 Profile functionality

Support:

- Create.
- Edit.
- Duplicate.
- Delete.
- Import.
- Export.
- Reset.
- Validate.
- Preview.
- Assign to game.
- Assign to platform.

Profile changes must be applied without requiring an OS restart.

Validate imported profiles before activation.

# 10. Native Ruya SDK integration

Native applications must use the Ruya Input API.

Applications must never need to access evdev or uinput directly.

## 10.1 Semantic actions

Allow applications to register semantic actions.

Example:

{
  "application_id": "com.ruya.example",
  "actions": [
    {
      "id": "navigate_up",
      "label": "Navigate up",
      "category": "navigation"
    },
    {
      "id": "select",
      "label": "Select",
      "category": "navigation"
    },
    {
      "id": "back",
      "label": "Go back",
      "category": "navigation"
    },
    {
      "id": "open_menu",
      "label": "Open menu",
      "category": "navigation"
    }
  ]
}

The user must be able to assign physical inputs to registered application actions.

## 10.2 SDK requirements

Provide:

- Action registration.
- Action subscriptions.
- Current action state.
- Press/release events.
- Repeated input events where appropriate.
- Device capability queries.
- Controller glyph information.
- Input configuration access.
- Haptic feedback requests.
- On-screen keyboard requests.
- Input focus management.

Applications must not receive input when they are not active or authorized to receive it.

## 10.3 Controller glyphs

The SDK must expose controller-specific glyphs.

For example:

- PlayStation: Cross, Circle, Square, Triangle.
- Xbox: A, B, X, Y.
- Nintendo: A, B, X, Y with the correct physical arrangement.

Applications should request glyphs for semantic actions rather than hardcoding controller icons.

Provide fallback glyphs for unknown controllers.

## 10.4 AI-first API documentation

The Ruya SDK documentation must include:

- API reference.
- JSON schemas.
- D-Bus interface definitions.
- Action registration examples.
- Controller input examples.
- Haptic examples.
- Error handling.
- Permissions.
- Version compatibility.
- Migration instructions.

Provide machine-readable API specifications and complete working examples.

Include an AGENTS.md or equivalent guidance file describing how AI coding agents should integrate Ruya Input.

Never rely solely on prose documentation.

# 11. Ruya UI integration

Integrate Ruya Input into the Ruya system settings and gaming interface.

The user must be able to manage controller configurations entirely through a controller.

## 11.1 Controller settings

Provide:

- Connected controllers.
- Connection type.
- Battery status where available.
- Controller assignment.
- Default profile.
- Vibration settings.
- Device capabilities.
- Disconnect/reconnect status.

## 11.2 Controller configuration editor

Create an interactive controller configuration interface.

Required features:

- Visual controller representation.
- Select a button to configure it.
- Press a physical button to identify it.
- Assign a new action.
- Configure axis sensitivity.
- Configure dead zones.
- Configure gyro.
- Configure touchpad.
- Preview changes.
- Save and discard changes.

The editor must be fully controller navigable.

## 11.3 Per-game configuration

Add a controller configuration entry to the game's Ruya details/settings interface.

Users must be able to:

- View the active profile.
- Change the profile.
- Customize mappings.
- Reset to default.
- Import a community profile when that functionality becomes available.

## 11.4 Controller shortcuts

Support configurable global shortcuts.

Initial examples:

- Guide + X: Screenshot.
- Guide + Y: Open Quick Resume.
- Guide + B: Return to Ruya Shell.

Shortcuts must not interfere with applications that require the same combinations.

Provide configurable activation and conflict handling.

# 12. Security and reliability

Security is mandatory.

Requirements:

- No unnecessary root privileges.
- Strict device access permissions.
- D-Bus access controls.
- Application/session isolation.
- Validated profile imports.
- No arbitrary profile code execution.
- Safe virtual device lifecycle.
- Proper cleanup after application crashes.
- Input focus enforcement.
- Rate limits for macros and repeated actions.

The system must detect and recover from:

- Service crashes.
- Controller disconnects.
- Virtual device creation failures.
- Invalid profiles.
- Input routing conflicts.
- Unsupported device capabilities.

Maintain a fallback path to direct physical controller input.

The Ruya Shell must always retain a reliable navigation path.

# 13. Performance requirements

Controller input must feel immediate.

Target:

- Minimal additional input latency.
- No unnecessary polling loops.
- Efficient event-driven processing.
- No blocking operations in the input processing path.
- Predictable CPU and memory usage.
- No dropped events during normal operation.
- Stable behavior with multiple connected controllers.

Measure latency rather than relying on assumptions.

Include instrumentation for input event timestamps, processing time and output delivery time.

# 14. Quick Resume integration

Ruya Input must cooperate with the Ruya Quick Resume subsystem.

When a game is suspended:

- Release or suspend its active input routing.
- Prevent input leakage into the suspended game.
- Restore the appropriate Ruya Shell input context.

When a game resumes:

- Restore its routing configuration.
- Restore its active profile and action layer.
- Reassociate its virtual devices where possible.
- Ensure no stale or duplicated input state exists.

Quick Resume must not depend on virtual device instance identifiers remaining unchanged.

# 15. Community profiles

This is a later milestone.

Provide an architecture for importing and exporting controller configurations.

Future functionality:

- Community profile repository.
- Profile search.
- Popular profiles.
- Game-specific recommendations.
- User ratings.
- Profile version history.
- Profile updates.

Community profiles must be treated as untrusted data and validated before use.

The basic import/export format must be designed in V1 so this feature does not require a profile format migration.

# 16. Implementation roadmap

Implement incrementally. Do not attempt to build all advanced functionality at once.

## Phase 0 – Architecture and research

- Inspect the existing Ruya OS architecture.
- Identify existing input handling.
- Identify D-Bus and SDK conventions.
- Verify available Linux kernel interfaces.
- Evaluate controller compatibility.
- Define the profile schema.
- Define service interfaces.
- Produce an architecture decision record.

Deliverable: Approved implementation architecture.

## Phase 1 – Core input foundation

Implement:

- Device discovery.
- Physical controller identification.
- Capability detection.
- Input normalization.
- Device connection lifecycle.
- Basic D-Bus API.
- Basic controller test interface.

Support the initial controller families as far as available drivers permit.

Deliverable: Ruya can discover controllers and expose standardized input events.

## Phase 2 – Mapping and virtual devices

Implement:

- Button remapping.
- Axis remapping.
- Dead zones.
- Sensitivity curves.
- Virtual Xbox-compatible gamepad.
- Virtual keyboard.
- Virtual mouse.
- Profile persistence.
- Global profiles.
- Basic routing.

Deliverable: Games without native controller support can receive mapped virtual input.

## Phase 3 – Application and launcher integration

Implement:

- Native Ruya Input SDK.
- Semantic actions.
- Controller glyphs.
- Game profiles.
- Platform profiles.
- Steam ownership integration.
- Heroic integration.
- RPCS3 integration.
- Application lifecycle management.

Deliverable: Ruya Input works across the Ruya gaming ecosystem.

## Phase 4 – Advanced controller features

Implement:

- Gyroscope.
- Touchpad.
- Action layers.
- Chords.
- Macros.
- Advanced rumble.
- Adaptive trigger support where possible.
- Controller shortcuts.
- Advanced configuration UI.

Deliverable: Advanced controller customization.

## Phase 5 – Ecosystem

Implement:

- Community profiles.
- Profile repository integration.
- Profile sharing.
- Recommendations.
- Expanded controller support.

Deliverable: A mature controller configuration ecosystem.

# 17. Testing requirements

Create automated tests for the input engine.

## Unit tests

- Button mapping.
- Axis mapping.
- Dead zones.
- Sensitivity curves.
- Action layers.
- Chords.
- Macro cancellation.
- Profile inheritance.
- Profile validation.
- Routing decisions.

## Integration tests

- USB controller detection.
- Bluetooth controller detection.
- Device disconnection.
- Device reconnection.
- Virtual device creation.
- Virtual device removal.
- Steam ownership.
- Direct passthrough.
- Multiple controllers.
- Application crashes.
- Quick Resume transitions.

## Compatibility tests

Test at minimum:

- DualSense.
- DualShock 4.
- Xbox controller.
- Switch Pro Controller.
- 8BitDo controller.
- Generic HID controller.

Test with:

- Ruya Shell.
- A native Ruya application.
- Steam.
- A Proton game.
- Heroic.
- RPCS3.
- A keyboard/mouse-only game.

Create simulated input devices for automated testing so physical hardware is not required for every test.

# 18. Definition of Done

Ruya Input V1 is complete when:

1. Physical controllers are detected reliably.
2. Device capabilities are exposed.
3. Standardized controller input is available.
4. Button and axis remapping work.
5. Global, platform and game profiles work.
6. Profiles can be imported and exported.
7. Virtual Xbox-compatible gamepads work.
8. Virtual keyboard and mouse work.
9. Direct passthrough works.
10. Steam Input can operate without conflicting with Ruya Input.
11. Native Ruya applications can use semantic actions.
12. Controller configuration is available in Ruya settings.
13. Controller navigation remains available when the input service fails.
14. Automated tests cover the critical input and routing paths.
15. API documentation and machine-readable schemas are complete.

# 19. Instructions to Claude

Before writing code:

1. Inspect the complete existing Ruya OS repository.
2. Read existing architecture documentation and development instructions.
3. Identify existing services and SDK interfaces that should be reused.
4. Identify any existing input handling that would conflict with this subsystem.
5. Create a concrete implementation plan.
6. Document architectural decisions.
7. Identify technical uncertainties and validate them against the actual target Linux environment.

During implementation:

- Follow existing project architecture and coding conventions.
- Do not introduce unnecessary frameworks or dependencies.
- Do not duplicate existing OS services.
- Do not create temporary hacks or placeholder implementations.
- Do not leave TODOs in completed functionality.
- Do not silently reduce the scope of requirements.
- Use explicit versioned API contracts.
- Include automated tests with each implementation milestone.
- Keep all documentation synchronized with the implementation.
- Make every subsystem independently testable.
- Prefer small, reviewable implementation stages.

If a requirement cannot be implemented as specified, explain the technical limitation and propose an architectural alternative before changing the requirement.

Do not assume that a successful compilation means the subsystem is complete.

Verify actual controller behavior, routing, application integration and recovery.

**Final objective:** Ruya Input must become a first-class Ruya OS capability that works across the entire gaming ecosystem without requiring Steam or any other individual application to manage the user's controller experience.