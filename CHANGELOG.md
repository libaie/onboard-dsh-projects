# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- docs/getting-started.md (+ Simplified Chinese) — full walkthrough from a clean machine to a running controller session.
- Cost discipline: economy-first tiering, per-batch controller session rotation (default 8 terminal CHAINs), and off-peak batching guidance in SKILL.md and the controller template.
- `scripts/rebuild-dashboard.ps1` regenerates `TASKS.md` from the controller manifest (active / pending with gate status / terminal rows).
- Governance test suite: phase state machine + dashboard regeneration (15 assertions; total suite count now 5, 75 assertions).

### Changed

- Dispatch phases are now a closed, monotonic set (`dispatched -> in-progress -> evidence-collected`); backward or unknown transitions are rejected.

## [0.1.0] - 2026-08-17

First public release of the DeepSeek Harness adaptation.

### Added

- **Repository onboarding**: read-only verification, workspace-local snapshot index, and persistent entry subagents; `projects/<repoId>/binding.json` is the single source of truth.
- **Controller**: `.dsh-controller.json` manifest, CAS-protected `Read -> PrepareCandidate -> ApplyCandidate -> Read` protocol, hash-chained CHAIN ledger with monthly archive, bounded `MEMORY.md`, and `TASKS.md` dashboard.
- **Dispatch queue**: per-repo FIFO with cross-repo parallelism, leases, generations/rework, model tiers (DSH DeepSeek defaults, overridable via `set-model-tier`), retry and cancel.
- **External-write lane**: capability registry, per-dispatch user authorization gate, no-lane brake, and a lane-executor seed template for Jenkins/Nacos/MySQL/Redis/SSH/HTTP mutations.
- **Goal ledger**: `register-goal` / `advance-goal` / `terminal-goal` with CHAIN linkage.
- **Dependency gating**: dispatches declare dependencies with allowed terminal states; `cancel-pending-dispatch` prevents FIFO deadlocks.
- **Contracts in state**: `freeze-contract` (append-only, amendments are new versions) with `contractRef` and `goalIdRef` on dispatches.
- **Mandatory request routing**: entry agent for single-repo work, workflow for cross-repo work, external-write lane for external mutations, with anti-bypass brakes.
- **Controller / Entry-Agent Contract**: authoritative responsibilities, boundaries, and collaboration order for both sides.
- **Codebase-Memory Bridge** (`cbm_*`): optional call-graph-level exploration.
- **Tests and CI**: four suites (lane / goal / dependency / contract), 60 assertions, running on Windows PowerShell 5.1 with a GitHub Actions workflow.
