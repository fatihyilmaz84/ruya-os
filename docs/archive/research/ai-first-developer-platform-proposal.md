# Ruya OS — AI-First Developer Platform
## Technical Implementation Specification

**Project:** Ruya OS  
**Component:** Ruya AI Developer Platform  
**Document type:** Technical implementation specification  
**Status:** Proposed — not yet implemented  
**Target implementer:** Claude Code  
**Priority:** Foundational platform component

---

# 1. Project vision

Ruya OS must be designed as an AI-first software development platform.

The fundamental assumption is that most software developed for Ruya OS will be created, maintained, tested and extended using AI coding agents such as Claude Code, Codex, Cursor and other compatible development agents.

The Ruya developer experience must therefore be designed around the needs of AI agents, rather than treating AI support as an additional feature of a conventional SDK.

The platform must allow an AI agent to:

1. Understand the Ruya OS architecture.
2. Discover available SDKs, APIs, services and UI components.
3. Understand the rules and conventions for developing Ruya applications.
4. Create a new native application.
5. Generate application code using official SDKs and components.
6. Integrate with Ruya OS services.
7. Build and package the application.
8. Run the application in a Ruya development environment.
9. Inspect its UI, logs and behaviour.
10. Run automated tests and validate compliance.
11. Identify and correct implementation problems.
12. Produce a finished application that follows Ruya standards.

The intended result is a development platform where an AI agent can receive a product brief and independently implement a complete Ruya-native application with minimal human intervention.

**Important:** This project is about providing the infrastructure, SDK, documentation and tooling that AI agents need to develop software for Ruya. It is not a request to build an LLM, AI assistant or AI inference engine into the operating system.

# 2. Implementation instructions

Before making changes, inspect the existing Ruya OS repository and understand its current architecture.

Do not assume that the architecture, programming languages, service managers, build systems or directory structures described in this document already exist.

The implementation must:

- Reuse the existing architecture wherever possible.
- Follow established project conventions.
- Avoid introducing unnecessary dependencies.
- Avoid creating parallel implementations of existing functionality.
- Keep interfaces modular and independently testable.
- Use documented, versioned interfaces.
- Avoid temporary hacks, placeholder implementations and unnecessary TODOs.
- Include proper error handling.
- Include automated tests.
- Update relevant documentation whenever functionality changes.
- Keep the implementation compatible with the existing Ruya OS direction.

If an architectural decision in this specification conflicts with an established implementation, inspect the conflict and choose the solution that best preserves the long-term architecture. Document significant deviations.

Do not rewrite existing working systems simply to match the examples in this specification.

Before implementation, produce a short architecture assessment identifying:

- Existing components that can be reused.
- Missing infrastructure.
- Existing conventions and technologies.
- Required architectural decisions.
- Dependencies between implementation phases.

Then implement the specification incrementally.

# 3. Core architectural principles

## 3.1 AI-first, not AI-exclusive

The platform must work for both AI agents and human developers.

However, every developer-facing feature must be designed so that AI agents can discover, understand and operate it reliably.

## 3.2 One source of truth

Documentation, API definitions, schemas, examples and validation rules must not become independent representations of the same functionality.

Where practical, generate documentation and reference material from authoritative API definitions and source code.

The goal is to prevent documentation from becoming outdated or contradicting the actual implementation.

## 3.3 Machine-readable interfaces

All important developer-facing functionality must have machine-readable representations.

Examples include:

- API specifications.
- SDK metadata.
- Application manifests.
- Capability definitions.
- Permission definitions.
- UI component catalogues.
- Error definitions.
- Build configuration.
- Test results.

AI agents must not need to infer important platform behaviour from source code alone.

## 3.4 Predictable behaviour

APIs must be explicit and consistent.

Prefer:

- Strongly typed parameters.
- Explicit method names.
- Predictable return structures.
- Standardised error codes.
- Explicit permission requirements.
- Idempotent operations where appropriate.
- Consistent naming conventions.
- Documented lifecycle behaviour.

Avoid ambiguous APIs and undocumented implicit behaviour.

## 3.5 Validation over trust

The platform must not assume that generated applications follow Ruya standards.

It must provide automated mechanisms to verify application architecture, permissions, UI behaviour, controller navigation, API integration and packaging.

# 4. Platform architecture

The Ruya AI Developer Platform must be a distinct but integrated part of the Ruya developer ecosystem.

It consists of the following components.

| Component | Responsibility |
|---|---|
| Developer Documentation | Human- and AI-readable technical documentation |
| SDK Discovery | Discover available APIs, services and components |
| Ruya Developer CLI | Command-line interface for development operations |
| Application Templates | Official, working application scaffolds |
| API Catalogue | Machine-readable API and service definitions |
| Design System Catalogue | Discoverable UI components and HIG rules |
| Validation Engine | Validate applications against Ruya requirements |
| Build and Packaging Integration | Build and package native applications |
| Development Environment Integration | Run and inspect applications |
| UI Inspection | Inspect UI structure, focus and accessibility |
| Ruya Developer MCP | Optional structured interface for AI agents |

The implementation must integrate with existing Ruya services and build infrastructure rather than duplicate them.

# 5. Documentation architecture

Documentation is a core platform feature, not an optional project deliverable.

The documentation must serve two audiences:

1. Human developers.
2. AI coding agents.

Both must use the same authoritative information.

## 5.1 Documentation structure

Establish a structured documentation repository.

Suggested structure:

```text
developer-platform/
│
├── README.md
├── AGENTS.md
├── llms.txt
├── llms-full.txt
│
├── getting-started/
│   ├── overview.md
│   ├── environment-setup.md
│   ├── installation.md
│   ├── first-application.md
│   └── troubleshooting.md
│
├── architecture/
│   ├── overview.md
│   ├── application-model.md
│   ├── service-architecture.md
│   ├── application-lifecycle.md
│   ├── permissions.md
│   ├── events.md
│   └── versioning.md
│
├── sdk/
│   ├── overview.md
│   ├── app.md
│   ├── ui.md
│   ├── content.md
│   ├── library.md
│   ├── storage.md
│   ├── activity.md
│   ├── launch.md
│   ├── saves.md
│   ├── media.md
│   ├── input.md
│   └── system.md
│
├── design-system/
│   ├── principles.md
│   ├── colors.md
│   ├── typography.md
│   ├── spacing.md
│   ├── navigation.md
│   ├── controller-interaction.md
│   ├── accessibility.md
│   └── components/
│
├── api-reference/
│   ├── services/
│   ├── schemas/
│   ├── events/
│   ├── permissions/
│   └── errors/
│
├── examples/
│   ├── basic-application/
│   ├── media-player/
│   ├── emulator/
│   ├── game-launcher/
│   └── settings-application/
│
├── recipes/
│   ├── register-a-game.md
│   ├── register-media.md
│   ├── implement-recent-items.md
│   ├── implement-search.md
│   ├── implement-controller-navigation.md
│   ├── implement-notifications.md
│   └── integrate-save-management.md
│
└── testing/
    ├── build-validation.md
    ├── api-validation.md
    ├── ui-validation.md
    ├── controller-testing.md
    └── integration-testing.md
```

Adapt this structure to the actual repository where appropriate.

## 5.2 Documentation requirements

Every public SDK module must document:

- Purpose.
- Supported functionality.
- Public interfaces.
- Parameters and return values.
- Required permissions.
- Expected errors.
- Lifecycle considerations.
- Version compatibility.
- Security considerations.
- Working examples.
- Related APIs.

Documentation must distinguish between:

- Guaranteed behaviour.
- Optional functionality.
- Implementation-specific behaviour.
- Deprecated functionality.
- Experimental functionality.

Do not present proposed or unsupported functionality as implemented.

## 5.3 AI-readable documentation

Provide:

### `llms.txt`

A concise entry point for AI agents explaining:

- What Ruya is.
- Where the documentation is located.
- How to discover the SDK.
- Where API specifications are stored.
- Where examples are located.
- How to build and validate applications.

### `llms-full.txt`

A generated consolidated documentation representation containing the relevant stable developer documentation.

It must be generated from authoritative documentation sources rather than maintained manually.

### `AGENTS.md`

Provide repository-level instructions for AI coding agents.

These instructions must cover:

- Project architecture.
- Supported technologies.
- Repository structure.
- Build commands.
- Testing commands.
- Coding conventions.
- API usage rules.
- Design-system requirements.
- Security requirements.
- Documentation requirements.
- Prohibited implementation practices.

Application templates must also include an application-specific `AGENTS.md`.

## 5.4 Documentation quality

Documentation must be:

- Concise without omitting important technical details.
- Structured with predictable headings.
- Explicit about prerequisites.
- Version-aware.
- Cross-referenced.
- Searchable.
- Supported by working examples.

Avoid relying on screenshots as the only explanation of an API or component.

# 6. SDK and API discovery

The platform must provide a reliable way for AI agents to discover what Ruya supports.

Implement an SDK catalogue containing:

- Available SDK modules.
- Public APIs.
- API versions.
- Required permissions.
- Supported capabilities.
- Available UI components.
- Supported application types.
- Code examples.
- Documentation references.
- Compatibility information.

The catalogue must be machine-readable.

An AI agent must be able to request information about an API without reading the entire SDK.

For example:

```bash
ruya sdk list
ruya sdk inspect content
ruya sdk inspect activity
ruya sdk inspect ui
ruya sdk components list
ruya sdk permissions list
```

The exact commands may be adapted to the existing CLI conventions.

The output must include enough information to select the correct API and understand how to use it.

Where possible, the CLI must support JSON output.

# 7. Ruya Developer CLI

Create an official developer command-line tool named `ruya`, or integrate these capabilities into an existing Ruya CLI if one already exists.

The CLI must be designed for both humans and AI agents.

## 7.1 Application management

Required operations:

```bash
ruya app create <name>
ruya app inspect <app-id>
ruya app validate
ruya app build
ruya app run
ruya app package
```

The application creation command must generate a valid project structure based on an official template.

## 7.2 SDK discovery

```bash
ruya sdk list
ruya sdk inspect <module>
ruya sdk components list
ruya sdk permissions list
ruya sdk versions
```

## 7.3 Code generation

Provide code generators for common integration patterns.

Examples:

```bash
ruya generate content-provider
ruya generate activity-provider
ruya generate media-session
ruya generate game-integration
ruya generate settings-page
```

Generated code must be functional and use the official SDK.

Do not generate placeholder methods that silently do nothing.

## 7.4 Validation

```bash
ruya app validate
ruya app validate --format json

ruya ui validate
ruya ui validate --format json

ruya test integration
ruya test integration --format json
```

## 7.5 Structured output

Every command intended for automated use must support predictable machine-readable output where applicable.

JSON output must include:

- Operation status.
- Results.
- Errors.
- Error codes.
- Relevant file paths.
- Suggested corrective actions where available.

The CLI must use meaningful exit codes.

Do not make AI agents parse unstable terminal formatting to determine whether an operation succeeded.

## 7.6 Error messages

Errors must be actionable.

Example:

```text
ERROR: Missing permission.

Application:
com.example.media

Required permission:
content.register

Suggested action:
Add content.register to the application manifest.

Documentation:
sdk/content/registration.md
```

The CLI must distinguish between user errors, application errors, environment errors and platform errors.

# 8. Application manifest and capability discovery

Every native Ruya application must provide a machine-readable manifest.

The manifest must describe:

- Application identity.
- Name and version.
- SDK compatibility.
- Entry point.
- UI framework.
- Supported input methods.
- Declared capabilities.
- Requested permissions.
- Content types.
- Supported application actions.
- Optional service integrations.

Illustrative example:

```yaml
app:
  id: com.ruya.media
  name: Ruya Media
  version: 1.0.0
  sdk_version: 1

ui:
  framework: qt-quick
  controller_support: true
  keyboard_support: true
  touch_support: true

capabilities:
  - content.provider
  - content.recent
  - content.recently_added
  - content.search
  - activity.provider
  - media.playback

permissions:
  - storage.media.read
  - storage.media.write

integrations:
  content_types:
    - movie
    - episode
    - series
    - music

  actions:
    - open
    - play
    - resume
```

This is an illustrative schema. Define the authoritative manifest format based on the existing Ruya architecture.

The manifest validator must check:

- Required fields.
- Field types.
- Supported SDK versions.
- Capability validity.
- Permission validity.
- Compatibility.
- Duplicate identifiers.
- Invalid combinations.

Applications must not be able to claim capabilities that they cannot implement.

# 9. Design System and HIG integration

The Ruya Design System must be available to application developers through official SDK components and machine-readable component definitions.

The design system must be treated as a platform dependency.

## 9.1 Official UI framework

Qt 6 / Qt Quick / QML is the proposed official native UI framework, subject to verification against the existing Ruya OS architecture.

The SDK should provide reusable components for:

- Buttons.
- Icon buttons.
- Cards.
- Game cards.
- Media cards.
- Carousels.
- Content grids.
- Navigation sidebars.
- Dialogs.
- Context menus.
- Toast notifications.
- Progress indicators.
- Focus indicators.
- Controller hints.
- Featured content layouts.
- Loading states.
- Empty states.

## 9.2 Component catalogue

Every component must have a discoverable specification containing:

- Component name.
- Purpose.
- Properties.
- Events.
- Supported states.
- Focus behaviour.
- Controller behaviour.
- Accessibility information.
- Examples.
- Restrictions.

The catalogue must be accessible through the SDK documentation and CLI.

## 9.3 HIG requirements

Applications must follow Ruya's controller-first design principles.

Mandatory requirements:

- All interactive elements must be accessible through controller navigation.
- Focus must always be visually apparent.
- Focus order must be predictable.
- No essential functionality may depend on hover.
- Back and Confirm behaviour must be consistent.
- Focus should be restored after closing dialogs or navigating back.
- Interactive targets must be suitable for television viewing.
- Text must remain readable at supported viewing distances.
- Important content must respect safe display areas.
- Loading and empty states must be implemented.
- Keyboard navigation must also work.
- Accessibility labels must be available.

## 9.4 Shared system preferences

The SDK should expose system preferences where supported:

- Theme.
- Accent colour.
- Language.
- Display scaling.
- Accessibility preferences.
- Controller mappings.
- Audio output preferences.

Applications should inherit system preferences by default.

They must not independently override global settings without an explicit user choice.

# 10. Automated application validation

Create a Ruya Validation Engine.

Its purpose is to verify that applications meet platform requirements.

Validation must be executable from the CLI and suitable for AI-driven development loops.

## 10.1 Manifest validation

Check:

- Manifest syntax.
- Required metadata.
- Capability declarations.
- Permission declarations.
- SDK compatibility.
- Application identity.
- Unsupported features.

## 10.2 SDK validation

Check:

- Correct SDK usage.
- Deprecated API usage.
- Unsupported API usage.
- Missing required integrations.
- API compatibility.
- Invalid permission combinations.

Do not attempt to prove all application behaviour through static analysis. Runtime tests are also required.

## 10.3 UI validation

Check:

- Use of official components where required.
- Focus visibility.
- Focus navigation.
- Controller interaction.
- Keyboard navigation.
- Accessibility labels.
- Text contrast.
- Supported display sizes.
- Safe display areas.
- Loading states.
- Empty states.
- Error states.

## 10.4 Integration validation

Check:

- Service availability handling.
- Permission enforcement.
- Content registration.
- Activity reporting.
- Application lifecycle.
- Launch integration.
- Error handling.
- Recovery after service interruption.

## 10.5 Validation levels

Define three application compliance levels:

**Basic**

- Builds successfully.
- Manifest is valid.
- Required permissions are declared.
- Application can launch.

**Ruya Compatible**

- Passes API integration tests.
- Passes controller navigation tests.
- Meets mandatory HIG requirements.
- Handles service failures correctly.

**Ruya Verified**

- Passes the full automated test suite.
- Passes supported resolution and scaling tests.
- Passes accessibility checks.
- Passes lifecycle and recovery tests.
- Passes security and permission checks.
- Has complete application documentation.

The validation engine must return structured results and clear remediation instructions.

# 11. Development and runtime inspection

AI agents must be able to inspect applications running in a Ruya development environment.

Where possible, integrate with an existing emulator, virtual machine or development image.

Provide tooling for:

- Launching an application.
- Stopping an application.
- Retrieving logs.
- Inspecting application state.
- Inspecting service connectivity.
- Inspecting registered content.
- Inspecting permissions.
- Inspecting UI structure.
- Simulating controller input.
- Running automated navigation tests.
- Capturing screenshots.
- Inspecting application errors.

The implementation should not require a physical television or controller for routine testing.

## 11.1 UI inspection interface

Provide machine-readable information about the running UI.

For example:

```json
{
  "screen": "library",
  "elements": [
    {
      "id": "game-card-1",
      "role": "button",
      "label": "Sonic the Hedgehog",
      "focused": true,
      "enabled": true
    },
    {
      "id": "settings-button",
      "role": "button",
      "label": "Settings",
      "focused": false,
      "enabled": true
    }
  ]
}
```

This is an illustrative output format.

The inspection system must expose semantic information rather than relying only on screenshot analysis.

It must not expose sensitive user data unnecessarily.

## 11.2 Controller simulation

Provide automated controller input support.

At minimum:

- D-pad.
- Left stick.
- Right stick.
- Confirm.
- Back.
- Menu.
- Shoulder buttons.
- Triggers.

The test environment must allow AI agents to navigate the application and verify focus behaviour.

# 12. Ruya Developer MCP Server

Implement an optional Ruya Developer MCP Server to provide structured development tools to compatible AI agents.

MCP is a development-time integration. It must not be a mandatory runtime dependency of native applications.

The server must expose operations equivalent to the developer CLI and inspection tools.

Proposed tool catalogue:

| Tool | Purpose |
|---|---|
| `ruya_get_developer_overview` | Explain the development environment |
| `ruya_search_docs` | Search official documentation |
| `ruya_get_sdk_module` | Retrieve SDK module documentation |
| `ruya_inspect_api` | Inspect a public API |
| `ruya_list_components` | List UI components |
| `ruya_get_component` | Retrieve a component specification |
| `ruya_create_app` | Generate an application scaffold |
| `ruya_validate_manifest` | Validate an application manifest |
| `ruya_build_app` | Build an application |
| `ruya_run_app` | Launch an application |
| `ruya_get_logs` | Retrieve application logs |
| `ruya_inspect_ui` | Inspect running UI elements |
| `ruya_simulate_input` | Simulate controller input |
| `ruya_run_ui_tests` | Execute UI tests |
| `ruya_validate_integration` | Validate OS integration |

Requirements:

- Follow the MCP protocol version supported by the implementation.
- Use explicit input and output schemas.
- Return structured errors.
- Respect user and application permissions.
- Do not expose unrestricted system execution through the MCP server.
- Restrict operations to authorised development environments.
- Keep the server optional.
- Document configuration for Claude Code and other compatible agents.

If an MCP tool is not yet supported by the underlying infrastructure, do not create a misleading placeholder. Implement the required infrastructure or clearly mark the tool as unavailable.

# 13. Official reference applications

The platform must include reference applications that demonstrate correct SDK usage.

These applications are essential because AI agents need working examples, not just abstract documentation.

Implement the following progressively.

## 13.1 Basic Application

Demonstrates:

- Application manifest.
- App lifecycle.
- Navigation.
- Shared UI components.
- Controller interaction.
- System settings.
- Notifications.

## 13.2 Media Player Reference Application

Demonstrates:

- Media content registration.
- Recently added items.
- Recently played items.
- Metadata and artwork.
- Playback sessions.
- Playback progress.
- Continue Watching.
- Media controls.
- Search integration.

## 13.3 Emulator Reference Application

Demonstrates:

- ROM import.
- Managed ROM storage.
- Game registration.
- Game metadata.
- Emulator launch integration.
- Activity reporting.
- Save management integration.
- Controller support.

## 13.4 Settings Reference Application

Demonstrates:

- System preference APIs.
- Theme handling.
- Controller settings.
- Notifications.
- Dialogs.
- Accessibility.

These must be real applications that build, run and pass the platform's validation tests.

Avoid maintaining fake demonstration code that does not reflect the actual SDK.

# 14. API versioning and governance

Public interfaces must be versioned.

Establish rules for:

- SDK versions.
- API versions.
- Manifest versions.
- Component versions.
- Deprecation.
- Breaking changes.
- Migration.
- Compatibility.

Every public API must have an identifiable owner and authoritative specification.

Breaking changes must not silently break existing applications.

Provide migration documentation and, where practical, automated migration assistance.

Examples and reference applications must be tested against supported SDK versions.

# 15. Security requirements

The AI Developer Platform must not weaken Ruya OS security.

In particular:

- Development tools must not bypass application permissions.
- MCP operations must be authorised.
- Build and test operations must use controlled environments.
- Application inspection must respect user privacy.
- Logs must avoid exposing credentials and sensitive information.
- Applications must not receive unrestricted access to system services.
- Generated code must not be trusted simply because an AI generated it.
- Validation must include permission and integration checks.

The development environment should be isolated from the user's normal production environment where practical.

# 16. Testing requirements

The implementation must include automated tests for:

## Documentation

- All public APIs have documentation.
- Documentation links resolve.
- Generated documentation matches authoritative API definitions.
- SDK examples compile.
- Documentation version metadata is correct.

## CLI

- Application creation.
- SDK discovery.
- JSON output.
- Error reporting.
- Validation.
- Build operations.
- Packaging.

## Manifest

- Valid manifests.
- Invalid manifests.
- Missing permissions.
- Unsupported capabilities.
- Version incompatibility.

## Validation Engine

- Correctly identifies invalid applications.
- Reports actionable errors.
- Produces stable machine-readable output.
- Does not report unsupported checks as passed.

## Design System

- Component discovery.
- Component documentation.
- Controller navigation.
- Focus handling.
- Supported display sizes.

## MCP

- Tool discovery.
- Input validation.
- Output schemas.
- Error handling.
- Permission enforcement.

## Reference Applications

- Build.
- Launch.
- API integration.
- UI compliance.
- Controller interaction.
- Runtime recovery.

# 17. Implementation phases

Implement the platform in dependency order.

Do not attempt to implement every feature in one large change.

## Phase 0 — Repository and architecture assessment

Inspect the existing Ruya OS repository.

Identify:

- Existing architecture.
- Current programming languages.
- Build systems.
- Service communication.
- Application lifecycle.
- UI framework.
- Existing developer tooling.
- Existing documentation.
- Existing test infrastructure.

Deliver an architecture assessment and implementation plan.

Do not begin large-scale implementation before understanding these dependencies.

## Phase 1 — Developer platform foundation

Implement:

- Developer documentation structure.
- Repository-level `AGENTS.md`.
- `llms.txt`.
- SDK catalogue structure.
- API definition conventions.
- Versioning conventions.
- Developer platform architecture documentation.

Establish the authoritative source of truth for public interfaces.

## Phase 2 — Developer CLI

Implement:

- CLI foundation.
- Application inspection.
- SDK discovery.
- Component discovery.
- Permission discovery.
- Manifest validation.
- Structured JSON output.
- Actionable error reporting.

## Phase 3 — Application templates

Implement:

- Basic application template.
- Manifest generation.
- Official directory structure.
- Application-specific `AGENTS.md`.
- Build integration.
- Packaging integration.

The generated application must actually build and launch.

## Phase 4 — Design System integration

Implement:

- Official UI component catalogue.
- Design system documentation.
- HIG documentation.
- Component discovery through the CLI.
- Controller navigation validation.
- UI validation infrastructure.

Reuse the existing Ruya UI implementation where available.

## Phase 5 — Application validation

Implement:

- Static validation.
- API validation.
- Permission validation.
- UI validation.
- Integration validation.
- Machine-readable reports.

## Phase 6 — Development environment inspection

Implement:

- Application launch and stop.
- Log retrieval.
- Runtime inspection.
- UI inspection.
- Controller simulation.
- Automated UI testing.
- Screenshot capture.

## Phase 7 — MCP integration

Implement the optional developer MCP server.

Integrate it with the CLI, documentation, SDK catalogue and runtime inspection tools.

## Phase 8 — Reference applications

Implement the Basic Application first.

Then develop the Media Player and Emulator reference applications as the principal SDK integration tests.

Use these applications to identify missing APIs, documentation gaps and shortcomings in the design system.

# 18. Definition of Done

The Ruya AI Developer Platform is not complete merely because a CLI or documentation website exists.

The following must be demonstrated.

### Documentation and discovery

- An AI agent can discover available SDK modules.
- An AI agent can retrieve authoritative API specifications.
- An AI agent can find relevant implementation examples.
- Documentation accurately reflects implemented functionality.

### Application creation

- An AI agent can create a new Ruya application using the official template.
- The generated application contains the correct manifest and project structure.
- The application builds and launches.

### Development workflow

- The AI agent can inspect APIs and components.
- The AI agent can build the application.
- The AI agent can retrieve logs.
- The AI agent can inspect the running UI.
- The AI agent can simulate controller input.
- The AI agent can execute validation tests.

### Quality

- Validation produces structured and actionable results.
- The application passes the relevant HIG requirements.
- API and permission integration is verified.
- The application can be packaged for Ruya.

### Integration

- The developer tooling uses the actual Ruya SDK and services.
- No parallel or fake API implementation is used.
- Reference applications demonstrate real functionality.

# 19. Final architectural principles

These principles must guide all future work on the platform.

1. **AI-first:** Assume AI agents will be the primary application developers.
2. **Human-compatible:** Human developers must still be able to use the same tools.
3. **One source of truth:** APIs, schemas and documentation must remain consistent.
4. **Discoverable:** Every public capability must be machine-readable and discoverable.
5. **Predictable:** APIs must be explicit, typed and consistent.
6. **Testable:** All important application requirements must be verifiable.
7. **Self-correcting workflow:** Tools must explain failures and suggest corrective actions.
8. **Platform consistency:** Native applications must follow Ruya's HIG and Design System.
9. **Secure by design:** AI-generated applications must use the same security model as other applications.
10. **Independently extensible:** The platform must support new SDK modules, APIs, frameworks and application types without requiring a complete redesign.

---

# 20. Instructions to Claude Code

Treat this document as the architectural specification for the Ruya AI Developer Platform.

Your first task is to inspect the existing Ruya OS repository and establish how this platform should fit into the current architecture.

Then:

1. Produce a concise architecture assessment.
2. Identify existing components that can be reused.
3. Identify missing dependencies and infrastructure.
4. Propose the concrete implementation structure.
5. Identify architectural decisions that need to be resolved.
6. Implement the platform in dependency-ordered phases.
7. Add automated tests for every implemented feature.
8. Update documentation alongside implementation.
9. Verify the finished functionality using the actual development environment.

Do not simply create documentation and placeholder commands.

Every implemented command, API, validation rule and integration must perform its advertised function.

Do not mark an implementation complete if it only contains scaffolding.

If an underlying Ruya OS service does not yet exist, document the dependency and implement only the developer-platform infrastructure that can genuinely work without it. Do not simulate a successful integration with a fake service.

At the end of each phase, provide:

- What was implemented.
- Which existing components were reused.
- Which files and modules were added or changed.
- Tests performed and their results.
- Remaining dependencies.
- Any architectural decisions or deviations.

**Ultimate acceptance criterion:**

A compatible AI coding agent should be able to receive a brief such as:

"Create a native Ruya emulator that imports Genesis ROMs, registers them in the central Games library, supports controller navigation and integrates with Ruya Save Management."

It should be able to discover the required documentation, create the application, use the correct SDK APIs, implement the UI, build the application, run it in a Ruya development environment, validate its behaviour and produce a distributable application without having to guess how Ruya works.

That is the standard this platform must be built to achieve.