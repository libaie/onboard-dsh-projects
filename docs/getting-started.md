# Getting Started: Stand Up a Controller Session

This guide takes a brand-new user from a clean machine to a working
`dsh-flotilla` controller session. It assumes you know the basics of
[DeepSeek Harness](https://github.com/) sessions, but nothing about this skill.

> The authoritative contract lives in `SKILL.md`. This guide is the practical
> path through it; when they disagree, `SKILL.md` wins.

## 1. Prerequisites (dependencies)

Required:

- A DeepSeek Harness (DSH) installation — the skill only runs inside DSH.
- Windows PowerShell 5.1 — every script targets it.
- A DSH session-persistence backend — entry subagents are continuable children.
- Registered LLM models — the tier models (defaults `deepseek-v4-flash` /
  `deepseek-v4-pro` under `deepseek-official`) must resolve in your deployment;
  otherwise set tiers to `null` (session default) with `set-model-tier`.
- One DSH workspace per effort (all skill state lives under
  `<workspace>/.agents/dsh-flotilla/`).

Conditional:

- Git — only for remote repository sources.
- OpenSSH client — only for SSH-based sources.
- Git LFS — only for full-LFS checkouts.
- Node 18+ — controller dispatch via `workflow` and any Node scripts.

Optional: codebase-memory (the `cbm_*` graph bridge; the skill falls back to
its lightweight index without it).

`scripts/preflight.ps1` checks all of the above and fails closed.

## 2. Install the skill

Clone into your DSH skills directory (usually `~/.dsh/skills/`):

```powershell
git clone https://github.com/libaie/dsh-flotilla.git "$env:USERPROFILE\.dsh\skills\dsh-flotilla"
```

The skill becomes available in new DSH sessions. (If your DSH loads skills from
another directory, clone there instead.)

## 3. First run: bootstrap the state root

In a DSH session for your workspace, say:

```text
Use dsh-flotilla.

indexMode: full
```

The skill runs `scripts/index-mode.ps1` (asking you to pick `fast|moderate|full`
on first use) and `scripts/preflight.ps1`. You should see `ready` before
continuing.

## 4. Onboard your repositories

Give the skill a closed list of sources (local directories or Git URLs):

```text
sources:
- source: C:\work\service-a
- source: C:\work\web-app
- source: { source: https://github.com/org/repo.git, cloneRoot: C:\work\clones }
```

The skill, per repository: reads its `AGENTS.md`, verifies root/branch/HEAD/dirty
state, writes `projects/<repoId>/binding.json`, generates the snapshot index,
and creates one persistent entry subagent (durable id recorded in the binding).
You get one report line per repo with `state` and `reasonCode`.

From now on, every repository lives behind its entry agent — read-only by
default; writes only inside authorized dispatches.

## 5. Initialize the controller

Add the controller inputs in the same or a new turn:

```text
controllerRoot: <absolute path inside the workspace>
initializeController: true
createControllerAgent: true
```

`init-controller-dsh.ps1` scaffolds the controller root: the manifest
(`.dsh-controller.json`), `AGENTS.md`, `TASKS.md`, `memory/`, `docs/`,
`tools/control-state.ps1`, `tools/chain-store.ps1`, `state/`. With
`createControllerAgent`, the skill also spawns the persistent controller
subagent (seeded with "read `AGENTS.md` first").

## 6. Choose your controller shape

Two supported shapes — pick one:

**A. Controller subagent (hands-off).** Everything goes through the subagent:
`send_message` your cross-project requests to it; it reads
`memory/MEMORY.md` + `state/index.json` + the manifest and dispatches.

**B. User-driven controller session (interactive).** Open a DSH session whose
working directory you control (a dedicated empty dir works), and give it a
short `AGENTS.md` like:

```markdown
# Controller session

You are the controller for the dsh-flotilla skill.
Controller root: <workspace>\.agents\dsh-flotilla\controller
On startup: read the controller root AGENTS.md, run
control-state.ps1 -Action Read and chain-store.ps1 -Action Verify, then report
controller-ready. Route every request per SKILL.md "Request routing".
```

Then, in that session, register it as the controller session so the manifest
and the UI can find it:

```text
Use dsh-flotilla.
set-controller-session for this session.
```

(Internally this runs the `set-controller-session` operation with your session
id.)

## 7. Daily operation

Hand the controller a goal in plain language. It classifies each request
(`SKILL.md` "Request routing"):

- **single-repository work** → `send_message` to that repo's entry agent;
- **cross-repository / contract work** → freeze contracts (`freeze-contract`),
  enqueue (`enqueue-dispatch` with `economy|balanced|frontier` tier), start
  (`start-next-dispatch`), run lanes via `workflow`, then
  `record-dispatch-outcome` + terminal CHAIN;
- **external mutations** (Jenkins/Nacos/DB/Redis/SSH) → the external-write
  lane: `register-capability` → enqueue with `accessMode=external-write` →
  **you** run `authorize-dispatch` → lane executor runs → CHAIN terminal.

Check status any time with `control-state.ps1 -Action Read` and the
auto-generated `TASKS.md` (`scripts/rebuild-dashboard.ps1`).

## 8. Cost discipline (read once, follow always)

1. **Rotate the controller session per batch** — after 24 terminal CHAINs (or a
   finished business batch), hand over to a fresh session:
   `set-controller-session` registers the new session, then rebuild entry
   agents under it (`replace-project-binding` per repo; DSH subagents are bound
   to their durable parent session). Archive the old session.
2. **Batch large dispatches off-peak** — respect your provider's peak pricing
   windows; urgent single dispatches note the premium.
3. **Tiered execution** — `economy` (flash) for routine single-repo work,
   `balanced`/`frontier` (pro) for cross-repo engineering and contracts;
   controller-side analysis may use maximum reasoning effort.

## 9. Troubleshooting

Every public recovery result includes `state, reasonCode, nextAction,
safeToRerun` in that order. Common codes:

| code | meaning | next action |
| --- | --- | --- |
| `needs-entry-agent` | a repo's entry subagent is missing | rebuild it, `replace-project-binding` |
| `authorization-pending` | external-write head awaits your grant | `authorize-dispatch` (or deny) |
| `dependency-unsatisfied` | head's dependencies not terminal in allowed states | wait, or `cancel-pending-dispatch` |
| `no-external-write-lane` | no capability registered for the mutation | `register-capability` or stop |
| `controller-filesystem-conflict` | controller root drifted from its manifest | review by hand, never auto-overwrite |

Run the test suites any time to verify your deployment:
`powershell -NoProfile -ExecutionPolicy Bypass -File ./tests/run-all.ps1`
