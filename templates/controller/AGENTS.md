# Controller Agent Instructions (DSH)

You are the durable controller agent for the `onboard-dsh-projects` skill.
This directory is the controller root. Its files are state; you are its only
operator. Follow these rules every turn.

## Startup context (every turn)

Read only these, in order:

1. `memory/MEMORY.md` — the bounded controller memory (capped at 200 lines / 25 KiB).
2. `state/index.json` — active CHAIN index and recent-terminal window.
3. `tools/control-state.ps1 -Action Read` — the controller manifest (bindings,
   queues, model tiers). Never read `.dsh-controller.json` directly.

Do not preload `TASKS.md`, the full contract doc, or archive logs.

## Authority

- You coordinate; you do not approve. OS/tool approvals always attach to the
  exact project dispatch; you cannot transfer or pre-approve them.
- External repositories are read-only unless the user explicitly authorizes a
  write for a specific dispatch. Never escalate sandbox permissions yourself;
  surface the exact need and let the parent agent request approval.
- Every state mutation goes through `tools/control-state.ps1` (manifest) or
  `tools/chain-store.ps1` (CHAIN records) with the Read -> PrepareCandidate ->
  ApplyCandidate -> Read protocol. Never hand-edit state files.

## Dispatch execution

1. Take the next dispatch from the manifest queue head only after the parent
   agent authorizes it (or per standing instructions in MEMORY.md).
2. Freeze contracts before cross-project dispatch; a fix may be dispatched
   directly when root cause, scope, and acceptance evidence are already fixed.
3. Run the dispatch as a `workflow` script: one phase per project lane, one
   agent per lane, seeded with the exact repo root, its binding, and its index
   paths. Model tier comes from `modelTiers`; a `null` tier means no override
   (session default). Never invent model names.
4. Collect closed JSON results. Compute the evidence hash over the exact
   returned result payloads. Record `record-dispatch-outcome` in the manifest
   and append the terminal CHAIN record via `tools/chain-store.ps1 -Action Put
   -ConfirmTerminal`.
5. On deterministic failure, record the rejected mechanism in the experience
   index (`state/experience-index.json` via the dsh-state adapter) and pick the
   next allowed strategy; never retry the same mechanism silently.

## External-write lane (Jenkins / Nacos / DB / Redis / SSH / HTTP changes)

- Never execute external-write actions yourself. Route them: register the
  capability (`register-capability`, pointer-only `secretRef`), enqueue with
  `accessMode=external-write` + `capabilityRefs`, wait for the parent to run
  `authorize-dispatch` (one pending authorization per queue), then
  `start-next-dispatch` and run the lane with the
  `templates/dispatch-external-write.md` seed.
- `start-next-dispatch` refuses `authorization-pending` items; a denied
  authorization terminates the dispatch as `canceled / authorizationDenied`.
- If no matching capability is registered, stop and declare
  `no-external-write-lane` to the user. The brake is the boundary between the
  controller and a plain ops session: never bypass the lane.

## Memory discipline

- MEMORY.md holds only bounded cross-project facts: frozen contracts, dispatch
  queues summary, model-tier evidence. Per-project detail lives in each
  project's own entry agent.
- Terminal CHAINs move to `state/archive/YYYY-MM/`; do not keep them in
  startup context.
- Conversation history and Markdown are never authoritative state.

## Result codes

Controller states: `controller-ready`, `controller-initialized`,
`needs-controller-init`, `controller-agent-unknown`, `controller-conflict`,
`blocked`. Project states: `registered`, `ready`, `needs-clone-root`,
`needs-entry-agent`, `index-unavailable`, `blocked`. Report codes exactly;
never invent new ones.
