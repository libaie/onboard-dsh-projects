# dsh-flotilla

[English](./README.md) | [简体中文](./README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
![Status: preview](https://img.shields.io/badge/status-preview-orange.svg)

> **A DeepSeek Harness skill that lets one AI session drive many code repositories — without their contexts bleeding into each other.**

The scariest failure mode in AI-assisted coding isn't a weak model — it's crossed context. Debug a bug across three repos and repo A's instructions leak into repo B's code; you edit the wrong branch, or write somewhere you shouldn't. `dsh-flotilla` puts every repository in its own isolated **entry agent**, then adds an optional **controller** to orchestrate the whole effort.

---

## Why it exists

| Pain | What this skill does |
| --- | --- |
| 😵 Context pollution | One isolated entry subagent per repo: instructions, index, evidence, and edits all stay in their own context |
| 🔀 Repo and baseline drift | Verifies root, branch, HEAD, and dirty state before every run; drift blocks, it never silently proceeds |
| 💸 Model and task mismatch | Three-tier model routing: routine work on `v4-flash`, engineering and high-stakes work on `v4-pro` |
| 🔁 Repeating the same mistakes | A bounded experience index: proven strategies are reused, deterministic failures reject the same mechanism |
| 🧠 Controller memory bloat | The controller keeps only cross-project contracts and dispatch state; the ledger is hash-chained and archived, never growing without bound |

**In one line**: when a feature, incident, or release spans multiple repositories with different instructions, branch rules, test commands, or write scopes — this is the skill for it.

## Dependencies (read before installing)

| Dependency | Level | Notes |
| --- | --- | --- |
| DeepSeek Harness (DSH) | **Required** | The skill only runs inside DSH sessions; it is built on DSH-native tools (`subagent`, `workflow`, session notifications, skill loading). |
| Windows PowerShell 5.1 | **Required** | Every script targets it; CI verifies it on every push. |
| DSH session-persistence backend | **Required** | Entry subagents are continuable children and require a session-persistence backend to be loaded. |
| Registered LLM models | **Required** | Tier models (defaults: `deepseek-official` / `deepseek-v4-flash` / `deepseek-v4-pro`) must resolve in the deployment's `llm` service; otherwise set the tiers to `null` (session default) with `set-model-tier`. |
| Git | Conditional | Only for Git sources (`-RequireGit` in preflight). |
| OpenSSH client | Conditional | Only for SSH-based sources (`-RequireSsh`). |
| Git LFS | Conditional | Only for full-LFS checkouts (`-RequireLfs`). |
| Node 18+ | Conditional | Controller dispatch via `workflow` and any Node scripts (`-RequireNode`). |
| codebase-memory | Optional | The `cbm_*` graph bridge; when absent, the skill falls back to its lightweight index. |

`scripts/preflight.ps1` checks every dependency and fails closed on `status=blocked`.

## What you get

- ✅ Per repository: one read-only verification → one snapshot index (structure / entrypoints / docs / glossary) → one long-lived entry subagent
- ✅ Optional controller: dispatch queue state machine + hash-chained CHAIN records + three-tier model routing + bounded experience reuse
- ✅ **External-write lane**: Jenkins / Nacos / DB / Redis / SSH changes go through a capability registry with per-dispatch user authorization and the same CHAIN accounting — with a no-lane brake so the controller never does ops work itself
- ✅ **Mandatory request routing** — every request is classified first: external mutations → external-write lane, single-repo work → that repo's entry agent (never a one-shot stand-in), multi-repo or contract work → workflow dispatch; mixed requests are split and sequenced
- ✅ **Cost discipline** — economy-first tiering (flash by default), per-batch controller session rotation, and off-peak batching to keep context-cache spend bounded
- ✅ **Dependency gating** — a dispatch can declare dependencies on earlier dispatches (with allowed terminal states); the queue refuses to start it until satisfied, and a blocked head can be canceled without deadlocking the FIFO
- ✅ **Goal ledger**: register, advance, and terminate goals in the manifest (`register-goal` / `advance-goal` / `terminal-goal`), linkable to a CHAIN
- ✅ **Authoritative contract**: the SKILL.md section "Controller / Entry-Agent Contract" pins down responsibilities, boundaries, and the collaboration order for both sides — violations are reported, never silently worked around
- ✅ Every piece of state is CAS-hash-verified; mutations must go through a `Read → Prepare → Apply → Read` protocol — no hand edits, no drift
- ✅ Toolchain preflight, closed input parsing (rejects credentials, unsafe refs, duplicate conflicts); fails closed by default

## Architecture

```mermaid
flowchart LR
    U[User] --> C[Controller agent]
    C -->|dispatch balanced| E1[Repo A entry agent]
    C -->|dispatch balanced| E2[Repo B entry agent]
    C -->|dispatch frontier| E3[Contract freeze / high-stakes work]
    E1 --> I1[(A snapshot index)]
    E2 --> I2[(B snapshot index)]
    C --> Q[(Dispatch queue + CHAIN hash ledger)]
    Q --> M[Monthly archive]
    E1 -->|result evidence| C
    E2 -->|result evidence| C
```

## Quick start (30 seconds)

Full walkthrough from a clean machine to a running controller session:
[docs/getting-started.md](./docs/getting-started.md)
([简体中文](./docs/getting-started.zh-CN.md)).

In a DeepSeek Harness conversation, just say:

```text
Use dsh-flotilla.

sources:
- source: C:\work\service-a
- source: C:\work\web-app
indexMode: full
```

For cross-project work, add the controller:

```text
Use dsh-flotilla.

sources:
- source: C:\work\service-a
- source: C:\work\web-app
controllerRoot: <absolute path inside the workspace>
initializeController: true
createControllerAgent: true
```

Then hand the problem to the controller in plain language:

```text
Trace the H5 login flow end-to-end across the H5 app, mall backend, and member service.
Read-only first, freeze the shared interface contracts, dispatch checks to each repo's
entry agent, and return end-to-end evidence.
```

## Highlights

- 🧩 **Four-quadrant intake protocol** — shared-known / user-known / agent-known / shared-unknown each get their own handling; no guessing, no interrogation
- 🔒 **Read-only onboarding, writes authorized separately** — external repos are read-only by default; cloning, branch switches, and commits each require explicit authorization
- 🎯 **Model routing** — ships with DSH's DeepSeek models: `economy` → `deepseek-v4-flash`, `balanced`/`frontier` → `deepseek-v4-pro`; one command to change (`set-model-tier`)
- 🛡️ **External-write lane** — production mutations (Jenkins, Nacos, MySQL, Redis, SSH) never run bare: capability registry + per-dispatch authorization + evidence gates + rollback
- 🧾 **Hash-chained ledger** — one CHAIN per dispatch, line-by-line hash chaining, terminal records archived under `state/archive/YYYY-MM/`; verifiable and traceable
- 🧪 **Tested for real** — every script runs on Windows PowerShell 5.1: preflight, input parsing, indexing, CAS state machine, dispatch queue, chain store, external-write and Goal operations; end-to-end integration tests green

## Versus one long session

| Approach | Context and lifecycle | Best for |
| --- | --- | --- |
| One long session | All repos share one ever-growing context | Quick, low-risk checks where rules don't differ |
| This skill | Per-repo entry agents + controller holds only cross-project facts | Cross-repo features, incidents, and releases |

Entry agents can still use subagents and workflows internally — the two compose.

## Honest boundaries

- This is **workflow isolation**, not a security sandbox: it changes no filesystem permissions and never transfers authorizations between repos
- The index is a **snapshot**, not a live view; bindings and indexes are re-verified before cross-session work
- Model routing depends on the models your deployment registers; an unconfigured tier falls back to the session default model

## Development

- The repository is the source of truth. Iterate in the repo, then sync the changed files to your DSH skills directory (for example `~/.dsh/skills/dsh-flotilla/`).
- Run the test suites: `powershell -NoProfile -ExecutionPolicy Bypass -File ./tests/run-all.ps1` (Windows PowerShell 5.1). CI runs the same command on every push and pull request.
- Windows notes: keep test scripts ASCII or UTF-8 with BOM (PowerShell 5.1 misreads BOM-less non-ASCII files); the repo normalizes CRLF via `core.autocrlf=true`.
- State-machine changes go through `tools/control-state.ps1` with the CAS protocol; never hand-edit manifests or CHAIN files.

## License

[MIT](./LICENSE)

---

If this project helps you, **give it a Star ⭐** — or send it to a friend who is also fighting multi-repo context pollution. Feedback and PRs are always welcome.
