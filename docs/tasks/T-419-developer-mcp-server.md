# T-419 - Ruya Developer MCP server (optional, host-side): the CLI's commands as typed tools for AI agents

Status: todo · Phase: 7 · Depends: T-416, T-417, T-418 · Area: tools (an MCP server beside `ruya`), docs/developers · Size: S · Owner: builder · Developer surface: public-API

## Goal
An agent such as Claude Code adds one MCP server and gets typed tools: search docs, inspect an API or component, create, validate, build and run an app, read logs, inspect the UI, send input, run UI tests; every tool is the matching `ruya` command, nothing more.

## Read first
- ADR-031, T-416..T-418 Outcomes, the proposal `docs/archive/research/ai-first-developer-platform-proposal.md` §12 (tool list), the MCP specification version the server targets

## Scope
1. The server (Rust or the language the CLI uses), stdio transport, one tool per `ruya` command with JSON schemas taken from the CLI's output schemas; a tool whose command is not available on this setup is listed as unavailable, never faked.
2. Works only against a development image or the VM (the target address is configured; production consoles refuse the dev socket anyway).
3. A chapter: configuring it in Claude Code and other agents.

## Acceptance criteria
- [ ] Tests: tool discovery, input validation, error mapping from CLI codes, an unavailable tool is reported as such; a recorded session against the VM creates and validates the sample.
- [ ] `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
