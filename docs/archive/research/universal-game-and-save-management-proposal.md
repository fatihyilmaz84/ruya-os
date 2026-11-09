# Ruya OS — Universal Game & Save Management System

**Technical Architecture & Product Specification**

| Property | Value |
|---|---|
| Project | Ruya OS |
| Component | Core OS Services |
| Version | 2.0 |
| Status | Proposed — Not Implemented |
| Priority | Foundational |
| Target OS | Linux |
| Architecture | Modular, platform-independent |
| Connectivity | Local-first, optional cloud services |

---

# 1. Vision and Objectives

Ruya OS must provide a unified, operating-system-level system for managing games, installations, game files and saved game data.

The system must work independently of how a game is executed.

Supported game execution environments include:

- Retro game emulators.
- Console emulators.
- Windows games running through Proton.
- Windows games running through Wine.
- Native Linux games.
- Steam games.
- Heroic Launcher games.
- Lutris games.
- Games launched directly through Ruya OS.
- Future launchers and execution environments.

Users should not need to understand where individual games store their files, how different emulators organize their installations or where Windows games store their save data.

Ruya OS handles these differences.

## 1.1 Core principles

1. **Centralized game ownership:** Ruya OS maintains the authoritative game library.
2. **Universal save management:** All supported games use the same Save Management infrastructure.
3. **Launcher independence:** Games must not become tied to a particular launcher.
4. **Emulator independence:** Emulators must not own the canonical game library.
5. **Platform awareness:** The system understands the different storage requirements of gaming platforms.
6. **Non-destructive operation:** Original game files and saves must be protected.
7. **Data integrity:** Imports, backups, restores and relocations must be reliable.
8. **Local-first:** Core functionality works without an internet connection.
9. **Interchangeability:** Users can change launchers, emulators or compatibility layers without unnecessarily losing their games or saves.
10. **Extensibility:** New platforms, launchers, emulators and save formats can be integrated without redesigning the core.
11. **User ownership:** Users retain control over their games and saved progress.
12. **Single source of truth:** The Ruya OS services, rather than individual applications, maintain the authoritative metadata and storage records.

# 2. System Architecture

## 2.1 High-level architecture

Ruya OS provides a set of centralized services.

### Core services

**Game Management**
- Game Library Service
- Game Storage Service
- Game Installation Manager
- Game Metadata Service
- Game Asset Manager

**Save Management**
- Universal Save Manager
- Save Discovery Service
- Save Profile Manager
- Save Backup Service
- Save Version Manager
- Save Synchronization Service
- Save Compatibility Manager

**Integration**
- Emulator Integration Manager
- Launcher Integration Manager
- Runtime Integration Manager
- Application Permission Manager

**Infrastructure**
- Storage Location Manager
- Filesystem Monitoring Service
- Operation Manager
- Event Notification Service
- Database and Recovery Service

## 2.2 Application architecture

All applications must communicate with the same core services.

Applications include:

- Ruya Frontend.
- RPCS3.
- PCSX2.
- Dolphin.
- RetroArch.
- Xemu.
- Steam.
- Heroic.
- Lutris.
- Native Linux games.
- Future emulators and launchers.

The frontend must not maintain a separate game library or save database.

Likewise, an emulator or launcher must not become the authoritative owner of a game installation or save.

## 2.3 Responsibility boundaries

### Ruya OS responsibilities

Ruya OS owns:

- Game registration.
- Game identification.
- Canonical game storage.
- Installation records.
- Game metadata.
- Artwork references.
- Game asset relationships.
- Save registration.
- Save location tracking.
- Save backups.
- Save version history.
- Save restoration.
- Save synchronization.
- Storage management.
- Access permissions.
- Data integrity.
- Operation recovery.

### External application responsibilities

Emulators and launchers remain responsible for:

- Executing games.
- Managing their runtime environments.
- Providing emulator-specific settings.
- Managing runtime-generated files.
- Implementing platform-specific save formats.
- Reporting their storage requirements.
- Providing information about game and save locations.
- Communicating when a game session starts or ends.

Applications must use Ruya OS services for centralized storage wherever integration is supported.

# 3. Universal Game Library

## 3.1 General concept

The Game Library is the central registry of all games known to Ruya OS.

A game is a logical entity and must be independent of:

- Its physical file location.
- Its installation format.
- Its launcher.
- Its emulator.
- Its runtime environment.
- Its compatibility layer.

For example, the same game might have:

- A Steam installation.
- A Heroic installation.
- A standalone Windows installation.
- A native Linux installation.

These should be represented as related installations of the same logical game when identification and compatibility can be established.

The user should not automatically receive duplicate library entries just because a game is installed through different launchers.

## 3.2 Game data model

### Game

Represents the logical game.

Required properties:

| Property | Description |
|---|---|
| game_id | Unique Ruya OS identifier |
| title | Display title |
| platform_id | Gaming platform |
| external_ids | Steam, IGDB or other identifiers |
| serial | Platform-specific game identifier |
| region | Region, when applicable |
| developer | Developer |
| publisher | Publisher |
| release_date | Release date |
| description | Game description |
| artwork | Artwork references |
| metadata | Additional metadata |
| created_at | Registration timestamp |
| updated_at | Last update |

External identifiers must be stored with their provider name and must not be treated as globally unique across providers.

### Game Installation

Represents an actual installation of a game.

A logical game can have multiple installations.

Properties:

- installation_id
- game_id
- installation_type
- platform_id
- launcher_id
- runtime_id
- compatibility_layer
- storage_location_id
- installation_path
- version
- region
- installation_status
- file_manifest
- integrity_information
- source
- created_at
- updated_at

Installation types must be extensible.

Initial types:

- rom_file
- disc_image
- game_directory
- installed_package
- multi_disc
- native_application
- windows_application
- emulator_managed_installation

### Game Asset

Represents files associated with a game.

Examples:

- Main game files.
- Disc images.
- ROM files.
- Firmware dependencies.
- BIOS dependencies.
- Updates.
- DLC.
- License files.
- Additional required files.

Properties:

- asset_id
- game_id
- installation_id
- asset_type
- file_path
- storage_location_id
- size
- checksum
- version
- dependencies

Relationships must support base games, updates, DLC and additional content.

## 3.3 Game identification

Ruya OS must not rely exclusively on filenames.

Identification should use a combination of:

1. Platform-specific identifiers.
2. Launcher identifiers.
3. Game serial numbers.
4. Metadata providers.
5. File signatures.
6. Checksums.
7. Directory structures.
8. User confirmation.

Examples:

- Steam App ID.
- PlayStation serial number.
- IGDB identifier.
- Game-specific executable information.
- ROM database identifiers.

Identification confidence must be recorded.

If Ruya OS cannot reliably identify a game, it must allow manual identification.

## 3.4 Multiple installations

A game may have several installations.

Example:

- The Witcher 3 — Steam.
- The Witcher 3 — GOG/Heroic.
- The Witcher 3 — Standalone.
- The Witcher 3 — Native Linux, if available.

Each installation must have its own:

- Physical location.
- Launcher association.
- Runtime configuration.
- Version information.
- Installation status.

The user must be able to choose a preferred installation.

Different installations may share a save profile only when explicitly configured and compatible.

# 4. Universal Game Storage Service

## 4.1 Storage ownership

Ruya OS determines where canonical game files are stored.

Applications must request access through the Game Storage API rather than independently choosing their canonical storage locations.

The physical storage layout is an implementation detail.

## 4.2 Logical storage structure

An illustrative layout:

```text
RuyaStorage/
│
├── games/
│   ├── nes/
│   ├── snes/
│   ├── genesis/
│   ├── ps1/
│   ├── ps2/
│   ├── ps3/
│   ├── gamecube/
│   ├── wii/
│   ├── xbox/
│   └── native/
│
├── saves/
│
├── backups/
│
├── metadata/
│
├── artwork/
│
├── staging/
│
└── temporary/
```

This is a logical example. The implementation must support configurable storage roots and multiple physical drives.

## 4.3 Storage location management

Ruya OS must support:

- Internal SSDs.
- Secondary internal drives.
- External USB drives.
- Multiple partitions.
- Removable storage.
- Network storage where supported.

Users must be able to assign storage locations to different purposes.

For example:

- SSD for frequently played games.
- HDD for game archives.
- SSD for active game saves.
- External drive for backups.

Storage locations must have unique identifiers independent of their mount paths.

A drive mounted under a different path must not cause all its game registrations to become invalid.

## 4.4 Game importing

Supported sources:

- Individual files.
- Directories.
- External drives.
- Removable media.
- Mounted network storage.
- Supported archives.
- Existing launcher installations.

Import workflow:

1. Application requests import.
2. Ruya OS inspects the source.
3. Determines probable platform and format.
4. Extracts available metadata.
5. Calculates checksums.
6. Checks for duplicates.
7. Determines installation type.
8. Determines destination storage.
9. Checks available capacity.
10. Copies or moves data.
11. Verifies the imported content.
12. Registers the game and installation.
13. Makes it available to compatible applications.

Import must be transactional.

Incomplete imports must not appear as usable installations.

## 4.5 Import modes

Support:

- Copy: Preserve original source.
- Move: Relocate source after successful verification.
- Register in place: Manage an existing installation without copying.
- Reference: Register an external location without claiming ownership of the physical files.

The frontend must clearly indicate which mode is used.

## 4.6 Duplicate handling

Distinguish between:

- Identical files.
- Different regional releases.
- Different revisions.
- Different game versions.
- Multiple installations.
- Different formats of the same game.

Users must be able to keep multiple versions and regions.

Never automatically merge two installations based only on matching titles.

## 4.7 Archive handling

Support common archive formats where appropriate.

Requirements:

- Inspect before extraction.
- Prevent path traversal.
- Protect against archive bombs.
- Enforce configurable extraction limits.
- Preserve directory structures.
- Verify extracted files.
- Allow retaining the original archive.

# 5. Game Storage API

The Game Storage API is the standard interface for accessing the centralized library.

Required operations:

```text
GameStorage

getGame(gameId)
listGames(platformId)
searchGames(query)
getInstallation(installationId)
getGameAssets(gameId)

importGame(source, options)
registerGame(source, metadata)
removeGame(gameId)
removeInstallation(installationId)

requestGameAccess(installationId, applicationId)
releaseGameAccess(accessId)

getAvailablePlatforms()
getStorageInformation()
```

## 5.1 Access mechanisms

The API must support:

- Read-only access.
- Explicit writable access.
- Temporary working directories.
- Emulator-compatible filesystem paths.
- Multiple concurrent read operations.
- Exclusive access when necessary.

Canonical game files should be read-only for normal execution.

Writable operations should use isolated working copies or copy-on-write mechanisms where practical.

The service must not require copying entire games just to launch them.

## 5.2 Access leases

Every access request must create an access lease.

A lease should contain:

- access_id
- application_id
- game_id
- installation_id
- access_mode
- granted_path
- creation_time
- expiration_policy
- session_id

Leases must be released explicitly or cleaned up safely after application termination.

The service must detect stale leases after crashes or reboots.

# 6. Universal Save Management System

## 6.1 Purpose

The Universal Save Manager is a first-class Ruya OS service.

It must manage saved game data for every supported gaming environment.

This includes:

### Retro games
- NES.
- SNES.
- Sega Genesis.
- Game Boy.
- Game Boy Advance.
- Other ROM-based systems.

### Console emulation
- PlayStation.
- PlayStation 2.
- PlayStation 3.
- GameCube.
- Wii.
- Xbox.
- Other supported consoles.

### Windows games
- Proton.
- Wine.
- Steam.
- Heroic.
- Lutris.
- Standalone Windows games.

### Native Linux games
- Native Steam games.
- Standalone Linux games.
- Other native game launchers.

The save manager must not assume that all games use the same save format or directory structure.

## 6.2 Core responsibilities

The Save Manager owns:

- Save registration.
- Save location tracking.
- Save discovery.
- Save access.
- Save backups.
- Save snapshots.
- Save restoration.
- Save version history.
- Save compatibility information.
- Save import and export.
- Save synchronization.
- Save conflict detection.
- Save integrity verification.

## 6.3 Save data model

### Save Profile

Represents a logical save environment for a user and game.

Properties:

- save_profile_id
- user_id
- game_id
- name
- compatibility_group
- created_at
- updated_at

A game may have multiple profiles.

Examples:

- Main playthrough.
- Alternate playthrough.
- User 1.
- User 2.
- Separate save environments.

### Save Artifact

Represents a specific saved data collection.

Properties:

- save_id
- save_profile_id
- game_id
- platform_id
- installation_id
- save_type
- format
- source_emulator
- source_launcher
- runtime_id
- compatibility
- storage_location_id
- canonical_path
- last_modified
- integrity_status
- created_at
- updated_at

### Save Location

Represents a physical or logical directory or file containing save data.

Properties:

- save_location_id
- save_id
- location_type
- path
- detection_method
- access_method
- ownership
- required_permissions
- monitoring_status
- last_verified

A single save profile may have multiple save locations.

This is necessary for games that split their save data across multiple directories.

### Save Snapshot

Represents an immutable backup.

Properties:

- snapshot_id
- save_id
- created_at
- size
- checksum
- source
- description
- integrity_status
- manifest
- snapshot_type

Snapshots must be immutable.

Restoring a snapshot must never destroy the original snapshot.

# 7. Universal Save Discovery

## 7.1 Purpose

Ruya OS must identify save locations automatically wherever possible.

The discovery system must work across emulators, Windows games and native Linux games.

Three discovery methods must be supported.

### Method A: Known game profiles

Ruya OS maintains a database of known save locations.

Example:

```yaml
game_id: example-game
platform: windows

save_locations:
  - type: directory
    path: "%USERPROFILE%/Documents/My Games/ExampleGame"

  - type: directory
    path: "%APPDATA%/ExampleGame"

detection:
  method: directory
  required: false

backup:
  strategy: directory_snapshot
```

Profiles must be versioned and validated.

They must support multiple possible save locations.

### Method B: Automatic discovery

The system should detect likely save locations by:

- Monitoring game-related filesystem activity.
- Inspecting known save directories.
- Identifying changes during a game session.
- Using game installation information.
- Inspecting runtime environment mappings.
- Comparing filesystem state before and after gameplay.

Automatic detection must not assume every modified file is a save.

The system should assign confidence levels and avoid registering unrelated files as saves.

### Method C: Manual configuration

Users must be able to:

- Select a file.
- Select a directory.
- Add multiple save locations.
- Exclude specific files.
- Define backup rules.
- Define whether a location is writable.
- Associate the location with a game and save profile.

Manual configuration must always remain available.

## 7.2 Discovery confidence

Use:

- `verified`: Known and validated save location.
- `high`: Strong evidence that the location contains saves.
- `probable`: Likely save location.
- `unverified`: User-defined but not validated.
- `unknown`: Insufficient information.

Do not automatically move or delete files based on uncertain discovery.

## 7.3 Community save profile database

Ruya OS should support a community-maintained database of save profiles.

Profiles can contain:

- Game identifiers.
- Known save paths.
- File patterns.
- Runtime requirements.
- Save format.
- Multiple save locations.
- Backup strategies.
- Compatibility information.
- Known restrictions.

Profiles must be signed or validated before distribution.

Updates must not overwrite user-defined configuration without consent.

Core save management must continue working if the community database is unavailable.

# 8. Windows Save Integration: Proton and Wine

## 8.1 General requirements

Ruya OS must support Windows games running through:

- Steam Proton.
- Proton GE.
- Wine.
- Lutris Wine environments.
- Heroic Wine environments.
- Other compatible Windows runtime environments.

The Save Manager must understand Windows directory conventions and their mapping into Linux filesystems.

## 8.2 Common Windows save locations

Support detection of:

```text
%APPDATA%
%LOCALAPPDATA%
%USERPROFILE%
%USERPROFILE%\Documents
%USERPROFILE%\Saved Games
%PROGRAMDATA%
```

Games may also store data in:

- Installation directories.
- Custom directories.
- Registry-backed configuration.
- Launcher-specific directories.
- Game-specific virtual filesystem locations.

Not all of these contain saved progress. Ruya OS must distinguish save data from settings, caches and other application data.

## 8.3 Proton integration

Proton uses Wine prefixes.

Example:

```text
steamapps/
└── compatdata/
    └── GAME_ID/
        └── pfx/
            └── drive_c/
                └── users/
                    └── steamuser/
                        └── Documents/
                            └── My Games/
                                └── GameName/
```

Ruya OS must:

- Discover Proton prefixes.
- Associate prefixes with Steam installations.
- Identify their Windows user directories.
- Resolve Windows paths to Linux paths.
- Discover registered save locations.
- Monitor save changes.
- Back up save data.
- Restore compatible saves.
- Handle prefix recreation.
- Handle multiple prefixes for the same game.

A Proton prefix must not be treated as a game save itself.

It may contain settings, installed dependencies, registry data and other files unrelated to saved progress.

## 8.4 Prefix recreation

When a Proton prefix is deleted or recreated:

- Detect the changed prefix.
- Preserve centrally managed save data.
- Re-establish registered save locations.
- Restore saves only according to the configured policy.
- Never overwrite newer saves without conflict checks.

The system should distinguish between restoring saves and restoring an entire Proton prefix.

## 8.5 Wine integration

Wine integration must use the same architecture as Proton.

Wine prefixes should be registered as runtime environments.

A game may use its own prefix or share a prefix with other games.

Ruya OS must track this relationship and avoid assuming one prefix always equals one game.

# 9. Native Linux Game Integration

## 9.1 Supported locations

Support standard XDG locations:

```text
~/.local/share/
~/.config/
~/.local/state/
```

Also support:

- Custom game directories.
- Game installation directories.
- Steam user data.
- Launcher-managed directories.
- Game-specific save directories.

## 9.2 Data classification

The Save Manager must distinguish between:

- Saved progress.
- User configuration.
- Game preferences.
- Cache data.
- Logs.
- Temporary data.
- Shader caches.

Configuration and cache data must not automatically be treated as game saves.

The user may optionally include configuration data in backups.

## 9.3 Native game integration

Where supported, Ruya OS should provide a standard integration library or SDK allowing native games to register save locations directly.

Games that do not integrate with this SDK must still be supported through known profiles, filesystem monitoring or manual configuration.

# 10. Launcher Integration

## 10.1 General requirements

Game and save management must be independent of the launcher.

Initial launcher integrations:

- Steam.
- Heroic.
- Lutris.
- Ruya Launcher.
- Standalone games.

## 10.2 Steam

Steam integration must support:

- Steam App ID identification.
- Installed game discovery.
- Proton compatibility data.
- Native Linux save paths.
- Windows save paths inside Proton prefixes.
- Steam user profiles.
- Steam Cloud status where accessible.
- Steam Cloud conflict detection where accessible.

Ruya OS must not assume Steam Cloud is disabled.

It must avoid competing with Steam's synchronization mechanisms.

## 10.3 Heroic

Support:

- Epic Games installations.
- GOG installations.
- Amazon Games installations where supported.
- Wine and Proton prefixes.
- Launcher-specific game identifiers.
- Game-specific save locations.
- Existing cloud save functionality.

## 10.4 Lutris

Support:

- Game installation identifiers.
- Wine prefixes.
- Custom installation directories.
- Per-game runtime configuration.
- Custom save paths.

## 10.5 Launcher independence

A game installed through one launcher must not become permanently dependent on that launcher for save management.

When a user changes launchers:

- Identify the same logical game.
- Locate its existing save profile.
- Check compatibility.
- Reconnect the save data if appropriate.
- Avoid duplicate save repositories.

Launcher-specific cloud synchronization must remain separately identifiable.

# 11. Emulator Integration

## 11.1 General requirements

Emulators are one category of application integrated into Ruya OS.

They must use the Game Storage and Save Storage APIs.

Initial emulator integrations:

- RPCS3.
- PCSX2.
- Dolphin.
- RetroArch.
- Xemu.
- Other future emulators.

## 11.2 Emulator Adapter Contract

Each emulator adapter must implement a standardized interface.

```text
EmulatorAdapter

getInformation()
getSupportedPlatforms()
getSupportedGameFormats()
getSupportedSaveFormats()

getCapabilities()

discoverGames()
launchGame(gameId)
stopGame(sessionId)

prepareGameAccess(gameId)
releaseGameAccess(accessId)

discoverSaves(gameId)
prepareSaveAccess(gameId)
finalizeSaveAccess(accessId)

getConfiguration(gameId)
updateConfiguration(gameId, settings)

getHealthStatus()
```

Not all emulators support all operations.

Adapters must declare their capabilities explicitly.

Unsupported operations must return structured errors.

## 11.3 Emulator-specific storage

Emulators may require their own directory structures.

The adapter must provide an appropriate managed view of the centralized storage.

Examples:

- RPCS3 virtual hard drive structure.
- PCSX2 memory cards.
- Dolphin memory cards.
- RetroArch save directories.
- Xemu virtual disk and savedata structures.

The adapter must avoid unnecessary duplication.

Where an emulator requires physical files in specific locations, use managed mappings or synchronization mechanisms.

The canonical Ruya OS data must remain protected.

# 12. Save Access and Session Management

## 12.1 Save access lifecycle

1. Application requests save access.
2. Ruya OS identifies the game and save profile.
3. Compatibility is checked.
4. Permissions are checked.
5. Ruya OS grants access.
6. The application accesses the save.
7. Filesystem changes are monitored.
8. Application reports session completion.
9. Ruya OS verifies that writes have finished.
10. Save metadata is updated.
11. A snapshot is created according to backup policy.
12. Access is released.

## 12.2 Save access modes

Support:

- Read-only.
- Read/write.
- Exclusive write.
- Temporary working copy.
- Copy-on-write.
- Managed synchronization.

Writable access must use locking or equivalent coordination.

Two applications must not simultaneously write to the same save artifact unless the adapter explicitly guarantees safe behavior.

## 12.3 Session identification

Each running game session must have:

- session_id
- game_id
- installation_id
- application_id
- runtime_id
- save_profile_id
- access_ids
- started_at
- ended_at
- exit_status

Session information helps the system associate filesystem changes with the correct game.

## 12.4 Unexpected termination

If a game crashes:

- Detect the abnormal termination.
- Identify potentially incomplete writes.
- Preserve existing snapshots.
- Mark affected saves as potentially inconsistent.
- Avoid automatic restoration.
- Attempt safe finalization.
- Notify the user.

A crash must never automatically delete or replace existing save data.

# 13. Save Backup and Version Management

## 13.1 Backup policies

Users must be able to configure backup triggers.

Supported triggers:

- Before launching a game.
- After a game session.
- At game exit.
- Before a restore.
- Before a save migration.
- Before emulator or runtime updates.
- At scheduled intervals.
- On demand.

Users must be able to configure policies globally and per game.

## 13.2 Snapshot creation

Snapshots must:

- Be immutable.
- Include a file manifest.
- Include checksums.
- Record creation timestamps.
- Record their source.
- Record the relevant game and save profile.
- Support incremental storage optimization.

A snapshot must only be marked successful after its data has been verified.

## 13.3 Version history

Users must be able to:

- View historical saves.
- View backup timestamps.
- Compare snapshot sizes.
- Restore an earlier snapshot.
- Export snapshots.
- Delete individual snapshots.
- Configure retention rules.

Snapshots must remain immutable even after restoration.

## 13.4 Restore procedure

1. Select snapshot.
2. Validate snapshot integrity.
3. Validate target compatibility.
4. Create a safety snapshot of current data.
5. Check active application access.
6. Acquire exclusive write access.
7. Restore data into staging.
8. Verify restored data.
9. Replace target data atomically where possible.
10. Release access.
11. Record restoration history.

If restoration fails, the previous save must remain recoverable.

## 13.5 Retention management

Support:

- Maximum snapshots per save.
- Maximum backup storage.
- Retention periods.
- Manual protection of snapshots.
- Automatic cleanup.
- Deduplication.

Never automatically delete the only valid backup.

Never delete snapshots that are currently referenced by an active restore or synchronization operation.

# 14. Save Compatibility and Migration

## 14.1 Compatibility classifications

Use:

- `native`: Directly supported.
- `compatible`: Known to work without conversion.
- `convertible`: Requires supported conversion.
- `restricted`: Subject to platform, account or encryption restrictions.
- `unknown`: Not verified.
- `incompatible`: Known not to work.

Compatibility must be evaluated for the combination of:

- Game.
- Save format.
- Platform.
- Emulator or runtime.
- Game version.
- User profile, where relevant.

## 14.2 Cross-emulator compatibility

Ruya OS must not assume that two emulators share compatible save formats.

Examples:

- Different Genesis emulators may share compatible SRAM files.
- Different PS2 emulators may use different memory card formats.
- RPCS3 saves may contain account-specific restrictions.
- Different Xbox emulators may use incompatible savedata formats.

The system must maintain compatibility information and allow adapter-provided conversion.

## 14.3 Conversion

Conversion must:

- Preserve the original save.
- Use an isolated working copy.
- Verify the output.
- Record the conversion tool and version.
- Record source and destination formats.
- Never overwrite the only valid original.

## 14.4 Save migration

Migration between installations or environments must be explicit.

Examples:

- Steam to Heroic.
- Proton to Wine.
- Wine to Proton.
- One native Linux installation to another.
- One emulator to another.

The system must check compatibility and create a safety snapshot before migration.

# 15. Cloud Synchronization

## 15.1 General concept

Cloud synchronization is an optional extension of the local Save Manager.

Core local functionality must not depend on cloud connectivity.

The architecture must support multiple synchronization providers.

## 15.2 Requirements

Support:

- Local-only saves.
- Cloud backup.
- Cloud synchronization.
- Multiple devices.
- Multiple save profiles.
- Version history.
- Conflict detection.
- Manual conflict resolution.

## 15.3 Conflict detection

Conflicts may occur when:

- A game is played on two devices.
- Steam Cloud modifies a save.
- A local save is newer than a cloud save.
- A game updates its save format.
- Multiple synchronization providers modify the same data.

The system must never blindly overwrite newer or potentially more valuable data.

## 15.4 Conflict resolution

When a conflict occurs:

1. Preserve both versions.
2. Record their timestamps and checksums.
3. Identify their sources.
4. Determine whether automatic merging is safe.
5. Present the user with available versions.
6. Require confirmation when the outcome is uncertain.

Never assume that the newest timestamp always represents the correct save.

## 15.5 Third-party cloud services

Steam Cloud and other launcher-managed cloud services must be treated as separate synchronization authorities.

Ruya OS must avoid competing with them.

Where direct integration is unavailable, Ruya OS should provide backup and conflict protection without pretending to control the external cloud service.

# 16. Special Platform Requirements

## 16.1 RPCS3 / PlayStation 3

Support:

- Disc directories.
- ISO images.
- PKG installations.
- RAP license assets.
- Updates.
- DLC.
- Game serial identification.
- Firmware requirements.
- Virtual hard drive structures.
- Multiple PS3 user profiles.
- Savedata discovery.
- Account-related save restrictions.

The adapter must preserve relevant save metadata and original directory structures.

It must not assume PS3 saves are interchangeable between users.

It must not attempt to bypass encryption or licensing restrictions.

RPCS3 must remain an independent application.

## 16.2 PCSX2 / PlayStation 2

Support:

- Disc images.
- Game identification.
- Memory card files.
- Per-game memory card configuration.
- Memory card backups.
- Save import/export.
- Memory card format conversion where supported.

## 16.3 Dolphin / GameCube and Wii

Support:

- GameCube disc images.
- Wii disc images.
- GameCube memory cards.
- Wii NAND-based saves.
- Game-specific save discovery.
- Save export/import where supported.

## 16.4 RetroArch

Support:

- Core-specific game execution.
- SRAM.
- Save states.
- Memory cards where applicable.
- Per-game save directories.
- Core-specific save formats.

Save states and normal in-game saves must be treated as separate artifact types.

A save state must not be assumed compatible between different cores or emulator versions.

## 16.5 Native and Windows PC games

Support:

- Directory-based saves.
- Individual save files.
- Multiple save locations.
- Registry-backed data where necessary.
- Configuration backups as optional artifacts.
- Game-specific save profiles.
- Runtime-specific location mappings.

# 17. Native Game Integration SDK

Ruya OS should provide an optional SDK for native Linux games and future game developers.

The SDK should allow a game to:

- Register its identity.
- Register save locations.
- Request save access.
- Report save changes.
- Register multiple save profiles.
- Request backup creation.
- Report save format and version.

Games that do not use the SDK must remain supported through discovery and manual configuration.

The SDK must not be required for ordinary game execution.

# 18. Filesystem Monitoring

## 18.1 Purpose

Ruya OS needs to detect changes to managed save locations.

Monitoring must support:

- Native Linux directories.
- Proton prefixes.
- Wine prefixes.
- Emulator save directories.
- Custom save paths.
- Multiple storage locations.

## 18.2 Monitoring requirements

Use filesystem event notifications where available.

Monitoring must handle:

- File creation.
- File modification.
- File deletion.
- File renaming.
- Directory changes.
- Atomic replacement.
- Large batches of changes.

Filesystem events must be treated as notifications rather than proof of completed writes.

The service must verify actual filesystem state before finalizing a backup.

## 18.3 Monitoring limitations

The system must handle:

- Missed filesystem events.
- Watch limits.
- Application crashes.
- Service restarts.
- Disconnected drives.
- Symbolic links.
- Filesystem-specific behavior.

Periodic reconciliation scans must be available as a fallback.

Monitoring must not continuously scan entire game installations.

# 19. Emulator and Launcher Management

## 19.1 Emulator Manager

Responsibilities:

- Register emulators.
- Detect installations.
- Manage emulator versions.
- Register adapters.
- Discover capabilities.
- Configure default emulators.
- Manage per-game emulator selection.
- Monitor emulator health.

## 19.2 Launcher Manager

Responsibilities:

- Register launchers.
- Discover installations.
- Identify games.
- Associate installations with logical games.
- Track launcher identifiers.
- Resolve launcher-specific paths.
- Detect installation changes.
- Report cloud synchronization capabilities.

## 19.3 Runtime Manager

Responsibilities:

- Register Proton versions.
- Register Wine versions.
- Manage runtime environments.
- Discover prefixes.
- Associate prefixes with games.
- Resolve virtual Windows paths.
- Track runtime compatibility.

A runtime environment must not be confused with a game installation.

Multiple games may share a runtime or prefix.

# 20. Security and Permissions

All services must follow the principle of least privilege.

Requirements:

- Application-specific permissions.
- Restricted filesystem access.
- Path validation.
- Symlink validation.
- Archive validation.
- Protection against path traversal.
- Secure operation tracking.
- Access leases.
- Controlled writable access.
- Audit logging for destructive operations.

Applications must not receive unrestricted access to the complete Ruya OS storage repository.

## 20.1 Concurrent access

Game files should support concurrent read access.

Save files require controlled writable access.

The system must prevent conflicting writes unless an adapter explicitly supports them.

## 20.2 Multi-user support

Save profiles must be isolated by OS user.

Users must not accidentally access another user's private saves.

Shared game installations may be supported, but saves must remain separate unless explicitly shared.

# 21. Storage Relocation and Recovery

## 21.1 Relocation

Users must be able to relocate:

- Games.
- Installations.
- Saves.
- Backup repositories.

Relocation workflow:

1. Validate destination.
2. Check available capacity.
3. Acquire appropriate locks.
4. Copy data to staging.
5. Verify checksums.
6. Update database references.
7. Commit the relocation.
8. Remove the original only after successful verification.

## 21.2 Recovery

The system must recover from:

- Power loss.
- Kernel crashes.
- Service crashes.
- Emulator crashes.
- Failed imports.
- Failed restores.
- Interrupted relocation.
- Storage disconnection.
- Insufficient capacity.
- Database interruptions.

Operations must be journaled or otherwise recoverable.

The system must be able to identify incomplete operations after restart.

# 22. API Architecture

## 22.1 Communication

The implementation must support communication between system services and applications.

Possible transports:

- D-Bus.
- Unix domain sockets.
- Local service APIs.

The final transport should be chosen based on the Ruya OS technology stack.

It must not require internet connectivity.

## 22.2 API requirements

- Versioned contracts.
- Consistent error handling.
- Application authentication.
- Permission checks.
- Asynchronous operations.
- Progress reporting.
- Cancellation support.
- Event notifications.
- Backward compatibility.
- Documentation.

## 22.3 Long-running operations

Imports, scanning, backups, restores, relocation and synchronization must execute asynchronously.

Each operation must have:

- operation_id
- operation_type
- status
- progress
- start_time
- completion_time
- error_information

The frontend must be able to retrieve operation status after reconnecting.

## 22.4 Core Game API

```text
GameStorage

getGame()
listGames()
searchGames()
getInstallation()
getGameAssets()

importGame()
registerGame()
removeGame()
removeInstallation()

requestGameAccess()
releaseGameAccess()
```

## 22.5 Core Save API

```text
SaveStorage

discoverSaves()
listSaves()
getSave()

registerSave()
updateSaveLocation()
removeSaveLocation()

requestSaveAccess()
releaseSaveAccess()
finalizeSaveAccess()

createSnapshot()
listSnapshots()
restoreSnapshot()

importSave()
exportSave()

getSaveCompatibility()
synchronizeSave()
```

## 22.6 Core Integration API

```text
IntegrationManager

registerApplication()
registerEmulator()
registerLauncher()
registerRuntime()

getCapabilities()
getApplicationInformation()

startGameSession()
stopGameSession()
getGameSession()

publishEvent()
subscribeToEvents()
```

Final names and method signatures must be defined in the API contract.

# 23. Events and Notifications

The services should publish events.

Examples:

```text
game.import.started
game.import.completed
game.import.failed

game.availability.changed
game.installation.moved
game.installation.removed

save.discovered
save.updated
save.snapshot.created
save.restore.completed
save.restore.failed

save.conflict.detected
save.compatibility.changed
save.location.changed

storage.location.unavailable
storage.capacity.warning

emulator.session.started
emulator.session.ended
emulator.session.crashed

launcher.game.discovered
launcher.installation.changed

runtime.prefix.discovered
runtime.prefix.removed
```

Events must not be the authoritative source of state.

Applications must be able to retrieve the current state after reconnecting.

# 24. Ruya Frontend Integration

The frontend must use the same Game and Save APIs as other applications.

## 24.1 Game library

Users should be able to:

- Browse games by platform.
- Search and filter games.
- View game details.
- View installations.
- Select preferred launchers.
- Select preferred emulators.
- View storage locations.
- Import games.
- Move installations.
- Manage updates and DLC.
- Remove installations.

## 24.2 Save management interface

Every game detail page should provide a Save Management section.

It should display:

- Save profiles.
- Save locations.
- Last modified time.
- Last backup time.
- Backup history.
- Storage size.
- Compatibility status.
- Synchronization status.
- Backup warnings.

Users should be able to:

- Create backups.
- Restore backups.
- Export saves.
- Import saves.
- Manage save profiles.
- Configure backup policies.
- Configure synchronization.
- Remove saves.

## 24.3 Automatic detection interface

When Ruya discovers a possible save location, it should provide a notification.

For example:

"Ruya detected a possible save location for this game."

Users can:

- Confirm.
- Ignore.
- Configure manually.
- Review detected files.

Ruya must not automatically move user data based on uncertain detection.

## 24.4 Storage management interface

Users must be able to see:

- Total game storage.
- Total save storage.
- Total backup storage.
- Storage per platform.
- Storage per game.
- Storage per physical drive.
- Unavailable storage locations.
- Incomplete operations.

# 25. Performance Requirements

The architecture must be optimized for gaming workloads.

Requirements:

- Minimal overhead when launching games.
- No unnecessary copying of large game installations.
- Direct filesystem access where safe.
- Efficient metadata queries.
- Incremental game scanning.
- Asynchronous checksum calculation.
- Efficient snapshot creation.
- No continuous full-library scanning.
- Cached artwork and metadata.
- Efficient filesystem monitoring.
- Minimal memory consumption by background services.
- No blocking of the game execution process during ordinary save management.

Backups should be scheduled to avoid interfering with active gameplay.

# 26. Edge Cases and Required Behavior

| Scenario | Expected behavior |
|---|---|
| Game imported twice | Detect duplicate and offer appropriate action |
| Same game in different regions | Preserve separate installations |
| Game installed in multiple launchers | Associate installations with one logical game when verified |
| Game renamed externally | Detect missing path and offer relinking |
| External drive disconnected | Keep library entry and mark unavailable |
| Proton prefix recreated | Reconnect managed saves or offer restoration |
| Game uses multiple save directories | Register all relevant locations |
| Game has no identifiable save path | Allow manual configuration |
| Save modified during backup | Retry or abort snapshot |
| Emulator crashes during save | Protect snapshots and mark current data uncertain |
| Two applications access the same save | Prevent conflicting writes |
| User changes emulator | Check save compatibility |
| User changes launcher | Reconnect compatible save profile |
| Game updates save format | Preserve historical snapshots |
| Steam Cloud modifies save | Detect conflict where possible |
| Cloud synchronization fails | Preserve local save and retry |
| Storage fills during import | Abort safely and clean staging data |
| Storage fills during backup | Preserve original and previous snapshots |
| Power loss during relocation | Recover or roll back |
| Corrupted game file | Report integrity failure |
| Missing firmware | Explain dependency and prevent invalid launch |
| Multiple OS users | Keep save profiles isolated |
| Encrypted save | Preserve original and report restrictions |
| Duplicate save import | Detect possible duplicate and ask |
| Unsupported file type | Do not silently import |
| Emulator uninstalled | Preserve games and saves |
| Launcher uninstalled | Preserve registrations and data |
| Emulator updated | Do not automatically migrate saves |
| API service restarts | Recover operations and access leases |
| Network storage disappears | Preserve metadata and report unavailable data |
| Read-only storage | Allow reads and reject writes clearly |
| Case-sensitive filenames | Preserve original filenames |
| Symlink encountered | Resolve safely and prevent unauthorized access |
| Filesystem monitoring misses events | Reconcile through periodic scanning |
| Game writes to installation directory | Support registered writable save locations |
| Save is stored in registry | Support optional registry-backed backup |
| Game stores progress server-side | Explain that local backup is unavailable |
| Game has multiple profiles | Keep profile data separate |
| Save conversion fails | Preserve original and report failure |
| Game launched outside Ruya | Detect changes when possible without claiming guaranteed monitoring |
| Game has anti-cheat restrictions | Respect runtime and filesystem restrictions |
| Save file is locked | Wait, retry or report the lock |
| Two installations share a save | Require explicit compatible sharing |
| Game is moved while running | Prevent relocation until access is released |
| Backup repository becomes unavailable | Preserve local save and report failure |

# 27. Testing Requirements

Testing must cover all core services independently and in combination.

## 27.1 Game Storage

- Import individual ROM files.
- Import directory-based games.
- Import disc images.
- Import installed packages.
- Register existing installations.
- Detect duplicates.
- Support multiple installations.
- Relocate installations.
- Handle missing storage.
- Recover interrupted imports.
- Verify file integrity.

## 27.2 Save Management

- Register save directories.
- Register individual save files.
- Discover known save locations.
- Discover unknown save locations.
- Create snapshots.
- Restore snapshots.
- Import and export saves.
- Detect changes.
- Prevent conflicting writes.
- Recover after crashes.
- Maintain multiple save profiles.
- Handle multiple save locations.

## 27.3 Windows and Proton

- Discover Steam Proton prefixes.
- Discover Wine prefixes.
- Resolve Windows environment variables.
- Discover known game save locations.
- Handle recreated prefixes.
- Handle multiple games sharing a prefix.
- Detect save changes.
- Restore saves after runtime recreation.

## 27.4 Native Linux

- Discover XDG directories.
- Support custom save locations.
- Separate configuration from progress.
- Handle custom installation paths.
- Handle standalone games.

## 27.5 Launchers

- Steam integration.
- Heroic integration.
- Lutris integration.
- Ruya Launcher integration.
- Standalone game integration.
- Duplicate installation identification.
- Launcher removal and recovery.

## 27.6 Reliability

- Power loss.
- Kernel crash.
- Application crash.
- Emulator crash.
- Storage disconnection.
- Full disk.
- Failed synchronization.
- Concurrent access.
- Database recovery.
- Interrupted relocation.
- Interrupted restore.

# 28. Implementation Roadmap

Implementation must proceed in phases.

Do not implement emulator-specific features before the underlying storage architecture is established.

## Phase 1 — Core Infrastructure

Implement:

- Core database models.
- Game entity.
- Game installation entity.
- Game asset entity.
- Save profile entity.
- Save artifact entity.
- Save location entity.
- Save snapshot entity.
- Storage location manager.
- Game Storage Service.
- Universal Save Storage Service.
- Basic filesystem operations.
- Integrity verification.

**Deliverable:** Ruya OS can centrally register, store and manage games and saves without any emulator integration.

## Phase 2 — API and Security

Implement:

- Versioned API contracts.
- Application authentication.
- Permissions.
- Access leases.
- File locking.
- Operation management.
- Event notifications.
- Recovery mechanisms.
- Filesystem monitoring.

**Deliverable:** Applications can safely interact with the centralized storage system.

## Phase 3 — Universal Save Management

Implement:

- Save discovery.
- Known game profiles.
- Manual save registration.
- Automatic discovery.
- Snapshot creation.
- Backup policies.
- Save restoration.
- Save history.
- Save compatibility tracking.
- Save import/export.

**Deliverable:** Ruya OS can manage saves independently of emulators and launchers.

## Phase 4 — Windows and Native Linux Integration

Implement:

- Steam integration.
- Proton prefix discovery.
- Wine prefix discovery.
- Windows save path resolution.
- Native Linux save discovery.
- XDG integration.
- Heroic integration.
- Lutris integration.
- Filesystem monitoring.
- Launcher-independent game identification.

**Deliverable:** Windows and Linux games can use the Universal Save Manager.

## Phase 5 — Emulator Integration

Start with RPCS3.

Implement:

- RPCS3 adapter.
- PS3 game discovery.
- PS3 installation management.
- Firmware and dependency checks.
- PKG and RAP asset management.
- Game launching.
- Save discovery.
- Save access.
- Save backups.
- Crash handling.

Then integrate:

- PCSX2.
- Dolphin.
- RetroArch.
- Xemu.
- Other emulators.

**Deliverable:** Emulators use the same game and save infrastructure as PC games.

## Phase 6 — Advanced Features

Implement:

- Cloud synchronization.
- Conflict resolution.
- Cross-device synchronization.
- Save migration.
- Save conversion.
- Advanced deduplication.
- Multiple backup repositories.
- Advanced storage policies.
- Community game save profiles.
- Native game SDK.

**Deliverable:** A complete universal game and save management platform.

# 29. Non-Goals

The initial implementation must not attempt to:

- Rewrite emulators.
- Modify emulator source code.
- Replace Steam Cloud.
- Replace other launcher cloud services.
- Guarantee universal save-format compatibility.
- Circumvent platform encryption or licensing.
- Require cloud connectivity.
- Require internet access for basic storage.
- Automatically convert unsupported save formats.
- Automatically delete user data to reclaim storage.
- Force every game to use the Ruya OS SDK.
- Copy every game installation into a new directory unnecessarily.
- Assume all game progress is stored locally.

# 30. Architectural Definition of Done

The foundational architecture is complete when:

1. Ruya OS has one authoritative game library.
2. Ruya OS has one authoritative game storage service.
3. Ruya OS has one universal save management service.
4. All services expose documented, versioned APIs.
5. The frontend uses the same APIs as external applications.
6. Emulators can access games without owning the canonical library.
7. Windows games can use Proton/Wine save integration.
8. Native Linux games can use save integration.
9. Launchers are independent of the save repository.
10. Saves can be backed up and restored.
11. Multiple installations can be associated with compatible save profiles.
12. Data integrity and recovery mechanisms are implemented.
13. Concurrent access is controlled.
14. Applications receive restricted access.
15. The architecture supports additional platforms without redesigning the core.

# 31. Final Architectural Principles

The following principles are mandatory throughout development.

**1. Ruya OS owns the library.**

Games, installations, metadata and assets are centrally managed.

**2. Ruya OS owns saved progress.**

The Save Manager is independent of emulators, launchers and runtime environments.

**3. Physical storage is abstracted.**

Applications request access through APIs and must not depend on canonical filesystem locations.

**4. Adapters handle platform differences.**

RPCS3, Proton, Wine, Steam, Dolphin and other applications have different requirements. Those differences belong in their respective adapters.

**5. Original data is protected.**

Imports, backups, migrations, conversions and restores must be recoverable and non-destructive.

**6. Compatibility must be verified.**

The existence of a centralized save does not guarantee that every emulator or game version can use it.

**7. The system is local-first.**

Core game and save management must work without cloud services.

**8. The architecture must remain extensible.**

New launchers, emulators, platforms and game execution environments must be integrable without changing the foundational storage architecture.

---

**Final vision:**

Ruya OS provides one universal game library and one universal save management system.

It does not matter whether a user plays a Sega Genesis game through an emulator, a PlayStation 3 game through RPCS3, a Windows game through Proton, or a native Linux game.

The game library, saved progress, backups and storage management belong to Ruya OS.

The applications that execute games are replaceable. The user's collection and progress are not.