# Ruya OS — Web UI
## Architecture & Implementation Specification

**Document type:** Product and technical implementation specification  
**Component:** Ruya Web  
**Platform:** Ruya OS  
**Status:** Implementation specification  
**Primary objective:** Build the central local Content & System Management interface for Ruya OS.

---

# 1. Objective

Build Ruya Web, a comprehensive browser-based management interface integrated into Ruya OS.

Ruya Web allows users to manage their Ruya system from another device on the same local network using a web browser.

It is not intended to be a simple ROM manager. It is the central interface for managing the content, storage, applications and configuration of a Ruya OS installation.

Examples of intended functionality:

- Upload and import ROMs.
- Browse and organize the game library.
- Manage game metadata and artwork.
- Manage emulator resources and BIOS files.
- Manage save data and backups.
- Browse storage devices and available space.
- Monitor downloads and imports.
- Manage installed applications and system components.
- View system information, logs and diagnostics.
- Configure Ruya OS settings.

The interface must be suitable for both ordinary users and advanced users.

## 1.1 Core principles

The implementation MUST follow these principles:

1. Ruya Web is a first-party Ruya OS application.
2. Ruya Web is strictly local-network-only.
3. Ruya Web uses the shared Ruya Platform APIs.
4. Ruya Web must not contain independent business logic for managing games, files, storage or system services.
5. All content must be managed through shared platform services.
6. The UI must use the Ruya Design System.
7. The architecture must be modular and extensible.
8. APIs and documentation must be designed for AI-assisted development and future AI agents.
9. Security must be enforced by the backend, not just by frontend restrictions.
10. The implementation must be production-quality, not a prototype.

---

# 2. Position Within Ruya OS

Ruya OS has three primary user interfaces.

| Interface | Primary purpose | Connectivity |
|---|---|---|
| Ruya TV | Gaming and entertainment | Local |
| Ruya Companion | Mobile management and remote control | Local and optional remote |
| Ruya Web | Comprehensive content and system administration | Local only |

All three interfaces communicate with the same Ruya Platform API.

```text
                    RUYA OS
                       |
              Ruya Platform APIs
                       |
        +--------------+--------------+
        |              |              |
     Ruya TV       Companion       Ruya Web
        |              |              |
        +--------------+--------------+
                       |
              Platform Services
                       |
    +------------------+------------------+
    |                  |                  |
Content Management  System Management  App Registry
    |                  |                  |
Storage Management  Download Manager  Notifications
    |                  |                  |
    +------------------+------------------+
                       |
                 Ruya OS Core
                       |
              Linux / Drivers / FS
```

Ruya Web must not create its own independent management services.

If an API or service required by Ruya Web does not exist, identify it as a missing platform capability. Implement it in the appropriate shared platform layer rather than introducing Web-specific backend logic.

---

# 3. Local-Only Architecture

This is a hard architectural requirement.

Ruya Web must only be accessible from the Ruya device itself or devices on its local network.

It must never be accessible through:

- Ruya remote-access services.
- External relay infrastructure.
- Public internet-facing management endpoints.
- Companion remote-access sessions.
- Third-party cloud services acting as a proxy.

## 3.1 Network requirements

The Web service must:

- Listen only on explicitly configured local network interfaces and loopback.
- Never bind to a public interface.
- Never register itself with the Ruya remote-access gateway.
- Reject requests arriving through unauthorized network interfaces.
- Be inaccessible when local Web management is disabled.
- Support access through a local hostname, for example `https://ruya.local`.
- Support direct local IP access when hostname resolution is unavailable.

Do not assume that binding to a private IP alone provides sufficient security.

The service must validate the actual incoming connection and enforce its local-network policy.

## 3.2 Local discovery

Support local hostname resolution and discovery through mDNS/DNS-SD where available.

The hostname should be configurable.

Suggested default:

`https://ruya.local`

Do not make the application dependent on mDNS. Users must still be able to access it using the device's local IP address.

## 3.3 HTTPS

All management traffic must use HTTPS, including traffic within the local network.

Implement a Ruya-managed local certificate strategy.

The implementation must consider:

- Certificate creation and lifecycle.
- Certificate renewal.
- Browser trust limitations.
- Certificate changes after reinstall or device identity reset.
- Secure access through both hostname and IP address.

Never silently downgrade management sessions to HTTP.

If the certificate is not trusted by a browser, provide clear instructions rather than weakening TLS requirements.

## 3.4 Security protections

Implement:

- Authentication for all management sessions.
- CSRF protection.
- Strict origin validation.
- DNS rebinding protection.
- Secure cookie configuration.
- Content Security Policy.
- Request rate limiting.
- Input validation.
- Upload size and file-type restrictions.
- Session expiration and revocation.
- Audit logging for administrative actions.

Being connected to the home network must not automatically grant administrative access.

---

# 4. Architecture and Technology

Before implementation, inspect the existing Ruya OS codebase.

Determine:

- Existing frontend framework and build system.
- Existing backend architecture.
- Existing API conventions.
- Existing authentication and authorization.
- Existing shared services.
- Existing design system.
- Existing deployment and service-management approach.

Do not replace existing technologies simply because another framework is preferred.

## 4.1 Frontend

Preferred technology, if compatible with the existing architecture:

- React
- TypeScript
- Vite
- Shared Ruya Design System
- Component-based architecture

The frontend should be bundled and distributed as part of Ruya OS.

It must not require an external website or cloud-hosted frontend to function.

Use a modular feature-oriented structure.

Suggested structure:

```text
ruya-web/
├── src/
│   ├── app/
│   │   ├── routing/
│   │   ├── providers/
│   │   └── layout/
│   ├── components/
│   ├── design-system/
│   ├── features/
│   │   ├── dashboard/
│   │   ├── library/
│   │   ├── imports/
│   │   ├── storage/
│   │   ├── artwork/
│   │   ├── emulator-resources/
│   │   ├── saves/
│   │   ├── downloads/
│   │   ├── applications/
│   │   ├── system/
│   │   ├── network/
│   │   ├── settings/
│   │   └── diagnostics/
│   ├── services/
│   ├── hooks/
│   ├── types/
│   └── utils/
├── public/
└── documentation/
```

This is a conceptual structure. Adapt it to existing repository conventions.

## 4.2 Backend

The Web UI must communicate with Ruya's shared platform services through authenticated APIs.

It must not:

- Directly access application databases.
- Directly access internal service databases.
- Execute arbitrary shell commands.
- Access arbitrary filesystem paths.
- Communicate directly with D-Bus.
- Implement its own emulator detection.
- Implement its own content identification.
- Manage storage independently of the Storage Management service.

Privileged operations must be performed by appropriate platform services.

## 4.3 API communication

Use:

- HTTPS REST APIs for commands and queries.
- WebSockets or the existing Ruya event mechanism for real-time updates.
- Structured JSON request and response schemas.
- Explicit API versioning.
- Consistent error responses.
- Pagination for large collections.
- Cursor-based event recovery where supported.

The frontend must not poll excessively when an event-based mechanism is available.

---

# 5. Ruya Design System

Ruya Web must use the shared Ruya Design System.

Do not develop an unrelated visual language for the administration interface.

## 5.1 Design objectives

The interface should feel like a native part of Ruya OS.

Visual characteristics:

- Modern.
- Minimal.
- Elegant.
- Clean typography.
- Strong visual hierarchy.
- Consistent spacing.
- Carefully controlled use of color.
- Clear status indicators.
- Subtle animations.
- Responsive layouts.

The interface should prioritize clarity and usability over decorative elements.

## 5.2 Shared components

Use reusable components for:

- Navigation.
- Page headers.
- Cards.
- Tables and lists.
- Search.
- Filters.
- Dialogs.
- Confirmation dialogs.
- Context menus.
- Notifications.
- Toast messages.
- Progress indicators.
- Empty states.
- Loading states.
- Error states.
- Status badges.
- File upload areas.
- Storage indicators.
- Artwork and game cards.

Components should be reusable by other Ruya interfaces where appropriate.

## 5.3 Responsive behavior

Ruya Web is primarily intended for desktop and tablet browsers.

It must also remain usable on mobile browsers.

Support:

- Desktop layouts.
- Tablet layouts.
- Mobile layouts.

Do not simply shrink the desktop layout on mobile. Navigation and complex management controls should adapt appropriately.

## 5.4 Accessibility

Implement:

- Keyboard navigation.
- Visible focus states.
- Accessible labels.
- Appropriate contrast.
- Screen-reader-friendly status updates.
- Reduced-motion support.
- Semantic HTML.

---

# 6. Navigation and Information Architecture

Use a persistent navigation structure.

Proposed navigation:

```text
RUYA

Overview

CONTENT
  Game Library
  Imports
  Artwork & Metadata
  Saves & Backups
  Emulator Resources

STORAGE
  Storage Devices
  File Browser

SYSTEM
  Applications
  Downloads & Updates
  Hardware
  Network & Services
  Logs & Diagnostics

SETTINGS
  General
  Security
  Users & Permissions
  Web Management
```

The navigation must be extensible.

Only show sections supported by the installed Ruya OS capabilities.

For example, if a particular emulator integration is not installed, the UI must not pretend that its resources are available.

Use capability-driven navigation where appropriate.

---

# 7. Dashboard

The dashboard is the landing page after authentication.

It should provide a useful overview of the Ruya system.

## 7.1 System overview

Display:

- Ruya OS version.
- Device name.
- System uptime.
- CPU utilization.
- GPU utilization, when supported.
- Memory usage.
- Storage usage.
- Network status.
- Temperature information where available.

Do not assume all hardware exposes the same metrics.

Use the capabilities reported by the System Management API.

## 7.2 Content overview

Display:

- Total registered games.
- Games by platform.
- Recently imported games.
- Recent imports.
- Failed imports.
- Missing artwork.
- Unavailable content.
- Storage distribution.

## 7.3 Activity

Display recent events:

- Import completed.
- Import failed.
- Download completed.
- Application installed.
- Application updated.
- Storage device connected or disconnected.
- Backup completed.
- System warning.

All activity must come from the shared Ruya event system.

## 7.4 Quick actions

Provide shortcuts to:

- Import games.
- Browse library.
- Manage storage.
- Manage emulator resources.
- View system diagnostics.

---

# 8. Content Management

Content Management is one of the most important parts of Ruya Web.

It must be built on the shared Ruya Content Management architecture.

The UI must not treat content as arbitrary files with manually maintained paths.

## 8.1 Content Registry

Ruya OS must maintain a central Content Registry.

Every managed content item must have a stable identifier independent of its physical storage location.

Example:

```json
{
  "id": "ruya.content.game.example",
  "type": "game",
  "title": "Example Game",
  "platform": "snes",
  "availability": "available",
  "storage": {
    "provider_id": "internal-ssd",
    "location_id": "game-location-123"
  }
}
```

This is illustrative only. Use the actual shared API schema when available.

The registry should support:

- Games.
- Game files.
- Game assets.
- Save data.
- Save states.
- Emulator resources.
- Media.
- User-imported content.

The Web UI must use Content Registry identifiers, not physical paths, as the primary references to content.

## 8.2 Game Library

Provide a comprehensive game-management interface.

Features:

- Browse all registered games.
- Search by title.
- Filter by platform.
- Filter by emulator.
- Filter by availability.
- Filter by import status.
- Sort by title, platform, date added and other supported metadata.
- Switch between grid and list views.
- View game details.
- Edit permitted metadata.
- Associate or replace artwork.
- View storage information.
- View compatibility information.
- Launch a game when the user has the required permission.
- Remove a game from the library.
- Delete associated files only through an explicit, confirmed operation.

The distinction between removing a library entry and deleting physical files must be clear.

## 8.3 Game details

Each game should have a dedicated details page.

Display available information:

- Title.
- Platform.
- Description.
- Release information.
- Developer and publisher.
- Genre.
- Artwork.
- Screenshots.
- Associated files.
- File integrity information.
- Storage location.
- Emulator compatibility.
- Installation/import status.
- Save data.
- Recently played information, when exposed by the application registry or game services.

Only show metadata that is actually available.

## 8.4 Artwork and metadata

Provide an interface for managing game artwork and metadata.

Features:

- View current artwork.
- Upload custom artwork.
- Replace artwork.
- Remove artwork.
- Associate screenshots.
- Edit supported metadata.
- Identify missing artwork.
- Identify incomplete metadata.
- Preview changes.

External metadata providers must be integrated through platform services or provider integrations.

Do not embed provider-specific credentials in the frontend.

Users must be able to manage locally stored artwork without an internet connection.

---

# 9. Import Management

Importing content must be a shared Ruya OS service.

The Web UI provides the interface, but the Import Pipeline handles the actual work.

## 9.1 Upload and import distinction

There are two separate operations:

**Upload:** Transfer files to Ruya OS.

**Import:** Validate, identify and register uploaded files.

Do not combine these into one opaque operation.

The user must be able to see which stage is currently running.

## 9.2 Supported import sources

Initially support:

- Browser file upload.
- Multiple file upload.
- Folder upload where browser support allows it.
- Import from an existing local storage location.
- Import from an attached storage device.

Future sources should be supported through extensible importer integrations.

## 9.3 Upload requirements

Implement:

- Drag and drop.
- File selection.
- Multiple file selection.
- Upload queue.
- Upload progress.
- Cancel upload.
- Retry failed upload.
- Resumable uploads where technically supported.
- Upload size limits.
- Storage availability checks.
- Clear upload errors.

Uploads must not block the browser or the entire management service.

Large uploads must be processed asynchronously.

## 9.4 Import Pipeline

The shared Import Pipeline should support these stages:

```text
UPLOAD
   |
VALIDATION
   |
IDENTIFICATION
   |
METADATA
   |
REGISTRATION
   |
AVAILABLE IN LIBRARY
```

Each stage must have a clear status.

Suggested states:

- Pending.
- Uploading.
- Uploaded.
- Validating.
- Identifying.
- Metadata lookup.
- Registering.
- Completed.
- Failed.
- Cancelled.
- Needs attention.

The actual state model must be defined by the shared Import API.

## 9.5 ROM import

ROM import is the first major use case.

The importer must determine supported formats from installed emulator and platform integrations.

Do not hardcode the complete list of supported ROM formats in the frontend.

The UI should display:

- Detected platform.
- Detected file format.
- File size.
- Identification result.
- Matching game metadata, if available.
- Emulator compatibility.
- Duplicate detection result.
- Import warnings.

If identification fails, allow manual metadata association.

## 9.6 Archive handling

Support archive processing through platform importers where available.

Consider:

- ZIP.
- 7z.
- Nested archives.
- Multiple ROMs in one archive.
- Invalid archives.
- Password-protected archives.

Archive extraction must be subject to resource limits and safe path handling.

Do not allow archive path traversal or uncontrolled extraction.

Do not silently extract files without showing the user what will be imported.

## 9.7 Duplicate detection

Detect duplicates using available identifiers such as:

- Cryptographic file hashes.
- File size.
- Known content identifiers.
- Platform-specific identification.

Do not rely on filenames alone.

Provide clear choices when duplicates are detected.

The user should be able to keep the existing item, replace it or import another copy where appropriate.

## 9.8 Import history

Provide an import history page.

Display:

- Import date.
- Source.
- Files processed.
- Result.
- Warnings.
- Errors.
- Duration.
- Associated content records.

Allow users to inspect failed imports and retry when safe.

---

# 10. Storage Management

Storage must be managed through the shared Ruya Storage Management API.

The Web UI must not manage mounts or storage configuration directly.

## 10.1 Storage overview

Display:

- Internal drives.
- External drives.
- Removable storage.
- Available capacity.
- Used capacity.
- Filesystem.
- Mount status.
- Storage health where available.
- Content distribution.

## 10.2 Storage device details

For each device, show:

- Device name.
- Device identifier.
- Capacity.
- Free space.
- Filesystem.
- Mount point as informational data.
- Connection status.
- Health information where supported.
- Associated content.

Do not expose privileged filesystem operations through the UI.

## 10.3 Storage operations

Where supported by the platform API, provide:

- View storage devices.
- View storage locations.
- Configure content storage locations.
- Move managed content.
- Safely eject removable storage.
- View content unavailable due to disconnected storage.
- View storage errors.

## 10.4 Storage abstraction

Physical storage must be independent of logical content identity.

Moving a game between internal and external storage must not invalidate:

- Its Content ID.
- Its metadata.
- Its artwork.
- Its library entry.
- Its save-data associations.

Storage providers and locations must be represented through the shared Storage API.

If an external drive is disconnected, its content must remain registered but show an unavailable status.

---

# 11. Emulator Resources

Provide a dedicated section for emulator-related resources.

This is separate from normal ROM importing.

Possible resources include:

- BIOS files.
- Firmware.
- Emulator configuration resources.
- Platform-specific system files.

The UI must discover supported resources from installed emulator integrations.

## 11.1 Resource management

Display:

- Resource type.
- Required platform or emulator.
- Installation status.
- Validation status.
- Version, where applicable.
- Associated emulator.
- Availability.

Support uploading and validating resources through platform services.

Never assume that a file is valid merely because its filename matches an expected BIOS filename.

## 11.2 Validation

Validation must be performed by the relevant emulator integration.

Where possible, support:

- File integrity checks.
- Expected hashes.
- Version checks.
- Required-resource checks.
- Compatibility checks.

Do not distribute copyrighted BIOS or firmware files.

The UI should explain that users must provide resources they are legally entitled to use.

---

# 12. Saves and Backups

Provide a dedicated section for save-data management.

The system should distinguish:

- Game saves.
- Save states.
- Backup copies.
- Emulator-specific save resources.

Features:

- Browse available saves.
- Associate saves with games.
- Display storage location.
- Show backup status.
- Create backups where supported.
- Restore backups with explicit confirmation.
- Export supported save files.
- Identify unassociated save files.

Use the shared Backup API and emulator integrations.

Never manipulate emulator save files while the associated emulator is actively writing to them unless the platform service guarantees safe handling.

---

# 13. Downloads and Updates

Provide a unified view of ongoing platform-managed downloads and updates.

Display:

- Active downloads.
- Queue.
- Progress.
- Transfer speed.
- Estimated remaining time where reliable.
- Download source.
- Destination.
- Result.
- Errors.

Support actions where permitted:

- Pause.
- Resume.
- Cancel.
- Retry.

Use the shared Download Management API.

Do not implement a separate download engine inside Ruya Web.

---

# 14. Application Management

Provide an overview of installed applications and supported integrations.

Use the shared Application Registry.

Display:

- Application name.
- Application type.
- Version.
- Installation status.
- Enabled capabilities.
- Update status.
- Compatibility information where available.

Support permitted actions:

- Launch.
- Install.
- Uninstall.
- Update.
- View details.
- Configure supported settings.

The UI must not assume that every application exposes the same capabilities.

Applications should expose their capabilities through the shared application registration mechanism.

---

# 15. System Management

Provide a comprehensive but understandable view of the Ruya device.

## 15.1 Hardware

Display available information about:

- CPU.
- GPU.
- Memory.
- Storage.
- Network adapters.
- Displays.
- Audio devices.
- Controllers and connected peripherals.
- Temperatures and fan speeds where supported.

Hardware information must be obtained from shared System Management APIs.

Do not assume every GPU vendor exposes identical metrics.

## 15.2 Network and services

Display:

- Network connection status.
- IP addresses.
- Hostname.
- Network interfaces.
- Relevant Ruya services.
- Service health.

Only expose safe, explicitly authorized management operations.

Do not allow arbitrary service commands.

## 15.3 System settings

Provide an extensible settings interface for Ruya OS.

Potential areas:

- Device name.
- Display configuration.
- Audio configuration.
- Controller configuration.
- Storage preferences.
- Network configuration.
- Power settings.
- Automatic updates.
- Web management settings.

Only implement settings supported by shared platform services.

## 15.4 Logs and diagnostics

Provide:

- System logs.
- Service logs.
- Import logs.
- Application logs where exposed.
- Error history.
- Diagnostic information.

Support filtering by:

- Time.
- Severity.
- Service.
- Component.

Allow exporting diagnostic reports.

Sensitive information, tokens and credentials must be redacted.

---

# 16. Users, Authentication and Permissions

Ruya Web must use the shared Ruya identity and authorization architecture.

Do not implement a separate user database or authentication system.

## 16.1 Authentication

Use the platform's local authentication mechanism.

The user must authenticate before accessing management functionality.

Support secure session handling and explicit logout.

## 16.2 Authorization

Enforce permissions on the backend.

Potential permission groups:

- View system information.
- View content.
- Upload content.
- Import content.
- Modify metadata.
- Manage storage.
- Manage emulator resources.
- Manage backups.
- Manage applications.
- Modify system settings.
- Manage users and permissions.

The final permission model must align with the shared Ruya Platform authorization system.

## 16.3 Sensitive operations

Require explicit confirmation for destructive or high-impact operations, including:

- Deleting content files.
- Formatting or reconfiguring storage.
- Restoring backups.
- Uninstalling applications.
- Resetting configuration.
- Changing security settings.

Confirmation dialogs must explain what will happen.

---

# 17. Shared Platform API Requirements

Ruya Web is a consumer of shared platform capabilities.

The following API domains are required. Reuse existing APIs and contracts wherever possible.

| API domain | Responsibility |
|---|---|
| Content API | Content Registry and content metadata |
| Storage API | Storage devices, providers and locations |
| Import API | Upload and import workflows |
| Metadata API | Metadata and artwork |
| Backup API | Saves and backups |
| Search API | Search across managed content |
| Collection API | Content organization |
| Application API | Application Registry and capabilities |
| Download API | Download and update management |
| System API | Hardware and system information |
| Settings API | Ruya configuration |
| Notification API | System events and notifications |
| Authorization API | Identity, sessions and permissions |
| Diagnostics API | Logs and diagnostic reports |

Illustrative endpoint structure:

```text
/api/v1/content
/api/v1/content/{id}
/api/v1/content/{id}/assets
/api/v1/content/{id}/metadata

/api/v1/storage
/api/v1/storage/volumes
/api/v1/storage/locations

/api/v1/imports
/api/v1/imports/{id}
/api/v1/imports/{id}/files

/api/v1/collections
/api/v1/collections/{id}

/api/v1/backups
/api/v1/applications
/api/v1/downloads
/api/v1/system
/api/v1/settings
/api/v1/events
```

These routes are examples, not permission to create duplicate or conflicting APIs.

Before implementing endpoints, inspect the existing Ruya Platform API and document the final contracts.

## 17.1 API consistency

All APIs must use consistent:

- Naming conventions.
- Resource identifiers.
- Pagination.
- Filtering.
- Sorting.
- Error structures.
- Authentication.
- Authorization.
- Versioning.
- Event schemas.

## 17.2 Machine-readable contracts

Provide:

- OpenAPI specifications.
- JSON Schemas.
- Event schemas.
- Permission definitions.
- Example requests.
- Example responses.
- Error documentation.

These contracts are mandatory deliverables.

---

# 18. Events and Real-Time Updates

Ruya Web must subscribe to shared platform events.

Examples:

```text
content.import.started
content.import.progress
content.import.completed
content.import.failed

content.availability.changed

storage.device.connected
storage.device.disconnected
storage.capacity.changed

download.started
download.progress
download.completed
download.failed

application.installed
application.updated
application.uninstalled

system.warning
system.service.status_changed
```

The exact event names and schemas must be defined centrally.

Every event should contain sufficient information to identify:

- Event ID.
- Event type.
- Schema version.
- Device ID.
- Timestamp.
- Resource ID where applicable.
- Structured payload.

The UI must handle:

- Reconnection.
- Duplicate events.
- Missing events.
- Event ordering.
- Full state refresh after reconnecting.

The frontend must never treat an event as authoritative if the corresponding resource state cannot be verified.

---

# 19. AI-First Architecture

Ruya OS is designed with AI-assisted software development and future AI agents in mind.

Ruya Web must follow the same principle.

The management capabilities must be exposed through structured, documented platform APIs.

Potential future AI actions:

- Import all SNES ROMs from a selected folder.
- Find games without artwork.
- Identify duplicate games.
- Find games without a compatible emulator.
- Move rarely played games to external storage.
- Find save files without an associated game.
- Identify storage devices with insufficient capacity.

AI agents must not receive unrestricted filesystem access.

Every action must use the same authorization, validation and confirmation mechanisms as normal UI operations.

Destructive operations must require explicit authorization.

The Web UI should not be the only place where a management operation can be performed.

---

# 20. Initial Release Scope

Do not attempt to implement every possible management feature in the first release.

Build a useful, complete foundation.

## Phase 1 — Web foundation

- Ruya Web application structure.
- Ruya Design System integration.
- Navigation and layout.
- Local HTTPS access.
- Local-only network enforcement.
- Authentication.
- Session management.
- Shared Platform API integration.
- Dashboard.
- Error and notification handling.

## Phase 2 — Content management

- Game Library.
- Game details.
- Search and filtering.
- Content Registry integration.
- Metadata editing.
- Artwork management.
- Content availability status.

## Phase 3 — Import management

- Browser uploads.
- Multiple uploads.
- Upload queue and progress.
- Import Pipeline integration.
- ROM identification.
- Duplicate detection.
- Archive handling where supported.
- Import history.
- Failed import recovery.

## Phase 4 — Storage and emulator resources

- Storage overview.
- Storage device details.
- Content location management.
- External drive availability.
- Emulator resource management.
- BIOS validation.

## Phase 5 — System administration

- Download management.
- Application management.
- Hardware information.
- System settings.
- Logs and diagnostics.
- Saves and backups.

Features should be implemented in dependency order. Do not create placeholder functionality that appears operational but has no working backend.

---

# 21. Companion Integration

Ruya Web and Ruya Companion must complement one another.

They should share:

- Platform APIs.
- Content identifiers.
- Application identifiers.
- Device identity.
- Authorization model.
- Event schemas.
- Design tokens and common components where appropriate.

However, they have different responsibilities.

| Capability | Companion | Web |
|---|---|---|
| Device monitoring | Yes | Yes |
| Remote control | Yes | No requirement |
| Game library | Browse | Full management |
| Launch games | Yes | Yes, if supported |
| ROM uploads | Not initial scope | Yes |
| Bulk imports | No | Yes |
| Artwork management | Basic | Full |
| Storage management | Basic | Full |
| BIOS management | Limited | Full |
| Saves and backups | Basic | Full |
| System settings | Selected | Comprehensive |
| Logs and diagnostics | Basic | Full |
| Remote access | Optional | Never |

Ruya Web must not inherit Companion's remote connectivity.

---

# 22. Testing and Quality Requirements

The implementation must include automated tests.

## 22.1 Frontend

Test:

- Navigation.
- Authentication states.
- Permission-based UI.
- Upload workflows.
- Import progress.
- Error handling.
- Search and filtering.
- Responsive behavior.
- Real-time updates.

## 22.2 Backend and integration

Test:

- API authentication.
- Authorization.
- Local-only network enforcement.
- CSRF protection.
- Origin validation.
- DNS rebinding protection.
- Upload validation.
- Upload size limits.
- Archive safety.
- Import cancellation.
- Duplicate detection.
- Storage disconnection.
- Event reconnection.
- Session revocation.

## 22.3 Security testing

Explicitly verify that:

- Ruya Web cannot be reached through the remote-access gateway.
- Management endpoints cannot be accessed from public interfaces.
- A remote Companion session cannot access Ruya Web.
- Unauthorized LAN devices cannot access management functionality.
- A user without permissions cannot perform privileged operations.
- Malicious archive files cannot escape the import destination.
- Uploads cannot overwrite arbitrary system files.
- User-controlled paths cannot be used for arbitrary filesystem access.

## 22.4 Hardware testing

Test on representative Ruya hardware with:

- AMD GPU.
- NVIDIA GPU.
- Intel GPU.
- Internal storage.
- External USB storage.
- Disconnected and reconnected storage.
- Different browser sizes and devices.

Do not assume all hardware-specific metrics are available.

---

# 23. Documentation Requirements

Documentation is part of the implementation, not a later optional task.

Create or update:

1. Ruya Web architecture.
2. Frontend development guide.
3. Backend integration guide.
4. API integration documentation.
5. Authentication and security documentation.
6. Local network access documentation.
7. Content import workflow.
8. Storage management integration.
9. Design System usage.
10. Testing and troubleshooting.
11. AI development guide.

Document architectural decisions and important trade-offs.

Update the documentation whenever implementation changes the architecture or API contracts.

---

# 24. Implementation Instructions for Claude

Before writing code:

1. Inspect the complete existing Ruya OS repository structure.
2. Read existing architecture documentation.
3. Identify the existing Platform API and shared services.
4. Identify the existing Design System.
5. Identify existing authentication, identity and authorization mechanisms.
6. Identify the existing Content Registry, Storage and Import implementations, if any.
7. Identify existing service deployment and network configuration.
8. Produce a short gap analysis against this specification.

Then prepare an implementation plan.

The plan must identify:

- Existing components that can be reused.
- Missing components.
- New modules required.
- API dependencies.
- Security dependencies.
- Implementation order.
- Testing requirements.

After that, implement the work in logical, testable stages.

## Non-negotiable development rules

- Do not create a parallel architecture.
- Do not duplicate existing services.
- Do not introduce unnecessary dependencies.
- Do not use mock data as a substitute for actual functionality in production.
- Do not create non-functional placeholder controls.
- Do not leave TODOs or temporary hacks.
- Do not bypass existing security mechanisms.
- Do not directly manipulate files or databases from the frontend.
- Do not expose internal system operations through arbitrary commands.
- Do not make Ruya Web dependent on external cloud services.
- Do not make Ruya Web remotely accessible.
- Do not silently change existing platform contracts.
- Do not break existing Ruya TV or Companion functionality.

If a required platform capability does not exist, implement it in the correct shared service or document the dependency and propose the required change. Do not hide missing functionality behind a Web-specific workaround.

## Definition of Done

Ruya Web is considered complete for its initial release when:

- It is installed and served as part of Ruya OS.
- It is accessible through the local network using HTTPS.
- It cannot be accessed through public or remote-access infrastructure.
- Authentication and backend authorization work correctly.
- It uses the shared Ruya Design System.
- It uses shared Platform APIs.
- Users can browse and manage registered games.
- Users can upload and import supported ROM files.
- Import progress and errors are visible.
- Users can manage artwork and metadata.
- Users can inspect storage devices and content availability.
- Users can manage supported emulator resources.
- The UI handles disconnected storage and failed imports correctly.
- Automated tests cover the critical workflows and security boundaries.
- API contracts and documentation are complete.
- Existing Ruya OS functionality remains intact.

---

# 25. Final Architectural Direction

Ruya Web is the central local administration interface of Ruya OS.

It is not a separate product with its own content database, import engine or system-management backend.

It is one of several interfaces built on top of a common Ruya Platform.

The long-term architecture should allow the same management capabilities to be used by:

- Ruya Web.
- Ruya Companion.
- Ruya TV.
- Native Ruya applications.
- Authorized third-party applications.
- Future AI agents.

The most important implementation decision is to keep the platform capabilities independent of the interface that uses them.

**Build the management platform once. Let every Ruya interface use it.**