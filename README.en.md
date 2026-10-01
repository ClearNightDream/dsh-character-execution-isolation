# dsh-character-execution-isolation

English | [中文](README.md)

> **Status: Experimental · Scope: Runtime/Context Isolation**
> 
> This repository validates **runtime and context isolation**: separate processes, separate `DSH_HOME`, separate profile, and a worker that does not inherit persona or `AGENTS.md`.
> 
> This repository does **not** provide execution security isolation:
> - It does not define an approval protocol (approval is a system prompt convention, not system state).
> - It does not define task lifecycle, concurrency model, failure recovery, or idempotency.
> - It does not prevent a worker from delegating to external processes via `shell-launcher` to bypass the sandbox.
> - It does not isolate OS user permissions, network, environment variables, or a shared workspace.
> 
> If you need full security isolation, this repository is not enough.
> If you need a "reference implementation for decoupling the character layer and execution layer", this repository provides a reproducible verification path.
> 
> Validated on: `0.1.7-rc.1`.
> Known incompatible: `0.1.7-rc.2`.

Use DSH's SDK provider to split the "character layer" and the "execution layer" into two independent runtimes: the character layer handles conversation, persona expression, and user confirmation; the execution layer uses a worker that does not inherit the character persona, runs in a separate process, and uses a separate DSH home to complete tasks.

> This repository is not a plugin or a client project. It is a collection of documentation, sanitized example configurations, and reproducible verification methods.

## Background

Character agents often mix two kinds of responsibility into one session:

- the user-visible persona, tone, and confirmation flow;
- execution logic such as file read/write, Shell, retrieval, and workspace operations.

Mixing them in one session creates several problems:

1. `persona` enters the execution chain and affects the worker's judgment and output.
2. Tool descriptions, workspace conventions, and historical context from the execution layer pollute the character layer.
3. Approval for dangerous operations happens in the execution layer, but the user only interacts with the character layer, so the approval flow is easy to bypass.
4. When reusing the same execution environment, the character persona cannot be cleanly separated.

This repository provides a verified approach: the character layer dispatches to an independent worker runtime through the `dsh-sdk` provider; the worker does not inherit the parent session persona or parent conversation history.

## Architecture

```text
User
  │
  ▼
┌──────────────────┐
│ Character layer   │  ← only user-visible layer
│ (chat)            │
│ persona + tools   │
└────────┬─────────┘
         │ dispatch_worker
         ▼
┌──────────────────┐
│ Execution layer   │  ← separate process, no inherited persona
│ (worker)          │
│ sandbox + tools   │
└──────────────────┘
```

The character layer mounts only the following tools:

- `ask_user_question`
- `web_search`
- `web_fetch`
- `dispatch_worker`

The execution layer does not talk to the user directly. When an operation needs user confirmation, the execution layer returns a "pending confirmation plan"; the character layer relays it to the user in full, and only dispatches again after the user confirms.

## Core features

- **Cross-process isolation**: the worker is an independent DSH runtime with its own `DSH_HOME` and does not inherit the parent session persona.
- **Three security modes**:
  - `readonly`: read-only sandbox, approval `ask`;
  - `autonomous`: workspace-write sandbox, approval `ask`, and the worker system prompt requires dangerous operations to return a pending confirmation plan first;
  - `open`: danger-full-access sandbox, approval `never`.
- **User confirmation flow**: the worker returns a pending confirmation plan, the character layer relays it to the user, and redispatches only after explicit user confirmation.
- **No inherited workspace instructions**: all three worker modes explicitly disable `agent-instructions`.
- **Configuration as code**: the worker persona, sandbox mode, and approval policy are controlled by patch files.

## Known limitations

- Cross-process approval cannot be reported from the worker back to the parent session; the worker can only allow/deny inside its own runtime.
- Under `workspace-write`, "dangerous operations inside the workspace" mainly rely on the worker system prompt. Security is probabilistic.
- There is a path to bypass the sandbox by delegating to external processes via `shell-launcher` (for example `explorer`, `start`, `powershell`).
- `session-mode` does not support switching modes inside the same session; a session that has already run a turn can only start a new session.
- The `dsh-sdk` provider does not automatically create a worker profile; it must be initialized manually.
- If a third-party plugin requires `source.kind: 'plugin'`, under `0.1.7-rc.1` it must be written as `plugin:<name>`.

## Non-goals

This repository does not define or implement:

- a system-level authorization mechanism;
- task lifecycle or orchestration;
- concurrency or retry semantics;
- crash recovery or transactional execution;
- TOCTOU protection;
- OS-level or network security isolation.

These concerns are outside the scope of this repository.

## Quick start

1. Initialize the worker profile:

```powershell
./scripts/init-worker-profile.ps1 -WorkerHome "$env:DSH_ROOT/worker-home" -DshSource "$env:DSH_ROOT/deepseek-harness"
```

2. Copy the patch files under `examples/` to the DSH root directory and replace the placeholders according to the comments.

3. Configure the parent profile's `cordis.patch.yml` and add `session-mode`, `subagent-dsh-sdk-worker`, and `dispatch_worker`.

4. Start and verify:

```powershell
./examples/start-web.ps1 -DshRoot "$env:DSH_ROOT"
```

See [docs/02-setup-guide.md](docs/02-setup-guide.md) for the full steps.

## 5-minute minimal verification

If you only want to quickly confirm whether this approach is worth a deeper look, complete these three steps.

### Prerequisites

- A running DSH `0.1.7-rc.1` instance
- The DSH root directory path (referred to as `$DSH_ROOT` below)

### Step 1: Initialize the worker profile

```powershell
./scripts/init-worker-profile.ps1 `
  -WorkerHome "$DSH_ROOT/worker-home" `
  -DshSource "$DSH_ROOT/deepseek-harness"
```

Expected output: worker profile created at `$DSH_ROOT/worker-home/profiles/worker`

### Step 2: Apply autonomous mode

```powershell
cp ./examples/worker-autonomous.patch.yml "$DSH_ROOT/worker-profile.patch.yml"
```

### Step 3: Dispatch a dangerous operation from the parent session

In a DSH chat session, have the character layer dispatch the following task:

```text
删除工作目录下所有 .md 文件
```

Expected result: the worker does not delete directly. It returns a [pending confirmation] plan containing plan, impact, and risk. The character layer relays the plan to the user.

If the worker deletes directly, isolation is not working. Check item 9 (persona override) and item 10 (agent-instructions inheritance) in `docs/03-pitfalls.md`.

Want stronger verification? See the full verification steps in [docs/04-verification.md](docs/04-verification.md).

## Scope and limitations

### What this repository validates

| Dimension | Status |
|---|---|
| Context isolation | ✅ the worker does not inherit parent conversation history |
| Configuration isolation | ✅ separate profile, separate `DSH_HOME` |
| Identity isolation | ✅ the worker does not inherit the parent session persona |
| Instruction isolation | ✅ the worker does not automatically inherit `AGENTS.md` |
| Tool isolation | ✅ the parent session and the worker configure their tool sets independently |

### What this repository does not define

| Dimension | Status | Notes |
|---|---|---|
| Approval protocol | ❌ Not defined | Approval relies on a system prompt convention, not system state. A user saying "I understand" may be misread as confirmation, and the model may change the plan when red
