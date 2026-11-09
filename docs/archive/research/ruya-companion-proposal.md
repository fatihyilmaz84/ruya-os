# Ruya Companion
## Product Architecture & Feature Specification

**Project:** Ruya OS  
**Component:** Ruya Companion  
**Document type:** Product and Technical Specification  
**Status:** Architecture proposal – V1  
**Platforms:** iOS and Android

---

# 1. Product Vision

Ruya Companion is the official mobile companion application for Ruya OS.

It provides a unified interface for discovering, managing, controlling and monitoring Ruya devices.

The application extends the Ruya OS experience beyond the television or monitor. Users should be able to manage their gaming PC without having to sit in front of it.

Ruya Companion is not simply a remote control. It is the mobile management interface for the Ruya ecosystem.

### 1.1 Core principles

1. **Local-first:** The application must work without a Ruya cloud account.
2. **Remote-capable:** Users can optionally access their Ruya devices from outside their local network.
3. **Unified ecosystem:** Games and applications are managed through common Ruya OS APIs.
4. **Platform-native integration:** Native Ruya applications can expose capabilities and information to Companion.
5. **Secure by design:** Every paired device has an independent identity and explicit permissions.
6. **Consistent experience:** The mobile application follows the Ruya design system.
7. **LLM-first development:** APIs, contracts and documentation must be understandable and usable by AI development agents.

### 1.2 Product boundaries

The initial product focuses on management.

Included:
- Device discovery and pairing.
- Remote control.
- Game library management.
- Installation and download management.
- Application management.
- System monitoring.
- Device configuration.
- Notifications.
- Remote connectivity.

Not included in the initial scope:
- Game streaming / Remote Play.
- AI gaming assistant.
- Social gaming features.
- Community achievements.
- Game discovery marketplace.
- Media streaming.

These may become separate future capabilities.

---

# 2. Application Structure

The mobile application uses five primary navigation sections.

## 2.1 Home

The home screen provides an overview of the connected Ruya ecosystem.

Information:
- Paired devices.
- Online/offline status.
- Currently active device.
- Currently running game.
- Recently played games.
- Active downloads.
- System health overview.
- Available OS updates.
- Important notifications.

Actions:
- Connect to a device.
- Open remote control.
- Launch a recently played game.
- Open download management.
- View system information.
- Shut down, restart or suspend a device.

Users can pair multiple Ruya devices and switch between them.

## 2.2 Library

A unified library of games and installed applications.

Supported functionality:
- Browse all games.
- Browse installed games.
- Browse uninstalled games.
- Browse native applications.
- Search and filter.
- View game and application details.
- Launch applications remotely.
- Install and uninstall.
- View installation size.
- View compatibility information.
- View available updates.

The library must not be tied to a specific launcher.

Steam, Epic, GOG, Heroic, emulators and native Ruya applications should integrate through the common platform library APIs.

The Companion must never directly access launcher databases.

## 2.3 Downloads

Central management of installation and update operations.

Information:
- Current downloads.
- Download progress.
- Download speed.
- Estimated remaining time, when available.
- Download queue.
- Installation progress.
- Update operations.
- Failed operations.
- Available storage.

Actions:
- Pause.
- Resume.
- Cancel.
- Reorder queue.
- Install.
- Update.
- Retry failed operations.

Downloads should be managed by Ruya OS services, not by the mobile application itself.

The mobile application only submits commands and observes operation status.

## 2.4 System

System administration and monitoring.

Information:

**Hardware**
- CPU model.
- CPU utilization.
- CPU temperature.
- GPU model.
- GPU utilization.
- GPU temperature.
- GPU memory.
- RAM usage.
- Storage devices.
- Available storage.
- Network interfaces.
- Fan speeds where supported.

**Software**
- Ruya OS version.
- Kernel version.
- System update status.
- Installed application versions.
- Service health.
- Driver information.

**Controls**
- Sleep.
- Wake.
- Restart.
- Shutdown.
- Check for updates.
- Install updates.
- Configure supported system settings.

Monitoring should be efficient and event-driven. The application must not continuously poll every hardware metric.

## 2.5 Settings

Application and device configuration.

Application settings:
- Appearance.
- Language.
- Notifications.
- Preferred connection method.
- Default device.
- Security settings.

Device settings:
- Device name.
- Paired devices.
- Device permissions.
- Network status.
- Remote access.
- OS updates.
- Storage information.
- Remove device pairing.

---

# 3. Remote Control

Remote control is a core capability.

The initial implementation should support:

### 3.1 Navigation

- D-pad.
- Confirm.
- Back.
- Home.
- Context menu.
- Directional navigation.
- Long-press actions.

### 3.2 Pointer control

- Touchpad.
- Mouse movement.
- Left and right click.
- Scroll.
- Drag and drop where supported.

### 3.3 Text input

The user should be able to type using the native mobile keyboard.

The input mechanism should support:
- Search fields.
- Text boxes.
- Password fields.
- Application text input.
- Keyboard shortcuts where supported.

Sensitive input must be handled through secure input channels and must not be stored in logs.

### 3.4 Power management

- Suspend.
- Resume.
- Restart.
- Shutdown.
- Wake-on-LAN where hardware supports it.

Wake functionality must distinguish between a sleeping device that supports network wake and a powered-off device that cannot be awakened through the available hardware.

---

# 4. Ruya OS Architecture

The Companion must integrate with Ruya OS through a dedicated service.

## 4.1 Architecture overview

Mobile application:

- Flutter application.
- Shared business logic.
- Platform-specific notification integration.
- Secure local credential storage.
- HTTPS client.
- WebSocket client.

Ruya OS:

- Ruya Companion Service.
- Ruya Platform API.
- Existing platform services.
- D-Bus internal communication.
- Rust-based privileged service components.

Communication:

- HTTPS for commands and queries.
- WebSocket for events and live updates.
- TLS for transport encryption.
- Device-specific authentication.

The mobile application must never communicate directly with D-Bus.

## 4.2 Ruya Companion Service

The Ruya Companion Service runs as a system service.

Responsibilities:

1. Expose authorized platform APIs to paired devices.
2. Authenticate incoming requests.
3. Enforce device-specific permissions.
4. Forward requests to existing Ruya platform services.
5. Publish system and application events.
6. Manage connection state.
7. Manage remote connectivity.
8. Provide structured errors.
9. Maintain an auditable security event log.

The service should be implemented in Rust and integrate with the existing Ruya service architecture.

It must not duplicate functionality already provided by existing OS services.

## 4.3 Shared platform APIs

The Companion must consume the same underlying APIs as native Ruya applications.

Relevant platform domains:

- Device API.
- Identity API.
- Library API.
- Content API.
- Launch API.
- Activity API.
- Storage API.
- System API.
- Download API.
- Notification API.
- Permission API.

If an API does not exist yet, it should be added to the shared platform architecture rather than implemented as a Companion-specific workaround.

## 4.4 API versioning

All external APIs must be versioned.

Example:

`/api/v1/devices`

`/api/v1/library/games`

`/api/v1/downloads`

`/api/v1/system/metrics`

The API must expose:
- Platform version.
- API version.
- Supported capabilities.
- Deprecated endpoints.
- Device feature availability.

The mobile application must negotiate supported capabilities instead of assuming every Ruya device has identical hardware or software.

---

# 5. Device Discovery and Pairing

## 5.1 Local discovery

Use mDNS/DNS-SD for discovering Ruya devices on the local network.

The discovery mechanism should:
- Advertise compatible Ruya devices.
- Include a device identifier.
- Include supported protocol information.
- Avoid exposing sensitive device information.
- Support multiple devices on one network.

Discovery is only a convenience mechanism. It must never establish trust by itself.

## 5.2 Pairing process

Recommended flow:

1. User opens Companion.
2. Companion discovers available Ruya devices.
3. User selects a device.
4. Ruya displays a QR pairing code.
5. User scans the QR code.
6. Both devices perform a mutually authenticated pairing exchange.
7. Ruya displays the requested permissions.
8. User confirms pairing.
9. Ruya issues a device-specific credential.
10. Companion securely stores the credential.

Pairing codes must:
- Be single-use.
- Expire.
- Be sufficiently unpredictable.
- Be protected against replay.
- Never contain reusable credentials.

## 5.3 Device identity

Every Ruya installation has a persistent cryptographic device identity.

Every paired mobile device receives its own identity.

A user can:
- View paired devices.
- Rename paired devices.
- Revoke a device.
- View last connection time.
- Change permissions.
- Re-pair a device.

Revocation must immediately invalidate the associated credentials.

No central Ruya account is required.

---

# 6. Connectivity Architecture

Ruya Companion supports two connection modes.

## 6.1 Local network

Default connection method.

Requirements:
- Automatic device discovery.
- Secure HTTPS.
- WebSocket events.
- Automatic reconnection.
- Connection health monitoring.

Local network connectivity must work without internet access.

## 6.2 Remote connectivity

Users can optionally access their Ruya devices over the internet.

The architecture should support:

1. Direct connections where network configuration permits.
2. NAT traversal where possible.
3. An optional encrypted relay when direct connectivity is unavailable.

Remote access must not require exposing the Ruya management API directly to the public internet.

The preferred design is an outbound connection from Ruya OS to a remote rendezvous service.

The relay must forward encrypted traffic without having access to application credentials or decrypted commands.

Device pairing and authorization remain local and accountless.

A user-owned VPN, such as WireGuard, should also be supported as an alternative connection path.

### Important distinction

Remote connectivity is optional. A Ruya installation must remain fully manageable on the local network if the remote infrastructure is unavailable.

The relay service is infrastructure, not an identity provider.

---

# 7. Security and Permissions

Security must be implemented at the OS service level.

## 7.1 Device permissions

Each paired mobile device has an independent permission set.

Initial permission categories:

- View device information.
- View system metrics.
- Browse library.
- Launch applications.
- Manage installations.
- Manage downloads.
- Control system power.
- Send remote input.
- Manage device settings.

Permissions should be independently configurable.

## 7.2 Authorization

Every command must be authorized by the Ruya Companion Service.

The mobile application cannot grant itself additional permissions.

Sensitive operations, including shutdown, restart, uninstallation and credential management, must have explicit authorization checks.

## 7.3 Security requirements

- TLS 1.3 where supported.
- Mutual device authentication.
- Short-lived access tokens.
- Rotatable credentials.
- Revocation support.
- Secure mobile credential storage.
- Rate limiting.
- Request validation.
- Replay protection.
- Structured security logging.
- No plaintext credentials in logs.
- No public unauthenticated management endpoints.

The implementation should follow established Linux security mechanisms rather than introducing unnecessary custom security infrastructure.

---

# 8. Event Architecture

The Companion should use an event-driven architecture.

WebSocket connections deliver changes from Ruya OS.

Examples:

`device.online`

`device.offline`

`system.metrics.updated`

`system.update.available`

`library.game.added`

`library.game.removed`

`library.game.updated`

`launch.started`

`launch.completed`

`download.started`

`download.progress`

`download.completed`

`download.failed`

`application.installed`

`application.uninstalled`

`device.power.state_changed`

Every event should have:
- Event ID.
- Event type.
- Schema version.
- Device ID.
- Timestamp.
- Relevant resource ID.
- Structured payload.

Events must be safe to process more than once.

The client should be able to recover after disconnection using a cursor or event sequence mechanism.

A full state synchronization endpoint must be available when incremental event recovery is impossible.

---

# 9. Application Integration

The Companion must support future native Ruya applications.

This is important for creating an ecosystem instead of a collection of isolated features.

## 9.1 Application capabilities

Native applications can expose discoverable capabilities through the Ruya Content and Application Registry.

Examples:

A music application:
- Recently played tracks.
- Recently added albums.
- Current playback.
- Playback controls.

An emulator:
- Installed games.
- Recently played games.
- Game launch actions.
- Save-state information.

A media player:
- Recently played media.
- Current playback.
- Playback controls.

A download manager:
- Active transfers.
- Transfer progress.
- Queue management.

## 9.2 Capability registration

Applications declare their supported capabilities in their application manifest and register runtime endpoints through the platform services.

The Companion discovers capabilities through the OS registry.

It must not depend on:
- Application-specific databases.
- Hardcoded application IDs.
- Direct filesystem access.
- Launcher-specific integrations.

## 9.3 Extensibility

The architecture must allow new application capabilities without requiring a complete redesign of Companion.

Applications should only expose capabilities that they explicitly support.

The OS remains responsible for authentication, permission checks and capability discovery.

---

# 10. Technical Implementation

## 10.1 Mobile application

Proposed technology: Flutter.

Reasons:
- Shared iOS and Android implementation.
- Consistent UI.
- Strong networking support.
- Native platform integration.
- Good long-term maintainability.

Use platform-native secure storage and notification services.

Keep networking, state management and UI layers separate.

Suggested logical modules:

- `core`
- `authentication`
- `device_discovery`
- `device_management`
- `remote_control`
- `library`
- `downloads`
- `system_monitoring`
- `notifications`
- `settings`
- `design_system`

## 10.2 Ruya OS service

Proposed technology: Rust.

Responsibilities:
- API gateway.
- Device authentication.
- Authorization.
- Event distribution.
- Remote connectivity.
- Platform API integration.

The service should be relatively lightweight and must not become a second implementation of the existing OS services.

## 10.3 API documentation

All APIs must be documented in machine-readable and human-readable formats.

Required:
- OpenAPI specifications.
- JSON Schemas.
- Event schemas.
- Authentication documentation.
- Permission definitions.
- API versioning documentation.
- Error code reference.
- Example requests and responses.
- Reference client implementation.

All documentation must be suitable for consumption by AI coding agents.

---

# 11. Development Phases

## Phase 1 – Foundation

- Companion Service.
- Device identity.
- Local discovery.
- QR pairing.
- Authentication.
- Permission management.
- Device status.
- Basic application navigation.

**Deliverable:** Companion can securely discover and pair with a Ruya device.

## Phase 2 – Remote Control

- D-pad.
- Navigation commands.
- Pointer mode.
- Text input.
- Volume controls.
- Power management.
- Wake-on-LAN.

**Deliverable:** A Ruya device can be operated entirely through Companion.

## Phase 3 – Library Management

- Unified game library.
- Application library.
- Search and filtering.
- Game details.
- Remote launching.
- Installation and uninstallation.
- Compatibility information.

**Deliverable:** Users can manage their library remotely.

## Phase 4 – Downloads and System

- Download management.
- Installation queues.
- System metrics.
- Storage information.
- Hardware information.
- OS updates.
- Application updates.

**Deliverable:** Full remote management of the Ruya device.

## Phase 5 – Remote Connectivity

- Remote rendezvous.
- NAT traversal.
- Encrypted relay.
- Remote authentication.
- Connection recovery.
- VPN support.

**Deliverable:** Secure remote management from outside the local network.

## Phase 6 – Ecosystem Integration

- Application capability registry.
- Third-party application integrations.
- Custom application information.
- Application-provided actions.
- Application notifications.

**Deliverable:** Native Ruya applications can expose information and functionality to Companion without custom mobile integrations.

---

# 12. Non-functional Requirements

- Local network functionality must not depend on internet access.
- Multiple Ruya devices must be supported.
- Multiple paired mobile devices must be supported.
- Connection interruptions must not corrupt operations.
- Commands must be idempotent where appropriate.
- Long-running operations must have persistent operation IDs.
- The application must recover after backgrounding.
- System monitoring must minimize network traffic.
- APIs must be versioned.
- All sensitive operations must be authorized.
- Remote connectivity must be optional.
- No mandatory account or subscription.
- No direct database access from Companion.

---

# 13. Definition of Done

The initial product is considered functionally complete when:

1. A user can discover and pair a Ruya device without an account.
2. Pairing uses cryptographic device identities.
3. A user can manage multiple Ruya devices.
4. Remote control works over the local network.
5. The unified library displays games and applications.
6. Games can be launched remotely.
7. Downloads can be monitored and controlled.
8. System information can be viewed.
9. Notifications are delivered for important operations.
10. Individual paired devices can be revoked.
11. Optional remote access works without exposing public management endpoints.
12. Native applications can expose supported capabilities through the shared platform APIs.
13. The application recovers cleanly after connection interruptions.

---

# 14. Architectural Principle

Ruya Companion is a first-party client of the Ruya OS platform.

It must not own game libraries, installation state, application databases, device configuration or system state.

Those belong to Ruya OS.

Companion provides the interface through which users access and manage that functionality.

This principle must guide all future implementation decisions.